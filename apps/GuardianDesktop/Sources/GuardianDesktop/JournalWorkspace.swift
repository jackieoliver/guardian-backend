import Foundation
import Observation

enum JournalLineRole: String, Codable {
    case user
    case system
}

struct JournalLine: Identifiable, Codable, Equatable {
    let id: UUID
    let role: JournalLineRole
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), role: JournalLineRole, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

struct JournalDocument: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var lines: [JournalLine]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        lines: [JournalLine],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.lines = lines
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct JournalSubmission {
    let entryID: UUID
    let text: String
}

private struct JournalWorkspaceSnapshot: Codable {
    var entries: [JournalDocument]
    var selectedEntryID: UUID?
    var draftText: String

    private enum CodingKeys: String, CodingKey {
        case entries
        case selectedEntryID
        case draftText
        case chapters
        case selectedChapterID
    }

    init(entries: [JournalDocument], selectedEntryID: UUID?, draftText: String) {
        self.entries = entries
        self.selectedEntryID = selectedEntryID
        self.draftText = draftText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([JournalDocument].self, forKey: .entries)
            ?? container.decodeIfPresent([JournalDocument].self, forKey: .chapters)
            ?? []
        selectedEntryID = try container.decodeIfPresent(UUID.self, forKey: .selectedEntryID)
            ?? container.decodeIfPresent(UUID.self, forKey: .selectedChapterID)
        draftText = try container.decodeIfPresent(String.self, forKey: .draftText) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encodeIfPresent(selectedEntryID, forKey: .selectedEntryID)
        try container.encode(draftText, forKey: .draftText)
    }
}

@Observable
@MainActor
final class JournalWorkspace {
    var entries: [JournalDocument]
    var selectedEntryID: UUID?
    var draftText: String

    init() {
        if let snapshot = Self.loadSnapshot() {
            entries = snapshot.entries
            selectedEntryID = snapshot.selectedEntryID ?? snapshot.entries.first?.id
            draftText = snapshot.draftText
        } else {
            let initialEntry = JournalDocument(
                title: "Entry 1",
                lines: []
            )
            entries = [initialEntry]
            selectedEntryID = initialEntry.id
            draftText = ""
            persist()
        }
    }

    var selectedEntry: JournalDocument? {
        guard let selectedEntryID else {
            return entries.first
        }
        return entries.first { $0.id == selectedEntryID }
    }

    func selectEntry(_ id: UUID) {
        selectedEntryID = id
        persist()
    }

    func createEntry() {
        let nextIndex = entries.count + 1
        let entry = JournalDocument(
            title: "Entry \(nextIndex)",
            lines: []
        )
        entries.insert(entry, at: 0)
        selectedEntryID = entry.id
        draftText = ""
        persist()
    }

    func renameSelectedEntry(to title: String) {
        guard let selectedEntryID,
              let index = entries.firstIndex(where: { $0.id == selectedEntryID })
        else {
            return
        }

        entries[index].title = title
        entries[index].updatedAt = Date()
        persist()
    }

    func submitDraftForSelectedEntry() -> JournalSubmission? {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let selectedEntryID,
              let index = entries.firstIndex(where: { $0.id == selectedEntryID })
        else {
            return nil
        }

        entries[index].lines.append(JournalLine(role: .user, text: trimmed))
        entries[index].updatedAt = Date()
        draftText = ""
        persist()
        return JournalSubmission(entryID: selectedEntryID, text: trimmed)
    }

    func appendSystemLine(_ text: String, to entryID: UUID, createdAt: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        entries[index].lines.append(JournalLine(role: .system, text: trimmed, createdAt: createdAt))
        entries[index].updatedAt = Date()
        persist()
    }

    func appendSystemLineIfNeeded(_ text: String, to entryID: UUID, createdAt: Date = Date()) {
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        if let lastLine = entry.lines.last,
           lastLine.role == .system,
           lastLine.text == trimmed
        {
            return
        }

        appendSystemLine(trimmed, to: entryID, createdAt: createdAt)
    }

    func setDraftText(_ text: String) {
        draftText = text
        persist()
    }

    private func persist() {
        let snapshot = JournalWorkspaceSnapshot(
            entries: entries,
            selectedEntryID: selectedEntryID,
            draftText: draftText
        )

        do {
            let data = try JSONEncoder.pretty.encode(snapshot)
            try FileManager.default.createDirectory(
                at: Self.storageDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: Self.storageURL, options: .atomic)
        } catch {
            NSLog("JournalWorkspace persist error: %@", String(describing: error))
        }
    }

    private static func loadSnapshot() -> JournalWorkspaceSnapshot? {
        do {
            let data = try Data(contentsOf: storageURL)
            return try JSONDecoder.guardian.decode(JournalWorkspaceSnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    private static let storageDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("GuardianDesktop", isDirectory: true)
    }()

    private static let storageURL = storageDirectory.appendingPathComponent("journal-workspace.json")
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var guardian: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
