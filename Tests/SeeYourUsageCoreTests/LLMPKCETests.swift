import Foundation
import Security
import XCTest
@testable import SeeYourUsageCore

private final class PKCEMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func read() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }; value = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func store(origin: String) -> LLMTokenStore {
        LLMTokenStore(readItem: { _ in (self.read() == nil ? errSecItemNotFound : errSecSuccess, self.read()) },
            updateItem: { _, attributes in self.write(attributes) }, addItem: { self.write($0) },
            originProvider: { origin })
    }
}

private final class PKCEProtocol: URLProtocol, @unchecked Sendable {
    final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var challenges: [String: String] = [:]
        private var paths: [String: [String]] = [:]
        func record(host: String, path: String, challenge: String? = nil) {
            lock.lock(); defer { lock.unlock() }
            paths[host, default: []].append(path)
            if let challenge { challenges[host] = challenge }
        }
        func challenge(_ host: String) -> String? { lock.lock(); defer { lock.unlock() }; return challenges[host] }
        func paths(_ host: String) -> [String] { lock.lock(); defer { lock.unlock() }; return paths[host] ?? [] }
    }
    static let records = Records()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func body() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    override func startLoading() {
        let url = request.url!, host = url.host!
        let platformHost = host.hasPrefix("iam-") ? String(host.dropFirst(4)) : host
        Self.records.record(host: platformHost, path: url.path)
        let origin = "https://\(platformHost)", issuer = "https://iam-\(platformHost)"
        var status = 200
        var root: [String: Any]
        switch url.path {
        case "/llm/api/cli/auth/session":
            let sent = try! JSONSerialization.jsonObject(with: body()) as! [String: String]
            let state = sent["state"]!, challenge = sent["codeChallenge"]!
            XCTAssertTrue(state.hasPrefix("llmctl_")); XCTAssertEqual(challenge.count, 43)
            XCTAssertNil(sent["codeVerifier"])
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")!.contains("llmctl/0.2.15"))
            Self.records.record(host: platformHost, path: "challenge", challenge: challenge)
            var authorization = URLComponents(string: issuer + "/oauth/authorize")!
            authorization.queryItems = [URLQueryItem(name: "client_id", value: "synthetic-client"),
                URLQueryItem(name: "redirect_uri", value: origin + "/auth/callback"),
                URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256")]
            root = ["code": 0, "data": ["state": state, "authorizeUrl": authorization.url!.absoluteString,
                "tokenEndpoint": issuer + "/oauth/token", "clientId": "synthetic-client",
                "redirectUri": origin + "/auth/callback", "expiresIn": 300, "pollIntervalMs": 1000]]
        case "/llm/api/cli/auth/poll":
            root = ["code": 0, "data": ["status": "authorized", "authorizationCode": "synthetic-one-time-code"]]
        case "/oauth/token":
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            let parts = URLComponents(string: "https://unused.invalid/?" + String(decoding: body(), as: UTF8.self))!
            let fields = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(fields["client_id"], "synthetic-client")
            let renewing = fields["grant_type"] == "refresh_token"
            if renewing { XCTAssertEqual(fields["refresh_token"], "synthetic-refresh-1") }
            else {
                XCTAssertEqual(fields["grant_type"], "authorization_code")
                XCTAssertEqual(fields["code"], "synthetic-one-time-code")
                XCTAssertEqual(fields["redirect_uri"], origin + "/auth/callback")
                XCTAssertEqual(LLMPKCE.challenge(for: fields["code_verifier"]!), Self.records.challenge(platformHost))
            }
            root = ["access_token": renewing ? "synthetic-access-2" : "synthetic-access-1",
                "refresh_token": renewing ? "synthetic-refresh-2" : "synthetic-refresh-1",
                "expires_in": 3600, "token_type": "Bearer"]
            if platformHost.hasPrefix("missing-refresh") { root.removeValue(forKey: "refresh_token") }
            if platformHost.hasPrefix("expired-code") { status = 400; root = ["error": "invalid_grant", "error_description": "secret-fixture"] }
        case "/llm/api/department/my/quota-overview":
            XCTAssertTrue(["Bearer synthetic-access-1", "Bearer synthetic-access-2"].contains(request.value(forHTTPHeaderField: "Authorization")))
            if platformHost.hasPrefix("rejected-quota") { status = 403 }
            root = ["code": status, "data": ["hasDept": true, "monthlyLimit": 7000,
                "monthlyUsed": 123, "monthlyRemaining": 6877, "todayUsed": 12.3]]
        default: XCTFail("Unexpected protocol request"); root = [:]
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: root))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class LLMPKCETests: XCTestCase, @unchecked Sendable {
    private func fixture(_ kind: String = "valid") -> (LLMCenterService, PKCEMemory, URL) {
        let url = URL(string: "https://\(kind)-\(UUID().uuidString.lowercased()).example.invalid")!
        let memory = PKCEMemory()
        let blockedLegacy = LLMTokenStore(readItem: { _ in (errSecInteractionNotAllowed, nil) },
            updateItem: { _, _ in XCTFail("New login must not update an older keychain item"); return errSecInteractionNotAllowed },
            addItem: { _ in XCTFail(); return errSecInteractionNotAllowed }, originProvider: { url.absoluteString })
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PKCEProtocol.self]
        let service = LLMCenterService(session: URLSession(configuration: configuration), endpoint: url,
            authenticationStore: blockedLegacy, nativeAuthenticationStore: memory.store(origin: url.absoluteString))
        return (service, memory, url)
    }

    func testPKCELoginPersistsThenRenewsWithoutSafariAndSurvivesRestart() async throws {
        let (service, memory, url) = fixture(); defer { service.session.invalidateAndCancel() }
        let login = try await service.beginLogin()
        XCTAssertTrue(login.usesNativeRenewal)
        XCTAssertNotEqual(login.url.host, url.host)
        let quota = try await service.completeBrowserLogin(login)
        XCTAssertEqual(quota.monthlyRemaining, 6877)
        let renewed = try await service.authentication.accessToken(origin: url.absoluteString, rejectedToken: "synthetic-access-1")
        XCTAssertEqual(renewed, "synthetic-access-2")
        let saved = try JSONDecoder().decode(LLMRenewableSession.self, from: memory.read()!)
        XCTAssertEqual(saved.refreshToken, "synthetic-refresh-2")
        let restarted = LLMAuthentication(session: service.session, store: memory.store(origin: url.absoluteString))
        let reused = try await restarted.accessToken(origin: url.absoluteString)
        XCTAssertEqual(reused, renewed)
        _ = try await service.fetchUsage(reconnect: { _, _ in XCTFail("Native OIDC must not need Safari") })
        XCTAssertEqual(PKCEProtocol.records.paths(url.host!).filter { $0 == "/oauth/token" }.count, 2)
        XCTAssertEqual(PKCEProtocol.records.paths(url.host!).filter { $0 == "/llm/api/cli/auth/session" }.count, 1)
    }

    func testFailedExchangeOrQuotaDoesNotReplaceSavedSession() async throws {
        for (kind, expected) in [("missing-refresh", LLMCenterError.invalidResponse), ("expired-code", .loginExpired), ("rejected-quota", .forbidden)] {
            let (service, memory, url) = fixture(kind); defer { service.session.invalidateAndCancel() }
            let previous = LLMRenewableSession(origin: url.absoluteString, issuer: url,
                tokenEndpoint: url.appendingPathComponent("token"), clientID: "previous-client",
                accessToken: "previous-access", refreshToken: "previous-refresh", expiresAt: .distantFuture)
            let before = try JSONEncoder().encode(previous)
            _ = memory.write([kSecValueData as String: before])
            let login = try await service.beginLogin()
            do { _ = try await service.completeBrowserLogin(login); XCTFail() }
            catch { XCTAssertEqual(error as? LLMCenterError, expected); XCTAssertFalse(error.localizedDescription.contains("secret-fixture")) }
            XCTAssertEqual(memory.read(), before)
        }
    }

    func testRFC7636ChallengeAndFreshSecureVerifiers() throws {
        XCTAssertEqual(LLMPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let first = try LLMPKCE.makeVerifier(), second = try LLMPKCE.makeVerifier()
        XCTAssertEqual(first.count, 43); XCTAssertNotEqual(first, second)
        XCTAssertNotNil(first.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression))
    }

    func testAuthorizationMetadataAndEveryPKCEBindingAreValidated() throws {
        let platform = URL(string: "https://quota.example.invalid")!
        let verifier = "synthetic-verifier", state = "llmctl_synthetic-state"
        let payload: [String: Any] = ["state": state, "tokenEndpoint": "https://iam.example.invalid/oauth/token",
            "clientId": "synthetic-client", "redirectUri": "https://quota.example.invalid/auth/callback"]
        var components = URLComponents(string: "https://iam.example.invalid/oauth/authorize")!
        components.queryItems = [URLQueryItem(name: "client_id", value: "synthetic-client"),
            URLQueryItem(name: "redirect_uri", value: payload["redirectUri"] as? String),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: LLMPKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")]
        let validate: ([String: Any], URL) throws -> LLMPKCE? = {
            try LLMPKCE.validated(payload: $0, platform: platform, authorizationURL: $1, state: state, verifier: verifier)
        }
        XCTAssertNotNil(try validate(payload, components.url!))
        for index in components.queryItems!.indices {
            var altered = components; altered.queryItems![index].value = "tampered"
            XCTAssertThrowsError(try validate(payload, altered.url!))
        }
        var duplicated = components; duplicated.queryItems!.append(URLQueryItem(name: "state", value: state))
        XCTAssertThrowsError(try validate(payload, duplicated.url!))
        for override in [["tokenEndpoint": "https://other.example.invalid/token"], ["tokenEndpoint": "http://iam.example.invalid/token"],
                         ["redirectUri": "https://other.example.invalid/callback"], ["state": "mismatched-state"], ["clientId": ""]] {
            XCTAssertThrowsError(try validate(payload.merging(override) { _, value in value }, components.url!))
        }
        XCTAssertThrowsError(try validate(["tokenEndpoint": payload["tokenEndpoint"]!], components.url!))
    }
}
