import Foundation

public enum UsageRemainingBand: Equatable, Sendable {
    public static func band(forMonthlyRemaining remaining: Decimal, scope: LLMQuotaScope = .personal) -> UsageRemainingBand {
        if remaining < (scope == .personal ? 300 : 3000) { return .red }
        if remaining < (scope == .personal ? 600 : 6000) { return .yellow }
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
