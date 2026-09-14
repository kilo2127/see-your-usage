import Foundation

public enum UsageRemainingBand: Equatable, Sendable {
    public static func band(forMonthlyRemaining remaining: Decimal) -> UsageRemainingBand {
        if remaining < 1000 { return .red }
        if remaining < 3000 { return .yellow }
        return .green
    }

    case red
    case yellow
    case green

    public static func band(forRemainingPercent remaining: Double) -> UsageRemainingBand {
        let percent = UsageFormatting.roundedPercent(remaining)
        if percent <= 33 {
            return .red
        }
        if percent <= 66 {
            return .yellow
        }
        return .green
    }
}
