import Foundation

public struct AppEnvironment: Equatable {
    public let mockState: MockArchiveState
    public let uiTesting: Bool
    public let disableAnimations: Bool
    public let initialTab: String
    public let initialJournalSurface: String
    public let journalStartupCommand: String?
    public let journalStartupScriptPath: String?
    public let automationScriptPath: String?
    public let automationResultPath: String?
    public let backendBaseURLOverride: String?
    public let bearerToken: String?

    public init(
        mockState: MockArchiveState,
        uiTesting: Bool,
        disableAnimations: Bool,
        initialTab: String = "journal",
        initialJournalSurface: String = "notebook",
        journalStartupCommand: String? = nil,
        journalStartupScriptPath: String? = nil,
        automationScriptPath: String? = nil,
        automationResultPath: String? = nil,
        backendBaseURLOverride: String? = nil,
        bearerToken: String? = nil
    ) {
        self.mockState = mockState
        self.uiTesting = uiTesting
        self.disableAnimations = disableAnimations
        self.initialTab = initialTab
        self.initialJournalSurface = initialJournalSurface
        self.journalStartupCommand = journalStartupCommand
        self.journalStartupScriptPath = journalStartupScriptPath
        self.automationScriptPath = automationScriptPath
        self.automationResultPath = automationResultPath
        self.backendBaseURLOverride = backendBaseURLOverride
        self.bearerToken = bearerToken
    }

    public static func fromProcessInfo(_ processInfo: ProcessInfo = .processInfo) -> AppEnvironment {
        let arguments = processInfo.arguments
        let environment = processInfo.environment
        let mockState = Self.parseMockState(arguments: arguments) ?? .mixedCoverage
        return AppEnvironment(
            mockState: mockState,
            uiTesting: arguments.contains("--ui-testing"),
            disableAnimations: arguments.contains("--disable-animations"),
            initialTab: Self.parseInitialTab(arguments: arguments) ?? "journal",
            initialJournalSurface: Self.parseInitialJournalSurface(arguments: arguments) ?? "notebook",
            journalStartupCommand: Self.parseJournalStartupCommand(arguments: arguments),
            journalStartupScriptPath: Self.parseJournalStartupScriptPath(arguments: arguments),
            automationScriptPath: Self.parseAutomationScriptPath(arguments: arguments),
            automationResultPath: Self.parseAutomationResultPath(arguments: arguments),
            backendBaseURLOverride: Self.parseBackendBaseURLOverride(arguments: arguments)
                ?? Self.optionalValue(environment["GUARDIAN_DESKTOP_API_BASE_URL"]),
            bearerToken: Self.parseBearerToken(arguments: arguments)
                ?? Self.optionalValue(environment["GUARDIAN_DESKTOP_BEARER_TOKEN"])
        )
    }

    public static func parseMockState(arguments: [String]) -> MockArchiveState? {
        guard let index = arguments.firstIndex(of: "--mock-state"),
              index + 1 < arguments.count
        else {
            return nil
        }
        return MockArchiveState(rawValue: arguments[index + 1])
    }

    public static func parseInitialTab(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--initial-tab"),
              index + 1 < arguments.count
        else {
            return nil
        }
        return arguments[index + 1]
    }

    public static func parseInitialJournalSurface(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--journal-surface"),
              index + 1 < arguments.count
        else {
            return nil
        }
        return arguments[index + 1]
    }

    public static func parseJournalStartupCommand(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--journal-startup-command"),
              index + 1 < arguments.count
        else {
            return nil
        }
        return arguments[index + 1]
    }

    public static func parseJournalStartupScriptPath(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--journal-startup-script"),
              index + 1 < arguments.count
        else {
            return nil
        }
        return arguments[index + 1]
    }

    public static func parseAutomationScriptPath(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--automation-script"),
              index + 1 < arguments.count
        else {
            return nil
        }
        return optionalValue(arguments[index + 1])
    }

    public static func parseAutomationResultPath(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--automation-result-path"),
              index + 1 < arguments.count
        else {
            return nil
        }
        return optionalValue(arguments[index + 1])
    }

    public static func parseBackendBaseURLOverride(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--guardian-api-base-url"),
              index + 1 < arguments.count
        else {
            return nil
        }
        return optionalValue(arguments[index + 1])
    }

    public static func parseBearerToken(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--guardian-bearer-token"),
              index + 1 < arguments.count
        else {
            return nil
        }
        return optionalValue(arguments[index + 1])
    }

    private static func optionalValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
