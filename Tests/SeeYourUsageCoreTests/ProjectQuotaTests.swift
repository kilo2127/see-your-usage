import AppKit
import Foundation
import Testing
@testable import SeeYourUsageCore
@testable import SeeYourUsage

private final class ProjectQuotaProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        var bytes = request.httpBody
        if bytes == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            bytes = data
        }
        let body = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let json: String
        switch url.path {
        case "/llm/api/app/list":
            #expect(request.httpMethod == "POST")
            let page = (body?["pageReq"] as? [String: Int])?["pageNum"]
            if page == 1 {
                json = #"{"code":0,"data":{"total":2,"data":[{"id":"10","appCode":"sample-project","appTitle":"示例项目","appType":"MEMBER","memberQuotaAmount":"10000","accountBalance":"50000","usedQuota":"12000"}]}}"#
            } else {
                #expect(page == 2)
                json = #"{"code":0,"data":{"total":2,"data":[{"id":"11","appCode":"restricted","appTitle":"另一项目","appType":"MEMBER","accountBalance":"-","usedQuota":"-"}]}}"#
            }
        case "/api/admin/auth/check/token":
            #expect(body?["token"] as? String == "fixture")
            json = #"{"code":"0000","data":{"id":"self"}}"#
        case "/llm/api/app/detail/10":
            json = #"{"code":0,"data":{"members":[{"userId":"other","memberQuotaLimit":50000,"memberUsedQuota":9999},{"userId":"self","memberQuotaLimit":12000,"memberUsedQuota":1363.41,"accessKey":"unused-fixture"}]}}"#
        case "/llm/api/app/usage-overview":
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "appCode", value: "sample-project")])
            json = #"{"code":0,"data":{"quotaAvailable":true,"quotaLimited":true,"availableQuota":10636.59}}"#
        case "/llm/api/usage/statistics":
            #expect(body?["scope"] as? String == "PROJECT")
            #expect(body?["freeUser"] as? Int == 0)
            #expect(body?["appCodes"] as? [String] == ["sample-project"])
            #expect(body?["accountIds"] as? [String] == ["self"])
            let day = QuotaFormatting.timestamp(Date(), format: "yyyy-MM-dd")
            #expect(body?["startDate"] as? String == day)
            #expect(body?["endDate"] as? String == day)
            json = #"{"code":0,"data":{"totalCost":86.49}}"#
        default:
            Issue.record("Unexpected request: \(url.path)")
            json = #"{"code":403}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func projectFixtureService() -> LLMCenterService {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProjectQuotaProtocol.self]
    return LLMCenterService(session: URLSession(configuration: config), endpoint: URL(string: "https://quota.example.invalid")!)
}

@Test func projectQuotaUsesOwnAllowanceAndOwnTodayCost() async throws {
    let service = projectFixtureService()
    defer { service.session.invalidateAndCancel() }
    let quota = try await service.fetchUsage(token: "fixture", scope: .project, projectCode: "sample-project")
    #expect(quota.scope == .project)
    #expect(quota.monthlyLimit == 12000)
    #expect(quota.monthlyRemaining == Decimal(string: "10636.59"))
    #expect(quota.monthlyUsed == Decimal(string: "1363.41"))
    #expect(quota.todayUsed == Decimal(string: "86.49"))
    #expect(quota.projects.count == 2)
    #expect(quota.nextReset == nil)
    #expect(quota.isCurrentMonth(at: Date().addingTimeInterval(60 * 60 * 24 * 40)))
    #expect(!quota.isCurrentDay(at: Date().addingTimeInterval(60 * 60 * 24 * 40)))
}

@Test func multipleProjectsRequireSelectionAndKeepAllPages() async throws {
    let service = projectFixtureService()
    defer { service.session.invalidateAndCancel() }
    for code in [nil, "removed-project"] as [String?] {
        do {
            _ = try await service.fetchUsage(token: "fixture", scope: .project, projectCode: code)
            Issue.record("Multiple projects must require selection")
        } catch let LLMCenterError.projectSelectionRequired(projects) {
            #expect(projects.map(\.appCode) == ["sample-project", "restricted"])
        }
    }
}

@Test @MainActor func switchingQuotaClearsOldAmountsAndRemembersSelection() async throws {
    let name = "see-your-usage.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let service = projectFixtureService()
    defer { service.session.invalidateAndCancel() }
    let quota = try await service.fetchUsage(token: "fixture", scope: .project, projectCode: "sample-project")
    let store = UsageStore(initialState: UsageViewState(provider: .llmCenter), defaults: defaults)
    store.selectQuota(scope: .project)
    store.setQuota(quota)
    #expect(store.state.quota?.todayUsed == Decimal(string: "86.49"))
    #expect(UsageStore.savedState(provider: .llmCenter, defaults: defaults).projectCode == "sample-project")
    store.selectQuota(scope: .personal)
    #expect(store.state.quota == nil)
    store.setQuota(quota) // An old project request must never repaint personal mode.
    #expect(store.state.quota == nil)
    #expect(UsageStore.savedState(provider: .llmCenter, defaults: defaults).quotaScope == .personal)
    store.selectQuota(scope: .project, projectCode: "restricted")
    store.setError(LLMCenterError.projectSelectionRequired(quota.projects))
    #expect(store.state.menuPrompt?.0 == "选择项目")
    #expect(!store.state.showsLoginAction)
}
