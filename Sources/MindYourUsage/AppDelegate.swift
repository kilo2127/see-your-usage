import AppKit
import MindYourUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private let loginItemController = LoginItemController()
    private lazy var coordinator = RefreshCoordinator(store: store)
    private let statusItem = NSStatusBar.system.statusItem(withLength: StatusItemRenderer.size.width)
    private let popover = NSPopover()
    private var observerID: UUID?
    private var eventMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loginItemController.ensureDefaultEnabled()
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
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 374)
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
            closePopover()
        } else {
            coordinator.refreshNow()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installEventMonitors()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeEventMonitors()
    }

    private func closePopover() {
        popover.performClose(nil)
        removeEventMonitors()
    }

    private func installEventMonitors() {
        removeEventMonitors()

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                closePopover()
                return nil
            }
            guard let popoverWindow = popover.contentViewController?.view.window else { return event }
            if event.window !== popoverWindow {
                closePopover()
            }
            return event
        }) {
            eventMonitors.append(localMonitor)
        }

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }) {
            eventMonitors.append(globalMonitor)
        }
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }
}
