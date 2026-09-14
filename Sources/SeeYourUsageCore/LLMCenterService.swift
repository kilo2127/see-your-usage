import Foundation
import Security
import LocalAuthentication

public enum LLMCenterError: LocalizedError, Equatable {
    case configurationRequired, loginRequired, keychainUnavailable, invalidResponse, loginExpired, unsafeURL, keychain(Int32), http(Int)

    public var errorDescription: String? {
        switch self {
        case .configurationRequired: return "请先设置 LLM Center 平台地址。"
        case .loginRequired: return "请登录 LLM Center 后查看额度。"
        case .keychainUnavailable: return "旧登录信息暂不可读取，请重新登录 LLM Center。不会弹出钥匙串密码框。"
        case .invalidResponse: return "平台未返回完整额度数据，请稍后刷新。"
        case .loginExpired: return "登录授权已过期，请重新登录。"
        case .unsafeURL: return "平台返回了无法验证的授权地址。"
        case .keychain: return "无法保存登录信息到钥匙串，请重试。"
        case .http(let status): return "暂时无法连接 LLM Center（\(status)），请检查公司内网。"
        }
    }
}

public struct LLMQuotaSnapshot: Equatable, Sendable {
    public let fetchedAt: Date
    public let refreshedAt: Date
    public let monthlyLimit: Decimal
    public let monthlyUsed: Decimal
    public let monthlyRemaining: Decimal
    public let todayUsed: Decimal
    public let nextReset: Date?
    public let hasTeam: Bool

    public var remainingPercent: Double {
        guard monthlyLimit > 0 else { return 0 }
        return min(100, max(0, NSDecimalNumber(decimal: monthlyRemaining / monthlyLimit * 100).doubleValue))
    }

    public func isCurrentDay(at now: Date = Date()) -> Bool {
        Self.calendar.isDate(refreshedAt, inSameDayAs: now)
    }

    public func isCurrentMonth(at now: Date = Date()) -> Bool {
        Self.calendar.isDate(refreshedAt, equalTo: now, toGranularity: .month)
    }

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    public static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> LLMQuotaSnapshot {
        let value = try LLMCenterService.payload(data)
        guard let hasTeam = value["hasDept"] as? Bool,
              let money = try? JSONDecoder().decode(QuotaMoneyEnvelope.self, from: data).data else {
            throw LLMCenterError.invalidResponse
        }
        return LLMQuotaSnapshot(
            fetchedAt: fetchedAt,
            refreshedAt: date(value["refreshTime"]) ?? fetchedAt,
            monthlyLimit: money.monthlyLimit.value,
            monthlyUsed: money.monthlyUsed.value,
            monthlyRemaining: money.monthlyRemaining.value,
            todayUsed: money.todayUsed.value,
            nextReset: date(value["nextResetTime"]),
            hasTeam: hasTeam
        )
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let number = raw as? NSNumber {
            let time = number.doubleValue
            return Date(timeIntervalSince1970: time > 1e11 ? time / 1000 : time)
        }
        guard let string = raw as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}

// Decode JSON numeric tokens directly into Decimal; a Double/NSNumber bridge can
// turn a billed 86.4 into 86.40000000000001 before it reaches the UI.
private struct QuotaMoneyEnvelope: Decodable {
    let data: Amounts
    struct Amounts: Decodable {
        let monthlyLimit: Amount
        let monthlyUsed: Amount
        let monthlyRemaining: Amount
        let todayUsed: Amount
    }
    struct Amount: Decodable {
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
}

public enum QuotaFormatting {
    public static func amount(_ value: Decimal, compact: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .down
        var amount = value
        var suffix = ""
        if compact && abs(value) >= 100_000 { amount = value / 10_000; suffix = "万" }
        return "¥" + (formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—") + suffix
    }

    public static func today(_ value: Decimal, compact: Bool = false) -> String {
        guard value != 0 else { return "Nah" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.roundingMode = .down
        return "¥" + (formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—")
    }

    public static func timestamp(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = LLMQuotaSnapshot.calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

public final class LLMTokenStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedToken: String?
    private var cachedOrigin: String?
    private var blocked = false
    private let readItem: ([String: Any]) -> (OSStatus, Data?)
    private let updateItem: ([String: Any], [String: Any]) -> OSStatus
    private let addItem: ([String: Any]) -> OSStatus
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.leung.see-your-usage.llm-center",
         kSecAttrAccount as String: "webToken@" + origin]
    }

    private var origin: String { LLMCenterConfiguration.baseURL?.absoluteString ?? "unconfigured" }

    private func checkOrigin() {
        if cachedOrigin != origin {
            cachedToken = nil
            blocked = false
            cachedOrigin = origin
        }
    }

    // Background refresh and login persistence must never open SecurityAgent UI.
    var noninteractiveQuery: [String: Any] {
        var value = query
        let context = LAContext()
        context.interactionNotAllowed = true
        value[kSecUseAuthenticationContext as String] = context
        return value
    }

    public convenience init() {
        self.init(readItem: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }, updateItem: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }, addItem: { item in SecItemAdd(item as CFDictionary, nil) })
    }

