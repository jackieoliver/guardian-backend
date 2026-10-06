import GoogleSignIn
import GuardianDesktopCore
import SwiftUI

private struct JournalStartupAction: Decodable {
    let action: String
    let command: String?
    let title: String?
    let index: Int?
    let milliseconds: Int?
}

private struct AppAutomationAction: Decodable {
    let action: String
    let sourceID: String?
    let displayName: String?
    let paths: [String]?
    let command: String?
    let title: String?
    let index: Int?
    let timeoutSeconds: Int?
    let milliseconds: Int?
}

private struct AppAutomationResult: Encodable {
    let success: Bool
    let message: String
    let currentUserEmail: String?
    let sourceCount: Int
    let importQueueCount: Int
    let journalHasSeenShellPrompt: Bool
    let journalSelectedEntryTitle: String?
    let journalRecentLines: [String]
    let recentActivity: [String]
}

@main
struct GuardianDesktopApp: App {
    @State private var authSession: GoogleAuthSession
    @State private var model: ArchiveViewModel
    @State private var inventoryStore: SourceInventoryStore
    @State private var journalWorkspace: JournalWorkspace
    @State private var journalSessionController: JournalSessionController
    @State private var didRunStartupCommand = false
    @State private var didRunStartupScript = false
    @State private var didRunAutomationScript = false
    private let appEnvironment: AppEnvironment

    init() {
        MusicNotation.registerFont()
        let appEnvironment = AppEnvironment.fromProcessInfo()
        let authSession = GoogleAuthSession(
            backendBaseURLOverride: appEnvironment.backendBaseURLOverride,
            bearerToken: appEnvironment.bearerToken
        )
        let model = ArchiveViewModel(environment: appEnvironment)
        let journalWorkspace = JournalWorkspace()
        self.appEnvironment = appEnvironment
        _authSession = State(initialValue: authSession)
        _model = State(initialValue: model)
        _inventoryStore = State(initialValue: SourceInventoryStore(seedInventorySources: model.snapshot.inventorySources))
        _journalWorkspace = State(initialValue: journalWorkspace)
        _journalSessionController = State(
            initialValue: JournalSessionController(
                journalWorkspace: journalWorkspace,
                authSession: authSession
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                model: model,
                inventoryStore: inventoryStore,
                authSession: authSession,
                journalWorkspace: journalWorkspace,
                journalSessionController: journalSessionController
            )
            .onOpenURL { url in
                _ = GIDSignIn.sharedInstance.handle(url)
            }
            .task {
                authSession.startBackendMonitoringIfNeeded()
                authSession.restorePreviousSignInIfNeeded()
                if let startupScriptPath = appEnvironment.journalStartupScriptPath,
                   didRunStartupScript == false
                {
                    didRunStartupScript = true
                    await runJournalStartupScript(path: startupScriptPath)
                }
                if let startupCommand = appEnvironment.journalStartupCommand,
                   didRunStartupCommand == false
                {
                    didRunStartupCommand = true
                    journalWorkspace.setDraftText(startupCommand)
                    for _ in 0 ..< 40 {
                        if journalSessionController.hasSeenShellPrompt {
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    journalSessionController.submitSelectedDraft()
                }
                if let automationScriptPath = appEnvironment.automationScriptPath,
                   didRunAutomationScript == false
                {
                    didRunAutomationScript = true
                    await runAutomationScript(path: automationScriptPath)
                }
            }
        }
        .windowResizability(.automatic)
        .defaultSize(width: 1280, height: 900)
        .defaultPosition(.center)
        .commands {
            SourceMenuCommands(inventoryStore: inventoryStore)
            AuthMenuCommands(authSession: authSession)
            HelpMenuCommands(model: model, inventoryStore: inventoryStore, authSession: authSession)
        }
    }

    private func runJournalStartupScript(path: String) async {
        guard
            let data = FileManager.default.contents(atPath: path),
            let actions = try? JSONDecoder().decode([JournalStartupAction].self, from: data)
        else {
            return
        }

        for action in actions {
            switch action.action {
            case "createEntry":
                journalWorkspace.createEntry()
                if let title = action.title, !title.isEmpty {
                    journalWorkspace.renameSelectedEntry(to: title)
                }
                journalSessionController.activateForSelectedEntry()
            case "selectEntry":
                let index = action.index ?? 0
                guard journalWorkspace.entries.indices.contains(index) else {
                    continue
                }
                journalWorkspace.selectEntry(journalWorkspace.entries[index].id)
                journalSessionController.activateForSelectedEntry()
            case "wait":
                let milliseconds = max(action.milliseconds ?? 300, 0)
                try? await Task.sleep(for: .milliseconds(milliseconds))
            case "waitForPrompt":
                for _ in 0 ..< 100 {
                    if journalSessionController.hasSeenShellPrompt {
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            case "submit":
                if let command = action.command {
                    journalWorkspace.setDraftText(command)
                    journalSessionController.submitSelectedDraft()
                }
            default:
                continue
            }
        }
    }

    @MainActor
    private func runAutomationScript(path: String) async {
        let resultPath = appEnvironment.automationResultPath
        do {
            guard
                let data = FileManager.default.contents(atPath: path),
                let actions = try? JSONDecoder().decode([AppAutomationAction].self, from: data)
            else {
                throw NSError(
                    domain: "GuardianDesktopApp",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not decode automation script."]
                )
            }

            for action in actions {
                switch action.action {
                case "waitForAuth":
                    try await waitForAuthentication(timeoutSeconds: action.timeoutSeconds ?? 30)
                case "refreshState":
                    authSession.refreshCurrentState(
                        inventoryStore: inventoryStore,
                        fallbackInventorySources: model.snapshot.inventorySources
                    )
                    try await Task.sleep(for: .seconds(2))
                case "addSource":
                    guard let sourceID = action.sourceID,
                          let displayName = action.displayName
                    else {
                        throw NSError(
                            domain: "GuardianDesktopApp",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "addSource requires sourceID and displayName."]
                        )
                    }
                    _ = try await authSession.addInventorySourceForAutomation(
                        sourceID: sourceID,
                        displayName: displayName,
                        inventoryStore: inventoryStore,
                        fallbackInventorySources: model.snapshot.inventorySources
                    )
                case "importSource":
                    guard let displayName = action.displayName,
                          let paths = action.paths
                    else {
                        throw NSError(
                            domain: "GuardianDesktopApp",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "importSource requires displayName and paths."]
                        )
                    }
                    guard let ownedSourceID = try await waitForOwnedSourceID(
                        named: displayName,
                        timeoutSeconds: action.timeoutSeconds ?? 30
                    ) else {
                        throw NSError(
                            domain: "GuardianDesktopApp",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "Could not find owned source named \(displayName)."]
                        )
                    }
                    try await authSession.importSourceFilesForAutomation(
                        ownedSourceID: ownedSourceID,
                        selectedURLs: paths.map { URL(fileURLWithPath: $0) },
                        inventoryStore: inventoryStore,
                        fallbackInventorySources: model.snapshot.inventorySources
                    )
                case "wait":
                    try await Task.sleep(for: .milliseconds(action.milliseconds ?? 500))
                case "journalCreateEntry":
                    journalWorkspace.createEntry()
                    if let title = action.title, !title.isEmpty {
                        journalWorkspace.renameSelectedEntry(to: title)
                    }
                    journalSessionController.activateForSelectedEntry()
                case "journalSelectEntry":
                    let index = action.index ?? 0
                    guard journalWorkspace.entries.indices.contains(index) else {
                        throw NSError(
                            domain: "GuardianDesktopApp",
                            code: 6,
                            userInfo: [NSLocalizedDescriptionKey: "journalSelectEntry index \(index) is out of range."]
                        )
                    }
                    journalWorkspace.selectEntry(journalWorkspace.entries[index].id)
                    journalSessionController.activateForSelectedEntry()
                case "journalWaitForPrompt":
                    try await waitForJournalPrompt(timeoutSeconds: action.timeoutSeconds ?? 60)
                case "journalSubmit":
                    guard let command = action.command, !command.isEmpty else {
                        throw NSError(
                            domain: "GuardianDesktopApp",
                            code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "journalSubmit requires command."]
                        )
                    }
                    journalWorkspace.setDraftText(command)
                    journalSessionController.submitSelectedDraft()
                default:
                    continue
                }
            }

            try writeAutomationResult(
                makeAutomationResult(success: true, message: "Automation script completed."),
                to: resultPath
            )
        } catch {
            authSession.recordAutomationFailure(error.localizedDescription)
            try? writeAutomationResult(
                makeAutomationResult(success: false, message: error.localizedDescription),
                to: resultPath
            )
        }
    }

