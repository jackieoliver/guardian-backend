import Foundation

public enum ArchiveSourceType: String, Sendable {
    case screenpipe
    case gopro
    case phoneCapture
    case djiMic
    case gumstickMic
    case insta360
    case newCamera
}

public enum ArchiveCoverageHint: Sendable {
    case light
    case moderate
    case strong

    var multiplier: Double {
        switch self {
        case .light:
            0.45
        case .moderate:
            0.75
        case .strong:
            1.0
        }
    }
}

public enum ArchiveDatabaseSourceMode: Equatable, Sendable {
    case builtIn(MockArchiveState)
    case prototypeDatabase
}

public struct ArchiveSourceRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let sourceType: ArchiveSourceType
    public let createdAt: Date
    public let isConnected: Bool
    public let detailOverride: String?

    public init(
        id: String,
        name: String,
        sourceType: ArchiveSourceType,
        createdAt: Date,
        isConnected: Bool = false,
        detailOverride: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceType = sourceType
        self.createdAt = createdAt
        self.isConnected = isConnected
        self.detailOverride = detailOverride
    }
}

public struct ArchiveCaptureRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let sourceType: ArchiveSourceType
    public let capturedAtStart: Date
    public let capturedAtEnd: Date
    public let uploadedAt: Date
    public let coverageHint: ArchiveCoverageHint

    public init(
        id: String,
        sourceID: String,
        sourceType: ArchiveSourceType,
        capturedAtStart: Date,
        capturedAtEnd: Date,
        uploadedAt: Date,
        coverageHint: ArchiveCoverageHint
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceType = sourceType
        self.capturedAtStart = capturedAtStart
        self.capturedAtEnd = capturedAtEnd
        self.uploadedAt = uploadedAt
        self.coverageHint = coverageHint
    }
}

public struct ArchiveProjectionInput: Equatable, Sendable {
    public let windowTitle: String
    public let windowSubtitle: String
    public let sources: [ArchiveSourceRecord]
    public let captures: [ArchiveCaptureRecord]
    public let showsInventoryDecision: Bool
    public let regenerationSourceID: String?

    public init(
        windowTitle: String,
        windowSubtitle: String,
        sources: [ArchiveSourceRecord],
        captures: [ArchiveCaptureRecord],
        showsInventoryDecision: Bool = false,
        regenerationSourceID: String? = nil
    ) {
        self.windowTitle = windowTitle
        self.windowSubtitle = windowSubtitle
        self.sources = sources
        self.captures = captures
        self.showsInventoryDecision = showsInventoryDecision
        self.regenerationSourceID = regenerationSourceID
    }
}

public enum ArchiveDataPipeline {
    private static let measureDays = 2
    private static let historyDays = 90
    private static let futureDays = 7
    private static let hour: TimeInterval = 60 * 60
    private static let day: TimeInterval = 24 * hour

    public static func snapshot(
        for source: any ArchiveSnapshotSource,
        now: Date = Date()
    ) -> ArchiveSnapshot {
        let input = source.projectionInput(now: now)
        return snapshot(from: input, now: now)
    }

    public static func snapshot(
        for mode: ArchiveDatabaseSourceMode,
        now: Date = Date()
    ) -> ArchiveSnapshot {
        snapshot(for: ArchiveSnapshotSourceFactory.make(for: mode), now: now)
    }

    public static func snapshot(
        from input: ArchiveProjectionInput,
        now: Date = Date()
    ) -> ArchiveSnapshot {
        let measures = buildMeasures(now: now)
        let lanes = input.sources.map { source in
            PerspectiveLane(
                id: source.id,
                name: source.name,
                coverageByMeasureID: Dictionary(
                    uniqueKeysWithValues: measures.map { measure in
                        (
                            measure.id,
                            coverage(
                                for: source,
                                in: measure,
                                captures: input.captures
                            )
                        )
                    }
                )
            )
        }

        let derivedMeasures = measures.map { measure in
            PerspectiveMeasure(
                id: measure.id,
                rangeLabel: measure.rangeLabel,
                shortLabel: measure.shortLabel,
                note: note(
                    for: measure,
                    lanes: lanes,
                    regenerationSourceID: input.regenerationSourceID,
                    now: now
                ),
                startDate: measure.startDate,
                endDate: measure.endDate
            )
        }

        let inventorySources = input.sources.map { source in
            let lane = lanes.first { $0.id == source.id }
            let recentPreview = lane.map { previewMeasures(for: $0, measures: derivedMeasures) } ?? []
            let recentMeasureCount = recentPreview.filter { $0 != .none }.count
            let vitality = sourceVitality(for: source, captures: input.captures, now: now)
            let detail = source.detailOverride
                ?? "\(vitality.statusText) • \(recentMeasureCount) recent measures"

            return SourceBook(
                id: source.id,
                name: source.name,
                sourceType: source.sourceType,
                vitality: vitality,
                detail: detail,
                isConnected: source.isConnected,
                timelineCoverageByMeasureID: lane?.coverageByMeasureID ?? [:],
                recentCoveragePreview: recentPreview
            )
        }

        return ArchiveSnapshot(
            windowTitle: input.windowTitle,
            windowSubtitle: input.windowSubtitle,
            measures: derivedMeasures,
            lanes: lanes,
            inventorySources: inventorySources,
            showsInventoryDecision: input.showsInventoryDecision,
            regenerationSourceID: input.regenerationSourceID
        )
    }

