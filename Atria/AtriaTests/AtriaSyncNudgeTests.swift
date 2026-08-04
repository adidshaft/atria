import XCTest
@testable import Atria

/// Pure-decision coverage for the sync nudge (2026-08-05 user directive:
/// graceful measures when data lags). The nudge must fire only when the user
/// can actually fix the lag, and stay silent otherwise.
final class AtriaSyncNudgeTests: XCTestCase {
    private func content(level: String? = "high",
                         debtAge: TimeInterval? = 600,
                         flushAge: TimeInterval? = 3 * 3600,
                         connected: Bool = true,
                         lowPower: Bool = false,
                         active: Bool = false,
                         hour: Int = 14) -> LocalNotificationScheduler.SyncNudgeContent? {
        LocalNotificationScheduler.syncNudgeContent(
            flushDebtLevelRaw: level,
            debtObservedAgeSeconds: debtAge,
            lastDurableFlushAgeSeconds: flushAge,
            linkConnected: connected,
            lowPowerMode: lowPower,
            applicationIsActive: active,
            hour: hour
        )
    }

    func testDeepStaleBacklogNudgesForegroundOpen() throws {
        let nudge = try XCTUnwrap(content())
        XCTAssertTrue(nudge.body.contains("foreground"))
    }

    func testStrapAwayVariantWhenDisconnectedAndDebtStale() throws {
        let nudge = try XCTUnwrap(content(debtAge: 8 * 3600, connected: false))
        XCTAssertTrue(nudge.title.contains("out of range"))
    }

    func testLowPowerVariant() throws {
        let nudge = try XCTUnwrap(content(lowPower: true))
        XCTAssertTrue(nudge.title.contains("Low Power"))
    }

    func testSilentWhenBackgroundCatchUpIsProgressing() {
        XCTAssertNil(content(flushAge: 20 * 60),
                     "a progressing drain needs no user action")
    }

    func testSilentWhenAppActiveOrNightOrShallowDebt() {
        XCTAssertNil(content(active: true))
        XCTAssertNil(content(hour: 23))
        XCTAssertNil(content(hour: 3))
        XCTAssertNil(content(level: "low"))
        XCTAssertNil(content(level: nil))
    }

    func testSilentWhenDebtStaleButStillConnected() {
        // Connected with only a stale observation: the next 0x22 will refresh
        // the picture — do not guess at the user.
        XCTAssertNil(content(debtAge: 8 * 3600, connected: true))
    }
}
