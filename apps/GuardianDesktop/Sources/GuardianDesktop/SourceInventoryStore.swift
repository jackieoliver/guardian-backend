import Foundation
import GuardianDesktopCore
import Observation

struct SourceCatalogItem: Identifiable, Hashable {
    let id: String
    let displayName: String
    let detail: String
    let archiveSourceType: ArchiveSourceType
}

@Observable
@MainActor
final class SourceInventoryStore {
    private static let savedImportFoldersKey = "GuardianDesktop.savedImportFoldersBySourceID"

    private let beatlesSongNames = [
        "Blackbird",
        "Eleanor Rigby",
        "Here Comes the Sun",
        "Across the Universe",
        "Penny Lane",
        "Something",
        "Dear Prudence",
        "Norwegian Wood",
        "Yesterday",
        "Hey Jude",
    ]
    private let userDefaults: UserDefaults
    private var savedImportFoldersBySourceID: [String: [String]]

    var supportedSourceTypes: [SourceCatalogItem]
    var inventorySources: [SourceBook]
    var isShowingAddSourceDialog = false
    var isShowingManageSourcesDialog = false
    var sourceImportDialogOwnedSourceID: String?

    init(seedInventorySources: [SourceBook], userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        savedImportFoldersBySourceID = Self.loadSavedImportFolders(from: userDefaults)
        supportedSourceTypes = Self.defaultSupportedSourceTypes
        inventorySources = seedInventorySources
    }

    func showAddSourceDialog() {
        isShowingManageSourcesDialog = false
        isShowingAddSourceDialog = true
    }

    func showManageSourcesDialog() {
        isShowingAddSourceDialog = false
        sourceImportDialogOwnedSourceID = nil
        isShowingManageSourcesDialog = true
    }

    func showSourceImportDialog(for sourceID: String) {
        isShowingAddSourceDialog = false
        isShowingManageSourcesDialog = false
        sourceImportDialogOwnedSourceID = sourceID
    }

    func dismissAddSourceDialog() {
        isShowingAddSourceDialog = false
    }

    func dismissManageSourcesDialog() {
        isShowingManageSourcesDialog = false
    }

    func dismissSourceImportDialog() {
        sourceImportDialogOwnedSourceID = nil
    }

    func sourceBook(id: String) -> SourceBook? {
        inventorySources.first { $0.id == id }
    }

    func savedImportFolderPaths(for sourceID: String) -> [String] {
        savedImportFoldersBySourceID[sourceID] ?? []
    }

