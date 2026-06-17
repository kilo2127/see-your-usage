import Foundation
import MindYourUsageCore

@MainActor
final class RefreshCoordinator {
    private let store: UsageStore
    private let service: CodexUsageService
    private var timer: Timer?
    private var failureCount = 0

    private let normalRefreshInterval: TimeInterval = 10 * 60
    private let minimumRefreshInterval: TimeInterval = 60
    private let resetRefreshGrace: TimeInterval = 10

    init(store: UsageStore, service: CodexUsageService = CodexUsageService()) {
        self.store = store
        self.service = service
    }

    func start() {
        refreshNow()
    }

    func refreshNow() {
        refresh(isManual: true)
    }

    func refreshIfUsefulForPopover() {
        guard !store.state.isPaused else { return }
        guard !store.state.isRefreshing else { return }
        if let lastRefresh = store.state.lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 {
            return
        }
        refresh(isManual: true)
    }

    func togglePaused() {
        setPaused(!store.state.isPaused)
    }

    func setPaused(_ isPaused: Bool) {
        store.setPaused(isPaused)
        if isPaused {
            timer?.invalidate()
            timer = nil
        } else {
            refreshNow()
        }
    }

    private func refresh(isManual: Bool) {
        guard !store.state.isRefreshing else { return }
        guard isManual || !store.state.isPaused else { return }

        timer?.invalidate()
        timer = nil
        store.setRefreshing(true)

        Task {
            do {
                let snapshot = try await service.fetchUsage()
                failureCount = 0
                store.setSnapshot(snapshot)
            } catch {
                failureCount += 1
                store.setError(error)
            }
            store.setRefreshing(false)
            scheduleNextRefresh()
        }
    }

    private func scheduleNextRefresh() {
        timer?.invalidate()
        timer = nil

        guard !store.state.isPaused else { return }

        let interval = nextRefreshInterval()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(isManual: false)
            }
        }
        timer.tolerance = min(90, max(10, interval * 0.15))
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func nextRefreshInterval() -> TimeInterval {
        if failureCount > 0 {
            let backoff = pow(2, Double(min(failureCount - 1, 4))) * 5 * 60
            return min(60 * 60, max(minimumRefreshInterval, backoff))
        }

        guard let snapshot = store.state.snapshot else {
            return minimumRefreshInterval
        }

        let now = Date()
        let soonestReset = snapshot.windows
            .compactMap(\.resetAt)
            .map { $0.timeIntervalSince(now) + resetRefreshGrace }
            .filter { $0 > minimumRefreshInterval }
            .min()

        if let soonestReset {
            return min(normalRefreshInterval, soonestReset)
        }

        return normalRefreshInterval
    }
}
