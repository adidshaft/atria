import XCTest
@testable import Atria

/// Not every trend is daily. Fitness age comes from `weeklyObservations`, so
/// the day-adjacency rule that correctly splits a once-a-day series would put
/// every fitness-age point in its own run and erase the line altogether —
/// turning an honesty fix into a blank chart.
///
/// The cadence-aware rule infers the series' own spacing and breaks only on a
/// gap that exceeds it, so "sampled coarsely" and "missing an observation" stop
/// being the same thing.
final class AtriaCadenceAwareGapTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let base = Date(timeIntervalSince1970: 1_756_000_000)

    private func samples(_ dayOffsets: [Double]) -> [AtriaTrendPoint.Sample] {
        dayOffsets.map { AtriaTrendPoint.Sample(date: base.addingTimeInterval($0 * day),
                                                value: 40) }
    }

    private func segments(_ dayOffsets: [Double], tolerance: Double = 2.0) -> [Int] {
        AtriaTrendGapPolicy
            .assigningCadenceAwareSegments(to: samples(dayOffsets),
                                           toleranceMultiplier: tolerance)
            .map(\.segment)
    }

    // MARK: - The regression this exists to prevent

    func testRegularlySampledWeeklyDataStaysOneUnbrokenRun() {
        // The naive day-adjacency rule returns [0,1,2,3,4,5] here — six runs of
        // one point each, which draws no line at all.
        XCTAssertEqual(segments([0, 7, 14, 21, 28, 35]), [0, 0, 0, 0, 0, 0])
    }

    func testAnyRegularCadenceSurvives() {
        for spacing in [1.0, 3.0, 7.0, 14.0, 30.0] {
            let offsets = (0..<6).map { Double($0) * spacing }
            XCTAssertEqual(Set(segments(offsets)).count, 1,
                           "a series sampled every \(spacing) days is not gappy")
        }
    }

    // MARK: - But a genuinely skipped observation still breaks

    func testASkippedWeekBreaksTheWeeklySeries() {
        // 0, 7, 14, then nothing until 35: a 21-day hole against a 7-day
        // cadence is three missed observations.
        XCTAssertEqual(segments([0, 7, 14, 35, 42, 49]), [0, 0, 0, 1, 1, 1])
    }

    func testADailySeriesStillBreaksOnAMissingDay() {
        XCTAssertEqual(segments([0, 1, 2, 5, 6, 7]), [0, 0, 0, 1, 1, 1])
    }

    func testTheMedianIsNotDraggedByOneEnormousGap() {
        // A mean spacing here is ~18 days, which would swallow the real breaks.
        // The median stays 1 day, so both holes are still seen.
        XCTAssertEqual(segments([0, 1, 2, 3, 90, 91, 180]),
                       [0, 0, 0, 0, 1, 1, 2])
    }

    // MARK: - Conservative where there is no evidence

    func testTwoPointsCannotEstablishACadenceSoTheyStayJoined() {
        XCTAssertEqual(segments([0, 400]), [0, 0],
                       "one spacing is not a cadence; do not invent a break")
    }

    func testEmptyAndSingleInputsAreSafe() {
        XCTAssertTrue(segments([]).isEmpty)
        XCTAssertEqual(segments([3]), [0])
    }

    func testDuplicateTimestampsDoNotProduceAZeroCadence() {
        // A zero spacing would make every later gap "infinitely" large.
        let result = segments([0, 0, 1, 2, 3])
        XCTAssertEqual(Set(result).count, 1, "duplicates are not gaps")
    }

    func testOutputStaysSortedByDate() {
        let assigned = AtriaTrendGapPolicy.assigningCadenceAwareSegments(
            to: samples([21, 0, 14, 7])
        )
        XCTAssertEqual(assigned.map(\.date), assigned.map(\.date).sorted())
        XCTAssertEqual(assigned.map(\.segment), [0, 0, 0, 0])
    }

    func testToleranceIsNeverBelowOne() {
        // A multiplier under 1 would break a perfectly regular series.
        XCTAssertEqual(Set(segments([0, 7, 14, 21], tolerance: 0.1)).count, 1)
    }
}
