import AppKit

enum UsageColors {
    static func accent(forRemainingPercent remaining: Double) -> NSColor {
        if remaining <= 20 {
            return .systemRed
        }
        if remaining <= 50 {
            return .systemYellow
        }
        return .systemGreen
    }
}
