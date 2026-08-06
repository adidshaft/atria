import XCTest
@testable import Atria

/// Pure-logic tests for `SessionStore.clampedSleepOnset` — the 2026-08-06
/// sleep-onset device-use clamp (app claimed 12:53am onset while the phone was
/// demonstrably in active use until well after 2am).
final class AtriaSleepOnsetClampTests: XCTestCase {
    private let strictMinimum = AggregateSleepCandidate.strictMinimumDuration

    private func date(_ t: TimeInterval) -> Date {
        Date(timeIntervalSince1970: t)
    }

    private func interval(_ start: TimeInterval,
                          _ end: TimeInterval) -> DateInterval {
        DateInterval(start: date(start), end: date(end))
    }

    func testLeadingUseClampsOnsetWithSettleMargin() {
        // Candidate 00:53–08:00-shaped window; sustained use covers the
        // claimed onset until "2:10am" (t = 4_620s into the window).
        let start = date(0)
        let end = date(8 * 3_600)
        let clamped = SessionStore.clampedSleepOnset(
            start: start,
            end: end,
            sustainedUse: [interval(-600, 4_620)],
            minimumRetainedDuration: strictMinimum
        )
        XCTAssertEqual(clamped,
                       date(4_620 + SessionStore.sleepOnsetClampSettleMargin))
    }

    func testChainedLeadingUseWithinSettleMarginKeepsClamping() {
        let start = date(0)
        let end = date(8 * 3_600)
        // Second use interval begins inside the first clamp's settle margin,
        // so the wearer never actually settled: both clamp.
        let clamped = SessionStore.clampedSleepOnset(
            start: start,
            end: end,
            sustainedUse: [
                interval(-600, 1_000),
                interval(1_000 + 120, 2_400),
            ],
            minimumRetainedDuration: strictMinimum
        )
        XCTAssertEqual(clamped,
                       date(2_400 + SessionStore.sleepOnsetClampSettleMargin))
    }

    func testMiddleOfNightUseDoesNotClamp() {
        // Use begins well after the (settled) onset: trailing/middle wake
        // handling is deliberately left to the existing wake detection.
        let start = date(0)
        let end = date(8 * 3_600)
        let clamped = SessionStore.clampedSleepOnset(
            start: start,
            end: end,
            sustainedUse: [interval(2 * 3_600, 2 * 3_600 + 900)],
            minimumRetainedDuration: strictMinimum
        )
        XCTAssertEqual(clamped, start)
    }

    func testClampNeverPassesEndMinusMinimumSleepDuration() {
        let start = date(0)
        let end = date(4 * 3_600)
        // Use covers nearly the whole window; the clamp must stop at
        // end - strictMinimumDuration rather than erase the sleep.
        let clamped = SessionStore.clampedSleepOnset(
            start: start,
            end: end,
            sustainedUse: [interval(-600, 4 * 3_600 - 60)],
            minimumRetainedDuration: strictMinimum
        )
        XCTAssertEqual(clamped, date(4 * 3_600 - strictMinimum))
    }

    func testEmptyJournalIsExactIdentity() {
        let start = date(0)
        let end = date(8 * 3_600)
        XCTAssertEqual(
            SessionStore.clampedSleepOnset(
                start: start,
                end: end,
                sustainedUse: [],
                minimumRetainedDuration: strictMinimum
            ),
            start
        )
    }

    func testClampNeverMovesOnsetEarlier() {
        // A use interval fully before the candidate cannot move the onset.
        let start = date(10_000)
        let end = date(10_000 + 8 * 3_600)
        XCTAssertEqual(
            SessionStore.clampedSleepOnset(
                start: start,
                end: end,
                sustainedUse: [interval(1_000, 5_000)],
                minimumRetainedDuration: strictMinimum
            ),
            start
        )
    }
}
