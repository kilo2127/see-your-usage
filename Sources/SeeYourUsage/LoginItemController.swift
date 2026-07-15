import Foundation
import ServiceManagement

@MainActor
final class LoginItemController {
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var isEnabled: Bool {
        guard isAvailable else { return true }
        return SMAppService.mainApp.status == .enabled
    }

    func ensureDefaultEnabled() {
        guard isAvailable else { return }
        guard SMAppService.mainApp.status == .notRegistered else { return }
        try? SMAppService.mainApp.register()
    }

    func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { return }
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
