import XCTest
@testable import Atria

final class AtriaMotionBankDutyCycleDiagTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "AtriaMotionBankDutyCycleDiagTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testElapsedTimeAttributesToPreviousReason() {
        let t0 = Date(timeIntervalSince1970: 1_785_900_000)
        AtriaMotionBankDutyCycleDiag.note("armed", now: t0, defaults: defaults)
        AtriaMotionBankDutyCycleDiag.note("link_down",
                                          now: t0.addingTimeInterval(60),
                                          defaults: defaults)
        AtriaMotionBankDutyCycleDiag.note("armed",
                                          now: t0.addingTimeInterval(90),
                                          defaults: defaults)
        let state = AtriaMotionBankDutyCycleDiag.load(defaults: defaults)
        XCTAssertEqual(state?.buckets["armed"] ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(state?.buckets["link_down"] ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(state?.lastReason, "armed")
    }

    func testGapBeyondCapLandsInUnsampled() {
        let t0 = Date(timeIntervalSince1970: 1_785_900_000)
        AtriaMotionBankDutyCycleDiag.note("governor_off", now: t0, defaults: defaults)
        AtriaMotionBankDutyCycleDiag.note("armed",
                                          now: t0.addingTimeInterval(2_000),
                                          defaults: defaults)
        let state = AtriaMotionBankDutyCycleDiag.load(defaults: defaults)
        XCTAssertEqual(state?.buckets["governor_off"] ?? 0,
                       AtriaMotionBankDutyCycleDiag.maximumAttributableGap,
                       accuracy: 0.001)
        XCTAssertEqual(state?.buckets["unsampled"] ?? 0,
                       2_000 - AtriaMotionBankDutyCycleDiag.maximumAttributableGap,
                       accuracy: 0.001)
    }

    func testDayRolloverSnapshotsAndResets() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_785_900_000))
        let yesterdayNoon = calendar.date(byAdding: .hour, value: -12, to: today)!
        AtriaMotionBankDutyCycleDiag.note("armed", now: yesterdayNoon, defaults: defaults)
        AtriaMotionBankDutyCycleDiag.note("link_down",
                                          now: yesterdayNoon.addingTimeInterval(120),
                                          defaults: defaults)
        let todayNoon = calendar.date(byAdding: .hour, value: 12, to: today)!
        AtriaMotionBankDutyCycleDiag.note("armed", now: todayNoon, defaults: defaults)
        let state = AtriaMotionBankDutyCycleDiag.load(defaults: defaults)
        XCTAssertEqual(state?.day, AtriaMotionBankDutyCycleDiag.dayKey(for: todayNoon))
        // Rollover happens before attribution, so the cross-midnight delta
        // lands in the new day's buckets (capped) rather than yesterday's.
        XCTAssertEqual(state?.buckets["armed"], nil)
        XCTAssertEqual(state?.buckets["link_down"] ?? 0,
                       AtriaMotionBankDutyCycleDiag.maximumAttributableGap,
                       accuracy: 0.001)
        let crossMidnightDelta = todayNoon.timeIntervalSince(
            yesterdayNoon.addingTimeInterval(120)
        )
        XCTAssertEqual(state?.buckets["unsampled"] ?? 0,
                       crossMidnightDelta
                           - AtriaMotionBankDutyCycleDiag.maximumAttributableGap,
                       accuracy: 0.001)
        let snapshotText = defaults.string(
            forKey: AtriaMotionBankDutyCycleDiag.previousDayKey
        )
        XCTAssertNotNil(snapshotText)
        let snapshot = snapshotText
            .flatMap { $0.data(using: .utf8) }
            .flatMap {
                try? JSONDecoder().decode(
                    AtriaMotionBankDutyCycleDiag.State.self, from: $0
                )
            }
        XCTAssertEqual(snapshot?.day,
                       AtriaMotionBankDutyCycleDiag.dayKey(for: yesterdayNoon))
        XCTAssertEqual(snapshot?.buckets["armed"] ?? 0, 120, accuracy: 0.001)
    }

    func testClockRewindAttributesNothing() {
        let t0 = Date(timeIntervalSince1970: 1_785_900_000)
        AtriaMotionBankDutyCycleDiag.note("armed", now: t0, defaults: defaults)
        AtriaMotionBankDutyCycleDiag.note("link_down",
                                          now: t0.addingTimeInterval(-300),
                                          defaults: defaults)
        let state = AtriaMotionBankDutyCycleDiag.load(defaults: defaults)
        XCTAssertTrue(state?.buckets.isEmpty ?? false)
        XCTAssertEqual(state?.lastReason, "link_down")
    }
}
