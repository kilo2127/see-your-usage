import Foundation
import Security
import LocalAuthentication
import XCTest
@testable import SeeYourUsageCore

final class KeychainTests: XCTestCase {
    private func assertNoninteractive(_ query: [String: Any]) {
        XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
    }

    func testRefreshReadsKeychainOnlyOnce() throws {
        var reads = 0
        let store = LLMTokenStore(readItem: { query in
            self.assertNoninteractive(query)
            reads += 1
            return (errSecSuccess, Data("fixture".utf8))
        }, updateItem: { _, _ in XCTFail(); return errSecParam }, addItem: { _ in XCTFail(); return errSecParam })
        for _ in 0..<20 { XCTAssertEqual(try store.load(), "fixture") }
        XCTAssertEqual(reads, 1)
    }

    func testDeniedAccessNeverRetriesOrBecomesAutomaticBrowserLogin() throws {
        var reads = 0
        let store = LLMTokenStore(readItem: { query in
            self.assertNoninteractive(query)
            reads += 1
            return (errSecInteractionNotAllowed, nil)
        }, updateItem: { _, _ in XCTFail(); return errSecParam }, addItem: { _ in XCTFail(); return errSecParam })
        for _ in 0..<20 {
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? LLMCenterError, .keychainUnavailable) }
        }
        XCTAssertEqual(reads, 1)
    }

    func testDeniedSaveKeepsOnlyInMemoryTokenAndNeverAddsAnotherItem() throws {
        let store = LLMTokenStore(readItem: { _ in XCTFail(); return (errSecParam, nil) }, updateItem: { query, _ in
            self.assertNoninteractive(query)
            return errSecInteractionNotAllowed
        }, addItem: { _ in XCTFail(); return errSecParam })
        XCTAssertFalse(try store.save("fixture-new-login"))
        XCTAssertEqual(try store.load(), "fixture-new-login")
    }

    func testFirstLoginSaveAlsoForbidsSystemPrompts() throws {
        let store = LLMTokenStore(readItem: { _ in XCTFail(); return (errSecParam, nil) }, updateItem: { query, _ in
            self.assertNoninteractive(query)
            return errSecItemNotFound
        }, addItem: { query in
            self.assertNoninteractive(query)
            return errSecSuccess
        })
        XCTAssertTrue(try store.save("fixture-first-login"))
        XCTAssertEqual(try store.load(), "fixture-first-login")
    }
}
