import XCTest
@testable import Atria

/// The morning summary was silently dropped for a late riser: the fixed
/// 4:00–11:30 AM window closed before the (drain-lagged) sleep metric was ready.
/// The window is now anchored to the confirmed wake. These pin that contract.
final class AtriaMorningSummaryWindowTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: h, minute: m))!
    }

    private func within(now: (Int, Int), wake: (Int, Int)?) -> Bool {
        SessionStore.isWithinMorningSummaryWindow(
            now: date(now.0, now.1),
            wake: wake.map { date($0.0, $0.1) },
            calendar: cal
        )
    }

    func testLateRiserGetsSummaryAfterTheOldFixedCutoff() {
        // Wake 10:50; the metric materializes at 11:15 / 13:00 — past the old
        // 11:30 bound but well within the wake window. Must now fire.
        XCTAssertTrue(within(now: (11, 15), wake: (10, 50)))
        XCTAssertTrue(within(now: (13, 0), wake: (10, 50)))
        // ...but never in the afternoon (hard 14:00 cap).
        XCTAssertFalse(within(now: (15, 0), wake: (10, 50)))
    }

    func testNormalRiserMorningWindow() {
        XCTAssertTrue(within(now: (8, 0), wake: (7, 0)))
        // More than 4h after waking is no longer "just after you woke".
        XCTAssertFalse(within(now: (11, 45), wake: (7, 0)))
    }

    func testEarlyFloorAndNoWakeFallback() {
        XCTAssertFalse(within(now: (3, 0), wake: (7, 0))) // before the 4 AM floor
        // No confirmed wake → conservative 11:30 AM fallback (unchanged behavior).
        XCTAssertTrue(within(now: (10, 0), wake: nil))
        XCTAssertFalse(within(now: (12, 0), wake: nil))
    }

    func testWakeAfterNowFallsBackToFixedBound() {
        // A nonsense wake later than `now` must not open the window forever.
        XCTAssertTrue(within(now: (10, 0), wake: (23, 0)))  // fallback: 10:00 <= 11:30
        XCTAssertFalse(within(now: (13, 0), wake: (23, 0))) // fallback: 13:00 > 11:30
    }
}
