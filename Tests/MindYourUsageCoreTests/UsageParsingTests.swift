import Foundation
import Testing
@testable import MindYourUsageCore

@Test
func decodesCodexUsageWindows() throws {
    let json = """
    {
      "account_id": "acct",
      "plan_type": "prolite",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 87,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 215,
          "reset_at": 1781681954
        },
        "secondary_window": {
          "used_percent": 29,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 547360,
          "reset_at": 1782229100
        }
      },
      "additional_rate_limits": [
        {
          "limit_name": "GPT-5.3-Codex-Spark",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 0,
              "limit_window_seconds": 18000,
              "reset_at": 1781699740
            },
            "secondary_window": {
              "used_percent": 0,
              "limit_window_seconds": 604800,
              "reset_at": 1782286540
            }
          }
        }
      ],
      "credits": {
        "has_credits": false,
        "unlimited": false,
        "balance": "0"
      },
      "rate_limit_reset_credits": {
        "available_count": 2
      }
    }
    """

    let snapshot = try CodexUsageService.decodeSnapshot(
        from: Data(json.utf8),
        fetchedAt: Date(timeIntervalSince1970: 100)
    )

    #expect(snapshot.planType == "prolite")
    #expect(snapshot.window(kind: .fiveHour)?.usedPercent == 87)
    #expect(snapshot.window(kind: .fiveHour)?.remainingPercent == 13)
    #expect(snapshot.window(kind: .sevenDay)?.usedPercent == 29)
    #expect(snapshot.window(kind: .sevenDay)?.remainingPercent == 71)
    #expect(snapshot.resetCreditsAvailable == 2)
    #expect(snapshot.additionalLimits.first?.name == "GPT-5.3-Codex-Spark")
}

@Test
func clampsUsagePercentages() throws {
    let window = UsageWindow(
        kind: .fiveHour,
        usedPercent: 140,
        windowSeconds: 18_000,
        resetAt: nil,
        resetAfterSeconds: nil
    )

    #expect(window.usedPercent == 100)
    #expect(window.remainingPercent == 0)
    #expect(window.isBlocked)
}

@Test
func remainingBandsUseDisplayedThirds() {
    #expect(UsageRemainingBand.band(forRemainingPercent: 33.4) == .red)
    #expect(UsageRemainingBand.band(forRemainingPercent: 33.5) == .yellow)
    #expect(UsageRemainingBand.band(forRemainingPercent: 50) == .yellow)
    #expect(UsageRemainingBand.band(forRemainingPercent: 66.4) == .yellow)
    #expect(UsageRemainingBand.band(forRemainingPercent: 66.5) == .green)
    #expect(UsageRemainingBand.band(forRemainingPercent: 100) == .green)
}
