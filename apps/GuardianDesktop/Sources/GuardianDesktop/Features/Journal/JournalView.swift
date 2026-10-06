import GuardianDesktopCore
import SwiftUI

struct JournalWorkspaceView: View {
    private enum SurfaceMode: String, CaseIterable, Identifiable {
        case notebook = "Notebook"
        case terminal = "Terminal"

        var id: String { rawValue }
    }

    @Bindable var journalWorkspace: JournalWorkspace
    let journalSessionController: JournalSessionController
    @State private var surfaceMode: SurfaceMode

    private let notebookPageSize = CGSize(width: 800, height: 520)
    private let surfaceLeadInset: CGFloat = 10
    private let entriesTopInset: CGFloat = 60
    private let entriesHeight: CGFloat = 448

    init(
        journalWorkspace: JournalWorkspace,
        journalSessionController: JournalSessionController,
        initialSurface: String = SurfaceMode.notebook.rawValue
    ) {
        _journalWorkspace = Bindable(journalWorkspace)
        self.journalSessionController = journalSessionController
        _surfaceMode = State(initialValue: SurfaceMode(rawValue: initialSurface) ?? .notebook)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            journalSurfaceColumn
            entriesCard
        }
        .padding(.bottom, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: journalWorkspace.selectedEntryID) {
            journalSessionController.activateForSelectedEntry()
        }
    }

    private var journalSurfaceColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            surfaceModePicker

            journalSurfaceCard
                .padding(.leading, surfaceLeadInset)
        }
        .frame(width: notebookPageSize.width + surfaceLeadInset, alignment: .leading)
        .animation(.snappy(duration: 0.22), value: surfaceMode)
    }

    private var surfaceModePicker: some View {
        HStack(spacing: 6) {
            ForEach(SurfaceMode.allCases) { mode in
                Button {
                    surfaceMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundStyle(surfaceMode == mode ? ArchiveTheme.ink : ArchiveTheme.ink.opacity(0.64))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Group {
                                if surfaceMode == mode {
                                    Capsule()
                                        .fill(Color.white.opacity(0.6))
                                        .overlay(
                                            Capsule()
                                                .stroke(ArchiveTheme.glassStroke.opacity(0.95), lineWidth: 1)
                                        )
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(mode == .notebook ? "button.surface.notebook" : "button.surface.terminal")
            }
        }
        .padding(6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.28))
                .overlay(
                    Capsule()
                        .stroke(ArchiveTheme.glassStroke.opacity(0.52), lineWidth: 1)
                )
        )
    }

    private var journalSurfaceCard: some View {
        ZStack(alignment: .topLeading) {
            if surfaceMode == .notebook {
                NotebookSheetBackground()
            }

            terminalViewport
        }
        .frame(width: notebookPageSize.width, height: notebookPageSize.height)
    }

    private var terminalViewport: some View {
        JournalTerminalSurfaceView(
            journalSessionController: journalSessionController,
            entryID: journalWorkspace.selectedEntryID,
            title: journalWorkspace.selectedEntry?.title ?? "Entry",
            style: surfaceMode == .notebook ? .notebook : .terminal,
            isActive: true
        )
        .frame(width: notebookPageSize.width, height: notebookPageSize.height)
    }

    private var entriesCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Text("Entries")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(ArchiveTheme.ink)

                Spacer(minLength: 12)

                Button {
                    journalWorkspace.createEntry()
                    journalSessionController.activateForSelectedEntry()
                } label: {
                    Label("New entry", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.44))
                                .overlay(
                                    Capsule()
                                        .stroke(ArchiveTheme.glassStroke.opacity(0.8), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("button.newEntry")
            }

            ScrollView {
                VStack(alignment: .trailing, spacing: 10) {
                    ForEach(journalEntries) { thread in
                        JournalEntryCard(
                            thread: thread,
                            journalWorkspace: journalWorkspace
                        ) {
                            journalWorkspace.selectEntry(thread.id)
                            journalSessionController.activateForSelectedEntry()
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 332, height: entriesHeight, alignment: .topLeading)
        .guardianPanel(cornerRadius: 24, style: .chrome)
        .padding(.top, entriesTopInset)
        .padding(.trailing, 4)
    }

    private var journalEntries: [JournalThread] {
        journalWorkspace.entries.map { entry in
            JournalThread(
                id: entry.id,
                title: entry.title,
                preview: entry.lines.last?.text ?? "Live shell ready",
                isSelected: entry.id == journalWorkspace.selectedEntryID
            )
        }
    }
}

private struct JournalThread: Identifiable {
    let id: UUID
    var title: String
    var preview: String
    var isSelected: Bool
}

private struct JournalEntryCard: View {
    let thread: JournalThread
    @Bindable var journalWorkspace: JournalWorkspace
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if thread.isSelected {
                TextField(
                    "Untitled entry",
                    text: Binding(
                        get: { thread.title },
                        set: { journalWorkspace.renameSelectedEntry(to: $0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(ArchiveTheme.ink)
                .accessibilityIdentifier("field.entryTitle")
            } else {
                Text(thread.title)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(ArchiveTheme.ink)
                    .lineLimit(1)
            }

            Text(thread.preview)
                .font(.system(size: 13, weight: .regular, design: .serif))
                .foregroundStyle(ArchiveTheme.ink.opacity(0.72))
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(thread.isSelected ? Color.white.opacity(0.42) : Color.white.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(thread.isSelected ? ArchiveTheme.glassStroke.opacity(0.92) : ArchiveTheme.glassStroke.opacity(0.45), lineWidth: 1)
                )
        }
        .onTapGesture(perform: onSelect)
    }
}
