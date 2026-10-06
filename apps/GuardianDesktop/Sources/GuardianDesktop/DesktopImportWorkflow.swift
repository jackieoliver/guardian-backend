import AppKit
import CryptoKit
import Foundation

struct LocalImportCandidate: Equatable {
    let fileURL: URL
    let relativePath: String
    let sizeBytes: Int
    let sourceModifiedAt: String
    let contentHash: String
}

struct LocalImportShardDraft: Equatable {
    let shardIndex: Int
    let filename: String
    let fileCount: Int
    let totalSizeBytes: Int
    let tarData: Data
    let contentHash: String
}

enum SourceImportWorkflow {
    private static let maxFilesPerShard = 500
    private static let maxUncompressedBytesPerShard = 8 * 1024 * 1024

    private struct PreparedTransportShard {
        let tarData: Data
        let fileCount: Int
        let totalSizeBytes: Int
    }

    @MainActor
    static func chooseImportFolders(startingAt directoryURL: URL? = nil) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Choose Stream Folders"
        panel.message = "Choose one or more folders for Guardian to scan for new uploads from this source."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.directoryURL = directoryURL ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.urls : nil
    }

    static func collectCandidates(from urls: [URL]) throws -> [LocalImportCandidate] {
        var candidates: [LocalImportCandidate] = []
        for selectedURL in urls {
            let standardizedURL = selectedURL.standardizedFileURL
            let values = try standardizedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                try appendCandidates(in: standardizedURL, to: &candidates)
            } else if values.isRegularFile == true {
                if let candidate = try candidateIfAvailable(
                    for: standardizedURL,
                    relativePath: standardizedURL.lastPathComponent
                ) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates.sorted { $0.relativePath < $1.relativePath }
    }

    static func buildShards(from candidates: [LocalImportCandidate]) throws -> [LocalImportShardDraft] {
        guard !candidates.isEmpty else {
            return []
        }

        var shardGroups: [[LocalImportCandidate]] = []
        var currentGroup: [LocalImportCandidate] = []
        var currentBytes = 0

        for candidate in candidates {
            let wouldExceedCount = currentGroup.count >= maxFilesPerShard
            let wouldExceedBytes = !currentGroup.isEmpty && (currentBytes + candidate.sizeBytes) > maxUncompressedBytesPerShard
            if wouldExceedCount || wouldExceedBytes {
                shardGroups.append(currentGroup)
                currentGroup = []
                currentBytes = 0
            }
            currentGroup.append(candidate)
            currentBytes += candidate.sizeBytes
        }

        if !currentGroup.isEmpty {
            shardGroups.append(currentGroup)
        }

        return try shardGroups.enumerated().compactMap { index, group in
            let preparedShard = try buildTransportShard(from: group)
            guard preparedShard.fileCount > 0 else {
                return nil
            }
            return LocalImportShardDraft(
                shardIndex: index,
                filename: String(format: "shard-%04d.tar", index),
                fileCount: preparedShard.fileCount,
                totalSizeBytes: preparedShard.totalSizeBytes,
                tarData: preparedShard.tarData,
                contentHash: sha256Hex(for: preparedShard.tarData)
            )
        }
    }

    private static func appendCandidates(
        in directoryURL: URL,
        to candidates: inout [LocalImportCandidate]
    ) throws {
        let canonicalDirectoryURL = directoryURL.resolvingSymlinksInPath()
        let rootName = canonicalDirectoryURL.lastPathComponent
        let enumerator = FileManager.default.enumerator(
            at: canonicalDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let nextObject = enumerator?.nextObject() as? URL {
            let canonicalNextObject = nextObject.resolvingSymlinksInPath()
            let values = try canonicalNextObject.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }

            let directoryPath = canonicalDirectoryURL.path
            let filePath = canonicalNextObject.path
            guard filePath.hasPrefix(directoryPath + "/") else {
                continue
            }
            let relativeComponent = String(filePath.dropFirst(directoryPath.count + 1))
            let relativePath = rootName + "/" + relativeComponent
            if let candidate = try candidateIfAvailable(
                for: canonicalNextObject,
                relativePath: relativePath
            ) {
                candidates.append(candidate)
            }
        }
    }

    private static func candidateIfAvailable(
        for fileURL: URL,
        relativePath: String
    ) throws -> LocalImportCandidate? {
        do {
            return try candidate(for: fileURL, relativePath: relativePath)
        } catch {
            if isMissingFileError(error) {
                return nil
            }
            throw error
        }
    }

    private static func candidate(for fileURL: URL, relativePath: String) throws -> LocalImportCandidate {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let sizeBytes = values.fileSize ?? Int((try? Data(contentsOf: fileURL).count) ?? 0)
        let modifiedAt = values.contentModificationDate ?? Date()
        return try LocalImportCandidate(
            fileURL: fileURL,
            relativePath: relativePath,
            sizeBytes: sizeBytes,
            sourceModifiedAt: ISO8601DateFormatter().string(from: modifiedAt),
            contentHash: sha256Hex(forFileAt: fileURL)
        )
    }

    private static func buildTransportShard(from candidates: [LocalImportCandidate]) throws -> PreparedTransportShard {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filesRoot = root.appendingPathComponent("files", isDirectory: true)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let tarURL = root.appendingPathComponent("archive.tar")

        try fileManager.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: root)
        }

        var includedCandidates: [LocalImportCandidate] = []
        for candidate in candidates {
            let destinationURL = filesRoot.appendingPathComponent(candidate.relativePath)
            do {
                guard fileIsReadableRegularFile(candidate.fileURL) else {
                    continue
                }
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: candidate.fileURL, to: destinationURL)
                includedCandidates.append(candidate)
            } catch {
                if isMissingFileError(error) {
                    continue
                }
                throw error
            }
        }

        guard includedCandidates.isEmpty == false else {
            return PreparedTransportShard(
                tarData: Data(),
                fileCount: 0,
                totalSizeBytes: 0
            )
        }

        let manifest = ImportShardManifest(
            files: includedCandidates.map { candidate in
                ImportShardManifestFile(
                    archivePath: "files/" + candidate.relativePath,
                    originalRelativePath: candidate.relativePath,
                    filename: candidate.fileURL.lastPathComponent,
                    contentHash: candidate.contentHash,
                    sizeBytes: candidate.sizeBytes,
                    contentType: "application/octet-stream",
                    sourceModifiedAt: candidate.sourceModifiedAt
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", tarURL.path, "-C", root.path, "manifest.json", "files"]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "tar failed"
            throw NSError(
                domain: "SourceImportWorkflow",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let tarData = try Data(contentsOf: tarURL)
        return PreparedTransportShard(
            tarData: tarData,
            fileCount: includedCandidates.count,
            totalSizeBytes: includedCandidates.reduce(0) { $0 + $1.sizeBytes }
        )
    }

    private static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(forFileAt fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileIsReadableRegularFile(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true && FileManager.default.isReadableFile(atPath: url.path)
        } catch {
            return false
        }
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError
            || nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT
    }
}

private struct ImportShardManifest: Encodable {
    let files: [ImportShardManifestFile]
}

private struct ImportShardManifestFile: Encodable {
    let archivePath: String
    let originalRelativePath: String
    let filename: String
    let contentHash: String
    let sizeBytes: Int
    let contentType: String
    let sourceModifiedAt: String

    enum CodingKeys: String, CodingKey {
        case archivePath = "archive_path"
        case originalRelativePath = "original_relative_path"
        case filename
        case contentHash = "content_hash"
        case sizeBytes = "size_bytes"
        case contentType = "content_type"
        case sourceModifiedAt = "source_modified_at"
    }
}
