import AppKit
import Carbon
import SeeYourUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var items: [UsageProvider: UsageMenuItemController] = [:]
    private var settingsWindow: NSWindow?
    private var settingsButtons: [UsageProvider: NSButton] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        ServicePreferences.shared.prepareForLaunch(isLogin: loginLaunch)
        try? LoginItemController().setEnabled(ServicePreferences.shared.needsLoginItem)
        NotificationCenter.default.addObserver(self, selector: #selector(reconcileItems), name: ServicePreferences.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showServices), name: .showUsageServices, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(platformChanged), name: .llmPlatformChanged, object: nil)
        reconcileItems()
        if items.isEmpty && !loginLaunch { showServices() }
    }

    @objc private func platformChanged() {
        items.removeValue(forKey: .llmCenter)?.stop()
        reconcileItems()
    }

    @objc private func reconcileItems() {
        for provider in UsageProvider.allCases {
            let visible = ServicePreferences.shared.isVisible(provider)
            if visible && items[provider] == nil {
                let item = UsageMenuItemController(provider: provider)
                items[provider] = item
                item.start()
            } else if !visible, let item = items.removeValue(forKey: provider) { item.stop() }
            settingsButtons[provider]?.state = visible ? .on : .off
        }
        // Hiding both services must never strand the user without a recovery UI.
        if items.isEmpty && NSApp.isActive { showServices() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showServices()
        return true
    }

    @objc private func showServices() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 310, height: 155), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "see-your-usage · 服务"
            window.isReleasedWhenClosed = false
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 16
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(stack)
            for provider in UsageProvider.allCases {
                let button = NSButton(checkboxWithTitle: "启动并显示 \(provider.title)", target: self, action: #selector(toggleService(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
                button.state = ServicePreferences.shared.isVisible(provider) ? .on : .off
                stack.addArrangedSubview(button)
                settingsButtons[provider] = button
            }
            let caption = NSTextField(labelWithString: "关闭后停止该服务的后台刷新。")
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            stack.addArrangedSubview(caption)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleService(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let provider = UsageProvider(rawValue: raw) else { return }
        ServicePreferences.shared.setVisible(sender.state == .on, for: provider)
    }

    func applicationWillTerminate(_ notification: Notification) {
        items.values.forEach { $0.stop() }
    }
}

@MainActor
final class UsageMenuItemController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private lazy var coordinator = RefreshCoordinator(store: store)
    private lazy var statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: StatusItemRenderer.size.width)
        item.autosaveName = store.state.provider == .codex ? "main-status-item" : "llm-center-status-item"
        item.behavior = []
        return item
    }()
    private let popover = NSPopover()
    private var observerID: UUID?
    private var eventMonitors: [Any] = []

    init(provider: UsageProvider) {
        store = UsageStore(initialState: UsageViewState(provider: provider))
        super.init()
    }

    func start() {
        configureStatusItem()
        configurePopover()
        observerID = store.observe { [weak self] state in self?.updateStatusItem(state) }
        coordinator.start()
    }

    func stop() {
        popover.performClose(nil)
        coordinator.stop()
        removeEventMonitors()
        if let observerID { store.removeObserver(observerID) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        statusItem.length = StatusItemRenderer.size.width
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover)
        button.toolTip = "see-your-usage"
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItem(store.state)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = DashboardViewController.preferredContentSize(for: store.state)
        popover.contentViewController = DashboardViewController(store: store, coordinator: coordinator)
    }

    private func updateStatusItem(_ state: UsageViewState) {
        guard let button = statusItem.button else { return }
        popover.contentSize = DashboardViewController.preferredContentSize(for: state)
        button.image = StatusItemRenderer.image(for: state, appearance: button.effectiveAppearance)
        statusItem.length = StatusItemRenderer.size(for: state).width
        if state.provider == .llmCenter {
            let quota = state.quota
            let remaining = quota.flatMap { $0.isCurrentMonth() ? QuotaFormatting.amount($0.monthlyRemaining) : nil } ?? "—"
            let today = quota.flatMap { $0.isCurrentDay() ? QuotaFormatting.today($0.todayUsed) : nil } ?? "—"
            let timestamp = quota.map { "\n上次更新 " + QuotaFormatting.timestamp($0.refreshedAt, format: "M/d HH:mm") } ?? ""
            let status = state.isPaused ? " · 已暂停" : (state.errorMessage == nil ? "" : " · 未更新")
            button.toolTip = "LLM Center\(status) · 本月剩余 \(remaining) · 今日已用 \(today)\(timestamp)"
            if let prompt = state.menuPrompt {
                button.toolTip = prompt.0 + " " + prompt.1 + (state.errorMessage.map { "\n" + $0 } ?? "")
            }
            button.setAccessibilityLabel(button.toolTip)
        } else { button.toolTip = "see-your-usage · Codex" }
        button.needsDisplay = true
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePopover()
            let menu = NSMenu()
            let label = NSMenuItem(title: store.state.provider.title, action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
            if store.state.provider == .llmCenter {
                let login = NSMenuItem(title: "登录 / 切换 LLM Center 账号…", action: #selector(loginLLM), keyEquivalent: "")
                login.target = self
                menu.addItem(login)
            }
            let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshUsage), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出 see-your-usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            quit.target = NSApp
            menu.addItem(quit)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            return
        }
        if popover.isShown {
            closePopover()
        } else {
            coordinator.refreshIfUsefulForPopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installEventMonitors()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeEventMonitors()
    }

    @objc private func refreshUsage() { coordinator.refreshNow() }

    @objc private func loginLLM() { coordinator.login() }

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

extension Notification.Name {
    static let llmPlatformChanged = Notification.Name("see-your-usage.platform-changed")
    static let showUsageServices = Notification.Name("see-your-usage.show-services")
}
