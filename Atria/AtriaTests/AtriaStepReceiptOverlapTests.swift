import XCTest
@testable import Atria

/// Two receipts describing the same walking must not be counted twice.
///
/// `dailyStepTotals` sums receipts that land on the same civil day, justified by
/// a comment reading "cycles do not overlap". A 2026-08-27 device pull says
/// otherwise: of 32 stored receipts, 17 overlap another and EIGHT are fully
/// contained inside one. On 15 Aug two 154-step receipts — one window entirely
/// inside the other — summed to 308.
///
/// Only full containment is removed. A partial overlap carries real steps
/// outside the shared portion and the receipts hold no per-interval breakdown,
/// so there is no honest way to subtract it; those still sum, and that is a
/// deliberate limit rather than an oversight.
final class AtriaStepReceiptOverlapTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_756_080_000)

    private func receipt(_ startOffset: TimeInterval,
                         _ endOffset: TimeInterval,
                         _ steps: Int) -> HistoricalArchive.MotionTickDayEvidence {
        HistoricalArchive.MotionTickDayEvidence(
            windowStart: now.addingTimeInterval(startOffset),
            windowEnd: now.addingTimeInterval(endOffset),
            motionTicks: steps * 2,
            steps: steps,
            knownCoverageSeconds: Int(endOffset - startOffset),
            missingCoverageSeconds: 0,
            decodedRows: 1_000,
            capturedThrough: now.addingTimeInterval(endOffset)
        )
    }

    private func totals(_ rs: [HistoricalArchive.MotionTickDayEvidence]) -> [Date: Int] {
        AtriaStepsWeekChart.dailyStepTotals(receipts: rs, now: now, calendar: calendar)
    }

    // MARK: - The device case

    func testAContainedReceiptIsNotCountedOnTopOfItsContainer() {
        // The 15 Aug shape: identical step counts, one window inside the other.
        let outer = receipt(-30 * 3600, -20 * 3600, 154)
        let inner = receipt(-27 * 3600, -22 * 3600, 154)
        let summed = totals([outer, inner]).values.reduce(0, +)

        XCTAssertEqual(summed, 154,
                       "the inner window's steps all happened inside the outer "
                           + "window; counting both shipped 308")
    }

    func testTheLargerContainerIsTheOneThatSurvives() {
        let outer = receipt(-30 * 3600, -20 * 3600, 1_118)
        let inner = receipt(-28 * 3600, -21 * 3600, 901)
        XCTAssertEqual(totals([outer, inner]).values.reduce(0, +), 1_118,
                       "the 21 Aug shape: 3,442 shipped for a day whose outer "
                           + "receipt says 1,118")
    }

    // MARK: - What must still be counted

    func testDisjointCyclesOnOneDayStillSum() {
        // The behaviour the sum exists for, and the reason `max` was wrong:
        // two genuinely separate cycles inside one date.
        let first = receipt(-20 * 3600, -16 * 3600, 1_458)
        let second = receipt(-14 * 3600, -10 * 3600, 900)
        XCTAssertEqual(totals([first, second]).values.reduce(0, +), 2_358)
    }

    func testAPartialOverlapIsLeftAlone() {
        // Neither contains the other, both hold steps outside the shared hours,
        // and no per-interval breakdown exists to subtract. Dropping either
        // would delete real walking, so this deliberately still sums.
        let a = receipt(-20 * 3600, -14 * 3600, 500)
        let b = receipt(-16 * 3600, -10 * 3600, 700)
        XCTAssertEqual(totals([a, b]).values.reduce(0, +), 1_200,
                       "partial overlap is a known, stated limit")
    }

    func testIdenticalWindowsAreBothKept() {
        // Two receipts with the SAME bounds are not container/contained — they
        // are a genuine duplicate-or-two-cycles ambiguity the window cannot
        // resolve, and silently dropping one would be a guess.
        let a = receipt(-20 * 3600, -16 * 3600, 300)
        let b = receipt(-20 * 3600, -16 * 3600, 400)
        XCTAssertEqual(totals([a, b]).values.reduce(0, +), 700)
    }

    func testASingleReceiptIsUnaffected() {
        XCTAssertEqual(totals([receipt(-20 * 3600, -16 * 3600, 4_211)]).values.reduce(0, +), 4_211)
        XCTAssertTrue(totals([]).isEmpty)
    }

    func testTheOpenCycleStillPinsToToday() {
        let today = calendar.startOfDay(for: now)
        let open = receipt(-6 * 3600, 0, 5_878)
        XCTAssertEqual(totals([open])[today], 5_878)
    }
}
