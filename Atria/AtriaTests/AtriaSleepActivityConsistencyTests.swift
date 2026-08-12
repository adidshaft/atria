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

    // A user who slept twice on one wake day (a short overnight plus a long
    // daytime sleep) must have BOTH mains' effective hours in the persisted
    // daily total. Regression guard for the makeSavedDailyMetrics path, which the
    // History-model test above does not exercise.
    func testDailyMetricSumsTwoSameWakeDayMainSleeps() throws {
        let overnight = sleep(id: "overnight",
                              start: date(10, 23),
                              end: date(11, 3)) // 4h
        let daytime = sleep(id: "daytime",
                            start: date(11, 6),
                            end: date(11, 14), // 8h — same wake day (11)
                            source: "manual_sleep")
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [overnight, daytime],
                                            calendar: Self.utcCalendar)
        // One is canonical, the other lands in additionalMainNights.
        XCTAssertEqual(snapshot.nights.count, 1)
        XCTAssertEqual(snapshot.additionalMainNights.count, 1)

        let metrics = SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: snapshot,
            baseline: PersonalBaseline(),
            calendar: Self.utcCalendar)
        let wakeDay = Self.utcCalendar.startOfDay(for: daytime.end)
        let metric = try XCTUnwrap(metrics.first { $0.day == wakeDay })
        XCTAssertEqual(try XCTUnwrap(metric.sleepDuration),
                       overnight.duration + daytime.duration,
                       accuracy: 0.5,
                       "the day's total sleep must credit both same-wake-day mains")
    }

    // The display accessor sums same-wake-day mains but excludes resumed segments
    // (already folded into the canonical night) so they are never double-counted.
    func testLatestMainSleepDayEffectiveDurationSumsMainsExcludingResumed() throws {
        let overnight = sleep(id: "overnight",
                              start: date(10, 23),
                              end: date(11, 3)) // 4h main
        let daytime = sleep(id: "daytime",
                            start: date(11, 6),
                            end: date(11, 14), // 8h main — longer, so canonical
                            source: "manual_sleep")
        let resumed = sleep(id: "resumed",
                            start: date(11, 3, 30),
                            end: date(11, 4, 30), // 1h resumed continuation
                            source: "resumed_sleep")
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [overnight, daytime, resumed],
                                            calendar: Self.utcCalendar)
        // The longer main is canonical; the shorter main lands in additionalMainNights.
        let latest = try XCTUnwrap(snapshot.latestMainSleep)
        XCTAssertEqual(latest.duration, daytime.duration, accuracy: 0.5,
                       "the longer daytime sleep is the canonical main")
        // Total credits BOTH genuine mains and excludes the resumed continuation,
        // which must never be summed a second time.
        let total = try XCTUnwrap(snapshot.latestMainSleepDayEffectiveDuration)
        XCTAssertEqual(total, overnight.duration + daytime.duration, accuracy: 0.5)
        XCTAssertLessThan(total, overnight.duration + daytime.duration + resumed.duration,
                          "the resumed segment must not add to the day total")
    }

    // MARK: - "Which is your main sleep?" (dayPrimaryChoice) honoring

    // Two mains wake on the same day (early 4h, late 8h). Default: the later wake
    // anchors the physiological cycle and the longer is canonical.
    func testSameDayMainsDefaultToLongestAndLatestWithoutChoice() {
        let early = sleep(id: "early", start: date(10, 23), end: date(11, 3)) // 4h
        let late = sleep(id: "late", start: date(11, 6), end: date(11, 14))   // 8h
        let now = date(11, 16)
        let boundaries = AtriaPhysiologicalCycle.boundaryEligibleMainSleeps(
            now: now, confirmedSleeps: [early, late], calendar: Self.utcCalendar)
        XCTAssertEqual(boundaries.last?.id, "late", "latest wake anchors by default")
        XCTAssertEqual(boundaries.count, 2)
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [early, late],
                                            calendar: Self.utcCalendar)
        XCTAssertEqual(snapshot.latestMainSleep?.id, "late", "longer is canonical by default")
    }

    // Choosing the EARLIER, shorter sleep as primary makes it anchor the cycle and
    // become canonical; the later/longer main is demoted to a second sleep.
    func testChoosingEarlierSleepAsPrimaryOverridesHeuristic() {
        let early = sleep(id: "early", start: date(10, 23), end: date(11, 3))
            .replacingDayPrimaryChoice(true)
        let late = sleep(id: "late", start: date(11, 6), end: date(11, 14))
            .replacingDayPrimaryChoice(false)
        let now = date(11, 16)
        let boundaries = AtriaPhysiologicalCycle.boundaryEligibleMainSleeps(
            now: now, confirmedSleeps: [early, late], calendar: Self.utcCalendar)
        XCTAssertFalse(boundaries.contains { $0.id == "late" },
                       "the non-primary same-day main must not anchor its own cycle")
        XCTAssertEqual(boundaries.last?.id, "early",
                       "the chosen primary anchors the physiological day")
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [early, late],
                                            calendar: Self.utcCalendar)
        XCTAssertEqual(snapshot.latestMainSleep?.id, "early",
                       "the chosen primary is canonical even though it is shorter")
        XCTAssertTrue(snapshot.additionalMainNights.contains { $0.id == "late" },
                      "the non-primary main is preserved as a second sleep")
    }

    // Choosing the later/longer sleep keeps it as anchor/canonical and demotes the
    // earlier one out of boundary eligibility.
    func testChoosingLaterSleepAsPrimaryDemotesEarlier() {
        let early = sleep(id: "early", start: date(10, 23), end: date(11, 3))
            .replacingDayPrimaryChoice(false)
        let late = sleep(id: "late", start: date(11, 6), end: date(11, 14))
            .replacingDayPrimaryChoice(true)
        let now = date(11, 16)
        let boundaries = AtriaPhysiologicalCycle.boundaryEligibleMainSleeps(
            now: now, confirmedSleeps: [early, late], calendar: Self.utcCalendar)
        XCTAssertEqual(boundaries.map(\.id), ["late"],
                       "only the chosen primary is boundary-eligible")
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [early, late],
                                            calendar: Self.utcCalendar)
        XCTAssertEqual(snapshot.latestMainSleep?.id, "late")
        XCTAssertTrue(snapshot.additionalMainNights.contains { $0.id == "early" })
    }

    // The additive field round-trips and defaults to nil for legacy records.
    func testDayPrimaryChoiceCodableRoundTripAndLegacyDefault() throws {
        let chosen = sleep(id: "chosen", start: date(10, 23), end: date(11, 7))
            .replacingDayPrimaryChoice(true)
        let data = try JSONEncoder().encode(chosen)
        let restored = try JSONDecoder().decode(UserConfirmedSleep.self, from: data)
        XCTAssertEqual(restored.dayPrimaryChoice, true)
        // A legacy record without the key decodes to nil (no migration break).
        let legacy = sleep(id: "legacy", start: date(10, 23), end: date(11, 7))
        XCTAssertNil(legacy.dayPrimaryChoice)
        let legacyData = try JSONEncoder().encode(legacy)
        XCTAssertNil(try JSONDecoder().decode(UserConfirmedSleep.self, from: legacyData).dayPrimaryChoice)
    }

    // Detection: a day with two same-wake-day mains and no recorded choice is
    // surfaced, longest first; once answered it stops surfacing.
    func testPendingSameDayMainChoiceDetectionLifecycle() {
        let early = sleep(id: "early", start: date(10, 23), end: date(11, 3)) // 4h
        let late = sleep(id: "late", start: date(11, 6), end: date(11, 14))   // 8h

        let choice = SessionStore.pendingSameDayMainSleepChoice(
            confirmedSleeps: [early, late], calendar: Self.utcCalendar)
        XCTAssertNotNil(choice)
        XCTAssertEqual(choice?.options.map(\.id), ["late", "early"], "longest first")
        XCTAssertEqual(choice?.recommendedPrimaryID, "late")

        // A single-main day never prompts.
        XCTAssertNil(SessionStore.pendingSameDayMainSleepChoice(
            confirmedSleeps: [late], calendar: Self.utcCalendar))

        // Once either main carries a choice, the day is resolved — no re-prompt.
        let resolvedEarly = early.replacingDayPrimaryChoice(false)
        let resolvedLate = late.replacingDayPrimaryChoice(true)
        XCTAssertNil(SessionStore.pendingSameDayMainSleepChoice(
            confirmedSleeps: [resolvedEarly, resolvedLate], calendar: Self.utcCalendar))
    }

    // A resumed continuation is not a second main and never triggers the prompt.
    func testPendingSameDayMainChoiceIgnoresResumedSegments() {
        let main = sleep(id: "main", start: date(10, 23), end: date(11, 7))
        let resumed = sleep(id: "resumed", start: date(11, 9), end: date(11, 11),
                            source: "resumed_sleep")
        XCTAssertNil(SessionStore.pendingSameDayMainSleepChoice(
            confirmedSleeps: [main, resumed], calendar: Self.utcCalendar))
    }

    // MARK: - Main→nap reclassification recomputes day ownership (handoff-5 P0-A)

    // The physically reproduced topology: a short overnight main (00:58–03:41,
    // 2.62h) plus a long daytime main (06:15–15:27) colliding on one wake day.
    // The user answered "which is your main sleep?" with the SHORT one (the
    // worst case), then reclassified it to a nap. Without normalization the
    // long sleep keeps `dayPrimaryChoice == false`, is excluded from boundary
    // eligibility forever, and the physiological day de-anchors — the exact
    // "stale 2h37m ring / inverted Activity days" failure.
    func testMainToNapReclassificationRecomputesDayOwnershipAtomically() throws {
        let short = sleep(id: "short",
                          start: date(12, 0, 58),
                          end: date(12, 3, 41),
                          source: "user_adjusted_sleep")
        let long = sleep(id: "long",
                         start: date(12, 6, 15),
                         end: date(12, 15, 27),
                         source: "user_adjusted_sleep")

        // 1. The collision prompts.
        XCTAssertNotNil(SessionStore.pendingSameDayMainSleepChoice(
            confirmedSleeps: [short, long], calendar: Self.utcCalendar))

        // 2. The user answers with the SHORT one as primary.
        let answeredShort = short.replacingDayPrimaryChoice(true)
        let answeredLong = long.replacingDayPrimaryChoice(false)

        // 3. Reclassify the short main to a nap (type-only edit: same window,
        //    new source, flag dropped — exactly what the reclassify path does).
        let nap = UserConfirmedSleep(id: "\(Int(answeredShort.start.timeIntervalSince1970))-\(Int(answeredShort.end.timeIntervalSince1970))-user_adjusted_nap",
                                     createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                     start: answeredShort.start,
                                     end: answeredShort.end,
                                     source: "user_adjusted_nap",
                                     confidence: answeredShort.confidence,
                                     sessions: answeredShort.sessions,
                                     samples: answeredShort.samples,
                                     avgHR: answeredShort.avgHR,
                                     peakHR: answeredShort.peakHR,
                                     restingHR: answeredShort.restingHR,
                                     hrv: answeredShort.hrv,
                                     hrvWindowCount: answeredShort.hrvWindowCount,
                                     duration: answeredShort.duration,
                                     span: answeredShort.span,
                                     reason: "user_reclassified",
                                     motionSource: answeredShort.motionSource,
                                     motionValidated: answeredShort.motionValidated,
                                     stageSegments: answeredShort.stageSegments,
                                     eventTimeZoneIdentifier: answeredShort.eventTimeZoneIdentifier)

        // 4. Every durable save normalizes: the day no longer collides, so the
        //    survivor's stale `false` must clear.
        let normalized = try XCTUnwrap(SessionStore.normalizingDayPrimaryChoices(
            in: [nap, answeredLong],
            calendar: Self.utcCalendar,
            shouldContinue: { true }))
        let survivedLong = try XCTUnwrap(normalized.first { $0.id == answeredLong.id })
        XCTAssertNil(survivedLong.dayPrimaryChoice,
                     "a dissolved collision must clear the survivor's stale answer")
        let survivedNap = try XCTUnwrap(normalized.first { $0.source == "user_adjusted_nap" })
        XCTAssertNil(survivedNap.dayPrimaryChoice)

        // 5. The physiological anchor recomputes from the remaining main.
        let now = date(12, 18)
        let boundaries = AtriaPhysiologicalCycle.boundaryEligibleMainSleeps(
            now: now, confirmedSleeps: normalized, calendar: Self.utcCalendar)
        XCTAssertEqual(boundaries.map(\.id), [survivedLong.id],
                       "only the long main anchors; the nap never does")
        XCTAssertEqual(AtriaPhysiologicalCycle.current(
            now: now, confirmedSleeps: normalized, calendar: Self.utcCalendar).start,
            long.end,
            "the current physiological day starts at the long sleep's wake")

        // 6. The snapshot agrees: the long sleep is the canonical main, the nap
        //    is a nap exactly once, and the ring source is the long sleep.
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: normalized,
                                            calendar: Self.utcCalendar)
        XCTAssertEqual(snapshot.latestMainSleep?.id, survivedLong.id)
        XCTAssertEqual(snapshot.napNights.filter { $0.id == survivedNap.id }.count, 1)
        XCTAssertFalse(snapshot.nights.contains { $0.id == survivedNap.id },
                       "the nap must not occupy a canonical main slot")

        // 7. Daily metrics: the wake day's recovery/sleep authority is the long
        //    main; the nap contributes nothing to the main-sleep duration.
        let metrics = SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: snapshot,
            baseline: PersonalBaseline(),
            calendar: Self.utcCalendar)
        let wakeDay = Self.utcCalendar.startOfDay(for: long.end)
        let metric = try XCTUnwrap(metrics.first { $0.day == wakeDay })
        XCTAssertEqual(metric.sleepStart, long.start)
        XCTAssertEqual(metric.sleepEnd, long.end)
        XCTAssertEqual(try XCTUnwrap(metric.sleepDuration), long.duration, accuracy: 0.5,
                       "the nap must not inflate or replace the main-sleep total")

        // 8. No re-prompt: one main on the day means no pending choice.
        XCTAssertNil(SessionStore.pendingSameDayMainSleepChoice(
            confirmedSleeps: normalized, calendar: Self.utcCalendar))
    }

    // Normalization boundaries: a still-colliding day keeps its answer; flags
    // on non-mains always clear.
    func testDayPrimaryNormalizationKeepsValidAnswersAndClearsInvalidOnes() throws {
        let early = sleep(id: "early", start: date(10, 23), end: date(11, 3))
            .replacingDayPrimaryChoice(true)
        let late = sleep(id: "late", start: date(11, 6), end: date(11, 14))
            .replacingDayPrimaryChoice(false)
        let kept = try XCTUnwrap(SessionStore.normalizingDayPrimaryChoices(
            in: [early, late], calendar: Self.utcCalendar, shouldContinue: { true }))
        XCTAssertEqual(kept.first { $0.id == "early" }?.dayPrimaryChoice, true,
                       "a live collision keeps its recorded answer")
        XCTAssertEqual(kept.first { $0.id == "late" }?.dayPrimaryChoice, false)

        let strayNap = sleep(id: "stray", start: date(12, 13), end: date(12, 14, 30),
                             source: "user_adjusted_nap")
            .replacingDayPrimaryChoice(false)
        let cleaned = try XCTUnwrap(SessionStore.normalizingDayPrimaryChoices(
            in: [strayNap], calendar: Self.utcCalendar, shouldContinue: { true }))
        XCTAssertNil(cleaned.first?.dayPrimaryChoice,
                     "a nap can never carry a day-primary answer")
    }

    // A type-only edit is recognized as a window-unchanged save so it can take
    // the clone path instead of the sensor-coverage editor.
    func testWindowUnchangedRecognizesTypeOnlyEdits() {
        let record = sleep(id: "rec", start: date(12, 0, 58), end: date(12, 3, 41))
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [record],
                                            calendar: Self.utcCalendar)
        guard let night = snapshot.latestMainSleep else { return XCTFail("night missing") }
        XCTAssertTrue(SessionStore.sleepReviewWindowIsUnchanged(
            night: night, start: record.start, end: record.end))
        // The combined predicate still reports "changed" for a nap flip, which
        // routes into the reclassify path rather than the idempotent return.
        XCTAssertFalse(SessionStore.sleepReviewSaveIsUnchanged(
            night: night, start: record.start, end: record.end, isNap: true))
        XCTAssertFalse(SessionStore.sleepReviewWindowIsUnchanged(
            night: night, start: record.start.addingTimeInterval(120), end: record.end))
    }

    // Strict record atomicity (2026-08-12 user decision): a user save whose
    // window intersects a DIFFERENT saved record is rejected; the record being
    // edited never blocks itself, and touching windows (end == start) are fine.
    func testOverlapGuardRejectsIntersectingWindowsOnly() {
        let existing = sleep(id: "existing", start: date(12, 0, 58), end: date(12, 3, 41))
        // Intersecting: rejected.
        XCTAssertNotNil(SessionStore.firstOverlappingConfirmedSleep(
            in: [existing], start: date(12, 1, 1), end: date(12, 3, 17)))
        XCTAssertNotNil(SessionStore.firstOverlappingConfirmedSleep(
            in: [existing], start: date(12, 3, 0), end: date(12, 6, 0)))
        // Editing the same record: its own id is excluded, so it never blocks.
        XCTAssertNil(SessionStore.firstOverlappingConfirmedSleep(
            in: [existing], start: date(12, 1, 0), end: date(12, 3, 0),
            excludingIDs: [existing.id]))
        // Adjacent (touching) windows do not overlap.
        XCTAssertNil(SessionStore.firstOverlappingConfirmedSleep(
            in: [existing], start: date(12, 3, 41), end: date(12, 5, 0)))
        XCTAssertNil(SessionStore.firstOverlappingConfirmedSleep(
            in: [existing], start: date(11, 20, 0), end: date(12, 0, 58)))
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