    init(readItem: @escaping ([String: Any]) -> (OSStatus, Data?),
         updateItem: @escaping ([String: Any], [String: Any]) -> OSStatus,
         addItem: @escaping ([String: Any]) -> OSStatus) {
        self.readItem = readItem
        self.updateItem = updateItem
        self.addItem = addItem
    }

    public func load() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        checkOrigin()
        if let cachedToken { return cachedToken }
        if blocked { throw LLMCenterError.keychainUnavailable }
        var query = noninteractiveQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var (status, result) = readItem(query)
        // Optional migration is bound to the original origin in local preferences.
        // Never try an unscoped legacy token for a user-entered different platform.
        if status == errSecItemNotFound,
           UserDefaults.standard.string(forKey: "llm-center-legacy-origin") == origin {
            query[kSecAttrAccount as String] = "webToken"
            (status, result) = readItem(query)
        }
        if status != errSecSuccess && status != errSecItemNotFound {
            blocked = true
            throw LLMCenterError.keychainUnavailable
        }
        guard status == errSecSuccess, let data = result,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw LLMCenterError.loginRequired
        }
        cachedToken = token
        return token
    }

    @discardableResult
    public func save(_ token: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Browser authorization remains usable for this process even when the old
        // keychain ACL belongs to an earlier ad-hoc signed build. Do not delete or
        // relax that ACL, and do not fall back to writing plaintext credentials.
        checkOrigin()
        cachedToken = token
        blocked = false
        let attributes = [kSecValueData as String: Data(token.utf8)]
        var status = updateItem(noninteractiveQuery, attributes)
        if status == errSecItemNotFound {
            var item = noninteractiveQuery.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = addItem(item)
        }
        return status == errSecSuccess
    }
}

// Never forward a bearer token or login state through a redirect.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct LLMCenterService: Sendable {
    public static var baseURL: URL? { LLMCenterConfiguration.baseURL }
    private let endpoint: URL?
    private var resolvedURL: URL? { endpoint ?? Self.baseURL }
    public let session: URLSession
    public let tokens: LLMTokenStore

    public init(session: URLSession? = nil, endpoint: URL? = nil, tokens: LLMTokenStore = LLMTokenStore()) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        self.tokens = tokens
        self.endpoint = endpoint
    }

    public func fetchUsage() async throws -> LLMQuotaSnapshot {
        guard resolvedURL != nil else { throw LLMCenterError.configurationRequired }
        let token = try tokens.load()
        return try await fetchUsage(token: token)
    }

    public func fetchUsage(token: String) async throws -> LLMQuotaSnapshot {
        let data = try await request(path: "/llm/api/department/my/quota-overview", token: token)
        return try LLMQuotaSnapshot.decode(data)
    }

    public struct LoginSession: Sendable {
        public let state: String
        public let url: URL
        public let expiresAt: Date
        public let pollInterval: TimeInterval
    }

    public func beginLogin() async throws -> LoginSession {
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let result = try Self.payload(await request(path: "/llm/api/cli/auth/session", body: ["state": state]))
        guard let address = result["authorizeUrl"] as? String,
              let url = URL(string: address), url.scheme == "https",
              url.host?.lowercased() == resolvedURL?.host?.lowercased(), url.port == resolvedURL?.port,
              url.user == nil, url.password == nil else { throw LLMCenterError.unsafeURL }
        let expires = (result["expiresIn"] as? NSNumber)?.doubleValue ?? 300
        let interval = (result["pollIntervalMs"] as? NSNumber)?.doubleValue ?? 2000
        return LoginSession(state: state, url: url, expiresAt: Date().addingTimeInterval(min(600, max(1, expires))), pollInterval: max(2, min(10, interval / 1000)))
    }

    public func pollLogin(_ login: LoginSession) async throws -> String? {
        guard Date() < login.expiresAt else { throw LLMCenterError.loginExpired }
        let result = try Self.payload(await request(path: "/llm/api/cli/auth/poll", query: [URLQueryItem(name: "state", value: login.state)]))
        switch result["status"] as? String {
        case "completed":
            guard let token = result["webToken"] as? String, !token.isEmpty else { throw LLMCenterError.invalidResponse }
            return token
        case "expired", "cancelled", "denied": throw LLMCenterError.loginExpired
        case "pending", "waiting": return nil
        default: throw LLMCenterError.invalidResponse
        }
    }

    private func request(path: String, token: String? = nil, body: [String: String]? = nil,
                         query: [URLQueryItem] = []) async throws -> Data {
        guard let baseURL = resolvedURL else { throw LLMCenterError.configurationRequired }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LLMCenterError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw LLMCenterError.loginRequired }
        guard (200..<300).contains(response.statusCode) else { throw LLMCenterError.http(response.statusCode) }
        return data
    }

    static func payload(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMCenterError.invalidResponse }
        let code = root["code"].map { String(describing: $0) }
        if code == "401" || code == "403" { throw LLMCenterError.loginRequired }
        guard root["success"] as? Bool != false,
              code == nil || code == "200" || code == "0",
              let data = root["data"] as? [String: Any] else { throw LLMCenterError.invalidResponse }
        return data
    }
}
