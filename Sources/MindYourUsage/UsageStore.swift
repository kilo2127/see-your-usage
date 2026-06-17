import Foundation
import MindYourUsageCore

struct UsageViewState: Equatable {
    var snapshot: UsageSnapshot?
    var isRefreshing: Bool = false
    var isPaused: Bool = false
    var errorMessage: String?

    var lastRefresh: Date? {
        snapshot?.fetchedAt
    }
}

@MainActor
final class UsageStore {
    typealias Observer = (UsageViewState) -> Void

    private(set) var state = UsageViewState()
    private var observers: [UUID: Observer] = [:]

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
        state.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        notify()
    }

    private func notify() {
        for observer in observers.values {
            observer(state)
        }
    }
}
