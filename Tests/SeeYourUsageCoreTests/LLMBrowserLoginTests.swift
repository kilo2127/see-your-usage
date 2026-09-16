import Foundation
import Security
import XCTest
@testable import SeeYourUsageCore
@testable import SeeYourUsage

private final class BrowserLoginProtocol: URLProtocol, @unchecked Sendable {
    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: [String]] = [:]
        func record(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            values[url.host!, default: []].append(url.path)
        }
        func paths(_ host: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            return values[host, default: []]
        }
    }
    static let requests = Requests()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let host = url.host!
        Self.requests.record(url)
        var status = 200
        let payload: [String: Any]
        switch url.path {
        case "/llm/api/cli/auth/session":
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            payload = ["authorizeUrl": "https://\(host.hasPrefix("unsafe") ? "other.example.invalid" : host)/authorize",
                       "expiresIn": 300, "pollIntervalMs": 1]
        case "/llm/api/cli/auth/poll":
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNotNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
            if host.hasPrefix("pending") { payload = ["status": "pending"] }
            else if host.hasPrefix("denied") { payload = ["status": "denied"] }
            else { payload = ["status": "completed", "webToken": "synthetic-browser-token"] }
        case "/llm/api/department/my/quota-overview":
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertTrue(["Bearer synthetic-browser-token", "Bearer synthetic-expired-token"].contains(authorization))
            if host.hasPrefix("rejected") || authorization == "Bearer synthetic-expired-token" { status = 401 }
            if host.hasPrefix("offline") { status = 503 }
            payload = ["hasDept": true, "monthlyLimit": "7000", "monthlyUsed": "100",
                       "monthlyRemaining": "6900", "todayUsed": "12.3"]
        default:
            XCTFail("Unexpected request path: \(url.path)")
            payload = [:]
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        let data = try! JSONSerialization.data(withJSONObject: ["code": status, "data": payload])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class BrowserCredentialMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func read() -> (OSStatus, Data?) {
        lock.lock(); defer { lock.unlock() }
        return (data == nil ? errSecItemNotFound : errSecSuccess, data)
    }
    func write(_ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        data = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func store(origin: String) -> LLMTokenStore {
        LLMTokenStore(readItem: { _ in self.read() }, updateItem: { _, attributes in self.write(attributes) },
            addItem: { self.write($0) }, accountPrefix: "oidcSession@", originProvider: { origin })
    }
}

private actor BrowserCleanupRecorder {
    var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

final class LLMBrowserLoginTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ kind: String = "valid") -> (LLMCenterService, BrowserCredentialMemory, URL) {
        let url = URL(string: "https://\(kind)-\(UUID().uuidString.lowercased()).example.invalid")!
        let memory = BrowserCredentialMemory()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowserLoginProtocol.self]
        let empty = BrowserCredentialMemory()
        let service = LLMCenterService(session: URLSession(configuration: configuration), endpoint: url,
            tokens: empty.store(origin: url.absoluteString), authenticationStore: memory.store(origin: url.absoluteString))
        return (service, memory, url)
    }

    func testBrowserAuthorizationPersistsAndSurvivesRestart() async throws {
        let (service, memory, url) = fixture()
        defer { service.session.invalidateAndCancel() }
        let login = try await service.beginLogin()
        XCTAssertEqual(login.state.count, 64)
        XCTAssertEqual(login.origin, url.absoluteString)
        XCTAssertEqual(login.pollInterval, 2)
        let quota = try await service.completeBrowserLogin(login)
        XCTAssertEqual(quota.monthlyRemaining, 6900)
        let repeated = try await service.fetchUsage()
        XCTAssertEqual(repeated.todayUsed, Decimal(string: "12.3"))
        let restarted = LLMAuthentication(session: service.session, store: memory.store(origin: url.absoluteString))
        let token = try await restarted.accessToken(origin: url.absoluteString)
        XCTAssertEqual(token, "synthetic-browser-token")
        do {
            _ = try await restarted.accessToken(origin: url.absoluteString, rejectedToken: token)
            XCTFail("An expired browser token cannot silently renew")
        } catch { XCTAssertEqual(error as? LLMCenterError, .loginRequired) }
        XCTAssertEqual(BrowserLoginProtocol.requests.paths(url.host!), [
            "/llm/api/cli/auth/session", "/llm/api/cli/auth/poll",
            "/llm/api/department/my/quota-overview", "/llm/api/department/my/quota-overview"])
    }

    func testFailedVerificationKeepsPreviousCredentials() async throws {
        let (service, memory, url) = fixture("rejected")
        defer { service.session.invalidateAndCancel() }
        try await service.authentication.acceptBrowserToken("previous-account", origin: url.absoluteString)
        let before = memory.read().1
        let login = try await service.beginLogin()
        do { _ = try await service.completeBrowserLogin(login); XCTFail() }
        catch { XCTAssertEqual(error as? LLMCenterError, .loginRequired) }
        XCTAssertEqual(memory.read().1, before)
    }

    func testBrowserSessionReplacesOldRenewalWithoutRevivingOldAccount() async throws {
        let (service, memory, url) = fixture()
        defer { service.session.invalidateAndCancel() }
        let old = LLMRenewableSession(origin: url.absoluteString, issuer: url,
            tokenEndpoint: url.appendingPathComponent("token"), clientID: "synthetic-client",
            accessToken: "old-account", refreshToken: "old-refresh", expiresAt: .distantPast)
        _ = memory.write([kSecValueData as String: try JSONEncoder().encode(old)])
        let login = try await service.beginLogin()
        _ = try await service.completeBrowserLogin(login)
        let restarted = LLMCenterService(session: service.session, endpoint: url,
            authenticationStore: memory.store(origin: url.absoluteString))
        _ = try await restarted.fetchUsage()
        XCTAssertFalse(BrowserLoginProtocol.requests.paths(url.host!).contains("/token"))
    }

    func testUnsafeAuthorizationURLIsRejectedBeforeBrowserOpen() async throws {
        let (service, _, _) = fixture("unsafe")
        defer { service.session.invalidateAndCancel() }
        do { _ = try await service.beginLogin(); XCTFail() }
        catch { XCTAssertEqual(error as? LLMCenterError, .unsafeURL) }
    }

    func testExpiredTokenRecoversThroughNewTabAndPersistsNewAuthorization() async throws {
        let (service, memory, url) = fixture()
        defer { service.session.invalidateAndCancel() }
        let oldURL = url.appendingPathComponent("authorize-old")
        try await service.authentication.acceptBrowserToken("synthetic-expired-token", origin: url.absoluteString, authorizationURL: oldURL)
        let quota = try await service.fetchUsage { previous, next in
            XCTAssertEqual(previous, oldURL)
            XCTAssertEqual(next, url.appendingPathComponent("authorize"))
        }
        XCTAssertEqual(quota.monthlyRemaining, 6900)
        let restarted = LLMAuthentication(session: service.session, store: memory.store(origin: url.absoluteString))
        let linkedURL = try await restarted.browserAuthorizationURL(origin: url.absoluteString)
        XCTAssertEqual(linkedURL, url.appendingPathComponent("authorize"))
        _ = try await service.fetchUsage { _, _ in XCTFail("Healthy token must not touch Safari") }
        XCTAssertEqual(BrowserLoginProtocol.requests.paths(url.host!), [
            "/llm/api/department/my/quota-overview", "/llm/api/cli/auth/session", "/llm/api/cli/auth/poll",
            "/llm/api/department/my/quota-overview", "/llm/api/department/my/quota-overview"])
    }

    func testTemporaryTabCleanupOnSuccessDenialAndRejectedToken() async throws {
        for kind in ["valid", "denied", "rejected"] {
            let (service, _, url) = fixture(kind)
            defer { service.session.invalidateAndCancel() }
            try await service.authentication.acceptBrowserToken("synthetic-expired-token", origin: url.absoluteString,
                authorizationURL: url.appendingPathComponent("closed-original-tab"))
            let cleanup = BrowserCleanupRecorder()
            do {
                _ = try await service.fetchUsage(reconnect: { _, _ in }, finishReconnect: { await cleanup.record($0) })
                XCTAssertEqual(kind, "valid")
            } catch {
                XCTAssertEqual(error as? LLMCenterError, kind == "denied" ? .loginExpired : .loginRequired)
                XCTAssertNotEqual(kind, "valid")
            }
            let closed = await cleanup.urls
            XCTAssertEqual(closed, [url.appendingPathComponent("authorize")])
        }
    }

    func testTemporaryTabCleanupOnOpenFailureAndCancellation() async throws {
        for cancel in [false, true] {
            let (service, memory, url) = fixture("pending")
            defer { service.session.invalidateAndCancel() }
            try await service.authentication.acceptBrowserToken("synthetic-expired-token", origin: url.absoluteString,
                authorizationURL: url.appendingPathComponent("closed-original-tab"))
            let cleanup = BrowserCleanupRecorder()
            let before = memory.read().1
            let task = Task {
                try await service.fetchUsage(reconnect: { _, _ in
                    if !cancel { throw LLMCenterError.browserUnavailable }
                }, finishReconnect: { await cleanup.record($0) })
            }
            if cancel {
                while !BrowserLoginProtocol.requests.paths(url.host!).contains("/llm/api/cli/auth/poll") { await Task.yield() }
                task.cancel()
            }
            do { _ = try await task.value; XCTFail() }
            catch is CancellationError { XCTAssertTrue(cancel) }
            catch {
                if cancel { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
                else { XCTAssertEqual(error as? LLMCenterError, .browserUnavailable) }
            }
            let closed = await cleanup.urls
            XCTAssertEqual(closed, [url.appendingPathComponent("authorize")])
            if !cancel { XCTAssertEqual(memory.read().1, before) }
            let token = try await service.authentication.accessToken(origin: url.absoluteString)
            XCTAssertEqual(token, "synthetic-expired-token")
        }
    }

    func testMissingPermissionOrTabDoesNotPollOrReplaceCredentials() async throws {
        for expected in [LLMCenterError.browserAutomationRequired, .browserTabMissing] {
            let (service, memory, url) = fixture()
            defer { service.session.invalidateAndCancel() }
            try await service.authentication.acceptBrowserToken("synthetic-expired-token", origin: url.absoluteString,
                authorizationURL: url.appendingPathComponent("authorize-old"))
            let before = memory.read().1
            do {
                _ = try await service.fetchUsage { _, _ in throw expected }
                XCTFail()
            } catch { XCTAssertEqual(error as? LLMCenterError, expected) }
            XCTAssertEqual(memory.read().1, before)
            XCTAssertEqual(BrowserLoginProtocol.requests.paths(url.host!), [
                "/llm/api/department/my/quota-overview", "/llm/api/cli/auth/session"])
        }
    }

    func testRejectedReplacementDoesNotLoopOrOverwriteOldSession() async throws {
        let (service, _, url) = fixture("rejected")
        defer { service.session.invalidateAndCancel() }
        try await service.authentication.acceptBrowserToken("synthetic-expired-token", origin: url.absoluteString,
            authorizationURL: url.appendingPathComponent("authorize-old"))
        do { _ = try await service.fetchUsage { _, _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? LLMCenterError, .loginRequired) }
        let preserved = try await service.authentication.accessToken(origin: url.absoluteString)
        let tracked = try await service.authentication.browserAuthorizationURL(origin: url.absoluteString)
        XCTAssertEqual(preserved, "synthetic-expired-token")
        XCTAssertEqual(tracked, url.appendingPathComponent("authorize"))
        XCTAssertEqual(BrowserLoginProtocol.requests.paths(url.host!).filter { $0 == "/llm/api/cli/auth/session" }.count, 1)
    }

    func testOutageDoesNotTouchSafariAndUnlinkedSessionsRequireExplicitLogin() async throws {
        for (kind, linked, expected) in [("offline", true, LLMCenterError.http(503)), ("valid", false, .loginRequired)] {
            let (service, _, url) = fixture(kind)
            defer { service.session.invalidateAndCancel() }
            try await service.authentication.acceptBrowserToken("synthetic-expired-token", origin: url.absoluteString,
                authorizationURL: linked ? url.appendingPathComponent("authorize-old") : nil)
            do {
                _ = try await service.fetchUsage { _, _ in XCTFail("Must not request browser recovery") }
                XCTFail()
            } catch { XCTAssertEqual(error as? LLMCenterError, expected) }
            XCTAssertEqual(BrowserLoginProtocol.requests.paths(url.host!), ["/llm/api/department/my/quota-overview"])
        }
    }

    func testLinkedTabMustBelongToPlatformOrigin() async throws {
        let (service, memory, url) = fixture()
        defer { service.session.invalidateAndCancel() }
        do {
            try await service.authentication.acceptBrowserToken("synthetic-browser-token", origin: url.absoluteString,
                authorizationURL: URL(string: "https://other.example.invalid/authorize")!)
            XCTFail()
        } catch { XCTAssertEqual(error as? LLMCenterError, .unsafeURL) }
        XCTAssertNil(memory.read().1)
    }

    @MainActor
    func testSafariScriptCompilesWithoutExecutingOrRequestingPermission() throws {
        let script = try XCTUnwrap(NSAppleScript(source: SafariAuthorizationTab.source))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])")
    }

    func testCancellationStopsPendingPollingAndDoesNotSave() async throws {
        let (service, memory, url) = fixture("pending")
        defer { service.session.invalidateAndCancel() }
        let login = try await service.beginLogin()
        let task = Task { try await service.completeBrowserLogin(login) }
        while !BrowserLoginProtocol.requests.paths(url.host!).contains("/llm/api/cli/auth/poll") { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail() }
        catch is CancellationError {}
        catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
        XCTAssertNil(memory.read().1)
        XCTAssertEqual(BrowserLoginProtocol.requests.paths(url.host!).count, 2)
    }

    func testExpiredAndDifferentOriginSessionsNeverPoll() async throws {
        let (service, _, url) = fixture()
        defer { service.session.invalidateAndCancel() }
        for (origin, expiration, expected) in [
            (url.absoluteString, Date.distantPast, LLMCenterError.loginExpired),
            ("https://other.example.invalid", Date.distantFuture, .configurationRequired)
        ] {
            let login = LLMCenterService.LoginSession(origin: origin, state: "synthetic-state", url: url,
                expiresAt: expiration, pollInterval: 2)
            do { _ = try await service.completeBrowserLogin(login); XCTFail() }
            catch { XCTAssertEqual(error as? LLMCenterError, expected) }
        }
        XCTAssertTrue(BrowserLoginProtocol.requests.paths(url.host!).isEmpty)
        do {
            _ = try await service.fetchUsage(token: "must-not-be-sent", expectedOrigin: "https://other.example.invalid")
            XCTFail("Credential origin mismatch should fail before sending")
        } catch { XCTAssertEqual(error as? LLMCenterError, .configurationRequired) }
        XCTAssertTrue(BrowserLoginProtocol.requests.paths(url.host!).isEmpty)
    }

    @MainActor
    func testStartupWithMissingCredentialsDoesNotBeginBrowserAuthorization() async throws {
        let (service, _, url) = fixture()
        defer { service.session.invalidateAndCancel() }
        let store = UsageStore(initialState: UsageViewState(provider: .llmCenter))
        let coordinator = RefreshCoordinator(store: store, llmService: service)
        defer { coordinator.stop() }
        coordinator.start()
        for _ in 0..<100 where !store.state.needsLogin { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.state.needsLogin)
        XCTAssertFalse(store.state.isLoggingIn)
        XCTAssertTrue(BrowserLoginProtocol.requests.paths(url.host!).isEmpty)
    }
}
