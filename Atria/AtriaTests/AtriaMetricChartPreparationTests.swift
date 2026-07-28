import SwiftUI
import XCTest
@testable import Atria

final class AtriaMetricChartPreparationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    func testPreparationIncludesEveryStaticDomainInputOnce() {
        let points = [
            point(day: 1, value: 60, lower: 58, upper: 64),
            point(day: 2, value: 70)
        ]
        let prior = [point(day: 1, value: 52)]

        let prepared = AtriaMetricChartPreparedData(
            points: points,
            priorPoints: prior,
            baselineBounds: 55...75,
            priorAverage: 50,
            companionPoints: [],
            calendar: calendar
        )

        XCTAssertEqual(prepared.domain.lowerBound,
                       AtriaTrendChartScale.domain(low: 50, high: 75).lowerBound,
                       accuracy: 0.000_001)
        XCTAssertEqual(prepared.domain.upperBound,
                       AtriaTrendChartScale.domain(low: 50, high: 75).upperBound,
                       accuracy: 0.000_001)
        XCTAssertTrue(prepared.hasMinMaxBand)
        XCTAssertEqual(prepared.minMaxPoints.map(\.day), [points[0].day])
    }

    func testPreparedChartKeepsTheSelectedCalendarWindowAsItsXDomain() {
        let points = [
            point(day: 28, value: 7),
            point(day: 29, value: 9)
        ]
        let monthStart = date(day: 1, hour: 0)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        let prepared = AtriaMetricChartPreparedData(
            points: points,
            priorPoints: [],
            baselineBounds: nil,
            priorAverage: nil,
            companionPoints: [],
            calendar: calendar,
            xDomain: monthStart...monthEnd
        )

        XCTAssertEqual(prepared.xDomain, monthStart...monthEnd)
        XCTAssertNotEqual(prepared.xDomain, points.first!.day...points.last!.day,
                          "A sparse month must not be stretched into the same shape as a week")
    }

    func testDayWeekMonthProjectionUsesPersistedStrainAndReactsToUpdates() throws {
        let referenceDate = date(day: 29)
        let rollups = (1...29).reversed().map { day in
            DailyRollupStoreEntry(
                day: date(day: day),
                strain: Double(day),
                calendar: calendar
            )
        }
        let chronological = Array(rollups.reversed())

        let day = periodProjection(for: chronological,
                                   referenceDate: referenceDate,
                                   range: .day)
        let week = periodProjection(for: chronological,
                                    referenceDate: referenceDate,
                                    range: .week)
        let month = periodProjection(for: chronological,
                                     referenceDate: referenceDate,
                                     range: .month)

        XCTAssertEqual(day.compactMap(\.strain), [29])
        // 29 June 2026 is a Monday with this calendar's Monday-first week,
        // so the current (still incomplete) calendar week honestly contains
        // only the 29th. It must not borrow weekend rows to make a fuller line.
        XCTAssertEqual(week.compactMap(\.strain), [29])
        XCTAssertEqual(month.compactMap(\.strain), (1...29).map(Double.init))
        XCTAssertNotEqual(week.compactMap(\.strain),
                          month.compactMap(\.strain))

        var changedRollups = rollups
        changedRollups[0] = DailyRollupStoreEntry(
            day: date(day: 29),
            strain: 12.5,
            calendar: calendar
        )
        let changedDay = periodProjection(
            for: Array(changedRollups.reversed()),
            referenceDate: referenceDate,
            range: .day
        )
        XCTAssertEqual(changedDay.compactMap(\.strain), [12.5],
                       "The graph projection must change when persisted rollup input changes")
    }

    func testNearestPointLookupHandlesEdgesAndPreservesEarlierTieBehavior() {
        let points = [point(day: 1, value: 10), point(day: 3, value: 30), point(day: 5, value: 50)]
        let prepared = makePrepared(points: points)

        XCTAssertEqual(prepared.nearestPointIndex(to: date(day: 1).addingTimeInterval(-86_400)), 0)
        XCTAssertEqual(prepared.nearestPointIndex(to: date(day: 6)), 2)
        XCTAssertEqual(prepared.nearestPointIndex(to: date(day: 2)), 0)
        XCTAssertEqual(prepared.nearestPointIndex(to: date(day: 4, hour: 18)), 2)
    }

    func testCompanionLookupUsesPreparedCivilDayIndex() {
        let companions = [[point(day: 2, hour: 23, value: 41), point(day: 4, value: 43)]]
        let prepared = AtriaMetricChartPreparedData(
            points: [point(day: 1, value: 10), point(day: 2, value: 20)],
            priorPoints: [],
            baselineBounds: nil,
            priorAverage: nil,
            companionPoints: companions,
            calendar: calendar
        )

        XCTAssertEqual(prepared.companionPointIndex(at: 0, on: date(day: 2, hour: 1)), 0)
        XCTAssertNil(prepared.companionPointIndex(at: 0, on: date(day: 3)))
        XCTAssertNil(prepared.companionPointIndex(at: 1, on: date(day: 2)))
    }

    func testEmptyPreparationUsesStableFallbacks() {
        let prepared = makePrepared(points: [])
        XCTAssertEqual(prepared.domain, 0...1)
        XCTAssertNil(prepared.xDomain)
        XCTAssertFalse(prepared.hasMinMaxBand)
        XCTAssertNil(prepared.nearestPointIndex(to: date(day: 1)))
    }

    private func makePrepared(points: [AtriaDetailChartPoint]) -> AtriaMetricChartPreparedData {
        AtriaMetricChartPreparedData(points: points,
                                     priorPoints: [],
                                     baselineBounds: nil,
                                     priorAverage: nil,
                                     companionPoints: [],
                                     calendar: calendar)
    }

    private func periodProjection(
        for rollups: [DailyRollupStoreEntry],
        referenceDate: Date,
        range: AtriaTrendRange
    ) -> [DailyRollupStoreEntry] {
        let projection = AtriaMetricPeriodIndexProjection(
            days: rollups.map(\.day),
            referenceDate: referenceDate,
            range: range,
            calendar: calendar
        )
        return projection.currentIndices.map { rollups[$0] }
    }

    private func point(day: Int,
                       hour: Int = 12,
                       value: Double,
                       lower: Double? = nil,
                       upper: Double? = nil) -> AtriaDetailChartPoint {
        AtriaDetailChartPoint(day: date(day: day, hour: hour),
                              value: value,
                              tint: .green,
                              bandLower: lower,
                              bandUpper: upper)
    }

    private func date(day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }
}
