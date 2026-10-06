import Foundation
import GuardianDesktopCore
import Observation

@Observable
@MainActor
final class MockModeController {
    var isEnabled = false
    var isLoading = false
    var lastError: String?

    func setEnabled(
        _ enabled: Bool,
        model: ArchiveViewModel,
        inventoryStore: SourceInventoryStore
    ) {
        Task {
            await applyModeChange(enabled: enabled, model: model, inventoryStore: inventoryStore)
        }
    }

    func refresh(
        model: ArchiveViewModel,
        inventoryStore: SourceInventoryStore
    ) {
        Task {
            await loadProjectionSnapshot(model: model, inventoryStore: inventoryStore)
        }
    }

    private func applyModeChange(
        enabled: Bool,
        model: ArchiveViewModel,
        inventoryStore: SourceInventoryStore
    ) async {
        if enabled {
            isEnabled = true
            lastError = nil
            model.usePrototypeDatabase()
            inventoryStore.replaceInventorySources(with: model.snapshot.inventorySources)
        } else {
            isEnabled = false
            lastError = nil
            model.restoreBuiltInSnapshot()
            inventoryStore.replaceInventorySources(with: model.snapshot.inventorySources)
        }
    }

    private func loadProjectionSnapshot(
        model: ArchiveViewModel,
        inventoryStore: SourceInventoryStore
    ) async {
        isLoading = true
        defer { isLoading = false }

        model.refresh()
        inventoryStore.replaceInventorySources(with: model.snapshot.inventorySources)
        isEnabled = model.dataSourceMode == .prototypeDatabase
        lastError = nil
    }
}
