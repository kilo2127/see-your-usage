import Foundation

public enum LLMCenterConfiguration {
    public static let defaultsKey = "llm-center-api-url"
    public static var baseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        return validatedURL(raw)
    }

    public static func validatedURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        parts.path = ""
        return parts.url
    }
}
