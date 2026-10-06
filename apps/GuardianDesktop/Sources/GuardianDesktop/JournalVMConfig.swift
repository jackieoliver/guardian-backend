import Foundation

enum GuardianAppSupportPaths {
    static var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("GuardianDesktop", isDirectory: true)
    }
}

struct JournalLaunchConfiguration: Equatable {
    let displayName: String
    let shellCommand: String
    let terminalType: String
    let introMessages: [String]

    static let defaultDisplayName = "Guardian VM"
    static let defaultTerminalType = "xterm-256color"
    static let defaultIntroMessages = [
        "Synced files live under your runtime workspace.",
        "Guardian connects directly with your backend-assigned VM.",
    ]
}
