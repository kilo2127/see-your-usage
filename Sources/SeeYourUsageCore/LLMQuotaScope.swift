import Foundation

public enum LLMQuotaScope: String, CaseIterable, Sendable {
    case personal, project

    public var title: String { self == .personal ? "个人 Key" : "项目 Key" }
    public var remainingTitle: String { self == .personal ? "本月剩余" : "总剩余" }
}

public struct LLMProject: Equatable, Sendable, Decodable {
    public let appCode: String
    public let appTitle: String
}

struct LLMProjectPage: Decodable {
    let data: Page
    struct Page: Decodable {
        let data: [Project]
        let total: Int
    }
    struct Project: Decodable {
        let id: String
        let appCode: String
        let appTitle: String
        let appType: String
        let memberQuotaAmount: QuotaAmount?
        // Some visible projects omit financial fields when access is restricted.
        let accountBalance: QuotaAmount?
        let usedQuota: QuotaAmount?

        enum CodingKeys: String, CodingKey { case id, appCode, appTitle, appType, memberQuotaAmount, accountBalance, usedQuota }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let string = try? c.decode(String.self, forKey: .id) { id = string }
            else { id = String(try c.decode(Int.self, forKey: .id)) }
            appCode = try c.decode(String.self, forKey: .appCode)
            appTitle = try c.decode(String.self, forKey: .appTitle)
            appType = try c.decode(String.self, forKey: .appType)
            memberQuotaAmount = try? c.decode(QuotaAmount.self, forKey: .memberQuotaAmount)
            accountBalance = try? c.decode(QuotaAmount.self, forKey: .accountBalance)
            usedQuota = try? c.decode(QuotaAmount.self, forKey: .usedQuota)
        }

        var summary: LLMProject { LLMProject(appCode: appCode, appTitle: appTitle) }
    }
}

struct LLMProjectDetail: Decodable {
    let data: Detail
    struct Detail: Decodable { let members: [Member] }
    // The server also includes key fields. Decode only member identity and money.
    struct Member: Decodable {
        let userId: String
        let memberQuotaLimit: QuotaAmount?
        let memberUsedQuota: QuotaAmount
    }
}

struct LLMProjectStatistics: Decodable {
    let data: Statistics
    struct Statistics: Decodable { let totalCost: QuotaAmount }
}

// Decode numeric tokens directly as Decimal to preserve billed amounts.
struct QuotaAmount: Decodable {
    let value: Decimal
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            guard string.range(of: #"^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
                  let decimal = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")),
                  !decimal.isNaN else { throw LLMCenterError.invalidResponse }
            value = decimal
        } else {
            value = try container.decode(Decimal.self)
            guard !value.isNaN else { throw LLMCenterError.invalidResponse }
        }
    }
}
