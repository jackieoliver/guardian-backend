import Foundation
import SwiftTerm

@MainActor
protocol JournalTerminalSink: AnyObject {
    func resetTerminalTranscript()
    func appendTerminal(bytes: ArraySlice<UInt8>)
}

@MainActor
final class JournalSessionController {
    private enum JournalLaunchPlan {
        case shell(JournalLaunchConfiguration)
        case unavailable(String)
    }

    private(set) var activeEntryID: UUID?

    var isReady: Bool {
        activeSession?.isReady ?? false
    }

    var hasReceivedHostOutput: Bool {
        activeSession?.hasReceivedHostOutput ?? false
    }

    var hasSeenShellPrompt: Bool {
        activeSession?.hasSeenShellPrompt ?? false
    }

    private let journalWorkspace: JournalWorkspace
    private let authSession: GoogleAuthSession
    private let terminalSinks = NSHashTable<AnyObject>.weakObjects()
    private let transcriptStore = JournalTerminalTranscriptStore()
    private var sessions: [UUID: EntryShellSession] = [:]
    private var currentWindowSize = winsize(ws_row: 32, ws_col: 120, ws_xpixel: 1440, ws_ypixel: 900)
    private var currentUserID: String?
    private var vmAccessRefreshTask: Task<Void, Never>?

    init(journalWorkspace: JournalWorkspace, authSession: GoogleAuthSession) {
        self.journalWorkspace = journalWorkspace
        self.authSession = authSession
        currentUserID = authSession.currentUser?.userID
    }

    func activateForSelectedEntry() {
        guard let entry = journalWorkspace.selectedEntry else {
            detach()
            return
        }
        attach(to: entry.id)
    }

    func submitSelectedDraft() {
        guard let submission = journalWorkspace.submitDraftForSelectedEntry() else {
            return
        }

        attach(to: submission.entryID)
        sessions[submission.entryID]?.sendNotebookCommand(submission.text)
    }

    func registerTerminalSink(_ sink: JournalTerminalSink, for entryID: UUID?) {
        if !terminalSinks.contains(sink) {
            terminalSinks.add(sink)
        }
        sink.resetTerminalTranscript()

        guard let entryID else {
            return
        }

        if let existing = transcriptStore.readTranscript(for: entryID) {
            sink.appendTerminal(bytes: Array(existing)[...])
        }

        attach(to: entryID)
    }

    func unregisterTerminalSink(_ sink: JournalTerminalSink) {
        terminalSinks.remove(sink)
    }

    func sendTerminalInput(_ data: ArraySlice<UInt8>) {
        activeSession?.sendTerminalInput(data)
    }

