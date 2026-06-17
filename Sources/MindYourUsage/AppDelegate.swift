import AppKit
import MindYourUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private lazy var coordinator = RefreshCoordinator(store: store)
    private let statusItem = NSStatusBar.system.statusItem(withLength: StatusItemRenderer.size.width)
    private let popover = NSPopover()
    private var observerID: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()

        observerID = store.observe { [weak self] state in
            self?.updateStatusItem(state)
        }

        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observerID {
            store.removeObserver(observerID)
        }
    }

    private func configureStatusItem() {
        statusItem.length = StatusItemRenderer.size.width
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover)
        button.toolTip = "Codex usage"
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItem(store.state)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 342)
        popover.contentViewController = DashboardViewController(store: store, coordinator: coordinator)
    }

    private func updateStatusItem(_ state: UsageViewState) {
        guard let button = statusItem.button else { return }
        button.image = StatusItemRenderer.image(for: state, appearance: button.effectiveAppearance)
        button.needsDisplay = true
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            coordinator.refreshIfUsefulForPopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: false)
        }
    }
}
