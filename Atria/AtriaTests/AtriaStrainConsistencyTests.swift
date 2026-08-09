import XCTest
@testable import Atria

/// Strain-trend consistency (2026-07-08 audit): a day's strain is
/// score(SUM of session TRIMPs), NOT the average of per-session scores. Since
/// score() saturates, averaging per-session scores under-reports ~2x — the
/// trend chart used to disagree with every other strain surface.
final class AtriaStrainConsistencyTests: XCTestCase {
    private func workout(start: Date,
                         bpm: Int,
                         minutes: Int,
                         biologicalSex: AthleteProfile.BiologicalSex? = nil) -> SavedSession {
        let pts = stride(from: 0, through: minutes * 60, by: 10).map { SavedSession.Point(t: Double($0), bpm: bpm) }
        return SavedSession(id: UUID(), start: start, end: start.addingTimeInterval(Double(minutes * 60)),
                            label: "Workout", points: pts, respiratoryRate: nil, rrPoints: [],
                            sleepWakeResearchState: nil,
                            biologicalSex: biologicalSex)
    }

    func testDailyMetricPersistenceCannotBeStarvedByRapidArchiveRefreshes() {
        XCTAssertTrue(SessionStore.shouldKeepPendingDailyMetricPersist(
            pendingIsCancelled: false,
            requestedDelay: 0.35
        ))
        XCTAssertFalse(SessionStore.shouldKeepPendingDailyMetricPersist(
            pendingIsCancelled: true,
            requestedDelay: 0.35
        ))
        XCTAssertFalse(SessionStore.shouldKeepPendingDailyMetricPersist(
            pendingIsCancelled: false,
            requestedDelay: 0
        ))

        XCTAssertTrue(SessionStore.dailyMetricPersistNeedsCatchUp(
            completedRevision: 41,
            currentRevision: 42,
            writeSucceeded: true
        ))
        XCTAssertFalse(SessionStore.dailyMetricPersistNeedsCatchUp(
            completedRevision: 42,
            currentRevision: 42,
            writeSucceeded: true
        ))
        XCTAssertFalse(SessionStore.dailyMetricPersistNeedsCatchUp(
            completedRevision: 41,
            currentRevision: 42,
            writeSucceeded: false
        ))
    }

    func testQuietAllDayWearDoesNotBecomeTrainingLoad() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let quiet = workout(start: start, bpm: 84, minutes: 12 * 60)
        let aggregate = SessionStore.homeSavedAggregate(
            from: [quiet],
            rest: 56,
            maxHR: 190,
            biologicalSex: .male,
            now: start.addingTimeInterval(12 * 60 * 60),
            cycleStart: start
        )

        XCTAssertEqual(aggregate.savedTodayTRIMP, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(
            quiet.trimp(rest: 56, max: 190),
            100,
            "workout-window TRIMP must remain unchanged"
        )
        let historicalStrains = SessionStore.perDayStrains(
            [quiet],
            rest: 56,
            maxHR: 190
        )
        XCTAssertFalse(historicalStrains.isEmpty)
        XCTAssertTrue(
            historicalStrains.allSatisfy { $0 == 0 },
            "historical strain must share Today's quiet-wear exclusion"
        )
        XCTAssertEqual(
            AtriaAnalytics.TrainingLoad.summary(
                sessions: [quiet],
                rest: 56,
                maxHR: 190
            ).acuteLoad,
            0,
            "fitness-age training load must not count ordinary all-day wear"
        )
        XCTAssertEqual(
            SessionStore.makeOverviewTrendPoints(
                sessions: [quiet],
                rest: 56,
                maxHR: 190,
                now: start.addingTimeInterval(12 * 60 * 60)
            ).first?.strain,
            0,
            "D/W/M Overview strain must match the daily-load authority"
        )
    }

    func testDailyLoadRetainsMeasuredExerciseAboveRestZone() {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let exercise = workout(start: start, bpm: 130, minutes: 60)
        let interval = DateInterval(
            start: start,
            end: start.addingTimeInterval(60 * 60)
        )

        XCTAssertEqual(
            exercise.dailyLoadTRIMP(rest: 56, max: 190, within: interval),
            exercise.trimp(rest: 56, max: 190, within: interval),
            accuracy: 0.000_001
        )
    }

    func testPerDayStrainSumsWithinDayAndBeatsPerSessionAverage() {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(10 * 3600)
        let s1 = workout(start: day, bpm: 150, minutes: 25)
        let s2 = workout(start: day.addingTimeInterval(3600), bpm: 150, minutes: 25)
        let strains = SessionStore.perDayStrains([s1, s2], rest: 60, maxHR: 190)
        XCTAssertEqual(strains.count, 1, "two same-day sessions collapse to one day strain")
        let t1 = s1.trimp(rest: 60, max: 190), t2 = s2.trimp(rest: 60, max: 190)
        XCTAssertGreaterThan(t1, 0)
        XCTAssertEqual(strains[0], Metrics.strain(fromTRIMP: t1 + t2), accuracy: 0.01)
        let perSessionAverage = (Metrics.strain(fromTRIMP: t1) + Metrics.strain(fromTRIMP: t2)) / 2
        XCTAssertGreaterThan(strains[0], perSessionAverage + 0.5,
                             "day-summed strain must exceed per-session average (the ~2x under-report)")
    }

    func testPerDayStrainSeparatesDifferentDays() {
        let day1 = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(10 * 3600)
        let day2 = day1.addingTimeInterval(48 * 3600)
        let strains = SessionStore.perDayStrains([workout(start: day1, bpm: 150, minutes: 25),
                                                  workout(start: day2, bpm: 150, minutes: 25)],
                                                 rest: 60, maxHR: 190)
        XCTAssertEqual(strains.count, 2)
    }

