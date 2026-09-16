import Foundation

public struct LLMBrowserCredentials: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let issuer: URL
    public let clientID: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, issuer: URL, clientID: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.issuer = issuer
        self.clientID = clientID
        self.expiresAt = expiresAt
    }
}

struct LLMRenewableSession: Codable, Sendable {
    let origin: String
    let issuer: URL
    let tokenEndpoint: URL
    let clientID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

private struct LLMDeviceSession: Codable {
    let origin: String
    let webToken: String
    let authorizationURL: URL?
}

public actor LLMAuthentication {
    private let session: URLSession
    private let store: LLMTokenStore
    private var renewal: (id: UUID, origin: String, task: Task<LLMRenewableSession, Error>)?
    private var persistenceFailed = false

    public init(session: URLSession, store: LLMTokenStore = LLMTokenStore(accountPrefix: "oidcSession@")) {
        self.session = session
        self.store = store
    }

    public var credentialsArePersistent: Bool { !persistenceFailed }

    public func acceptBrowserToken(_ token: String, origin: String, authorizationURL: URL? = nil) async throws {
        // Finish any rotating grant before replacing the selected account.
        if let renewal { _ = try? await renewal.task.value }
        try Task.checkCancellation()
        guard !token.isEmpty else { throw LLMCenterError.invalidResponse }
        if let authorizationURL {
            guard let platform = URL(string: origin), Self.sameOrigin(platform, authorizationURL),
                  authorizationURL.fragment == nil else { throw LLMCenterError.unsafeURL }
        }
        let encoded = try JSONEncoder().encode(LLMDeviceSession(origin: origin, webToken: token, authorizationURL: authorizationURL))
        persistenceFailed = try !store.save(String(decoding: encoded, as: UTF8.self), expectedOrigin: origin)
    }

    public func browserAuthorizationURL(origin: String) throws -> URL? {
        let raw = try store.load(expectedOrigin: origin)
        guard let browser = try? JSONDecoder().decode(LLMDeviceSession.self, from: Data(raw.utf8)),
              browser.origin == origin, let url = browser.authorizationURL,
              let platform = URL(string: origin), Self.sameOrigin(platform, url), url.fragment == nil else { return nil }
        return url
    }

    public func trackBrowserAuthorizationURL(origin: String, previousURL: URL, nextURL: URL) throws {
        try Task.checkCancellation()
        guard let platform = URL(string: origin), Self.sameOrigin(platform, nextURL), nextURL.fragment == nil else {
            throw LLMCenterError.unsafeURL
        }
        let raw = try store.load(expectedOrigin: origin)
        guard let current = try? JSONDecoder().decode(LLMDeviceSession.self, from: Data(raw.utf8)),
              current.origin == origin, current.authorizationURL == previousURL else { throw LLMCenterError.loginRequired }
        // Keep tracking the tab if polling is interrupted, without changing credentials.
        let updated = LLMDeviceSession(origin: origin, webToken: current.webToken, authorizationURL: nextURL)
        let encoded = try JSONEncoder().encode(updated)
        persistenceFailed = try !store.save(String(decoding: encoded, as: UTF8.self), expectedOrigin: origin)
    }

    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme == "https" && b.scheme == "https" && a.host != nil &&
        a.host?.lowercased() == b.host?.lowercased() && (a.port ?? 443) == (b.port ?? 443) &&
        a.user == nil && a.password == nil && b.user == nil && b.password == nil
    }

