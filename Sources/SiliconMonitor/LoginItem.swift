import Foundation
import ServiceManagement

/// "Launch at login", through the system's login item API (the same list as System Settings > General > Login Items).
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var enabled = false
    /// Set when the system wants the user to approve the item, or when registering failed.
    @Published private(set) var note: String?

    private init() { refresh() }

    /// Re-read the system's state; the user can change it in System Settings behind the app's back.
    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            enabled = true
        case .requiresApproval:
            enabled = true
            note = "Approve SiliconMonitor in System Settings › General › Login Items."
        default:
            enabled = false
        }
    }

    func set(_ on: Bool) {
        note = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            note = "Couldn't change the login item: \(error.localizedDescription)"
        }
        let failure = note
        refresh()
        if let failure { note = failure }
    }
}
