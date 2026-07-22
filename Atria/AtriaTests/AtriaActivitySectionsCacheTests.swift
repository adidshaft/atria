import XCTest
import UIKit
@testable import Atria

final class AtriaActivitySectionsCacheTests: XCTestCase {
    func testDetectedActivityPresentationUsesOnlyExplicitClassifierHint() {
        let generic = AtriaDetectedActivityPresentation.make(kind: .activityCandidate,
                                                             suggestedActivityType: nil)
        XCTAssertEqual(generic.title, "Activity detected")
        XCTAssertEqual(generic.icon, "waveform.path.ecg")

        let walking = AtriaDetectedActivityPresentation.make(kind: .activityCandidate,
                                                             suggestedActivityType: .walking)
        XCTAssertEqual(walking.title, "Walking suggested")
        XCTAssertEqual(walking.icon, AtriaWorkoutActivityType.walking.icon)

        let genericWorkout = AtriaDetectedActivityPresentation.make(kind: .workout,
                                                                    suggestedActivityType: nil)
        XCTAssertEqual(genericWorkout.title, "Workout detected")
        XCTAssertEqual(genericWorkout.icon, "figure.mixed.cardio")

        let now = Date()
        let classified = ActivityDetection(id: UUID(),
                                           kind: .activityCandidate,
                                           confidence: .medium,
                                           start: now.addingTimeInterval(-600),
                                           end: now,
                                           duration: 600,
                                           avgHR: 118,
                                           peakHR: 136,
                                           reason: "independent classifier evidence",
                                           suggestedActivityType: .cycling)
        XCTAssertEqual(classified.suggestedActivityType, .cycling)
        XCTAssertEqual(AtriaDetectedActivityPresentation.make(
            kind: classified.kind,
            suggestedActivityType: classified.suggestedActivityType
        ), AtriaDetectedActivityPresentation(title: "Cycling suggested", icon: "bicycle"))
    }

    private func workout(samples: Int = 177,
                         avgHR: Int = 86,
                         peakHR: Int = 100,
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
                                    peakHR: peakHR,
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
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateSummaryText(sparse),
                       "3% HR · Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.peakHeartRateText(sparse), "Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.shareMetrics(sparse),
                       .init(strain: "Incomplete",
                             peakHeartRate: "--",
                             averageHeartRate: nil,
                             includesZoneMinutes: false))

