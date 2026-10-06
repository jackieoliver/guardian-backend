import SwiftUI

struct SourceMenuCommands: Commands {
    @Bindable var inventoryStore: SourceInventoryStore

    var body: some Commands {
        CommandMenu("Sources") {
            Button("Add Source...") {
                inventoryStore.showAddSourceDialog()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Manage Sources...") {
                inventoryStore.showManageSourcesDialog()
            }
            .keyboardShortcut(",", modifiers: [.command, .option])
        }
    }
}
