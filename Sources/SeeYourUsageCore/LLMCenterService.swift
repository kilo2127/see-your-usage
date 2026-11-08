import Foundation
import Security
import LocalAuthentication

public enum LLMCenterError: LocalizedError, Equatable {
    case configurationRequired, loginRequired, forbidden, renewalUnavailable, keychainUnavailable, invalidResponse, clientUpgradeRequired, loginExpired, browserUnavailable, browserAutomationRequired, browserTabMissing, unsafeURL, keychain(Int32), http(Int)

    case projectSelectionRequired([LLMProject])
    case noProjects

    public var errorDescription: String? {
        switch self {
        case .projectSelectionRequired: return "请选择要显示额度的项目。"
        case .noProjects: return "当前账号没有可查看的项目。"
        case .configurationRequired: return "请先设置 LLM Center 平台地址。"
        case .loginRequired: return "请登录 LLM Center 后查看额度。"
        case .forbidden: return "平台拒绝访问，请检查账号权限或公司内网。"
        case .renewalUnavailable: return "本次登录未提供续期凭据，请使用统一登录。"
        case .keychainUnavailable: return "旧登录信息暂不可读取，请重新登录 LLM Center。不会弹出钥匙串密码框。"
        case .invalidResponse: return "平台未返回完整额度数据，请稍后刷新。"
        case .clientUpgradeRequired: return "平台已升级登录协议，当前客户端不兼容，需要更新应用。"
        case .loginExpired: return "登录授权已过期，请重新登录。"
        case .browserUnavailable: return "无法打开 Safari，请稍后重试。"
        case .browserAutomationRequired: return "Safari 自动续期未获授权，请重新连接 Safari。"
        case .browserTabMissing: return "请打开一个 Safari 窗口后重新连接。"
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
    public var scope: LLMQuotaScope = .personal
    public var project: LLMProject?
    public var projects: [LLMProject] = []

    public var remainingPercent: Double {
        guard monthlyLimit > 0 else { return 0 }
        return min(100, max(0, NSDecimalNumber(decimal: monthlyRemaining / monthlyLimit * 100).doubleValue))
    }

    public func isCurrentDay(at now: Date = Date()) -> Bool {
        Self.calendar.isDate(refreshedAt, inSameDayAs: now)
    }

    public func isCurrentMonth(at now: Date = Date()) -> Bool {
        scope == .project || Self.calendar.isDate(refreshedAt, equalTo: now, toGranularity: .month)
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
    typealias Amount = QuotaAmount
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

// LAContext.interactionNotAllowed does not suppress ACL prompts for the legacy
// file-based login keychain. Disable that API's UI before every native access,
// and fail closed if the policy cannot be applied. Never restore interactive
// access in this background app, including after a failed operation.
enum NoninteractiveKeychain {
    static func perform<Result>(
        configure: () -> OSStatus = { SecKeychainSetUserInteractionAllowed(false) },
        failure: (OSStatus) -> Result,
        operation: () -> Result
    ) -> Result {
        let status = configure()
        guard status == errSecSuccess else { return failure(status) }
        return operation()
    }
}

public final class LLMTokenStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedToken: String?
    private var cachedOrigin: String?
    private var blocked = false
    private let accountPrefix: String
    private let originProvider: @Sendable () -> String
    private let readItem: ([String: Any]) -> (OSStatus, Data?)
    private let updateItem: ([String: Any], [String: Any]) -> OSStatus
    private let addItem: ([String: Any]) -> OSStatus
    private func query(for origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.leung.see-your-usage.llm-center",
         kSecAttrAccount as String: accountPrefix + origin]
    }

    private var origin: String { originProvider() }

    private func checkOrigin(_ origin: String) {
        if cachedOrigin != origin {
            cachedToken = nil
            blocked = false
            cachedOrigin = origin
        }
    }

    // Background refresh and login persistence must never open SecurityAgent UI.
    private func noninteractiveQuery(for origin: String) -> [String: Any] {
        var value = query(for: origin)
        let context = LAContext()
        context.interactionNotAllowed = true
        value[kSecUseAuthenticationContext as String] = context
        return value
    }

    public convenience init(accountPrefix: String = "webToken@") {
        self.init(readItem: { query in
            NoninteractiveKeychain.perform(failure: { ($0, nil) }) {
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result as? Data)
            }
        }, updateItem: { query, attributes in
            NoninteractiveKeychain.perform(failure: { $0 }) {
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }, addItem: { item in
            NoninteractiveKeychain.perform(failure: { $0 }) {
                SecItemAdd(item as CFDictionary, nil)
            }
        }, accountPrefix: accountPrefix)
    }

    init(readItem: @escaping ([String: Any]) -> (OSStatus, Data?),
         updateItem: @escaping ([String: Any], [String: Any]) -> OSStatus,
         addItem: @escaping ([String: Any]) -> OSStatus, accountPrefix: String = "webToken@",
         originProvider: @escaping @Sendable () -> String = { LLMCenterConfiguration.baseURL?.absoluteString ?? "unconfigured" }) {
        self.readItem = readItem
        self.updateItem = updateItem
        self.addItem = addItem
        self.accountPrefix = accountPrefix
        self.originProvider = originProvider
    }

    public func load(expectedOrigin: String? = nil) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let currentOrigin = origin
        checkOrigin(currentOrigin)
        if let expectedOrigin, expectedOrigin != currentOrigin { throw LLMCenterError.configurationRequired }
        if let cachedToken { return cachedToken }
        if blocked { throw LLMCenterError.keychainUnavailable }
        var query = noninteractiveQuery(for: currentOrigin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var (status, result) = readItem(query)
        // Optional migration is bound to the original origin in local preferences.
        // Never try an unscoped legacy token for a user-entered different platform.
        if status == errSecItemNotFound, accountPrefix == "webToken@",
           UserDefaults.standard.string(forKey: "llm-center-legacy-origin") == currentOrigin {
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
    public func save(_ token: String, expectedOrigin: String? = nil) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Browser authorization remains usable for this process even when the old
        // keychain ACL belongs to an earlier ad-hoc signed build. Do not delete or
        // relax that ACL, and do not fall back to writing plaintext credentials.
        let currentOrigin = origin
        checkOrigin(currentOrigin)
        if let expectedOrigin, expectedOrigin != currentOrigin { throw LLMCenterError.configurationRequired }
        cachedToken = token
        blocked = false
        let attributes = [kSecValueData as String: Data(token.utf8)]
        let query = noninteractiveQuery(for: currentOrigin)
        var status = updateItem(query, attributes)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = addItem(item)
        }
        return status == errSecSuccess
    }
}

// Never forward a bearer token or login state through a redirect.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
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
    public let authentication: LLMAuthentication

    public init(session: URLSession? = nil, endpoint: URL? = nil, tokens: LLMTokenStore = LLMTokenStore(),
                authenticationStore: LLMTokenStore? = nil, nativeAuthenticationStore: LLMTokenStore? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        config.urlCache = nil
        // The quota platform and its separate identity service use the company
        // network. A system forward proxy can reach quota while failing TLS to
        // the identity service, which blocks every refresh after token expiry.
        // Use the company route for both; keep normal TLS validation and the
        // redirect restriction. Codex uses its own session and system proxy.
        config.connectionProxyDictionary = [:]
        self.session = session ?? URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        self.tokens = tokens
        self.endpoint = endpoint
        self.authentication = LLMAuthentication(session: self.session,
            store: authenticationStore ?? LLMTokenStore(accountPrefix: "oidcSession@"),
            nativeStore: nativeAuthenticationStore ?? (authenticationStore == nil ? LLMTokenStore(accountPrefix: "pkceSession@") : nil))
    }

    public typealias BrowserReconnect = @Sendable (_ previousURL: URL, _ authorizationURL: URL) async throws -> Void
    public typealias BrowserReconnectFinished = @Sendable (_ authorizationURL: URL) async -> Void

    public func fetchUsage(scope: LLMQuotaScope = .personal, projectCode: String? = nil, reconnect: BrowserReconnect? = nil,
                           finishReconnect: BrowserReconnectFinished? = nil) async throws -> LLMQuotaSnapshot {
        do {
            return try await fetchSavedUsage(scope: scope, projectCode: projectCode)
        } catch LLMCenterError.loginRequired {
            guard let reconnect, let origin = resolvedURL?.absoluteString,
                  let previousURL = try await authentication.browserAuthorizationURL(origin: origin) else {
                throw LLMCenterError.loginRequired
            }
            try Task.checkCancellation()
            let pending = try await beginLogin()
            let login = LoginSession(origin: pending.origin, state: pending.state, url: pending.url,
                expiresAt: min(pending.expiresAt, Date().addingTimeInterval(45)), pollInterval: pending.pollInterval,
                pkce: pending.pkce)
            do {
                try await reconnect(previousURL, login.url)
                try Task.checkCancellation()
                if !login.usesNativeRenewal {
                    try await authentication.trackBrowserAuthorizationURL(origin: origin, previousURL: previousURL, nextURL: login.url)
                }
                let quota = try await completeBrowserLogin(login, keepAuthorizationTab: true)
                await finishReconnect?(login.url)
                return scope == .personal ? quota : try await fetchSavedUsage(scope: scope, projectCode: projectCode)
            } catch {
                await finishReconnect?(login.url)
                throw error
            }
        }
    }

    private func fetchSavedUsage(scope: LLMQuotaScope, projectCode: String?) async throws -> LLMQuotaSnapshot {
        guard let origin = resolvedURL?.absoluteString else { throw LLMCenterError.configurationRequired }
        guard try await authentication.hasSession(origin: origin) else {
            return try await fetchUsage(token: tokens.load(expectedOrigin: origin), expectedOrigin: origin, scope: scope, projectCode: projectCode)
        }
        let token = try await authentication.accessToken(origin: origin)
        do {
            return try await fetchUsage(token: token, expectedOrigin: origin, scope: scope, projectCode: projectCode)
        } catch LLMCenterError.loginRequired {
            let renewed = try await authentication.accessToken(origin: origin, rejectedToken: token)
            return try await fetchUsage(token: renewed, expectedOrigin: origin, scope: scope, projectCode: projectCode)
        }
    }

    public func fetchUsage(token: String, expectedOrigin: String? = nil, scope: LLMQuotaScope = .personal, projectCode: String? = nil) async throws -> LLMQuotaSnapshot {
        if scope == .project { return try await fetchProjectUsage(token: token, expectedOrigin: expectedOrigin, projectCode: projectCode) }
        let data = try await request(path: "/llm/api/department/my/quota-overview", token: token, expectedOrigin: expectedOrigin)
        return try LLMQuotaSnapshot.decode(data)
    }

    private func fetchProjectUsage(token: String, expectedOrigin: String?, projectCode: String?) async throws -> LLMQuotaSnapshot {
        let startedAt = Date()
        var projects: [LLMProjectPage.Project] = []
        var page = 1
        while true {
            let data = try await request(path: "/llm/api/app/list", token: token,
                body: ["pageReq": ["pageNum": page, "pageSize": 100]], expectedOrigin: expectedOrigin)
            _ = try Self.payload(data)
            guard let result = try? JSONDecoder().decode(LLMProjectPage.self, from: data) else {
                throw LLMCenterError.invalidResponse
            }
            projects.append(contentsOf: result.data.data)
            if projects.count >= result.data.total { break }
            guard !result.data.data.isEmpty, page < 100 else { throw LLMCenterError.invalidResponse }
            page += 1
        }
        guard !projects.isEmpty else { throw LLMCenterError.noProjects }
        let choices = projects.map(\.summary)
        let selected = projects.first { $0.appCode == projectCode } ?? (projects.count == 1 ? projects.first : nil)
        guard let selected else { throw LLMCenterError.projectSelectionRequired(choices) }
        var accountID: String?
        let balance: Decimal
        let used: Decimal
        let limit: Decimal
        if selected.appType == "MEMBER" {
            let identity = try Self.payload(await request(path: "/api/admin/auth/check/token", token: token,
                body: ["token": token, "thirdType": "feilian"], expectedOrigin: expectedOrigin))
            guard let id = identity["id"] as? String, !id.isEmpty else { throw LLMCenterError.invalidResponse }
            accountID = id
            let detailData = try await request(path: "/llm/api/app/detail/" + selected.id, token: token, expectedOrigin: expectedOrigin)
            _ = try Self.payload(detailData)
            guard let detail = try? JSONDecoder().decode(LLMProjectDetail.self, from: detailData),
                  let member = detail.data.members.first(where: { $0.userId == id }) else {
                throw LLMCenterError.invalidResponse
            }
            let overviewData = try await request(path: "/llm/api/app/usage-overview", token: token,
                query: [URLQueryItem(name: "appCode", value: selected.appCode)], expectedOrigin: expectedOrigin)
            _ = try Self.payload(overviewData)
            guard let overview = try? JSONDecoder().decode(LLMProjectOverview.self, from: overviewData),
                  overview.data.quotaLimited, let available = overview.data.availableQuota?.value else {
                throw LLMCenterError.invalidResponse
            }
            balance = available
            used = member.memberUsedQuota.value
            guard let memberLimit = member.memberQuotaLimit?.value ?? selected.memberQuotaAmount?.value else {
                throw LLMCenterError.invalidResponse
            }
            limit = memberLimit
        } else if selected.appType == "PROJECT", let remaining = selected.accountBalance?.value,
                  let spent = selected.usedQuota?.value {
            balance = remaining
            used = spent
            limit = remaining + spent
        } else { throw LLMCenterError.invalidResponse }
        let day = QuotaFormatting.timestamp(startedAt, format: "yyyy-MM-dd")
        var filters: [String: Any] = ["scope": "PROJECT", "freeUser": 0, "appCodes": [selected.appCode],
                                      "startDate": day, "endDate": day]
        if let accountID { filters["accountIds"] = [accountID] }
        let data = try await request(path: "/llm/api/usage/statistics", token: token,
            body: filters, expectedOrigin: expectedOrigin)
        _ = try Self.payload(data)
        guard let statistics = try? JSONDecoder().decode(LLMProjectStatistics.self, from: data) else {
            throw LLMCenterError.invalidResponse
        }
        return LLMQuotaSnapshot(fetchedAt: Date(), refreshedAt: startedAt,
            monthlyLimit: limit, monthlyUsed: used, monthlyRemaining: balance,
            todayUsed: statistics.data.totalCost.value, nextReset: nil, hasTeam: true,
            scope: .project, project: selected.summary, projects: choices)
    }

    public struct LoginSession: Sendable {
        public let origin: String
        public let state: String
        public let url: URL
        public let expiresAt: Date
        public let pollInterval: TimeInterval
        let pkce: LLMPKCE?
        public var usesNativeRenewal: Bool { pkce != nil }

        init(origin: String, state: String, url: URL, expiresAt: Date, pollInterval: TimeInterval, pkce: LLMPKCE? = nil) {
            self.origin = origin; self.state = state; self.url = url
            self.expiresAt = expiresAt; self.pollInterval = pollInterval; self.pkce = pkce
        }
    }

    public func beginLogin() async throws -> LoginSession {
        guard let platform = resolvedURL else { throw LLMCenterError.configurationRequired }
        try Task.checkCancellation()
        let state = "llmctl_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let verifier = try LLMPKCE.makeVerifier()
        let result = try Self.payload(await request(path: "/llm/api/cli/auth/session",
            body: ["state": state, "codeChallenge": LLMPKCE.challenge(for: verifier)], expectedOrigin: platform.absoluteString))
        guard let address = result["authorizeUrl"] as? String,
              let url = URL(string: address) else { throw LLMCenterError.unsafeURL }
        let pkce = try LLMPKCE.validated(payload: result, platform: platform, authorizationURL: url, state: state, verifier: verifier)
        let expires = (result["expiresIn"] as? NSNumber)?.doubleValue ?? 300
        let interval = (result["pollIntervalMs"] as? NSNumber)?.doubleValue ?? 2000
        guard expires.isFinite, expires > 0, interval.isFinite else { throw LLMCenterError.invalidResponse }
        try Task.checkCancellation()
        return LoginSession(origin: platform.absoluteString, state: state, url: url,
            expiresAt: Date().addingTimeInterval(min(600, expires)), pollInterval: max(2, min(10, interval / 1000)), pkce: pkce)
    }

    public func pollLogin(_ login: LoginSession) async throws -> String? {
        try Task.checkCancellation()
        guard resolvedURL?.absoluteString == login.origin else { throw LLMCenterError.configurationRequired }
        guard Date() < login.expiresAt else { throw LLMCenterError.loginExpired }
        let result = try Self.payload(await request(path: "/llm/api/cli/auth/poll", query: [URLQueryItem(name: "state", value: login.state)], expectedOrigin: login.origin))
        switch result["status"] as? String {
        case "completed", "authorized":
            let key = login.usesNativeRenewal ? "authorizationCode" : "webToken"
            guard let token = result[key] as? String, !token.isEmpty else { throw LLMCenterError.invalidResponse }
            return token
        case "expired", "cancelled", "denied": throw LLMCenterError.loginExpired
        case "pending", "waiting": return nil
        default: throw LLMCenterError.invalidResponse
        }
    }

    public func completeBrowserLogin(_ login: LoginSession, keepAuthorizationTab: Bool = false) async throws -> LLMQuotaSnapshot {
        while true {
            try Task.checkCancellation()
            if let token = try await pollLogin(login) {
                try Task.checkCancellation()
                let candidate = try await authentication.exchangeAuthorizationCode(token, login: login)
                let quota = try await fetchUsage(token: candidate?.accessToken ?? token, expectedOrigin: login.origin)
                try Task.checkCancellation()
                guard resolvedURL?.absoluteString == login.origin else { throw LLMCenterError.configurationRequired }
                if let candidate {
                    try await authentication.acceptValidatedSession(candidate)
                } else {
                    try await authentication.acceptBrowserToken(token, origin: login.origin,
                        authorizationURL: keepAuthorizationTab ? login.url : nil)
                }
                return quota
            }
            let delay = min(login.pollInterval, login.expiresAt.timeIntervalSinceNow)
            guard delay > 0 else { throw LLMCenterError.loginExpired }
            try await Task.sleep(for: .seconds(delay))
        }
    }

    private func request(path: String, token: String? = nil, body: [String: Any]? = nil,
                         query: [URLQueryItem] = [], expectedOrigin: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard let baseURL = resolvedURL else { throw LLMCenterError.configurationRequired }
        if let expectedOrigin, baseURL.absoluteString != expectedOrigin { throw LLMCenterError.configurationRequired }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The official session endpoint gates its PKCE wire protocol by this
        // version tag. Identify our app too; no CLI executable is invoked.
        request.setValue("llmctl/0.2.15 (see-your-usage; macOS)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LLMCenterError.invalidResponse }
        if response.statusCode == 401 { throw LLMCenterError.loginRequired }
        if response.statusCode == 403 { throw LLMCenterError.forbidden }
        guard (200..<300).contains(response.statusCode) else { throw LLMCenterError.http(response.statusCode) }
        return data
    }

    static func payload(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMCenterError.invalidResponse }
        let code = root["code"].map { String(describing: $0) }
        // Match the official web client's authentication recovery codes. These
        // can arrive inside HTTP 200 responses and must enter the renewal flow.
        if let code, ["401", "1102", "1101", "1005", "1008", "1009", "1010", "1011", "1013", "1017", "1021"].contains(code) {
            throw LLMCenterError.loginRequired
        }
        if code == "403" { throw LLMCenterError.forbidden }
        if code == "400", let message = root["message"] as? String,
           message.contains("仅支持 llmctl"), message.contains("升级 CLI") {
            // Show a local, actionable explanation without exposing server text.
            throw LLMCenterError.clientUpgradeRequired
        }
        guard root["success"] as? Bool != false,
              code == nil || code == "200" || code == "0" || code == "0000",
              let data = root["data"] as? [String: Any] else { throw LLMCenterError.invalidResponse }
        return data
    }
}
