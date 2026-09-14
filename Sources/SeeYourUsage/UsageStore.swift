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
    var isRefreshing: Bool = false
    var isPaused: Bool = false
    var errorMessage: String?
    var needsLogin = false
    var keychainBlocked = false
    var needsConfiguration = false
    var isLoggingIn = false
    var loginMessage: String?

    var menuPrompt: (String, String)? {
        guard provider == .llmCenter else { return nil }
        if needsConfiguration { return ("配置", "LLM Center") }
        if isLoggingIn { return ("正在登录", "LLM Center") }
        if quota == nil && isRefreshing { return ("连接中", "LLM Center") }
        if quota == nil || needsLogin || errorMessage != nil { return ("登录", "LLM Center") }
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
    private var observers: [UUID: Observer] = [:]

    init(initialState: UsageViewState = UsageViewState()) { state = initialState }

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
        state.needsConfiguration = (error as? LLMCenterError) == .configurationRequired
        state.keychainBlocked = (error as? LLMCenterError) == .keychainUnavailable
        state.needsLogin = (error as? LLMCenterError) == .loginRequired || state.keychainBlocked
        if state.provider == .llmCenter, error is URLError {
            state.errorMessage = "暂时无法连接平台，请检查公司内网。保留上次数据。"
        } else {
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        notify()
    }

    func setQuota(_ quota: LLMQuotaSnapshot) {
        state.needsConfiguration = false
        state.quota = quota
        state.needsLogin = false
        state.keychainBlocked = false
        state.errorMessage = nil
        notify()
    }

    func clearQuota() {
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
