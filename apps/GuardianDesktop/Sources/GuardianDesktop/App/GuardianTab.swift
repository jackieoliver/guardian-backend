import Foundation

enum GuardianTab: String, CaseIterable, Identifiable {
    case journal
    case inventory

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .journal:
            "Journal"
        case .inventory:
            "Inventory"
        }
    }
}