    public static func projectionInput(
        for mode: ArchiveDatabaseSourceMode,
        now: Date = Date()
    ) -> ArchiveProjectionInput {
        switch mode {
        case let .builtIn(state):
            builtInProjectionInput(for: state, now: now)
        case .prototypeDatabase:
            prototypeProjectionInput(now: now)
        }
    }

    private static func buildMeasures(now: Date) -> [PerspectiveMeasure] {
        let calendar = Calendar.guardianUTC
        let currentDay = calendar.startOfDay(for: now)
        let historyMeasureCount = Int(ceil(Double(historyDays) / Double(measureDays)))
        let futureMeasureCount = Int(ceil(Double(futureDays) / Double(measureDays)))

        guard let start = calendar.date(
            byAdding: .day,
            value: -(historyMeasureCount * measureDays),
            to: currentDay
        ) else {
            return []
        }

        var measures: [PerspectiveMeasure] = []
        for offset in 0 ... (historyMeasureCount + futureMeasureCount) {
            guard let currentStart = calendar.date(byAdding: .day, value: offset * measureDays, to: start),
                  let currentEnd = calendar.date(byAdding: .day, value: 1, to: currentStart)
            else {
                continue
            }

            measures.append(
                PerspectiveMeasure(
                    id: measureID(start: currentStart, end: currentEnd, calendar: calendar),
                    rangeLabel: rangeLabel(start: currentStart, end: currentEnd, calendar: calendar),
                    shortLabel: shortLabel(for: currentStart, calendar: calendar),
                    note: "",
                    startDate: currentStart,
                    endDate: currentEnd
                )
            )
        }

        return measures
    }

    private static func coverage(
        for source: ArchiveSourceRecord,
        in measure: PerspectiveMeasure,
        captures: [ArchiveCaptureRecord]
    ) -> PerspectiveCoverage {
        let relevantCaptures = captures.filter { $0.sourceID == source.id }
        let measureSeconds = measure.endDate.timeIntervalSince(measure.startDate) + 1
        var weightedOverlapSeconds = 0.0

        for capture in relevantCaptures {
            let overlapStart = max(capture.capturedAtStart, measure.startDate)
            let overlapEnd = min(capture.capturedAtEnd, measure.endDate)
            if overlapEnd <= overlapStart {
                continue
            }

            let overlapSeconds = overlapEnd.timeIntervalSince(overlapStart)
            weightedOverlapSeconds += overlapSeconds * capture.coverageHint.multiplier
        }

        let score = min(weightedOverlapSeconds / measureSeconds, 1.0)
        if score >= 0.9 {
            return .full
        }
        if score >= 0.75 {
            return .threeQuarters
        }
        if score >= 0.5 {
            return .twoQuarters
        }
        if score >= 0.25 {
            return .oneQuarter
        }
        return .none
    }

    private static func sourceVitality(
        for source: ArchiveSourceRecord,
        captures: [ArchiveCaptureRecord],
        now: Date
    ) -> SourceVitality {
        let latestCaptureEnd = captures
            .filter { $0.sourceID == source.id }
            .map(\.capturedAtEnd)
            .max() ?? source.createdAt

        let age = now.timeIntervalSince(latestCaptureEnd)
        if age <= 2 * 24 * 60 * 60 {
            return .vital
        }
        if age <= 7 * 24 * 60 * 60 {
            return .fading
        }
        return .dark
    }

    private static func previewMeasures(
        for lane: PerspectiveLane,
        measures: [PerspectiveMeasure],
        count: Int = 6
    ) -> [PerspectiveCoverage] {
        measures.suffix(count).map { lane.coverage(for: $0.id) }
    }

