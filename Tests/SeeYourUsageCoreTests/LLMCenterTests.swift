import Foundation
import XCTest
@testable import SeeYourUsageCore

final class LLMCenterTests: XCTestCase {
    private func data(_ overrides: [String: Any] = [:]) throws -> Data {
        var payload: [String: Any] = [
            "hasDept": true, "monthlyLimit": "7000.00", "monthlyUsed": 1180,
            "monthlyRemaining": "5820.00", "todayUsed": "86.40",
            "refreshTime": "2026-09-14 10:42:00", "nextResetTime": "2026-10-01 00:00:00"
        ]
        payload.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["code": 200, "success": true, "data": payload])
    }

    func testActualPlatformCamelCaseSchemaAndDecimalMoney() throws {
        let quota = try LLMQuotaSnapshot.decode(data())
        XCTAssertEqual(quota.monthlyRemaining, Decimal(5820))
        XCTAssertEqual(quota.todayUsed, Decimal(string: "86.40"))
        XCTAssertEqual(quota.remainingPercent, 83.142857, accuracy: 0.00001)
        XCTAssertEqual(QuotaFormatting.timestamp(quota.nextReset!, format: "yyyy-MM-dd HH:mm"), "2026-10-01 00:00")
    }

    func testJSONZeroAndOneAreMoneyNotBooleans() throws {
        let quota = try LLMQuotaSnapshot.decode(data(["todayUsed": 0, "monthlyUsed": 1, "monthlyRemaining": 0]))
        XCTAssertEqual(quota.todayUsed, 0)
        XCTAssertEqual(quota.monthlyUsed, 1)
        XCTAssertEqual(quota.monthlyRemaining, 0)
        XCTAssertThrowsError(try LLMQuotaSnapshot.decode(data(["todayUsed": true])))
    }

    func testMissingInvalidAmountsNeverBecomeZero() throws {
        for invalid: Any in [NSNull(), "", "invalid", "NaN", true] {
            XCTAssertThrowsError(try LLMQuotaSnapshot.decode(data(["todayUsed": invalid])))
        }
        XCTAssertThrowsError(try LLMQuotaSnapshot.decode(Data(#"{"code":200,"data":{}}"#.utf8)))
        XCTAssertThrowsError(try LLMQuotaSnapshot.decode(Data(#"{"code":200,"success":false,"data":{}}"#.utf8)))
    }

    func testExpiredLoginEnvelope() {
        XCTAssertThrowsError(try LLMQuotaSnapshot.decode(Data(#"{"code":401,"message":"secret must not surface"}"#.utf8))) {
            XCTAssertEqual($0 as? LLMCenterError, .loginRequired)
            XCTAssertFalse($0.localizedDescription.contains("secret"))
        }
    }

    func testBeijingMidnightInvalidatesTodayButNotMonth() throws {
        let quota = try LLMQuotaSnapshot.decode(data())
        let iso = ISO8601DateFormatter()
        XCTAssertTrue(quota.isCurrentDay(at: iso.date(from: "2026-09-14T15:59:59Z")!))
        XCTAssertFalse(quota.isCurrentDay(at: iso.date(from: "2026-09-14T16:00:00Z")!))
        XCTAssertTrue(quota.isCurrentMonth(at: iso.date(from: "2026-09-14T16:00:00Z")!))
        XCTAssertFalse(quota.isCurrentMonth(at: iso.date(from: "2026-09-30T16:00:00Z")!))
    }

    func testZeroBudgetAndNegativeRemaining() throws {
        let zero = try LLMQuotaSnapshot.decode(data(["monthlyLimit": 0, "monthlyRemaining": 0, "hasDept": false]))
        XCTAssertEqual(zero.remainingPercent, 0)
        XCTAssertFalse(zero.hasTeam)
        let negative = try LLMQuotaSnapshot.decode(data(["monthlyRemaining": "-12.34"]))
        XCTAssertEqual(negative.monthlyRemaining, Decimal(string: "-12.34"))
        XCTAssertEqual(negative.remainingPercent, 0)
    }

    func testMenuFormattingFitsCompactWidthAndDoesNotOverstateBalance() {
        XCTAssertEqual(QuotaFormatting.amount(5820, compact: true), "¥5,820")
        XCTAssertEqual(QuotaFormatting.amount(Decimal(string: "86.49")!, compact: true), "¥86")
        XCTAssertEqual(QuotaFormatting.amount(Decimal(string: "86.40")!), "¥86")
        XCTAssertEqual(QuotaFormatting.amount(1234567, compact: true), "¥123万")
        XCTAssertEqual(QuotaFormatting.amount(0), "¥0")
        XCTAssertEqual(QuotaFormatting.today(0), "Nah")
        XCTAssertEqual(QuotaFormatting.today(0, compact: true), "Nah")
        XCTAssertEqual(QuotaFormatting.today(Decimal(string: "0.9")!), "¥0")
        XCTAssertEqual(QuotaFormatting.amount(Decimal(string: "6044.99")!), "¥6,044")
    }
}
