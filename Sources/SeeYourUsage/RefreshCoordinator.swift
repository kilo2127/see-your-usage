import AppKit
import OSLog
import SeeYourUsageCore

@MainActor
final class RefreshCoordinator {
    private let store: UsageStore
    private let service: CodexUsageService
    private let llmService: LLMCenterService
    private var timer: Timer?
    private var requestTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.leung.see-your-usage", category: "Login")
    private var failureCount = 0
    private var lastAttempt: Date?
    private var nextAttempt: Date?
    private var sleeping = false
    private var generation = UUID()

    init(store: UsageStore, service: CodexUsageService = CodexUsageService(), llmService: LLMCenterService = LLMCenterService()) {
        self.store = store
        self.service = service
        self.llmService = llmService
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func start() {
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

    enum LoginSource: String { case dashboard, statusMenu }

    func login(source: LoginSource) {
        if store.state.isLoggingIn { cancelLogin(); return }
        guard store.state.provider == .llmCenter else { return }
        cancelRequests()
        timer?.invalidate()
        timer = nil
        guard LLMCenterConfiguration.baseURL != nil else {
            store.setError(LLMCenterError.configurationRequired)
            return
        }
        logger.notice("Browser authorization requested: \(source.rawValue, privacy: .public)")
        store.setLogin(active: true, message: "正在打开 Safari…")
        loginTask = Task {
            do {
                let login = try await llmService.beginLogin()
                let previousURL = try? await llmService.authentication.browserAuthorizationURL(origin: login.origin)
                try Task.checkCancellation()
                let linked = try await SafariLogin.open(login.url, previousURL: previousURL)
                logger.notice("Safari authorization page opened")
                store.setLogin(active: true, message: "等待 Safari 授权…")
                let quota = try await llmService.completeBrowserLogin(login, keepAuthorizationTab: linked)
                try Task.checkCancellation()
                let saved = await llmService.authentication.credentialsArePersistent
                try Task.checkCancellation()
                store.setLogin(active: false, message: !saved ? "本次已登录；凭证未保存，重启后需重新登录。" :
                    (linked ? nil : "已登录；Safari 自动续期未启用。"))
                store.setQuota(quota)
                failureCount = 0
                lastAttempt = Date()
                loginTask = nil
                logger.notice("Browser authorization completed; persistent: \(saved, privacy: .public)")
                scheduleNextRefresh()
                return
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                store.setLogin(active: false)
                scheduleNextRefresh()
            } catch {
                guard !Task.isCancelled else { return }
                logger.notice("Browser authorization failed")
                store.setLogin(active: false)
                store.setError(error)
                failureCount += 1
                scheduleNextRefresh()
            }
            loginTask = nil
        }
    }

    func cancelLogin() {
        if loginTask != nil { logger.notice("Browser authorization cancelled") }
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
                    let logger = self.logger
                    let quota = try await llmService.fetchUsage(reconnect: { previous, next in
                        logger.notice("Safari session renewal requested after authentication rejection")
                        try await SafariLogin.reconnect(previousURL: previous, authorizationURL: next)
                        logger.notice("Temporary Safari authorization tab opened in background")
                    }, finishReconnect: { url in
                        await SafariLogin.finishReconnect(authorizationURL: url)
                        logger.notice("Temporary Safari authorization cleanup finished")
                    })
                    guard !Task.isCancelled, current == generation else { return }
                    store.setQuota(quota)
                    logger.notice("LLM quota refresh succeeded")
                } else {
                    let snapshot = try await service.fetchUsage()
                    guard !Task.isCancelled, current == generation else { return }
                    store.setSnapshot(snapshot)
                }
                failureCount = 0
            } catch {
                guard !Task.isCancelled, current == generation else { return }
                failureCount += 1
                if provider == .llmCenter {
                    let reason: String
                    switch error as? LLMCenterError {
                    case .loginRequired: reason = "login_required"
                    case .loginExpired: reason = "browser_authorization_expired"
                    case .browserAutomationRequired: reason = "safari_permission_missing"
                    case .browserTabMissing: reason = "safari_tab_missing"
                    case .http(let status): reason = "http_\(status)"
                    default: reason = "request_failed"
                    }
                    logger.error("LLM refresh failed: \(reason, privacy: .public)")
                }
                store.setError(error)
            }
            requestTask = nil
            store.setRefreshing(false)
            // Authentication failures stop scheduling until the user reconnects.
            scheduleNextRefresh()
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
