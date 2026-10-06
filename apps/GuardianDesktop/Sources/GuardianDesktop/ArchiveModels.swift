// swiftlint:disable file_length
import Foundation

public extension Calendar {
    static var guardianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }
}

public enum SourceVitality: String, CaseIterable, Identifiable, Sendable {
    case vital
    case fading
    case dark

    public var id: String {
        rawValue
    }

    public var statusText: String {
        switch self {
        case .vital:
            "Recently regenerated"
        case .fading:
            "Needs regeneration soon"
        case .dark:
            "Dark for over a week"
        }
    }
}

public enum PerspectiveCoverage: Double, Equatable, Sendable {
    case none = 0
    case oneQuarter = 0.25
    case twoQuarters = 0.5
    case threeQuarters = 0.75
    case full = 0.9

    public var quarterNoteCount: Int {
        switch self {
        case .none:
            0
        case .oneQuarter:
            1
        case .twoQuarters:
            2
        case .threeQuarters:
            3
        case .full:
            0
        }
    }

    public var detailText: String {
        switch self {
        case .none:
            "missing"
        case .oneQuarter:
            "light"
        case .twoQuarters:
            "moderate"
        case .threeQuarters:
            "substantial"
        case .full:
            "strong"
        }
    }
}

public struct PerspectiveMeasure: Identifiable, Equatable, Sendable {
    public let id: String
    public let rangeLabel: String
    public let shortLabel: String
    public let note: String
    public let startDate: Date
    public let endDate: Date

    public init(
        id: String,
        rangeLabel: String,
        shortLabel: String,
        note: String,
        startDate: Date,
        endDate: Date
    ) {
        self.id = id
        self.rangeLabel = rangeLabel
        self.shortLabel = shortLabel
        self.note = note
        self.startDate = startDate
        self.endDate = endDate
    }

    public func contains(_ date: Date, calendar: Calendar = .guardianUTC) -> Bool {
        let start = calendar.startOfDay(for: startDate)
        let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
        return date >= start && date < dayAfterEnd
    }
}

public struct PerspectiveLane: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let coverageByMeasureID: [String: PerspectiveCoverage]

    public init(id: String, name: String, coverageByMeasureID: [String: PerspectiveCoverage]) {
        self.id = id
        self.name = name
        self.coverageByMeasureID = coverageByMeasureID
    }

    public func coverage(for measureID: String) -> PerspectiveCoverage {
        coverageByMeasureID[measureID] ?? .none
    }
}

public struct SourceBook: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let sourceType: ArchiveSourceType
    public let vitality: SourceVitality
    public let detail: String
    public let isConnected: Bool
    public let timelineCoverageByMeasureID: [String: PerspectiveCoverage]
    public let recentCoveragePreview: [PerspectiveCoverage]

    public init(
        id: String,
        name: String,
        sourceType: ArchiveSourceType,
        vitality: SourceVitality,
        detail: String,
        isConnected: Bool,
        timelineCoverageByMeasureID: [String: PerspectiveCoverage] = [:],
        recentCoveragePreview: [PerspectiveCoverage]
    ) {
        self.id = id
        self.name = name
        self.sourceType = sourceType
        self.vitality = vitality
        self.detail = detail
        self.isConnected = isConnected
        self.timelineCoverageByMeasureID = timelineCoverageByMeasureID
        self.recentCoveragePreview = recentCoveragePreview
    }
}

public enum MockArchiveState: String, CaseIterable, Identifiable, Sendable {
    case mixedCoverage = "mixed-coverage"
    case allDark = "all-dark"
    case regeneration
    case newSource = "new-source"

    public var id: String {
        rawValue
    }
}

public enum PreviewOverrideSelection: String, CaseIterable, Identifiable, Sendable {
    case off
    case mixedCoverage = "mixed-coverage"
    case allDark = "all-dark"
    case regeneration
    case newSource = "new-source"

    public var id: String {
        rawValue
    }

    public var mockState: MockArchiveState? {
        switch self {
        case .off:
            return nil
        case .mixedCoverage:
            return .mixedCoverage
        case .allDark:
            return .allDark
        case .regeneration:
            return .regeneration
        case .newSource:
            return .newSource
        }
    }
}

public struct ArchiveSnapshot: Equatable, Sendable {
    public let windowTitle: String
    public let windowSubtitle: String
    public let measures: [PerspectiveMeasure]
    public let lanes: [PerspectiveLane]
    public let inventorySources: [SourceBook]
    public let showsInventoryDecision: Bool
    public let regenerationSourceID: String?

    public init(
        windowTitle: String,
        windowSubtitle: String,
        measures: [PerspectiveMeasure],
        lanes: [PerspectiveLane],
        inventorySources: [SourceBook],
        showsInventoryDecision: Bool,
        regenerationSourceID: String?
    ) {
        self.windowTitle = windowTitle
        self.windowSubtitle = windowSubtitle
        self.measures = measures
        self.lanes = lanes
        self.inventorySources = inventorySources
        self.showsInventoryDecision = showsInventoryDecision
        self.regenerationSourceID = regenerationSourceID
    }
}

public extension ArchiveSnapshot {
    static func make(for state: MockArchiveState) -> ArchiveSnapshot {
        ArchiveDataPipeline.snapshot(for: .builtIn(state))
    }
}

// swiftlint:enable file_length