    private static func note(
        for measure: PerspectiveMeasure,
        lanes: [PerspectiveLane],
        regenerationSourceID: String?,
        now: Date
    ) -> String {
        let currentDay = Calendar.guardianUTC.startOfDay(for: now)
        let presentLanes = lanes.filter { $0.coverage(for: measure.id) != .none }

        if presentLanes.isEmpty {
            if measure.startDate > currentDay {
                return "This future measure is open and waiting for incoming material."
            }
            return "No source material is present in this measure yet."
        }

        let names = presentLanes.map(\.name)
        if let regenerationSourceID,
           presentLanes.contains(where: { $0.id == regenerationSourceID })
        {
            return "\(names.joined(separator: ", ")) are helping this measure regenerate."
        }
        if names.count == 1 {
            return "\(names[0]) carries this measure."
        }
        return "\(names.count) sources contribute here: \(names.prefix(3).joined(separator: ", "))."
    }

    static func builtInProjectionInput(
        for state: MockArchiveState,
        now: Date
    ) -> ArchiveProjectionInput {
        let currentMeasureStart = Calendar.guardianUTC.startOfDay(for: now)
        let createdAt = currentMeasureStart.addingTimeInterval(TimeInterval(-40 * 24 * 60 * 60))

        switch state {
        case .mixedCoverage:
            let sources = defaultSources(createdAt: createdAt)
            let captures = capturesForMixedCoverage(currentMeasureStart: currentMeasureStart)
            return ArchiveProjectionInput(
                windowTitle: "Guardian",
                windowSubtitle: builtInSubtitle("archive", now: now),
                sources: sources,
                captures: captures
            )
        case .allDark:
            let sources = defaultSources(
                createdAt: createdAt.addingTimeInterval(TimeInterval(-20 * 24 * 60 * 60))
            )
            return ArchiveProjectionInput(
                windowTitle: "Guardian",
                windowSubtitle: builtInSubtitle("all-dark", now: now),
                sources: sources,
                captures: []
            )
        case .regeneration:
            let sources = [
                ArchiveSourceRecord(
                    id: "gopro",
                    name: "GoPro",
                    sourceType: .gopro,
                    createdAt: createdAt,
                    isConnected: true,
                    detailOverride: "Regenerating now"
                ),
                ArchiveSourceRecord(id: "phoneCapture", name: "Phone Capture", sourceType: .phoneCapture, createdAt: createdAt),
                ArchiveSourceRecord(id: "djiMic", name: "DJI Mic", sourceType: .djiMic, createdAt: createdAt),
                ArchiveSourceRecord(id: "insta360", name: "Insta360", sourceType: .insta360, createdAt: createdAt),
            ]
            let captures = capturesForRegeneration(currentMeasureStart: currentMeasureStart)
            return ArchiveProjectionInput(
                windowTitle: "Guardian",
                windowSubtitle: builtInSubtitle("regeneration", now: now),
                sources: sources,
                captures: captures,
                regenerationSourceID: "gopro"
            )
        case .newSource:
            let sources = [
                ArchiveSourceRecord(
                    id: "gopro",
                    name: "GoPro",
                    sourceType: .gopro,
                    createdAt: createdAt,
                    detailOverride: "Current inventory camera"
                ),
                ArchiveSourceRecord(id: "phoneCapture", name: "Phone Capture", sourceType: .phoneCapture, createdAt: createdAt),
                ArchiveSourceRecord(id: "djiMic", name: "DJI Mic", sourceType: .djiMic, createdAt: createdAt),
                ArchiveSourceRecord(
                    id: "newCamera",
                    name: "New Camera",
                    sourceType: .newCamera,
                    createdAt: currentMeasureStart.addingTimeInterval(TimeInterval(-2 * 24 * 60 * 60)),
                    isConnected: true,
                    detailOverride: "Awaiting inventory choice"
                ),
            ]
            let captures = capturesForNewSource(currentMeasureStart: currentMeasureStart)
            return ArchiveProjectionInput(
                windowTitle: "Guardian",
                windowSubtitle: builtInSubtitle("new-source", now: now),
                sources: sources,
                captures: captures,
                showsInventoryDecision: true
            )
        }
    }

    static func prototypeProjectionInput(now: Date) -> ArchiveProjectionInput {
        return ArchiveProjectionInput(
            windowTitle: "Guardian",
            windowSubtitle: prototypeSubtitle(now: now),
            sources: [],
            captures: []
        )
    }