    // The issuer is accepted only after the login window has visited its HTTPS origin.
    public func accept(_ credentials: LLMBrowserCredentials, origin: String) async throws {
        if let renewal { _ = try? await renewal.task.value }
        guard !credentials.accessToken.isEmpty, !credentials.refreshToken.isEmpty,
              !credentials.clientID.isEmpty, credentials.issuer.query == nil,
              credentials.issuer.fragment == nil,
              Self.sameOrigin(credentials.issuer, credentials.issuer) else {
            throw LLMCenterError.renewalUnavailable
        }
        let discovery = credentials.issuer.appendingPathComponent(".well-known/openid-configuration")
        let (data, response) = try await session.data(for: URLRequest(url: discovery))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.issuer == credentials.issuer,
              Self.sameOrigin(metadata.token_endpoint, credentials.issuer),
              metadata.token_endpoint.query == nil, metadata.token_endpoint.fragment == nil,
              metadata.grant_types_supported.contains("refresh_token") else {
            throw LLMCenterError.unsafeURL
        }
        let value = LLMRenewableSession(origin: origin, issuer: credentials.issuer,
            tokenEndpoint: metadata.token_endpoint, clientID: credentials.clientID,
            accessToken: credentials.accessToken, refreshToken: credentials.refreshToken,
            expiresAt: credentials.expiresAt)
        // Exercise the real renewal grant at login so unsupported sessions fail immediately.
        _ = try await renew(value)
    }

    public func accessToken(origin: String, rejectedToken: String? = nil) async throws -> String {
        let raw = try store.load(expectedOrigin: origin)
        if let browser = try? JSONDecoder().decode(LLMDeviceSession.self, from: Data(raw.utf8)) {
            guard browser.origin == origin, !browser.webToken.isEmpty,
                  browser.webToken != rejectedToken else { throw LLMCenterError.loginRequired }
            return browser.webToken
        }
        guard let value = try? JSONDecoder().decode(LLMRenewableSession.self, from: Data(raw.utf8)),
              value.origin == origin, Self.sameOrigin(value.issuer, value.tokenEndpoint) else {
            throw LLMCenterError.loginRequired
        }
        if value.expiresAt.timeIntervalSinceNow > 60 && rejectedToken != value.accessToken {
            return value.accessToken
        }
        return try await renew(value).accessToken
    }

    public func hasSession(origin: String) throws -> Bool {
        do { _ = try store.load(expectedOrigin: origin); return true }
        catch LLMCenterError.loginRequired { return false }
    }

    private func renew(_ value: LLMRenewableSession) async throws -> LLMRenewableSession {
        if let renewal, renewal.origin == value.origin { return try await renewal.task.value }
        let id = UUID()
        let session = self.session
        let store = self.store
        // A rotating grant must finish and persist even if its quota request is cancelled.
        let task = Task { () throws -> LLMRenewableSession in
            var request = URLRequest(url: value.tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = Self.form([
                "grant_type": "refresh_token", "client_id": value.clientID,
                "refresh_token": value.refreshToken
            ])
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw LLMCenterError.invalidResponse }
            if response.statusCode == 400 || response.statusCode == 401 {
                let error = try? JSONDecoder().decode(OAuthError.self, from: data)
                if error?.error == "invalid_grant" || error?.error == "invalid_client" || response.statusCode == 401 {
                    throw LLMCenterError.loginRequired
                }
            }
            guard response.statusCode == 200 else { throw LLMCenterError.http(response.statusCode) }
            guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data),
                  !tokens.access_token.isEmpty, tokens.expires_in > 0,
                  tokens.expires_in.isFinite, tokens.token_type.lowercased() == "bearer" else {
                throw LLMCenterError.invalidResponse
            }
            var next = value
            next.accessToken = tokens.access_token
            if let replacement = tokens.refresh_token {
                guard !replacement.isEmpty else { throw LLMCenterError.invalidResponse }
                next.refreshToken = replacement
            }
            next.expiresAt = Date().addingTimeInterval(tokens.expires_in)
            let encoded = try JSONEncoder().encode(next)
            let saved = try store.save(String(decoding: encoded, as: UTF8.self), expectedOrigin: value.origin)
            self.persistenceFailed = !saved
            return next
        }
        renewal = (id, value.origin, task)
        defer { if renewal?.id == id { renewal = nil } }
        return try await task.value
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" +
            $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }

    private struct Metadata: Decodable {
        let issuer: URL
        let token_endpoint: URL
        let grant_types_supported: [String]
    }
    private struct OAuthError: Decodable { let error: String }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: TimeInterval
        let token_type: String
    }
}
