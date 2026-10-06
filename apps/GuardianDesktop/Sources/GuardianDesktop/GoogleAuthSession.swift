import AppKit
import Foundation
import GoogleSignIn
import GuardianDesktopCore
import Observation

@MainActor
@Observable
final class GoogleAuthSession {
    struct ActivityEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let isError: Bool

        var timeLabel: String {
            timestamp.formatted(date: .omitted, time: .shortened)
        }
    }

    struct SignedInUser: Equatable {
        let userID: String
        let email: String?
        let displayName: String?
    }

    private enum BackendStatusValue: String {
        case online = "Online"
        case offline = "Offline"
    }

    private let backendClient: GuardianBackendClient
    private let bearerToken: String?
    private var hasAttemptedRestore = false
    private var backendMonitorTask: Task<Void, Never>?
    private var bearerTokenRejected = false
    private var suppressLastErrorInSignedOutPreview = false

    private(set) var currentUser: SignedInUser?
    private(set) var backendUser: GuardianBackendUser?
    private(set) var appUserProfile: GuardianAppUserProfile?
    private(set) var currentVMAccess: GuardianVMAccess?
    private(set) var currentImportQueue: [GuardianImportQueueItem] = []
    private(set) var backendStatus = BackendStatusValue.offline.rawValue
    private(set) var lastError: String?
    private(set) var recentActivity: [ActivityEntry] = []
    private(set) var isWorking = false

    var canSignIn: Bool {
        currentUser == nil && !isWorking
    }

    var canSignOut: Bool {
        currentUser != nil && !isWorking
    }

    var usesBearerTokenSignIn: Bool {
        bearerToken != nil && !bearerTokenRejected
    }

    var signInActionTitle: String {
        usesBearerTokenSignIn ? "Sign In with Access Token" : "Sign In with Google…"
    }

    var visibleErrorMessage: String? {
        if currentUser == nil, suppressLastErrorInSignedOutPreview {
            return nil
        }
        return lastError
    }

    var isShowingPreviewExperience: Bool {
        currentUser == nil
    }

    init(
        backendBaseURLOverride: String? = nil,
        bearerToken: String? = nil
    ) {
        backendClient = GuardianBackendClient(baseURLOverride: backendBaseURLOverride)
        let trimmedToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bearerToken = (trimmedToken?.isEmpty == false) ? trimmedToken : nil
        GIDSignIn.sharedInstance.configuration = googleConfiguration()
    }

    func startBackendMonitoringIfNeeded() {
        guard backendMonitorTask == nil else {
            return
        }
        backendMonitorTask = Task { [weak self] in
            guard let self else {
                return
            }
            await runBackendMonitorLoop()
        }
    }

    func restorePreviousSignInIfNeeded() {
        guard !hasAttemptedRestore else {
            return
        }
        hasAttemptedRestore = true

        if let bearerToken, !bearerTokenRejected {
            isWorking = true
            clearErrorState()
            Task {
                await signInWithBearerToken(
                    bearerToken,
                    activityLabel: "Restored access token sign-in"
                )
                isWorking = false
            }
            return
        }

        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else {
            return
        }

        isWorking = true
        clearErrorState()
        Task {
            do {
                let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                try await finishSignIn(with: user)
                recordActivity("Restored previous Google sign-in")
            } catch {
                clearAuthenticatedState()
                setLastError(
                    error.localizedDescription,
                    suppressInSignedOutPreview: true
                )
                recordActivity(
                    "Previous sign-in could not be restored. Showing preview data instead.",
                    isError: true
                )
            }
            isWorking = false
        }
    }

    func signIn() {
        if let bearerToken, !bearerTokenRejected {
            isWorking = true
            clearErrorState()
            Task {
                await signInWithBearerToken(
                    bearerToken,
                    activityLabel: "Signed in with access token"
                )
                isWorking = false
            }
            return
        }

        guard let configuration = googleConfiguration() else {
            let message = "Missing Google Sign-In configuration in Info.plist."
            setLastError(message)
            recordActivity(message, isError: true)
            return
        }
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else {
            let message = "No active window is available for Google Sign-In."
            setLastError(message)
            recordActivity(message, isError: true)
            return
        }

        GIDSignIn.sharedInstance.configuration = configuration
        isWorking = true
        clearErrorState()
        Task {
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
                try await finishSignIn(with: result.user)
                recordActivity("Signed in as \(result.user.profile?.email ?? "Google user")")
            } catch {
                clearAuthenticatedState()
                setLastError(error.localizedDescription)
                recordActivity(error.localizedDescription, isError: true)
            }
            isWorking = false
        }
    }

    func signOut() {
        let signedOutLabel = currentUser?.email ?? currentUser?.displayName ?? "current user"
        if !usesBearerTokenSignIn {
            GIDSignIn.sharedInstance.signOut()
        }
        clearAuthenticatedState()
        recordActivity("Signed out \(signedOutLabel)")
    }

    func syncInventory(
        inventoryStore: SourceInventoryStore,
        fallbackInventorySources: [SourceBook]
    ) {
        guard currentUser != nil else {
            inventoryStore.replaceSupportedSourceTypes(with: SourceInventoryStore.defaultSupportedSourceTypes)
            inventoryStore.replaceInventorySources(with: fallbackInventorySources)
            currentImportQueue = []
            return
        }

        Task {
            do {
                try await refreshInventory(
                    inventoryStore: inventoryStore,
                    fallbackInventorySources: fallbackInventorySources
                )
            } catch {
                markBackendOffline()
                setLastError(error.localizedDescription)
                recordActivity(error.localizedDescription, isError: true)
            }
        }
    }

    func refreshCurrentState(
        inventoryStore: SourceInventoryStore,
        fallbackInventorySources: [SourceBook]
    ) {
        guard currentUser != nil else {
            inventoryStore.replaceSupportedSourceTypes(with: SourceInventoryStore.defaultSupportedSourceTypes)
            inventoryStore.replaceInventorySources(with: fallbackInventorySources)
            currentImportQueue = []
            clearErrorState()
            recordActivity("Reloaded signed-out preview data")
            return
        }

        isWorking = true
        clearErrorState()
        Task {
            defer { isWorking = false }
            do {
                let token = try await currentAuthTokenString()
                try await loadAuthenticatedState(idToken: token, fallbackUser: currentUser)
                try await refreshInventory(
                    inventoryStore: inventoryStore,
                    fallbackInventorySources: fallbackInventorySources
                )
                recordActivity("Refreshed current backend state")
            } catch {
                markBackendOffline()
                setLastError(error.localizedDescription)
                recordActivity(error.localizedDescription, isError: true)
            }
        }
    }

    @discardableResult
    func refreshVMAccessState(
        recordActivityOnChange: Bool = true,
        clearVisibleError: Bool = false
    ) async throws -> GuardianVMAccess {
        let previousVMAccess = currentVMAccess
        let idToken = try await currentAuthTokenString()
        let refreshedVMAccess = try await fetchPreparedVMAccess(idToken: idToken)
        currentVMAccess = refreshedVMAccess
        markBackendOnline()
        if clearVisibleError {
            clearErrorState()
        }
        if recordActivityOnChange, previousVMAccess != refreshedVMAccess {
            recordActivity(vmAccessActivityMessage(for: refreshedVMAccess))
        }
        return refreshedVMAccess
    }

    func addInventorySource(
        _ sourceType: SourceCatalogItem,
        customName: String,
        inventoryStore: SourceInventoryStore
    ) {
        guard currentUser != nil else {
            inventoryStore.addInventorySource(sourceType, customName: customName)
            return
        }

        let resolvedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = resolvedName.isEmpty ? inventoryStore.defaultCustomName(for: sourceType) : resolvedName

        isWorking = true
        clearErrorState()
        Task {
            defer { isWorking = false }
            do {
                _ = try await createOwnedSourceLive(
                    sourceID: sourceType.id,
                    displayName: displayName,
                    inventoryStore: inventoryStore,
                    fallbackInventorySources: inventoryStore.inventorySources
                )
            } catch {
                markBackendOffline()
                setLastError(error.localizedDescription)
                recordActivity(error.localizedDescription, isError: true)
            }
        }
    }

    func removeInventorySource(
        id: String,
        inventoryStore: SourceInventoryStore,
        fallbackInventorySources: [SourceBook]
    ) {
        guard currentUser != nil else {
            inventoryStore.removeInventorySource(id: id)
            return
        }

        isWorking = true
        clearErrorState()
        Task {
            defer { isWorking = false }
            do {
                let idToken = try await currentAuthTokenString()
                try await backendClient.deleteOwnedSource(idToken: idToken, ownedSourceID: id)
                recordActivity("Removed source")
                try await refreshInventory(
                    inventoryStore: inventoryStore,
                    fallbackInventorySources: fallbackInventorySources
                )
            } catch {
                markBackendOffline()
                setLastError(error.localizedDescription)
                recordActivity(error.localizedDescription, isError: true)
            }
        }
    }

    func replaceInventorySource(
        id: String,
        with sourceType: SourceCatalogItem,
        inventoryStore: SourceInventoryStore,
        fallbackInventorySources: [SourceBook]
    ) {
        guard currentUser != nil else {
            inventoryStore.replaceInventorySource(id: id, with: sourceType)
            return
        }

        isWorking = true
        clearErrorState()
        Task {
            defer { isWorking = false }
            do {
                let idToken = try await currentAuthTokenString()
                try await backendClient.deleteOwnedSource(idToken: idToken, ownedSourceID: id)
                _ = try await backendClient.createOwnedSource(
                    idToken: idToken,
                    sourceID: sourceType.id,
                    displayName: sourceType.displayName
                )
                recordActivity("Replaced source with \(sourceType.displayName)")
                try await refreshInventory(
                    inventoryStore: inventoryStore,
                    fallbackInventorySources: fallbackInventorySources
                )
            } catch {
                markBackendOffline()
                setLastError(error.localizedDescription)
                recordActivity(error.localizedDescription, isError: true)
            }
        }
    }

    func loadImportRuns(for ownedSourceID: String) async throws -> [GuardianImportRun] {
        let idToken = try await currentAuthTokenString()
        return try await backendClient.listImportRuns(
            idToken: idToken,
            ownedSourceID: ownedSourceID
        )
    }

    func cancelImportRun(
        ownedSourceID: String,
        importRunID: String,
        inventoryStore: SourceInventoryStore,
        fallbackInventorySources: [SourceBook]
    ) {
        guard currentUser != nil else {
            return
        }

        isWorking = true
        clearErrorState()
        Task {
            defer { isWorking = false }
            do {
                let idToken = try await currentAuthTokenString()
                _ = try await backendClient.cancelImportRun(
                    idToken: idToken,
                    ownedSourceID: ownedSourceID,
                    importRunID: importRunID
                )
                recordActivity("Canceled import run")
                try await refreshInventory(
                    inventoryStore: inventoryStore,
                    fallbackInventorySources: fallbackInventorySources
                )
            } catch {
                markBackendOffline()
                setLastError(error.localizedDescription)
                recordActivity(error.localizedDescription, isError: true)
            }
        }
    }

    func importSourceFiles(
        ownedSourceID: String,
        selectedURLs: [URL],
        inventoryStore: SourceInventoryStore,
        fallbackInventorySources: [SourceBook]
    ) {
        guard currentUser != nil else {
            return
        }

        isWorking = true
        clearErrorState()
        Task {
            defer { isWorking = false }
            do {
                try await importSourceFilesForAutomation(
                    ownedSourceID: ownedSourceID,
                    selectedURLs: selectedURLs,
                    inventoryStore: inventoryStore,
                    fallbackInventorySources: fallbackInventorySources
                )
            } catch {
                markBackendOffline()
                setLastError(error.localizedDescription)
                recordActivity(error.localizedDescription, isError: true)
            }
        }
    }

    func addInventorySourceForAutomation(
        sourceID: String,
        displayName: String,
        inventoryStore: SourceInventoryStore,
        fallbackInventorySources: [SourceBook]
    ) async throws -> GuardianOwnedSource {
        try await createOwnedSourceLive(
            sourceID: sourceID,
            displayName: displayName,
            inventoryStore: inventoryStore,
            fallbackInventorySources: fallbackInventorySources
        )
    }

    func importSourceFilesForAutomation(
        ownedSourceID: String,
        selectedURLs: [URL],
        inventoryStore: SourceInventoryStore,
        fallbackInventorySources: [SourceBook]
    ) async throws {
        let candidates = try await Task.detached(priority: .userInitiated) {
            try SourceImportWorkflow.collectCandidates(from: selectedURLs)
        }.value

        guard !candidates.isEmpty else {
            recordActivity("No importable files were selected.")
            return
        }

        let totalCandidateFileCount = candidates.count
        let totalCandidateSizeBytes = candidates.reduce(0) { $0 + $1.sizeBytes }
        let idToken = try await currentAuthTokenString()
        let importRun = try await backendClient.createImportRun(
            idToken: idToken,
            ownedSourceID: ownedSourceID,
            sourceSnapshotLabel: "desktop-import",
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

        let missingKeys = Set(
            plan.missing.map { "\($0.contentHash)|\($0.originalRelativePath)" }
        )
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
            try await refreshInventory(
                inventoryStore: inventoryStore,
                fallbackInventorySources: fallbackInventorySources
            )
            recordActivity("All selected files were already present for this source.")
            return
        }

        let shardDrafts = try await Task.detached(priority: .userInitiated) {
            try SourceImportWorkflow.buildShards(from: missingCandidates)
        }.value

        guard shardDrafts.isEmpty == false else {
            _ = try await backendClient.cancelImportRun(
                idToken: idToken,
                ownedSourceID: ownedSourceID,
                importRunID: importRun.importRunID,
                error: "Selected files disappeared before Guardian could package them."
            )
            try await refreshInventory(
                inventoryStore: inventoryStore,
                fallbackInventorySources: fallbackInventorySources
            )
            recordActivity("Selected files changed while scanning. Try the upload again.")
            return
        }

        let createdShards = try await backendClient.createImportShards(
            idToken: idToken,
            ownedSourceID: ownedSourceID,
            importRunID: importRun.importRunID,
            shards: shardDrafts.map {
                GuardianImportShardCreateInputPayload(
                    shardIndex: $0.shardIndex,
                    filename: $0.filename,
                    objectPath: buildTransportObjectPath(
                        userID: currentUser?.userID ?? backendUser?.userID ?? "guardian-desktop",
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

        try await refreshInventory(
            inventoryStore: inventoryStore,
            fallbackInventorySources: fallbackInventorySources
        )

        let draftsByIndex = Dictionary(uniqueKeysWithValues: shardDrafts.map { ($0.shardIndex, $0) })
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
            try await refreshInventory(
                inventoryStore: inventoryStore,
                fallbackInventorySources: fallbackInventorySources
            )
        }

        _ = try await backendClient.completeImportRun(
            idToken: idToken,
            ownedSourceID: ownedSourceID,
            importRunID: importRun.importRunID
        )
        recordActivity(
            "Started import of \(missingCandidates.count) new file(s) across \(createdShards.count) shard(s)."
        )
        try await refreshInventory(
            inventoryStore: inventoryStore,
            fallbackInventorySources: fallbackInventorySources
        )
        try await pollImportRunUntilSettled(
            idToken: idToken,
            ownedSourceID: ownedSourceID,
            importRunID: importRun.importRunID,
            inventoryStore: inventoryStore,
            fallbackInventorySources: fallbackInventorySources
        )
    }

    func recordAutomationFailure(_ message: String) {
        setLastError(message)
        recordActivity("Automation failed: \(message)", isError: true)
    }

    private func refreshInventory(
        inventoryStore: SourceInventoryStore,
        fallbackInventorySources: [SourceBook]
    ) async throws {
        let idToken = try await currentAuthTokenString()
        let sourceTypes = try await backendClient.listSourceTypes()
        let ownedSources = try await backendClient.listOwnedSources(idToken: idToken)
        let importQueue = try await backendClient.listImportQueue(idToken: idToken)
        inventoryStore.replaceSupportedSourceTypes(with: SourceInventoryStore.catalogItems(from: sourceTypes))
        inventoryStore.replaceInventorySources(with: SourceInventoryStore.sourceBooks(from: ownedSources))
        currentImportQueue = importQueue
        markBackendOnline()
        clearErrorState()
        recordActivity("Loaded \(ownedSources.count) source(s) and \(importQueue.count) queued import(s)")

        if ownedSources.isEmpty, fallbackInventorySources.isEmpty == false {
            recordActivity("No live sources yet. Mock coverage remains available in preview mode.")
        }
    }

    private func signInWithBearerToken(
        _ token: String,
        activityLabel: String
    ) async {
        do {
            try await finishSignIn(usingBearerToken: token)
            bearerTokenRejected = false
            recordActivity(activityLabel)
            clearErrorState()
        } catch {
            clearAuthenticatedState(resetError: false)
            if Self.isRejectedBearerTokenError(error) {
                bearerTokenRejected = true
                setLastError(error.localizedDescription, suppressInSignedOutPreview: true)
                recordActivity(
                    "Configured access token was rejected. Showing preview data instead.",
                    isError: true
                )
            } else {
                setLastError(error.localizedDescription)
                recordActivity(error.localizedDescription, isError: true)
            }
        }
    }

    private func finishSignIn(with user: GIDGoogleUser) async throws {
        let idToken = try await refreshedIDTokenString(from: user)
        try await loadAuthenticatedState(
            idToken: idToken,
            fallbackUser: Self.makeSignedInUser(from: user)
        )
    }

    private func finishSignIn(usingBearerToken token: String) async throws {
        try await loadAuthenticatedState(
            idToken: token,
            fallbackUser: nil
        )
    }

    private func loadAuthenticatedState(
        idToken: String,
        fallbackUser: SignedInUser?
    ) async throws {
        let backendUser = try await backendClient.fetchCurrentUser(idToken: idToken)
        self.backendUser = backendUser
        currentUser = SignedInUser(
            userID: backendUser.userID,
            email: backendUser.email ?? fallbackUser?.email,
            displayName: backendUser.name ?? fallbackUser?.displayName
        )
        appUserProfile = try await backendClient.fetchProfile(idToken: idToken)
        currentVMAccess = try await fetchPreparedVMAccess(idToken: idToken)

        markBackendOnline()
        clearErrorState()
        recordActivity("Authenticated \(currentUser?.email ?? currentUser?.displayName ?? "user")")
    }

    private func refreshedIDTokenString(from user: GIDGoogleUser) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { refreshedUser, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard
                    let refreshedUser,
                    let idToken = refreshedUser.idToken?.tokenString
                else {
                    continuation.resume(throwing: GuardianBackendClient.ClientError.missingIDToken)
                    return
                }
                continuation.resume(returning: idToken)
            }
        }
    }

    private func currentAuthTokenString() async throws -> String {
        if let bearerToken {
            return bearerToken
        }
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw GuardianBackendClient.ClientError.missingIDToken
        }
        return try await refreshedIDTokenString(from: user)
    }

    private func googleConfiguration(bundle: Bundle = .main) -> GIDConfiguration? {
        guard let clientID = bundle.object(forInfoDictionaryKey: "GIDClientID") as? String else {
            return nil
        }
        let serverClientID = bundle.object(forInfoDictionaryKey: "GIDServerClientID") as? String
        return GIDConfiguration(clientID: clientID, serverClientID: serverClientID)
    }

    private func runBackendMonitorLoop() async {
        while !Task.isCancelled {
            do {
                _ = try await backendClient.fetchReadiness()
                if currentUser != nil {
                    markBackendOnline()
                    _ = try? await refreshVMAccessState(
                        recordActivityOnChange: true,
                        clearVisibleError: false
                    )
                }
            } catch {
                markBackendOffline()
            }

            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
        }
    }

    private func fetchPreparedVMAccess(idToken: String) async throws -> GuardianVMAccess {
        var vmAccess = try await backendClient.fetchVMAccess(idToken: idToken)

        if vmAccess.terminalSSHPublicKeyPresent == false || vmAccess.accessState == "needs_ssh_key" {
            do {
                let identity = try GuardianTerminalSSHIdentity.ensurePresent()
                appUserProfile = try await backendClient.registerTerminalSSHKey(
                    idToken: idToken,
                    publicKey: identity.publicKey
                )
                vmAccess = try await backendClient.fetchVMAccess(idToken: idToken)
            } catch {
                recordActivity(
                    "Terminal SSH key setup failed: \(error.localizedDescription)",
                    isError: true
                )
            }
        }

        return vmAccess
    }

    private func vmAccessActivityMessage(for vmAccess: GuardianVMAccess) -> String {
        let vmLabel = vmAccess.vmDisplayName ?? vmAccess.vmID ?? "Guardian VM"

        switch vmAccess.accessState {
        case "ready" where vmAccess.canConnect:
            return "\(vmLabel) is ready for Journal access"
        case "needs_ssh_key":
            return "\(vmLabel) is waiting for terminal SSH key registration"
        case "provisioning":
            return "\(vmLabel) is still provisioning"
        case "unassigned":
            return "No Guardian VM is assigned to this account yet"
        case "error":
            return vmAccess.bootstrapError ?? "\(vmLabel) provisioning reported an error"
        default:
            if vmAccess.canConnect {
                return "\(vmLabel) access changed"
            }
            return "\(vmLabel) is not ready for SSH connections yet"
        }
    }

    private func pollImportRunUntilSettled(
        idToken: String,
        ownedSourceID: String,
        importRunID: String,
        inventoryStore: SourceInventoryStore,
        fallbackInventorySources: [SourceBook]
    ) async throws {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let importRun = try await backendClient.fetchImportRun(
                idToken: idToken,
                ownedSourceID: ownedSourceID,
                importRunID: importRunID
            )
            try await refreshInventory(
                inventoryStore: inventoryStore,
                fallbackInventorySources: fallbackInventorySources
            )

            switch importRun.status {
            case "completed":
                recordActivity("Import completed for source \(ownedSourceID).")
                return
            case "failed":
                let message = importRun.error ?? "Import failed."
                setLastError(message)
                recordActivity(message, isError: true)
                return
            case "canceled":
                recordActivity("Import was canceled.")
                return
            default:
                try await Task.sleep(for: .seconds(2))
            }
        }

        recordActivity("Import is still processing in the backend.")
    }

    private func createOwnedSourceLive(
        sourceID: String,
        displayName: String,
        inventoryStore: SourceInventoryStore,
        fallbackInventorySources: [SourceBook]
    ) async throws -> GuardianOwnedSource {
        let idToken = try await currentAuthTokenString()
        let source = try await backendClient.createOwnedSource(
            idToken: idToken,
            sourceID: sourceID,
            displayName: displayName
        )
        recordActivity("Added source \(displayName)")
        try await refreshInventory(
            inventoryStore: inventoryStore,
            fallbackInventorySources: fallbackInventorySources
        )
        return source
    }

    private func buildTransportObjectPath(
        userID: String,
        ownedSourceID: String,
        importRunID: String,
        filename: String
    ) -> String {
        "tmp-imports/\(userID)/\(ownedSourceID)/\(importRunID)/\(filename)"
    }

    private func clearAuthenticatedState(resetError: Bool = true) {
        currentUser = nil
        backendUser = nil
        appUserProfile = nil
        currentVMAccess = nil
        currentImportQueue = []
        markBackendOffline()
        if resetError {
            clearErrorState()
        }
    }

    private func markBackendOnline() {
        backendStatus = BackendStatusValue.online.rawValue
    }

    private func markBackendOffline() {
        backendStatus = BackendStatusValue.offline.rawValue
    }

    private func clearErrorState() {
        lastError = nil
        suppressLastErrorInSignedOutPreview = false
    }

    private func setLastError(
        _ message: String,
        suppressInSignedOutPreview: Bool = false
    ) {
        lastError = message
        suppressLastErrorInSignedOutPreview = suppressInSignedOutPreview
    }

    private func recordActivity(_ message: String, isError: Bool = false) {
        recentActivity.insert(
            ActivityEntry(timestamp: Date(), message: message, isError: isError),
            at: 0
        )
        if recentActivity.count > 40 {
            recentActivity.removeLast(recentActivity.count - 40)
        }
    }

    private static func makeSignedInUser(from user: GIDGoogleUser?) -> SignedInUser? {
        guard let user else {
            return nil
        }
        return SignedInUser(
            userID: user.userID ?? UUID().uuidString,
            email: user.profile?.email,
            displayName: user.profile?.name
        )
    }

    private static func isRejectedBearerTokenError(_ error: Error) -> Bool {
        guard case let GuardianBackendClient.ClientError.server(statusCode, _) = error else {
            return false
        }
        return statusCode == 401
    }
}
