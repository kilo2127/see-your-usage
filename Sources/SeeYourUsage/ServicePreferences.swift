import AppKit
import ServiceManagement

@MainActor
final class ServicePreferences {
    static let shared = ServicePreferences()
    static let changed = Notification.Name("see-your-usage.service-preferences")
    private let defaults: UserDefaults
    private(set) var loginSuppressed: Set<UsageProvider> = []

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isVisible(_ provider: UsageProvider) -> Bool {
        (defaults.object(forKey: key(provider, "visible")) as? Bool ?? true) && !loginSuppressed.contains(provider)
    }

    func startsAtLogin(_ provider: UsageProvider) -> Bool {
        defaults.object(forKey: key(provider, "login")) as? Bool ?? true
    }

    func prepareForLaunch(isLogin: Bool) {
        loginSuppressed = isLogin ? Set(UsageProvider.allCases.filter { !startsAtLogin($0) }) : []
    }

    var needsLoginItem: Bool {
        UsageProvider.allCases.contains {
            startsAtLogin($0) && (defaults.object(forKey: key($0, "visible")) as? Bool ?? true)
        }
    }

    func setVisible(_ visible: Bool, for provider: UsageProvider) {
        defaults.set(visible, forKey: key(provider, "visible"))
        loginSuppressed.remove(provider)
        try? LoginItemController().setEnabled(needsLoginItem)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func setStartsAtLogin(_ enabled: Bool, for provider: UsageProvider) throws {
        let old = defaults.object(forKey: key(provider, "login"))
        defaults.set(enabled, forKey: key(provider, "login"))
        do { try LoginItemController().setEnabled(needsLoginItem) }
        catch {
            if let old { defaults.set(old, forKey: key(provider, "login")) }
            else { defaults.removeObject(forKey: key(provider, "login")) }
            throw error
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private func key(_ provider: UsageProvider, _ field: String) -> String {
        "service.\(provider.rawValue).\(field)"
    }
}
