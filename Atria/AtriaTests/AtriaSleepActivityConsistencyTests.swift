import XCTest
@testable import Atria

final class AtriaSleepActivityConsistencyTests: XCTestCase {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.utcCalendar.date(from: DateComponents(year: 2032,
                                                   month: 7,
                                                   day: day,
                                                   hour: hour,
                                                   minute: minute))!
    }

    private func sleep(id: String = "confirmed-night",
                       start: Date,
                       end: Date,
                       source: String = "auto_confirmed_sleep") -> UserConfirmedSleep {
        UserConfirmedSleep(id: id,
                           createdAt: end,
                           start: start,
                           end: end,
                           source: source,
                           confidence: "test",
                           sessions: 1,
                           samples: 400,
                           avgHR: 52,
                           peakHR: 58,
                           restingHR: 49,
                           hrv: 52,
                           hrvWindowCount: 8,
                           duration: end.timeIntervalSince(start),
                           span: end.timeIntervalSince(start),
                           reason: "test",
                           motionSource: "validated_strap_stillness",
                           motionValidated: true,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: "UTC")
    }

    private func workout(start: Date, end: Date) -> UserConfirmedWorkout {
        UserConfirmedWorkout(id: "confirmed-workout",
                             createdAt: end,
                             start: start,
                             end: end,
                             label: "Workout",
                             source: "test",
                             confidence: "high",
                             sessions: 1,
                             samples: 600,
                             avgHR: 130,
                             peakHR: 160,
                             p95HR: 155,
                             p99HR: 159,
                             thresholdHR: 120,
                             streamCoveragePercent: 100,
                             observedDuration: end.timeIntervalSince(start),
                             reason: "test",
                             eventTimeZoneIdentifier: "UTC")
    }

    func testConfirmedOvernightKeepsCandidateWakeDayIdentity() throws {
        let start = date(10, 23)
        let end = date(11, 7)
        let confirmed = sleep(start: start, end: end)

        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [confirmed],
                                            calendar: Self.utcCalendar)
        let night = try XCTUnwrap(snapshot.latestMainSleep)

        XCTAssertEqual(night.day, Self.utcCalendar.startOfDay(for: end))
        XCTAssertEqual(night.id, confirmed.id)
        XCTAssertTrue(night.confirmed)
    }

    func testConfirmedSleepSuppressesSameWakeDayCandidateAfterSave() throws {
        let start = date(10, 23)
        let end = date(11, 7)
        let confirmed = sleep(start: start, end: end)
        let wakeDay = Self.utcCalendar.startOfDay(for: end)
        let candidateRollup = DailyRollup(day: wakeDay,
                                         sessions: 1,
                                         activityCandidates: 0,
                                         workouts: 0,
                                         confirmedWorkouts: 0,
                                         restCandidates: 0,
                                         sleepReady: 0,
                                         sleepCandidates: 1,
                                         duration: end.timeIntervalSince(start),
                                         sleepDuration: end.timeIntervalSince(start),
                                         sleepSpan: end.timeIntervalSince(start),
                                         sleepStart: start,
                                         sleepEnd: end,
                                         sleepSource: "sleep_candidate",
                                         sleepStageSegments: [],
                                         strain: 0,
                                         avgHRV: 52,
                                         restingHR: 49,
                                         avgRespiratoryRate: nil)

        let snapshot = SleepHistorySnapshot(rollups: [candidateRollup],
                                            confirmedSleeps: [confirmed],
                                            calendar: Self.utcCalendar)

        XCTAssertEqual(snapshot.candidateCount, 0)
        XCTAssertEqual(snapshot.latestMainSleep?.id, confirmed.id)
        XCTAssertTrue(snapshot.latestMainSleep?.confirmed == true)
    }

    func testConfirmedNightMintsRecoveryOnSameWakeDayWithoutMovingEvidence() throws {
        let start = date(10, 23)
        let end = date(11, 7)
        let confirmed = sleep(start: start, end: end)
        let wakeDay = Self.utcCalendar.startOfDay(for: end)
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [confirmed],
                                            calendar: Self.utcCalendar)

        let metric = try XCTUnwrap(SessionStore.makeMorningFrozenDailyMetric(
            for: wakeDay,
            computed: [],
            sessions: [],
            sleep: snapshot,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: end.addingTimeInterval(60 * 60),
            calendar: Self.utcCalendar
        ))
        let night = try XCTUnwrap(snapshot.latestMainSleep)

        XCTAssertEqual(metric.day, wakeDay)
        XCTAssertEqual(metric.sleepStart, confirmed.start)
        XCTAssertEqual(metric.sleepEnd, confirmed.end)
        XCTAssertEqual(metric.sleepDuration, confirmed.duration)
        XCTAssertTrue(DailyRecoveryResolver.metricMatchesConfirmedNight(metric, night: night))
    }

    func testActivityCenterShowsSavedSleepBeforeMetricRollupExists() throws {
        let start = date(10, 23)
        let end = date(11, 7)
        let confirmed = sleep(start: start, end: end)

        let model = AtriaHistoryModel.make(rollups: [],
                                           workouts: [],
                                           sleeps: [confirmed],
                                           calendar: Self.utcCalendar)
        let day = try XCTUnwrap(model.days.first)

        XCTAssertEqual(model.days.count, 1)
        XCTAssertEqual(day.date, Self.utcCalendar.startOfDay(for: end))
        XCTAssertEqual(day.confirmedSleepCount, 1)
        XCTAssertEqual(day.sleepSeconds, confirmed.duration)
        XCTAssertEqual(day.state, .sleepOnly)
    }

    func testActivityCenterDoesNotDropTwoDurableSleepsOnSameWakeDay() throws {
        let main = sleep(id: "main",
                         start: date(10, 23),
                         end: date(11, 7))
        let resumed = sleep(id: "resumed",
                            start: date(11, 9),
                            end: date(11, 11),
                            source: "user_adjusted_sleep")

        let model = AtriaHistoryModel.make(rollups: [],
                                           workouts: [],
                                           sleeps: [main, resumed],
                                           calendar: Self.utcCalendar)
        let day = try XCTUnwrap(model.days.first)

        XCTAssertEqual(model.days.count, 1)
        XCTAssertEqual(day.confirmedSleepCount, 2)
        XCTAssertEqual(day.sleepSeconds, main.duration + resumed.duration)
    }

    func testActivityCenterShowsGenuineCandidateOnlyDayAsReview() throws {
        let candidateStart = date(12, 18)
        let candidateDay = AtriaHistoryReviewCandidateDay(
            day: Self.utcCalendar.startOfDay(for: candidateStart),
            count: 2
        )

        let model = AtriaHistoryModel.make(rollups: [],
                                           workouts: [],
                                           sleeps: [],
                                           reviewCandidateDays: [candidateDay],
                                           calendar: Self.utcCalendar)
        let day = try XCTUnwrap(model.days.first)

        XCTAssertEqual(model.days.count, 1)
        XCTAssertEqual(day.reviewPending, 2)
        XCTAssertEqual(day.state, .review)
    }

    func testConfirmedWorkoutTakesStatePrecedenceWithoutHidingReviewCount() throws {
        let start = date(13, 18)
        let end = date(13, 19)
        let candidateDay = AtriaHistoryReviewCandidateDay(
            day: Self.utcCalendar.startOfDay(for: start),
            count: 1
        )

        let model = AtriaHistoryModel.make(rollups: [],
                                           workouts: [workout(start: start, end: end)],
                                           sleeps: [],
                                           reviewCandidateDays: [candidateDay],
                                           calendar: Self.utcCalendar)
        let day = try XCTUnwrap(model.days.first)

        XCTAssertEqual(day.confirmedWorkoutCount, 1)
        XCTAssertEqual(day.reviewPending, 1)
        XCTAssertEqual(day.state, .confirmed)
    }
}
