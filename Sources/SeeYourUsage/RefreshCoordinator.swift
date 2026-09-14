import AppKit
import SeeYourUsageCore

@MainActor
final class RefreshCoordinator {
    private let store: UsageStore
    private let service: CodexUsageService
    private let llmService = LLMCenterService()
    private var timer: Timer?
    private var requestTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var failureCount = 0
    private var lastAttempt: Date?
    private var nextAttempt: Date?
    private var sleeping = false
    private var generation = UUID()

    init(store: UsageStore, service: CodexUsageService = CodexUsageService()) {
        self.store = store
        self.service = service
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private var mayAutoLogin = false

    func start() {
        mayAutoLogin = store.state.provider == .llmCenter
        refreshNow()
    }

    func refreshNow() {
        guard !store.state.isLoggingIn else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 5 { return }
        refresh()
    }

    func refreshIfUsefulForPopover() {
        store.redraw()
        guard !store.state.isPaused, !store.state.needsLogin, !store.state.isLoggingIn else { return }
        if failureCount > 0, let nextAttempt, Date() < nextAttempt { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 60 { return }
        refresh()
    }

    func togglePaused() {
        store.setPaused(!store.state.isPaused)
        if store.state.isPaused {
            timer?.invalidate()
            timer = nil
            cancelRequests()
            cancelLogin()
        } else {
            lastAttempt = nil
            refreshNow()
        }
    }

    func login() {
        if store.state.isLoggingIn { cancelLogin(); return }
        guard store.state.provider == .llmCenter else { return }
        cancelRequests()
        timer?.invalidate()
        timer = nil
        store.setLogin(active: true, message: "正在打开浏览器授权…")
        loginTask = Task {
            do {
                let login = try await llmService.beginLogin()
                try Task.checkCancellation()
                guard NSWorkspace.shared.open(login.url) else { throw LLMCenterError.unsafeURL }
                store.setLogin(active: true, message: "请在浏览器完成授权；可点击取消。")
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(login.pollInterval))
                    if let token = try await llmService.pollLogin(login) {
                        try Task.checkCancellation()
                        let saved = try llmService.tokens.save(token)
                        store.clearQuota()
                        store.setLogin(active: false, message: saved ? nil : "本次已登录；凭证未保存，重启后需重新登录。")
                        failureCount = 0
                        lastAttempt = nil
                        loginTask = nil
                        refreshNow()
                        return
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                store.setLogin(active: false)
                store.setError(error)
            }
            loginTask = nil
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        store.setLogin(active: false)
        scheduleNextRefresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelRequests()
        loginTask?.cancel()
        loginTask = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func cancelRequests() {
        generation = UUID()
        requestTask?.cancel()
        requestTask = nil
        store.setRefreshing(false)
    }

    private func refresh() {
        guard !sleeping, !store.state.isRefreshing, !store.state.isLoggingIn else { return }
        timer?.invalidate()
        timer = nil
        lastAttempt = Date()
        store.setRefreshing(true)
        let current = generation
        let provider = store.state.provider
        requestTask = Task {
            do {
                if provider == .llmCenter {
                    let quota = try await llmService.fetchUsage()
                    guard !Task.isCancelled, current == generation else { return }
                    store.setQuota(quota)
                } else {
                    let snapshot = try await service.fetchUsage()
                    guard !Task.isCancelled, current == generation else { return }
                    store.setSnapshot(snapshot)
                }
                failureCount = 0
            } catch {
                guard !Task.isCancelled, current == generation else { return }
                failureCount += 1
                store.setError(error)
            }
            requestTask = nil
            store.setRefreshing(false)
            // Try existing credentials first. Open authorization only once per launch,
            // and only for an authentication failure, never repeatedly on a VPN outage.
            let autoLogin = mayAutoLogin && store.state.needsLogin && !store.state.keychainBlocked
            mayAutoLogin = false
            if autoLogin { login() } else { scheduleNextRefresh() }
        }
    }

    private func scheduleNextRefresh() {
        timer?.invalidate()
        timer = nil
        guard !sleeping, !store.state.isPaused, !store.state.needsLogin,
              !store.state.isLoggingIn, !store.state.needsConfiguration else { return }
        let interval: TimeInterval
        if failureCount > 0 {
            interval = min(3600, pow(2, Double(min(failureCount - 1, 4))) * 300)
        } else {
            let normal: TimeInterval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 600 : 300
            var resets: [Date] = []
            if store.state.provider == .llmCenter {
                if let next = store.state.quota?.nextReset { resets.append(next) }
                if let midnight = LLMQuotaSnapshot.calendar.date(byAdding: .day, value: 1, to: LLMQuotaSnapshot.calendar.startOfDay(for: Date())) { resets.append(midnight) }
            } else {
                resets = store.state.snapshot?.windows.compactMap(\.resetAt) ?? []
            }
            let next = resets.map { $0.timeIntervalSinceNow + 5 }.filter { $0 > 0 }.min() ?? normal
            interval = max(5, min(normal, next))
        }
        nextAttempt = Date().addingTimeInterval(interval)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = min(60, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func willSleep() {
        sleeping = true
        timer?.invalidate()
        timer = nil
        cancelRequests()
        cancelLogin()
    }

    @objc private func didWake() {
        sleeping = false
        store.redraw()
        scheduleNextRefresh()
        if !store.state.isPaused, !store.state.needsLogin, failureCount == 0,
           lastAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
            timer?.fireDate = Date().addingTimeInterval(10)
        }
    }
}
