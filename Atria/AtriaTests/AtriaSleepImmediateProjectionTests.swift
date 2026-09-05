import Combine
import XCTest
@testable import Atria

final class AtriaSleepImmediateProjectionTests: XCTestCase {
    private func confirmedSleep(
        start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000),
        duration: TimeInterval = 8 * 60 * 60,
        span: TimeInterval? = nil,
        source: String = "manual_sleep",
        motionSource: String = "manual",
        motionValidated: Bool = false,
        stages: [SleepStageSegment]? = nil,
        eventTimeZoneIdentifier: String = "UTC",
        restingHR: Int = 52,
        hrv: Int? = 48,
        hrvWindowCount: Int? = 4,
        respiratoryRate: Double? = 15.2,
        id: String = "sleep-fixture"
    ) -> UserConfirmedSleep {
        let factualSpan = span ?? duration
        return UserConfirmedSleep(id: id,
                           createdAt: start.addingTimeInterval(factualSpan),
                           start: start,
                           end: start.addingTimeInterval(factualSpan),
                           source: source,
                           confidence: "manual_user_entered",
                           sessions: 1,
                           samples: 1_000,
                           avgHR: 60,
                           peakHR: 90,
                           restingHR: restingHR,
                           hrv: hrv,
                           hrvWindowCount: hrvWindowCount,
                           respiratoryRate: respiratoryRate,
                           duration: duration,
                           span: factualSpan,
                           reason: "fixture",
                           motionSource: motionSource,
                           motionValidated: motionValidated,
                           stageSegments: stages,
                           eventTimeZoneIdentifier: eventTimeZoneIdentifier)
    }

    func testConfirmedMainSleepPublishesDailyMetricAndRollupWithoutSessionRollup() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 8,
            hour: 3,
            minute: 23
        )))
        let duration: TimeInterval = 6 * 60 * 60 + 31 * 60 + 41.692
        let sleepRecord = confirmedSleep(
            start: start,
            duration: duration,
            source: "user_adjusted_sleep",
            eventTimeZoneIdentifier: "Asia/Kolkata",
            restingHR: 59,
            hrv: 41,
            hrvWindowCount: 37,
            respiratoryRate: 11
        )
        let sleep = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [sleepRecord],
            calendar: calendar
        )

        let metrics = SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            calendar: calendar
        )
        let metric = try XCTUnwrap(metrics.first)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertTrue(calendar.isDate(metric.day, inSameDayAs: sleepRecord.end))
        XCTAssertEqual(metric.sleepStart, sleepRecord.start)
        XCTAssertEqual(metric.sleepEnd, sleepRecord.end)
        XCTAssertEqual(metric.sleepDuration, sleepRecord.duration)
        XCTAssertEqual(metric.hrv, sleepRecord.hrv)
        XCTAssertEqual(metric.restingHR, sleepRecord.restingHR)
        XCTAssertEqual(metric.respiratoryRate, sleepRecord.respiratoryRate)
        XCTAssertNil(metric.strain, "sleep evidence must not invent activity")
        XCTAssertNil(metric.strainCoverageFraction)
        XCTAssertNil(metric.strainEvidenceQuality)

        let rollups = SessionStore.makeDailyRollupStoreEntries(
            metrics: metrics,
            sessions: [],
            calendar: calendar
        )
        let rollup = try XCTUnwrap(rollups.first)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertTrue(calendar.isDate(rollup.day, inSameDayAs: sleepRecord.end))
        XCTAssertEqual(rollup.sleepSeconds, sleepRecord.duration)
        XCTAssertEqual(rollup.rhr, sleepRecord.restingHR)
        XCTAssertEqual(
            try XCTUnwrap(rollup.lnRMSSD),
            log(Double(try XCTUnwrap(sleepRecord.hrv))),
            accuracy: 0.000_001
        )
        XCTAssertEqual(rollup.respiratoryRate, sleepRecord.respiratoryRate)
        XCTAssertNil(rollup.strain, "the published rollup must preserve the activity gap")
    }

    func testPhysicalShortAdjustedSleepAdvancesCycleAndPublishesRecoveryWithoutHRV() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        func local(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )))
        }

        // Physical 2026-08-11 record: the explicit adjustment covered 8,102
        // sensor seconds inside valid 01:01:57-03:17:00 bounds. It had RHR but
        // no qualified RR/HRV windows, so Recovery must update honestly without
        // inventing HRV and Today must begin at this wake instead of yesterday's.
        let prior = confirmedSleep(
            start: try local(10, 3, 30),
            duration: 8 * 60 * 60 + 25 * 60,
            source: "auto_confirmed_sleep",
            eventTimeZoneIdentifier: "Asia/Kolkata",
            id: "physical-prior-main"
        )
        let start = try local(11, 1, 1, 57)
        let end = try local(11, 3, 17)
        let measuredCoverage: TimeInterval = 8_102
        XCTAssertEqual(end.timeIntervalSince(start), measuredCoverage + 1)
        let adjusted = UserConfirmedSleep(
            id: "physical-8102s-user-adjusted-sleep",
            createdAt: end.addingTimeInterval(60),
            start: start,
            end: end,
            source: "user_adjusted_sleep",
            confidence: "user_adjusted_hr_only",
            sessions: 3,
            samples: 8_102,
            avgHR: 58,
            peakHR: 72,
            restingHR: 51,
            hrv: nil,
            hrvWindowCount: 0,
            respiratoryRate: nil,
            duration: measuredCoverage,
            span: end.timeIntervalSince(start),
            reason: "physical adjusted sleep regression",
            motionSource: "user_adjusted",
            motionValidated: false,
            stageSegments: nil,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        let now = try local(11, 3, 55)
        let day = calendar.startOfDay(for: end)

        XCTAssertTrue(SessionStore.confirmedSleepIsPhysiologicalMainSleep(adjusted))
        let cycle = AtriaPhysiologicalCycle.current(
            now: now,
            confirmedSleeps: [prior, adjusted],
            calendar: calendar
        )
        XCTAssertEqual(cycle.start, end)
        XCTAssertEqual(cycle.boundaryKind, .mainSleep)
        XCTAssertEqual(cycle.anchorSleepID, adjusted.id)

        let sleep = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [prior, adjusted],
            calendar: calendar
        )
        let projected = try XCTUnwrap(sleep.nights.first { $0.id == adjusted.id })
        XCTAssertTrue(SessionStore.confirmedSleepIsPhysiologicalMainSleep(projected))
        XCTAssertNil(projected.hrv)
        XCTAssertEqual(projected.hrvWindowCount, 0)

        let bulk = try XCTUnwrap(SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            calendar: calendar
        ).first { calendar.isDate($0.day, inSameDayAs: day) })
        XCTAssertEqual(bulk.sleepStart, start)
        XCTAssertEqual(bulk.sleepEnd, end)
        XCTAssertEqual(bulk.sleepDuration, measuredCoverage)
        XCTAssertEqual(bulk.sleepSource, "user_adjusted_sleep")
        XCTAssertNil(bulk.hrv)
        XCTAssertNotNil(bulk.recoveryPercent)
        XCTAssertEqual(bulk.recoveryConfidence, "unverified")
        XCTAssertEqual(bulk.recoverySummary?.usesHRV, false)

        let frozen = try XCTUnwrap(SessionStore.makeMorningFrozenDailyMetric(
            for: day,
            computed: [],
            sessions: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: now,
            calendar: calendar
        ))
        XCTAssertEqual(frozen.sleepStart, start)
        XCTAssertEqual(frozen.sleepEnd, end)
        XCTAssertEqual(frozen.sleepDuration, measuredCoverage)
        XCTAssertEqual(frozen.sleepSource, "user_adjusted_sleep")
        XCTAssertNil(frozen.hrv)
        XCTAssertNotNil(frozen.recoveryPercent)
        XCTAssertEqual(frozen.recoveryPercent, bulk.recoveryPercent)
        XCTAssertEqual(frozen.recoveryConfidence, "unverified")
        XCTAssertEqual(frozen.recoverySummary?.usesHRV, false)
        XCTAssertNil(frozen.recoverySummary?.inputSnapshot?.hrvRMSSD)
    }

    func testStagedAdjustedSleepKeepsObservedEligibilityWhileRecoveryUsesNonAwakeTST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 8,
            hour: 1
        )))
        let observedDuration = AggregateSleepCandidate.napMinimumDuration
        let span: TimeInterval = 25 * 60
        let nonAwakeDuration: TimeInterval = 15 * 60
        let stages = [
            SleepStageSegment(
                id: "research-motion-v2-awake",
                start: start,
                end: start.addingTimeInterval(span - nonAwakeDuration),
                stage: .awake
            ),
            SleepStageSegment(
                id: "research-motion-v2-light",
                start: start.addingTimeInterval(span - nonAwakeDuration),
                end: start.addingTimeInterval(span),
                stage: .light
            )
        ]
        let adjusted = confirmedSleep(
            start: start,
            duration: observedDuration,
            span: span,
            source: "user_adjusted_sleep",
            motionSource: AtriaRecoveredMotionEpoch.source,
            motionValidated: false,
            stages: stages,
            restingHR: 51,
            hrv: nil,
            hrvWindowCount: 0,
            respiratoryRate: nil,
            id: "staged-adjusted-boundary"
        )
        let now = adjusted.end.addingTimeInterval(5 * 60)

        XCTAssertEqual(adjusted.effectiveSleepDuration, nonAwakeDuration)
        XCTAssertTrue(SessionStore.confirmedSleepIsPhysiologicalMainSleep(adjusted))

        let snapshot = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [adjusted],
            calendar: calendar
        )
        let projected = try XCTUnwrap(snapshot.nights.first)
        XCTAssertEqual(projected.observedDuration, observedDuration)
        XCTAssertEqual(projected.duration, nonAwakeDuration)
        XCTAssertTrue(SessionStore.confirmedSleepIsPhysiologicalMainSleep(projected),
                      "projection eligibility must retain measured coverage, not reuse staged TST")

        let directCycle = AtriaPhysiologicalCycle.current(
            now: now,
            confirmedSleeps: [adjusted],
            calendar: calendar
        )
        let compactCycle = AtriaPhysiologicalDay.current(
            now: now,
            sleepHistory: snapshot,
            calendar: calendar
        )
        XCTAssertEqual(directCycle.start, adjusted.end)
        XCTAssertEqual(compactCycle.start, directCycle.start)
        XCTAssertEqual(compactCycle.boundaryKind, directCycle.boundaryKind)

        let bulk = try XCTUnwrap(SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: snapshot,
            baseline: PersonalBaseline(),
            calendar: calendar
        ).first)
        XCTAssertEqual(bulk.sleepDuration, nonAwakeDuration)
        XCTAssertNotNil(bulk.recoveryPercent)

        let frozen = try XCTUnwrap(SessionStore.makeMorningFrozenDailyMetric(
            for: calendar.startOfDay(for: adjusted.end),
            computed: [],
            sessions: [],
            sleep: snapshot,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: now,
            calendar: calendar
        ))
        XCTAssertEqual(frozen.sleepDuration, nonAwakeDuration)
        XCTAssertEqual(frozen.recoveryPercent, bulk.recoveryPercent)
    }

    func testConfirmedShortRestCannotMintSleepOnlyDailyRows() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 8,
            hour: 1
        )))
        let shortRest = confirmedSleep(
            start: start,
            duration: AtriaPhysiologicalCycle.minimumMainSleepDuration - 1,
            source: "manual_sleep"
        )
        let sleep = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [shortRest],
            calendar: calendar
        )

        XCTAssertTrue(sleep.nights.contains { $0.id == shortRest.id })
        XCTAssertTrue(SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            calendar: calendar
        ).isEmpty, "a confirmed sub-3h rest cannot create a physiological daily row")
    }

    func testAutomaticShortDetectionKeepsThreeHourPhysiologicalFloor() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 8,
            hour: 1
        )))
        let automatic = confirmedSleep(
            start: start,
            duration: AtriaPhysiologicalCycle.minimumMainSleepDuration - 1,
            source: "auto_confirmed_sleep"
        )
        let sleep = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [automatic],
            calendar: calendar
        )

        XCTAssertFalse(SessionStore.confirmedSleepIsPhysiologicalMainSleep(automatic))
        XCTAssertTrue(SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            calendar: calendar
        ).isEmpty)
    }

    func testUserAdjustedSleepStillRequiresTwentyMinutesMeasuredCoverage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 8,
            hour: 1
        )))
        let insufficient = confirmedSleep(
            start: start,
            duration: AggregateSleepCandidate.napMinimumDuration - 1,
            source: "user_adjusted_sleep"
        )
        let sleep = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [insufficient],
            calendar: calendar
        )
        let projected = try XCTUnwrap(sleep.nights.first)

        XCTAssertFalse(SessionStore.confirmedSleepIsPhysiologicalMainSleep(insufficient))
        XCTAssertFalse(SessionStore.confirmedSleepIsPhysiologicalMainSleep(projected))
        XCTAssertTrue(SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            calendar: calendar
        ).isEmpty)
    }

    func testUserAdjustedSleepRejectsBroadWindowWithSparseSensorCoverage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 8,
            hour: 1
        )))
        let sparse = confirmedSleep(
            start: start,
            duration: AggregateSleepCandidate.napMinimumDuration,
            span: 8 * 60 * 60,
            source: "user_adjusted_sleep"
        )
        let sleep = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [sparse],
            calendar: calendar
        )
        let projected = try XCTUnwrap(sleep.nights.first)

        XCTAssertFalse(SessionStore.confirmedSleepIsPhysiologicalMainSleep(sparse))
        XCTAssertFalse(SessionStore.confirmedSleepIsPhysiologicalMainSleep(projected))
        XCTAssertTrue(SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            calendar: calendar
        ).isEmpty)
    }

    /// Device 2026-09-05: the owner marked 23:17–06:58 as Sleep. Measured
    /// coverage was 4h 45m of 7h 41m (62%). The 80% ratio rejected it, so
    /// the physiological day never moved and daytime HR overwrote the night's
    /// resting 58. A substantial measured night is the user's sleep even
    /// with a hole in the window.
    func testUserAdjustedSubstantialNightIsMainSleepDespiteCoverageHole() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 4, hour: 23, minute: 17
        )))
        let measured: TimeInterval = 4 * 3_600 + 45 * 60
        let span: TimeInterval = 7 * 3_600 + 41 * 60
        let night = confirmedSleep(
            start: start,
            duration: measured,
            span: span,
            source: "user_adjusted_sleep",
            eventTimeZoneIdentifier: "Asia/Kolkata",
            restingHR: 58
        )
        XCTAssertLessThan(measured / span, AggregateSleepCandidate.minimumAutoConfirmHRCoverageFraction)
        XCTAssertGreaterThanOrEqual(measured, AtriaPhysiologicalCycle.minimumMainSleepDuration)
        XCTAssertTrue(SessionStore.confirmedSleepIsPhysiologicalMainSleep(night))

        let sleep = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [night],
            calendar: calendar
        )
        let metrics = SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            calendar: calendar
        )
        let metric = try XCTUnwrap(metrics.first)
        XCTAssertEqual(metric.restingHR, 58)
        XCTAssertEqual(metric.sleepDuration, measured)

        let now = start.addingTimeInterval(span + 6 * 3_600)
        let cycle = AtriaPhysiologicalCycle.current(
            now: now,
            confirmedSleeps: [night],
            calendar: calendar
        )
        XCTAssertEqual(cycle.start, night.end)
        XCTAssertEqual(cycle.boundaryKind, .mainSleep)
    }

    func testConfirmedShortRestCannotMintOrRepairCurrentMorningDailyMetric() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 8
        )))
        let shortRest = confirmedSleep(
            start: day.addingTimeInterval(30 * 60),
            duration: AtriaPhysiologicalCycle.minimumMainSleepDuration - 1,
            source: "manual_sleep",
            id: "current-morning-short-rest"
        )
        let now = day.addingTimeInterval(3 * 60 * 60 + 45 * 60)
        let sleep = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [shortRest],
            calendar: calendar
        )

        XCTAssertNil(SessionStore.makeMorningFrozenDailyMetric(
            for: day,
            computed: [],
            sessions: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: now,
            calendar: calendar
        ), "a confirmed sub-3h rest cannot become current-morning physiology")
        XCTAssertTrue(SessionStore.mergeDailyMetricHistory(
            existing: [],
            computed: [],
            sessions: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: now,
            calendar: calendar
        ).isEmpty, "the current-morning merge cannot mint a row from a short rest")

        let frozenBlank = SavedDailyMetric(
            day: day,
            recoveryPercent: nil,
            recoveryConfidence: "unverified",
            hrv: nil,
            restingHR: nil,
            respiratoryRate: nil,
            sleepDuration: nil,
            sleepSpan: nil,
            sleepStart: nil,
            sleepEnd: nil,
            sleepSource: nil,
            sleepStageSegments: [],
            sleepConsistencyPercent: nil,
            strain: nil
        )
        let retained = SessionStore.mergeDailyMetricHistory(
            existing: [frozenBlank],
            computed: [],
            sessions: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(retained, [frozenBlank],
                       "a short rest cannot repair a blank frozen morning as physiological sleep")
    }

    func testLinkedResumedSleepPublishesOnCanonicalFinalWakeMorningAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let mainStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 8,
            hour: 20,
            minute: 30
        )))
        let main = confirmedSleep(
            start: mainStart,
            duration: 3 * 60 * 60,
            source: "overnight_sleep",
            id: "main-before-midnight"
        )
        let resumed = confirmedSleep(
            start: main.end.addingTimeInterval(15 * 60),
            duration: 2 * 60 * 60,
            source: "resumed_sleep",
            id: "resumed-after-midnight"
        )
        let sleep = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [main, resumed],
            calendar: calendar
        )

        let metric = try XCTUnwrap(SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            calendar: calendar
        ).first)
        XCTAssertTrue(calendar.isDate(metric.day, inSameDayAs: resumed.end))
        XCTAssertFalse(calendar.isDate(metric.day, inSameDayAs: main.end))
        XCTAssertEqual(metric.sleepStart, main.start)
        XCTAssertEqual(metric.sleepEnd, resumed.end)
        XCTAssertEqual(metric.sleepDuration, main.duration + resumed.duration)
    }

    func testConfirmedSleepSavePublishesLightweightSnapshotBeforeDeferredHistory() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func saveConfirmedSleeps("))
        let end = try XCTUnwrap(
            source.range(of: "private func writeDutyCycleSleepWindow", range: start.upperBound..<source.endIndex)
        )
        let savePath = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(savePath.contains("setCachedConfirmedSleeps("))
        XCTAssertTrue(
            savePath.contains(
                "refreshDerivedCaches: !archiveFreeLatestNightSettlement"
            )
        )
        XCTAssertTrue(savePath.contains("sleepHistorySnapshot = SleepHistorySnapshot("))
        XCTAssertTrue(savePath.contains("confirmedSleeps: sorted"))
        let publicationIndex = try XCTUnwrap(
            savePath.range(of: "sleepHistorySnapshot = SleepHistorySnapshot(")?.lowerBound
        )
        let deferredRefreshIndex = try XCTUnwrap(
            savePath.range(of: "refreshHistorySnapshotCache(deferred: true)")?.lowerBound
        )
        XCTAssertTrue(publicationIndex < deferredRefreshIndex)
    }

    func testConfirmedSleepCycleChangeRebuildsCurrentStepReceipt() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "private func saveConfirmedSleeps(")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "private func writeDutyCycleSleepWindow",
                range: start.upperBound..<source.endIndex
            )
        )
        let savePath = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(savePath.contains("preparation.stepReceiptCycleChanged"))
        XCTAssertTrue(savePath.contains("prepareConfirmedSleepSave("))
        XCTAssertFalse(savePath.contains(
            "let previousStepReceiptCycleStart = AtriaPhysiologicalCycle.current"
        ), "recovered save must not walk physiological history on MainActor")
        XCTAssertTrue(savePath.contains(
            "currentCycleStepReceiptDeferredUntilForeground = true"
        ))
        XCTAssertTrue(savePath.contains(
            "else if archiveFreeLatestNightSettlement {"
        ))
        XCTAssertTrue(savePath.contains(
            "reason: \"compact_latest_night_sleep_cycle_changed\""
        ), "archive-free sleep settlement must immediately refresh the new compact cycle")
        XCTAssertTrue(savePath.contains(
            "reason: \"confirmed_sleep_cycle_changed\""
        ))
    }

    func testDashboardRevisionSchedulesWidgetRefreshWithoutRelaunch() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: ".onReceive(store.$dashboardRevision.throttle")
        )
        let end = try XCTUnwrap(
            source.range(of: ".onReceive(NotificationCenter.default.publisher",
                         range: start.upperBound..<source.endIndex)
        )
        let dashboardHandler = String(source[start.lowerBound..<end.lowerBound])

        // 2026-08-20: the inline closure was extracted to
        // handleDashboardRevisionUpdate() (type-check relief on this large
        // view); follow the indirection so the pin still proves the revision
        // stream schedules a widget snapshot without a relaunch.
        XCTAssertTrue(dashboardHandler.contains("handleDashboardRevisionUpdate()"))
        let handlerStart = try XCTUnwrap(
            source.range(of: "private func handleDashboardRevisionUpdate() {")
        )
        let handlerEnd = try XCTUnwrap(
            source.range(of: "private func ",
                         range: handlerStart.upperBound..<source.endIndex)
        )
        let handlerBody = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])
        XCTAssertTrue(handlerBody.contains("scheduleWidgetSnapshot(reason: \"dashboard_revision\")"))
    }

    func testDeferredLaunchSettlementRejectsGreyOrStaleRowsAndAcceptsCoherentCards() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sleep = confirmedSleep()
        let day = calendar.startOfDay(for: sleep.end)
        let metric = SavedDailyMetric(day: day,
                                      recoveryPercent: 71,
                                      recoveryConfidence: "personal_baseline",
                                      hrv: sleep.hrv,
                                      restingHR: sleep.restingHR,
                                      respiratoryRate: 15.2,
                                      sleepDuration: sleep.duration,
                                      sleepSpan: sleep.span,
                                      sleepStart: sleep.start,
                                      sleepEnd: sleep.end,
                                      sleepSource: sleep.source,
                                      sleepStageSegments: sleep.stageSegments ?? [],
                                      sleepConsistencyPercent: 84,
                                      strain: 3.4)
        let settled = DailyRollupStoreEntry(day: day,
                                            recovery: 71,
                                            lnRMSSD: sleep.hrv.map { log(Double($0)) },
                                            rhr: sleep.restingHR,
                                            sleepSeconds: sleep.duration,
                                            sleepPerformance: 93,
                                            bedtimeMinutes: 1_320,
                                            strain: 3.4,
                                            respiratoryRate: 15.2,
                                            calendar: calendar)

        XCTAssertTrue(SessionStore.deferredLaunchCardSettlementMatches(
            sleep: sleep,
            metric: metric,
            rollup: settled,
            calendar: calendar
        ))
        let laterStrainRollup = DailyRollupStoreEntry(
            day: day,
            recovery: 71,
            lnRMSSD: sleep.hrv.map { log(Double($0)) },
            rhr: sleep.restingHR,
            sleepSeconds: sleep.duration,
            sleepPerformance: 93,
            bedtimeMinutes: 1_320,
            strain: 3.47,
            respiratoryRate: 15.2,
            calendar: calendar
        )
        XCTAssertTrue(SessionStore.deferredLaunchCardSettlementMatches(
            sleep: sleep,
            metric: metric,
            rollup: laterStrainRollup,
            calendar: calendar
        ), "live day-strain drift must not hold an immutable recovery widget")

        let grey = DailyRollupStoreEntry(day: day, calendar: calendar)
        XCTAssertFalse(SessionStore.deferredLaunchCardSettlementMatches(
            sleep: sleep,
            metric: metric,
            rollup: grey,
            calendar: calendar
        ), "an old all-nil rollup must never authorize launch/widget publication")

        let staleMetric = SavedDailyMetric(day: day,
                                           recoveryPercent: 71,
                                           recoveryConfidence: "personal_baseline",
                                           hrv: sleep.hrv,
                                           restingHR: sleep.restingHR,
                                           respiratoryRate: 15.2,
                                           sleepDuration: sleep.duration - 60 * 60,
                                           sleepSpan: sleep.span,
                                           sleepStart: sleep.start.addingTimeInterval(60 * 60),
                                           sleepEnd: sleep.end,
                                           sleepSource: sleep.source,
                                           sleepStageSegments: [],
                                           sleepConsistencyPercent: 84,
                                           strain: 3.4)
        XCTAssertFalse(SessionStore.deferredLaunchCardSettlementMatches(
            sleep: sleep,
            metric: staleMetric,
            rollup: settled,
            calendar: calendar
        ), "a prior sleep boundary must not be published for the confirmed night")

        let stalePhysiology = SavedDailyMetric(
            day: day,
            recoveryPercent: 71,
            recoveryConfidence: "personal_baseline",
            hrv: (sleep.hrv ?? 0) + 7,
            restingHR: sleep.restingHR + 4,
            respiratoryRate: 16.1,
            sleepDuration: sleep.duration,
            sleepSpan: sleep.span,
            sleepStart: sleep.start,
            sleepEnd: sleep.end,
            sleepSource: sleep.source,
            sleepStageSegments: sleep.stageSegments ?? [],
            sleepConsistencyPercent: 84,
            strain: 3.4
        )
        XCTAssertFalse(SessionStore.deferredLaunchCardSettlementMatches(
            sleep: sleep,
            metric: stalePhysiology,
            rollup: settled,
            calendar: calendar
        ), "a corrected linked night must not retain physiology from only its first segment")
    }

    func testDeferredLaunchSettlementUsesCanonicalFinalWakeForLinkedResumedSleep() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let main = confirmedSleep(duration: 4 * 60 * 60, source: "overnight_sleep")
        let resumedStart = main.end.addingTimeInterval(30 * 60)
        let resumedDuration: TimeInterval = 2 * 60 * 60
        let resumed = UserConfirmedSleep(
            id: "resumed-fixture",
            createdAt: resumedStart.addingTimeInterval(resumedDuration),
            start: resumedStart,
            end: resumedStart.addingTimeInterval(resumedDuration),
            source: "resumed_sleep",
            confidence: "manual_user_entered",
            sessions: 1,
            samples: 800,
            avgHR: 58,
            peakHR: 82,
            restingHR: 50,
            hrv: 51,
            hrvWindowCount: 3,
            duration: resumedDuration,
            span: resumedDuration,
            reason: "fixture",
            motionSource: "manual",
            motionValidated: false,
            stageSegments: nil,
            eventTimeZoneIdentifier: "UTC"
        )
        let canonical = try XCTUnwrap(AtriaPhysiologicalCycle.latestCompletedMainSleep(
            now: resumed.end.addingTimeInterval(60),
            confirmedSleeps: [main, resumed]
        ))
        let day = calendar.startOfDay(for: canonical.end)
        let metric = SavedDailyMetric(
            day: day,
            recoveryPercent: 39,
            recoveryConfidence: "unverified",
            hrv: canonical.hrv,
            restingHR: canonical.restingHR,
            respiratoryRate: 15.2,
            sleepDuration: canonical.duration,
            sleepSpan: canonical.span,
            sleepStart: canonical.start,
            sleepEnd: canonical.end,
            sleepSource: canonical.source,
            sleepStageSegments: canonical.stageSegments ?? [],
            sleepConsistencyPercent: 72,
            strain: 6.2
        )
        let rollup = DailyRollupStoreEntry(
            day: day,
            recovery: 39,
            lnRMSSD: canonical.hrv.map { log(Double($0)) },
            rhr: canonical.restingHR,
            sleepSeconds: canonical.duration,
            sleepPerformance: 68,
            bedtimeMinutes: 1_320,
            strain: 6.2,
            respiratoryRate: canonical.respiratoryRate,
            calendar: calendar
        )

        XCTAssertEqual(canonical.id, main.id)
        XCTAssertEqual(canonical.end, resumed.end)
        XCTAssertTrue(SessionStore.deferredLaunchCardSettlementMatches(
            sleep: canonical,
            metric: metric,
            rollup: rollup,
            calendar: calendar
        ))
    }

    func testDeferredLoadPublishesWidgetOnlyAfterVerifiedCardSettlement() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let sessions = try String(contentsOf: appDirectory.appendingPathComponent("Sessions.swift"),
                                  encoding: .utf8)
        let app = try String(contentsOf: appDirectory.appendingPathComponent("AtriaApp.swift"),
                             encoding: .utf8)
        let finishStart = try XCTUnwrap(sessions.range(of: "private func finishDeferredLoad("))
        let finishEnd = try XCTUnwrap(sessions.range(of: "private func continueDeferredLoadFollowUp",
                                                     range: finishStart.upperBound..<sessions.endIndex))
        let finish = String(sessions[finishStart.lowerBound..<finishEnd.lowerBound])
        let historyInvalidation = try XCTUnwrap(finish.range(
            of: "historySnapshotRevision &+= 1"
        ))
        let rollupInvalidation = try XCTUnwrap(finish.range(
            of: "dailyRollupPreparationRevision &+= 1"
        ))
        let loadedSessions = try XCTUnwrap(finish.range(of: "sessions = merged"))
        XCTAssertTrue(historyInvalidation.lowerBound < loadedSessions.lowerBound)
        XCTAssertTrue(rollupInvalidation.lowerBound < loadedSessions.lowerBound,
                      "pre-load empty history/rollup work must be stale before real sessions publish")
        let fence = try XCTUnwrap(finish.range(of: "deferredLaunchCardSettlementPending = true"))
        let loaded = try XCTUnwrap(finish.range(of: "self.hasCompletedDeferredSessionLoad = true"))
        let earlyDashboard = try XCTUnwrap(finish.range(of: "publishDashboardRevision()"))
        XCTAssertTrue(fence.lowerBound < loaded.lowerBound)
        XCTAssertTrue(loaded.lowerBound < earlyDashboard.lowerBound,
                      "the early UI revision is safe only because the widget fence is already active")

        let followUpStart = try XCTUnwrap(sessions.range(of: "private func continueDeferredLoadFollowUp"))
        let followUpEnd = try XCTUnwrap(sessions.range(of: "nonisolated static func deferredLaunchCardSettlementMatches",
                                                       range: followUpStart.upperBound..<sessions.endIndex))
        let followUp = String(sessions[followUpStart.lowerBound..<followUpEnd.lowerBound])
        XCTAssertTrue(followUp.contains("resumeDeferredLaunchCardSettlementIfNeeded(reason: \"deferred_session_load\")"))
        XCTAssertFalse(followUp.contains("refreshHistorySnapshotCache(deferred: true)"),
                       "launch must use the inherited required-publication fence")

        let requestStart = try XCTUnwrap(sessions.range(of: "private func requestDeferredLaunchCardSettlement("))
        let requestBody = String(sessions[requestStart.lowerBound...].prefix(20_000))
        let persistedFastPath = try XCTUnwrap(requestBody.range(
            of: "status=published_fast_path"
        ))
        let historicalRefresh = try XCTUnwrap(requestBody.range(
            of: "requestRequiredHistorySnapshotRefresh(deferred: true)"
        ))
        XCTAssertLessThan(
            persistedFastPath.lowerBound,
            historicalRefresh.lowerBound,
            "coherent persisted cards must not wait on the historical archive projection"
        )
        let verification = try XCTUnwrap(requestBody.range(of: "deferredLaunchCardSettlementMatches"))
        let dashboard = try XCTUnwrap(requestBody.range(of: "self.publishDashboardRevision()",
                                                        range: verification.upperBound..<requestBody.endIndex))
        let handoff = try XCTUnwrap(requestBody.range(of: "self.onDeferredLaunchCardSettlementPublished?(reason)",
                                                      range: dashboard.upperBound..<requestBody.endIndex))
        XCTAssertTrue(verification.lowerBound < dashboard.lowerBound)
        XCTAssertTrue(dashboard.lowerBound < handoff.lowerBound)
        XCTAssertTrue(requestBody.contains("status=withheld"),
                      "mismatched rows must retain the last durable widget snapshot")
        let clearFence = try XCTUnwrap(requestBody.range(
            of: "self.deferredLaunchCardSettlementPending = false",
            range: verification.upperBound..<requestBody.endIndex
        ))
        XCTAssertTrue(verification.lowerBound < clearFence.lowerBound)
        XCTAssertTrue(clearFence.lowerBound < dashboard.lowerBound)

        XCTAssertTrue(app.contains("store.onDeferredLaunchCardSettlementPublished ="))
        XCTAssertTrue(app.contains("reason: \"deferred_launch_cards_\\(reason)\""))
        XCTAssertTrue(app.contains("delay: .zero"))
    }

    func testNoSleepFallbackReleasesWidgetFenceFromCurrentRecoveryAuthority() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let sessions = try String(
            contentsOf: appDirectory.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let requestStart = try XCTUnwrap(
            sessions.range(of: "private func requestDeferredLaunchCardSettlement(")
        )
        let requestBody = String(sessions[requestStart.lowerBound...].prefix(10_000))
        let requiredRefresh = try XCTUnwrap(
            requestBody.range(of: "requestRequiredHistorySnapshotRefresh(")
        )
        let fallback = try XCTUnwrap(
            requestBody.range(of: "physiologicalCycle.boundaryKind != .mainSleep")
        )
        let resolver = try XCTUnwrap(
            requestBody.range(
                of: "DailyRecoveryResolver.summary(",
                range: fallback.upperBound..<requestBody.endIndex
            )
        )
        let release = try XCTUnwrap(
            requestBody.range(
                of: "deferredLaunchCardSettlementPending = false",
                range: resolver.upperBound..<requestBody.endIndex
            )
        )
        XCTAssertTrue(fallback.lowerBound < resolver.lowerBound)
        XCTAssertTrue(resolver.lowerBound < release.lowerBound)
        XCTAssertTrue(release.lowerBound < requiredRefresh.lowerBound,
                      "a current strict fallback must not wait behind the history worker")
        XCTAssertTrue(requestBody.contains("_fallback_recovery"))
    }

    func testWidgetPersistenceWaitsForBothSessionLoadAndCardSettlement() {
        XCTAssertFalse(WidgetSnapshotPublisher.shouldPersistSnapshot(
            hasLoadedSavedSessions: false,
            hasLoadedRecoveryHistory: true,
            deferredLaunchCardSettlementPending: false
        ))
        XCTAssertFalse(WidgetSnapshotPublisher.shouldPersistSnapshot(
            hasLoadedSavedSessions: true,
            hasLoadedRecoveryHistory: false,
            deferredLaunchCardSettlementPending: false
        ), "a provisional live Recovery must not replace persisted authority")
        XCTAssertFalse(WidgetSnapshotPublisher.shouldPersistSnapshot(
            hasLoadedSavedSessions: true,
            hasLoadedRecoveryHistory: true,
            deferredLaunchCardSettlementPending: true
        ), "the sessions-landed UI revision must not persist stale grey cards")
        XCTAssertTrue(WidgetSnapshotPublisher.shouldPersistSnapshot(
            hasLoadedSavedSessions: true,
            hasLoadedRecoveryHistory: true,
            deferredLaunchCardSettlementPending: false
        ))
    }

    func testDeferredLaunchCardSettlementRetryIsStrictlyBounded() {
        XCTAssertEqual(SessionStore.deferredLaunchCardSettlementRetryDelay(afterFailedAttempt: 0), 250)
        XCTAssertEqual(SessionStore.deferredLaunchCardSettlementRetryDelay(afterFailedAttempt: 1), 500)
        XCTAssertNil(SessionStore.deferredLaunchCardSettlementRetryDelay(afterFailedAttempt: 2))
        XCTAssertNil(SessionStore.deferredLaunchCardSettlementRetryDelay(afterFailedAttempt: 100))
        XCTAssertEqual(SessionStore.deferredLaunchCardSettlementRetryDelay(afterFailedAttempt: -1), 250)
    }

    func testRecoveryShowsLimitedConfidenceScoreWithoutQualifiedCurrentHRV() {
        let now = Date()
        var baseline = PersonalBaseline()
        for dayOffset in 1...3 {
            baseline.learn(fromResting: 56,
                           hrv: 48 + dayOffset,
                           at: now.addingTimeInterval(-Double(dayOffset) * 24 * 60 * 60),
                           overnight: true)
        }

        let recovery = Metrics.recoveryV2(
            hrvSnapshot: nil,
            fallbackRMSSD: nil,
            restingNow: 54,
            baseline: baseline,
            sleepEfficiency: 0.9,
            sleepDurationHours: 6.1
        )
        XCTAssertNotNil(recovery.percent,
                        "measured sleep must produce an honestly labeled day-one estimate")
        XCTAssertEqual(recovery.confidence, .unverified)
        XCTAssertFalse(recovery.usesHRV)
        XCTAssertTrue(recovery.detail.contains("HRV unavailable"))
        XCTAssertEqual(recovery.contributors.first(where: { $0.kind == .hrv })?.weight, 0)
    }

    func testStageAndMotionOnlySleepRepairCannotTriggerBaselineReplay() {
        let original = confirmedSleep()
        let stage = SleepStageSegment(id: "light",
                                      start: original.start,
                                      end: original.end,
                                      stage: .light)
        let repaired = confirmedSleep(motionSource: "historical_gravity",
                                      motionValidated: true,
                                      stages: [stage])

        XCTAssertFalse(SessionStore.confirmedSleepMutationAffectsBaseline(
            previous: [original],
            next: [repaired]
        ))
    }

    func testConfirmedMainSleepBoundaryChangeStillTriggersBaselineReplay() {
        let original = confirmedSleep()
        let shifted = confirmedSleep(start: original.start.addingTimeInterval(30 * 60))

        XCTAssertTrue(SessionStore.confirmedSleepMutationAffectsBaseline(
            previous: [original],
            next: [shifted]
        ))
    }

    func testSleepReclassificationStillTriggersBaselineReplay() {
        let original = confirmedSleep()
        let nap = confirmedSleep(duration: 60 * 60, source: "manual_nap")

        XCTAssertTrue(SessionStore.confirmedSleepMutationAffectsBaseline(
            previous: [original],
            next: [nap]
        ))
    }

    @MainActor
    func testCorrectedSleepSaveSettlesTodayRecoveryStrainAndWidgetInProcess() async throws {
        // Confirmed records are intentionally process-global durable state. A
        // prior test can therefore leave a future-dated fixture behind. Anchor
        // this scenario after the authoritative ledger so "latest" continues
        // to mean the sleep saved by this test without deleting unrelated
        // records or relying on suite order.
        let durableLatestEnd = SessionStore().confirmedSleeps.map(\.end).max()
        let now = max(
            Date(),
            durableLatestEnd?.addingTimeInterval(24 * 60 * 60) ?? Date()
        )
        let store = makeStore(now: now)
        let correctedEnd = now.addingTimeInterval(-45 * 60)
        let correctedStart = correctedEnd.addingTimeInterval(-(5 * 60 * 60 + 35 * 60))
        let wrongStart = correctedStart.addingTimeInterval(-(2 * 60 * 60 + 44 * 60))
        let wrongEnd = correctedEnd.addingTimeInterval(-60 * 60)
        let rollover = correctedStart.addingTimeInterval(3 * 60 * 60)
        let sleepSessions = [
            physiologicalSession(start: correctedStart,
                                 end: rollover,
                                 restingBPM: 54),
            physiologicalSession(start: rollover,
                                 end: correctedEnd,
                                 restingBPM: 54)
        ]
        let activityStart = correctedEnd.addingTimeInterval(10 * 60)
        let activityEnd = now.addingTimeInterval(-5 * 60)
        let activitySession = elevatedSession(start: activityStart, end: activityEnd)
        for session in sleepSessions {
            XCTAssertTrue(store.add(session))
        }
        XCTAssertTrue(store.add(activitySession))
        addTeardownBlock { @MainActor in
            for session in sleepSessions {
                store.deleteSession(id: session.id)
            }
            store.deleteSession(id: activitySession.id)
        }

        let today = AtriaTodaySessionProjectionStore(store: store)
        let review = SleepHistorySnapshot.Night(
            id: "wrong-pending-\(UUID().uuidString)",
            day: Calendar.current.startOfDay(for: wrongEnd),
            start: wrongStart,
            end: wrongEnd,
            duration: wrongEnd.timeIntervalSince(wrongStart),
            restingHR: 54,
            hrv: nil,
            hrvWindowCount: 0,
            respiratoryRate: nil,
            sleepEfficiency: 0.9,
            confidence: "review_needed",
            source: "sleep_episode_review",
            confirmed: false,
            stageSegments: [],
            eventTimeZoneIdentifier: TimeZone.current.identifier
        )
        let priorDashboardRevision = store.dashboardRevision
        let publication = expectation(description: "Today receives confirmed sleep")
        var didFulfillPublication = false
        var cancellable: AnyCancellable?
        cancellable = today.$state.dropFirst().sink { state in
            if state.sleepHistorySnapshot.latestMainSleep?.confirmed == true,
               !didFulfillPublication {
                didFulfillPublication = true
                publication.fulfill()
            }
        }

        let savedResult = await store.saveSleepReviewNightForUI(
            review,
            start: correctedStart,
            end: correctedEnd,
            isNap: false,
            rest: 55,
            source: "post_sleep_cards_regression"
        )
        let saved = try XCTUnwrap(savedResult)
        addTeardownBlock { @MainActor in
            _ = await store.deleteConfirmedSleep(id: saved.id)
        }

        await fulfillment(of: [publication], timeout: 2)
        withExtendedLifetime(cancellable) {}

        XCTAssertEqual(saved.start, correctedStart)
        XCTAssertEqual(saved.end, correctedEnd)
        XCTAssertEqual(saved.sessions, sleepSessions.count,
                       "the corrected sleep must be assembled across persisted three-hour rollovers")
        XCTAssertGreaterThan(saved.duration, 5 * 60 * 60)
        XCTAssertNotNil(saved.hrv, "qualified RR in the corrected window must survive the edit")
        XCTAssertGreaterThan(saved.hrvWindowCount ?? 0, 2)
        XCTAssertGreaterThan(store.dashboardRevision, priorDashboardRevision,
                             "the same process must publish the widget/dashboard trigger")

        let projectedSleep = try XCTUnwrap(today.state.sleepHistorySnapshot.latestMainSleep)
        XCTAssertEqual(projectedSleep.id, saved.id)
        XCTAssertTrue(projectedSleep.confirmed)
        XCTAssertEqual(projectedSleep.duration, saved.duration, accuracy: 0.1)
        let performance = today.state.sleepHistorySnapshot.sleepPerformancePercent(
            for: projectedSleep,
            baseNeedHours: SessionStore.configuredSleepBaseNeedHours()
        )
        XCTAssertGreaterThan(try XCTUnwrap(performance), 0,
                             "a newly saved sleep owns its frozen adaptive need and can be scored")

        let recovery = store.recoveryProjection(now: now,
                                                initialFallbackHRVSnapshot: nil,
                                                liveRestingHeartRate: nil)
        XCTAssertNotNil(recovery.percent,
                        "qualified sleep HRV + RHR + a learned baseline must produce an honest score")
        XCTAssertTrue(recovery.usesHRV)

        // Home and the widget both use the learned resting baseline as the
        // stable strain anchor; the corrected sleep's RHR is Recovery evidence,
        // not a replacement strain baseline.
        let strainRest = try XCTUnwrap(store.baseline.restingInt)
        let aggregate = store.homeSavedAggregate(rest: strainRest,
                                                 maxHR: store.profile.maxHR,
                                                 now: now)
        let strain = Metrics.strain(fromTRIMP: aggregate.savedTodayTRIMP)
        XCTAssertGreaterThan(strain, 0, "post-wake activity strain must remain real after sleep changes the cycle")
        let strainFill = try XCTUnwrap(AtriaRingMetricProjection.strainFill(strain: strain))
        XCTAssertGreaterThan(strainFill, 0)
        XCTAssertEqual(AtriaRingMetricProjection.strainTint(targetProgress: nil,
                                                            actualFill: strainFill),
                       Metrics.electricStrain,
                       "missing Recovery target must not make measured strain look absent")

        let ble = AtriaBLEManager(startsBluetooth: false)
        let widget = WidgetSnapshotPublisher.publish(store: store,
                                                     ble: ble,
                                                     reason: "post_sleep_cards_regression",
                                                     now: now)
        XCTAssertEqual(widget.sleepHours ?? -1, saved.duration / 3_600, accuracy: 0.01)
        XCTAssertEqual(widget.recoveryPercent, recovery.percent)
        XCTAssertGreaterThan(widget.strain, 0)
        XCTAssertEqual(widget.strain, strain, accuracy: 0.05,
                       "widget and Today must remain on the same physiological-cycle strain")
    }

    @MainActor
    private func makeStore(now: Date) -> SessionStore {
        var baseline = PersonalBaseline()
        for dayOffset in 1...3 {
            baseline.learn(fromResting: 56,
                           hrv: 48 + dayOffset,
                           at: now.addingTimeInterval(-Double(dayOffset) * 24 * 60 * 60),
                           overnight: true)
        }
        let rollupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-post-sleep-cards-\(UUID().uuidString).json")
        return SessionStore(restoreInitialization: .init(
            recover: { .noMarker },
            loadBaseline: { baseline },
            loadProfile: {
                AthleteProfile(age: 30,
                               measuredMaxHR: 190,
                               maxHRSource: .measured,
                               updated: now,
                               hasCompletedOnboarding: true)
            },
            loadDailyRollups: {
                DailyRollupStore(url: rollupURL,
                                 recoveryMetricsURL: nil,
                                 loadPersisted: false)
            }
        ))
    }

    private func physiologicalSession(start: Date,
                                      end: Date,
                                      restingBPM: Int) -> SavedSession {
        let duration = end.timeIntervalSince(start)
        let points = stride(from: 0.0, through: duration, by: 60.0).map {
            SavedSession.Point(t: $0, bpm: restingBPM + (Int($0 / 60).isMultiple(of: 7) ? 1 : 0))
        }
        var session = SavedSession(id: UUID(),
                                   start: start,
                                   end: end,
                                   label: "Post-sleep card RR fixture",
                                   points: points,
                                   eventTimeZoneIdentifier: TimeZone.current.identifier)
        session.rrPoints = stride(from: 0.0, through: duration, by: 1.0).map {
            SavedSession.RRPoint(t: $0,
                                 ms: Int($0).isMultiple(of: 2) ? 920 : 1_040,
                                 source: .standardHeartRateMeasurement2A37)
        }
        return session
    }

    private func elevatedSession(start: Date, end: Date) -> SavedSession {
        let duration = end.timeIntervalSince(start)
        return SavedSession(id: UUID(),
                            start: start,
                            end: end,
                            label: "Post-wake strain fixture",
                            points: stride(from: 0.0, through: duration, by: 1.0).map {
                                SavedSession.Point(t: $0, bpm: 138)
                            },
                            kind: "workout",
                            eventTimeZoneIdentifier: TimeZone.current.identifier)
    }
    // MARK: - Launch stage-backfill same-process publication (handoff-6 CP1)

    private func denseStageSession(start: Date,
                                   end: Date,
                                   bpm: Int) -> SavedSession {
        let duration = end.timeIntervalSince(start)
        // 5-second cadence passes the stage engine's density gate
        // (<=15s gaps, >=6 samples/min, boundary samples at both edges).
        let points = stride(from: 0.0, through: duration, by: 5.0).map {
            SavedSession.Point(t: $0,
                               bpm: bpm + (Int($0 / 300).isMultiple(of: 2) ? 1 : 0))
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: end,
                            label: "Dense stage-backfill fixture",
                            points: points,
                            eventTimeZoneIdentifier: TimeZone.current.identifier)
    }

    /// Earlier tests in this shared-process suite can leave stores with
    /// in-flight async follow-ups that write the process-global confirmed
    /// file. Give them a moment to settle so this test's saves are not
    /// interleaved with a zombie instance's rebases. (Production has exactly
    /// one store; this is test-topology, not a product race.)
    @MainActor
    private func quiesceSharedConfirmedStore() async {
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(750))
    }

    @MainActor
    func testDeferredStageBackfillPublicationExposesCommittedStagesInProcess() async throws {
        await quiesceSharedConfirmedStore()
        let now = Date(timeIntervalSinceReferenceDate: 805_316_709)
        let store = makeStore(now: now)
        let sleepStart = now.addingTimeInterval(-10 * 60 * 60)
        let sleepDuration: TimeInterval = 8 * 60 * 60
        // The exact stored shape the launch backfill commits: estimate-
        // provenance segments whose non-awake total reconciles with the
        // measured duration. (Stage DERIVATION is pinned by the engine and
        // refresh-gate suites and was device-proven on 2026-08-13; this test
        // pins the same-process PUBLICATION of an already-committed backfill.)
        let stages = [
            SleepStageSegment(id: SleepStageSegment.hrEstimateIDPrefix + "publish-a",
                              start: sleepStart,
                              end: sleepStart.addingTimeInterval(4 * 60 * 60),
                              stage: .light),
            SleepStageSegment(id: SleepStageSegment.hrEstimateIDPrefix + "publish-b",
                              start: sleepStart.addingTimeInterval(4 * 60 * 60),
                              end: sleepStart.addingTimeInterval(sleepDuration),
                              stage: .deep)
        ]
        let record = confirmedSleep(start: sleepStart,
                                    duration: sleepDuration,
                                    source: "user_adjusted_sleep",
                                    motionSource: "hr_only",
                                    motionValidated: false,
                                    stages: stages,
                                    restingHR: 52,
                                    id: "stage-backfill-publication-fixture")
        // The deferred save is exactly what the launch backfill performs:
        // durable commit, no per-save publication.
        await store.debugInstallConfirmedSleepsForTesting([record])
        addTeardownBlock { @MainActor in
            _ = await store.debugInstallConfirmedSleepsForTesting([])
        }
        XCTAssertFalse(
            (store.sleepHistorySnapshot.nights
                + store.sleepHistorySnapshot.additionalMainNights).contains {
                $0.start == sleepStart
            },
            "a deferred save must not have published the snapshot by itself"
        )

        let revisionBefore = store.sleepHistorySnapshotRevision
        store.debugPublishDeferredStageBackfillForTesting()

        XCTAssertEqual(store.sleepHistorySnapshotRevision, revisionBefore + 1,
                       "the narrow publication rebuilds the compact snapshot exactly once")
        let night = try XCTUnwrap(
            (store.sleepHistorySnapshot.nights
                + store.sleepHistorySnapshot.additionalMainNights).first {
                $0.start == sleepStart
            },
            "the committed stages must be visible in the live snapshot without a relaunch"
        )
        XCTAssertEqual(night.stageEvidence, .hrOnlyEstimate)
        XCTAssertTrue(night.isEstimatedStageDisplay,
                      "estimate-provenance stages render only through the labeled lane")
    }

    func testLaunchBackfillCallSitePublishesNarrowlyExactlyOnce() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // The deferred-load follow-up opts into the narrow publication.
        let followUpStart = try XCTUnwrap(source.range(
            of: "private func continueDeferredLoadFollowUp"
        )?.lowerBound)
        let followUpEnd = try XCTUnwrap(source.range(
            of: "nonisolated static func deferredLaunchCardSettlementMatches",
            range: followUpStart..<source.endIndex
        )?.lowerBound)
        let followUp = String(source[followUpStart..<followUpEnd])
        XCTAssertTrue(followUp.contains("narrowPublicationAfterCommit: true"),
                      "the launch backfill must publish its commit in the same launch")
        let resume = try XCTUnwrap(followUp.range(
            of: "resumeDeferredLaunchCardSettlementIfNeeded(reason: \"deferred_session_load\")"
        ))
        let backfillCall = try XCTUnwrap(followUp.range(
            of: "narrowPublicationAfterCommit: true"
        ))
        XCTAssertLessThan(backfillCall.lowerBound, resume.lowerBound,
                          "publication precedes card settlement so settlement reads post-commit truth")

        // The backfill runs the publication exactly once, only after a
        // repaired>0 durable save succeeded.
        let backfillStart = try XCTUnwrap(source.range(
            of: "private func backfillConfirmedSleepStagesFromSessions("
        )?.lowerBound)
        let backfillEnd = try XCTUnwrap(source.range(
            of: "/// One narrow, current-generation derived publication",
            range: backfillStart..<source.endIndex
        )?.lowerBound)
        let backfill = String(source[backfillStart..<backfillEnd])
        XCTAssertEqual(
            backfill.components(
                separatedBy: "publishDeferredConfirmedSleepStageBackfill(reason:"
            ).count - 1,
            1,
            "exactly one narrow publication per backfill run"
        )
        let saveGuard = try XCTUnwrap(backfill.range(of: "guard saved, executionShouldContinue()"))
        let publishCall = try XCTUnwrap(backfill.range(
            of: "publishDeferredConfirmedSleepStageBackfill(reason:"
        ))
        XCTAssertLessThan(saveGuard.lowerBound, publishCall.lowerBound,
                          "a failed or stale save publishes nothing")

        // The publication helper: fences + post-commit truth + deferred full
        // rebuild. It never touches archive recovery or BLE history.
        let helperStart = try XCTUnwrap(source.range(
            of: "private func publishDeferredConfirmedSleepStageBackfill(reason: String) {"
        )?.lowerBound)
        let helperEnd = try XCTUnwrap(source.range(
            of: "nonisolated static func recoveredMotionProvenance(",
            range: helperStart..<source.endIndex
        )?.lowerBound)
        let helper = String(source[helperStart..<helperEnd])
        XCTAssertTrue(helper.contains("guard canonicalMutationAllowed"))
        // A recovered transaction fences this publication only once it has
        // journaled a canonical mutation — that is when a mid-transaction
        // image exists. Bare admission is timing-driven (the launch
        // projection can be admitted at any instant) and fencing on it
        // silently swallowed committed stages until relaunch (2026-08-20).
        XCTAssertTrue(helper.contains(
            "guard recoveredDataMutationTransaction.rollbackOperationCount == 0"
        ), "a mutated recovered transaction owns its own terminal publication")
        XCTAssertTrue(helper.contains(
            "pendingDeferredStageBackfillPublicationReason = reason"
        ), "a fenced publication parks for the transaction's terminal edges — delayed, never lost")
        XCTAssertTrue(helper.contains(
            "func flushPendingDeferredStageBackfillPublicationAfterRecoveredTerminal"
        ), "both terminal edges flush the parked publication")
        XCTAssertTrue(helper.contains("confirmedSleeps: cachedConfirmedSleeps"),
                      "publication reads post-commit truth so a newer user edit wins")
        XCTAssertTrue(helper.contains("refreshHistorySnapshotCache(deferred: true)"),
                      "the heavy full rebuild stays off-main behind its revision fences")
        XCTAssertFalse(helper.contains("requestOfflineHistoricalSync"),
                       "publication must never trigger archive recovery or BLE history")
    }

    @MainActor
    func testStaleStageBackfillCommitCannotOverwriteNewerUserEdit() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 805_316_709)
        let store = makeStore(now: now)
        let start = now.addingTimeInterval(-12 * 60 * 60)
        let original = confirmedSleep(start: start,
                                      duration: 8 * 60 * 60,
                                      source: "user_adjusted_sleep",
                                      motionSource: "hr_only",
                                      motionValidated: false,
                                      stages: nil,
                                      restingHR: 52,
                                      id: "stage-backfill-race-fixture")
        await store.debugInstallConfirmedSleepsForTesting([original])
        addTeardownBlock { @MainActor in
            _ = await store.debugInstallConfirmedSleepsForTesting([])
        }

        // A user edit lands while the backfill's stage build is off-main:
        // same id, moved bounds.
        let edited = confirmedSleep(start: start.addingTimeInterval(30 * 60),
                                    duration: 7 * 60 * 60,
                                    source: "user_adjusted_sleep",
                                    motionSource: "hr_only",
                                    motionValidated: false,
                                    stages: nil,
                                    restingHR: 52,
                                    id: "stage-backfill-race-fixture")
        await store.debugInstallConfirmedSleepsForTesting([edited])

        // The stale backfill commit carries stages derived for the ORIGINAL
        // bounds and rebases over the base it captured before the edit.
        let staleStages = [
            SleepStageSegment(id: SleepStageSegment.hrEstimateIDPrefix + "stale",
                              start: start,
                              end: start.addingTimeInterval(8 * 60 * 60),
                              stage: .deep)
        ]
        let staleStaged = confirmedSleep(start: start,
                                         duration: 8 * 60 * 60,
                                         source: "user_adjusted_sleep",
                                         motionSource: "hr_only",
                                         motionValidated: false,
                                         stages: staleStages,
                                         restingHR: 52,
                                         id: "stage-backfill-race-fixture")
        _ = await store.debugSaveConfirmedSleepsWithRecoveredBaseForTesting(
            [staleStaged],
            base: [original]
        )

        let survivor = try XCTUnwrap(store.confirmedSleeps.first {
            $0.id == "stage-backfill-race-fixture"
        })
        XCTAssertEqual(survivor.start, edited.start,
                       "the newer user edit's bounds must win over the stale stage commit")
        XCTAssertEqual(survivor.duration, edited.duration)
        XCTAssertNil(survivor.stageSegments,
                     "stages derived for the pre-edit window must not attach to the edited record")

        // Re-minted variant: the user's edit replaced the record id entirely.
        let reminted = confirmedSleep(start: start.addingTimeInterval(60 * 60),
                                      duration: 6 * 60 * 60,
                                      source: "user_adjusted_sleep",
                                      motionSource: "hr_only",
                                      motionValidated: false,
                                      stages: nil,
                                      restingHR: 52,
                                      id: "stage-backfill-race-reminted")
        await store.debugInstallConfirmedSleepsForTesting([reminted])
        _ = await store.debugSaveConfirmedSleepsWithRecoveredBaseForTesting(
            [staleStaged],
            base: [original]
        )
        XCTAssertEqual(store.confirmedSleeps.map(\.id),
                       ["stage-backfill-race-reminted"],
                       "a stale stage commit must never resurrect a record the user replaced")
    }
    // MARK: - Nap/main reclassification racing the launch backfill (handoff-6 CP3)

    @MainActor
    func testReclassifyToNapSurvivesStageBackfillAndRelaunchPasses() async throws {
        await quiesceSharedConfirmedStore()
        let calendar = Calendar.current
        // Past-dated and clear of the suite's other fixture windows — see
        // testLaunchStageBackfillPublishesStagesInSameProcessExactlyOnce.
        let now = Date(timeIntervalSinceReferenceDate: 806_500_000)
        let store = makeStore(now: now)
        // The physically reported shape: a short early episode and a long
        // 9h12 main on the same civil date.
        let shortStart = now.addingTimeInterval(-20 * 60 * 60)
        let shortEnd = shortStart.addingTimeInterval(2 * 3_600 + 43 * 60)
        let longStart = now.addingTimeInterval(-14 * 60 * 60)
        let longDuration: TimeInterval = 9 * 3_600 + 12 * 60
        let longEnd = longStart.addingTimeInterval(longDuration)
        let session = denseStageSession(start: longStart.addingTimeInterval(-120),
                                        end: longEnd.addingTimeInterval(120),
                                        bpm: 55)
        XCTAssertTrue(store.add(session, deferDerivedPublication: true))
        let short = confirmedSleep(start: shortStart,
                                   duration: shortEnd.timeIntervalSince(shortStart),
                                   source: "user_adjusted_sleep",
                                   motionSource: "hr_only",
                                   motionValidated: false,
                                   stages: nil,
                                   restingHR: 52,
                                   id: "cp3-short")
        let long = confirmedSleep(start: longStart,
                                  duration: longDuration,
                                  source: "user_adjusted_sleep",
                                  motionSource: "hr_only",
                                  motionValidated: false,
                                  stages: nil,
                                  restingHR: 52,
                                  id: "cp3-long")
        await store.debugInstallConfirmedSleepsForTesting([short, long])
        addTeardownBlock { @MainActor in
            _ = await store.debugInstallConfirmedSleepsForTesting([])
            store.deleteSession(id: session.id)
        }

        // Launch pass 1: the backfill stages the long main.
        let first = await store.debugRunConfirmedSleepStageBackfillForTesting()
        XCTAssertTrue(first.succeeded)

        // The user's reclassification commits: same window, nap source,
        // re-minted id — exactly what the type-only reclassify path writes.
        // (The concurrent-commit variant of this protection is pinned
        // deterministically at the save layer by
        // testStaleStageBackfillCommitCannotOverwriteNewerUserEdit.)
        let stagedLong = store.confirmedSleeps.first { $0.id == "cp3-long" } ?? long
        let nap = confirmedSleep(start: shortStart,
                                 duration: shortEnd.timeIntervalSince(shortStart),
                                 source: "user_adjusted_nap",
                                 motionSource: "hr_only",
                                 motionValidated: false,
                                 stages: nil,
                                 restingHR: 52,
                                 id: "cp3-short-as-nap")
        await store.debugInstallConfirmedSleepsForTesting([nap, stagedLong])

        // Launch pass 2 (the relaunch shape): the backfill must not revert
        // the reclassification, resurrect the replaced record, or lose either.
        let relaunch = await store.debugRunConfirmedSleepStageBackfillForTesting()
        XCTAssertTrue(relaunch.succeeded)
        let finalRecords = store.confirmedSleeps.filter {
            $0.id.hasPrefix("cp3-")
        }
        XCTAssertEqual(Set(finalRecords.map(\.id)),
                       ["cp3-short-as-nap", "cp3-long"])
        let survivedNap = try XCTUnwrap(finalRecords.first {
            $0.id == "cp3-short-as-nap"
        })
        XCTAssertEqual(survivedNap.source, "user_adjusted_nap",
                       "a backfill pass must never overwrite an explicit nap classification")
        XCTAssertFalse(store.confirmedSleeps.contains { $0.id == "cp3-short" },
                       "the replaced main must not be resurrected by the backfill")

        // Ownership: only the long main anchors the physiological cycle.
        let boundaries = AtriaPhysiologicalCycle.boundaryEligibleMainSleeps(
            now: now,
            confirmedSleeps: finalRecords,
            calendar: calendar
        )
        XCTAssertEqual(boundaries.map(\.id), ["cp3-long"],
                       "the nap must never anchor the day; the long main owns the ring")

        // The compact snapshot reaches a terminal, consistent row set: the
        // nap renders exactly once as a nap and never as a canonical main.
        let snapshot = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: finalRecords,
            calendar: calendar
        )
        XCTAssertEqual(snapshot.napNights.filter {
            $0.start == shortStart
        }.count, 1)
        XCTAssertFalse(snapshot.nights.contains { $0.start == shortStart },
                       "the reclassified nap must not occupy a canonical main slot")
    }
}