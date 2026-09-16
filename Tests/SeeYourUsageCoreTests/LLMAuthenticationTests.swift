import Foundation
import Security
import XCTest
@testable import SeeYourUsageCore

private final class RenewalProtocol: URLProtocol, @unchecked Sendable {
    final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Int] = [:]
        func next(_ host: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            values[host, default: 0] += 1
            return values[host]!
        }
        func get(_ host: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return values[host, default: 0]
        }
    }
    static let counts = Counts()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let host = url.host!
        var status = 200
        let body: [String: Any]
        if url.path.hasSuffix("openid-configuration") {
            let issuer = "https://\(host)/oauth2"
            body = ["issuer": issuer, "token_endpoint": host.hasPrefix("unsafe") ? "https://other.example.invalid/token" : "https://\(host)/token",
                    "grant_types_supported": ["refresh_token"]]
        } else {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            let index = Self.counts.next(host)
            if host.hasPrefix("invalid") {
                status = 400
                body = ["error": "invalid_grant", "error_description": "sensitive server message"]
            } else if host.hasPrefix("offline") {
                status = 503
                body = ["error": "temporarily_unavailable"]
            } else {
                body = ["access_token": "access-\(index)", "refresh_token": "rotated-\(index)",
                        "expires_in": 3600, "token_type": "Bearer"]
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        let data = try! JSONSerialization.data(withJSONObject: body)
        let deliver: @Sendable () -> Void = {
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if host.hasPrefix("slow") { DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: deliver) }
        else { deliver() }
    }
    override func stopLoading() {}
}

final class LLMAuthenticationTests: XCTestCase, @unchecked Sendable {
    private let origin = "https://quota.example.invalid"

    private func fixture(_ kind: String = "valid", expiresAt: Date = .distantPast) throws -> (LLMAuthentication, LLMTokenStore, URLSession, URL) {
        let host = "\(kind)-\(UUID().uuidString.lowercased()).example.invalid"
        let issuer = URL(string: "https://\(host)/oauth2")!
        let value = LLMRenewableSession(origin: origin, issuer: issuer,
            tokenEndpoint: URL(string: "https://\(host)/token")!, clientID: "test-client",
            accessToken: "old-access", refreshToken: "old-refresh", expiresAt: expiresAt)
        let data = try JSONEncoder().encode(value)
        let origin = self.origin
        let store = LLMTokenStore(readItem: { _ in (errSecSuccess, data) },
            updateItem: { _, _ in errSecSuccess }, addItem: { _ in errSecSuccess },
            accountPrefix: "oidcSession@", originProvider: { origin })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RenewalProtocol.self]
        let session = URLSession(configuration: configuration)
        return (LLMAuthentication(session: session, store: store), store, session, issuer)
    }

    func testExpiryRenewsAndPersistsRotatedPair() async throws {
        let (auth, store, session, issuer) = try fixture()
        defer { session.invalidateAndCancel() }
        let token = try await auth.accessToken(origin: origin)
        XCTAssertEqual(token, "access-1")
        for _ in 0..<20 {
            let cached = try await auth.accessToken(origin: origin)
            XCTAssertEqual(cached, "access-1")
        }
        let stored = try JSONDecoder().decode(LLMRenewableSession.self, from: Data(store.load().utf8))
        XCTAssertEqual(stored.refreshToken, "rotated-1")
        XCTAssertEqual(stored.accessToken, "access-1")
        XCTAssertEqual(RenewalProtocol.counts.get(issuer.host!), 1)
        let restarted = LLMAuthentication(session: session, store: store)
        let reused = try await restarted.accessToken(origin: origin)
        XCTAssertEqual(reused, "access-1")
    }

    func testRejectedTokenRenewalIsDeduplicated() async throws {
        let (auth, _, session, issuer) = try fixture(expiresAt: Date().addingTimeInterval(3600))
        defer { session.invalidateAndCancel() }
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await auth.accessToken(origin: self.origin, rejectedToken: "old-access") } }
            var values: [String] = []
            for try await token in group { values.append(token) }
            return values
        }
        XCTAssertEqual(Set(tokens), ["access-1"])
        XCTAssertEqual(RenewalProtocol.counts.get(issuer.host!), 1)
    }

    func testLoginVerifiesRenewalBeforeAcceptingCredentials() async throws {
        let (auth, _, session, issuer) = try fixture()
        defer { session.invalidateAndCancel() }
        try await auth.accept(LLMBrowserCredentials(accessToken: "browser-access", refreshToken: "browser-refresh",
            issuer: issuer, clientID: "test-client", expiresAt: Date().addingTimeInterval(3600)), origin: origin)
        let token = try await auth.accessToken(origin: origin)
        XCTAssertEqual(token, "access-1")
    }

    func testDiscoveryCannotSendCredentialsToAnotherOrigin() async throws {
        let (auth, _, session, issuer) = try fixture("unsafe")
        defer { session.invalidateAndCancel() }
        do {
            try await auth.accept(LLMBrowserCredentials(accessToken: "browser-access", refreshToken: "browser-refresh",
                issuer: issuer, clientID: "test-client", expiresAt: .distantFuture), origin: origin)
            XCTFail("Unsafe metadata was accepted")
        } catch { XCTAssertEqual(error as? LLMCenterError, .unsafeURL) }
        XCTAssertEqual(RenewalProtocol.counts.get(issuer.host!), 0)
    }

    func testExpiredRefreshRequiresLoginButOutageDoesNot() async throws {
        for (kind, expected) in [("invalid", LLMCenterError.loginRequired), ("offline", .http(503))] {
            let (auth, store, session, _) = try fixture(kind)
            defer { session.invalidateAndCancel() }
            do { _ = try await auth.accessToken(origin: origin); XCTFail("Failure was hidden") }
            catch {
                XCTAssertEqual(error as? LLMCenterError, expected)
                XCTAssertFalse(error.localizedDescription.contains("sensitive"))
            }
            XCTAssertTrue(try store.load().contains("old-refresh"))
        }
    }

    func testFormEscapesCredentialCharactersAndOriginsStayIsolated() async throws {
        let encoded = String(decoding: LLMAuthentication.form(["refresh_token": "a+b&c=d %"]), as: UTF8.self)
        XCTAssertEqual(encoded, "refresh_token=a%2Bb%26c%3Dd%20%25")
        let (auth, _, session, issuer) = try fixture()
        defer { session.invalidateAndCancel() }
        do { _ = try await auth.accessToken(origin: "https://different.example.invalid"); XCTFail() }
        catch { XCTAssertEqual(error as? LLMCenterError, .configurationRequired) }
        XCTAssertEqual(RenewalProtocol.counts.get(issuer.host!), 0)
    }

    func testCancellingCallerStillPersistsRotatingGrant() async throws {
        let (auth, store, session, issuer) = try fixture("slow")
        defer { session.invalidateAndCancel() }
        let task = Task { try await auth.accessToken(origin: self.origin) }
        while RenewalProtocol.counts.get(issuer.host!) == 0 { await Task.yield() }
        task.cancel()
        _ = try await task.value
        let stored = try JSONDecoder().decode(LLMRenewableSession.self, from: Data(store.load().utf8))
        XCTAssertEqual(stored.refreshToken, "rotated-1")
        XCTAssertEqual(stored.accessToken, "access-1")
    }
}
