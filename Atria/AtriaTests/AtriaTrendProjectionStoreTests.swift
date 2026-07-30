import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaTrendProjectionStoreTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int,
                      _ month: Int,
                      _ day: Int,
                      _ hour: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: year,
                                              month: month,
                                              day: day,
                                              hour: hour))!
    }

    private func trendSession(id: String,
                              start: Date,
                              bpm: Int,
                              persistedHRV: Int? = nil) -> SavedSession {
        let end = start.addingTimeInterval(10 * 60)
        return SavedSession(
            id: UUID(uuidString: id)!,
            start: start,
            end: end,
            label: "Trend fixture",
            points: (0...10).map {
                SavedSession.Point(t: Double($0 * 60), bpm: bpm)
            },
            hrv: persistedHRV,
            eventTimeZoneIdentifier: "UTC"
        )
    }

    private func state(points: [AtriaTrendPoint] = [],
                       revision: Int = 0,
                       restingHR: Int? = nil,
                       events: [AtriaChartEvent] = []) -> AtriaTrendChartProjectionState {
        AtriaTrendChartProjectionState(points: points,
                                       pointsRevision: revision,
                                       baselineRestingHR: restingHR,
                                       events: events)
    }

    func testEqualTrendProjectionDoesNotPublish() {
        let initial = state()
        let projection = AtriaTrendChartProjectionStore(state: initial)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(initial))
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testRelevantTrendProjectionPublishesExactlyOnce() {
        let projection = AtriaTrendChartProjectionStore(state: state())
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }
        let points = [AtriaTrendPoint(id: UUID(),
                                      date: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                      restingHR: 58,
                                      strain: 8.2,
                                      hrv: 61)]

        XCTAssertTrue(projection.refresh(state(points: points, revision: 1, restingHR: 58)))
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testOverviewTrendPointsAggregateSessionsIntoDeterministicCivilDays() throws {
        let firstDayMorning = trendSession(
            id: "00000000-0000-4000-8000-000000000001",
            start: date(2026, 7, 27, 8),
            bpm: 62
        )
        let firstDayEvening = trendSession(
            id: "00000000-0000-4000-8000-000000000002",
            start: date(2026, 7, 27, 18),
            bpm: 64,
            persistedHRV: 88
        )
        let secondDay = trendSession(
            id: "00000000-0000-4000-8000-000000000003",
            start: date(2026, 7, 28, 9),
            bpm: 66
        )
        let sessions = [secondDay, firstDayEvening, firstDayMorning]

        let points = SessionStore.makeOverviewTrendPoints(
            sessions: sessions,
            rest: 60,
            maxHR: 190,
            now: date(2026, 7, 29, 12),
            calendar: utcCalendar
        )
        let reversed = SessionStore.makeOverviewTrendPoints(
            sessions: Array(sessions.reversed()),
            rest: 60,
            maxHR: 190,
            now: date(2026, 7, 29, 12),
            calendar: utcCalendar
        )

        XCTAssertEqual(points, reversed)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.map(\.date), [
            date(2026, 7, 27),
            date(2026, 7, 28),
        ])
        XCTAssertEqual(points[0].id, firstDayMorning.id)
        XCTAssertEqual(points[0].restingHR, 62)
        XCTAssertNil(points[0].hrv)
        XCTAssertEqual(
            try XCTUnwrap(points[0].strain),
            Metrics.strain(
                fromTRIMP:
                    firstDayMorning.trimp(rest: 60, max: 190)
                    + firstDayEvening.trimp(rest: 60, max: 190)
            ),
            accuracy: 0.000_001
        )
        XCTAssertEqual(points[1].restingHR, 66)
    }

    func testTrendHostUsesNarrowProjectionInsteadOfWholeSessionStoreObservation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTrendChart.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let hostStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewTrendChartHost: View"))
        let hostEnd = try XCTUnwrap(source.range(of: "enum AtriaTrendRange", range: hostStart.lowerBound..<source.endIndex))
        let host = String(source[hostStart.lowerBound..<hostEnd.lowerBound])

        XCTAssertTrue(host.contains("let store: SessionStore"))
        XCTAssertTrue(host.contains("@StateObject private var projectionStore: AtriaTrendChartProjectionStore"))
        XCTAssertFalse(host.contains("@ObservedObject var store"))
        XCTAssertTrue(host.contains("store.$overviewTrendPoints"))
        XCTAssertTrue(host.contains("store.$baseline"))
        XCTAssertTrue(host.contains("store.$sleepHistorySnapshot"))
        XCTAssertTrue(host.contains("store.confirmedWorkoutsRevision != self.confirmedWorkoutsRevision"))
    }
}
