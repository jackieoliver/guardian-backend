import AppKit
import Foundation
import GuardianDesktopCore
import SwiftUI

struct HelpMenuCommands: Commands {
    @Bindable var model: ArchiveViewModel
    @Bindable var inventoryStore: SourceInventoryStore
    @Bindable var authSession: GoogleAuthSession

    var body: some Commands {
        CommandGroup(after: .help) {
            Divider()

            Menu("Development Tools") {
                Button("Refresh Current State") {
                    authSession.refreshCurrentState(
                        inventoryStore: inventoryStore,
                        fallbackInventorySources: model.snapshot.inventorySources
                    )
                }
                .disabled(authSession.isWorking)

                Picker("Use Preview Data", selection: previewSelectionBinding) {
                    Text("Off").tag(PreviewOverrideSelection.off)
                    ForEach(MockArchiveState.allCases) { state in
                        Text(previewTitle(for: state)).tag(selection(for: state))
                    }
                }

                Divider()

                Button("Open Session Diagnostics") {
                    openSessionDiagnostics()
                }

                Button("Copy Diagnostics JSON") {
                    copySessionDiagnostics()
                }

                Divider()

                Button("Open App Support Folder") {
                    openAppSupportFolder()
                }
            }
        }
    }

    private func previewTitle(for state: MockArchiveState) -> String {
        switch state {
        case .mixedCoverage:
            return "Mixed Coverage"
        case .allDark:
            return "All Dark"
        case .regeneration:
            return "Regeneration"
        case .newSource:
            return "New Source"
        }
    }

    private func selection(for state: MockArchiveState) -> PreviewOverrideSelection {
        switch state {
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

    private var previewSelectionBinding: Binding<PreviewOverrideSelection> {
        Binding(
            get: { model.previewOverrideSelection },
            set: { selection in
                if let state = selection.mockState {
                    model.useBuiltInPreviewState(state)
                    inventoryStore.replaceInventorySources(with: model.snapshot.inventorySources)
                    inventoryStore.replaceSupportedSourceTypes(with: SourceInventoryStore.defaultSupportedSourceTypes)
                } else {
                    model.restoreBuiltInSnapshot()
                    authSession.refreshCurrentState(
                        inventoryStore: inventoryStore,
                        fallbackInventorySources: model.snapshot.inventorySources
                    )
                }
            }
        )
    }

    private func copySessionDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sessionDiagnosticsJSON(), forType: .string)
    }