    func savedImportFolderURLs(for sourceID: String) -> [URL] {
        savedImportFolderPaths(for: sourceID).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func replaceSavedImportFolders(_ urls: [URL], for sourceID: String) {
        setSavedImportFolderPaths(Self.normalizedImportFolderPaths(from: urls), for: sourceID)
    }

    func appendSavedImportFolders(_ urls: [URL], for sourceID: String) {
        let current = savedImportFolderPaths(for: sourceID)
        let combined = current + Self.normalizedImportFolderPaths(from: urls)
        setSavedImportFolderPaths(Self.deduplicatedFolderPaths(combined), for: sourceID)
    }

    func removeSavedImportFolder(path: String, for sourceID: String) {
        let remaining = savedImportFolderPaths(for: sourceID).filter { $0 != path }
        setSavedImportFolderPaths(remaining, for: sourceID)
    }

    func clearSavedImportFolders(for sourceID: String) {
        setSavedImportFolderPaths([], for: sourceID)
    }

    func defaultCustomName(for sourceType: SourceCatalogItem) -> String {
        let matchingCount = inventorySources.filter { $0.sourceType == sourceType.archiveSourceType }.count
        let song = beatlesSongNames[matchingCount % beatlesSongNames.count]
        return "\(sourceType.displayName) \(song)"
    }

    func addInventorySource(_ sourceType: SourceCatalogItem, customName: String) {
        let resolvedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        inventorySources.append(
            SourceBook(
                id: sourceType.id + "-" + String(inventorySources.count + 1),
                name: resolvedName.isEmpty ? defaultCustomName(for: sourceType) : resolvedName,
                sourceType: sourceType.archiveSourceType,
                vitality: .dark,
                detail: "Awaiting first sync",
                isConnected: false,
                timelineCoverageByMeasureID: [:],
                recentCoveragePreview: [.none, .none, .none, .none, .none, .none]
            )
        )
        isShowingAddSourceDialog = false
    }

    func replaceInventorySource(id: String, with sourceType: SourceCatalogItem) {
        guard let index = inventorySources.firstIndex(where: { $0.id == id }) else {
            return
        }
        clearSavedImportFolders(for: id)
        if sourceImportDialogOwnedSourceID == id {
            dismissSourceImportDialog()
        }

        inventorySources[index] = SourceBook(
            id: sourceType.id + "-" + String(index + 1),
            name: sourceType.displayName,
            sourceType: sourceType.archiveSourceType,
            vitality: .fading,
            detail: "Replacement source awaiting first sync",
            isConnected: false,
            timelineCoverageByMeasureID: [:],
            recentCoveragePreview: [.none, .none, .none, .none, .none, .none]
        )
    }

    func removeInventorySource(id: String) {
        inventorySources.removeAll { $0.id == id }
        clearSavedImportFolders(for: id)
        if sourceImportDialogOwnedSourceID == id {
            dismissSourceImportDialog()
        }
    }

    func replaceInventorySources(with inventorySources: [SourceBook]) {
        self.inventorySources = inventorySources
        if let sourceID = sourceImportDialogOwnedSourceID,
           inventorySources.contains(where: { $0.id == sourceID }) == false
        {
            dismissSourceImportDialog()
        }
    }

    func replaceSupportedSourceTypes(with sourceTypes: [SourceCatalogItem]) {
        supportedSourceTypes = sourceTypes.isEmpty ? Self.defaultSupportedSourceTypes : sourceTypes
    }

    func displayedSourceBook(
        for source: SourceBook,
        measures: [PerspectiveMeasure]
    ) -> SourceBook {
        SourceBook(
            id: source.id,
            name: source.name,
            sourceType: source.sourceType,
            vitality: source.vitality,
            detail: source.detail,
            isConnected: source.isConnected,
            timelineCoverageByMeasureID: source.timelineCoverageByMeasureID,
            recentCoveragePreview: normalizedCoveragePreview(for: source, measures: measures)
        )
    }

    func perspectiveLane(
        for source: SourceBook,
        measures: [PerspectiveMeasure]
    ) -> PerspectiveLane {
        if !source.timelineCoverageByMeasureID.isEmpty {
            let coverageByMeasureID = Dictionary(uniqueKeysWithValues: measures.map { measure in
                (measure.id, source.timelineCoverageByMeasureID[measure.id] ?? .none)
            })

            return PerspectiveLane(
                id: source.id,
                name: source.name,
                coverageByMeasureID: coverageByMeasureID
            )
        }

        let normalizedPreview = normalizedCoveragePreview(for: source, measures: measures)
        let trailingMeasures = Array(measures.suffix(normalizedPreview.count))
        var coverageByMeasureID = Dictionary(uniqueKeysWithValues: measures.map { ($0.id, PerspectiveCoverage.none) })

        for (measure, coverage) in zip(trailingMeasures, normalizedPreview) {
            coverageByMeasureID[measure.id] = coverage
        }

        return PerspectiveLane(
            id: source.id,
            name: source.name,
            coverageByMeasureID: coverageByMeasureID
        )
    }

    private func normalizedCoveragePreview(
        for source: SourceBook,
        measures: [PerspectiveMeasure]
    ) -> [PerspectiveCoverage] {
        guard !source.recentCoveragePreview.isEmpty else {
            return Array(repeating: .none, count: min(measures.count, 6))
        }

        let previewCount = min(max(measures.count, 1), source.recentCoveragePreview.count)
        let preview = Array(source.recentCoveragePreview.suffix(previewCount))
        if preview.count == previewCount {
            return preview
        }

        let padding = Array(repeating: PerspectiveCoverage.none, count: previewCount - preview.count)
        return padding + preview
    }

    private func setSavedImportFolderPaths(_ paths: [String], for sourceID: String) {
        let normalizedPaths = Self.deduplicatedFolderPaths(paths)
        if normalizedPaths.isEmpty {
            savedImportFoldersBySourceID.removeValue(forKey: sourceID)
        } else {
            savedImportFoldersBySourceID[sourceID] = normalizedPaths
        }
        persistSavedImportFolders()
    }

    private func persistSavedImportFolders() {
        userDefaults.set(savedImportFoldersBySourceID, forKey: Self.savedImportFoldersKey)
    }

    private static func loadSavedImportFolders(from userDefaults: UserDefaults) -> [String: [String]] {
        (userDefaults.dictionary(forKey: savedImportFoldersKey) as? [String: [String]]) ?? [:]
    }

    private static func normalizedImportFolderPaths(from urls: [URL]) -> [String] {
        deduplicatedFolderPaths(
            urls.map { url in
                url.standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
            }
        )
    }

    private static func deduplicatedFolderPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths where !path.isEmpty {
            if seen.insert(path).inserted {
                result.append(path)
            }
        }
        return result
    }

