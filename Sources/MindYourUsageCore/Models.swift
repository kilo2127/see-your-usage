import Foundation

public struct UsageSnapshot: Equatable, Sendable {
    public let fetchedAt: Date
    public let accountID: String?
    public let planType: String?
    public let windows: [UsageWindow]
    public let additionalLimits: [AdditionalUsageLimit]
    public let credits: CreditStatus?
    public let resetCreditsAvailable: Int?

    public init(
        fetchedAt: Date,
        accountID: String?,
        planType: String?,
        windows: [UsageWindow],
        additionalLimits: [AdditionalUsageLimit],
        credits: CreditStatus?,
        resetCreditsAvailable: Int?
    ) {
        self.fetchedAt = fetchedAt
        self.accountID = accountID
        self.planType = planType
        self.windows = windows
        self.additionalLimits = additionalLimits
        self.credits = credits
        self.resetCreditsAvailable = resetCreditsAvailable
    }

    public func window(kind: UsageWindow.Kind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }
}

public struct UsageWindow: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case fiveHour = "5h"
        case sevenDay = "7d"

        public var targetSeconds: TimeInterval {
            switch self {
            case .fiveHour: return 5 * 60 * 60
            case .sevenDay: return 7 * 24 * 60 * 60
            }
        }
    }

    public let kind: Kind
    public let usedPercent: Double
    public let windowSeconds: TimeInterval
    public let resetAt: Date?
    public let resetAfterSeconds: TimeInterval?

    public init(
        kind: Kind,
        usedPercent: Double,
        windowSeconds: TimeInterval,
        resetAt: Date?,
        resetAfterSeconds: TimeInterval?
    ) {
        self.kind = kind
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.windowSeconds = windowSeconds
        self.resetAt = resetAt
        self.resetAfterSeconds = resetAfterSeconds
    }

    public var remainingPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }

    public var isBlocked: Bool {
        usedPercent >= 100
    }
}

public struct AdditionalUsageLimit: Equatable, Sendable {
    public let name: String
    public let windows: [UsageWindow]

    public init(name: String, windows: [UsageWindow]) {
        self.name = name
        self.windows = windows
    }
}

public struct CreditStatus: Equatable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public enum UsageFetchError: LocalizedError, Equatable, Sendable {
    case missingAuthFile(String)
    case missingAccessToken
    case invalidAuthFile
    case invalidEndpoint
    case httpStatus(Int, String?)
    case noRateLimitWindows
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAuthFile(let path):
            return "Codex auth file was not found at \(path)."
        case .missingAccessToken:
            return "Codex access token is missing. Open Codex and log in again."
        case .invalidAuthFile:
            return "Codex auth file could not be read."
        case .invalidEndpoint:
            return "Codex usage endpoint is invalid."
        case .httpStatus(let code, let message):
            if let message, !message.isEmpty {
                return "Usage request failed with HTTP \(code): \(message)"
            }
            return "Usage request failed with HTTP \(code)."
        case .noRateLimitWindows:
            return "Codex did not return rate limit windows."
        case .decodingFailed(let message):
            return "Usage response could not be decoded: \(message)"
        }
    }
}
