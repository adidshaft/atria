import XCTest
@testable import Atria

/// Pure-decision coverage for the sync nudge (2026-08-05 user directive:
/// graceful measures when data lags). The nudge must fire only when the user
/// can actually fix the lag, and stay silent otherwise.
final class AtriaSyncNudgeTests: XCTestCase {
    private func content(pending: Int? = 45 * 60,
                         debtAge: TimeInterval? = 600,
                         flushAge: TimeInterval? = 3 * 3600,
                         connected: Bool = true,
                         lowPower: Bool = false,
                         active: Bool = false) -> LocalNotificationScheduler.SyncNudgeContent? {
        LocalNotificationScheduler.syncNudgeContent(
            flushDebtPendingRecords: pending,
            debtObservedAgeSeconds: debtAge,
            lastDurableFlushAgeSeconds: flushAge,
            linkConnected: connected,
            lowPowerMode: lowPower,
            applicationIsActive: active
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

    func testSilentWhenAppActiveOrShallowDebt() {
        XCTAssertNil(content(active: true))
        // 2026-08-05 user decision: no time-of-day gate — a 30min+ miss is
        // worth knowing at any hour. The threshold is the only depth gate.
        XCTAssertNil(content(pending: 20 * 60))
        XCTAssertNil(content(pending: nil))
        XCTAssertNotNil(content(pending: 30 * 60),
                        "exactly 30 minutes of missed data qualifies")
    }

    func testSilentWhenDebtStaleButStillConnected() {
        // Connected with only a stale observation: the next 0x22 will refresh
        // the picture — do not guess at the user.
        XCTAssertNil(content(debtAge: 8 * 3600, connected: true))
    }
}