    static let defaultSupportedSourceTypes: [SourceCatalogItem] = [
        .init(id: "screenpipe", displayName: "Screenpipe", detail: "Desktop capture", archiveSourceType: .screenpipe),
        .init(id: "gopro", displayName: "GoPro", detail: "Action camera", archiveSourceType: .gopro),
        .init(id: "insta360-go-ultra", displayName: "Insta360 Go Ultra", detail: "Compact action camera", archiveSourceType: .insta360),
        .init(id: "dji-mic-3", displayName: "DJI Mic 3", detail: "Wireless mic system", archiveSourceType: .djiMic),
        .init(id: "jelly-phone-capture", displayName: "Jelly Phone Capture", detail: "Phone capture", archiveSourceType: .phoneCapture),
        .init(id: "gumstick-mic", displayName: "Gumstick Mic", detail: "Portable audio recorder", archiveSourceType: .gumstickMic),
    ]
}

extension SourceInventoryStore {
    static func catalogItems(from sourceTypes: [GuardianSourceType]) -> [SourceCatalogItem] {
        let mapped = sourceTypes.compactMap { sourceType -> SourceCatalogItem? in
            guard let archiveSourceType = archiveSourceType(forBackendSourceID: sourceType.sourceID) else {
                return nil
            }
            return SourceCatalogItem(
                id: sourceType.sourceID,
                displayName: sourceType.sourceName,
                detail: catalogDetail(for: archiveSourceType),
                archiveSourceType: archiveSourceType
            )
        }
        return mapped.isEmpty ? defaultSupportedSourceTypes : mapped
    }

    static func sourceBooks(from ownedSources: [GuardianOwnedSource]) -> [SourceBook] {
        ownedSources.map { ownedSource in
            let archiveSourceType = archiveSourceType(forBackendSourceID: ownedSource.sourceID) ?? .newCamera
            return SourceBook(
                id: ownedSource.ownedSourceID,
                name: ownedSource.displayName.isEmpty
                    ? (ownedSource.sourceName ?? catalogDisplayName(forBackendSourceID: ownedSource.sourceID))
                    : ownedSource.displayName,
                sourceType: archiveSourceType,
                vitality: vitality(for: ownedSource),
                detail: detailText(for: ownedSource),
                isConnected: ownedSource.currentImportRunID != nil || ownedSource.lastImportCompletedAt != nil,
                timelineCoverageByMeasureID: [:],
                recentCoveragePreview: [.none, .none, .none, .none, .none, .none]
            )
        }
    }

    private static func catalogDisplayName(forBackendSourceID sourceID: String) -> String {
        defaultSupportedSourceTypes.first(where: { $0.id == sourceID })?.displayName ?? sourceID
    }

    private static func detailText(for ownedSource: GuardianOwnedSource) -> String {
        if ownedSource.currentImportRunID != nil {
            return "Import queued"
        }

        guard let lastImportCompletedAt = ownedSource.lastImportCompletedAt,
              let date = ISO8601DateFormatter().date(from: lastImportCompletedAt)
        else {
            return "Ready to import"
        }
        return "Last import \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private static func vitality(for ownedSource: GuardianOwnedSource) -> SourceVitality {
        if ownedSource.currentImportRunID != nil {
            return .vital
        }
        if ownedSource.lastImportCompletedAt != nil {
            return .fading
        }
        return .dark
    }

    private static func catalogDetail(for archiveSourceType: ArchiveSourceType) -> String {
        switch archiveSourceType {
        case .screenpipe:
            return "Desktop capture"
        case .gopro:
            return "Action camera"
        case .phoneCapture:
            return "Phone capture"
        case .djiMic:
            return "Wireless mic system"
        case .gumstickMic:
            return "Portable audio recorder"
        case .insta360:
            return "Compact action camera"
        case .newCamera:
            return "Capture source"
        }
    }

    private static func archiveSourceType(forBackendSourceID sourceID: String) -> ArchiveSourceType? {
        switch sourceID {
        case "screenpipe":
            return .screenpipe
        case "gopro":
            return .gopro
        case "insta360-go-ultra":
            return .insta360
        case "dji-mic-3":
            return .djiMic
        case "gumstick-mic":
            return .gumstickMic
        case "jelly-phone-capture":
            return .phoneCapture
        default:
            return nil
        }
    }
}
