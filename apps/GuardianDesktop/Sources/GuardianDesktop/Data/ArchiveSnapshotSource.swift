import Foundation

public protocol ArchiveSnapshotSource {
    var mode: ArchiveDatabaseSourceMode { get }
    func projectionInput(now: Date) -> ArchiveProjectionInput
}

public struct BuiltInMockArchiveSource: ArchiveSnapshotSource {
    public let state: MockArchiveState

    public var mode: ArchiveDatabaseSourceMode {
        .builtIn(state)
    }

    public init(state: MockArchiveState) {
        self.state = state
    }

    public func projectionInput(now: Date) -> ArchiveProjectionInput {
        ArchiveDataPipeline.builtInProjectionInput(for: state, now: now)
    }
}

public struct PrototypeArchiveSource: ArchiveSnapshotSource {
    public let mode: ArchiveDatabaseSourceMode = .prototypeDatabase

    public init() {}

    public func projectionInput(now: Date) -> ArchiveProjectionInput {
        ArchiveDataPipeline.prototypeProjectionInput(now: now)
    }
}

public enum ArchiveSnapshotSourceFactory {
    public static func make(for mode: ArchiveDatabaseSourceMode) -> any ArchiveSnapshotSource {
        switch mode {
        case let .builtIn(state):
            BuiltInMockArchiveSource(state: state)
        case .prototypeDatabase:
            PrototypeArchiveSource()
        }
    }
}
