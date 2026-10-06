import GuardianDesktopCore
import SwiftUI

struct SourceImportDialog: View {
    @Bindable var inventoryStore: SourceInventoryStore
    @Bindable var authSession: GoogleAuthSession
    let sourceID: String
    let fallbackInventorySources: [SourceBook]
    @Environment(\.dismiss) private var dismiss
    @State private var localError: String?

    private var book: SourceBook? {
        inventoryStore.sourceBook(id: sourceID)
    }

    private var sourceDisplayName: String {
        book?.name ?? "Stream"
    }

    private var savedFolderPaths: [String] {
        inventoryStore.savedImportFolderPaths(for: sourceID)
    }

    private var validFolderURLs: [URL] {
        savedFolderPaths.compactMap { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return url
        }
    }

    private var missingFolderCount: Int {
        savedFolderPaths.count - validFolderURLs.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Upload to \(sourceDisplayName)")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(ArchiveTheme.ink)

            Text("Choose one or more folders for Guardian to scan whenever this stream uploads new material.")
                .font(.system(size: 16, weight: .regular, design: .serif))
                .foregroundStyle(ArchiveTheme.ink.opacity(0.72))

            HStack(spacing: 10) {
                Button(savedFolderPaths.isEmpty ? "Choose Folders…" : "Add Folders…") {
                    chooseFolders(replacingExisting: false)
                }
                .buttonStyle(.borderedProminent)
                .tint(ArchiveTheme.green)
                .accessibilityIdentifier("button.chooseImportFolders.\(sourceID)")

                if savedFolderPaths.isEmpty == false {
                    Button("Replace All…") {
                        chooseFolders(replacingExisting: true)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("button.replaceImportFolders.\(sourceID)")

                    Button("Clear") {
                        inventoryStore.clearSavedImportFolders(for: sourceID)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("button.clearImportFolders.\(sourceID)")
                }
            }

            if savedFolderPaths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No folders selected yet.")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(ArchiveTheme.ink)
                    Text("Guardian will look through every selected folder, figure out what is new, shard it, and queue the upload.")
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .foregroundStyle(ArchiveTheme.ink.opacity(0.68))
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(savedFolderPaths, id: \.self) { folderPath in
                            ImportFolderRow(
                                path: folderPath,
                                isMissing: folderIsMissing(folderPath)
                            ) {
                                inventoryStore.removeSavedImportFolder(path: folderPath, for: sourceID)
                            }
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 260)
            }

            if missingFolderCount > 0 {
                Text("\(missingFolderCount) saved folder\(missingFolderCount == 1 ? "" : "s") can’t be found right now and will be skipped.")
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .foregroundStyle(.red.opacity(0.82))
            }

            if let localError {
                Text(localError)
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .foregroundStyle(.red.opacity(0.82))
            }

            if authSession.currentUser == nil {
                Text("Sign in to run live uploads from these folders.")
                    .font(.system(size: 13, weight: .medium, design: .serif))
                    .foregroundStyle(ArchiveTheme.ink.opacity(0.72))
            }

            HStack {
                Button("Upload New Files") {
                    beginUpload()
                }
                .buttonStyle(.borderedProminent)
                .tint(ArchiveTheme.green)
                .disabled(authSession.currentUser == nil || authSession.isWorking || validFolderURLs.isEmpty)
                .accessibilityIdentifier("button.uploadFolders.\(sourceID)")

                Spacer()

                Button("Done") {
                    inventoryStore.dismissSourceImportDialog()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("button.doneSourceImport.\(sourceID)")
            }
        }
        .padding(28)
        .frame(minWidth: 620, minHeight: 420)
        .background(ArchiveTheme.paper)
        .accessibilityIdentifier("dialog.sourceImport.\(sourceID)")
    }

    private func chooseFolders(replacingExisting: Bool) {
        let startingDirectory = savedFolderPaths.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let selectedURLs = SourceImportWorkflow.chooseImportFolders(startingAt: startingDirectory),
              selectedURLs.isEmpty == false
        else {
            return
        }

        localError = nil
        if replacingExisting {
            inventoryStore.replaceSavedImportFolders(selectedURLs, for: sourceID)
        } else {
            inventoryStore.appendSavedImportFolders(selectedURLs, for: sourceID)
        }
    }

    private func beginUpload() {
        guard validFolderURLs.isEmpty == false else {
            localError = "Choose at least one available folder before uploading."
            return
        }

        localError = nil
        authSession.importSourceFiles(
            ownedSourceID: sourceID,
            selectedURLs: validFolderURLs,
            inventoryStore: inventoryStore,
            fallbackInventorySources: fallbackInventorySources
        )
        inventoryStore.dismissSourceImportDialog()
        dismiss()
    }

    private func folderIsMissing(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) == false || isDirectory.boolValue == false
    }
}

