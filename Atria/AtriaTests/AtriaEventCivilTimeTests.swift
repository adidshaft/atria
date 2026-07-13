import XCTest
@testable import Atria

final class AtriaEventCivilTimeTests: XCTestCase {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0,
                      timeZone: String = "UTC") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar.date(from: DateComponents(year: year,
                                                  month: month,
                                                  day: day,
                                                  hour: hour,
                                                  minute: minute))!
    }

    private func session(start: Date,
                         end: Date,
                         timeZoneIdentifier: String? = nil) -> SavedSession {
        SavedSession(id: UUID(),
                     start: start,
                     end: end,
                     label: "Test",
                     points: [],
                     hrv: nil,
                     eventTimeZoneIdentifier: timeZoneIdentifier)
    }

    private func workout(start: Date,
                         end: Date,
                         timeZoneIdentifier: String? = nil) -> UserConfirmedWorkout {
        UserConfirmedWorkout(id: UUID().uuidString,
                             createdAt: end,
                             start: start,
                             end: end,
                             label: "Test workout",
                             source: "test",
                             confidence: "test",
                             sessions: 1,
                             samples: 0,
                             avgHR: 0,
                             peakHR: 0,
                             p95HR: 0,
                             p99HR: 0,
                             thresholdHR: 0,
                             streamCoveragePercent: 0,
                             observedDuration: end.timeIntervalSince(start),
                             reason: "test",
                             eventTimeZoneIdentifier: timeZoneIdentifier)
    }

    private func sleep(start: Date,
                       end: Date,
                       timeZoneIdentifier: String? = nil) -> UserConfirmedSleep {
        UserConfirmedSleep(id: UUID().uuidString,
                           createdAt: end,
                           start: start,
                           end: end,
                           source: "test",
                           confidence: "test",
                           sessions: 1,
                           samples: 0,
                           avgHR: 0,
                           peakHR: 0,
                           restingHR: 0,
                           hrv: nil,
                           hrvWindowCount: nil,
                           duration: end.timeIntervalSince(start),
                           span: end.timeIntervalSince(start),
                           reason: "test",
                           motionSource: "test",
                           motionValidated: false,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: timeZoneIdentifier)
    }

    func testPersistedModelsDecodeLegacyJSONWithoutEventTimeZoneIdentifier() throws {
        let start = date(2026, 7, 9, 22)
        let end = date(2026, 7, 10, 6)
        let values: [Any] = [
            session(start: start, end: end, timeZoneIdentifier: "America/Los_Angeles"),
            workout(start: start, end: end, timeZoneIdentifier: "America/Los_Angeles"),
            sleep(start: start, end: end, timeZoneIdentifier: "America/Los_Angeles")
        ]

        for value in values {
            let encoded: Data
            switch value {
            case let value as SavedSession: encoded = try JSONEncoder().encode(value)
            case let value as UserConfirmedWorkout: encoded = try JSONEncoder().encode(value)
            case let value as UserConfirmedSleep: encoded = try JSONEncoder().encode(value)
            default: XCTFail("unexpected fixture"); return
            }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: "eventTimeZoneIdentifier")
            let legacy = try JSONSerialization.data(withJSONObject: object)

            if value is SavedSession {
                XCTAssertNil(try JSONDecoder().decode(SavedSession.self, from: legacy).eventTimeZoneIdentifier)
            } else if value is UserConfirmedWorkout {
                XCTAssertNil(try JSONDecoder().decode(UserConfirmedWorkout.self, from: legacy).eventTimeZoneIdentifier)
            } else {
                XCTAssertNil(try JSONDecoder().decode(UserConfirmedSleep.self, from: legacy).eventTimeZoneIdentifier)
            }
        }
    }

    func testPersistedModelsRoundTripEventTimeZoneIdentifier() throws {
        let start = date(2026, 7, 9, 22)
        let end = date(2026, 7, 10, 6)
        let identifier = "America/Los_Angeles"

        XCTAssertEqual(try JSONDecoder().decode(SavedSession.self,
                                                from: JSONEncoder().encode(session(start: start, end: end,
                                                                                   timeZoneIdentifier: identifier)))
            .eventTimeZoneIdentifier, identifier)
        XCTAssertEqual(try JSONDecoder().decode(UserConfirmedWorkout.self,
                                                from: JSONEncoder().encode(workout(start: start, end: end,
                                                                                  timeZoneIdentifier: identifier)))
            .eventTimeZoneIdentifier, identifier)
        XCTAssertEqual(try JSONDecoder().decode(UserConfirmedSleep.self,
                                                from: JSONEncoder().encode(sleep(start: start, end: end,
                                                                                timeZoneIdentifier: identifier)))
            .eventTimeZoneIdentifier, identifier)
    }

    func testEventCivilDayRematerializesIntoOutputCalendarAndInvalidFallsBack() {
        let instant = date(2026, 7, 10, 2)
        let eventDay = EventCivilTime.day(containing: instant,
                                          eventTimeZoneIdentifier: "America/Los_Angeles",
                                          outputCalendar: Self.utcCalendar)
        XCTAssertEqual(eventDay, date(2026, 7, 9, 0))
        XCTAssertEqual(EventCivilTime.day(containing: instant,
                                          eventTimeZoneIdentifier: nil,
                                          outputCalendar: Self.utcCalendar),
                       date(2026, 7, 10, 0))
        XCTAssertEqual(EventCivilTime.day(containing: instant,
                                          eventTimeZoneIdentifier: "Not/A_TimeZone",
                                          outputCalendar: Self.utcCalendar),
                       date(2026, 7, 10, 0))
    }

    func testHistoryRollupKeepsSessionAndWorkoutOnEventCivilDayAfterTravel() {
        let start = date(2026, 7, 10, 2)
        let end = date(2026, 7, 10, 3)
        let identifier = "America/Los_Angeles"
        let rollups = SessionStore.makeHistoryDailyRollups(
            sessions: [session(start: start, end: end, timeZoneIdentifier: identifier)],
            detections: [],
            confirmedWorkouts: [workout(start: start, end: end, timeZoneIdentifier: identifier)],
            rest: 60,
            maxHR: 190,
            calendar: Self.utcCalendar
        )

        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups.first?.day, date(2026, 7, 9, 0))
        XCTAssertEqual(rollups.first?.sessions, 1)
        XCTAssertEqual(rollups.first?.confirmedWorkouts, 1)
    }

    func testHistoryRollupIncludesConfirmedWorkoutCivilDayWithoutSession() {
        let start = date(2026, 7, 10, 2)
        let end = date(2026, 7, 10, 3)
        let identifier = "America/Los_Angeles"
        let rollups = SessionStore.makeHistoryDailyRollups(
            sessions: [],
            detections: [],
            confirmedWorkouts: [workout(start: start, end: end, timeZoneIdentifier: identifier)],
            rest: 60,
            maxHR: 190,
            calendar: Self.utcCalendar
        )

        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups.first?.day, date(2026, 7, 9, 0))
        XCTAssertEqual(rollups.first?.sessions, 0)
        XCTAssertEqual(rollups.first?.confirmedWorkouts, 1)
        XCTAssertEqual(rollups.first?.strain, 0)
    }

    @MainActor
    func testLiveRollupIncludesMetadataOnlyConfirmedWorkoutDayWithoutSession() {
        let store = SessionStore()
        let marker = "confirmed-only-rollup-\(UUID().uuidString)"
        // A future fixture cannot overlap any persisted test/session evidence,
        // so this exercises the confirmed-workout-only day path exactly.
        let start = Date(timeIntervalSince1970: 2_208_988_800)
        let end = start.addingTimeInterval(60 * 60)
        let saved = store.confirmWorkoutWindowForUI(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: "test",
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityType: "Strength",
            reviewSource: marker
        )
        defer {
            for workout in store.confirmedWorkouts where workout.reviewSource == marker {
                _ = store.deleteConfirmedWorkout(id: workout.id)
            }
        }

        XCTAssertNotNil(saved)
        let rollup = store.dailyRollups(rest: 60, maxHR: 190).first {
            Calendar.current.isDate($0.day, inSameDayAs: start)
        }
        XCTAssertEqual(rollup?.sessions, 0)
        XCTAssertEqual(rollup?.confirmedWorkouts, 1)
        XCTAssertEqual(rollup?.strain, 0)
    }

    func testMorningMetricDayUsesEventCivilEndDayAfterTravel() {
        let start = date(2026, 7, 10, 5)
        let end = date(2026, 7, 10, 6, 30)
        let value = session(start: start,
                            end: end,
                            timeZoneIdentifier: "America/Los_Angeles")

        XCTAssertEqual(SessionStore.morningMetricDay(for: value, calendar: Self.utcCalendar),
                       date(2026, 7, 9, 0))
    }
}
