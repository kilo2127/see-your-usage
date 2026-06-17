import Foundation

public enum UsageFormatting {
    public static func menuResetText(for window: UsageWindow, now: Date = Date(), locale: Locale = .current) -> String {
        guard let resetAt = window.resetAt else { return "--" }
        switch window.kind {
        case .fiveHour:
            return timeFormatter(locale: locale).string(from: resetAt)
        case .sevenDay:
            return dateFormatter(locale: locale).string(from: resetAt)
        }
    }

    public static func dashboardResetText(for window: UsageWindow, now: Date = Date(), locale: Locale = .current) -> String {
        guard let resetAt = window.resetAt else { return "Unknown reset" }
        let absolute: String
        switch window.kind {
        case .fiveHour:
            absolute = timeFormatter(locale: locale).string(from: resetAt)
        case .sevenDay:
            absolute = dateFormatter(locale: locale).string(from: resetAt)
        }

        let remaining = max(0, resetAt.timeIntervalSince(now))
        if remaining < 60 {
            return "resets in <1m"
        }
        if remaining < 60 * 60 {
            return "resets in \(Int(ceil(remaining / 60)))m"
        }
        if remaining < 24 * 60 * 60 {
            let hours = Int(remaining / 3600)
            let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            return minutes > 0 ? "resets \(absolute) (\(hours)h \(minutes)m)" : "resets \(absolute) (\(hours)h)"
        }
        return "resets \(absolute)"
    }

    public static func lastRefreshText(_ date: Date?, locale: Locale = .current) -> String {
        guard let date else { return "Not refreshed yet" }
        return "Last refreshed \(timeFormatter(locale: locale).string(from: date))"
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(round(value)))%"
    }

    private static func timeFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    private static func dateFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }
}