struct AddSourceDialog: View {
    @Bindable var inventoryStore: SourceInventoryStore
    @Bindable var authSession: GoogleAuthSession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSourceTypeID: String?
    @State private var customName = ""

    private var selectedSourceType: SourceCatalogItem? {
        inventoryStore.supportedSourceTypes.first { $0.id == selectedSourceTypeID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Source")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(ArchiveTheme.ink)

            Text("Choose from validated source types for your inventory.")
                .font(.system(size: 16, weight: .regular, design: .serif))
                .foregroundStyle(ArchiveTheme.ink.opacity(0.72))

            VStack(spacing: 12) {
                ForEach(inventoryStore.supportedSourceTypes) { sourceType in
                    Button {
                        selectedSourceTypeID = sourceType.id
                        customName = inventoryStore.defaultCustomName(for: sourceType)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sourceType.displayName)
                                    .font(.system(size: 17, weight: .semibold, design: .serif))
                                    .foregroundStyle(ArchiveTheme.ink)
                                Text(sourceType.detail)
                                    .font(.system(size: 13, weight: .regular, design: .serif))
                                    .foregroundStyle(ArchiveTheme.ink.opacity(0.68))
                            }

                            Spacer()

                            Text(selectedSourceTypeID == sourceType.id ? "Selected" : "Choose")
                                .font(.system(size: 14, weight: .semibold, design: .serif))
                                .foregroundStyle(selectedSourceTypeID == sourceType.id ? ArchiveTheme.ink : ArchiveTheme.green)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selectedSourceTypeID == sourceType.id ? Color.white.opacity(0.88) : Color.white.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(
                                    selectedSourceTypeID == sourceType.id ? ArchiveTheme.green.opacity(0.5) : .clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("button.addSourceType.\(sourceType.id)")
                }
            }

            if let selectedSourceType {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom name")
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundStyle(ArchiveTheme.ink.opacity(0.82))

                    TextField(
                        "Name this source",
                        text: $customName,
                        prompt: Text(inventoryStore.defaultCustomName(for: selectedSourceType))
                            .foregroundStyle(ArchiveTheme.ink.opacity(0.42))
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .accessibilityIdentifier("field.customSourceName")

                    Text("Default suggestion: \(inventoryStore.defaultCustomName(for: selectedSourceType))")
                        .font(.system(size: 12, weight: .regular, design: .serif))
                        .foregroundStyle(ArchiveTheme.ink.opacity(0.56))
                }
                .padding(18)
                .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            HStack {
                if let selectedSourceType {
                    Button("Add Selected Source") {
                        authSession.addInventorySource(
                            selectedSourceType,
                            customName: customName,
                            inventoryStore: inventoryStore
                        )
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ArchiveTheme.green)
                    .accessibilityIdentifier("button.confirmAddSource")
                }

                Spacer()

                Button("Done") {
                    inventoryStore.dismissAddSourceDialog()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("button.doneAddSource")
            }
        }
        .padding(28)
        .frame(minWidth: 520)
        .background(ArchiveTheme.paper)
        .accessibilityIdentifier("dialog.addSource")
        .onAppear {
            if selectedSourceTypeID == nil, let first = inventoryStore.supportedSourceTypes.first {
                selectedSourceTypeID = first.id
                customName = inventoryStore.defaultCustomName(for: first)
            }
        }
    }
}

struct ManageSourcesDialog: View {
    @Bindable var inventoryStore: SourceInventoryStore
    @Bindable var authSession: GoogleAuthSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Manage Sources")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundStyle(ArchiveTheme.ink)
                    Text("Replace, remove, or expand your inventory.")
                        .font(.system(size: 16, weight: .regular, design: .serif))
                        .foregroundStyle(ArchiveTheme.ink.opacity(0.72))
                }

                Spacer()

                Button("Add Source") {
                    inventoryStore.showAddSourceDialog()
                }
                .buttonStyle(.borderedProminent)
                .tint(ArchiveTheme.green)
                .accessibilityIdentifier("button.manageAddSource")
            }

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(inventoryStore.inventorySources) { book in
                        ManageSourceRow(book: book, inventoryStore: inventoryStore, authSession: authSession)
                    }
                }
            }

            HStack {
                Spacer()

                Button("Done") {
                    inventoryStore.dismissManageSourcesDialog()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("button.doneManageSources")
            }
        }
        .padding(28)
        .frame(minWidth: 680, minHeight: 520)
        .background(ArchiveTheme.paper)
        .accessibilityIdentifier("dialog.manageSources")
    }
}

