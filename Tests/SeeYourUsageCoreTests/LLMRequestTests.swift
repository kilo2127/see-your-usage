import Foundation
import Testing
@testable import SeeYourUsageCore

private final class QuotaProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var responseBody = ""
        var status = 200
        switch url.path {
        case "/llm/api/department/my/quota-overview":
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-fixture" {
                status = 401
                responseBody = #"{"message":"do not display this server body"}"#
            } else {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-test-fixture")
                responseBody = #"{"code":200,"data":{"hasDept":true,"monthlyLimit":7000,"monthlyUsed":1180,"monthlyRemaining":5820,"todayUsed":86.4}}"#
            }
        case "/llm/api/cli/auth/session":
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            responseBody = #"{"code":200,"data":{"authorizeUrl":"https://llm-center.example.invalid/cli-auth?state=fixture","expiresIn":300,"pollIntervalMs":1000}}"#
        case "/llm/api/cli/auth/poll":
            #expect(request.httpMethod == "GET")
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.name == "state")
            responseBody = #"{"code":200,"data":{"status":"completed","webToken":"local-test-fixture"}}"#
        default:
            Issue.record("Unexpected request path")
            status = 404
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func nativeQuotaAndLoginRequests() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [QuotaProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let service = LLMCenterService(session: session, endpoint: URL(string: "https://llm-center.example.invalid")!)
    let snapshot = try await service.fetchUsage(token: "local-test-fixture")
    #expect(snapshot.monthlyRemaining == 5820)
    #expect(snapshot.todayUsed == Decimal(string: "86.4"))
    do {
        _ = try await service.fetchUsage(token: "expired-fixture")
        Issue.record("Expired auth should fail")
    } catch {
        #expect(error as? LLMCenterError == .loginRequired)
        #expect(!error.localizedDescription.contains("server body"))
    }
    let login = try await service.beginLogin()
    #expect(login.pollInterval >= 2)
    #expect(login.expiresAt.timeIntervalSinceNow <= 300)
    #expect(login.state.count == 64)
    #expect(try await service.pollLogin(login) == "local-test-fixture")
}