    private static func defaultSources(createdAt: Date) -> [ArchiveSourceRecord] {
        [
            ArchiveSourceRecord(id: "screenpipe", name: "Screenpipe", sourceType: .screenpipe, createdAt: createdAt),
            ArchiveSourceRecord(id: "gopro", name: "GoPro", sourceType: .gopro, createdAt: createdAt),
            ArchiveSourceRecord(id: "phoneCapture", name: "Phone Capture", sourceType: .phoneCapture, createdAt: createdAt),
            ArchiveSourceRecord(id: "djiMic", name: "DJI Mic", sourceType: .djiMic, createdAt: createdAt),
            ArchiveSourceRecord(id: "gumstickMic", name: "Gumstick Mic", sourceType: .gumstickMic, createdAt: createdAt),
            ArchiveSourceRecord(id: "insta360", name: "Insta360", sourceType: .insta360, createdAt: createdAt),
        ]
    }

    private static func capturesForMixedCoverage(currentMeasureStart: Date) -> [ArchiveCaptureRecord] {
        let screenpipe = captures(
            sourceID: "screenpipe",
            sourceType: .screenpipe,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: offsets(in: -30 ... -28, -26 ... -20, -18 ... -12, -10 ... -5, -3 ... 0),
            moderateOffsets: offsets(in: -27 ... -27, -19 ... -19, -11 ... -11, -4 ... -4),
            lightOffsets: []
        )
        let gopro = captures(
            sourceID: "gopro",
            sourceType: .gopro,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: offsets(in: -30 ... -26, -23 ... -18, -15 ... -10, -7 ... -3, -1 ... 0),
            moderateOffsets: offsets(in: -25 ... -24, -17 ... -16, -9 ... -8, -2 ... -2),
            lightOffsets: []
        )
        let phone = captures(
            sourceID: "phoneCapture",
            sourceType: .phoneCapture,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: offsets(in: -30 ... -29, -27 ... -23, -21 ... -16, -14 ... -9, -7 ... -2, 0 ... 0),
            moderateOffsets: offsets(in: -28 ... -28, -22 ... -22, -15 ... -15, -8 ... -8, -1 ... -1),
            lightOffsets: []
        )
        let dji = captures(
            sourceID: "djiMic",
            sourceType: .djiMic,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: offsets(in: -29 ... -27, -24 ... -22, -18 ... -15, -11 ... -9, -5 ... -3),
            moderateOffsets: offsets(in: -30 ... -30, -26 ... -25, -21 ... -19, -14 ... -12, -8 ... -6, -2 ... 0),
            lightOffsets: []
        )
        let gumstick = captures(
            sourceID: "gumstickMic",
            sourceType: .gumstickMic,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: offsets(in: -28 ... -26, -22 ... -19, -16 ... -13, -9 ... -6, -2 ... 0),
            moderateOffsets: offsets(in: -25 ... -23, -18 ... -17, -12 ... -10, -5 ... -3),
            lightOffsets: []
        )
        let insta = captures(
            sourceID: "insta360",
            sourceType: .insta360,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: offsets(in: -30 ... -28, -24 ... -21, -17 ... -14, -10 ... -7, -2 ... 0),
            moderateOffsets: offsets(in: -27 ... -25, -20 ... -18, -13 ... -11, -6 ... -3),
            lightOffsets: []
        )
        return screenpipe + gopro + phone + dji + gumstick + insta
    }

    private static func capturesForRegeneration(currentMeasureStart: Date) -> [ArchiveCaptureRecord] {
        let gopro = captures(
            sourceID: "gopro",
            sourceType: .gopro,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: [-3, -2, -1, 0],
            moderateOffsets: [-5],
            lightOffsets: [-6]
        )
        let phone = captures(
            sourceID: "phoneCapture",
            sourceType: .phoneCapture,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: [-5, -3, -2],
            moderateOffsets: [-7, -4],
            lightOffsets: [-9]
        )
        let dji = captures(
            sourceID: "djiMic",
            sourceType: .djiMic,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: [-2],
            moderateOffsets: [-4],
            lightOffsets: [-7]
        )
        let insta = captures(
            sourceID: "insta360",
            sourceType: .insta360,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: [-4, -2],
            moderateOffsets: [-6, -3],
            lightOffsets: [-8]
        )
        return gopro + phone + dji + insta
    }

