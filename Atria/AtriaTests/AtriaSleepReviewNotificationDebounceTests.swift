import XCTest
@testable import Atria

/// Sleep-review notification window-start debounce (2026-08-01,
/// user-specified semantics). Physical trigger: one growing overnight
/// candidate re-fired at 04:50, 04:56 and 04:57 because each minor end
/// extension minted a fresh start-end candidate id. The durable dedupe key is
/// the candidate WINDOW START:
///   - the first offer for a start notifies;
///   - a later offer for the same start notifies only when the end grew
///     >= 30 minutes past the end the user was already told about;
///   - end jitter below that stays silent;
///   - a separate later episode (different start) is fully independent.
final class AtriaSleepReviewNotificationDebounceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_806_000_000)

    private func ledger(_ entries: [(start: Date, end: Date)]) -> [String: Double] {
        entries.reduce(into: [:]) { partial, entry in
            partial = AtriaSleepReviewNotificationDebounce.recordingNotifiedEnd(
                start: entry.start,
                end: entry.end,
                in: partial
            )
        }
    }

    func testFirstOfferForAStartAlwaysNotifies() {
        XCTAssertTrue(AtriaSleepReviewNotificationDebounce.shouldNotify(
            start: start,
            end: start.addingTimeInterval(7 * 3_600),
            lastNotifiedEndByStart: [:]
        ))
    }

    func testEndJitterStaysSilent() {
        // The observed triple-fire: 04:50, then 04:56 (+6 min), then 04:57.
        let firstEnd = start.addingTimeInterval(7 * 3_600)
        let recorded = ledger([(start, firstEnd)])
        XCTAssertFalse(AtriaSleepReviewNotificationDebounce.shouldNotify(
            start: start,
            end: firstEnd.addingTimeInterval(6 * 60),
            lastNotifiedEndByStart: recorded
        ), "a six-minute end extension is jitter, not a new review")
        XCTAssertFalse(AtriaSleepReviewNotificationDebounce.shouldNotify(
            start: start,
            end: firstEnd.addingTimeInterval(7 * 60),
            lastNotifiedEndByStart: recorded
        ))
        XCTAssertFalse(AtriaSleepReviewNotificationDebounce.shouldNotify(
            start: start,
            end: firstEnd.addingTimeInterval(30 * 60 - 1),
            lastNotifiedEndByStart: recorded
        ), "growth below thirty minutes never re-fires")
        XCTAssertFalse(AtriaSleepReviewNotificationDebounce.shouldNotify(
            start: start,
            end: firstEnd.addingTimeInterval(-5 * 60),
            lastNotifiedEndByStart: recorded
        ), "a shrinking end is never growth")
    }

    func testMaterialEndGrowthReFires() {
        let firstEnd = start.addingTimeInterval(7 * 3_600)
        let recorded = ledger([(start, firstEnd)])
        XCTAssertTrue(AtriaSleepReviewNotificationDebounce.shouldNotify(
            start: start,
            end: firstEnd.addingTimeInterval(30 * 60),
            lastNotifiedEndByStart: recorded
        ), "thirty minutes of real growth is a materially different review")
    }

    func testSeparateLaterEpisodeIsIndependent() {
        let firstEnd = start.addingTimeInterval(7 * 3_600)
        let recorded = ledger([(start, firstEnd)])
        let napStart = firstEnd.addingTimeInterval(5 * 3_600)
        XCTAssertTrue(AtriaSleepReviewNotificationDebounce.shouldNotify(
            start: napStart,
            end: napStart.addingTimeInterval(40 * 60),
            lastNotifiedEndByStart: recorded
        ), "a different start is its own episode and its own key")
    }

    func testRecordingNeverRegressesTheNotifiedEnd() {
        let longEnd = start.addingTimeInterval(8 * 3_600)
        var recorded = ledger([(start, longEnd)])
        recorded = AtriaSleepReviewNotificationDebounce.recordingNotifiedEnd(
            start: start,
            end: start.addingTimeInterval(6 * 3_600),
            in: recorded
        )
        XCTAssertEqual(
            recorded[AtriaSleepReviewNotificationDebounce.startKey(for: start)],
            longEnd.timeIntervalSince1970,
            "a stale shorter end must not reopen re-fire room"
        )
    }

    func testLedgerStaysBoundedToNewestEightStarts() {
        var entries: [(start: Date, end: Date)] = []
        for index in 0..<12 {
            let episodeStart = start.addingTimeInterval(TimeInterval(index) * 86_400)
            entries.append((episodeStart, episodeStart.addingTimeInterval(7 * 3_600)))
        }
        let recorded = ledger(entries)
        XCTAssertEqual(recorded.count,
                       AtriaSleepReviewNotificationDebounce.maximumTrackedStarts)
        // Oldest starts were evicted; the newest survive.
        XCTAssertNil(recorded[AtriaSleepReviewNotificationDebounce.startKey(for: start)])
        let newest = start.addingTimeInterval(11 * 86_400)
        XCTAssertNotNil(recorded[AtriaSleepReviewNotificationDebounce.startKey(for: newest)])
    }

    func testStartKeyIsMinuteStableAgainstFloatNoise() {
        let jittered = start.addingTimeInterval(0.4)
        XCTAssertEqual(AtriaSleepReviewNotificationDebounce.startKey(for: start),
                       AtriaSleepReviewNotificationDebounce.startKey(for: jittered))
    }
}
