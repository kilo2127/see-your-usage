import Foundation
import SeeYourUsageCore

enum UsageProvider: String, CaseIterable {
    case llmCenter, codex
    var title: String { self == .llmCenter ? "LLM Center" : "Codex" }
}

struct UsageViewState: Equatable {
    var provider: UsageProvider = .llmCenter
    var snapshot: UsageSnapshot?
    var quota: LLMQuotaSnapshot?
    var quotaScope: LLMQuotaScope = .personal
    var projectCode: String?
    var projects: [LLMProject] = []
    var needsProjectSelection = false
    var isRefreshing: Bool = false
    var isPaused: Bool = false
    var errorMessage: String?
    var needsLogin = false
    var keychainBlocked = false
    var needsConfiguration = false
    var isLoggingIn = false
    var loginMessage: String?

    var showsLoginAction: Bool {
        provider == .llmCenter && (needsConfiguration || needsLogin || isLoggingIn ||
            (quota == nil && errorMessage == nil && !isRefreshing && !needsProjectSelection))
    }

    var menuPrompt: (String, String)? {
        guard provider == .llmCenter else { return nil }
        if needsConfiguration { return ("配置", "LLM Center") }
        if isLoggingIn { return ("正在登录", "LLM Center") }
        if quota == nil && isRefreshing { return ("连接中", "LLM Center") }
        if needsProjectSelection { return ("选择项目", "LLM Center") }
        if needsLogin { return ("登录", "LLM Center") }
        if errorMessage != nil { return ("未更新", "LLM Center") }
        if quota == nil { return ("登录", "LLM Center") }
        return nil
    }

    var lastRefresh: Date? {
        provider == .llmCenter ? quota?.fetchedAt : snapshot?.fetchedAt
    }
}

@MainActor
final class UsageStore {
    typealias Observer = (UsageViewState) -> Void

    private(set) var state: UsageViewState
    private let defaults: UserDefaults
    private var observers: [UUID: Observer] = [:]

    init(initialState: UsageViewState = UsageViewState(), defaults: UserDefaults = .standard) {
        state = initialState
        self.defaults = defaults
    }

    static func savedState(provider: UsageProvider, defaults: UserDefaults = .standard) -> UsageViewState {
        UsageViewState(provider: provider,
            quotaScope: LLMQuotaScope(rawValue: defaults.string(forKey: "llm-center-quota-scope") ?? "") ?? .project,
            projectCode: defaults.string(forKey: projectPreferenceKey))
    }

    private static var projectPreferenceKey: String {
        "llm-center-project@" + (LLMCenterConfiguration.baseURL?.absoluteString ?? "unconfigured")
    }

    func selectQuota(scope: LLMQuotaScope, projectCode: String? = nil) {
        state.quotaScope = scope
        if let projectCode {
            state.projectCode = projectCode
            defaults.set(projectCode, forKey: Self.projectPreferenceKey)
        }
        state.quota = nil
        state.errorMessage = nil
        state.needsProjectSelection = false
        defaults.set(scope.rawValue, forKey: "llm-center-quota-scope")
        notify()
    }

    @discardableResult
    func observe(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(state)
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    func setRefreshing(_ isRefreshing: Bool) {
        state.isRefreshing = isRefreshing
        notify()
    }

    func setPaused(_ isPaused: Bool) {
        state.isPaused = isPaused
        notify()
    }

    func setSnapshot(_ snapshot: UsageSnapshot) {
        state.snapshot = snapshot
        state.errorMessage = nil
        notify()
    }

    func setError(_ error: Error) {
        if case let LLMCenterError.projectSelectionRequired(projects) = error {
            state.projects = projects
            state.needsProjectSelection = true
        }
        state.needsConfiguration = (error as? LLMCenterError) == .configurationRequired
        state.keychainBlocked = (error as? LLMCenterError) == .keychainUnavailable
        state.needsLogin = state.keychainBlocked || (error as? LLMCenterError).map {
            [LLMCenterError.loginRequired, .loginExpired, .browserAutomationRequired, .browserTabMissing].contains($0)
        } == true
        if state.provider == .llmCenter, let networkError = error as? URLError {
            switch networkError.code {
            case .secureConnectionFailed:
                state.errorMessage = "安全连接失败，请检查代理或公司网络。保留上次数据。"
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                state.errorMessage = "无法验证服务器证书，请检查系统时间或联系平台管理员。"
            case .timedOut:
                state.errorMessage = "连接平台超时，请稍后刷新。保留上次数据。"
            default:
                state.errorMessage = "暂时无法连接平台，请检查公司内网。保留上次数据。"
            }
        } else {
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        notify()
    }

    func setQuota(_ quota: LLMQuotaSnapshot) {
        state.needsConfiguration = false
        guard quota.scope == state.quotaScope else { return }
        state.quota = quota
        state.needsProjectSelection = false
        if quota.scope == .project {
            state.projects = quota.projects
            state.projectCode = quota.project?.appCode
            defaults.set(state.projectCode, forKey: Self.projectPreferenceKey)
        }
        state.needsLogin = false
        state.keychainBlocked = false
        state.errorMessage = nil
        notify()
    }

    func clearQuota() {
        state.projects = []
        state.projectCode = nil
        state.needsProjectSelection = false
        state.quota = nil
        state.errorMessage = nil
        state.needsLogin = false
        notify()
    }

    func setLogin(active: Bool, message: String? = nil) {
        state.isLoggingIn = active
        state.loginMessage = message
        notify()
    }

    func redraw() { notify() }

    private func notify() {
        for observer in observers.values {
            observer(state)
        }
    }
}
