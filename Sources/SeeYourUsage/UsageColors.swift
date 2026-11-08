import AppKit
import SeeYourUsageCore

enum UsageColors {
    static func accent(forMonthlyRemaining remaining: Decimal, scope: LLMQuotaScope = .personal) -> NSColor {
        switch UsageRemainingBand.band(forMonthlyRemaining: remaining, scope: scope) {
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        }
    }

    static func accent(forRemainingPercent remaining: Double) -> NSColor {
        switch UsageRemainingBand.band(forRemainingPercent: remaining) {
        case .red:
            return .systemRed
        case .yellow:
            return .systemYellow
        case .green:
            return .systemGreen
        }
    }
}
