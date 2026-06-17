import AppKit
import MindYourUsageCore

@MainActor
final class DashboardViewController: NSViewController {
    private let store: UsageStore
    private let coordinator: RefreshCoordinator
    private let loginItemController = LoginItemController()
    private var observerID: UUID?

    private let titleLabel = NSTextField(labelWithString: "see-your-usage")
    private let subtitleLabel = NSTextField(labelWithString: "Not refreshed yet")
    private let refreshButton = NSButton()
    private let pauseButton = NSButton()
    private let fiveHourPanel = UsagePanelView()
    private let sevenDayPanel = UsagePanelView()
    private let detailsLabel = NSTextField(labelWithString: "")
    private let openAtLoginSwitch = BlueSwitch()
    private let errorLabel = NSTextField(labelWithString: "")

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
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 374))
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
            $0.widthAnchor.constraint(equalToConstant: 328).isActive = true
            $0.heightAnchor.constraint(equalToConstant: 86).isActive = true
            stack.addArrangedSubview($0)
        }

        detailsLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.maximumNumberOfLines = 2
        detailsLabel.lineBreakMode = .byWordWrapping
        detailsLabel.translatesAutoresizingMaskIntoConstraints = false
        detailsLabel.widthAnchor.constraint(equalToConstant: 328).isActive = true
        stack.addArrangedSubview(detailsLabel)

        stack.addArrangedSubview(makeLoginItemRow())

        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.widthAnchor.constraint(equalToConstant: 328).isActive = true
        stack.addArrangedSubview(errorLabel)

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

    override func viewWillAppear() {
        super.viewWillAppear()
        coordinator.refreshNow()
    }

    private func makeHeader() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 328).isActive = true
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
        container.widthAnchor.constraint(equalToConstant: 328).isActive = true
        container.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        let refreshNowButton = NSButton(title: "Refresh now", target: self, action: #selector(refreshNow))
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
        container.widthAnchor.constraint(equalToConstant: 328).isActive = true
        container.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let label = NSTextField(labelWithString: "Open at Login")
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
        let snapshot = state.snapshot
        subtitleLabel.stringValue = UsageFormatting.lastRefreshText(snapshot?.fetchedAt)

        refreshButton.isEnabled = !state.isRefreshing
        openAtLoginSwitch.state = loginItemController.isEnabled ? .on : .off
        let pauseSymbol = state.isPaused ? "play.fill" : "pause.fill"
        pauseButton.image = NSImage(systemSymbolName: pauseSymbol, accessibilityDescription: state.isPaused ? "Resume" : "Pause")
        pauseButton.toolTip = state.isPaused ? "Resume" : "Pause"

        let fiveHour = snapshot?.window(kind: .fiveHour)
        let sevenDay = snapshot?.window(kind: .sevenDay)
        fiveHourPanel.usageWindow = fiveHour
        sevenDayPanel.usageWindow = sevenDay
        fiveHourPanel.subtitle = fiveHour.map { "Used \(UsageFormatting.percent($0.usedPercent))" } ?? ""
        sevenDayPanel.subtitle = sevenDay.map { "Used \(UsageFormatting.percent($0.usedPercent))" } ?? ""

        if let snapshot {
            let plan = snapshot.planType?.capitalized ?? "Codex"
            let resetCredits = snapshot.resetCreditsAvailable.map { "\($0) reset credits" } ?? "No reset credit info"
            let creditBalance = snapshot.credits?.balance.map { "balance \($0)" } ?? "credits unavailable"
            detailsLabel.stringValue = "\(plan) · \(resetCredits) · \(creditBalance)"
        } else {
            detailsLabel.stringValue = "Waiting for Codex usage data"
        }

        errorLabel.stringValue = state.errorMessage ?? ""
        errorLabel.isHidden = state.errorMessage == nil
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

    @objc private func toggleOpenAtLogin() {
        do {
            try loginItemController.setEnabled(openAtLoginSwitch.state == .on)
        } catch {
            openAtLoginSwitch.state = loginItemController.isEnabled ? .on : .off
            errorLabel.stringValue = "Open at Login could not be changed."
            errorLabel.isHidden = false
        }
    }
}
