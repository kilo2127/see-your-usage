import Foundation
import CryptoKit
import Security

struct LLMPKCE: Sendable {
    let verifier: String
    let issuer: URL
    let tokenEndpoint: URL
    let clientID: String
    let redirectURI: URL

    static func makeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LLMCenterError.invalidResponse
        }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // Metadata comes from the configured platform over HTTPS. The authorization
    // and token endpoints must share an origin; the callback must return to the
    // platform. Bind every OAuth parameter before opening a browser or sending
    // the one-time code and its verifier to that issuer.
    static func validated(payload: [String: Any], platform: URL, authorizationURL: URL,
                          state: String, verifier: String) throws -> LLMPKCE? {
        let keys = ["tokenEndpoint", "clientId", "redirectUri"]
        guard keys.contains(where: { payload[$0] != nil }) else {
            guard LLMAuthentication.sameOrigin(platform, authorizationURL), authorizationURL.fragment == nil else {
                throw LLMCenterError.unsafeURL
            }
            return nil // Older servers can still return the original device flow.
        }
        guard let rawToken = payload["tokenEndpoint"] as? String, let token = URL(string: rawToken),
              let client = payload["clientId"] as? String, !client.isEmpty,
              let rawRedirect = payload["redirectUri"] as? String, let redirect = URL(string: rawRedirect),
              LLMAuthentication.sameOrigin(authorizationURL, token),
              LLMAuthentication.sameOrigin(platform, redirect),
              token.query == nil, token.fragment == nil, !token.path.isEmpty,
              redirect.query == nil, redirect.fragment == nil, authorizationURL.fragment == nil,
              let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false) else {
            throw LLMCenterError.unsafeURL
        }
        let items = components.queryItems ?? []
        let expected = ["state": state, "client_id": client, "redirect_uri": rawRedirect,
                        "response_type": "code", "code_challenge_method": "S256",
                        "code_challenge": challenge(for: verifier)]
        for (key, value) in expected {
            let matches = items.filter { $0.name == key }
            guard matches.count == 1, matches[0].value == value else { throw LLMCenterError.unsafeURL }
        }
        if let echoed = payload["state"] as? String, echoed != state { throw LLMCenterError.unsafeURL }
        var issuer = URLComponents(url: token, resolvingAgainstBaseURL: false)!
        issuer.path = ""
        return LLMPKCE(verifier: verifier, issuer: issuer.url!, tokenEndpoint: token,
                       clientID: client, redirectURI: redirect)
    }
}
