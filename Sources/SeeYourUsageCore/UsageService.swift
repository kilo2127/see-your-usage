import Foundation

public struct CodexUsageService: Sendable {
    public var endpoint: URL
    public var authStore: AuthStore
    public var urlSession: URLSession

    public init(
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        authStore: AuthStore = AuthStore(),
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.authStore = authStore
        self.urlSession = urlSession
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let credentials = try authStore.loadCredentials()
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex Desktop", forHTTPHeaderField: "Originator")
        request.setValue("en", forHTTPHeaderField: "OAI-Language")
        request.setValue("see-your-usage/0.1", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageFetchError.httpStatus(-1, nil)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data.prefix(240), encoding: .utf8)
            throw UsageFetchError.httpStatus(httpResponse.statusCode, message)
        }

        return try Self.decodeSnapshot(from: data, fetchedAt: Date())
    }

    public static func decodeSnapshot(from data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let response: UsageResponse
        do {
            response = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageFetchError.decodingFailed(error.localizedDescription)
        }

        guard let rootLimit = response.rateLimit else {
            throw UsageFetchError.noRateLimitWindows
        }

        let windows = buildWindows(from: rootLimit)
        guard !windows.isEmpty else {
            throw UsageFetchError.noRateLimitWindows
        }

        let additionalLimits = response.additionalRateLimits.compactMap { item -> AdditionalUsageLimit? in
            guard let name = item.limitName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            let windows = buildWindows(from: item.rateLimit)
            return windows.isEmpty ? nil : AdditionalUsageLimit(name: name, windows: windows)
        }

        let credits = response.credits.map {
            CreditStatus(hasCredits: $0.hasCredits, unlimited: $0.unlimited, balance: $0.balance)
        }

        return UsageSnapshot(
            fetchedAt: fetchedAt,
            accountID: response.accountID,
            planType: response.planType,
            windows: windows.sorted { $0.kind.displayOrder < $1.kind.displayOrder },
            additionalLimits: additionalLimits,
            credits: credits,
            resetCreditsAvailable: response.rateLimitResetCredits?.availableCount
        )
    }

    private static func buildWindows(from limit: RateLimit) -> [UsageWindow] {
        let rawWindows = [limit.primaryWindow, limit.secondaryWindow].compactMap { $0 }
        guard !rawWindows.isEmpty else { return [] }

        var output: [UsageWindow] = []
        var consumedKinds = Set<UsageWindow.Kind>()

        for rawWindow in rawWindows {
            guard let windowSeconds = rawWindow.limitWindowSeconds,
                  let kind = kind(forWindowSeconds: windowSeconds),
                  !consumedKinds.contains(kind) else {
                continue
            }
            consumedKinds.insert(kind)
            output.append(UsageWindow(
                kind: kind,
                usedPercent: rawWindow.usedPercent ?? 0,
                windowSeconds: TimeInterval(windowSeconds),
                resetAt: rawWindow.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                resetAfterSeconds: rawWindow.resetAfterSeconds.map(TimeInterval.init)
            ))
        }

        return output
    }

    private static func kind(forWindowSeconds seconds: Int) -> UsageWindow.Kind? {
        UsageWindow.Kind.allCases.first { kind in
            let tolerance = max(60, kind.targetSeconds * 0.05)
            return abs(TimeInterval(seconds) - kind.targetSeconds) <= tolerance
        }
    }
}

private struct UsageResponse: Decodable {
    let accountID: String?
    let planType: String?
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]
    let credits: Credits?
    let rateLimitResetCredits: ResetCredits?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        additionalRateLimits = try container.decodeIfPresent([AdditionalRateLimit].self, forKey: .additionalRateLimits) ?? []
        credits = try container.decodeIfPresent(Credits.self, forKey: .credits)
        rateLimitResetCredits = try container.decodeIfPresent(ResetCredits.self, forKey: .rateLimitResetCredits)
    }
}

private struct RateLimit: Decodable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: RateLimitWindow?
    let secondaryWindow: RateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double?
    let limitWindowSeconds: Int?
    let resetAfterSeconds: Int?
    let resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

private struct AdditionalRateLimit: Decodable {
    let limitName: String?
    let rateLimit: RateLimit

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case rateLimit = "rate_limit"
    }
}

private struct Credits: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

private struct ResetCredits: Decodable {
    let availableCount: Int?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
    }
}
