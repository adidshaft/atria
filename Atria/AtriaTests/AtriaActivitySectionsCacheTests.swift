import XCTest
import UIKit
@testable import Atria

final class AtriaActivitySectionsCacheTests: XCTestCase {
    private func workout(samples: Int = 177,
                         avgHR: Int = 86,
                         strain: Double? = 0.051,
                         coverage: Int = 100) -> UserConfirmedWorkout {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return UserConfirmedWorkout(id: "workout",
                                    createdAt: start,
                                    start: start,
                                    end: start.addingTimeInterval(173),
                                    label: "Workout",
                                    source: "test",
                                    confidence: "high",
                                    sessions: 1,
                                    samples: samples,
                                    avgHR: avgHR,
                                    peakHR: 100,
                                    p95HR: 96,
                                    p99HR: 99,
                                    thresholdHR: 124,
                                    streamCoveragePercent: coverage,
                                    observedDuration: 173,
                                    reason: "test",
                                    strain: strain,
                                    zoneSeconds: [:])
    }

    func testGentleWorkoutWithHeartRateDoesNotClaimNoHRData() {
        XCTAssertEqual(AtriaActivityMonitorTab.strainBadge(for: workout()), "Strain 0.1")
    }

    func testOnlyMissingSamplesClaimNoHRData() {
        XCTAssertEqual(AtriaActivityMonitorTab.strainBadge(for: workout(samples: 0)), "No HR data")
        XCTAssertEqual(AtriaActivityMonitorTab.strainBadge(for: workout(avgHR: 0)), "No HR data")
    }

    func testSparseHeartRateIsQualifiedInsteadOfDiscarded() {
        XCTAssertEqual(AtriaActivityMonitorTab.strainBadge(for: workout(strain: 1.1, coverage: 40)),
                       "Strain 1.1 · partial HR")
    }