    @MainActor
    private func waitForAuthentication(timeoutSeconds: Int) async throws {
        let timeout = max(timeoutSeconds, 1)
        for _ in 0 ..< (timeout * 10) {
            if authSession.currentUser != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(
            domain: "GuardianDesktopApp",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for authenticated user."]
        )
    }

    @MainActor
    private func waitForJournalPrompt(timeoutSeconds: Int) async throws {
        let timeout = max(timeoutSeconds, 1)
        for _ in 0 ..< (timeout * 10) {
            if journalSessionController.hasSeenShellPrompt {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(
            domain: "GuardianDesktopApp",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Journal shell prompt."]
        )
    }

    @MainActor
    private func waitForOwnedSourceID(named displayName: String, timeoutSeconds: Int) async throws -> String? {
        let timeout = max(timeoutSeconds, 1)
        for _ in 0 ..< (timeout * 5) {
            if let book = inventoryStore.inventorySources.first(where: { $0.name == displayName }) {
                return book.id
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    @MainActor
    private func makeAutomationResult(success: Bool, message: String) -> AppAutomationResult {
        AppAutomationResult(
            success: success,
            message: message,
            currentUserEmail: authSession.currentUser?.email,
            sourceCount: inventoryStore.inventorySources.count,
            importQueueCount: authSession.currentImportQueue.count,
            journalHasSeenShellPrompt: journalSessionController.hasSeenShellPrompt,
            journalSelectedEntryTitle: journalWorkspace.selectedEntry?.title,
            journalRecentLines: journalWorkspace.selectedEntry?.lines.suffix(8).map(\.text) ?? [],
            recentActivity: authSession.recentActivity.prefix(12).map(\.message)
        )
    }

    private func writeAutomationResult(_ result: AppAutomationResult, to path: String?) throws {
        guard let path, !path.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: url, options: .atomic)
    }
}
