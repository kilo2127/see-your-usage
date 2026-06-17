import AppKit
import MindYourUsageCore

enum UsageColors {
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
