import XCTest
@testable import Atria

/// The continuous-active-period window that the cumulative Today metrics
/// (strain / TRIMP / calories / wear) integrate over. A confirmed boundary must
/// never extend; an UNCONFIRMED no-sleep fallback reaches back to the last
/// confirmed wake so a synthetic mid-active rollover does not zero those
/// metrics — but never further than a plausible 18h waking day, so a stale
/// anchor cannot integrate multiple days of strain.
final class AtriaContinuousTodayAccumulationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var eighteenHours: TimeInterval {
        AtriaCurrentDayPresentation.maximumWakingDayHeldAcrossMidnight
    }

    func testConfirmedBoundaryNeverExtends() {
        let cycleStart = now.addingTimeInterval(-3 * 3_600)
        let lastWake = now.addingTimeInterval(-30 * 3_600) // old, irrelevant
        let start = AtriaHomeModel.continuousTodayAccumulationStart(
            cycleStart: cycleStart,
            lastConfirmedWake: lastWake,
            now: now,
            isUnconfirmedFallback: false
        )
        XCTAssertEqual(start, cycleStart, "A confirmed .mainSleep boundary must not fold anything back")
    }

    func testUnconfirmedFallbackReachesBackToLastConfirmedWake() {
        // Fallback rolled the boundary to 3h ago, but the last real wake (the
        // start of this continuous active period) was 9h ago and within 18h.
        let cycleStart = now.addingTimeInterval(-3 * 3_600)
        let lastWake = now.addingTimeInterval(-9 * 3_600)
        let start = AtriaHomeModel.continuousTodayAccumulationStart(
            cycleStart: cycleStart,
            lastConfirmedWake: lastWake,
            now: now,
            isUnconfirmedFallback: true
        )
        XCTAssertEqual(start, lastWake, "Fold back to the real wake that the synthetic boundary split")
        XCTAssertLessThan(start, cycleStart)
    }

    func testUnconfirmedFallbackNeverExtendsBeyondEighteenHours() {
        // Last confirmed wake is 40h ago (user has not confirmed a sleep in
        // days). The window must clamp to now-18h, NOT integrate 40h of strain.
        let cycleStart = now.addingTimeInterval(-3 * 3_600)
        let staleWake = now.addingTimeInterval(-40 * 3_600)
        let start = AtriaHomeModel.continuousTodayAccumulationStart(
            cycleStart: cycleStart,
            lastConfirmedWake: staleWake,
            now: now,
            isUnconfirmedFallback: true
        )
        XCTAssertEqual(start.timeIntervalSince1970,
                       now.addingTimeInterval(-eighteenHours).timeIntervalSince1970,
                       accuracy: 0.5)
    }

    func testUnconfirmedFallbackWithNoConfirmedWakeClampsToEighteenHours() {
        let cycleStart = now.addingTimeInterval(-2 * 3_600)
        let start = AtriaHomeModel.continuousTodayAccumulationStart(
            cycleStart: cycleStart,
            lastConfirmedWake: nil,
            now: now,
            isUnconfirmedFallback: true
        )
        XCTAssertEqual(start.timeIntervalSince1970,
                       now.addingTimeInterval(-eighteenHours).timeIntervalSince1970,
                       accuracy: 0.5)
    }

    func testResultNeverExceedsCycleStart() {
        // A recent confirmed wake AFTER the (older) cycle start must not push the
        // window forward — folding only ever reaches back, never trims.
        let cycleStart = now.addingTimeInterval(-6 * 3_600)
        let recentWake = now.addingTimeInterval(-2 * 3_600) // later than cycleStart
        let start = AtriaHomeModel.continuousTodayAccumulationStart(
            cycleStart: cycleStart,
            lastConfirmedWake: recentWake,
            now: now,
            isUnconfirmedFallback: true
        )
        XCTAssertEqual(start, cycleStart, "min(candidate, cycleStart) must cap at the canonical start")
        XCTAssertLessThanOrEqual(start.timeIntervalSince1970, cycleStart.timeIntervalSince1970)
    }
}