    func updateTerminalWindowSize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        currentWindowSize = winsize(
            ws_row: UInt16(max(rows, 1)),
            ws_col: UInt16(max(cols, 1)),
            ws_xpixel: UInt16(max(pixelWidth, 1)),
            ws_ypixel: UInt16(max(pixelHeight, 1))
        )
        activeSession?.updateWindowSize(currentWindowSize)
    }

    func detach() {
        activeEntryID = nil
    }

    func resetForSignedInUserChange() {
        let newUserID = authSession.currentUser?.userID
        guard newUserID != currentUserID else {
            return
        }
        currentUserID = newUserID
        terminateAllSessions()
    }

    private var activeSession: EntryShellSession? {
        guard let activeEntryID else {
            return nil
        }
        return sessions[activeEntryID]
    }

    private func attach(to entryID: UUID) {
        activeEntryID = entryID

        if let session = sessions[entryID], session.isRunning {
            session.updateWindowSize(currentWindowSize)
            return
        }

        switch resolvedLaunchPlan() {
        case let .shell(config):
            vmAccessRefreshTask?.cancel()
            vmAccessRefreshTask = nil
            let session = sessions[entryID] ?? makeSession(for: entryID)
            sessions[entryID] = session
            session.ensureStarted(
                config: config,
                windowSize: currentWindowSize
            )
        case let .unavailable(message):
            renderUnavailableState(for: entryID, message: message)
            refreshVMAccessForActiveEntryIfNeeded(entryID: entryID)
        }
    }

    private func makeSession(for entryID: UUID) -> EntryShellSession {
        EntryShellSession(
            entryID: entryID,
            transcriptStore: transcriptStore,
            onOutput: { [weak self] entryID, slice in
                Task { @MainActor [weak self] in
                    self?.handleOutput(slice, for: entryID)
                }
            },
            onLine: { [weak self] entryID, line in
                Task { @MainActor [weak self] in
                    self?.journalWorkspace.appendSystemLine(line, to: entryID)
                }
            },
            onTermination: { [weak self] entryID in
                Task { @MainActor [weak self] in
                    self?.handleTermination(for: entryID)
                }
            }
        )
    }

    private func handleOutput(_ slice: ArraySlice<UInt8>, for entryID: UUID) {
        guard activeEntryID == entryID else {
            return
        }
        terminalSinks.allObjects
            .compactMap { $0 as? JournalTerminalSink }
            .forEach { $0.appendTerminal(bytes: slice) }
    }

    private func handleTermination(for entryID: UUID) {
        sessions[entryID] = nil
        if activeEntryID == entryID {
            activeEntryID = nil
        }
        journalWorkspace.appendSystemLine(
            "Guardian VM session ended. Reopen this entry to start a new live shell.",
            to: entryID
        )
    }

    private func terminateAllSessions() {
        vmAccessRefreshTask?.cancel()
        vmAccessRefreshTask = nil
        sessions.values.forEach { $0.terminate() }
        sessions.removeAll()
        activeEntryID = nil
    }

    private func resolvedLaunchPlan() -> JournalLaunchPlan {
        switch guardianSSHCommandResolution(vmAccess: authSession.currentVMAccess) {
        case let .command(dynamicCommand):
            return .shell(
                JournalLaunchConfiguration(
                    displayName: authSession.currentVMAccess?.vmDisplayName ?? JournalLaunchConfiguration.defaultDisplayName,
                    shellCommand: dynamicCommand,
                    terminalType: JournalLaunchConfiguration.defaultTerminalType,
                    introMessages: JournalLaunchConfiguration.defaultIntroMessages
                )
            )
        case let .unavailable(message):
            return .unavailable(message)
        }
    }

    private func renderUnavailableState(for entryID: UUID, message: String) {
        sessions[entryID]?.terminate()
        sessions[entryID] = nil

        let rendered = """
        Guardian VM unavailable

        \(message)
        """
        let transcript = Array((rendered + "\n").utf8)
        transcriptStore.overwriteTranscript(Data(transcript), for: entryID)
        terminalSinks.allObjects
            .compactMap { $0 as? JournalTerminalSink }
            .forEach {
                $0.resetTerminalTranscript()
                $0.appendTerminal(bytes: transcript[...])
            }
        journalWorkspace.appendSystemLineIfNeeded(message, to: entryID)
    }

    private func refreshVMAccessForActiveEntryIfNeeded(entryID: UUID) {
        guard authSession.currentUser != nil else {
            return
        }

        vmAccessRefreshTask?.cancel()
        vmAccessRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                _ = try await authSession.refreshVMAccessState(
                    recordActivityOnChange: true,
                    clearVisibleError: false
                )
            } catch {
                return
            }

            guard !Task.isCancelled, activeEntryID == entryID else {
                return
            }

            switch resolvedLaunchPlan() {
            case .shell:
                attach(to: entryID)
            case let .unavailable(message):
                renderUnavailableState(for: entryID, message: message)
            }
        }
    }
}

private final class EntryShellSession: LocalProcessDelegate {
    private static let suppressedNotebookLines: Set<String> = [
        "Guardian raw VM shell",
        "Synced files live under /srv/guardian-sync",
        "Run guardian-status for VM, user, and sync state",
    ]

    let entryID: UUID
    private let transcriptStore: JournalTerminalTranscriptStore
    private let onOutput: @Sendable (UUID, ArraySlice<UInt8>) -> Void
    private let onLine: @Sendable (UUID, String) -> Void
    private let onTermination: @Sendable (UUID) -> Void