private struct ManageSourceRow: View {
    let book: SourceBook
    @Bindable var inventoryStore: SourceInventoryStore
    @Bindable var authSession: GoogleAuthSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ArchiveTheme.vitalityColor(for: book.vitality))
                .frame(width: 28, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.name)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(ArchiveTheme.ink)
                Text(book.detail)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .foregroundStyle(ArchiveTheme.ink.opacity(0.68))
            }

            Spacer()

            Button("Upload…") {
                openImportDialog()
            }
            .buttonStyle(.borderedProminent)
            .tint(ArchiveTheme.green)
            .disabled(authSession.currentUser == nil || authSession.isWorking)
            .accessibilityIdentifier("button.importSource.\(book.id)")

            Menu("Replace") {
                ForEach(inventoryStore.supportedSourceTypes) { sourceType in
                    Button(sourceType.displayName) {
                        authSession.replaceInventorySource(
                            id: book.id,
                            with: sourceType,
                            inventoryStore: inventoryStore,
                            fallbackInventorySources: inventoryStore.inventorySources
                        )
                    }
                }
            }
            .accessibilityIdentifier("menu.replaceSource.\(book.id)")

            Button("Delete") {
                authSession.removeInventorySource(
                    id: book.id,
                    inventoryStore: inventoryStore,
                    fallbackInventorySources: inventoryStore.inventorySources
                )
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityIdentifier("button.deleteSource.\(book.id)")
        }
        .padding(18)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ArchiveTheme.line.opacity(0.28), lineWidth: 1)
        )
    }

    private func openImportDialog() {
        inventoryStore.showSourceImportDialog(for: book.id)
        dismiss()
    }
}

private struct ImportFolderRow: View {
    let path: String
    let isMissing: Bool
    let onRemove: () -> Void

    private var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isMissing ? "exclamationmark.triangle.fill" : "folder.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isMissing ? Color.red.opacity(0.82) : ArchiveTheme.green)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(ArchiveTheme.ink)
                Text(path)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(ArchiveTheme.ink.opacity(0.58))
                    .textSelection(.enabled)

                if isMissing {
                    Text("Folder unavailable")
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundStyle(.red.opacity(0.8))
                }
            }

            Spacer()

            Button("Remove", action: onRemove)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ArchiveTheme.line.opacity(0.22), lineWidth: 1)
        )
    }
}
