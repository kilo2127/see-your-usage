import AppKit
import Foundation
import Testing
@testable import SeeYourUsage
@testable import SeeYourUsageCore

@Test @MainActor func independentVisibilityAndStartupPreferences() throws {
    let name = "see-your-usage.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = ServicePreferences(defaults: defaults)
    settings.setVisible(false, for: .llmCenter)
    #expect(!settings.isVisible(.llmCenter))
    #expect(settings.isVisible(.codex))
    try settings.setStartsAtLogin(false, for: .codex)
    #expect(!settings.startsAtLogin(.codex))
    #expect(settings.startsAtLogin(.llmCenter))
    #expect(!settings.needsLoginItem)
    settings.setVisible(true, for: .llmCenter)
    #expect(settings.needsLoginItem)
    settings.prepareForLaunch(isLogin: true)
    #expect(!settings.isVisible(.codex))
    #expect(settings.isVisible(.llmCenter))
    settings.setVisible(true, for: .codex)
    #expect(settings.isVisible(.codex))
    let restored = ServicePreferences(defaults: defaults)
    restored.prepareForLaunch(isLogin: false)
    #expect(restored.isVisible(.codex))
    #expect(!restored.startsAtLogin(.codex))
}

@Test func monthlyAmountColorBoundaries() {
    #expect(UsageRemainingBand.band(forMonthlyRemaining: 3000) == .green)
    #expect(UsageRemainingBand.band(forMonthlyRemaining: 2999.99) == .yellow)
    #expect(UsageRemainingBand.band(forMonthlyRemaining: 1000) == .yellow)
    #expect(UsageRemainingBand.band(forMonthlyRemaining: 999.99) == .red)
    #expect(UsageRemainingBand.band(forMonthlyRemaining: 0) == .red)
    #expect(UsageRemainingBand.band(forMonthlyRemaining: -1) == .red)
}

@Test func platformConfigurationRejectsCredentialsAndInsecureAddresses() {
    #expect(LLMCenterConfiguration.validatedURL("https://llm.example.invalid/")?.absoluteString == "https://llm.example.invalid")
    for url in ["http://llm.example.invalid", "https://user:secret@llm.example.invalid", "https://llm.example.invalid/?token=secret", "https://llm.example.invalid/login", "file:///tmp/config", "not a url"] {
        #expect(LLMCenterConfiguration.validatedURL(url) == nil)
    }
}
