import Foundation

struct DesktopImportResult: Equatable, Sendable {
    let userID: String
    let ownedSourceID: String
    let importRunID: String
    let totalCandidateFileCount: Int
    let totalCandidateSizeBytes: Int
    let missingCandidateFileCount: Int
    let shardCount: Int
    let uploadedShardCount: Int
    let settledStatus: String
    let canonicalFileCount: Int
    let processedTransportShardCount: Int
}

enum DesktopImportRunner {
    static func runImport(
        backendClient: GuardianBackendClient,
        idToken: String,
        ownedSourceID: String,
        sourceSnapshotLabel: String = "desktop-import",
        selectedURLs: [URL],
        pollTimeoutSeconds: TimeInterval = 300,
        pollIntervalSeconds: TimeInterval = 2
    ) async throws -> DesktopImportResult {
        let currentUser = try await backendClient.fetchCurrentUser(idToken: idToken)
        let candidates = try await Task.detached(priority: .userInitiated) {
            try SourceImportWorkflow.collectCandidates(from: selectedURLs)
        }.value

        guard !candidates.isEmpty else {
            throw NSError(
                domain: "DesktopImportRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No importable files were found at the selected paths."]
            )
        }

        let totalCandidateFileCount = candidates.count
        let totalCandidateSizeBytes = candidates.reduce(0) { $0 + $1.sizeBytes }
        let importRun = try await backendClient.createImportRun(
            idToken: idToken,
            ownedSourceID: ownedSourceID,
            sourceSnapshotLabel: sourceSnapshotLabel,
            totalCandidateFileCount: totalCandidateFileCount,
            totalCandidateSizeBytes: totalCandidateSizeBytes
        )

        let plan = try await backendClient.planImportRun(
            idToken: idToken,
            ownedSourceID: ownedSourceID,
            importRunID: importRun.importRunID,
            candidates: candidates.map {
                GuardianImportPlanCandidatePayload(
                    contentHash: $0.contentHash,
                    originalRelativePath: $0.relativePath,
                    sizeBytes: $0.sizeBytes,
                    sourceModifiedAt: $0.sourceModifiedAt
                )
            }
        )

        let missingKeys = Set(plan.missing.map { "\($0.contentHash)|\($0.originalRelativePath)" })
        let missingCandidates = candidates.filter {
            missingKeys.contains("\($0.contentHash)|\($0.relativePath)")
        }

        if missingCandidates.isEmpty {
            _ = try await backendClient.cancelImportRun(
                idToken: idToken,
                ownedSourceID: ownedSourceID,
                importRunID: importRun.importRunID,
                error: "All selected files were already imported."
            )
            return DesktopImportResult(
                userID: currentUser.userID,
                ownedSourceID: ownedSourceID,
                importRunID: importRun.importRunID,
                totalCandidateFileCount: totalCandidateFileCount,
                totalCandidateSizeBytes: totalCandidateSizeBytes,
                missingCandidateFileCount: 0,
                shardCount: 0,
                uploadedShardCount: 0,
                settledStatus: "canceled",
                canonicalFileCount: 0,
                processedTransportShardCount: 0
            )
        }

        let shardDrafts = try await Task.detached(priority: .userInitiated) {
            try SourceImportWorkflow.buildShards(from: missingCandidates)
        }.value

        let createdShards = try await backendClient.createImportShards(
            idToken: idToken,
            ownedSourceID: ownedSourceID,
            importRunID: importRun.importRunID,
            shards: shardDrafts.map {
                GuardianImportShardCreateInputPayload(
                    shardIndex: $0.shardIndex,
                    filename: $0.filename,
                    objectPath: buildTransportObjectPath(
                        userID: currentUser.userID,
                        ownedSourceID: ownedSourceID,
                        importRunID: importRun.importRunID,
                        filename: $0.filename
                    ),
                    contentHash: $0.contentHash,
                    fileCount: $0.fileCount,
                    totalSizeBytes: $0.totalSizeBytes
                )
            }
        )

        let draftsByIndex = Dictionary(uniqueKeysWithValues: shardDrafts.map { ($0.shardIndex, $0) })
        var uploadedShardCount = 0
        for shard in createdShards.sorted(by: { $0.shardIndex < $1.shardIndex }) {
            guard let draft = draftsByIndex[shard.shardIndex] else {
                continue
            }

            _ = try await backendClient.uploadImportShardContent(
                idToken: idToken,
                ownedSourceID: ownedSourceID,
                importRunID: importRun.importRunID,
                importShardID: shard.importShardID,
                payload: draft.tarData
            )
            uploadedShardCount += 1
        }

        _ = try await backendClient.completeImportRun(
            idToken: idToken,
            ownedSourceID: ownedSourceID,
            importRunID: importRun.importRunID
        )

        let settledRun = try await pollImportRunUntilSettled(
            backendClient: backendClient,
            idToken: idToken,
            ownedSourceID: ownedSourceID,
            importRunID: importRun.importRunID,
            timeoutSeconds: pollTimeoutSeconds,
            pollIntervalSeconds: pollIntervalSeconds
        )

        return DesktopImportResult(
            userID: currentUser.userID,
            ownedSourceID: ownedSourceID,
            importRunID: importRun.importRunID,
            totalCandidateFileCount: totalCandidateFileCount,
            totalCandidateSizeBytes: totalCandidateSizeBytes,
            missingCandidateFileCount: missingCandidates.count,
            shardCount: createdShards.count,
            uploadedShardCount: uploadedShardCount,
            settledStatus: settledRun.status,
            canonicalFileCount: settledRun.canonicalFileCount,
            processedTransportShardCount: settledRun.processedTransportShardCount
        )
    }

    private static func pollImportRunUntilSettled(
        backendClient: GuardianBackendClient,
        idToken: String,
        ownedSourceID: String,
        importRunID: String,
        timeoutSeconds: TimeInterval,
        pollIntervalSeconds: TimeInterval
    ) async throws -> GuardianImportRun {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let importRun = try await backendClient.fetchImportRun(
                idToken: idToken,
                ownedSourceID: ownedSourceID,
                importRunID: importRunID
            )

            switch importRun.status {
            case "completed", "failed", "canceled":
                return importRun
            default:
                let nanos = UInt64(max(pollIntervalSeconds, 0.1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
            }
        }

        throw NSError(
            domain: "DesktopImportRunner",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for import run \(importRunID) to settle."]
        )
    }

    private static func buildTransportObjectPath(
        userID: String,
        ownedSourceID: String,
        importRunID: String,
        filename: String
    ) -> String {
        "tmp-imports/\(userID)/\(ownedSourceID)/\(importRunID)/\(filename)"
    }
}
