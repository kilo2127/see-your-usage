public enum UsageRemainingBand: Equatable, Sendable {
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