    private(set) var process: LocalProcess?
    private(set) var isReady = false
    private(set) var hasReceivedHostOutput = false
    private(set) var hasSeenShellPrompt = false
    private var pendingEchoes: [String] = []
    private var suppressedCommandEchoes: Set<String> = []
    private var lineBuffer = ""
    private var currentWindowSize = winsize(ws_row: 32, ws_col: 120, ws_xpixel: 1440, ws_ypixel: 900)

    init(
        entryID: UUID,
        transcriptStore: JournalTerminalTranscriptStore,
        onOutput: @escaping @Sendable (UUID, ArraySlice<UInt8>) -> Void,
        onLine: @escaping @Sendable (UUID, String) -> Void,
        onTermination: @escaping @Sendable (UUID) -> Void
    ) {
        self.entryID = entryID
        self.transcriptStore = transcriptStore
        self.onOutput = onOutput
        self.onLine = onLine
        self.onTermination = onTermination
    }

    var isRunning: Bool {
        process?.running == true
    }

    func ensureStarted(config: JournalLaunchConfiguration, windowSize: winsize) {
        guard process?.running != true else {
            updateWindowSize(windowSize)
            return
        }

        currentWindowSize = windowSize
        isReady = false
        hasReceivedHostOutput = false
        hasSeenShellPrompt = false
        pendingEchoes = []
        suppressedCommandEchoes = []
        lineBuffer = ""

        let launchCommand = guardianSSHLaunchCommand(baseCommand: config.shellCommand)
        let process = LocalProcess(delegate: self)

        var environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        environment.removeAll { $0.hasPrefix("TERM=") }
        environment.append("TERM=\(config.terminalType)")

        self.process = process
        process.startProcess(
            executable: "/bin/zsh",
            args: ["-lc", "exec \(launchCommand)"],
            environment: environment
        )
        isReady = true
    }

    func sendNotebookCommand(_ commandText: String) {
        guard let process, process.running else {
            return
        }
        pendingEchoes.append(commandText)
        suppressedCommandEchoes.insert(commandText)
        process.send(data: Array((commandText + "\r").utf8)[...])
    }

    func sendTerminalInput(_ data: ArraySlice<UInt8>) {
        guard let process, process.running else {
            return
        }
        process.send(data: data)
    }

