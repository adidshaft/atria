import XCTest
import SwiftUI
@testable import Atria

/// Graph grammar slice 4 (design spec section 4). These lock the three pieces
/// of pure math the interaction grammar rests on: the compare delta, the
/// per-bucket real min–max envelope, and the honesty rule that disables a
/// comparison the moment there isn't enough prior data to state it.
final class AtriaGraphGrammarTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let reference = Date(timeIntervalSince1970: 1_785_000_000)

    private func day(_ offset: Int) -> Date {
        calendar.startOfDay(for: reference.addingTimeInterval(TimeInterval(offset * 86_400)))
    }

    private func point(_ offset: Int, _ value: Double) -> AtriaDetailChartPoint {
        AtriaDetailChartPoint(day: day(offset), value: value, tint: .green)
    }

    // MARK: - Compare delta math

    func testCompareDeltaComputesSignedDifferenceOfRealAverages() throws {
        // current avg = 60, comparison avg = 52 → +8 (ms, spaced unit).
        let delta = try XCTUnwrap(
            AtriaGraphCompareDelta(current: [58, 62, 60, 60],
                                   comparison: [50, 54, 52, 52],
                                   unit: "ms",
                                   scopeText: "Month-over-month")
        )
        XCTAssertEqual(delta.currentAverage, 60, accuracy: 0.0001)
        XCTAssertEqual(delta.comparisonAverage, 52, accuracy: 0.0001)
        XCTAssertEqual(delta.delta, 8, accuracy: 0.0001)
        XCTAssertEqual(delta.deltaText, "+8 ms")
        XCTAssertTrue(delta.isIncrease)
        XCTAssertFalse(delta.isFlat)
        XCTAssertEqual(delta.scopeText, "Month-over-month")
    }

    func testCompareDeltaKeepsOneDecimalAndPercentHasNoSpace() throws {
        let ms = try XCTUnwrap(
            AtriaGraphCompareDelta(current: [63.5, 63.5, 63.5],
                                   comparison: [55.1, 55.1, 55.1],
                                   unit: "ms", scopeText: "s")
        )
        XCTAssertEqual(ms.deltaText, "+8.4 ms") // spec example value

        let percent = try XCTUnwrap(
            AtriaGraphCompareDelta(current: [40, 40, 40],
                                   comparison: [46, 46, 46],
                                   unit: "%", scopeText: "s")
        )
        XCTAssertEqual(percent.deltaText, "-6%") // negative, percent, no space
        XCTAssertFalse(percent.isIncrease)
    }

    func testCompareDeltaScopeWordingForSingleWordAndPhraseNouns() {
        XCTAssertEqual(AtriaGraphCompareDelta.scope(for: .previousPeriod, noun: "month"),
                       "Month-over-month")
        XCTAssertEqual(AtriaGraphCompareDelta.scope(for: .previousPeriod, noun: "3 months"),
                       "Vs the previous 3 months")
        XCTAssertEqual(AtriaGraphCompareDelta.scope(for: .samePeriodLastYear, noun: "month"),
                       "Vs the same month last year")
    }

    // MARK: - "Disable comparison when no prior data" rule

    func testComparisonIsNilWhenPriorDataIsTooThin() {
        // Enough current samples, but only 1 comparison sample — below the
        // max(3, current/2) floor. Never fabricate a delta from a stray point.
        XCTAssertNil(AtriaGraphCompareDelta(current: [60, 60, 60, 60, 60, 60],
                                            comparison: [52],
                                            unit: "ms", scopeText: "s"))
        // Exactly at the floor (3 for 4 current) passes.
        XCTAssertNotNil(AtriaGraphCompareDelta(current: [60, 60, 60, 60],
                                               comparison: [52, 52, 52],
                                               unit: "ms", scopeText: "s"))
        // No current data at all → nothing to compare.
        XCTAssertNil(AtriaGraphCompareDelta(current: [],
                                            comparison: [52, 52, 52, 52],
                                            unit: "ms", scopeText: "s"))
    }

    func testAvailabilityGatesEachModeAndAgeGroupIsAlwaysUnavailable() {
        // Previous period has data; last-year does not; age-group never does.
        let availability = AtriaGraphCompareAvailability.make(currentCount: 8,
                                                              previousPeriodCount: 8,
                                                              samePeriodLastYearCount: 0)
        XCTAssertTrue(availability.isAvailable(.previousPeriod))
        XCTAssertFalse(availability.isAvailable(.samePeriodLastYear))
        XCTAssertFalse(availability.isAvailable(.ageGroupTypical))
        XCTAssertEqual(availability.firstAvailable, .previousPeriod)

        // Disabled modes carry an honest, plain-language reason; available ones
        // carry none.
        XCTAssertNil(availability.disabledNote(for: .previousPeriod))
        XCTAssertNotNil(availability.disabledNote(for: .samePeriodLastYear))
        XCTAssertEqual(availability.disabledNote(for: .ageGroupTypical),
                       "Atria ships no age-group reference — it won't invent one.")
    }

    func testAvailabilityWithNoPriorDataOffersNothing() {
        let availability = AtriaGraphCompareAvailability.make(currentCount: 10,
                                                              previousPeriodCount: 0,
                                                              samePeriodLastYearCount: 0)
        XCTAssertFalse(availability.isAvailable(.previousPeriod))
        XCTAssertNil(availability.firstAvailable)
    }

    // MARK: - Min–max envelope

    func testEnvelopeBucketsByWeekWithRealMinMaxAndAverage() throws {
        // Anchor to the calendar's own week boundaries so this is independent of
        // firstWeekday. Week 1 gets three days (10,20,30); the next week gets
        // two (40,60). Envelope must average each week and carry that week's
        // true min/max — nothing interpolated.
        let week1Start = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: reference)?.start)
        func pt(_ base: Date, plusDays: Int, _ value: Double) -> AtriaDetailChartPoint {
            AtriaDetailChartPoint(day: calendar.date(byAdding: .day, value: plusDays, to: base)!,
                                  value: value, tint: .green)
        }
        let week2Start = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: week1Start))
        let pts = [
            pt(week1Start, plusDays: 0, 10),
            pt(week1Start, plusDays: 1, 20),
            pt(week1Start, plusDays: 2, 30),
            pt(week2Start, plusDays: 0, 40),
            pt(week2Start, plusDays: 1, 60)
        ]

        let weekly = AtriaGraphMinMaxEnvelope.bucketed(pts, by: .week, calendar: calendar)
        XCTAssertEqual(weekly.count, 2)

        let first = weekly[0]
        XCTAssertEqual(first.value, 20, accuracy: 0.0001)
        XCTAssertEqual(first.bandLower, 10)
        XCTAssertEqual(first.bandUpper, 30)

        let second = weekly[1]
        XCTAssertEqual(second.value, 50, accuracy: 0.0001)
        XCTAssertEqual(second.bandLower, 40)
        XCTAssertEqual(second.bandUpper, 60)
    }

    func testEnvelopeMonthlyGroupsAcrossManyDays() {
        // 40 consecutive days spanning two calendar months.
        let pts = (0..<40).map { point($0, Double($0)) }
        let monthly = AtriaGraphMinMaxEnvelope.bucketed(pts, by: .month, calendar: calendar)
        XCTAssertGreaterThanOrEqual(monthly.count, 2)
        // Every bucket's band must bound its value.
        for bucket in monthly {
            XCTAssertNotNil(bucket.bandLower)
            XCTAssertNotNil(bucket.bandUpper)
            XCTAssertLessThanOrEqual(bucket.bandLower ?? 0, bucket.value + 0.0001)
            XCTAssertGreaterThanOrEqual(bucket.bandUpper ?? 0, bucket.value - 0.0001)
        }
        // Buckets are sorted ascending and cover the real span.
        XCTAssertEqual(monthly.map(\.day), monthly.map(\.day).sorted())
    }

    func testEnvelopeDayIntervalIsIdentityAndEmptyStaysEmpty() {
        let pts = [point(0, 1), point(1, 2), point(2, 3)]
        let daily = AtriaGraphMinMaxEnvelope.bucketed(pts, by: .day, calendar: calendar)
        XCTAssertEqual(daily.count, 3)
        XCTAssertNil(daily[0].bandLower) // no envelope synthesized for single days
        XCTAssertTrue(AtriaGraphMinMaxEnvelope.bucketed([], by: .week, calendar: calendar).isEmpty)
    }

    func testEnvelopeClampsFirstPartialBucketIntoVisiblePeriod() {
        // A point whose week starts before the visible period must be plotted at
        // the period start, not off-domain (regression of the 2026-07-31 clip).
        let periodStart = day(2)
        let clamp = DateInterval(start: periodStart, end: day(9))
        let pts = [point(0, 5), point(1, 7), point(3, 9)] // days 0,1 precede start
        let weekly = AtriaGraphMinMaxEnvelope.bucketed(pts, by: .week,
                                                       calendar: calendar, within: clamp)
        for bucket in weekly {
            XCTAssertGreaterThanOrEqual(bucket.day, periodStart)
        }
    }

    // MARK: - Chart type availability

    func testRangeChartTypeOnlyOfferedWhenBandExists() {
        XCTAssertEqual(AtriaGraphChartType.options(hasMinMaxBand: false), [.line, .bars])
        XCTAssertEqual(AtriaGraphChartType.options(hasMinMaxBand: true), [.line, .bars, .range])
    }
}
