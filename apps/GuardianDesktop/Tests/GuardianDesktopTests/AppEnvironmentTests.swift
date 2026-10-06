@testable import GuardianDesktopCore
import XCTest

final class AppEnvironmentTests: XCTestCase {
    func testParsesMockStateArgument() {
        let state = AppEnvironment.parseMockState(arguments: ["GuardianDesktop", "--mock-state", "new-source"])

        XCTAssertEqual(state, .newSource)
    }

    func testParsesInitialTabArgument() {
        let tab = AppEnvironment.parseInitialTab(arguments: ["GuardianDesktop", "--initial-tab", "inventory"])

        XCTAssertEqual(tab, "inventory")
    }

    func testParsesInitialJournalSurfaceArgument() {
        let surface = AppEnvironment.parseInitialJournalSurface(arguments: ["GuardianDesktop", "--journal-surface", "terminal"])

        XCTAssertEqual(surface, "terminal")
    }

    func testParsesJournalStartupCommandArgument() {
        let command = AppEnvironment.parseJournalStartupCommand(arguments: ["GuardianDesktop", "--journal-startup-command", "pwd"])

        XCTAssertEqual(command, "pwd")
    }

    func testParsesBackendBaseURLOverrideArgument() {
        let value = AppEnvironment.parseBackendBaseURLOverride(
            arguments: ["GuardianDesktop", "--guardian-api-base-url", "http://127.0.0.1:8000"]
        )

        XCTAssertEqual(value, "http://127.0.0.1:8000")
    }

    func testParsesBearerTokenArgument() {
        let value = AppEnvironment.parseBearerToken(
            arguments: ["GuardianDesktop", "--guardian-bearer-token", "alpha-token"]
        )

        XCTAssertEqual(value, "alpha-token")
    }

    func testParsesAutomationScriptArgument() {
        let value = AppEnvironment.parseAutomationScriptPath(
            arguments: ["GuardianDesktop", "--automation-script", "/tmp/guardian-automation.json"]
        )

        XCTAssertEqual(value, "/tmp/guardian-automation.json")
    }

    func testParsesAutomationResultArgument() {
        let value = AppEnvironment.parseAutomationResultPath(
            arguments: ["GuardianDesktop", "--automation-result-path", "/tmp/guardian-result.json"]
        )

        XCTAssertEqual(value, "/tmp/guardian-result.json")
    }

    func testReturnsNilWhenMockStateMissing() {
        let state = AppEnvironment.parseMockState(arguments: ["GuardianDesktop", "--ui-testing"])

        XCTAssertNil(state)
    }

    func testReturnsNilWhenInitialTabMissing() {
        let tab = AppEnvironment.parseInitialTab(arguments: ["GuardianDesktop", "--ui-testing"])

        XCTAssertNil(tab)
    }

    func testReturnsNilWhenInitialJournalSurfaceMissing() {
        let surface = AppEnvironment.parseInitialJournalSurface(arguments: ["GuardianDesktop", "--ui-testing"])

        XCTAssertNil(surface)
    }

    func testReturnsNilWhenJournalStartupCommandMissing() {
        let command = AppEnvironment.parseJournalStartupCommand(arguments: ["GuardianDesktop", "--ui-testing"])

        XCTAssertNil(command)
    }

    func testReturnsNilWhenBackendBaseURLOverrideMissing() {
        let value = AppEnvironment.parseBackendBaseURLOverride(arguments: ["GuardianDesktop", "--ui-testing"])

        XCTAssertNil(value)
    }

    func testReturnsNilWhenBearerTokenMissing() {
        let value = AppEnvironment.parseBearerToken(arguments: ["GuardianDesktop", "--ui-testing"])

        XCTAssertNil(value)
    }

    func testReturnsNilWhenAutomationScriptMissing() {
        let value = AppEnvironment.parseAutomationScriptPath(arguments: ["GuardianDesktop", "--ui-testing"])

        XCTAssertNil(value)
    }

    func testReturnsNilWhenAutomationResultMissing() {
        let value = AppEnvironment.parseAutomationResultPath(arguments: ["GuardianDesktop", "--ui-testing"])

        XCTAssertNil(value)
    }
}
