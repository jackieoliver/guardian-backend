@testable import GuardianDesktopCore
import XCTest

final class ArchivePipelineTests: XCTestCase {
    func testMixedCoverageKeepsRecentTwoMonthTimelinePopulated() {
        let now = Date(timeIntervalSince1970: 1_774_908_800) // 2026-03-25T00:00:00Z
        let calendar = Calendar.guardianUTC
        let lowerBound = calendar.date(byAdding: .day, value: -60, to: calendar.startOfDay(for: now)) ?? now

        let snapshot = ArchiveDataPipeline.snapshot(for: .builtIn(.mixedCoverage), now: now)
        let recentMeasures = snapshot.measures.filter { measure in
            measure.startDate >= lowerBound && measure.startDate <= now
        }

        XCTAssertGreaterThanOrEqual(recentMeasures.count, 30)

        for lane in snapshot.lanes {
            let occupiedMeasures = recentMeasures.filter { lane.coverage(for: $0.id) != .none }
            XCTAssertGreaterThanOrEqual(
                occupiedMeasures.count,
                28,
                "Expected \(lane.name) to stay visibly active across the preview horizon"
            )
        }
    }

    func testPrototypeDatabaseUsesSameProjectionWindowShapeWithoutSyntheticRecords() {
        let now = Date(timeIntervalSince1970: 1_774_908_800) // 2026-03-25T00:00:00Z
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        let currentMeasureLabel = formatter.string(from: calendar.startOfDay(for: now))
        let futureMeasureLabel = formatter.string(
            from: calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now
        )

        let snapshot = ArchiveDataPipeline.snapshot(for: .prototypeDatabase, now: now)

        XCTAssertEqual(snapshot.windowTitle, "Guardian")
        XCTAssertTrue(snapshot.windowSubtitle.contains("Prototype database"))
        XCTAssertTrue(snapshot.measures.contains { $0.shortLabel == currentMeasureLabel })
        XCTAssertTrue(snapshot.measures.contains { $0.shortLabel == futureMeasureLabel })
        XCTAssertTrue(snapshot.lanes.isEmpty)
        XCTAssertTrue(snapshot.inventorySources.isEmpty)
    }

    @MainActor
    func testViewModelSwitchesOnlyDataSourceMode() {
        let model = ArchiveViewModel(
            environment: AppEnvironment(
                mockState: .mixedCoverage,
                uiTesting: true,
                disableAnimations: true
            )
        )

        XCTAssertEqual(model.dataSourceMode, .builtIn(.mixedCoverage))

        model.usePrototypeDatabase()

        XCTAssertEqual(model.dataSourceMode, .prototypeDatabase)
        XCTAssertTrue(model.snapshot.windowSubtitle.contains("Prototype database"))

        model.restoreBuiltInSnapshot()

        XCTAssertEqual(model.dataSourceMode, .builtIn(.mixedCoverage))
        XCTAssertTrue(model.snapshot.windowSubtitle.contains("Built-in archive database"))
    }

    @MainActor
    func testViewModelCanFocusAndAdvanceMeasures() {
        let model = ArchiveViewModel(
            environment: AppEnvironment(
                mockState: .mixedCoverage,
                uiTesting: true,
                disableAnimations: true
            )
        )
        let measures = model.snapshot.measures

        XCTAssertFalse(measures.isEmpty)

        model.focusMeasure(measures[2].id)
        XCTAssertEqual(model.selectedMeasureID, measures[2].id)
        XCTAssertEqual(model.focusedMeasureID, measures[2].id)

        model.focusAdjacentMeasure(offset: 1)
        XCTAssertEqual(model.selectedMeasureID, measures[3].id)

        model.focusAdjacentMeasure(offset: -2)
        XCTAssertEqual(model.selectedMeasureID, measures[1].id)
    }
}