    private static func capturesForNewSource(currentMeasureStart: Date) -> [ArchiveCaptureRecord] {
        let gopro = captures(
            sourceID: "gopro",
            sourceType: .gopro,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: [-8, -4, -2],
            moderateOffsets: [-6],
            lightOffsets: [-10]
        )
        let phone = captures(
            sourceID: "phoneCapture",
            sourceType: .phoneCapture,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: [-5, -2],
            moderateOffsets: [-4, -1],
            lightOffsets: [-8]
        )
        let dji = captures(
            sourceID: "djiMic",
            sourceType: .djiMic,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: [-2],
            moderateOffsets: [-3],
            lightOffsets: [-7]
        )
        let newCamera = captures(
            sourceID: "newCamera",
            sourceType: .newCamera,
            currentMeasureStart: currentMeasureStart,
            strongOffsets: [0],
            moderateOffsets: [-1],
            lightOffsets: []
        )
        return gopro + phone + dji + newCamera
    }

    private static func captures(
        sourceID: String,
        sourceType: ArchiveSourceType,
        currentMeasureStart: Date,
        strongOffsets: [Int],
        moderateOffsets: [Int],
        lightOffsets: [Int]
    ) -> [ArchiveCaptureRecord] {
        let strongCaptures = buildCaptures(
            sourceID: sourceID,
            sourceType: sourceType,
            currentMeasureStart: currentMeasureStart,
            offsets: strongOffsets,
            coverage: .strong,
            durationHours: 46
        )
        let moderateCaptures = buildCaptures(
            sourceID: sourceID,
            sourceType: sourceType,
            currentMeasureStart: currentMeasureStart,
            offsets: moderateOffsets,
            coverage: .moderate,
            durationHours: 24
        )
        let lightCaptures = buildCaptures(
            sourceID: sourceID,
            sourceType: sourceType,
            currentMeasureStart: currentMeasureStart,
            offsets: lightOffsets,
            coverage: .light,
            durationHours: 12
        )

        return strongCaptures + moderateCaptures + lightCaptures
    }

    private static func buildCaptures(
        sourceID: String,
        sourceType: ArchiveSourceType,
        currentMeasureStart: Date,
        offsets: [Int],
        coverage: ArchiveCoverageHint,
        durationHours: Int
    ) -> [ArchiveCaptureRecord] {
        offsets.enumerated().map { index, offset in
            let offsetDays = TimeInterval(offset * measureDays) * day
            let measureStart = currentMeasureStart.addingTimeInterval(offsetDays)
            let start = measureStart.addingTimeInterval(2 * hour)
            let end = start.addingTimeInterval(TimeInterval(durationHours) * hour)
            return ArchiveCaptureRecord(
                id: "\(sourceID)-\(coverage)-\(offset)-\(index)",
                sourceID: sourceID,
                sourceType: sourceType,
                capturedAtStart: start,
                capturedAtEnd: end,
                uploadedAt: end.addingTimeInterval(2 * hour),
                coverageHint: coverage
            )
        }
    }

    private static func offsets(in ranges: ClosedRange<Int>...) -> [Int] {
        ranges.flatMap(Array.init)
    }

    private static func builtInSubtitle(_ name: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .guardianUTC
        formatter.timeZone = formatter.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return "Built-in \(name) database centered on \(formatter.string(from: now)) UTC"
    }

    private static func prototypeSubtitle(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .guardianUTC
        formatter.timeZone = formatter.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return "Prototype database is not wired yet. Showing an empty horizon centered on \(formatter.string(from: now)) UTC."
    }

    private static func shortLabel(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func rangeLabel(start: Date, end: Date, calendar: Calendar) -> String {
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.timeZone = calendar.timeZone
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.dateFormat = "MMM"

        let startMonth = monthFormatter.string(from: start)
        let endMonth = monthFormatter.string(from: end)
        let startDay = calendar.component(.day, from: start)
        let endDay = calendar.component(.day, from: end)

        if calendar.component(.month, from: start) == calendar.component(.month, from: end) {
            return "\(startMonth) \(startDay)-\(endDay)"
        }

        return "\(startMonth) \(startDay)-\(endMonth) \(endDay)"
    }

    private static func measureID(start: Date, end: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"

        let startMonth = formatter.string(from: start).lowercased()
        let endMonth = formatter.string(from: end).lowercased()
        let startDay = String(format: "%02d", calendar.component(.day, from: start))
        let endDay = String(format: "%02d", calendar.component(.day, from: end))

        if startMonth == endMonth {
            return "\(startMonth)\(startDay)_\(endDay)"
        }

        return "\(startMonth)\(startDay)_\(endMonth)\(endDay)"
    }
}