    private func openSessionDiagnostics() {
        let diagnosticsURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("guardian-desktop-session-diagnostics.json")
        do {
            try sessionDiagnosticsJSON().write(to: diagnosticsURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(diagnosticsURL)
        } catch {
            NSLog("Open Session Diagnostics error: %@", String(describing: error))
        }
    }

    private func openAppSupportFolder() {
        do {
            try FileManager.default.createDirectory(at: GuardianAppSupportPaths.storageDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("Open App Support Folder createDirectory error: %@", String(describing: error))
        }
        NSWorkspace.shared.open(GuardianAppSupportPaths.storageDirectory)
    }

    private func sessionDiagnosticsJSON() -> String {
        struct DiagnosticsSnapshot: Encodable {
            struct UserSnapshot: Encodable {
                let userID: String?
                let email: String?
                let displayName: String?
            }

            struct BackendUserSnapshot: Encodable {
                let userID: String?
                let email: String?
                let emailVerified: Bool?
                let name: String?
            }

            struct ProfileSnapshot: Encodable {
                let userID: String?
                let email: String?
                let name: String?
                let vmID: String?
                let terminalSSHPublicKey: String?
            }

            struct VMAccessSnapshot: Encodable {
                let vmID: String?
                let host: String?
                let port: Int?
                let linuxUsername: String?
                let runtimeWorkspacePath: String?
                let runtimeWorkspaceState: String?
                let accessState: String?
                let canConnect: Bool
                let terminalSSHPublicKeyPresent: Bool
                let bootstrapError: String?
            }

            struct InventorySnapshot: Encodable {
                let id: String
                let name: String
                let detail: String
                let isConnected: Bool
            }

            struct ImportQueueSnapshot: Encodable {
                let importRunID: String
                let sourceDisplayName: String
                let status: String
                let transportShardCount: Int
                let uploadedTransportShardCount: Int
                let processedTransportShardCount: Int
            }

            struct ActivitySnapshot: Encodable {
                let timestamp: String
                let message: String
                let isError: Bool
            }

            let generatedAt: String
            let previewState: String
            let previewOverrideSelection: String
            let isPreviewVisible: Bool
            let backendStatus: String
            let isWorking: Bool
            let signInActionTitle: String
            let visibleErrorMessage: String?
            let lastError: String?
            let currentUser: UserSnapshot
            let backendUser: BackendUserSnapshot
            let profile: ProfileSnapshot
            let vmAccess: VMAccessSnapshot
            let inventorySources: [InventorySnapshot]
            let importQueue: [ImportQueueSnapshot]
            let recentActivity: [ActivitySnapshot]
        }

        let snapshot = DiagnosticsSnapshot(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            previewState: model.builtInMockState.rawValue,
            previewOverrideSelection: model.previewOverrideSelection.rawValue,
            isPreviewVisible: authSession.isShowingPreviewExperience,
            backendStatus: authSession.backendStatus,
            isWorking: authSession.isWorking,
            signInActionTitle: authSession.signInActionTitle,
            visibleErrorMessage: authSession.visibleErrorMessage,
            lastError: authSession.lastError,
            currentUser: .init(
                userID: authSession.currentUser?.userID,
                email: authSession.currentUser?.email,
                displayName: authSession.currentUser?.displayName
            ),
            backendUser: .init(
                userID: authSession.backendUser?.userID,
                email: authSession.backendUser?.email,
                emailVerified: authSession.backendUser?.emailVerified,
                name: authSession.backendUser?.name
            ),
            profile: .init(
                userID: authSession.appUserProfile?.userID,
                email: authSession.appUserProfile?.email,
                name: authSession.appUserProfile?.name,
                vmID: authSession.appUserProfile?.vmID,
                terminalSSHPublicKey: authSession.appUserProfile?.terminalSSHPublicKey
            ),
            vmAccess: .init(
                vmID: authSession.currentVMAccess?.vmID,
                host: authSession.currentVMAccess?.host,
                port: authSession.currentVMAccess?.port,
                linuxUsername: authSession.currentVMAccess?.linuxUsername,
                runtimeWorkspacePath: authSession.currentVMAccess?.runtimeWorkspacePath,
                runtimeWorkspaceState: authSession.currentVMAccess?.runtimeWorkspaceState,
                accessState: authSession.currentVMAccess?.accessState,
                canConnect: authSession.currentVMAccess?.canConnect ?? false,
                terminalSSHPublicKeyPresent: authSession.currentVMAccess?.terminalSSHPublicKeyPresent ?? false,
                bootstrapError: authSession.currentVMAccess?.bootstrapError
            ),
            inventorySources: inventoryStore.inventorySources.map {
                .init(
                    id: $0.id,
                    name: $0.name,
                    detail: $0.detail,
                    isConnected: $0.isConnected
                )
            },
            importQueue: authSession.currentImportQueue.map {
                .init(
                    importRunID: $0.importRunID,
                    sourceDisplayName: $0.sourceDisplayName,
                    status: $0.status,
                    transportShardCount: $0.transportShardCount,
                    uploadedTransportShardCount: $0.uploadedTransportShardCount,
                    processedTransportShardCount: $0.processedTransportShardCount
                )
            },
            recentActivity: authSession.recentActivity.map {
                .init(
                    timestamp: ISO8601DateFormatter().string(from: $0.timestamp),
                    message: $0.message,
                    isError: $0.isError
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{\n  \"error\" : \"Could not encode diagnostics\"\n}"
        }
        return text
    }
}
