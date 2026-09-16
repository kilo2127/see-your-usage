import AppKit
import SeeYourUsageCore

@MainActor
final class DashboardViewController: NSViewController {
    static let contentWidth: CGFloat = 340
    static let twoWindowHeight: CGFloat = 374
    static let oneWindowHeight: CGFloat = 276

    static func preferredContentSize(for state: UsageViewState) -> NSSize {
        if state.provider == .llmCenter {
            let login = state.showsLoginAction
            return NSSize(width: contentWidth, height: 450 + (login ? 40 : 0) + (state.errorMessage != nil || state.quota?.hasTeam == false ? 40 : 0))
        }
        let windowCount = state.snapshot?.windows.count ?? 1
        return NSSize(
            width: contentWidth,
            height: (windowCount > 1 ? twoWindowHeight : oneWindowHeight) + 42 + (state.errorMessage != nil ? 40 : 0)
        )
    }

    private let store: UsageStore
    private let coordinator: RefreshCoordinator
    private let preferences = ServicePreferences.shared
    private var observerID: UUID?

    private let titleLabel = NSTextField(labelWithString: "see-your-usage")
    private let subtitleLabel = NSTextField(labelWithString: "Not refreshed yet")
    private let refreshButton = NSButton()
    private let pauseButton = NSButton()
    private let fiveHourPanel = UsagePanelView()
    private let sevenDayPanel = UsagePanelView()
    private let detailsLabel = NSTextField(labelWithString: "")
    private let openAtLoginSwitch = BlueSwitch()
    private let visibleSwitch = BlueSwitch()
    private let addressButton = NSButton(title: "平台地址…", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let loginButton = NSButton(title: "登录 LLM Center", target: nil, action: nil)
    private let platformButton = NSButton()
    private var panelHeights: [NSLayoutConstraint] = []

    init(store: UsageStore, coordinator: RefreshCoordinator) {
        self.store = store
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let observerID {
            Task { @MainActor [store] in
                store.removeObserver(observerID)
            }
        }
    }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.contentWidth,
            height: Self.oneWindowHeight
        ))
        root.material = .menu
        root.blendingMode = .behindWindow
        root.state = .active
        root.isEmphasized = true
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 0.8
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -14)
        ])

        stack.addArrangedSubview(makeHeader())

        fiveHourPanel.title = "5-hour window"
        sevenDayPanel.title = "7-day window"
        [fiveHourPanel, sevenDayPanel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 308).isActive = true
            let height = $0.heightAnchor.constraint(equalToConstant: 86)
            height.isActive = true
            panelHeights.append(height)
            stack.addArrangedSubview($0)
        }

        detailsLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.maximumNumberOfLines = 2
        detailsLabel.lineBreakMode = .byWordWrapping
        detailsLabel.translatesAutoresizingMaskIntoConstraints = false
        detailsLabel.widthAnchor.constraint(equalToConstant: 308).isActive = true
        stack.addArrangedSubview(detailsLabel)

        stack.addArrangedSubview(makeVisibilityRow())
        stack.addArrangedSubview(makeLoginItemRow())
        addressButton.bezelStyle = .rounded
        addressButton.controlSize = .small
        addressButton.target = self
        addressButton.action = #selector(configurePlatform)
        stack.addArrangedSubview(addressButton)

        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.widthAnchor.constraint(equalToConstant: 308).isActive = true
        stack.addArrangedSubview(errorLabel)

        loginButton.bezelStyle = .rounded
        loginButton.target = self
        loginButton.action = #selector(login)
        loginButton.controlSize = .small
        stack.addArrangedSubview(loginButton)

        let footer = makeFooter()
        stack.addArrangedSubview(footer)

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observerID = store.observe { [weak self] state in
            self?.render(state)
        }
    }


    private func makeHeader() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 308).isActive = true
        container.heightAnchor.constraint(equalToConstant: 42).isActive = true

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        configureIconButton(refreshButton, symbol: "arrow.clockwise", tooltip: "Refresh now", action: #selector(refreshNow))
        configureIconButton(pauseButton, symbol: "pause.fill", tooltip: "Pause", action: #selector(togglePaused))
        container.addSubview(refreshButton)
        container.addSubview(pauseButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -6),
            refreshButton.topAnchor.constraint(equalTo: container.topAnchor),
            pauseButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pauseButton.topAnchor.constraint(equalTo: container.topAnchor)
        ])

        return container
    }

    private func makeFooter() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 308).isActive = true
        container.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let quitButton = NSButton(title: "服务…", target: self, action: #selector(showServices))
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        let refreshNowButton = platformButton
        refreshNowButton.title = "打开 LLM Center ↗"
        refreshNowButton.target = self
        refreshNowButton.action = #selector(openPlatform)
        refreshNowButton.bezelStyle = .rounded
        refreshNowButton.controlSize = .small
        refreshNowButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(quitButton)
        container.addSubview(refreshNowButton)

        NSLayoutConstraint.activate([
            quitButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            quitButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            refreshNowButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            refreshNowButton.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    private func makeLoginItemRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 308).isActive = true
        container.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let label = NSTextField(labelWithString: "开机启动此服务")
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        openAtLoginSwitch.target = self
        openAtLoginSwitch.action = #selector(toggleOpenAtLogin)
        openAtLoginSwitch.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(openAtLoginSwitch)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            openAtLoginSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            openAtLoginSwitch.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func render(_ state: UsageViewState) {
        addressButton.isHidden = store.state.provider != .llmCenter
        titleLabel.stringValue = state.provider == .llmCenter ? "LLM Center" : "see-your-usage"
        platformButton.title = state.provider == .llmCenter ? "打开 LLM Center ↗" : "打开 Codex 用量 ↗"
        loginButton.isHidden = !state.showsLoginAction
        loginButton.title = state.needsConfiguration ? "设置平台地址" : (state.isLoggingIn ? "取消登录" : "在 Safari 中登录")
        if state.provider == .llmCenter { renderQuota(state); return }
        detailsLabel.isHidden = false
        for (index, panel) in [fiveHourPanel, sevenDayPanel].enumerated() {
            panel.isQuota = false
            panelHeights[index].constant = 86
        }
        fiveHourPanel.title = "5-hour window"
        sevenDayPanel.title = "7-day window"
        let snapshot = state.snapshot
        subtitleLabel.stringValue = UsageFormatting.lastRefreshText(snapshot?.fetchedAt)

        refreshButton.isEnabled = !state.isRefreshing
        openAtLoginSwitch.state = preferences.startsAtLogin(store.state.provider) ? .on : .off
        visibleSwitch.state = preferences.isVisible(store.state.provider) ? .on : .off
        let pauseSymbol = state.isPaused ? "play.fill" : "pause.fill"
        pauseButton.image = NSImage(systemSymbolName: pauseSymbol, accessibilityDescription: state.isPaused ? "Resume" : "Pause")
        pauseButton.toolTip = state.isPaused ? "Resume" : "Pause"

        let fiveHour = snapshot?.window(kind: .fiveHour)
        let sevenDay = snapshot?.window(kind: .sevenDay)
        fiveHourPanel.isHidden = fiveHour == nil
        sevenDayPanel.isHidden = snapshot != nil && sevenDay == nil
        fiveHourPanel.usageWindow = fiveHour
        sevenDayPanel.usageWindow = sevenDay
        fiveHourPanel.subtitle = fiveHour.map { "Used \(UsageFormatting.percent($0.usedPercent))" } ?? ""
        sevenDayPanel.subtitle = sevenDay.map { "Used \(UsageFormatting.percent($0.usedPercent))" } ?? ""

        if let snapshot {
            let plan = snapshot.planType?.capitalized ?? "Codex"
            var details = [plan]
            if let resetCredits = snapshot.resetCreditsAvailable {
                details.append("\(resetCredits) reset credits")
            }
            if let balance = snapshot.credits?.balance {
                details.append("balance \(balance)")
            }
            detailsLabel.stringValue = details.joined(separator: " · ")
        } else {
            detailsLabel.stringValue = "Waiting for Codex usage data"
        }

        errorLabel.stringValue = state.errorMessage ?? ""
        errorLabel.isHidden = state.errorMessage == nil
    }

    private func renderQuota(_ state: UsageViewState) {
        let quota = state.quota
        let time = quota.map { "上次更新 " + QuotaFormatting.timestamp($0.refreshedAt, format: "M/d HH:mm") } ?? "等待获取额度"
        subtitleLabel.stringValue = state.loginMessage ?? ("see-your-usage · " + (state.isPaused ? "已暂停" : time))
        subtitleLabel.toolTip = subtitleLabel.stringValue
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        refreshButton.isEnabled = !state.isRefreshing && !state.isLoggingIn
        openAtLoginSwitch.state = preferences.startsAtLogin(store.state.provider) ? .on : .off
        visibleSwitch.state = preferences.isVisible(store.state.provider) ? .on : .off
        pauseButton.image = NSImage(systemSymbolName: state.isPaused ? "play.fill" : "pause.fill", accessibilityDescription: state.isPaused ? "恢复刷新" : "暂停刷新")
        pauseButton.toolTip = state.isPaused ? "恢复刷新" : "暂停刷新"
        refreshButton.toolTip = "立即刷新"
        detailsLabel.isHidden = true
        fiveHourPanel.isHidden = false
        sevenDayPanel.isHidden = false
        fiveHourPanel.isQuota = true
        sevenDayPanel.isQuota = true
        fiveHourPanel.isToday = true
        sevenDayPanel.isToday = false
        panelHeights[0].constant = 78
        panelHeights[1].constant = 118
        fiveHourPanel.title = "今日已用"
        sevenDayPanel.title = "本月剩余"
        fiveHourPanel.quotaAmount = quota.flatMap { $0.isCurrentDay() ? QuotaFormatting.today($0.todayUsed) : nil }
        sevenDayPanel.quotaAmount = quota.flatMap { $0.isCurrentMonth() ? QuotaFormatting.amount($0.monthlyRemaining) : nil }
        sevenDayPanel.monthlyRemaining = quota.flatMap { $0.isCurrentMonth() ? $0.monthlyRemaining : nil }
        sevenDayPanel.quotaPercent = quota.flatMap { $0.isCurrentMonth() ? $0.remainingPercent : nil }
        sevenDayPanel.quotaCaption = quota.map {
            $0.isCurrentMonth() ? "已用 \(QuotaFormatting.amount($0.monthlyUsed)) / 月度额度 \(QuotaFormatting.amount($0.monthlyLimit))" : "数据已跨月，等待刷新本月额度"
        } ?? "登录后显示个人月度额度"
        sevenDayPanel.quotaFooter = quota.map {
            let reset = $0.nextReset.map { QuotaFormatting.timestamp($0, format: "M 月 d 日") + "重置" } ?? "重置时间未返回"
            return String(format: "剩余 %.1f%% · ", $0.remainingPercent) + reset
        } ?? ""
        fiveHourPanel.quotaCaption = quota?.isCurrentDay() == false ? "已跨日，等待刷新今日用量" : "今日 00:00 至今"
        for panel in [fiveHourPanel, sevenDayPanel] {
            panel.setAccessibilityElement(true)
            panel.setAccessibilityRole(.staticText)
            panel.setAccessibilityLabel(panel.title)
            panel.setAccessibilityValue((panel.quotaAmount ?? "待更新") + "，" + panel.quotaCaption)
            panel.toolTip = panel.quotaCaption
        }
        var message = state.errorMessage
        if message == nil, quota?.hasTeam == false { message = "尚未加入团队，请联系团队负责人分配额度。" }
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
    }

    @objc private func login() {
        if store.state.needsConfiguration { configurePlatform() } else { coordinator.login(source: .dashboard) }
    }

    @objc private func openPlatform() {
        let url = store.state.provider == .llmCenter ? LLMCenterService.baseURL : URL(string: "https://chatgpt.com/codex/settings/usage")!
        if let url { NSWorkspace.shared.open(url) } else { configurePlatform() }
    }

    @objc private func refreshNow() {
        coordinator.refreshNow()
    }

    @objc private func togglePaused() {
        coordinator.togglePaused()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func configurePlatform() {
        let alert = NSAlert()
        alert.messageText = "LLM Center 平台地址"
        alert.informativeText = "填写公司的 HTTPS 平台地址。此设置只保存在本机；更改地址后需要重新登录。"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 310, height: 24))
        input.stringValue = LLMCenterConfiguration.baseURL?.absoluteString ?? ""
        input.placeholderString = "https://your-platform.example"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = LLMCenterConfiguration.validatedURL(input.stringValue) else {
            let error = NSAlert()
            error.messageText = "请输入有效的 HTTPS 根地址"
            error.informativeText = "地址不能包含账号、密码、查询参数或页面路径。"
            error.runModal()
            return
        }
        guard url != LLMCenterConfiguration.baseURL else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: LLMCenterConfiguration.defaultsKey)
        NotificationCenter.default.post(name: .llmPlatformChanged, object: nil)
    }

    @objc private func toggleOpenAtLogin() {
        do { try preferences.setStartsAtLogin(openAtLoginSwitch.state == .on, for: store.state.provider) }
        catch {
            openAtLoginSwitch.state = preferences.startsAtLogin(store.state.provider) ? .on : .off
            errorLabel.stringValue = "无法修改开机启动，请检查系统登录项设置。"
            errorLabel.isHidden = false
        }
    }

    @objc private func showServices() {
        NotificationCenter.default.post(name: .showUsageServices, object: nil)
    }

    @objc private func toggleVisible() {
        preferences.setVisible(visibleSwitch.state == .on, for: store.state.provider)
    }

    private func makeVisibilityRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 308).isActive = true
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let label = NSTextField(labelWithString: "启动并在菜单栏显示")
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        visibleSwitch.target = self
        visibleSwitch.action = #selector(toggleVisible)
        row.addArrangedSubview(label)
        row.addArrangedSubview(visibleSwitch)
        return row
    }
}