    func testSeverelySparseWorkoutDoesNotShowPreciseDerivedMetrics() {
        let sparse = workout(samples: 58, avgHR: 118, strain: 0.17, coverage: 3)

        XCTAssertTrue(AtriaWorkoutMetricPresentation.metricsAreIncomplete(sparse))
        XCTAssertEqual(AtriaActivityMonitorTab.strainBadge(for: sparse), "3% HR · Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.strainText(sparse), "Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.averageHeartRateText(sparse), "Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.energyText(sparse), "Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.shareMetrics(sparse),
                       .init(strain: "Incomplete",
                             peakHeartRate: "--",
                             averageHeartRate: nil,
                             includesZoneMinutes: false))

        let complete = workout(samples: 1_200, avgHR: 126, strain: 5.4, coverage: 92)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.shareMetrics(complete),
                       .init(strain: "5.4",
                             peakHeartRate: "100",
                             averageHeartRate: "126",
                             includesZoneMinutes: true))
    }

    func testTinyDayStrainIsIncompleteOnlyWhenAllSameDayWorkoutsAreSeverelySparse() {
        let sparse = workout(samples: 58, avgHR: 118, strain: 0.17, coverage: 3)
        let complete = workout(samples: 1_200, avgHR: 126, strain: 5.4, coverage: 92)

        XCTAssertTrue(AtriaWorkoutMetricPresentation.dayStrainIsIncomplete(day: sparse.start,
                                                                           strain: 0.17,
                                                                           workouts: [sparse]))
        XCTAssertFalse(AtriaWorkoutMetricPresentation.dayStrainIsIncomplete(day: sparse.start,
                                                                            strain: 5.4,
                                                                            workouts: [sparse]))
        XCTAssertFalse(AtriaWorkoutMetricPresentation.dayStrainIsIncomplete(day: sparse.start,
                                                                            strain: 0.17,
                                                                            workouts: [sparse, complete]))
    }

    func testActivityReviewProjectionShowsUnsavedDetectorWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let detection = ActivityDetection(id: UUID(),
                                          kind: .activityCandidate,
                                          confidence: .medium,
                                          start: day.addingTimeInterval(600),
                                          end: day.addingTimeInterval(2_400),
                                          duration: 1_800,
                                          avgHR: 118,
                                          peakHR: 154,
                                          reason: "test")

        let visible = AtriaActivityReviewProjection.visibleDetections(
            [detection],
            workoutReview: nil,
            confirmedWorkouts: [],
            selectedDay: day,
            calendar: calendar
        )

        XCTAssertEqual(visible, [detection])
    }

    func testActivityReviewProjectionDeduplicatesConfirmedAndHigherQualityReviewWindows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let start = day.addingTimeInterval(600)
        let end = start.addingTimeInterval(1_800)
        let detection = ActivityDetection(id: UUID(),
                                          kind: .workout,
                                          confidence: .medium,
                                          start: start,
                                          end: end,
                                          duration: 1_800,
                                          avgHR: 118,
                                          peakHR: 154,
                                          reason: "test")
        let review = WorkoutReviewCandidate(id: "review",
                                            start: start,
                                            end: end,
                                            kind: .activityCandidate,
                                            confidence: .medium,
                                            duration: 1_800,
                                            avgHR: 118,
                                            peakHR: 154,
                                            streamCoveragePercent: 92,
                                            observedDuration: 1_700,
                                            droppedGapSeconds: 100,
                                            maxSampleGap: 12,
                                            gapCount: 2,
                                            reason: "test")

        XCTAssertTrue(AtriaActivityReviewProjection.visibleDetections(
            [detection],
            workoutReview: review,
            confirmedWorkouts: [],
            selectedDay: day,
            calendar: calendar
        ).isEmpty, "the cached review window is the single review row")

        let confirmed = workout(samples: 1_200, avgHR: 126, strain: 5.4, coverage: 92)
        let matchingReview = WorkoutReviewCandidate(id: "confirmed-review",
                                                    start: confirmed.start,
                                                    end: confirmed.end,
                                                    kind: .activityCandidate,
                                                    confidence: .medium,
                                                    duration: confirmed.duration,
                                                    avgHR: confirmed.avgHR,
                                                    peakHR: confirmed.peakHR,
                                                    streamCoveragePercent: 92,
                                                    observedDuration: confirmed.duration,
                                                    droppedGapSeconds: 0,
                                                    maxSampleGap: 1,
                                                    gapCount: 0,
                                                    reason: "test")
        XCTAssertNil(AtriaActivityReviewProjection.visibleWorkoutReview(
            matchingReview,
            confirmedWorkouts: [confirmed],
            selectedDay: confirmed.start,
            calendar: calendar
        ))
    }

    func testSelectedDayTimelineIncludesEveryConfirmedActivityTypeWithItsOwnIcon() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 7,
                                                                   day: 12)))
        let workouts = AtriaWorkoutActivityType.allCases.enumerated().map { offset, type in
            timelineWorkout(id: type.id,
                            start: day.addingTimeInterval(Double(offset * 120)),
                            end: day.addingTimeInterval(Double(offset * 120 + 60)),
                            type: type)
        }

        let spans = AtriaActivityTimelineBuilder.workoutSpans(workouts: workouts,
                                                               selectedDay: day,
                                                               calendar: calendar)

        XCTAssertEqual(spans.count, AtriaWorkoutActivityType.allCases.count)
        XCTAssertEqual(Set(spans.map(\.id)).count, spans.count)
        XCTAssertEqual(Set(spans.map(\.lane)).count, 1,
                       "Non-overlapping activities should share one compact lane")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: spans.map { ($0.label, $0.icon) }),
                       Dictionary(uniqueKeysWithValues: AtriaWorkoutActivityType.allCases.map {
                           ($0.rawValue, $0.icon)
                       }))
        XCTAssertEqual(Set(AtriaWorkoutActivityType.allCases.map(\.icon)).count,
                       AtriaWorkoutActivityType.allCases.count,
                       "Each selectable activity type must retain distinct timeline iconography")
        for type in AtriaWorkoutActivityType.allCases {
            XCTAssertNotNil(UIImage(systemName: type.icon),
                            "\(type.rawValue) must use an available native SF Symbol")
        }
    }

    func testTimelineAxisUsesCompactSixHourLabelsAndContextualFinalTick() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 7,
                                                                   day: 12)))
        let now = day.addingTimeInterval(20 * 3_600 + 17 * 60)
        let todayTicks = AtriaActivityTimelineAxis.ticks(selectedDay: day,
                                                         calendar: calendar,
                                                         now: now)
        let pastDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
        let pastTicks = AtriaActivityTimelineAxis.ticks(selectedDay: pastDay,
                                                        calendar: calendar,
                                                        now: now)

        XCTAssertEqual(todayTicks.map(\.label), ["12a", "6a", "12p", "6p", "Now"])
        XCTAssertEqual(todayTicks.map(\.date), [
            day,
            day.addingTimeInterval(6 * 3_600),
            day.addingTimeInterval(12 * 3_600),
            day.addingTimeInterval(18 * 3_600),
            now
        ])
        XCTAssertEqual(pastTicks.map(\.label), ["12a", "6a", "12p", "6p", "12a"])
        XCTAssertEqual(pastTicks.last?.accessibilityLabel, "End of day, 12 AM")
    }

    func testTimelineKeepsOverlappingActivitiesVisibleInSeparateLanesAndClipsCrossDaySpans() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 7,
                                                                   day: 12)))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let sameStart = day.addingTimeInterval(12 * 3_600)
        let workouts = [
            timelineWorkout(id: "walk", start: sameStart,
                            end: sameStart.addingTimeInterval(600), type: .walking),
            timelineWorkout(id: "run", start: sameStart,
                            end: sameStart.addingTimeInterval(600), type: .running),
            timelineWorkout(id: "cross-midnight",
                            start: day.addingTimeInterval(23.5 * 3_600),
                            end: nextDay.addingTimeInterval(1_800), type: .cycling),
            timelineWorkout(id: "tomorrow", start: nextDay.addingTimeInterval(3_600),
                            end: nextDay.addingTimeInterval(4_000), type: .rowing),
            timelineWorkout(id: "invalid", start: sameStart, end: sameStart, type: .other)
        ]

        let spans = AtriaActivityTimelineBuilder.workoutSpans(workouts: workouts,
                                                               selectedDay: day,
                                                               calendar: calendar)

        XCTAssertEqual(Set(spans.map(\.id)),
                       ["workout-walk", "workout-run", "workout-cross-midnight"])
        XCTAssertEqual(Set(spans.map(\.lane)).count, 2,
                       "Only simultaneous activities should require separate chart lanes")
        let crossing = try XCTUnwrap(spans.first { $0.id == "workout-cross-midnight" })
        XCTAssertEqual(crossing.start, day.addingTimeInterval(23.5 * 3_600))
        XCTAssertEqual(crossing.end, nextDay)
    }

    func testTimelineLanePackingIsMinimalDeterministicAndReusesHalfOpenEnds() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let intervals = [
            AtriaActivityTimelineLaneInterval(id: "later", start: start.addingTimeInterval(20), end: start.addingTimeInterval(30)),
            AtriaActivityTimelineLaneInterval(id: "overlap", start: start.addingTimeInterval(5), end: start.addingTimeInterval(15)),
            AtriaActivityTimelineLaneInterval(id: "first", start: start, end: start.addingTimeInterval(10)),
            AtriaActivityTimelineLaneInterval(id: "touching", start: start.addingTimeInterval(10), end: start.addingTimeInterval(20))
        ]

        let assignments = AtriaActivityTimelineLanePacker.assignments(for: intervals)

        XCTAssertEqual(assignments["first"], 0)
        XCTAssertEqual(assignments["overlap"], 1)
        XCTAssertEqual(assignments["touching"], 0,
                       "An interval ending exactly at the next start must release its lane")
        XCTAssertEqual(assignments["later"], 0)
        XCTAssertEqual(Set(assignments.values), [0, 1])
    }

    func testCrossMidnightWorkoutIsSelectableOnBothDaysExactlyLikeTimeline() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                        month: 7,
                                                                        day: 12)))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let crossing = timelineWorkout(id: "cross-midnight",
                                       start: firstDay.addingTimeInterval(23.5 * 3_600),
                                       end: secondDay.addingTimeInterval(30 * 60),
                                       type: .cycling)
        let endsAtMidnight = timelineWorkout(id: "ends-at-midnight",
                                             start: firstDay.addingTimeInterval(23 * 3_600),
                                             end: secondDay,
                                             type: .walking)
        let startsAtMidnight = timelineWorkout(id: "starts-at-midnight",
                                               start: secondDay,
                                               end: secondDay.addingTimeInterval(30 * 60),
                                               type: .running)
        let invalid = timelineWorkout(id: "invalid",
                                      start: secondDay.addingTimeInterval(60),
                                      end: secondDay.addingTimeInterval(60),
                                      type: .other)
        let workouts = [crossing, endsAtMidnight, startsAtMidnight, invalid]

        let firstDayRows = AtriaActivitySelectedDayWorkouts.overlapping(
            workouts,
            selectedDay: firstDay,
            calendar: calendar
        )
        let secondDayRows = AtriaActivitySelectedDayWorkouts.overlapping(
            workouts,
            selectedDay: secondDay,
            calendar: calendar
        )
        let secondDaySpans = AtriaActivityTimelineBuilder.workoutSpans(
            workouts: workouts,
            selectedDay: secondDay,
            calendar: calendar
        )

        XCTAssertEqual(Set(firstDayRows.map(\.id)), ["cross-midnight", "ends-at-midnight"])
        XCTAssertEqual(Set(secondDayRows.map(\.id)), ["cross-midnight", "starts-at-midnight"])
        XCTAssertEqual(Set(secondDaySpans.map(\.id)),
                       Set(secondDayRows.map { "workout-\($0.id)" }),
                       "Every workout marker must have a matching tappable row on the selected day")
    }

    private func key(sleepRevision: Int = 1,
                     workoutsRevision: Int = 1,
                     rollupsRevision: Int = 1,
                     selectedDay: Date = Date(timeIntervalSince1970: 1_800_000_000),
                     identifier: Calendar.Identifier = .gregorian,
                     timeZone: String = "UTC") -> AtriaActivitySectionsRequestKey {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return AtriaActivitySectionsRequestKey(sleepRevision: sleepRevision,
                                               workoutsRevision: workoutsRevision,
                                               rollupsRevision: rollupsRevision,
                                               selectedDay: selectedDay,
                                               calendar: calendar)
    }

    func testRequestKeyTracksRevisionsSelectedDayAndCalendarIdentityAndTimeZone() {
        let original = key()

        XCTAssertNotEqual(original, key(sleepRevision: 2))
        XCTAssertNotEqual(original, key(workoutsRevision: 2))
        XCTAssertNotEqual(original, key(rollupsRevision: 2))
        XCTAssertNotEqual(original, key(selectedDay: Date(timeIntervalSince1970: 1_800_086_400)))
        XCTAssertNotEqual(original, key(identifier: .buddhist))
        XCTAssertNotEqual(original, key(timeZone: "America/Los_Angeles"))
    }

    func testDuplicatePendingAndPublishedRequestsAreCoalesced() throws {
        var cache = AtriaActivitySectionsCache<[Int]>()
        let requestKey = key()
        let request = try XCTUnwrap(cache.request(for: requestKey))

        XCTAssertNil(cache.request(for: requestKey))
        XCTAssertTrue(cache.publish([1, 2, 3], for: request))
        XCTAssertNil(cache.request(for: requestKey))
        XCTAssertEqual(cache.value, [1, 2, 3])
    }

    func testSupersededGenerationCannotPublish() throws {
        var cache = AtriaActivitySectionsCache<String>()
        let stale = try XCTUnwrap(cache.request(for: key()))
        let current = try XCTUnwrap(cache.request(for: key(sleepRevision: 2)))

        XCTAssertFalse(cache.publish("stale", for: stale))
        XCTAssertNil(cache.value)
        XCTAssertTrue(cache.publish("current", for: current))
        XCTAssertEqual(cache.value, "current")
    }

    func testPriorValueIsNotProjectedForANewlySelectedDayWhileItRefreshes() throws {
        var cache = AtriaActivitySectionsCache<String>()
        let firstKey = key()
        let nextKey = key(workoutsRevision: 2)
        let first = try XCTUnwrap(cache.request(for: firstKey))
        XCTAssertTrue(cache.isLoadingWithoutValue)
        XCTAssertTrue(cache.publish("prior", for: first))

        _ = try XCTUnwrap(cache.request(for: nextKey))

        XCTAssertEqual(cache.value, "prior")
        XCTAssertEqual(cache.value(for: firstKey), "prior")
        XCTAssertNil(cache.value(for: nextKey),
                     "Rows from the prior day must not appear under the newly selected day header")
        XCTAssertFalse(cache.isLoadingWithoutValue)
    }

    func testCancelledRequestCanBeRequestedAgain() throws {
        var cache = AtriaActivitySectionsCache<String>()
        let requestKey = key()
        let cancelled = try XCTUnwrap(cache.request(for: requestKey))

        cache.cancel(cancelled)

        XCTAssertNotNil(cache.request(for: requestKey))
    }

    func testRecoveryEffectComparesNextMorningWithPrecedingPersonalBaseline() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workoutDay = Date(timeIntervalSince1970: 1_800_000_000)
        let recoveryDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: workoutDay))
        let workout = UserConfirmedWorkout(id: "walk",
                                           createdAt: workoutDay,
                                           start: workoutDay,
                                           end: workoutDay.addingTimeInterval(1_800),
                                           label: "Walk",
                                           source: "test",
                                           confidence: "high",
                                           sessions: 1,
                                           samples: 100,
                                           avgHR: 110,
                                           peakHR: 130,
                                           p95HR: 125,
                                           p99HR: 130,
                                           thresholdHR: 100,
                                           streamCoveragePercent: 100,
                                           observedDuration: 1_800,
                                           reason: "test",
                                           zoneSeconds: [:])
        let prior = [60, 70, 80].enumerated().map { index, recovery in
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day,
                                                     value: -(index + 1),
                                                     to: recoveryDay)!,
                                  recovery: recovery,
                                  calendar: calendar)
        }
        let observed = DailyRollupStoreEntry(day: recoveryDay, recovery: 80, calendar: calendar)

        let effect = AtriaActivityRecoveryEffect.make(workout: workout,
                                                      rollups: [observed] + prior,
                                                      calendar: calendar)

        XCTAssertEqual(effect.status, .observed(delta: 10, recovery: 80, baseline: 70, samples: 3))
    }

    private func timelineWorkout(id: String,
                                 start: Date,
                                 end: Date,
                                 type: AtriaWorkoutActivityType) -> UserConfirmedWorkout {
        UserConfirmedWorkout(id: id,
                             createdAt: start,
                             start: start,
                             end: end,
                             label: type.rawValue,
                             source: "test",
                             confidence: "user_confirmed",
                             sessions: 1,
                             samples: 2,
                             avgHR: 100,
                             peakHR: 120,
                             p95HR: 115,
                             p99HR: 119,
                             thresholdHR: 110,
                             streamCoveragePercent: 100,
                             observedDuration: max(0, end.timeIntervalSince(start)),
                             reason: "test",
                             activityType: type.rawValue,
                             zoneSeconds: [:])
    }
}