    func updateWindowSize(_ windowSize: winsize) {
        currentWindowSize = windowSize
        guard let process, process.running else {
            return
        }
        var updated = currentWindowSize
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &updated)
    }

    func terminate() {
        process?.terminate()
        process = nil
        isReady = false
        hasReceivedHostOutput = false
        hasSeenShellPrompt = false
        pendingEchoes = []
        suppressedCommandEchoes = []
        lineBuffer = ""
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        hasReceivedHostOutput = true
        transcriptStore.appendChunk(Data(slice), for: entryID)
        onOutput(entryID, slice)
        projectNotebookOutput(from: Data(slice))
    }

    func processTerminated(_: LocalProcess, exitCode _: Int32?) {
        terminate()
        onTermination(entryID)
    }

    func getWindowSize() -> winsize {
        currentWindowSize
    }

    private func projectNotebookOutput(from data: Data) {
        lineBuffer += sanitize(String(decoding: data, as: UTF8.self))

        while let newlineRange = lineBuffer.range(of: "\n") {
            let rawLine = String(lineBuffer[..<newlineRange.lowerBound])
            lineBuffer.removeSubrange(lineBuffer.startIndex ... newlineRange.lowerBound)
            appendProjectedLine(rawLine)
        }
    }

    private func appendProjectedLine(_ rawLine: String) {
        let line = normalizeLine(rawLine)
        guard !line.isEmpty else {
            return
        }

        if Self.suppressedNotebookLines.contains(line) {
            return
        }

        if let strippedPromptLine = stripPromptPrefix(from: line) {
            hasSeenShellPrompt = true
            guard !strippedPromptLine.isEmpty else {
                return
            }

            if shouldSuppressCommandEcho(strippedPromptLine) {
                return
            }

            if let echo = pendingEchoes.first,
               strippedPromptLine == echo || strippedPromptLine.hasSuffix(echo)
            {
                pendingEchoes.removeFirst()
                return
            }

            onLine(entryID, strippedPromptLine)
            return
        }

        if looksLikeShellPrompt(line) {
            hasSeenShellPrompt = true
            return
        }

        if shouldSuppressCommandEcho(line) {
            return
        }

        if let echo = pendingEchoes.first,
           line == echo || line.hasSuffix(echo) || line.contains(echo)
        {
            pendingEchoes.removeFirst()
            return
        }

        onLine(entryID, line)
    }

    private func sanitize(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var result = ""
        var index = normalized.startIndex

        while index < normalized.endIndex {
            let character = normalized[index]

            if character == "\u{001B}" {
                index = normalized.index(after: index)
                guard index < normalized.endIndex else { break }

                let lead = normalized[index]
                if lead == "[" {
                    index = normalized.index(after: index)
                    while index < normalized.endIndex {
                        let scalar = normalized[index].unicodeScalars.first!.value
                        if (64 ... 126).contains(scalar) {
                            index = normalized.index(after: index)
                            break
                        }
                        index = normalized.index(after: index)
                    }
                } else if lead == "]" {
                    index = normalized.index(after: index)
                    while index < normalized.endIndex {
                        let scalar = normalized[index].unicodeScalars.first!.value
                        if scalar == 0x07 {
                            index = normalized.index(after: index)
                            break
                        }
                        if normalized[index] == "\u{001B}" {
                            let nextIndex = normalized.index(after: index)
                            if nextIndex < normalized.endIndex, normalized[nextIndex] == "\\" {
                                index = normalized.index(after: nextIndex)
                                break
                            }
                        }
                        index = normalized.index(after: index)
                    }
                } else if lead == "(" || lead == ")" || lead == "%" || lead == "#" {
                    index = normalized.index(after: index)
                    if index < normalized.endIndex {
                        index = normalized.index(after: index)
                    }
                } else {
                    index = normalized.index(after: index)
                }
                continue
            }

            let scalar = character.unicodeScalars.first!.value
            if scalar == 0x09 || scalar == 0x0A || scalar >= 0x20 {
                result.append(character)
            }

            index = normalized.index(after: index)
        }

        return result
    }

    private func normalizeLine(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix("(B") {
            cleaned.removeFirst(2)
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        }
        while cleaned.hasSuffix("(B") {
            cleaned.removeLast(2)
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        }
        return cleaned
    }

    private func looksLikeShellPrompt(_ line: String) -> Bool {
        if line.contains("$ ") || line.hasSuffix("$") || line.contains("% ") || line.hasSuffix("%") {
            return true
        }
        return false
    }

    private func stripPromptPrefix(from line: String) -> String? {
        for marker in ["$ ", "% "] {
            if let range = line.range(of: marker, options: .backwards) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func shouldSuppressCommandEcho(_ line: String) -> Bool {
        for command in suppressedCommandEchoes where line == command || line.hasSuffix(command) {
            pendingEchoes.removeAll { $0 == command }
            return true
        }
        return false
    }
}

private struct JournalTerminalTranscriptStore {
    private let fileManager = FileManager.default

    func overwriteTranscript(_ data: Data, for entryID: UUID) {
        let url = transcriptURL(for: entryID)

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("JournalTerminalTranscriptStore overwrite error: %@", String(describing: error))
        }
    }

    func appendChunk(_ data: Data, for entryID: UUID) {
        guard !data.isEmpty else {
            return
        }

        let url = transcriptURL(for: entryID)

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if !fileManager.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
                return
            }

            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("JournalTerminalTranscriptStore append error: %@", String(describing: error))
        }
    }

    func readTranscript(for entryID: UUID) -> Data? {
        try? Data(contentsOf: transcriptURL(for: entryID))
    }

    private func transcriptURL(for entryID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("GuardianDesktop", isDirectory: true)
            .appendingPathComponent("terminal-transcripts", isDirectory: true)
            .appendingPathComponent("\(entryID.uuidString.lowercased()).ansi")
    }
}