    func testPerDayStrainSlicesCrossMidnightSessionIntoBothCivilDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
        let start = day.addingTimeInterval(23 * 3_600 + 50 * 60)
        let session = workout(start: start, bpm: 150, minutes: 20)

        let strains = SessionStore.perDayStrains([session],
                                                 rest: 60,
                                                 maxHR: 190,
                                                 calendar: calendar)

        XCTAssertEqual(strains.count, 2)
        XCTAssertTrue(strains.allSatisfy { $0 > 0 })
        XCTAssertEqual(strains[0], strains[1], accuracy: 0.000_001)
    }

    func testArchiveOnlyHeartRateContributesToDailyStrain() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12))!
        let archive = stride(from: 0, through: 20 * 60, by: 10).map {
            HistoricalArchive.HeartRatePoint(t: day.addingTimeInterval(8 * 3600 + Double($0)), bpm: 150)
        }

        let aggregate = SessionStore.homeSavedAggregate(from: [],
                                                         archiveHeartRatePoints: archive,
                                                         rest: 60,
                                                         maxHR: 190,
                                                         biologicalSex: .unspecified,
                                                         calendar: calendar,
                                                         now: day.addingTimeInterval(12 * 3600))
        let expected = Metrics.trimp(archive.map { ($0.t.timeIntervalSince(archive[0].t), $0.bpm) },
                                     rest: 60,
                                     max: 190)
        XCTAssertEqual(aggregate.savedTodayTRIMP, expected, accuracy: 0.000_001)
        XCTAssertGreaterThan(aggregate.savedTodayTRIMP, 0)
        XCTAssertTrue(aggregate.hasSavedToday, "validated archive HR is durable day-load evidence")
    }

    func testArchiveOnlyLoadMatchesHomeAndHistoryRollup() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
        let archive = stride(from: 0, through: 20 * 60, by: 10).map {
            HistoricalArchive.HeartRatePoint(t: day.addingTimeInterval(8 * 3_600 + Double($0)), bpm: 150)
        }
        let home = SessionStore.homeSavedAggregate(from: [],
                                                   archiveHeartRatePoints: archive,
                                                   rest: 60,
                                                   maxHR: 190,
                                                   biologicalSex: .male,
                                                   calendar: calendar,
                                                   now: day.addingTimeInterval(12 * 3_600))
        let rollup = try XCTUnwrap(SessionStore.makeHistoryDailyRollups(
            sessions: [],
            detections: [],
            confirmedWorkouts: [],
            archiveHeartRatePoints: archive,
            biologicalSex: .male,
            rest: 60,
            maxHR: 190,
            calendar: calendar
        ).first)

        XCTAssertEqual(rollup.strain,
                       Metrics.strain(fromTRIMP: home.savedTodayTRIMP),
                       accuracy: 0.000_001)
    }

    func testArchiveOverlapDoesNotDoubleCountSavedSession() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12))!
        let start = day.addingTimeInterval(8 * 3600)
        let saved = workout(start: start, bpm: 150, minutes: 20)
        let archive = stride(from: 0, through: 20 * 60, by: 1).map {
            HistoricalArchive.HeartRatePoint(t: start.addingTimeInterval(Double($0)), bpm: 150)
        }

        let aggregate = SessionStore.homeSavedAggregate(from: [saved],
                                                         archiveHeartRatePoints: archive,
                                                         rest: 60,
                                                         maxHR: 190,
                                                         biologicalSex: .unspecified,
                                                         calendar: calendar,
                                                         now: day.addingTimeInterval(12 * 3600))
        XCTAssertEqual(aggregate.savedTodayTRIMP,
                       saved.trimp(rest: 60, max: 190),
                       accuracy: 0.000_001,
                       "1 Hz archive rows beneath a 10-second saved stream must add zero load")
    }

    func testConfirmedSleepIntervalContributesNoDailyLoadOrCalories() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 12
        ))!
        let sleepStart = day.addingTimeInterval(1 * 3_600)
        let sleepEnd = sleepStart.addingTimeInterval(6 * 3_600)
        let sleepLike = workout(start: sleepStart,
                                bpm: 145,
                                minutes: 6 * 60)
        let awake = workout(start: day.addingTimeInterval(9 * 3_600),
                            bpm: 145,
                            minutes: 20)
        let profile = AthleteProfile(
            age: 30,
            measuredMaxHR: 190,
            maxHRSource: .measured,
            biologicalSex: .male,
            weightKg: 75,
            heightCm: 175,
            updated: day,
            hasCompletedOnboarding: true
        )

        let aggregate = SessionStore.homeSavedAggregate(
            from: [sleepLike, awake],
            rest: 60,
            maxHR: 190,
            biologicalSex: .male,
            profile: profile,
            calendar: calendar,
            now: day.addingTimeInterval(12 * 3_600),
            excludedLoadIntervals: [
                DateInterval(start: sleepStart, end: sleepEnd)
            ]
        )
        XCTAssertEqual(aggregate.savedTodayTRIMP,
                       awake.trimp(rest: 60, max: 190),
                       accuracy: 0.000_001)
        XCTAssertEqual(
            aggregate.savedTodayActiveCalories ?? -1,
            awake.activeCalories(rest: 60, profile: profile) ?? -2,
            accuracy: 0.000_001
        )
    }

    func testArchiveOverlapDoesNotDoubleCountHistoryRollup() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
        let start = day.addingTimeInterval(8 * 3_600)
        let saved = workout(start: start, bpm: 150, minutes: 20, biologicalSex: .male)
        let archive = stride(from: 0, through: 20 * 60, by: 1).map {
            HistoricalArchive.HeartRatePoint(t: start.addingTimeInterval(Double($0)), bpm: 150)
        }
        let rollup = try XCTUnwrap(SessionStore.makeHistoryDailyRollups(
            sessions: [saved],
            detections: [],
            confirmedWorkouts: [],
            archiveHeartRatePoints: archive,
            biologicalSex: .male,
            rest: 60,
            maxHR: 190,
            calendar: calendar
        ).first)

        XCTAssertEqual(rollup.strain,
                       Metrics.strain(fromTRIMP: saved.trimp(rest: 60, max: 190)),
                       accuracy: 0.000_001)
    }

    func testArchiveRecoversTrueGapButNotCoveredSides() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12))!
        let start = day.addingTimeInterval(8 * 3600)
        let offsets = Array(stride(from: 0, through: 5 * 60, by: 10))
            + Array(stride(from: 15 * 60, through: 20 * 60, by: 10))
        let points = offsets.map {
            SavedSession.Point(t: Double($0), bpm: 150)
        }
        let saved = SavedSession(id: UUID(), start: start,
                                 end: start.addingTimeInterval(20 * 60),
                                 label: "Interrupted", points: points,
                                 biologicalSex: .male)
        let archive = stride(from: 0, through: 20 * 60, by: 10).map {
            HistoricalArchive.HeartRatePoint(t: start.addingTimeInterval(Double($0)), bpm: 150)
        }
        let archiveOnly = SessionStore.archiveOnlyTRIMP(archive,
                                                        excludingCoverageFrom: [saved],
                                                        within: DateInterval(start: day,
                                                                             end: day.addingTimeInterval(24 * 3600)),
                                                        rest: 60,
                                                        maxHR: 190,
                                                        biologicalSex: .male)
        let gapStart = 5 * 60 + 10
        let gapOffsets = Array(stride(from: gapStart, through: 15 * 60 - 10, by: 10))
        let gapSeries: [(t: Double, bpm: Int)] = gapOffsets.map { offset in
            (t: Double(offset - gapStart), bpm: 150)
        }
        let expectedGap = Metrics.trimp(gapSeries, rest: 60, max: 190)
        XCTAssertEqual(archiveOnly, expectedGap, accuracy: 0.000_001)
        XCTAssertGreaterThan(archiveOnly, 0)
    }

    func testArchiveMidnightSampleBelongsOnlyToFollowingCivilDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12))!
        let midnight = calendar.date(byAdding: .day, value: 1, to: day)!
        let archive = [
            HistoricalArchive.HeartRatePoint(t: midnight.addingTimeInterval(-20), bpm: 150),
            HistoricalArchive.HeartRatePoint(t: midnight.addingTimeInterval(-10), bpm: 150),
            HistoricalArchive.HeartRatePoint(t: midnight, bpm: 150),
            HistoricalArchive.HeartRatePoint(t: midnight.addingTimeInterval(10), bpm: 150),
            HistoricalArchive.HeartRatePoint(t: midnight.addingTimeInterval(20), bpm: 150)
        ]

        let dayOne = SessionStore.homeSavedAggregate(from: [],
                                                       archiveHeartRatePoints: archive,
                                                       rest: 60,
                                                       maxHR: 190,
                                                       biologicalSex: .unspecified,
                                                       calendar: calendar,
                                                       now: midnight,
                                                       cycleStart: day)
        let followingMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
        let dayTwo = SessionStore.homeSavedAggregate(from: [],
                                                       archiveHeartRatePoints: archive,
                                                       rest: 60,
                                                       maxHR: 190,
                                                       biologicalSex: .unspecified,
                                                       calendar: calendar,
                                                       now: followingMidnight,
                                                       cycleStart: midnight)
        let tenSeconds = Metrics.trimp([(t: 0, bpm: 150), (t: 10, bpm: 150)],
                                       rest: 60,
                                       max: 190)
        let twentySeconds = Metrics.trimp([(t: 0, bpm: 150),
                                           (t: 10, bpm: 150),
                                           (t: 20, bpm: 150)],
                                          rest: 60,
                                          max: 190)
        XCTAssertEqual(dayOne.savedTodayTRIMP, tenSeconds, accuracy: 0.000_001)
        XCTAssertEqual(dayTwo.savedTodayTRIMP, twentySeconds, accuracy: 0.000_001)
    }

    func testCrossMidnightSessionSplitsLoadAndStepsAndHomeMatchesRollups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12))!
        let midnight = calendar.date(byAdding: .day, value: 1, to: dayOne)!
        let start = midnight.addingTimeInterval(-10 * 60)
        let end = midnight.addingTimeInterval(20 * 60)
        let points = stride(from: 0.0, through: 30 * 60.0, by: 10).map {
            SavedSession.Point(t: $0, bpm: 150)
        }
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: end,
                                   label: "Cross-midnight workout",
                                   points: points,
                                   strapStepResearchCount: 300,
                                   biologicalSex: .male,
                                   eventTimeZoneIdentifier: "UTC")

        let dayOneHome = SessionStore.homeSavedAggregate(from: [session],
                                                          rest: 60,
                                                          maxHR: 190,
                                                          biologicalSex: .male,
                                                          calendar: calendar,
                                                          now: midnight,
                                                          cycleStart: dayOne)
        let followingMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
        let dayTwoHome = SessionStore.homeSavedAggregate(from: [session],
                                                          rest: 60,
                                                          maxHR: 190,
                                                          biologicalSex: .male,
                                                          calendar: calendar,
                                                          now: followingMidnight,
                                                          cycleStart: midnight)
        let rollups = SessionStore.makeHistoryDailyRollups(sessions: [session],
                                                            detections: [],
                                                            confirmedWorkouts: [],
                                                            rest: 60,
                                                            maxHR: 190,
                                                            calendar: calendar)
        let dayOneRollup = rollups.first { calendar.isDate($0.day, inSameDayAs: dayOne) }
        let dayTwoRollup = rollups.first { calendar.isDate($0.day, inSameDayAs: midnight) }

        XCTAssertEqual(dayOneHome.savedTodayStrapSteps, 100)
        XCTAssertEqual(dayTwoHome.savedTodayStrapSteps, 200)
        XCTAssertEqual(dayOneHome.savedTodayStrapSteps + dayTwoHome.savedTodayStrapSteps, 300)
        XCTAssertEqual(dayOneRollup?.duration ?? -1, 10 * 60, accuracy: 0.001)
        XCTAssertEqual(dayTwoRollup?.duration ?? -1, 20 * 60, accuracy: 0.001)
        XCTAssertEqual(dayOneRollup?.strain ?? -1,
                       Metrics.strain(fromTRIMP: dayOneHome.savedTodayTRIMP),
                       accuracy: 0.000_001)
        XCTAssertEqual(dayTwoRollup?.strain ?? -1,
                       Metrics.strain(fromTRIMP: dayTwoHome.savedTodayTRIMP),
                       accuracy: 0.000_001)
        XCTAssertGreaterThan(dayOneHome.savedTodayTRIMP, 0)
        XCTAssertGreaterThan(dayTwoHome.savedTodayTRIMP, dayOneHome.savedTodayTRIMP)
    }

    func testSavedSessionTRIMPPersistsAndUsesCapturedBiologicalSex() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let female = workout(start: start, bpm: 160, minutes: 30, biologicalSex: .female)
        let male = workout(start: start, bpm: 160, minutes: 30, biologicalSex: .male)
        let legacy = workout(start: start, bpm: 160, minutes: 30)

        XCTAssertGreaterThan(female.trimp(rest: 60, max: 190), male.trimp(rest: 60, max: 190))
        XCTAssertEqual(legacy.trimp(rest: 60, max: 190),
                       male.trimp(rest: 60, max: 190),
                       accuracy: 0.000_001)

        let decoded = try JSONDecoder().decode(SavedSession.self,
                                                from: JSONEncoder().encode(female))
        XCTAssertEqual(decoded.biologicalSex, .female)
        XCTAssertEqual(decoded.trimp(rest: 60, max: 190),
                       female.trimp(rest: 60, max: 190),
                       accuracy: 0.000_001)
    }

    func testIdenticalHeartRateUsesIdenticalSexParametersAcrossSavedConfirmedAndArchivePaths() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = stride(from: 0, through: 30 * 60, by: 10).map {
            SavedSession.Point(t: Double($0), bpm: 160)
        }
        let archive = points.map {
            HistoricalArchive.HeartRatePoint(t: start.addingTimeInterval($0.t), bpm: $0.bpm)
        }
        let samples = points.map {
            HRSample(t: start.addingTimeInterval($0.t), bpm: $0.bpm)
        }
        let interval = DateInterval(start: start, end: start.addingTimeInterval(30 * 60 + 1))

        for sex in [AthleteProfile.BiologicalSex.female, .male] {
            let saved = SavedSession(id: UUID(),
                                     start: start,
                                     end: start.addingTimeInterval(30 * 60),
                                     label: "Equivalent evidence",
                                     points: points,
                                     biologicalSex: sex)
            let savedTRIMP = saved.trimp(rest: 60, max: 190)
            let confirmedTRIMP = SessionStore.confirmedWorkoutTRIMP(
                segments: [samples],
                start: start,
                rest: 60,
                maxHR: 190,
                biologicalSex: sex
            )
            let archiveTRIMP = SessionStore.archiveOnlyTRIMP(
                archive,
                excludingCoverageFrom: [],
                within: interval,
                rest: 60,
                maxHR: 190,
                biologicalSex: sex
            )

            XCTAssertEqual(confirmedTRIMP, savedTRIMP, accuracy: 0.000_001)
            XCTAssertEqual(archiveTRIMP, savedTRIMP, accuracy: 0.000_001)
        }

        let female = SessionStore.archiveOnlyTRIMP(archive,
                                                   excludingCoverageFrom: [],
                                                   within: interval,
                                                   rest: 60,
                                                   maxHR: 190,
                                                   biologicalSex: .female)
        let male = SessionStore.archiveOnlyTRIMP(archive,
                                                 excludingCoverageFrom: [],
                                                 within: interval,
                                                 rest: 60,
                                                 maxHR: 190,
                                                 biologicalSex: .male)
        XCTAssertGreaterThan(female, male)
    }

    @MainActor
    func testIncrementalLiveTRIMPInvalidatesCacheWhenBiologicalSexChanges() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = stride(from: 0, through: 30 * 60, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 160)
        }
        let female = WidgetSnapshotPublisher.incrementalLiveTRIMP(samples: samples,
                                                                   rest: 60,
                                                                   max: 190,
                                                                   sex: .female)
        let male = WidgetSnapshotPublisher.incrementalLiveTRIMP(samples: samples,
                                                                 rest: 60,
                                                                 max: 190,
                                                                 sex: .male)
        XCTAssertGreaterThan(female, male)
        XCTAssertEqual(male,
                       Metrics.trimp(samples.map { ($0.t.timeIntervalSince(start), $0.bpm) },
                                     rest: 60,
                                     max: 190,
                                     sex: .male),
                       accuracy: 0.000_001)
    }
    // Recovery honesty (2026-07-08 audit): unknown in-bed span must NOT read as
    // 100% efficiency — return nil so recovery skips the sleep signal.
    func testSleepEfficiencyNilWhenSpanUnknown() {
        XCTAssertNil(SessionStore.sleepEfficiency(duration: 7 * 3600, span: nil))
        XCTAssertNil(SessionStore.sleepEfficiency(duration: nil, span: 8 * 3600))
    }

    func testSleepEfficiencyComputesWhenSpanKnown() {
        let e = SessionStore.sleepEfficiency(duration: 7 * 3600, span: 8 * 3600)
        XCTAssertEqual(e ?? 0, 0.875, accuracy: 0.001)
        // span shorter than duration clamps to <= 1 (never > 100%).
        XCTAssertEqual(SessionStore.sleepEfficiency(duration: 8 * 3600, span: 7 * 3600) ?? 0, 1.0, accuracy: 0.001)
    }

    @MainActor
    func testIncrementalLiveStrainMatchesCanonicalGapEvidenceRule() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            HRSample(t: start, bpm: 100),
            HRSample(t: start.addingTimeInterval(15), bpm: 160),
            // 16 seconds is deliberately beyond the evidence boundary and
            // must not be back-filled with the later heart rate.
            HRSample(t: start.addingTimeInterval(31), bpm: 160),
        ]
        let incremental = WidgetSnapshotPublisher.incrementalLiveTRIMP(samples: samples,
                                                                       rest: 60,
                                                                       max: 190)
        let canonical = Metrics.trimp(samples.map { (t: $0.t.timeIntervalSince(start), bpm: $0.bpm) },
                                      rest: 60,
                                      max: 190)

        XCTAssertEqual(incremental, canonical, accuracy: 0.000_001)
        XCTAssertGreaterThan(incremental, 0)
    }

    func testLiveWorkoutAccumulatorMatchesFinalPauseAwareTRIMP() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = stride(from: 0, through: 20 * 60, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 155)
        }
        let pause = ExcludedInterval(start: start.addingTimeInterval(7 * 60),
                                     end: start.addingTimeInterval(10 * 60))
        var accumulator = AtriaLiveWorkoutTRIMPAccumulator()
        _ = accumulator.trimp(samples: Array(samples.prefix(50)),
                              startedAt: start,
                              rest: 60,
                              maxHR: 190,
                              sex: .male,
                              excludedIntervals: [])
        let live = accumulator.trimp(samples: samples,
                                     startedAt: start,
                                     rest: 60,
                                     maxHR: 190,
                                     sex: .male,
                                     excludedIntervals: [pause])
        let expected = AtriaAnalytics.Strain.contiguousSegments(samples,
                                                                 excluding: [pause])
            .reduce(0) { total, segment in
                guard let origin = segment.first?.t else { return total }
                return total + Metrics.trimp(segment.map {
                    ($0.t.timeIntervalSince(origin), $0.bpm)
                }, rest: 60, max: 190, sex: .male)
            }

        XCTAssertEqual(live, expected, accuracy: 0.000_001)
        XCTAssertEqual(Metrics.strain(fromTRIMP: live),
                       Metrics.strain(fromTRIMP: expected),
                       accuracy: 0.000_001)
    }

    func testLiveWorkoutMetricsUseSamePauseAwareWindowForStrainAndCalories() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = stride(from: 0, through: 20 * 60, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 155)
        }
        let pause = ExcludedInterval(start: start.addingTimeInterval(7 * 60),
                                     end: start.addingTimeInterval(10 * 60))
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     weightKg: 75,
                                     heightCm: 178,
                                     updated: nil,
                                     hasCompletedOnboarding: true)
        let segments = AtriaAnalytics.Strain.contiguousSegments(samples, excluding: [pause])
        let expectedTRIMP = segments.reduce(0) { total, segment in
            guard let origin = segment.first?.t else { return total }
            return total + Metrics.trimp(segment.map {
                ($0.t.timeIntervalSince(origin), $0.bpm)
            }, rest: 60, max: 190, sex: .male)
        }
        let expectedCalories = segments.reduce(0.0) { total, segment in
            total + (Metrics.dayCalories(segment.map {
                Metrics.HeartRateEnergySample(t: $0.t, bpm: $0.bpm)
            }, rest: 60, profile: profile) ?? 0)
        }

        var accumulator = AtriaLiveWorkoutTRIMPAccumulator()
        _ = accumulator.metrics(samples: Array(samples.prefix(50)),
                                startedAt: start,
                                rest: 60,
                                maxHR: 190,
                                profile: profile,
                                excludedIntervals: [])
        let live = accumulator.metrics(samples: samples,
                                       startedAt: start,
                                       rest: 60,
                                       maxHR: 190,
                                       profile: profile,
                                       excludedIntervals: [pause])

        XCTAssertEqual(live.trimp, expectedTRIMP, accuracy: 0.000_001)
        XCTAssertEqual(live.activeCalories ?? -1, expectedCalories, accuracy: 0.000_001)
    }

    func testLiveWorkoutMetricsRemainMonotonicAcrossStrictlyForwardSessionRoll() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     weightKg: 75,
                                     heightCm: 178,
                                     updated: nil,
                                     hasCompletedOnboarding: true)
        let firstSegment = stride(from: 0, through: 30, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 150)
        }
        let secondSegment = stride(from: 40, through: 70, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 155)
        }
        var accumulator = AtriaLiveWorkoutTRIMPAccumulator()
        let first = accumulator.metrics(samples: firstSegment,
                                        startedAt: start,
                                        rest: 60,
                                        maxHR: 190,
                                        profile: profile,
                                        excludedIntervals: [])
        let rolled = accumulator.metrics(samples: secondSegment,
                                         startedAt: start,
                                         rest: 60,
                                         maxHR: 190,
                                         profile: profile,
                                         excludedIntervals: [])
        let expectedTRIMP = [firstSegment, secondSegment].reduce(0.0) { total, segment in
            guard let origin = segment.first?.t else { return total }
            return total + Metrics.trimp(segment.map {
                ($0.t.timeIntervalSince(origin), $0.bpm)
            }, rest: 60, max: 190, sex: .male)
        }
        let expectedCalories = [firstSegment, secondSegment].reduce(0.0) { total, segment in
            total + (Metrics.dayCalories(segment.map {
                Metrics.HeartRateEnergySample(t: $0.t, bpm: $0.bpm)
            }, rest: 60, profile: profile) ?? 0)
        }

        XCTAssertGreaterThanOrEqual(rolled.trimp, first.trimp)
        XCTAssertGreaterThanOrEqual(rolled.activeCalories ?? -1,
                                    first.activeCalories ?? 0)
        XCTAssertEqual(rolled.trimp, expectedTRIMP, accuracy: 0.000_001)
        XCTAssertEqual(rolled.activeCalories ?? -1, expectedCalories, accuracy: 0.000_001)
    }

    func testLiveWorkoutMetricsDeduplicateOverlappingForwardSessionRoll() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     weightKg: 75,
                                     heightCm: 178,
                                     updated: nil,
                                     hasCompletedOnboarding: true)
        let firstSegment = stride(from: 0, through: 30, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 150)
        }
        let replacement = stride(from: 20, through: 50, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 150)
        }
        let canonical = stride(from: 0, through: 50, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 150)
        }
        var accumulator = AtriaLiveWorkoutTRIMPAccumulator()
        _ = accumulator.metrics(samples: firstSegment,
                                startedAt: start,
                                rest: 60,
                                maxHR: 190,
                                profile: profile,
                                excludedIntervals: [])
        let rolled = accumulator.metrics(samples: replacement,
                                         startedAt: start,
                                         rest: 60,
                                         maxHR: 190,
                                         profile: profile,
                                         excludedIntervals: [])
        let expectedTRIMP = Metrics.trimp(canonical.map {
            ($0.t.timeIntervalSince(start), $0.bpm)
        }, rest: 60, max: 190, sex: .male)
        let expectedCalories = Metrics.dayCalories(canonical.map {
            Metrics.HeartRateEnergySample(t: $0.t, bpm: $0.bpm)
        }, rest: 60, profile: profile)

        XCTAssertEqual(rolled.trimp, expectedTRIMP, accuracy: 0.000_001)
        XCTAssertEqual(rolled.activeCalories ?? -1, expectedCalories ?? -2, accuracy: 0.000_001)
    }

    func testRolledWorkoutPrefixSurvivesPauseResumeAndProfileChangeWithoutDoubleCount() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let originalProfile = AthleteProfile(age: 30,
                                             measuredMaxHR: 190,
                                             maxHRSource: .measured,
                                             biologicalSex: .male,
                                             weightKg: 75,
                                             heightCm: 178,
                                             updated: nil,
                                             hasCompletedOnboarding: true)
        let updatedProfile = AthleteProfile(age: 30,
                                            measuredMaxHR: 190,
                                            maxHRSource: .measured,
                                            biologicalSex: .female,
                                            weightKg: 80,
                                            heightCm: 178,
                                            updated: start.addingTimeInterval(120),
                                            hasCompletedOnboarding: true)
        let completedSegment = stride(from: 0, through: 30, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 150)
        }
        let liveSegment = stride(from: 40, through: 110, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 155)
        }
        let openPause = ExcludedInterval(start: start.addingTimeInterval(60),
                                         end: .distantFuture)
        let closedPause = ExcludedInterval(start: start.addingTimeInterval(60),
                                           end: start.addingTimeInterval(80))
        var accumulator = AtriaLiveWorkoutTRIMPAccumulator()
        let prefix = accumulator.metrics(samples: completedSegment,
                                         startedAt: start,
                                         rest: 60,
                                         maxHR: 190,
                                         profile: originalProfile,
                                         excludedIntervals: [])
        _ = accumulator.metrics(samples: liveSegment,
                                startedAt: start,
                                rest: 60,
                                maxHR: 190,
                                profile: originalProfile,
                                excludedIntervals: [])
        let paused = accumulator.metrics(samples: liveSegment,
                                         startedAt: start,
                                         rest: 60,
                                         maxHR: 190,
                                         profile: originalProfile,
                                         excludedIntervals: [openPause])
        XCTAssertGreaterThanOrEqual(paused.trimp, prefix.trimp,
                                    "opening a pause after a roll cannot erase completed load")

        let resumed = accumulator.metrics(samples: liveSegment,
                                          startedAt: start,
                                          rest: 60,
                                          maxHR: 190,
                                          profile: originalProfile,
                                          excludedIntervals: [closedPause])
        let expectedResumedTRIMP = prefix.trimp
            + AtriaAnalytics.Strain.contiguousSegments(liveSegment, excluding: [closedPause])
                .reduce(0.0) { total, segment in
                    guard let origin = segment.first?.t else { return total }
                    return total + Metrics.trimp(segment.map {
                        ($0.t.timeIntervalSince(origin), $0.bpm)
                    }, rest: 60, max: 190, sex: .male)
                }
        XCTAssertEqual(resumed.trimp, expectedResumedTRIMP, accuracy: 0.000_001)

        let reprofiled = accumulator.metrics(samples: liveSegment,
                                              startedAt: start,
                                              rest: 60,
                                              maxHR: 190,
                                              profile: updatedProfile,
                                              excludedIntervals: [closedPause])
        let activeSegments = AtriaAnalytics.Strain.contiguousSegments(
            liveSegment,
            excluding: [closedPause]
        )
        let expectedReprofiledTRIMP = prefix.trimp + activeSegments.reduce(0.0) { total, segment in
            guard let origin = segment.first?.t else { return total }
            return total + Metrics.trimp(segment.map {
                ($0.t.timeIntervalSince(origin), $0.bpm)
            }, rest: 60, max: 190, sex: .female)
        }
        let expectedCalories = (prefix.activeCalories ?? 0) + activeSegments.reduce(0.0) {
            total, segment in
            total + (Metrics.dayCalories(segment.map {
                Metrics.HeartRateEnergySample(t: $0.t, bpm: $0.bpm)
            }, rest: 60, profile: updatedProfile) ?? 0)
        }
        XCTAssertEqual(reprofiled.trimp, expectedReprofiledTRIMP, accuracy: 0.000_001)
        XCTAssertEqual(reprofiled.activeCalories ?? -1, expectedCalories, accuracy: 0.000_001)

        let repeated = accumulator.metrics(samples: liveSegment,
                                            startedAt: start,
                                            rest: 60,
                                            maxHR: 190,
                                            profile: updatedProfile,
                                            excludedIntervals: [closedPause])
        XCTAssertEqual(repeated, reprofiled,
                       "replaying an unchanged rolled segment must not add its prefix twice")
    }

    func testDelayedExclusionOverFrozenPrefixMarksLiveLoadIncomplete() {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     weightKg: 75,
                                     heightCm: 178,
                                     updated: nil,
                                     hasCompletedOnboarding: true)
        let frozenSegment = stride(from: 0, through: 30, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 150)
        }
        let replayableSegment = stride(from: 40, through: 80, by: 10).map {
            HRSample(t: start.addingTimeInterval(Double($0)), bpm: 155)
        }
        var accumulator = AtriaLiveWorkoutTRIMPAccumulator()
        _ = accumulator.metrics(samples: frozenSegment,
                                startedAt: start,
                                rest: 60,
                                maxHR: 190,
                                profile: profile,
                                excludedIntervals: [])
        let rolled = accumulator.metrics(samples: replayableSegment,
                                         startedAt: start,
                                         rest: 60,
                                         maxHR: 190,
                                         profile: profile,
                                         excludedIntervals: [])
        XCTAssertTrue(rolled.isComplete)

        let delayedPause = ExcludedInterval(start: start.addingTimeInterval(10),
                                            end: start.addingTimeInterval(20))
        let invalidated = accumulator.metrics(samples: replayableSegment,
                                              startedAt: start,
                                              rest: 60,
                                              maxHR: 190,
                                              profile: profile,
                                              excludedIntervals: [delayedPause])
        XCTAssertTrue(invalidated.hasEvidence)
        XCTAssertFalse(invalidated.isComplete,
                       "discarded HR cannot be replayed to remove a delayed pause")

        let projection = AtriaLiveWorkoutMetricProjection(
            strain: Metrics.strain(fromTRIMP: invalidated.trimp),
            activeCalories: nil,
            sensorAvailability: .live,
            sensorCapturedAt: replayableSegment.last?.t,
            hasSensorEvidence: true,
            loadIsComplete: invalidated.isComplete
        )
        XCTAssertFalse(projection.coachingIsLive)
        XCTAssertEqual(projection.strainHUDText, "--")
        XCTAssertEqual(projection.activeCaloriesHUDText, "--")
        XCTAssertEqual(projection.sensorStatusTitle, "Load incomplete")
    }

    func testWorkoutStepProjectionSharesFreshnessAcrossHUDAndLiveActivity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let live = AtriaLiveWorkoutStepProjection.make(totalCount: 180,
                                                       startingCount: 100,
                                                       hasStepEvidence: true,
                                                       isValidated: false,
                                                       capturedAt: now.addingTimeInterval(-10),
                                                       isReconnecting: false,
                                                       now: now)
        XCTAssertEqual(live.availability, .live)
        XCTAssertEqual(live.liveCount, 80)
        XCTAssertEqual(live.hudText, "~80")
        XCTAssertNotNil(live.liveCapturedAt)

        let stale = AtriaLiveWorkoutStepProjection.make(totalCount: 180,
                                                        startingCount: 100,
                                                        hasStepEvidence: true,
                                                        isValidated: true,
                                                        capturedAt: now.addingTimeInterval(-16),
                                                        isReconnecting: false,
                                                        now: now)
        XCTAssertEqual(stale.availability, .stale)
        XCTAssertNil(stale.liveCount)
        XCTAssertEqual(stale.hudText, "stale")
        XCTAssertNil(stale.liveCapturedAt)

        let reconnecting = AtriaLiveWorkoutStepProjection.make(totalCount: 180,
                                                               startingCount: 100,
                                                               hasStepEvidence: true,
                                                               isValidated: true,
                                                               capturedAt: now.addingTimeInterval(-16),
                                                               isReconnecting: true,
                                                               now: now)
        XCTAssertEqual(reconnecting.availability, .reconnecting)
        XCTAssertNil(reconnecting.liveCount)
        // 2026-07-17: copy aligned with the Live Activity ("Syncing") and made
        // truncation-proof at XXXL type. Still fails closed to a qualifier —
        // never a frozen count rendered as live.
        XCTAssertEqual(reconnecting.hudText, "syncing")
    }

    func testWorkoutStepProjectionFreezesDuringPauseAndExcludesPausedStepsAfterResume() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let whilePaused = AtriaLiveWorkoutStepProjection.make(
            totalCount: 175,
            startingCount: 100,
            pausedCount: 20,
            pauseStartedCount: 150,
            hasStepEvidence: true,
            isValidated: true,
            capturedAt: now,
            isReconnecting: false,
            now: now
        )
        XCTAssertEqual(whilePaused.count, 30,
                       "Steps after the pause anchor must not enter workout steps")

        let afterResume = AtriaLiveWorkoutStepProjection.make(
            totalCount: 190,
            startingCount: 100,
            pausedCount: 45,
            hasStepEvidence: true,
            isValidated: true,
            capturedAt: now,
            isReconnecting: false,
            now: now
        )
        XCTAssertEqual(afterResume.count, 45,
                       "Completed paused steps remain excluded after workout steps resume")
    }

    func testWorkoutMotionProjectionUsesRawFrameFreshnessWithoutInventingSteps() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let live = AtriaLiveWorkoutMotionProjection.make(
            capturedAt: now.addingTimeInterval(-3),
            isReconnecting: false,
            now: now
        )
        XCTAssertEqual(live.availability, .live)
        XCTAssertEqual(live.compactLabel, "Motion live")
        XCTAssertEqual(live.ageSeconds, 3)

        let qualifying = AtriaLiveWorkoutMotionProjection.make(
            capturedAt: now.addingTimeInterval(-3),
            hasContinuousValidatedMotion: false,
            isReconnecting: false,
            now: now
        )
        XCTAssertEqual(qualifying.availability, .unavailable)
        XCTAssertEqual(qualifying.compactLabel, "Motion qualifying")

        let gap = AtriaLiveWorkoutMotionProjection.make(
            capturedAt: now.addingTimeInterval(-19),
            isReconnecting: false,
            now: now
        )
        XCTAssertEqual(gap.availability, .stale)
        XCTAssertEqual(gap.compactLabel, "Motion gap · 19s")

        let syncing = AtriaLiveWorkoutMotionProjection.make(
            capturedAt: now.addingTimeInterval(-19),
            isReconnecting: true,
            now: now
        )
        XCTAssertEqual(syncing.availability, .reconnecting)
        XCTAssertEqual(syncing.compactLabel, "Motion syncing")

        let pending = AtriaLiveWorkoutMotionProjection.make(
            capturedAt: nil,
            isReconnecting: false,
            now: now
        )
        XCTAssertEqual(pending.availability, .unavailable)
        XCTAssertEqual(pending.compactLabel, "Motion pending")
    }

    func testWorkoutMovingDurationMatchesClosedAndOpenPauseProjection() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let now = start.addingTimeInterval(30 * 60)
        let closedPause = ExcludedInterval(start: start.addingTimeInterval(5 * 60),
                                           end: start.addingTimeInterval(8 * 60))
        let openPause = start.addingTimeInterval(25 * 60)

        XCTAssertEqual(AtriaWorkoutMovingDuration.project(
            startedAt: start,
            excludedIntervals: [closedPause],
            pauseStartedAt: openPause,
            now: now
        ), 22 * 60, accuracy: 0.001)
    }

    func testWorkoutLoadNeedsAContinuousHeartRateIntervalBeforePublishingMetrics() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     weightKg: 75,
                                     heightCm: 178,
                                     updated: nil,
                                     hasCompletedOnboarding: true)
        var accumulator = AtriaLiveWorkoutTRIMPAccumulator()

        let loneSample = accumulator.metrics(
            samples: [HRSample(t: start, bpm: 145)],
            startedAt: start,
            rest: 60,
            maxHR: 190,
            profile: profile,
            excludedIntervals: []
        )
        XCTAssertFalse(loneSample.hasEvidence)

        let brokenPair = accumulator.metrics(
            samples: [
                HRSample(t: start, bpm: 145),
                HRSample(t: start.addingTimeInterval(
                    AtriaAnalytics.Strain.maximumLoadEvidenceGap + 1
                ), bpm: 150),
            ],
            startedAt: start,
            rest: 60,
            maxHR: 190,
            profile: profile,
            excludedIntervals: []
        )
        XCTAssertFalse(brokenPair.hasEvidence,
                       "A transport hole must not become load evidence")

        let continuousPair = accumulator.metrics(
            samples: [
                HRSample(t: start, bpm: 145),
                HRSample(t: start.addingTimeInterval(10), bpm: 150),
            ],
            startedAt: start,
            rest: 60,
            maxHR: 190,
            profile: profile,
            excludedIntervals: []
        )
        XCTAssertTrue(continuousPair.hasEvidence)
    }

    func testWorkoutProjectionLabelsFrozenTotalsAndSuspendsCoaching() {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let live = AtriaLiveWorkoutMetricProjection(
            strain: 4.2,
            activeCalories: 121,
            sensorAvailability: .live,
            sensorCapturedAt: capturedAt,
            hasSensorEvidence: true
        )
        XCTAssertTrue(live.coachingIsLive)
        XCTAssertEqual(live.strainHUDTitle, "Strain")
        XCTAssertEqual(live.activeCaloriesHUDText, "≈ 121 kcal")
        XCTAssertNil(live.sensorStatusTitle)

        let reconnecting = AtriaLiveWorkoutMetricProjection(
            strain: 4.2,
            activeCalories: 121,
            sensorAvailability: .reconnecting,
            sensorCapturedAt: capturedAt,
            hasSensorEvidence: true
        )
        XCTAssertFalse(reconnecting.coachingIsLive)
        XCTAssertEqual(reconnecting.strainHUDTitle, "Last strain")
        XCTAssertEqual(reconnecting.activeCaloriesHUDTitle, "Last active")
        XCTAssertEqual(reconnecting.sensorStatusTitle, "Reconnecting")
        XCTAssertEqual(reconnecting.strainHUDText, "4.2")
    }

    func testWorkoutProjectionDoesNotPresentZeroAsMeasuredBeforeEvidence() {
        let waiting = AtriaLiveWorkoutMetricProjection(
            strain: 0,
            activeCalories: 0,
            sensorAvailability: .live,
            sensorCapturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            hasSensorEvidence: false
        )

        XCTAssertFalse(waiting.coachingIsLive)
        XCTAssertEqual(waiting.strainHUDText, "--")
        XCTAssertEqual(waiting.activeCaloriesHUDText, "--")
        XCTAssertEqual(waiting.sensorStatusTitle, "Waiting for strap")
    }

    func testHistorySessionTRIMPUsesPersonalRestAnchor() throws {
        let session = workout(start: Date(timeIntervalSince1970: 1_800_000_000),
                              bpm: 150,
                              minutes: 20,
                              biologicalSex: .male)
        let snapshot = HistorySnapshot(sessions: [session],
                                       detections: [],
                                       trends: [],
                                       rollups: [],
                                       rest: 60,
                                       maxHR: 190)
        let row = try XCTUnwrap(snapshot.sessionRows.first)
        let expected = String(format: "%.1f", session.trimp(rest: 60, max: 190))

        XCTAssertEqual(row.trimpText, expected)
    }
}