        let complete = workout(samples: 1_200, avgHR: 126, strain: 5.4, coverage: 92)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateSummaryText(complete),
                       "126 avg · 100 peak")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.peakHeartRateText(complete), "100")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.shareMetrics(complete),
                       .init(strain: "5.4",
                             peakHeartRate: "100",
                             averageHeartRate: "126",
                             includesZoneMinutes: true))
    }

    func testUnavailableAndOneSampleHeartRateNeverExposeNumericPeak() {
        let unavailable = workout(samples: 0, avgHR: 0, peakHR: 0)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateState(unavailable), .unavailable)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateSummaryText(unavailable), "No HR data")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.peakHeartRateText(unavailable), "No HR data")

        let oneSample = workout(samples: 1, avgHR: 126, peakHR: 150, coverage: 100)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateState(oneSample), .incomplete)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.averageHeartRateText(oneSample), "Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.peakHeartRateText(oneSample), "Incomplete")

        let corruptPeak = workout(samples: 200, avgHR: 126, peakHR: 0, coverage: 92)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateState(corruptPeak), .incomplete)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateSummaryText(corruptPeak),
                       "92% HR · Incomplete")
    }

    func testDayStrainIsIncompleteWhenAllSameDayWorkoutsAreSeverelySparse() {
        let sparse = workout(samples: 58, avgHR: 118, strain: 0.17, coverage: 3)
        let complete = workout(samples: 1_200, avgHR: 126, strain: 5.4, coverage: 92)

        XCTAssertTrue(AtriaWorkoutMetricPresentation.dayStrainIsIncomplete(day: sparse.start,
                                                                           strain: 0.17,
                                                                           workouts: [sparse]))
        XCTAssertTrue(AtriaWorkoutMetricPresentation.dayStrainIsIncomplete(day: sparse.start,
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

    func testDismissedWorkoutWindowLeavesSleepAndPhysiologicalHistoryIntact() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let dismissed = ActivityDetection(id: UUID(),
                                          kind: .activityCandidate,
                                          confidence: .medium,
                                          start: start,
                                          end: start.addingTimeInterval(1_800),
                                          duration: 1_800,
                                          avgHR: 118,
                                          peakHR: 150,
                                          reason: "test")
        let otherActivity = ActivityDetection(id: UUID(),
                                              kind: .workout,
                                              confidence: .medium,
                                              start: start.addingTimeInterval(7_200),
                                              end: start.addingTimeInterval(9_000),
                                              duration: 1_800,
                                              avgHR: 125,
                                              peakHR: 160,
                                              reason: "test")
        let sleep = ActivityDetection(id: UUID(),
                                      kind: .sleepCandidate,
                                      confidence: .medium,
                                      start: start,
                                      end: start.addingTimeInterval(28_800),
                                      duration: 28_800,
                                      avgHR: 55,
                                      peakHR: 72,
                                      reason: "test")
        let tombstone = AtriaDismissedWorkoutCandidate(start: start.addingTimeInterval(60),
                                                       end: start.addingTimeInterval(1_740))

        let visible = SessionStore.activityDetectionsForUI(
            [dismissed, otherActivity, sleep],
            dismissedCandidates: [tombstone]
        )

        XCTAssertEqual(Set(visible.map(\.id)), [otherActivity.id, sleep.id])
        XCTAssertTrue(visible.contains(sleep),
                      "Workout dismissal must not erase sleep evidence from physiological history")
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

    func testActivityIconsPreferSpecificSubtypeAndLegacyUserLabel() {
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "Sport",
                                                     subtype: "Basketball",
                                                     label: "Sport"),
                       AtriaWorkoutActivityType.basketball.icon)
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "Cardio",
                                                     subtype: "Stair climber",
                                                     label: "Cardio"),
                       AtriaWorkoutActivityType.stairClimber.icon)
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "HIIT",
                                                     subtype: "Jump rope",
                                                     label: "Intervals"),
                       AtriaWorkoutActivityType.jumpRope.icon)
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "Other",
                                                     subtype: nil,
                                                     label: "Evening dance"),
                       AtriaWorkoutActivityType.dance.icon)
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "Strength",
                                                     subtype: "Push",
                                                     label: "Chest"),
                       AtriaWorkoutActivityType.strength.icon)
    }

    func testSleepTimelineAndRowsShareCanonicalCrossDayDeduplication() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                        month: 7,
                                                                        day: 12)))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let savedStart = firstDay.addingTimeInterval(23 * 3_600)
        let savedEnd = secondDay.addingTimeInterval(7 * 3_600)
        let saved = activitySleep(id: "saved",
                                  day: secondDay,
                                  start: savedStart,
                                  end: savedEnd,
                                  confirmed: true)
        let duplicatePending = activitySleep(id: "pending-duplicate",
                                             day: secondDay,
                                             start: savedStart.addingTimeInterval(5 * 60),
                                             end: savedEnd.addingTimeInterval(-5 * 60),
                                             confirmed: false)
        let snapshot = SleepHistorySnapshot(nights: [saved],
                                            confirmedCount: 1,
                                            candidateCount: 0)

        let canonical = AtriaActivitySelectedDaySleeps.canonical(
            snapshot: snapshot,
            pendingReview: duplicatePending
        )
        let firstDayRows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: duplicatePending,
            selectedDay: firstDay,
            calendar: calendar
        )
        let secondDayRows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: duplicatePending,
            selectedDay: secondDay,
            calendar: calendar
        )

        XCTAssertEqual(canonical.map(\.id), [saved.id],
                       "A detector replay must not draw a second icon for a saved sleep")
        XCTAssertEqual(firstDayRows.map(\.id), [saved.id])
        XCTAssertEqual(secondDayRows.map(\.id), [saved.id],
                       "A cross-midnight timeline marker must have an editable row on both days")
    }

    func testSleepProjectionKeepsDistinctPendingNapAndLegacyDayOnlyRecord() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 7,
                                                                   day: 12)))
        let saved = activitySleep(id: "legacy",
                                  day: day,
                                  start: nil,
                                  end: nil,
                                  confirmed: true)
        let pendingNap = activitySleep(id: "pending-nap",
                                       day: day,
                                       start: day.addingTimeInterval(15 * 3_600),
                                       end: day.addingTimeInterval(15.5 * 3_600),
                                       confirmed: false)
        let snapshot = SleepHistorySnapshot(nights: [saved],
                                            confirmedCount: 1,
                                            candidateCount: 0)

        let visible = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: pendingNap,
            selectedDay: day,
            calendar: calendar
        )

        XCTAssertEqual(Set(visible.map(\.id)), [saved.id, pendingNap.id])
    }

    func testSleepStatusUsesCompactHumanCopyInsteadOfRawEnumText() {
        XCTAssertEqual(AtriaActivitySleepStatusPresentation.badge(
            confirmed: false,
            confidence: "review_needed"
        ), "Review")
        XCTAssertEqual(AtriaActivitySleepStatusPresentation.badge(
            confirmed: false,
            confidence: "HIGH-CONFIDENCE"
        ), "High Confidence")
        XCTAssertEqual(AtriaActivitySleepStatusPresentation.badge(
            confirmed: true,
            confidence: "review_needed"
        ), "Confirmed")
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

    func testTimelineAxisReplacesAnchorThatWouldCollideWithNow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 7,
                                                                   day: 12)))
        let now = day.addingTimeInterval(17 * 3_600 + 39 * 60)

        let ticks = AtriaActivityTimelineAxis.ticks(selectedDay: day,
                                                    calendar: calendar,
                                                    now: now)

        XCTAssertEqual(ticks.map(\.label), ["12a", "6a", "12p", "Now"])
        XCTAssertFalse(ticks.contains { calendar.component(.hour, from: $0.date) == 18 })
        XCTAssertEqual(ticks.last?.date, now)
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

    func testCurrentActivityWindowSpansMidnightFromConfirmedWakeToNow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let wakeDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
        let wake = wakeDay.addingTimeInterval(7 * 3_600)
        let now = wakeDay.addingTimeInterval(26 * 3_600)
        let night = activitySleep(id: "main",
                                  day: wakeDay,
                                  start: wake.addingTimeInterval(-8 * 3_600),
                                  end: wake,
                                  confirmed: true)
        let snapshot = SleepHistorySnapshot(nights: [night], confirmedCount: 1, candidateCount: 0)

        let window = AtriaActivityDisplayWindow.current(now: now,
                                                        sleepHistory: snapshot,
                                                        calendar: calendar)

        XCTAssertEqual(window.interval.start, wake)
        XCTAssertEqual(window.interval.end, now)
        XCTAssertEqual(window.labelDay, wakeDay)
        XCTAssertTrue(window.isCurrentPhysiologicalDay)
    }

    func testPhysiologicalTimelineIncludesBothSidesOfMidnightAndClipsAtWake() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
        let interval = DateInterval(start: day.addingTimeInterval(7 * 3_600),
                                    end: day.addingTimeInterval(26 * 3_600))
        let beforeWake = timelineWorkout(id: "before-wake",
                                         start: day.addingTimeInterval(6 * 3_600),
                                         end: day.addingTimeInterval(6.5 * 3_600),
                                         type: .walking)
        let evening = timelineWorkout(id: "evening",
                                      start: day.addingTimeInterval(20 * 3_600),
                                      end: day.addingTimeInterval(21 * 3_600),
                                      type: .running)
        let afterMidnight = timelineWorkout(id: "after-midnight",
                                            start: day.addingTimeInterval(25 * 3_600),
                                            end: day.addingTimeInterval(25.5 * 3_600),
                                            type: .cycling)

        let spans = AtriaActivityTimelineBuilder.workoutSpans(
            workouts: [beforeWake, evening, afterMidnight], interval: interval
        )

        XCTAssertEqual(Set(spans.map(\.id)), ["workout-evening", "workout-after-midnight"])
    }

    func testHistoricalActivityWindowRemainsCivilDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
        let window = AtriaActivityDisplayWindow.historical(day: day.addingTimeInterval(15 * 3_600),
                                                           calendar: calendar)

        XCTAssertEqual(window.interval.start, day)
        XCTAssertEqual(window.interval.end, day.addingTimeInterval(24 * 3_600))
        XCTAssertFalse(window.isCurrentPhysiologicalDay)
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


    private func activitySleep(id: String,
                               day: Date,
                               start: Date?,
                               end: Date?,
                               confirmed: Bool) -> SleepHistorySnapshot.Night {
        let duration: TimeInterval
        if let start, let end {
            duration = max(0, end.timeIntervalSince(start))
        } else {
            duration = 0
        }
        return SleepHistorySnapshot.Night(id: id,
                                          day: day,
                                          start: start,
                                          end: end,
                                          duration: duration,
                                          restingHR: 55,
                                          hrv: nil,
                                          respiratoryRate: nil,
                                          sleepEfficiency: nil,
                                          confidence: confirmed ? "confirmed" : "review_needed",
                                          source: confirmed ? "manual_sleep" : "sleep_candidate",
                                          confirmed: confirmed,
                                          stageSegments: [])
    }
}
