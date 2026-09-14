import AppKit
import Foundation
import Testing
@testable import SeeYourUsage
@testable import SeeYourUsageCore

@Test @MainActor func dashboardLayoutAndMenuWidth() throws {
    _ = NSApplication.shared
    let store = UsageStore(initialState: UsageViewState(provider: .llmCenter))
    let now = Date()
    let iso = ISO8601DateFormatter()
    let payload: [String: Any] = [
        "code": 200, "data": ["hasDept": true, "monthlyLimit": "7000.00", "monthlyUsed": "1180.00",
        "monthlyRemaining": "5820.00", "todayUsed": "86.40", "refreshTime": iso.string(from: now),
        "nextResetTime": "2026-10-01 00:00:00"]
    ]
    store.setQuota(try LLMQuotaSnapshot.decode(JSONSerialization.data(withJSONObject: payload)))
    let coordinator = RefreshCoordinator(store: store)
    defer { coordinator.stop() }
    let controller = DashboardViewController(store: store, coordinator: coordinator)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: DashboardViewController.preferredContentSize(for: store.state)), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentViewController = controller
    controller.view.frame.size = DashboardViewController.preferredContentSize(for: store.state)
    controller.view.layoutSubtreeIfNeeded()
    let panels = controller.view.subviews.flatMap(\.subviews).compactMap { $0 as? UsagePanelView }
    #expect(panels.count == 2)
    #expect(panels.first?.quotaAmount == "¥5,820")
    #expect(panels.last?.quotaAmount == "¥86")
    #expect(panels.last?.quotaCaption == "今日 00:00 至今")
    #expect(StatusItemRenderer.size(for: store.state).width < 52)
    func verify(_ view: NSView) {
        for child in view.subviews where !child.isHidden {
            #expect(child.frame.width > 0)
            #expect(child.frame.height > 0)
            let alignment = child.alignmentRect(forFrame: child.frame)
            #expect(alignment.minY >= -1)
            #expect(alignment.maxY <= view.bounds.height + 1)
            verify(child)
        }
    }
    verify(controller.view)
    if let directory = ProcessInfo.processInfo.environment["SEE_USAGE_QA_DIR"] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            controller.view.appearance = NSAppearance(named: appearance)
            controller.view.needsDisplay = true
            let rep = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("dashboard-\(name).png"))
        }
        let image = StatusItemRenderer.image(for: store.state, appearance: NSAppearance(named: .aqua))
        let rep = NSBitmapImageRep(data: try #require(image.tiffRepresentation))
        try rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("menu.png"))
    }
    store.setError(LLMCenterError.loginRequired)
    controller.view.frame.size = DashboardViewController.preferredContentSize(for: store.state)
    controller.view.layoutSubtreeIfNeeded()
    verify(controller.view)
}

@Test @MainActor func independentProvidersAndLoginPrompt() throws {
    let codex = UsageStore(initialState: UsageViewState(provider: .codex))
    let llm = UsageStore(initialState: UsageViewState(provider: .llmCenter))
    #expect(llm.state.menuPrompt?.0 == "登录")
    #expect(llm.state.menuPrompt?.1 == "LLM Center")
    #expect(codex.state.menuPrompt == nil)
    llm.setRefreshing(true)
    #expect(llm.state.menuPrompt?.0 == "连接中")
    llm.setRefreshing(false)
    llm.setLogin(active: true)
    #expect(llm.state.menuPrompt?.0 == "正在登录")
    llm.setLogin(active: false)
    llm.setError(URLError(.notConnectedToInternet))
    #expect(llm.state.menuPrompt?.0 == "登录")
    #expect(codex.state.errorMessage == nil)
    llm.setPaused(true)
    #expect(!codex.state.isPaused)
    #expect(StatusItemRenderer.size(for: codex.state).width < 100)
    #expect(StatusItemRenderer.size(for: llm.state).width == 58)
}
