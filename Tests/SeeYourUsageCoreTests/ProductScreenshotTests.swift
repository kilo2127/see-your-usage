import AppKit
import Foundation
import Testing
@testable import SeeYourUsage
@testable import SeeYourUsageCore

// Opt-in documentation renders use the production views, entirely synthetic state,
// and no coordinator.start(), credentials, requests, or desktop screen capture.
@Test @MainActor func renderProductScreenshots() throws {
    guard let output = ProcessInfo.processInfo.environment["SEE_USAGE_PRODUCT_DIR"] else { return }
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date()
    let reset = LLMQuotaSnapshot.calendar.dateInterval(of: .month, for: now)!.end
    let iso = ISO8601DateFormatter()
    let payload: [String: Any] = ["code": 200, "data": [
        "hasDept": true, "monthlyLimit": "7000", "monthlyUsed": "1180",
        "monthlyRemaining": "5820", "todayUsed": "86.4",
        "refreshTime": iso.string(from: now), "nextResetTime": iso.string(from: reset)
    ]]
    let llm = UsageStore(initialState: UsageViewState(provider: .llmCenter))
    llm.setQuota(try LLMQuotaSnapshot.decode(JSONSerialization.data(withJSONObject: payload)))
    let codex = UsageStore(initialState: UsageViewState(provider: .codex))
    codex.setSnapshot(UsageSnapshot(fetchedAt: now, accountID: nil, planType: "pro", windows: [
        UsageWindow(kind: .sevenDay, usedPercent: 58, windowSeconds: 604800,
                    resetAt: now.addingTimeInterval(5 * 86400), resetAfterSeconds: nil)
    ], additionalLimits: [], credits: nil, resetCreditsAvailable: nil))

    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let appearance = NSAppearance(named: appearanceName)!
        for (provider, store) in [("llm-center", llm), ("codex", codex)] {
            let coordinator = RefreshCoordinator(store: store)
            defer { coordinator.stop() }
            let controller = DashboardViewController(store: store, coordinator: coordinator)
            let size = DashboardViewController.preferredContentSize(for: store.state)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = controller
            controller.view.frame.size = size
            controller.view.appearance = appearance
            controller.view.layoutSubtreeIfNeeded()
            let rep = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
            try documentationPNG(rep).write(to: directory.appendingPathComponent("\(provider)-\(name).png"))
        }
        let codexWidth = StatusItemRenderer.size(for: codex.state).width
        let llmWidth = StatusItemRenderer.size(for: llm.state).width
        let size = NSSize(width: codexWidth + llmWidth + 36, height: 32)
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
                StatusItemRenderer.image(for: codex.state, appearance: appearance).draw(at: NSPoint(x: 10, y: 4), from: .zero, operation: .sourceOver, fraction: 1)
                StatusItemRenderer.image(for: llm.state, appearance: appearance).draw(at: NSPoint(x: codexWidth + 26, y: 4), from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                data = try? documentationPNG(rep)
            }
        }
        try #require(data).write(to: directory.appendingPathComponent("menu-bar-\(name).png"))
    }
}

// AppKit may add EXIF while encoding. Public documentation needs only image data
// and color information; remove metadata chunks without changing rendered pixels.
private func documentationPNG(_ bitmap: NSBitmapImageRep) throws -> Data {
    let encoded = try #require(bitmap.representation(using: .png, properties: [:]))
    var result = Data(encoded.prefix(8))
    var offset = 8
    while offset + 12 <= encoded.count {
        let length = encoded[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        let end = offset + 12 + length
        #expect(end <= encoded.count)
        guard end <= encoded.count else { break }
        let kind = String(decoding: encoded[(offset + 4)..<(offset + 8)], as: UTF8.self)
        if !["eXIf", "tEXt", "zTXt", "iTXt"].contains(kind) { result.append(encoded[offset..<end]) }
        offset = end
    }
    return result
}
