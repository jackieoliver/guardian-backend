import GoogleSignInSwift
import GuardianDesktopCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: ArchiveViewModel
    @Bindable var inventoryStore: SourceInventoryStore
    @Bindable var authSession: GoogleAuthSession
    @Bindable var journalWorkspace: JournalWorkspace
    let journalSessionController: JournalSessionController
    @State private var showsInventoryChoice = false
    @State private var selectedTab: GuardianTab = .journal
    @State private var timelineScrollPosition: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundSurface

                VStack(alignment: .leading, spacing: selectedTab == .journal ? 24 : 18) {
                    topBar

                    if selectedTab == .journal {
                        JournalWorkspaceView(
                            journalWorkspace: journalWorkspace,
                            journalSessionController: journalSessionController,
                            initialSurface: model.environment.initialJournalSurface
                        )
                        .transition(.asymmetric(insertion: .opacity.animation(.snappy(duration: 0.24)), removal: .opacity.animation(.easeOut(duration: 0.14))))
                    } else {
                        InventoryView(
                            model: model,
                            inventoryStore: inventoryStore,
                            authSession: authSession,
                            timelineScrollPosition: $timelineScrollPosition
                        )
                        .transition(.asymmetric(insertion: .opacity.animation(.snappy(duration: 0.24)), removal: .opacity.animation(.easeOut(duration: 0.14))))
                    }

                    Spacer(minLength: 0)
                }
                .padding(22)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .animation(.snappy(duration: 0.28, extraBounce: 0.03), value: selectedTab)
            }
        }
        .accessibilityIdentifier("scroll.archiveRoot")
        .onAppear {
            showsInventoryChoice = model.snapshot.showsInventoryDecision
            if let initialTab = GuardianTab(rawValue: model.environment.initialTab) {
                selectedTab = initialTab
            }
            if timelineScrollPosition == nil, let focusedMeasureID = model.defaultFocusedMeasureID {
                timelineScrollPosition = "measure-\(focusedMeasureID)"
            }
        }
        .sheet(isPresented: $showsInventoryChoice) {
            InventoryChoiceView()
        }
        .sheet(isPresented: $inventoryStore.isShowingAddSourceDialog) {
            AddSourceDialog(inventoryStore: inventoryStore, authSession: authSession)
        }
        .sheet(isPresented: $inventoryStore.isShowingManageSourcesDialog) {
            ManageSourcesDialog(inventoryStore: inventoryStore, authSession: authSession)
        }
        .sheet(isPresented: sourceImportDialogPresented) {
            if let sourceID = inventoryStore.sourceImportDialogOwnedSourceID {
                SourceImportDialog(
                    inventoryStore: inventoryStore,
                    authSession: authSession,
                    sourceID: sourceID,
                    fallbackInventorySources: model.snapshot.inventorySources
                )
            }
        }
        .onChange(of: authSession.currentUser?.userID) { _, _ in
            journalSessionController.resetForSignedInUserChange()
            authSession.syncInventory(
                inventoryStore: inventoryStore,
                fallbackInventorySources: model.snapshot.inventorySources
            )
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == .inventory {
                if let focusedMeasureID = model.currentMeasureID {
                    timelineScrollPosition = "measure-\(focusedMeasureID)"
                }
            } else {
                journalSessionController.detach()
            }
        }
    }

    private var sourceImportDialogPresented: Binding<Bool> {
        Binding(
            get: { inventoryStore.sourceImportDialogOwnedSourceID != nil },
            set: { isPresented in
                if isPresented == false {
                    inventoryStore.dismissSourceImportDialog()
                }
            }
        )
    }

    private var backgroundSurface: some View {
        ZStack {
            LinearGradient(
                colors: [ArchiveTheme.paperGlow, ArchiveTheme.paper.opacity(0.94)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.white.opacity(0.42), .clear],
                center: .topLeading,
                startRadius: 40,
                endRadius: 520
            )
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 20) {
            tabBar
            Spacer(minLength: 20)
            authCard
        }
    }

    private var tabBar: some View {
        HStack(spacing: 10) {
            ForEach(GuardianTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.28, extraBounce: 0.03)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(ArchiveTheme.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(selectedTab == tab ? Color.white.opacity(0.42) : Color.white.opacity(0.16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(selectedTab == tab ? ArchiveTheme.glassStroke : Color.white.opacity(0.14), lineWidth: 1)
                                )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab.\(tab.rawValue)")
            }
        }
    }

    private var authCard: some View {
        HStack(spacing: 10) {
            if let user = authSession.currentUser {
                Text(user.displayName ?? user.email ?? "Signed in")
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(ArchiveTheme.ink)
                    .accessibilityIdentifier("label.authUser")

                Circle()
                    .fill(authSession.backendStatus == "Online" ? Color.green.opacity(0.85) : Color.red.opacity(0.85))
                    .frame(width: 8, height: 8)
            } else {
                if authSession.usesBearerTokenSignIn {
                    Button("Sign In") {
                        authSession.signIn()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ArchiveTheme.green)
                    .controlSize(.regular)
                    .accessibilityIdentifier("button.tokenSignIn")
                } else {
                    GoogleSignInButton {
                        authSession.signIn()
                    }
                    .frame(width: 158, height: 36)
                    .accessibilityIdentifier("button.googleSignIn")
                }
            }

            if authSession.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            if let error = authSession.visibleErrorMessage {
                Text(error)
                    .font(.system(size: 11, weight: .regular, design: .serif))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .guardianPanel(cornerRadius: 16, style: .chrome)
        .accessibilityIdentifier("card.auth")
    }
}

#Preview("Mixed Coverage") {
    let workspace = JournalWorkspace()
    let authSession = GoogleAuthSession()
    ContentView(
        model: ArchiveViewModel(
            environment: AppEnvironment(
                mockState: .mixedCoverage,
                uiTesting: false,
                disableAnimations: false
            )
        ),
        inventoryStore: SourceInventoryStore(seedInventorySources: ArchiveSnapshot.make(for: .mixedCoverage).inventorySources),
        authSession: authSession,
        journalWorkspace: workspace,
        journalSessionController: JournalSessionController(journalWorkspace: workspace, authSession: authSession)
    )
}

#Preview("Regeneration") {
    let workspace = JournalWorkspace()
    let authSession = GoogleAuthSession()
    ContentView(
        model: ArchiveViewModel(
            environment: AppEnvironment(
                mockState: .regeneration,
                uiTesting: true,
                disableAnimations: true
            )
        ),
        inventoryStore: SourceInventoryStore(seedInventorySources: ArchiveSnapshot.make(for: .regeneration).inventorySources),
        authSession: authSession,
        journalWorkspace: workspace,
        journalSessionController: JournalSessionController(journalWorkspace: workspace, authSession: authSession)
    )
}
