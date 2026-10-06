import Foundation
import Observation

@Observable
@MainActor
public final class ArchiveViewModel {
    public let environment: AppEnvironment
    public let defaultMockState: MockArchiveState
    public private(set) var builtInMockState: MockArchiveState
    public private(set) var previewOverrideSelection: PreviewOverrideSelection = .off
    public private(set) var dataSourceMode: ArchiveDatabaseSourceMode
    public private(set) var snapshot: ArchiveSnapshot
    public var selectedMeasureID: String?
    private var snapshotSource: any ArchiveSnapshotSource

    public init(environment: AppEnvironment) {
        self.environment = environment
        defaultMockState = environment.mockState
        builtInMockState = environment.mockState
        let initialMode = ArchiveDatabaseSourceMode.builtIn(environment.mockState)
        let initialSource = ArchiveSnapshotSourceFactory.make(for: initialMode)
        dataSourceMode = initialMode
        snapshotSource = initialSource
        snapshot = ArchiveDataPipeline.snapshot(for: initialSource)
        selectedMeasureID = nil
    }

    public var selectedMeasure: PerspectiveMeasure? {
        guard let selectedMeasureID else {
            return nil
        }
        return snapshot.measures.first { $0.id == selectedMeasureID }
    }

    public var currentMeasureID: String? {
        snapshot.measures.first { $0.contains(Date(), calendar: .guardianUTC) }?.id
    }

    public var focusedMeasureID: String? {
        selectedMeasureID ?? currentMeasureID ?? snapshot.measures.last?.id
    }

    public var defaultFocusedMeasureID: String? {
        currentMeasureID ?? snapshot.measures.last?.id
    }

    public var selectedMeasureSources: [PerspectiveLane] {
        guard let selectedMeasureID else {
            return []
        }
        return snapshot.lanes.filter { $0.coverage(for: selectedMeasureID) != .none }
    }

    public func selectMeasure(_ measureID: String) {
        if selectedMeasureID == measureID {
            selectedMeasureID = nil
        } else {
            selectedMeasureID = measureID
        }
    }

    public func focusMeasure(_ measureID: String) {
        guard snapshot.measures.contains(where: { $0.id == measureID }) else {
            return
        }
        selectedMeasureID = measureID
    }

    public func focusAdjacentMeasure(offset: Int) {
        guard let focusedMeasureID,
              let currentIndex = snapshot.measures.firstIndex(where: { $0.id == focusedMeasureID })
        else {
            return
        }

        let targetIndex = min(max(currentIndex + offset, 0), snapshot.measures.count - 1)
        selectedMeasureID = snapshot.measures[targetIndex].id
    }

    public func setDataSourceMode(_ mode: ArchiveDatabaseSourceMode) {
        dataSourceMode = mode
        snapshotSource = ArchiveSnapshotSourceFactory.make(for: mode)
        snapshot = ArchiveDataPipeline.snapshot(for: snapshotSource)

        if let selectedMeasureID,
           snapshot.measures.contains(where: { $0.id == selectedMeasureID }) == false
        {
            self.selectedMeasureID = nil
        }
    }

    public func refresh() {
        setDataSourceMode(dataSourceMode)
    }

    public func restoreBuiltInSnapshot() {
        builtInMockState = defaultMockState
        previewOverrideSelection = .off
        setDataSourceMode(.builtIn(defaultMockState))
    }

    public func useBuiltInPreviewState(_ state: MockArchiveState) {
        builtInMockState = state
        switch state {
        case .mixedCoverage:
            previewOverrideSelection = .mixedCoverage
        case .allDark:
            previewOverrideSelection = .allDark
        case .regeneration:
            previewOverrideSelection = .regeneration
        case .newSource:
            previewOverrideSelection = .newSource
        }
        setDataSourceMode(.builtIn(state))
    }

    public func usePrototypeDatabase() {
        setDataSourceMode(.prototypeDatabase)
    }
}
