import AppKit
import GuardianDesktopCore
import SwiftTerm
import SwiftUI

enum JournalTerminalSurfaceStyle: Equatable {
    case notebook
    case terminal
}

struct JournalTerminalSurfaceView: NSViewRepresentable {
    let journalSessionController: JournalSessionController
    let entryID: UUID?
    let title: String
    let style: JournalTerminalSurfaceStyle
    let isActive: Bool

    func makeNSView(context: Context) -> GuardianTerminalContainerView {
        let view = GuardianTerminalContainerView(frame: .zero, journalSessionController: journalSessionController)
        context.coordinator.terminalContainer = view
        return view
    }

    func updateNSView(_ nsView: GuardianTerminalContainerView, context: Context) {
        nsView.configure(entryID: entryID, title: title, style: style, isActive: isActive)
    }

    static func dismantleNSView(_ nsView: GuardianTerminalContainerView, coordinator: Coordinator) {
        nsView.disconnect()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var terminalContainer: GuardianTerminalContainerView?
    }
}

@MainActor
final class GuardianTerminalContainerView: NSView, @preconcurrency TerminalViewDelegate, JournalTerminalSink {
    private let journalSessionController: JournalSessionController
    private var terminalView: TerminalView?
    private let statusLabel = NSTextField(labelWithString: "Live terminal")
    private var currentEntryID: UUID?
    private var entryTitle: String = ""
    private var surfaceStyle: JournalTerminalSurfaceStyle = .terminal
    private var isActiveSurface = false

    init(frame frameRect: NSRect, journalSessionController: JournalSessionController) {
        self.journalSessionController = journalSessionController
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(entryID: UUID?, title: String, style: JournalTerminalSurfaceStyle, isActive: Bool) {
        entryTitle = title
        isActiveSurface = isActive

        if surfaceStyle != style {
            surfaceStyle = style
            applySurfaceStyle()
        }

        if currentEntryID != entryID {
            currentEntryID = entryID
            resetTerminalTranscript()
        }

        updateStatusLabel()

        guard let entryID else {
            journalSessionController.unregisterTerminalSink(self)
            return
        }

        journalSessionController.registerTerminalSink(self, for: entryID)
        if isActive {
            reportTerminalSize()
        }
    }

    func disconnect() {
        journalSessionController.unregisterTerminalSink(self)
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 26
        layer?.cornerCurve = .continuous

        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
        ])

        rebuildTerminalView()
        applySurfaceStyle()
        updateStatusLabel()
    }

    func resetTerminalTranscript() {
        guard let terminalView else {
            return
        }
        terminalView.terminal.resetToInitialState()
        terminalView.needsDisplay = true
        if isActiveSurface {
            reportTerminalSize()
        }
    }

    func appendTerminal(bytes: ArraySlice<UInt8>) {
        terminalView?.feed(byteArray: bytes)
    }

    private func rebuildTerminalView() {
        if let terminalView {
            terminalView.terminalDelegate = self
            terminalView.terminal.resetToInitialState()
            terminalView.needsDisplay = true
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                if self.isActiveSurface {
                    self.reportTerminalSize()
                }
            }
            return
        }

        let terminal = TerminalView(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.terminalDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        terminal.linkReporting = .implicit
        terminal.optionAsMetaKey = true
        terminal.allowMouseReporting = true
        terminal.wantsLayer = true

        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])

        terminalView = terminal
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if self.isActiveSurface {
                self.reportTerminalSize()
            }
        }
    }

    private func updateStatusLabel() {
        if let entryID = currentEntryID {
            let token = entryID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            statusLabel.stringValue = "\(entryTitle)  ·  live terminal  ·  \(token.prefix(12))"
        } else {
            statusLabel.stringValue = "\(entryTitle)  ·  live terminal"
        }
    }

    private func applySurfaceStyle() {
        guard let terminalView else {
            return
        }

        switch surfaceStyle {
        case .terminal:
            layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 0.98).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
            statusLabel.textColor = NSColor.white.withAlphaComponent(0.7)
            statusLabel.isHidden = false
            terminalView.nativeBackgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
            terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.95, alpha: 1)
            terminalView.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).cgColor
            terminalView.layer?.isOpaque = true
            terminalView.caretColor = NSColor(calibratedWhite: 0.95, alpha: 1)
            terminalView.caretTextColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
        case .notebook:
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
            statusLabel.textColor = NSColor.clear
            statusLabel.isHidden = true
            terminalView.nativeBackgroundColor = NSColor.clear
            terminalView.nativeForegroundColor = NSColor(ArchiveTheme.ink)
            terminalView.layer?.backgroundColor = NSColor.clear.cgColor
            terminalView.layer?.isOpaque = false
            terminalView.caretColor = NSColor(ArchiveTheme.ink)
            terminalView.caretTextColor = NSColor.clear
        }

        terminalView.needsDisplay = true
    }

    private func reportTerminalSize() {
        guard let terminalView else {
            return
        }
        let frame = terminalView.frame
        journalSessionController.updateTerminalWindowSize(
            cols: terminalView.terminal.cols,
            rows: terminalView.terminal.rows,
            pixelWidth: Int(frame.width),
            pixelHeight: Int(frame.height)
        )
    }

    override func layout() {
        super.layout()
        if isActiveSurface {
            reportTerminalSize()
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard isActiveSurface else {
            return
        }
        let frame = source.frame
        journalSessionController.updateTerminalWindowSize(
            cols: newCols,
            rows: newRows,
            pixelWidth: Int(frame.width),
            pixelHeight: Int(frame.height)
        )
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        journalSessionController.sendTerminalInput(data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
