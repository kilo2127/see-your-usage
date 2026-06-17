import Foundation

public struct CodexCredentials: Equatable, Sendable {
    public let accessToken: String
    public let accountID: String?

    public init(accessToken: String, accountID: String?) {
        self.accessToken = accessToken
        self.accountID = accountID
    }
}

public struct AuthStore: Sendable {
    public var authFileURL: URL

    public init(authFileURL: URL = AuthStore.defaultAuthFileURL()) {
        self.authFileURL = authFileURL
    }

    public static func defaultAuthFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    public func loadCredentials() throws -> CodexCredentials {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            throw UsageFetchError.missingAuthFile(authFileURL.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: authFileURL)
        } catch {
            throw UsageFetchError.invalidAuthFile
        }

        do {
            let auth = try JSONDecoder().decode(CodexAuthFile.self, from: data)
            guard let token = auth.tokens.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                throw UsageFetchError.missingAccessToken
            }
            return CodexCredentials(accessToken: token, accountID: auth.tokens.accountID)
        } catch let error as UsageFetchError {
            throw error
        } catch {
            throw UsageFetchError.invalidAuthFile
        }
    }
}

private struct CodexAuthFile: Decodable {
    let tokens: Tokens

    struct Tokens: Decodable {
        let accessToken: String?
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}
