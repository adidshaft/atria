import XCTest
import UIKit
@testable import Atria

final class AtriaAnalyticsTests: XCTestCase {
    private static let historicalArchiveTestLock = NSLock()

    func testLatestSleepSemanticsKeepNapsSeparateFromOvernightMetrics() throws {
        let day = Date(timeIntervalSince1970: 1_783_824_000)
        let mainStart = day.addingTimeInterval(23 * 60 * 60)
        let napStart = day.addingTimeInterval(15 * 60 * 60)
        let main = SleepHistorySnapshot.Night(id: "main",
                                              day: day,
                                              start: mainStart,
                                              end: mainStart.addingTimeInterval(8 * 3_600),
                                              duration: 8 * 3_600,
                                              restingHR: 52,
                                              hrv: 64,
                                              respiratoryRate: 14.2,
                                              sleepEfficiency: 0.92,
                                              confidence: "confirmed",
                                              source: "manual_sleep",
                                              confirmed: true,
                                              stageSegments: [])
        let pendingNap = SleepHistorySnapshot.Night(id: "pending-nap",
                                                    day: day,
                                                    start: napStart,
                                                    end: napStart.addingTimeInterval(30 * 60),
                                                    duration: 30 * 60,
                                                    restingHR: 58,
                                                    hrv: nil,
                                                    respiratoryRate: nil,
                                                    sleepEfficiency: nil,
                                                    confidence: "candidate",
                                                    source: "nap_candidate",
                                                    confirmed: false,
                                                    stageSegments: [])
        let confirmedNap = SleepHistorySnapshot.Night(id: "confirmed-nap",
                                                      day: day,
                                                      start: napStart,
                                                      end: napStart.addingTimeInterval(45 * 60),
                                                      duration: 45 * 60,
                                                      restingHR: 57,
                                                      hrv: 60,
                                                      respiratoryRate: 14.8,
                                                      sleepEfficiency: 0.86,
                                                      confidence: "confirmed",
                                                      source: "manual_nap",
                                                      confirmed: true,
                                                      stageSegments: [])

        let pendingAfterMain = SleepHistorySnapshot(nights: [pendingNap, main],
                                                    confirmedCount: 1,
                                                    candidateCount: 1)
        XCTAssertEqual(pendingAfterMain.latestMainSleep?.id, main.id)
        XCTAssertEqual(pendingAfterMain.latestNap?.id, pendingNap.id)
        XCTAssertEqual(pendingAfterMain.latestReviewable?.id, pendingNap.id)

        let pendingBeforeMain = SleepHistorySnapshot(nights: [main, pendingNap],
                                                     confirmedCount: 1,
                                                     candidateCount: 1)
        XCTAssertEqual(pendingBeforeMain.latestMainSleep?.id, main.id)
        XCTAssertEqual(pendingBeforeMain.latestNap?.id, pendingNap.id)
        XCTAssertEqual(pendingBeforeMain.latestReviewable?.id, main.id)

        let confirmedAfterMain = SleepHistorySnapshot(nights: [confirmedNap, main],
                                                      confirmedCount: 2,
                                                      candidateCount: 0)
        XCTAssertEqual(confirmedAfterMain.latestMainSleep?.id, main.id)
        XCTAssertEqual(confirmedAfterMain.latestNap?.id, confirmedNap.id)
        XCTAssertEqual(confirmedAfterMain.latestReviewable?.id, confirmedNap.id)
    }

    func testCalibrationExamplesRemainInRange() {
        for check in AtriaAnalytics.CalibrationExamples.numericChecks {
            XCTAssertTrue(check.passed,
                          "\(check.name) expected \(check.expected) +/- \(check.tolerance), got \(check.actual)")
        }

        for check in AtriaAnalytics.CalibrationExamples.labelChecks {
            XCTAssertTrue(check.passed,
                          "\(check.name) expected \(check.expected), got \(check.actual)")
        }
    }

    func testCurrentPhysicalBaselineVO2RemainsLearningUntilTrusted() {
        let summary = AtriaAnalytics.VO2Max.summary(
            rest: 59,
            maxHR: 190,
            restingSamples: 2,
            maxHRMeasured: true,
            restingTrend: [57, 58, 68, 70, 60, 62, 57]
        )

        XCTAssertNil(summary.value)
        // 2026-07-28 deterministic-presentation pass: valueText is a DISPLAY
        // string and now uses the app-wide no-value token. The invariant this
        // test is named for is untouched and still asserted either side of this
        // line -- no value, and confidence still reads "learning". VO2 max was
        // the last value line saying "Learning" while Recovery, Stress,
        // Respiration and Sleep beside it said "--".
        XCTAssertEqual(summary.valueText, AtriaCompactMetricPresentation.noValue)
        XCTAssertEqual(summary.confidence, "learning")
        XCTAssertEqual(summary.detail, "2/14 RHR")
        XCTAssertEqual(summary.compactStatusText, "2/14 RHR")
        XCTAssertEqual(summary.trendDetail, "2/14 RHR days.")
        XCTAssertTrue(summary.narrative.localizedCaseInsensitiveContains("7 qualified resting-HR days"))
    }

    func testVO2PublishesPreliminaryValueBeforeTrustedBaseline() throws {
        let summary = AtriaAnalytics.VO2Max.summary(
            rest: 57,
            maxHR: 190,
            restingSamples: 11,
            maxHRMeasured: true,
            restingTrend: [60, 59, 58, 57]
        )

        XCTAssertEqual(try XCTUnwrap(summary.value), 51.0, accuracy: 0.01)
        XCTAssertEqual(summary.confidence, "preliminary")
        XCTAssertEqual(summary.detail, "preliminary · RHR 57 · HRmax 190")
        XCTAssertTrue(summary.narrative.contains("11/14 qualified RHR days"))
    }

    func testVO2KeepsTrustedLabelAtFourteenDays() throws {
        let summary = AtriaAnalytics.VO2Max.summary(
            rest: 57,
            maxHR: 190,
            restingSamples: 14,
            maxHRMeasured: true,
            restingTrend: [60, 59, 58, 57]
        )

        XCTAssertEqual(try XCTUnwrap(summary.value), 51.0, accuracy: 0.01)
        XCTAssertEqual(summary.confidence, "rough estimate")
    }

    func testMeasuredSustainedStrengthLoadUsesModerateStrainRange() {
        // Regression point from a real 64-minute strength window: 3,820 seconds
        // of observed strap HR, mean 131 bpm, peak 170 bpm, rest 68, max 190.
        // The input is the measured Banister integral, not a workout estimate.
        XCTAssertEqual(Metrics.strain(fromTRIMP: 65.6037), 7.44, accuracy: 0.02)
    }

    func testSleepStagesIncludeREMInUserFacingOrder() {
        XCTAssertTrue(SleepStageKind.allCases.contains(.rem))
        XCTAssertEqual(SleepStageKind.rem.label, "REM")
        XCTAssertEqual(SleepStageKind.allCases.map(\.label), ["Awake", "Light", "REM", "SWS", "Deep"])
    }

    func testSleepStageResearchProducesUserVisibleBreakdown() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(4 * 60 * 60)
        let samples = syntheticSleepSamples(start: start)

        let stages = AtriaSleepWakeResearch.stageSegments(samples: samples,
                                                          start: start,
                                                          end: end,
                                                          restingHR: 60,
                                                          isNap: false,
                                                          motionValidated: true)
        let stageKinds = Set(stages.map(\.stage))

        XCTAssertFalse(stages.isEmpty)
        XCTAssertTrue(stageKinds.contains(.awake), "expected an awake edge segment")
        XCTAssertTrue(stageKinds.contains(.light), "expected light sleep to be distinguishable")
        XCTAssertTrue(stageKinds.contains(.rem), "expected REM to be distinguishable")
        XCTAssertTrue(stageKinds.contains(.sws) || stageKinds.contains(.deep),
                      "expected restorative SWS/deep sleep to be distinguishable")
        XCTAssertLessThanOrEqual(stages.first?.start ?? end, start)
        XCTAssertGreaterThanOrEqual(stages.last?.end ?? start, end.addingTimeInterval(-30))
    }

    func testSleepStageResearchProducesLabeledHROnlyBreakdown() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(4 * 60 * 60)
        let samples = stride(from: 0, through: 4 * 60 * 60, by: 30).map { second in
            AtriaSleepWakeResearch.HeartSample(t: start.addingTimeInterval(TimeInterval(second)),
                                               bpm: 61 + ((second / 30).isMultiple(of: 10) ? 1 : 0))
        }

        let stages = AtriaSleepWakeResearch.stageSegments(samples: samples,
                                                          start: start,
                                                          end: end,
                                                          restingHR: 60,
                                                          isNap: false,
                                                          motionValidated: false)
        let stageKinds = Set(stages.map(\.stage))

        XCTAssertFalse(stages.isEmpty)
        XCTAssertTrue(stageKinds.contains { $0 != .awake },
                      "expected HR-only sleep to produce labeled sleep-stage estimates")
    }

    func testSleepStageResearchHandlesFullNightOneHertzStream() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let duration = 8 * 60 * 60
        let end = start.addingTimeInterval(TimeInterval(duration))
        let samples = (0...duration).map { second in
            let cycle = Double(second % 5_400) / 5_400
            let bpm = 61 + Int((sin(cycle * 2 * .pi) * 5).rounded())
            return AtriaSleepWakeResearch.HeartSample(t: start.addingTimeInterval(TimeInterval(second)),
                                                      bpm: bpm)
        }

        let stages = AtriaSleepWakeResearch.stageSegments(samples: samples,
                                                          start: start,
                                                          end: end,
                                                          restingHR: 58,
                                                          isNap: false,
                                                          motionValidated: true)

        XCTAssertFalse(stages.isEmpty)
        XCTAssertEqual(stages.first?.start, start)
        XCTAssertEqual(stages.last?.end, end)
        XCTAssertEqual(stages.reduce(0) { $0 + $1.duration }, TimeInterval(duration), accuracy: 0.001)
    }

    func testDisplayStagesFoldSWSIntoDeep() {
        XCTAssertEqual(SleepStageKind.displayOrder, [.awake, .light, .rem, .deep])
        XCTAssertEqual(SleepStageKind.sws.displayStage, .deep)
        XCTAssertEqual(SleepStageKind.deep.displayStage, .deep)
        XCTAssertEqual(SleepStageKind.light.displayStage, .light)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let segments = [
            SleepStageSegment(id: "1", start: start, end: start.addingTimeInterval(1_200), stage: .light),
            SleepStageSegment(id: "2", start: start.addingTimeInterval(1_200), end: start.addingTimeInterval(2_400), stage: .sws),
            SleepStageSegment(id: "3", start: start.addingTimeInterval(2_400), end: start.addingTimeInterval(3_600), stage: .deep),
            SleepStageSegment(id: "4", start: start.addingTimeInterval(3_600), end: start.addingTimeInterval(4_200), stage: .rem)
        ]
        let night = SleepHistorySnapshot.Night(id: "night",
                                               day: start,
                                               start: start,
                                               end: start.addingTimeInterval(4_200),
                                               duration: 4_200,
                                               restingHR: nil,
                                               hrv: nil,
                                               respiratoryRate: nil,
                                               sleepEfficiency: nil,
                                               confidence: "confirmed",
                                               source: "manual_sleep",
                                               confirmed: true,
                                               stageSegments: segments)

        XCTAssertFalse(night.displayStageSegments.contains { $0.stage == .sws })
        let deepRuns = night.displayStageSegments.filter { $0.stage == .deep }
        XCTAssertEqual(deepRuns.count, 1, "adjacent sws+deep runs should merge into a single deep run")
        XCTAssertEqual(night.stageDuration(.deep), 2_400, accuracy: 0.001)
        XCTAssertEqual(night.stageDuration(.sws), 0)
    }

    func testSameDayNapSurvivesAlongsideMainSleepOnSameCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))

        let napStart = day.addingTimeInterval(13 * 60 * 60)
        let nap = UserConfirmedSleep(id: "nap",
                                    createdAt: napStart,
                                    start: napStart,
                                    end: napStart.addingTimeInterval(3_600),
                                    source: "manual_nap",
                                    confidence: "manual_user_entered",
                                    sessions: 1,
                                    samples: 10,
                                    avgHR: 58,
                                    peakHR: 62,
                                    restingHR: 55,
                                    hrv: 60,
                                    hrvWindowCount: 3,
                                    duration: 3_600,
                                    span: 3_600,
                                    reason: "manual",
                                    motionSource: "manual",
                                    motionValidated: false,
                                    stageSegments: nil)

        let mainStart = day.addingTimeInterval(23 * 60 * 60)
        let main = UserConfirmedSleep(id: "main",
                                     createdAt: mainStart,
                                     start: mainStart,
                                     end: mainStart.addingTimeInterval(7 * 60 * 60),
                                     source: "manual_sleep",
                                     confidence: "manual_user_entered",
                                     sessions: 1,
                                     samples: 10,
                                     avgHR: 52,
                                     peakHR: 58,
                                     restingHR: 50,
                                     hrv: 64,
                                     hrvWindowCount: 4,
                                     duration: 7 * 60 * 60,
                                     span: 7 * 60 * 60,
                                     reason: "manual",
                                     motionSource: "manual",
                                     motionValidated: false,
                                     stageSegments: nil)

        let snapshot = SleepHistorySnapshot(rollups: [], confirmedSleeps: [nap, main], calendar: calendar)

        // Both records survive: the nap in napNights, the main sleep in nights.
        XCTAssertTrue(snapshot.nights.contains { $0.id == "main" })
        XCTAssertTrue(snapshot.napNights.contains { $0.id == "nap" })
        XCTAssertFalse(snapshot.nights.contains { $0.id == "nap" })

        guard let mainNight = snapshot.nights.first(where: { $0.id == "main" }) else {
            return XCTFail("expected main sleep night")
        }
        let credited = snapshot.sleepNeedHours(for: mainNight,
                                               baseNeedHours: 8,
                                               yesterdayStrain: nil,
                                               calendar: calendar)
        XCTAssertEqual(credited, 8 - 1 * 0.9, accuracy: 0.001)
    }

    func testManualSleepKeepsDurationButDoesNotFabricateEfficiencyOrRecoveryLift() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date()
        let start = now.addingTimeInterval(-7 * 60 * 60)
        let manual = UserConfirmedSleep(id: "manual-efficiency-regression",
                                        createdAt: now,
                                        start: start,
                                        end: now,
                                        source: "manual_sleep",
                                        confidence: "manual_user_entered",
                                        sessions: 0,
                                        samples: 0,
                                        avgHR: 0,
                                        peakHR: 0,
                                        restingHR: 60,
                                        hrv: 50,
                                        hrvWindowCount: 0,
                                        duration: 7 * 60 * 60,
                                        span: 7 * 60 * 60,
                                        reason: "manual",
                                        motionSource: "manual",
                                        motionValidated: false,
                                        stageSegments: nil)
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [manual],
                                            calendar: calendar)
        let night = try XCTUnwrap(snapshot.nights.first)

        XCTAssertEqual(night.durationHours, 7, accuracy: 0.001)
        XCTAssertNil(night.sleepEfficiency)

        let baseline = PersonalBaseline(restingHR: 60,
                                        hrvEMA: 50,
                                        sessions: PersonalBaseline.trustedMinimumSamples,
                                        updated: now,
                                        samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                 now: now))
        let fromManualNight = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                               fallbackRMSSD: 50,
                                                               restingNow: 60,
                                                               baseline: baseline,
                                                               sleepEfficiency: night.sleepEfficiency,
                                                               sleepDurationHours: night.durationHours)
        let durationOnly = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                            fallbackRMSSD: 50,
                                                            restingNow: 60,
                                                            baseline: baseline,
                                                            sleepEfficiency: nil,
                                                            sleepDurationHours: 7)
        let fabricatedPerfectEfficiency = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                                           fallbackRMSSD: 50,
                                                                           restingNow: 60,
                                                                           baseline: baseline,
                                                                           sleepEfficiency: 1,
                                                                           sleepDurationHours: 7)

        XCTAssertEqual(fromManualNight.percent, durationOnly.percent)
        XCTAssertGreaterThan(fabricatedPerfectEfficiency.percent ?? 0,
                             fromManualNight.percent ?? 100)
    }

    func testConfirmedNapAndDismissalSuppressRegeneratedSleepCandidate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let start = day.addingTimeInterval(14 * 3_600)
        let end = start.addingTimeInterval(40 * 60)
        let rollup = DailyRollup(day: day,
                                sessions: 1,
                                activityCandidates: 0,
                                workouts: 0,
                                confirmedWorkouts: 0,
                                restCandidates: 0,
                                sleepReady: 0,
                                sleepCandidates: 1,
                                duration: 40 * 60,
                                sleepDuration: 40 * 60,
                                sleepSpan: 40 * 60,
                                sleepStart: start,
                                sleepEnd: end,
                                sleepSource: "nap_candidate",
                                sleepStageSegments: [],
                                strain: 0,
                                avgHRV: nil,
                                restingHR: 55,
                                avgRespiratoryRate: nil)
        let nap = UserConfirmedSleep(id: "saved-nap",
                                     createdAt: end,
                                     start: start,
                                     end: end,
                                     source: "manual_nap",
                                     confidence: "manual_user_entered",
                                     sessions: 1,
                                     samples: 10,
                                     avgHR: 58,
                                     peakHR: 62,
                                     restingHR: 55,
                                     hrv: nil,
                                     hrvWindowCount: nil,
                                     duration: 40 * 60,
                                     span: 40 * 60,
                                     reason: "test",
                                     motionSource: "manual",
                                     motionValidated: false,
                                     stageSegments: nil)

        let confirmed = SleepHistorySnapshot(rollups: [rollup], confirmedSleeps: [nap], calendar: calendar)
        XCTAssertEqual(confirmed.candidateCount, 0)
        XCTAssertEqual(confirmed.napNights.map(\.id), ["saved-nap"])
        XCTAssertFalse(confirmed.nights.contains { !$0.confirmed })

        let dismissed = SleepHistorySnapshot(
            rollups: [rollup],
            confirmedSleeps: [],
            dismissedCandidates: [AtriaDismissedSleepCandidate(start: start, end: end)],
            calendar: calendar
        )
        XCTAssertEqual(dismissed.candidateCount, 0)
        XCTAssertTrue(dismissed.nights.isEmpty)
    }

    func testDailyRollupSleepPerformanceCreditsSameDayNap() {
        let base = SessionStore.dailyRollupSleepPerformance(sleepDuration: 7 * 3_600,
                                                            baseNeedHours: 8,
                                                            yesterdayStrain: nil,
                                                            priorNights: [])
        let withNap = SessionStore.dailyRollupSleepPerformance(sleepDuration: 7 * 3_600,
                                                               baseNeedHours: 8,
                                                               yesterdayStrain: nil,
                                                               priorNights: [],
                                                               sameDayNapHours: 1)
        XCTAssertNotNil(base)
        XCTAssertNotNil(withNap)
        XCTAssertGreaterThan(withNap ?? 0, base ?? 0,
                             "a same-day nap should raise sleep performance vs. no nap credit")
    }

    func testSleepClassifyAcceptsArchiveDerivedStillness() throws {
        try withCleanHistoricalArchive {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            for index in 0..<30 {
                let unix = UInt32(start.timeIntervalSince1970) + UInt32(index * 60)
                let payload = historicalPayloadWithGravity(x: 0,
                                                           y: 0,
                                                           z: 1,
                                                           counter: UInt32(index),
                                                           timestamp: unix)
                let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                                      capturedAt: start.addingTimeInterval(TimeInterval(index * 60)),
                                                      source: "0x2f",
                                                      layoutVersion: HistoricalArchive.layoutVersion,
                                                      sequence: 24,
                                                      command: 0x16,
                                                      unix7: unix,
                                                      subsec11: 0,
                                                      flash13: UInt32(index),
                                                      payloadLength: payload.count,
                                                      whoofHR17: 61,
                                                      whoofRRNum18: 2,
                                                      whoofRR19: [980, 1_010],
                                                      kRR64: [980, 1_010],
                                                      gravityX36: 0,
                                                      gravityY40: 0,
                                                      gravityZ44: 1,
                                                      gravityMagnitude: 1,
                                                      gravityValidated: true,
                                                      candidateRR: ["whoof19", "k64"],
                                                      rawPayloadHex: HistoricalArchive.hex(payload),
                                                      clockDeviceRef: unix,
                                                      clockWallRef: unix,
                                                      clockDriftSeconds: 0,
                                                      clockCorrectedUnix7: unix,
                                                      clockCorrectionStatus: "clock_ref_present",
                                                      currentSessionUsable: false,
                                                      metricUsable: false,
                                                      usabilityReason: "test_archive_stillness")
                _ = try HistoricalArchive.append(record)
            }

            let summary = try XCTUnwrap(runOffMain {
                HistoricalArchive.motionFeatureSummary(start: start,
                                                       end: start.addingTimeInterval(30 * 60))
            })
            let result = AtriaSleepWakeResearch.classify(duration: 4 * 60 * 60,
                                                         averageHR: 62,
                                                         restingHR: 55,
                                                         imuStillnessRatio: summary.stillnessRatio,
                                                         imuMovementIntensity: summary.movementIntensity,
                                                         strapSteps: 0,
                                                         strapStepEvidenceAvailable: true,
                                                         windowStart: start,
                                                         hrStandardDeviation: 2)
            XCTAssertEqual(result.state, "sleep_research")
            XCTAssertEqual(result.confidence, "research")
            XCTAssertEqual(result.reason, "low_motion_low_hr")
        }
    }

    func testBoundedMotionSummaryDoesNotValidateSparseQuietWindow() {
        let summary = HistoricalArchive.MotionFeatureSummary(stillnessRatio: 1,
                                                             movementIntensity: 0,
                                                             rows: 30,
                                                             validatedRows: 30,
                                                             coverageSeconds: 3 * 60 * 60,
                                                             maximumGapSeconds: 5 * 60,
                                                             firstUnix: 1_800_000_000,
                                                             lastUnix: 1_800_010_800,
                                                             reason: "fixture")
        XCTAssertFalse(summary.lowMotionReady,
                       "a few quiet rows cannot validate hours of sleep-like stillness")
    }

    /// A missing strap-step stream is not a zero-step stream.  Without this
    /// guard, a short active-wear window could be labelled sleep simply because
    /// the R10 channel had not supplied any frames yet.
    func testSleepClassifyDoesNotTreatMissingStrapStepsAsStillness() {
        let result = AtriaSleepWakeResearch.classify(duration: 60 * 60,
                                                     averageHR: 58,
                                                     restingHR: 52,
                                                     imuStillnessRatio: 0.95,
                                                     imuMovementIntensity: 0.03,
                                                     strapSteps: nil,
                                                     strapStepEvidenceAvailable: false)

        XCTAssertEqual(result.state, "learning")
        XCTAssertEqual(result.confidence, "none")
        XCTAssertEqual(result.reason, "strap_steps_missing")
    }

    func testBoundedMotionSummaryRequiresDenseValidatedThirtyMinuteEvidence() {
        let ready = HistoricalArchive.MotionFeatureSummary(stillnessRatio: 0.96,
                                                           movementIntensity: 0.02,
                                                           rows: 300,
                                                           validatedRows: 300,
                                                           coverageSeconds: 30 * 60,
                                                           maximumGapSeconds: 60,
                                                           firstUnix: 1_800_000_000,
                                                           lastUnix: 1_800_001_800,
                                                           reason: "fixture")
        XCTAssertTrue(ready.lowMotionReady)

        let unvalidated = HistoricalArchive.MotionFeatureSummary(stillnessRatio: 1,
                                                                 movementIntensity: 0,
                                                                 rows: 400,
                                                                 validatedRows: 300,
                                                                 coverageSeconds: 30 * 60,
                                                                 maximumGapSeconds: 60,
                                                                 firstUnix: 1_800_000_000,
                                                                 lastUnix: 1_800_001_800,
                                                                 reason: "fixture")
        XCTAssertFalse(unvalidated.lowMotionReady)

        let discontinuous = HistoricalArchive.MotionFeatureSummary(stillnessRatio: 1,
                                                                   movementIntensity: 0,
                                                                   rows: 300,
                                                                   validatedRows: 300,
                                                                   coverageSeconds: 3 * 60 * 60,
                                                                   maximumGapSeconds: 31 * 60,
                                                                   firstUnix: 1_800_000_000,
                                                                   lastUnix: 1_800_010_800,
                                                                   reason: "fixture")
        XCTAssertFalse(discontinuous.lowMotionReady)
    }

    func testHistoricalCurrentSessionReplayUsesCaptureAnchoredMotionWindow() throws {
        try withCleanHistoricalArchive {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            // Keep the fixture drift on the production five-minute clock grid so
            // all 300 rows land exactly inside the requested capture window.
            let staleUnixBase: UInt32 = 1_781_000_100
            let step = 60
            let count = 300
            let batchCapturedAt = start.addingTimeInterval(TimeInterval((count - 1) * step))
            let rawDrift = Int(start.timeIntervalSince1970) - Int(staleUnixBase)
            let snappedDrift = ((rawDrift + 150) / 300) * 300
            for index in 0..<count {
                let unix = staleUnixBase + UInt32(index * step)
                let payload = historicalPayloadWithGravity(x: 0,
                                                           y: 0,
                                                           z: 1,
                                                           counter: UInt32(index),
                                                           timestamp: unix)
                let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                                      capturedAt: batchCapturedAt,
                                                      source: "0x2f",
                                                      layoutVersion: HistoricalArchive.layoutVersion,
                                                      sequence: 24,
                                                      command: 0x16,
                                                      unix7: unix,
                                                      subsec11: 0,
                                                      flash13: UInt32(index),
                                                      payloadLength: payload.count,
                                                      whoofHR17: 61,
                                                      whoofRRNum18: 0,
                                                      whoofRR19: [],
                                                      kRR64: [980, 1_010],
                                                      gravityX36: 0,
                                                      gravityY40: 0,
                                                      gravityZ44: 1,
                                                      gravityMagnitude: 1,
                                                      gravityValidated: true,
                                                      candidateRR: ["k64"],
                                                      rawPayloadHex: HistoricalArchive.hex(payload),
                                                      clockDeviceRef: staleUnixBase,
                                                      clockWallRef: UInt32(start.timeIntervalSince1970),
                                                      clockDriftSeconds: rawDrift,
                                                      clockCorrectedUnix7: UInt32(Int(unix) + snappedDrift),
                                                      clockCorrectionStatus: "clock_ref_present",
                                                      currentSessionUsable: true,
                                                      metricUsable: false,
                                                      usabilityReason: "current_session_replay_ready_metric_reference_pending")
                _ = try HistoricalArchive.append(record)
            }

            let end = start.addingTimeInterval(TimeInterval((count - 1) * step))
            let diagnostics = runOffMain {
                HistoricalArchive.motionWindowDiagnostics(start: start, end: end)
            }
            XCTAssertEqual(diagnostics.status, "ready")
            XCTAssertEqual(diagnostics.reason, "bounded_historical_gravity_validated")
            XCTAssertEqual(diagnostics.validatedRows, count)
            XCTAssertGreaterThanOrEqual(diagnostics.coverageSeconds, 30 * 60)
            XCTAssertEqual(diagnostics.nearestSeparationSeconds, 0)
            XCTAssertTrue(diagnostics.lowMotionReady)
        }
    }

    func testSleepClustersSplitMorningNapAfterMainOvernight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 19_800)!
        let start = DateComponents(calendar: calendar,
                                   timeZone: calendar.timeZone,
                                   year: 2026,
                                   month: 7,
                                   day: 1,
                                   hour: 0,
                                   minute: 33).date!
        let main = savedSession(start: start,
                                duration: 8 * 60 * 60 + 13 * 60,
                                bpm: 64)
        let nap = savedSession(start: main.end.addingTimeInterval(28 * 60),
                               duration: 2 * 60 * 60 + 5 * 60,
                               bpm: 63)

        let clusters = SessionStore.sleepClusters(from: [main, nap],
                                                  maxGap: 2 * 60 * 60,
                                                  rest: 60,
                                                  calendar: calendar)

        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters.first?.count, 1)
        XCTAssertEqual(clusters.last?.count, 1)
    }

    func testSleepClassifyUsesHonestHROnlyOvernightFallback() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = DateComponents(calendar: calendar,
                                   timeZone: calendar.timeZone,
                                   year: 2026,
                                   month: 7,
                                   day: 1,
                                   hour: 22).date!

        let result = AtriaSleepWakeResearch.classify(duration: 4 * 60 * 60,
                                                     averageHR: 61,
                                                     restingHR: 52,
                                                     imuStillnessRatio: nil,
                                                     imuMovementIntensity: nil,
                                                     strapSteps: nil,
                                                     windowStart: start,
                                                     hrStandardDeviation: 4,
                                                     calendar: calendar)

        XCTAssertEqual(result.state, "sleep_research")
        XCTAssertEqual(result.confidence, "hr_only")
        XCTAssertEqual(result.reason, "hr_pattern_no_imu")
    }

    func testSleepClassifyRejectsNoisyDaytimeHROnlyWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = DateComponents(calendar: calendar,
                                   timeZone: calendar.timeZone,
                                   year: 2026,
                                   month: 7,
                                   day: 1,
                                   hour: 14).date!

        let result = AtriaSleepWakeResearch.classify(duration: 4 * 60 * 60,
                                                     averageHR: 70,
                                                     restingHR: 52,
                                                     imuStillnessRatio: nil,
                                                     imuMovementIntensity: nil,
                                                     strapSteps: nil,
                                                     windowStart: start,
                                                     hrStandardDeviation: 12,
                                                     calendar: calendar)

        XCTAssertEqual(result.state, "learning")
        XCTAssertEqual(result.confidence, "none")
        XCTAssertEqual(result.reason, "imu_missing")
    }

    func testShortOvernightHROnlyWindowDoesNotBecomeNapCandidate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 19_800)!
        let start = DateComponents(calendar: calendar,
                                   timeZone: calendar.timeZone,
                                   year: 2026,
                                   month: 7,
                                   day: 10,
                                   hour: 1,
                                   minute: 28).date!
        let duration: TimeInterval = 23 * 60 + 57
        let points = (0...23).map { index in
            SavedSession.Point(t: min(TimeInterval(index * 60), duration),
                               bpm: index == 23 ? 95 : 70)
        }
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(duration),
                                   label: "All-day wear",
                                   points: points,
                                   motionEvidenceSource: "diagnostic_observe_only",
                                   motionEvidenceValidated: false)

        let detection = session.detectedActivity(rest: 62, maxHR: 190, calendar: calendar)

        XCTAssertNotEqual(detection?.kind, .sleepCandidate,
                          "quiet awake time without validated motion must not be shown as a nap")
        XCTAssertEqual(detection?.kind, .restCandidate)
        XCTAssertTrue(SessionStore.aggregateSleepCandidates(in: [session],
                                                            rest: 62,
                                                            maxHR: 190,
                                                            calendar: calendar,
                                                            historicalMotionPolicy: .boundedRecent).isEmpty)

        let legacyNight = SleepHistorySnapshot.Night(id: "legacy-short-overnight",
                                                     day: calendar.startOfDay(for: start),
                                                     start: start,
                                                     end: start.addingTimeInterval(duration),
                                                     duration: duration,
                                                     restingHR: 62,
                                                     hrv: nil,
                                                     respiratoryRate: nil,
                                                     sleepEfficiency: nil,
                                                     confidence: "review_needed",
                                                     source: "single_session_sleep_candidate",
                                                     confirmed: false,
                                                     stageSegments: [])
        XCTAssertFalse(legacyNight.isNapEvidence,
                       "legacy overnight rollups must not recreate a false nap")
    }

    func testManualSleepInferenceSeparatesNapsFromOvernightSleep() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = DateComponents(calendar: calendar,
                                 timeZone: calendar.timeZone,
                                 year: 2026,
                                 month: 6,
                                 day: 28,
                                 hour: 14).date!
        let night = DateComponents(calendar: calendar,
                                   timeZone: calendar.timeZone,
                                   year: 2026,
                                   month: 6,
                                   day: 28,
                                   hour: 23).date!
        let shortOvernight = DateComponents(calendar: calendar,
                                            timeZone: calendar.timeZone,
                                            year: 2026,
                                            month: 6,
                                            day: 29,
                                            hour: 1,
                                            minute: 2).date!

        XCTAssertTrue(AtriaAnalytics.ManualSleep.inferredIsNap(start: day,
                                                               end: day.addingTimeInterval(45 * 60),
                                                               currentSelection: false,
                                                               calendar: calendar))
        XCTAssertFalse(AtriaAnalytics.ManualSleep.inferredIsNap(start: shortOvernight,
                                                                end: shortOvernight.addingTimeInterval(26 * 60),
                                                                currentSelection: false,
                                                                calendar: calendar),
                       "a 01:02-01:28 window should remain sleep rather than becoming a nap from duration alone")
        XCTAssertFalse(AtriaAnalytics.ManualSleep.inferredIsNap(start: night,
                                                                end: night.addingTimeInterval(7 * 60 * 60),
                                                                currentSelection: true,
                                                                calendar: calendar))
        XCTAssertFalse(AtriaAnalytics.ManualSleep.inferredIsNap(start: day,
                                                                end: day.addingTimeInterval(10 * 60),
                                                                currentSelection: false,
                                                                calendar: calendar),
                       "too-short manual windows should preserve the user's sleep/nap choice")
    }

    func testManualSleepInferenceUsesEventLocalCivilTimeWhenAvailable() {
        var kolkataCalendar = Calendar(identifier: .gregorian)
        kolkataCalendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let overnightStart = DateComponents(calendar: kolkataCalendar,
                                            timeZone: kolkataCalendar.timeZone,
                                            year: 2026,
                                            month: 6,
                                            day: 29,
                                            hour: 1,
                                            minute: 2).date!

        XCTAssertTrue(AtriaAnalytics.ManualSleep.inferredIsNap(start: overnightStart,
                                                               end: overnightStart.addingTimeInterval(26 * 60),
                                                               currentSelection: false,
                                                               calendar: utcCalendar),
                      "the fallback UTC calendar sees this interval inside the daytime window")
        XCTAssertFalse(AtriaAnalytics.ManualSleep.inferredIsNap(start: overnightStart,
                                                                end: overnightStart.addingTimeInterval(26 * 60),
                                                                currentSelection: false,
                                                                eventTimeZoneIdentifier: "Asia/Kolkata",
                                                                calendar: utcCalendar),
                       "the event's civil timezone should keep its overnight interval classified as sleep")
    }

    func testBiologicalAgeIsLocalEstimateAndClamped() {
        let factors = [
            AtriaAnalytics.BiologicalAge.factor(id: "vo2",
                                                label: "VO2max",
                                                ageEquivalent: 18,
                                                chronologicalAge: 45,
                                                weight: 0.50,
                                                detail: "strong aerobic base"),
            AtriaAnalytics.BiologicalAge.factor(id: "sleep",
                                                label: "Sleep",
                                                ageEquivalent: 20,
                                                chronologicalAge: 45,
                                                weight: 0.50,
                                                detail: "stable sleep")
        ]

        let summary = AtriaAnalytics.BiologicalAge.summary(chronologicalAge: 45, factors: factors)
        XCTAssertEqual(summary.biologicalAge, 25)
        XCTAssertEqual(summary.ageDelta, -20)
        XCTAssertEqual(summary.agingPaceText, "Younger pace")
        XCTAssertTrue(summary.footnote.lowercased().contains("estimate"))
    }

    func testBiologicalAgePaceUsesTrendDeltaWhenPresent() {
        let factors = [
            AtriaAnalytics.BiologicalAge.factor(id: "vo2",
                                                label: "VO2max",
                                                ageEquivalent: 40,
                                                chronologicalAge: 40,
                                                weight: 1,
                                                detail: "steady")
        ]

        let improving = AtriaAnalytics.BiologicalAge.summary(chronologicalAge: 40,
                                                            factors: factors,
                                                            trendDeltaYears: -1)
        let widening = AtriaAnalytics.BiologicalAge.summary(chronologicalAge: 40,
                                                          factors: factors,
                                                          trendDeltaYears: 2)

        XCTAssertEqual(improving.agingPaceText, "Improving pace")
        XCTAssertTrue(improving.agingPaceDetail.contains("cached fitness trend"))
        XCTAssertEqual(widening.agingPaceText, "Widening pace")
    }

    func testBiologicalAgeReferenceSourcesAreDocumentedLocally() {
        let footnotes = AtriaAnalytics.BiologicalAge.referenceSourceFootnotes
        let joined = footnotes.joined(separator: " ")

        XCTAssertEqual(footnotes.count, 6)
        XCTAssertTrue(joined.contains("ACSM/Cooper"))
        XCTAssertTrue(joined.contains("Resting HR"))
        XCTAssertTrue(joined.contains("RMSSD"))
        XCTAssertTrue(joined.contains("Sleep"))
        XCTAssertTrue(joined.contains("Activity"))
        XCTAssertTrue(joined.contains("BMI"))
        XCTAssertFalse(joined.localizedCaseInsensitiveContains("lifespan"))
        XCTAssertFalse(joined.localizedCaseInsensitiveContains("diagnosis"))
        XCTAssertFalse(joined.contains("http"))
    }

    func testHRVAnalyzerRequiresContinuousCleanRRWindow() {
        let now = Date()
        let cleanRR = (0...300).map { index in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: index.isMultiple(of: 2) ? 1_000 : 1_020,
                       expectedHR: 60,
                       source: .standardHeartRateMeasurement2A37)
        }

        let clean = HRVAnalyzer.analyze(cleanRR, now: now, includeTachogram: false).0
        XCTAssertEqual(clean?.readinessReason, "ready")
        XCTAssertEqual(clean?.kept, 301)
        XCTAssertEqual(clean?.rejectedOutOfRange, 0)
        XCTAssertEqual(clean?.rejectedHRMismatch, 0)
        XCTAssertTrue(clean?.isReady == true)

        let sparseRR = stride(from: 0, through: 300, by: 5).map { index in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: 1_000,
                       expectedHR: 60,
                       source: .standardHeartRateMeasurement2A37)
        }

        let sparse = HRVAnalyzer.analyze(sparseRR, now: now, includeTachogram: false).0
        XCTAssertEqual(sparse?.readinessReason, "gap")
        XCTAssertFalse(sparse?.isReady ?? true)
        XCTAssertGreaterThan(sparse?.maxRRGapSeconds ?? 0, HRVSnapshot.maxReadyRRGapSeconds)
    }

    func testHRVAnalyzerAllowsCleanFiveMinuteWindowAtFortyBPM() throws {
        let now = Date()
        let samples = (0...200).map { index in
            RRInterval(t: now.addingTimeInterval(-300 + Double(index) * 1.5),
                       ms: index.isMultiple(of: 2) ? 1_490 : 1_510,
                       expectedHR: 40,
                       source: .standardHeartRateMeasurement2A37)
        }

        let snapshot = try XCTUnwrap(
            HRVAnalyzer.analyze(samples, now: now, includeTachogram: false).0
        )

        XCTAssertEqual(snapshot.windowSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(snapshot.minimumReadyBeatCount, 150)
        XCTAssertEqual(snapshot.kept, 201)
        XCTAssertEqual(snapshot.confidence, 1, accuracy: 0.001)
        XCTAssertLessThanOrEqual(snapshot.maxRRGapSeconds, HRVSnapshot.maxReadyRRGapSeconds)
        XCTAssertEqual(snapshot.readinessReason, "ready")
        XCTAssertTrue(snapshot.isReady)
    }

    func testHRVAnalyzerCountsFirstMeasuredIntervalAtRealisticFortyBPMBoundary() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var beat = now.addingTimeInterval(-300)
        let samples = (0..<200).map { index -> RRInterval in
            let ms = index.isMultiple(of: 2) ? 1_490.0 : 1_510.0
            beat = beat.addingTimeInterval(ms / 1_000)
            return RRInterval(t: beat,
                              ms: ms,
                              expectedHR: 40,
                              source: .standardHeartRateMeasurement2A37)
        }

        let snapshot = try XCTUnwrap(
            HRVAnalyzer.analyze(samples, now: now, includeTachogram: false).0
        )

        XCTAssertEqual(snapshot.raw, 200)
        XCTAssertEqual(snapshot.kept, 200)
        XCTAssertEqual(snapshot.windowSeconds, 300, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.rmssd, 20, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.readinessReason, "ready")
        XCTAssertTrue(snapshot.isReady)
    }

    func testLowRateHRVStillRequiresArtifactConfidence() throws {
        let now = Date()
        let samples = (0...200).map { index -> RRInterval in
            let rejected = index < 51
            return RRInterval(t: now.addingTimeInterval(-300 + Double(index) * 1.5),
                              ms: rejected ? 2_100 : 1_500,
                              expectedHR: 40,
                              source: .standardHeartRateMeasurement2A37)
        }

        let snapshot = try XCTUnwrap(
            HRVAnalyzer.analyze(samples, now: now, includeTachogram: false).0
        )

        XCTAssertEqual(snapshot.kept, 150)
        XCTAssertLessThan(snapshot.confidence, 0.75)
        XCTAssertFalse(snapshot.isReady)
        XCTAssertEqual(snapshot.readinessReason, "confidence")
    }

    func testHRVAnalyzerDoesNotCascadeRejectAfterEarlyArtifact() {
        let now = Date()
        var values = (0...300).map { index in
            index.isMultiple(of: 2) ? 1_000.0 : 1_040.0
        }
        values[0] = 480
        values[1] = 830
        values[10] = 520
        values[11] = 610

        let samples = values.enumerated().map { index, value in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: value,
                       expectedHR: nil,
                       source: .standardHeartRateMeasurement2A37)
        }

        let snapshot = HRVAnalyzer.analyze(samples, now: now, includeTachogram: false).0
        XCTAssertEqual(snapshot?.readinessReason, "ready")
        XCTAssertGreaterThanOrEqual(snapshot?.kept ?? 0, 295)
        XCTAssertLessThanOrEqual(snapshot?.rejectedDeltaOver20Percent ?? 999, 4)
        XCTAssertTrue(snapshot?.isReady == true)
    }

    func testHRVAnalyzerRejectsOutOfRangeAndHeartRateMismatch() {
        let now = Date()
        var samples = (0...300).map { index in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: 1_000,
                       expectedHR: 60,
                       source: .standardHeartRateMeasurement2A37)
        }
        samples[20] = RRInterval(t: samples[20].t, ms: 250, expectedHR: 60,
                                 source: .standardHeartRateMeasurement2A37)
        samples[40] = RRInterval(t: samples[40].t, ms: 2_100, expectedHR: 60,
                                 source: .standardHeartRateMeasurement2A37)
        samples[60] = RRInterval(t: samples[60].t, ms: 1_000, expectedHR: 120,
                                 source: .standardHeartRateMeasurement2A37)

        let snapshot = HRVAnalyzer.analyze(samples, now: now, includeTachogram: false).0
        XCTAssertEqual(snapshot?.rejectedOutOfRange, 2)
        XCTAssertEqual(snapshot?.rejectedHRMismatch, 1)
        XCTAssertEqual(snapshot?.kept, 298)
        XCTAssertTrue(snapshot?.isReady == true)
    }

    func testHRVAnalyzerNeverBridgesAcrossRejectedBeat() throws {
        let now = Date()
        var samples = (0...300).map { index in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: 1_000,
                       expectedHR: nil,
                       source: .standardHeartRateMeasurement2A37)
        }
        samples[149] = RRInterval(t: samples[149].t, ms: 920, expectedHR: nil,
                                  source: .standardHeartRateMeasurement2A37)
        samples[150] = RRInterval(t: samples[150].t, ms: 250, expectedHR: nil,
                                  source: .standardHeartRateMeasurement2A37)
        samples[151] = RRInterval(t: samples[151].t, ms: 1_080, expectedHR: nil,
                                  source: .standardHeartRateMeasurement2A37)

        let snapshot = try XCTUnwrap(HRVAnalyzer.analyze(samples,
                                                         now: now,
                                                         includeTachogram: false).0)
        let validAdjacentPairCount = 298.0
        XCTAssertEqual(snapshot.rejectedOutOfRange, 1)
        XCTAssertEqual(snapshot.successiveDifferenceCount, Int(validAdjacentPairCount))
        XCTAssertEqual(snapshot.rmssd, sqrt((80 * 80 * 2) / validAdjacentPairCount), accuracy: 0.000_001)
        XCTAssertEqual(snapshot.pnn50, 2 / validAdjacentPairCount * 100, accuracy: 0.000_001)
        XCTAssertTrue(snapshot.isReady)
    }

    func testHRVReadinessRejectsSparseIslandsDespiteEnoughRetainedBeats() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let samples = (0..<400).map { index in
            RRInterval(t: now.addingTimeInterval(-300 + Double(index) * 300 / 399),
                       ms: index.isMultiple(of: 4) ? 250 : (index.isMultiple(of: 2) ? 1_000 : 1_020),
                       expectedHR: nil,
                       source: .standardHeartRateMeasurement2A37)
        }

        let snapshot = try XCTUnwrap(HRVAnalyzer.analyze(samples,
                                                         now: now,
                                                         includeTachogram: false).0)

        XCTAssertEqual(snapshot.kept, 300)
        XCTAssertEqual(snapshot.confidence, 0.75, accuracy: 0.000_001)
        XCTAssertLessThan(snapshot.successiveDifferenceCount ?? .max,
                          snapshot.minimumReadySuccessiveDifferenceCount)
        XCTAssertEqual(snapshot.readinessReason, "differences")
        XCTAssertFalse(snapshot.isReady)
    }

    func testSavedSessionRMSSDNeverBridgesRejectedIntervals() throws {
        var samples = (0...300).map { index in
            (t: Double(index), ms: 1_000.0)
        }
        samples[149].ms = 920
        samples[150].ms = 250
        samples[151].ms = 1_080

        let lnRMSSD = try XCTUnwrap(SavedSession.qualifiedLnRMSSD(samples))
        XCTAssertEqual(exp(lnRMSSD), sqrt((80 * 80 * 2) / 298.0), accuracy: 0.000_001)
    }

    func testSavedSessionRMSSDRejectsSparseAcceptedIslands() {
        let samples = (0..<400).map { index in
            (t: Double(index),
             ms: index.isMultiple(of: 4) ? 250.0 : (index.isMultiple(of: 2) ? 1_000.0 : 1_020.0))
        }

        XCTAssertNil(SavedSession.qualifiedLnRMSSD(samples))
    }

    func testSavedSessionRMSSDAcceptsCleanFiveMinuteWindowAtFortyBPM() throws {
        let samples = (0...200).map { index in
            (t: Double(index) * 1.5,
             ms: index.isMultiple(of: 2) ? 1_480.0 : 1_520.0)
        }

        let lnRMSSD = try XCTUnwrap(SavedSession.qualifiedLnRMSSD(samples))
        XCTAssertEqual(exp(lnRMSSD), 40, accuracy: 0.000_001)
    }

    func testSavedSessionRMSSDAcceptsRealisticFortyBPMBeatBoundaries() throws {
        var beat = 0.0
        let samples = (0..<200).map { index -> (t: Double, ms: Double) in
            let ms = index.isMultiple(of: 2) ? 1_490.0 : 1_510.0
            beat += ms / 1_000
            return (t: beat, ms: ms)
        }

        let lnRMSSD = try XCTUnwrap(SavedSession.qualifiedLnRMSSD(samples))
        XCTAssertEqual(exp(lnRMSSD), 20, accuracy: 0.000_001)
    }

    func testSavedSessionRMSSDRejectsDenseButShortWindow() {
        let samples = (0..<200).map { index in
            (t: Double(index) * 0.5,
             ms: index.isMultiple(of: 2) ? 980.0 : 1_020.0)
        }

        XCTAssertNil(SavedSession.qualifiedLnRMSSD(samples))
    }

    func testShortWindowRMSSDRejectsDisconnectedRRIslands() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let samples = (0..<100).map { index in
            let offset = index < 50 ? Double(index) : Double(index + 10)
            return (date: start.addingTimeInterval(offset),
                    ms: index.isMultiple(of: 2) ? 980.0 : 1_020.0)
        }

        XCTAssertNil(AtriaShortWindowRMSSD.value(samples: samples,
                                                  minimumCoverageSeconds: 90))
    }

    func testShortWindowRMSSDNeverInventsCoverageAfterLastBeat() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let samples = (0...89).map { index in
            (date: start.addingTimeInterval(Double(index)),
             ms: index == 0 ? 300.0 : (index.isMultiple(of: 2) ? 1_980.0 : 2_000.0))
        }

        XCTAssertNil(AtriaShortWindowRMSSD.value(samples: samples,
                                                  minimumCoverageSeconds: 90))
    }

    func testShortWindowRMSSDDoesNotBridgeRejectedArtifact() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var samples = (0...100).map { index in
            (date: start.addingTimeInterval(Double(index)),
             ms: index.isMultiple(of: 2) ? 980.0 : 1_020.0)
        }
        samples[50].ms = 1_900

        let rmssd = try XCTUnwrap(AtriaShortWindowRMSSD.value(samples: samples,
                                                              minimumCoverageSeconds: 90))
        XCTAssertEqual(rmssd, 40, accuracy: 0.000_001)
    }

    func testReferenceRMSSDNeverBridgesOrdinalGap() throws {
        XCTAssertNil(SessionStore.referenceRMSSD([
            (ordinal: 149, value: 920),
            (ordinal: 151, value: 1_080)
        ]))
        XCTAssertEqual(try XCTUnwrap(SessionStore.referenceRMSSD([
            (ordinal: 149, value: 920),
            (ordinal: 150, value: 1_000),
            (ordinal: 151, value: 1_080)
        ])), 80, accuracy: 0.000_001)
    }

    func testSavedRRReferenceWindowRejectsSparseAcceptedIslands() {
        let end = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = HRVSnapshot(rmssd: 20,
                                   sdnn: 30,
                                   pnn50: 5,
                                   lnRMSSD: log(20),
                                   confidence: 0.75,
                                   kept: 300,
                                   raw: 400,
                                   rejectedOutOfRange: 100,
                                   rejectedDeltaOver20Percent: 0,
                                   rejectedHRMismatch: 0,
                                   interpolated: 0,
                                   successiveDifferenceCount: 200,
                                   windowSeconds: 300,
                                   maxRRGapSeconds: 1,
                                   respiratoryRate: nil,
                                   measurementStart: end.addingTimeInterval(-300),
                                   measurementEnd: end,
                                   analyzedAt: end,
                                   provenance: .sleepRRWindow)

        XCTAssertFalse(SessionStore.savedRRReferenceWindowIsReady(snapshot: snapshot,
                                                                   strictGap: 1))
        XCTAssertEqual(SessionStore.replayReason(snapshot: snapshot, strictGap: 1),
                       "differences")
    }

    func testLegacySourceAmbiguousValidatedSessionCannotExposeSDNN() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let rrPoints = (0...300).map { SavedSession.RRPoint(t: Double($0), ms: 1_000) }
        let legacy = SavedSession(id: UUID(),
                                  start: start,
                                  end: start.addingTimeInterval(300),
                                  label: "Legacy",
                                  points: [SavedSession.Point(t: 0, bpm: 60)],
                                  rrPoints: rrPoints,
                                  hrvReferenceValidated: true)
        var bounded = legacy
        bounded.hrvSDNN = 42

        XCTAssertNil(legacy.referenceValidatedSDNN)
        XCTAssertNil(bounded.referenceValidatedSDNN)
    }

    func testSavedRRProvenanceRoundTripAndMixedMetricGate() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let standardPoint = SavedSession.RRPoint(
            t: 1,
            ms: 1_000,
            source: .standardHeartRateMeasurement2A37
        )
        let decoded = try JSONDecoder().decode(
            SavedSession.RRPoint.self,
            from: JSONEncoder().encode(standardPoint)
        )
        XCTAssertEqual(decoded.source, .standardHeartRateMeasurement2A37)

        let qualifiedStandardPoints = (0...900).map { index in
            SavedSession.RRPoint(
                t: Double(index),
                ms: index.isMultiple(of: 2) ? 980 : 1_020,
                source: .standardHeartRateMeasurement2A37
            )
        }
        let standard = SavedSession(
            id: UUID(), start: start, end: start.addingTimeInterval(300), label: "Standard",
            points: [SavedSession.Point(t: 0, bpm: 60)], hrv: 42,
            respiratoryRate: 14,
            rrPoints: qualifiedStandardPoints
        )
        let legacy = SavedSession(
            id: UUID(), start: start, end: start.addingTimeInterval(300), label: "Legacy",
            points: [SavedSession.Point(t: 0, bpm: 60)], hrv: 42,
            respiratoryRate: 14,
            rrPoints: [SavedSession.RRPoint(t: 1, ms: 1_000)],
            sleepWakeResearchState: "sleep_research"
        )
        let mixed = SavedSession(
            id: UUID(), start: start, end: start.addingTimeInterval(300), label: "Mixed",
            points: [SavedSession.Point(t: 0, bpm: 60)], hrv: 42,
            respiratoryRate: 14,
            rrPoints: [standardPoint,
                       SavedSession.RRPoint(t: 2, ms: 1_000,
                                            source: .validatedProprietaryRealtime)],
            sleepWakeResearchState: "sleep_research"
        )

        XCTAssertEqual(standard.localRMSSD, 42)
        XCTAssertNil(legacy.localRMSSD)
        XCTAssertNil(mixed.localRMSSD)
        XCTAssertNil(legacy.sleepRespiratoryRate(rest: 55, maxHR: 190))
        XCTAssertNil(mixed.sleepRespiratoryRate(rest: 55, maxHR: 190))
    }

    func testLiveHRVAnalyzerRejectsLegacyAndMixedSourceWindows() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let legacy = (0...300).map { index in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: index.isMultiple(of: 2) ? 1_000 : 1_020,
                       expectedHR: 60)
        }
        var mixed = legacy.map {
            RRInterval(t: $0.t, ms: $0.ms, expectedHR: $0.expectedHR,
                       source: .standardHeartRateMeasurement2A37)
        }
        mixed[150] = RRInterval(t: mixed[150].t,
                                ms: mixed[150].ms,
                                expectedHR: mixed[150].expectedHR,
                                source: .validatedProprietaryRealtime)

        XCTAssertNil(HRVAnalyzer.analyze(legacy, now: now, includeTachogram: false).0)
        XCTAssertNil(HRVAnalyzer.analyze(mixed, now: now, includeTachogram: false).0)
    }

    func testSuccessiveDifferenceHelperPreservesCleanAlternation() {
        let accepted = (0..<6).map { index in
            (ordinal: index, value: index.isMultiple(of: 2) ? 1_000.0 : 1_040.0)
        }
        XCTAssertEqual(AtriaHRVSuccessiveDifferences.adjacentValues(accepted), [40, -40, 40, -40, 40])
    }

    func testRecoveryHonestButPresentForThinAndStaleBaselines() {
        // docs/24 honesty rule (line 19): "No fabricated data. Estimates are
        // labeled estimates. Confidence tiers stay honest." The primary-device
        // audit (commit ac1a820f) deliberately moved recovery from blank-refusal
        // toward HONEST-BUT-PRESENT: when only a raw restingHR/hrvEMA baseline
        // exists (thin history, or a fully-stale baseline), recovery still scores
        // but is clamped to the .unverified confidence tier. It never reaches
        // .personalBaseline/.validated without a trusted, fresh baseline, so the
        // confidence tier stays honest. Fail-closed still holds when there is NO
        // resting baseline at all (see the third case below).
        let now = Date()
        let thinBaseline = PersonalBaseline(restingHR: 60,
                                            hrvEMA: 50,
                                            sessions: 3,
                                            updated: now,
                                            samples: baselineSamples(count: 3, now: now))

        let thin = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                    fallbackRMSSD: 55,
                                                    restingNow: 58,
                                                    baseline: thinBaseline,
                                                    sleepEfficiency: 0.90,
                                                    sleepDurationHours: 7.5)
        // Thin (< trustedMinimumSamples fresh days) still scores off the raw
        // restingHR EMA + provisional HRV, labeled honestly as unverified.
        XCTAssertNotNil(thin.percent)
        XCTAssertEqual(thin.confidence, .unverified)
        XCTAssertTrue(thin.usesHRV)

        let staleDate = now.addingTimeInterval(-(PersonalBaseline.staleAfter + 86_400))
        let staleBaseline = PersonalBaseline(restingHR: 60,
                                             hrvEMA: 50,
                                             sessions: PersonalBaseline.trustedMinimumSamples,
                                             updated: staleDate,
                                             samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                      now: staleDate))
        let stale = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                     fallbackRMSSD: 55,
                                                     restingNow: 58,
                                                     baseline: staleBaseline,
                                                     sleepEfficiency: 0.90,
                                                     sleepDurationHours: 7.5)
        // Every sample is older than staleAfter, so hasTrustedRestingBaseline is
        // false and confidence can never be promoted past .unverified. The score
        // still comes off the last-known personal EMA, clearly labeled unverified.
        XCTAssertNotNil(stale.percent)
        XCTAssertEqual(stale.confidence, .unverified)

        // Fail-closed guardrail: with NO resting baseline at all there is nothing
        // honest to anchor to, so recovery must refuse (blank + .learning).
        let noRestingBaseline = PersonalBaseline(restingHR: nil,
                                                 hrvEMA: 50,
                                                 sessions: 3,
                                                 updated: now,
                                                 samples: [])
        let refused = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                       fallbackRMSSD: 55,
                                                       restingNow: 58,
                                                       baseline: noRestingBaseline,
                                                       sleepEfficiency: 0.90,
                                                       sleepDurationHours: 7.5)
        XCTAssertNil(refused.percent)
        XCTAssertEqual(refused.confidence, .learning)
        XCTAssertFalse(refused.usesHRV)
    }

    private static func journalDays(_ recoveries: [Int?], startingAt start: Date, calendar: Calendar) -> [AtriaBehaviorImpact.Day] {
        recoveries.enumerated().map { index, recovery in
            AtriaBehaviorImpact.Day(day: calendar.date(byAdding: .day, value: index, to: start) ?? start,
                                    recoveryPercent: recovery)
        }
    }

    func testJournalSpearmanPerfectMonotone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let recoveries = [40, 45, 50, 55, 60, 65, 70, 75]
        let days = Self.journalDays(recoveries, startingAt: start, calendar: calendar)
        let answers = (0..<8).map { index in
            AtriaJournalInsights.AnswerDay(day: calendar.date(byAdding: .day, value: index, to: start)!,
                                           value: .quantity(Double(index + 1)))
        }
        let insights = AtriaJournalInsights.insights(questionAnswers: ["q": answers],
                                                     days: days,
                                                     referenceDate: days.last?.day,
                                                     calendar: calendar)
        guard case .rankCorrelation(let rho, let count, let p)? = insights.first?.kind else {
            return XCTFail("expected rank correlation insight")
        }
        XCTAssertEqual(rho, 1.0, accuracy: 1e-9)
        XCTAssertEqual(count, 8)
        XCTAssertLessThanOrEqual(p, 0.01)
    }

    func testJournalSpearmanHandlesTies() {
        let x: [Double] = [1, 1, 2, 2, 3, 3, 4, 4]
        let y: [Double] = [50, 52, 55, 54, 60, 58, 64, 66]
        let insight = AtriaJournalInsights.rankCorrelationInsight(questionID: "ties",
                                                                  label: "ties",
                                                                  pairs: Array(zip(x, y).map { (x: $0, y: $1) }))
        guard case .rankCorrelation(let rho, _, _)? = insight?.kind else {
            return XCTFail("expected rank correlation insight")
        }
        // Tie-exact Pearson-on-average-ranks value; the 6Σd² shortcut gives a
        // different number, so this pins the correct formula.
        XCTAssertEqual(rho, 0.97590007294853, accuracy: 1e-6)
    }

    func testJournalThresholdSplitFindsAfternoonCaffeine() {
        let minutes = [480, 510, 540, 600, 660, 720, 840, 900, 930, 960, 1020, 1080, 1140, 1200]
        let recoveries: [Double] = [70, 71, 69, 72, 70, 68, 71, 58, 57, 60, 59, 56, 58, 57]
        let insight = AtriaJournalInsights.thresholdSplitInsight(questionID: "caffeine.lastTime",
                                                                 label: "Caffeine",
                                                                 pairs: Array(zip(minutes, recoveries).map { (minutes: $0, recovery: $1) }))
        guard case .thresholdSplit(let split, let delta, let earlier, let later, let adjusted)? = insight?.kind else {
            return XCTFail("expected threshold split insight")
        }
        XCTAssertEqual(split, 870)
        XCTAssertEqual(delta, -12.2857142857, accuracy: 1e-6)
        XCTAssertEqual(earlier, 7)
        XCTAssertEqual(later, 7)
        XCTAssertLessThan(adjusted, 0.001)
        XCTAssertTrue(insight?.valueText.contains("2:30 PM") == true)
        XCTAssertTrue(insight?.valueText.contains("7 vs 7 days") == true)
    }

    func testJournalInsightsSuppressUnderpoweredInputs() {
        // (a) too few correlation pairs
        let sevenPairs = (0..<7).map { (x: Double($0), y: Double(50 + $0)) }
        XCTAssertNil(AtriaJournalInsights.rankCorrelationInsight(questionID: "a", label: "a", pairs: sevenPairs))
        // (b) constant answers — rank spread degenerate
        let constant = (0..<8).map { (x: 3.0, y: Double(50 + $0)) }
        XCTAssertNil(AtriaJournalInsights.rankCorrelationInsight(questionID: "b", label: "b", pairs: constant))
        // (c) threshold split with a side that can never reach 5 days
        let lopsided = (0..<10).map { (minutes: 480, recovery: 70.0 - Double($0 % 2)) }
            + (0..<4).map { (minutes: 1200, recovery: 58.0 + Double($0 % 2)) }
        XCTAssertNil(AtriaJournalInsights.thresholdSplitInsight(questionID: "c", label: "c", pairs: lopsided))
        // (d) 11 total days is below the minimum
        let eleven = (0..<11).map { (minutes: 480 + $0 * 60, recovery: 60.0 + Double($0)) }
        XCTAssertNil(AtriaJournalInsights.thresholdSplitInsight(questionID: "d", label: "d", pairs: Array(eleven.prefix(11))))
    }

    func testHRVBaselineRampIsContinuousAcrossOvernightThreshold() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func baseline(overnightCount: Int) -> PersonalBaseline {
            var samples: [PersonalBaseline.BaselineSample] = []
            for index in 0..<overnightCount {
                samples.append(PersonalBaseline.BaselineSample(date: now.addingTimeInterval(-Double(index) * 24 * 3_600),
                                                               restingHR: 55,
                                                               rmssd: 62,
                                                               overnight: true))
            }
            for index in 0..<6 {
                samples.append(PersonalBaseline.BaselineSample(date: now.addingTimeInterval(-Double(index + overnightCount) * 24 * 3_600),
                                                               restingHR: 58,
                                                               rmssd: 30,
                                                               overnight: false))
            }
            return PersonalBaseline(restingHR: 56, hrvEMA: 55, sessions: samples.count, updated: now, samples: samples)
        }
        let sixStats = try XCTUnwrap(baseline(overnightCount: 6).lnRMSSDStats(now: now))
        let sevenStats = try XCTUnwrap(baseline(overnightCount: 7).lnRMSSDStats(now: now))
        // Old cliff: 6 overnight used the all-12 mean (3.764); 7 overnight jumped to
        // ln(62)=4.127 — a 0.363 step. The ramp blends at w=6/7 so the final step is
        // only the last 1/7 of the gap.
        XCTAssertEqual(sixStats.mean, 4.0754, accuracy: 0.001)
        XCTAssertEqual(sevenStats.mean, log(62.0), accuracy: 0.001)
        XCTAssertLessThan(abs(sevenStats.mean - sixStats.mean), 0.06)
        XCTAssertEqual(sevenStats.count, 7)
        XCTAssertEqual(sixStats.count, 12)
    }

    func testRecoveryUsesTrustedBaselineAndSleepEvidence() {
        let now = Date()
        let baseline = PersonalBaseline(restingHR: 60,
                                        hrvEMA: 50,
                                        sessions: PersonalBaseline.trustedMinimumSamples,
                                        updated: now,
                                        samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                 now: now))

        let estimate = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                        fallbackRMSSD: 56,
                                                        restingNow: 58,
                                                        baseline: baseline,
                                                        hrvReferenceValidated: false,
                                                        sleepEfficiency: 0.91,
                                                        sleepDurationHours: 7.6)

        XCTAssertNotNil(estimate.percent)
        XCTAssertEqual(estimate.confidence, .personalBaseline)
        XCTAssertTrue(estimate.usesHRV)
        XCTAssertTrue((1...99).contains(estimate.percent ?? 0))
        XCTAssertTrue(estimate.detail.contains("lnRMSSD z"))
    }

    func testRecoveryWithoutCurrentHRVUsesLimitedEvidenceAndNeverBaselineHRVAsMeasurement() {
        let now = Date()
        let baseline = PersonalBaseline(restingHR: 60,
                                        hrvEMA: 50,
                                        sessions: PersonalBaseline.trustedMinimumSamples,
                                        updated: now,
                                        samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                 now: now))

        let estimate = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                        fallbackRMSSD: nil,
                                                        restingNow: 58,
                                                        baseline: baseline,
                                                        sleepEfficiency: 0.91,
                                                        sleepDurationHours: 7.6)

        XCTAssertNotNil(estimate.percent)
        XCTAssertEqual(estimate.confidence, .unverified)
        XCTAssertFalse(estimate.usesHRV)
        XCTAssertTrue(estimate.detail.contains("HRV unavailable"))
        let hrv = estimate.contributors.first { $0.kind == .hrv }
        XCTAssertEqual(hrv?.weight, 0)
        XCTAssertEqual(hrv?.displayValue, "HRV unavailable")
        XCTAssertFalse(estimate.contributors.contains {
            $0.kind == .hrv && $0.displayValue.contains("50")
        }, "the saved baseline must never masquerade as today's HRV")
    }

    func testDayOneRecoveryCanUseMeasuredSleepBeforeAnyPersonalBaselineExists() {
        let estimate = AtriaAnalytics.Recovery.estimate(
            hrvSnapshot: nil,
            fallbackRMSSD: nil,
            restingNow: nil,
            baseline: PersonalBaseline(),
            sleepEfficiency: 0.88,
            sleepDurationHours: 6.25
        )

        XCTAssertNotNil(estimate.percent)
        XCTAssertEqual(estimate.confidence, .unverified)
        XCTAssertFalse(estimate.usesHRV)
        XCTAssertTrue(estimate.detail.contains("Limited confidence"))
        XCTAssertEqual(estimate.contributors.first(where: { $0.kind == .sleep })?.weight,
                       0.75)
    }

    func testRecoveryCanPublishRHRLimitedEstimateWhenSleepAndHRVAreUnavailable() {
        let estimate = AtriaAnalytics.Recovery.estimate(
            hrvSnapshot: nil,
            fallbackRMSSD: nil,
            restingNow: 58,
            baseline: PersonalBaseline(restingHR: 60),
            sleepEfficiency: nil,
            sleepDurationHours: nil
        )

        XCTAssertNotNil(estimate.percent)
        XCTAssertEqual(estimate.confidence, .unverified)
        XCTAssertFalse(estimate.usesHRV)
        // Migrated 2026-07-31 (device review): plain-language detail copy.
        XCTAssertTrue(estimate.detail.contains("resting HR only"))
        XCTAssertEqual(estimate.contributors.first(where: { $0.kind == .restingHeartRate })?.weight,
                       0.20)
        XCTAssertEqual(estimate.contributors.first(where: { $0.kind == .sleep })?.weight,
                       0)
    }

    func testRHROnlyRecoveryCannotBecomeNearCertainWithoutSleepOrHRV() {
        let estimate = AtriaAnalytics.Recovery.estimate(
            hrvSnapshot: nil,
            fallbackRMSSD: nil,
            restingNow: 54,
            baseline: PersonalBaseline(restingHR: 66),
            sleepEfficiency: nil,
            sleepDurationHours: nil
        )

        XCTAssertEqual(estimate.confidence, .unverified)
        XCTAssertNotNil(estimate.percent)
        XCTAssertLessThanOrEqual(estimate.percent ?? 100, 80,
                                 "one secondary signal must not present near-certain recovery")
        XCTAssertGreaterThan(estimate.percent ?? 0, 50,
                             "a genuinely low resting HR should still move the day-one estimate")
    }

    func testRecoveryContributorsExposeHelpfulHRVAndRestingDirections() {
        let now = Date()
        let baseline = PersonalBaseline(restingHR: 60,
                                        hrvEMA: 50,
                                        sessions: PersonalBaseline.trustedMinimumSamples,
                                        updated: now,
                                        samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                 now: now))

        let estimate = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                        fallbackRMSSD: 70,
                                                        restingNow: 55,
                                                        baseline: baseline,
                                                        hrvReferenceValidated: false,
                                                        sleepEfficiency: 0.92,
                                                        sleepDurationHours: 7.7,
                                                        respiratoryRate: 14.2)

        let hrv = estimate.contributors.first { $0.kind == .hrv }
        let resting = estimate.contributors.first { $0.kind == .restingHeartRate }

        XCTAssertEqual(hrv?.direction, 1)
        XCTAssertEqual(resting?.direction, 1)
        XCTAssertEqual(hrv?.displayValue, "HRV \(String(format: "%+.1fσ", hrv?.zScore ?? 0))")
        XCTAssertEqual(resting?.displayValue, "Resting HR \(String(format: "%+.1fσ", resting?.zScore ?? 0))")
    }

    func testRecoveryExcludesUnavailableRespirationInsteadOfInjectingNeutralWeight() {
        let now = Date()
        let baseline = PersonalBaseline(
            restingHR: 60,
            hrvEMA: 50,
            sessions: PersonalBaseline.trustedMinimumSamples,
            updated: now,
            samples: baselineSamples(
                count: PersonalBaseline.trustedMinimumSamples,
                now: now
            )
        )

        let estimate = AtriaAnalytics.Recovery.estimate(
            hrvSnapshot: nil,
            fallbackRMSSD: 56,
            restingNow: 58,
            baseline: baseline,
            sleepEfficiency: 0.91,
            sleepDurationHours: 7.6,
            respiratoryRate: nil,
            respiratoryBaseline: nil
        )

        let respiration = estimate.contributors.first { $0.kind == .respiration }
        XCTAssertEqual(respiration?.weight, 0)
        XCTAssertEqual(respiration?.displayValue, "Respiration unavailable")
        XCTAssertEqual(
            estimate.contributors.reduce(0) { $0 + $1.weight },
            1,
            accuracy: 0.000_001
        )
    }

    func testCurrentHRVWithoutComparatorDoesNotOwnSixtyPercentOfRecovery() {
        let now = Date()
        let restingOnlySamples = (0..<PersonalBaseline.trustedMinimumSamples).map { index in
            PersonalBaseline.BaselineSample(
                date: now.addingTimeInterval(Double(-index * 86_400)),
                restingHR: [58.0, 60.0, 62.0][index % 3],
                rmssd: nil,
                overnight: true
            )
        }
        let baseline = PersonalBaseline(
            restingHR: 60,
            hrvEMA: nil,
            sessions: restingOnlySamples.count,
            updated: now,
            samples: restingOnlySamples
        )

        let estimate = AtriaAnalytics.Recovery.estimate(
            hrvSnapshot: nil,
            fallbackRMSSD: 56,
            restingNow: 58,
            baseline: baseline,
            sleepEfficiency: 0.91,
            sleepDurationHours: 7.6
        )

        XCTAssertFalse(estimate.usesHRV)
        XCTAssertEqual(
            estimate.contributors.first { $0.kind == .hrv }?.weight,
            0
        )
        XCTAssertTrue(estimate.detail.contains("HRV unavailable"))
    }

    func testSleepBudgetNeedCapsFloorsStrainAndNapCredit() {
        XCTAssertEqual(AtriaSleepBudget.sleepNeed(baseHours: 11,
                                                  yesterdayStrain: 16,
                                                  debtHours: 4,
                                                  sameDayNapHours: 0),
                       10)
        XCTAssertEqual(AtriaSleepBudget.sleepNeed(baseHours: 5,
                                                  yesterdayStrain: nil,
                                                  debtHours: 0,
                                                  sameDayNapHours: 2),
                       6)
        // 2026-07-07: strain adder is continuous and WHOOP-anchored (~0 at
        // strain 8, +37 min at the published 15-strain anchor) instead of the
        // old binary "+30 min at strain >= 14" step.
        XCTAssertEqual(AtriaSleepBudget.sleepNeed(baseHours: 8,
                                                  yesterdayStrain: 15.0,
                                                  debtHours: 0,
                                                  sameDayNapHours: 0),
                       8.62,
                       accuracy: 0.0001)
        XCTAssertEqual(AtriaSleepBudget.sleepNeed(baseHours: 8,
                                                  yesterdayStrain: 8.0,
                                                  debtHours: 0,
                                                  sameDayNapHours: 0),
                       8.0)
        XCTAssertEqual(AtriaSleepBudget.sleepNeed(baseHours: 8,
                                                  yesterdayStrain: nil,
                                                  debtHours: 2,
                                                  sameDayNapHours: 0.5),
                       8.55,
                       accuracy: 0.0001)
    }

    func testSleepPerformanceZoneUsesAdaptiveNeedBands() throws {
        let low = try XCTUnwrap(Metrics.sleepPerformanceZone(69, neededHours: 10))
        XCTAssertEqual(low.level, .red)
        XCTAssertTrue(low.current.contains("10 h"))
        XCTAssertEqual(Metrics.sleepPerformanceZone(70)?.level, .yellow)
        XCTAssertEqual(Metrics.sleepPerformanceZone(84)?.level, .yellow)
        XCTAssertEqual(Metrics.sleepPerformanceZone(85)?.level, .green)
        XCTAssertEqual(Metrics.sleepPerformanceZone(100)?.level, .green)
        XCTAssertNil(Metrics.sleepPerformanceZone(nil))
    }

    func testNapRecoveryLiftNeverLowersMorningRecovery() {
        let lowerNap = AtriaNapRecovery.adjustedRecovery(morningRecovery: 70,
                                                         morningLnRMSSD: log(60),
                                                         napLnRMSSD: log(50),
                                                         napDurationHours: 1.0,
                                                         qualifyingHRVWindows: 3)
        XCTAssertEqual(lowerNap.percent, 70)
        XCTAssertFalse(lowerNap.lifted)

        let thinNap = AtriaNapRecovery.adjustedRecovery(morningRecovery: 70,
                                                        morningLnRMSSD: log(60),
                                                        napLnRMSSD: log(80),
                                                        napDurationHours: 0.5,
                                                        qualifyingHRVWindows: 3)
        XCTAssertEqual(thinNap.percent, 70)
        XCTAssertFalse(thinNap.lifted)

        let liftedNap = AtriaNapRecovery.adjustedRecovery(morningRecovery: 70,
                                                          morningLnRMSSD: log(60),
                                                          napLnRMSSD: log(90),
                                                          napDurationHours: 1.0,
                                                          qualifyingHRVWindows: 3)
        XCTAssertGreaterThan(liftedNap.percent ?? 0, 70)
        XCTAssertTrue(liftedNap.lifted)
    }

    func testSleepHistoryNapRecoveryRequiresQualifyingHRVWindows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let main = SleepHistorySnapshot.Night(id: "main",
                                              day: day,
                                              start: day.addingTimeInterval(23 * 60 * 60),
                                              end: day.addingTimeInterval(30 * 60 * 60),
                                              duration: 7 * 3_600,
                                              restingHR: 56,
                                              hrv: 60,
                                              hrvWindowCount: 4,
                                              respiratoryRate: nil,
                                              sleepEfficiency: nil,
                                              confidence: "confirmed",
                                              source: "manual_sleep",
                                              confirmed: true,
                                              stageSegments: [])
        let undercountedNap = SleepHistorySnapshot.Night(id: "nap-low-windows",
                                                         day: day,
                                                         start: day.addingTimeInterval(13 * 60 * 60),
                                                         end: day.addingTimeInterval(14 * 60 * 60),
                                                         duration: 3_600,
                                                         restingHR: nil,
                                                         hrv: 90,
                                                         hrvWindowCount: 2,
                                                         respiratoryRate: nil,
                                                         sleepEfficiency: nil,
                                                         confidence: "confirmed",
                                                         source: "manual_nap",
                                                         confirmed: true,
                                                         stageSegments: [])
        let qualifiedNap = SleepHistorySnapshot.Night(id: "nap-qualified",
                                                      day: day,
                                                      start: day.addingTimeInterval(15 * 60 * 60),
                                                      end: day.addingTimeInterval(16 * 60 * 60),
                                                      duration: 3_600,
                                                      restingHR: nil,
                                                      hrv: 92,
                                                      hrvWindowCount: 3,
                                                      respiratoryRate: nil,
                                                      sleepEfficiency: nil,
                                                      confidence: "confirmed",
                                                      source: "manual_nap",
                                                      confirmed: true,
                                                      stageSegments: [])

        let lowWindowSnapshot = SleepHistorySnapshot(nights: [main, undercountedNap],
                                                     confirmedCount: 2,
                                                     candidateCount: 0)
        let lowWindowResult = lowWindowSnapshot.napAdjustedRecovery(morningRecovery: 70,
                                                                    for: main,
                                                                    calendar: calendar)
        XCTAssertEqual(lowWindowResult.percent, 70)
        XCTAssertFalse(lowWindowResult.lifted)

        let qualifiedSnapshot = SleepHistorySnapshot(nights: [main, undercountedNap, qualifiedNap],
                                                     confirmedCount: 3,
                                                     candidateCount: 0)
        let qualifiedResult = qualifiedSnapshot.napAdjustedRecovery(morningRecovery: 70,
                                                                    for: main,
                                                                    calendar: calendar)
        XCTAssertGreaterThan(qualifiedResult.percent ?? 0, 70)
        XCTAssertTrue(qualifiedResult.lifted)
    }

    func testBehaviorImpactReportsWelchGatedNextMorningRecovery() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let recovery = [70, 71, 69, 70, 72, 58, 57, 59, 56, 58, 71, 70, 72, 69]
        let days = recovery.enumerated().map { offset, value in
            AtriaBehaviorImpact.Day(day: calendar.date(byAdding: .day, value: offset, to: start)!,
                                    recoveryPercent: value)
        }
        let journalEntries = (5..<10).map { offset in
            BehaviorJournalEntry(id: "stress-\(offset)",
                                 day: calendar.date(byAdding: .day, value: offset, to: start)!,
                                 createdAt: start,
                                 tags: [.stress])
        }

        let summaries = AtriaBehaviorImpact.summaries(days: days,
                                                      journalEntries: journalEntries,
                                                      referenceDate: calendar.date(byAdding: .day, value: 13, to: start)!,
                                                      calendar: calendar)

        XCTAssertEqual(summaries.map(\.tag), [.stress])
        XCTAssertEqual(summaries.first?.loggedDays, 5)
        XCTAssertEqual(summaries.first?.comparisonDays, 9)
        XCTAssertLessThan(summaries.first?.impact ?? 0, -10)
        XCTAssertLessThan(summaries.first?.pValue ?? 1, 0.10)
    }

    func testBehaviorImpactSuppressesUnderpoweredAndSmallEffects() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let recovery = [70, 71, 69, 70, 72, 69, 70, 71, 70, 69, 70, 71]
        let days = recovery.enumerated().map { offset, value in
            AtriaBehaviorImpact.Day(day: calendar.date(byAdding: .day, value: offset, to: start)!,
                                    recoveryPercent: value)
        }
        let smallEffectEntries = (0..<5).map { offset in
            BehaviorJournalEntry(id: "caffeine-\(offset)",
                                 day: calendar.date(byAdding: .day, value: offset, to: start)!,
                                 createdAt: start,
                                 tags: [.caffeine])
        }
        let underpoweredEntries = (0..<4).map { offset in
            BehaviorJournalEntry(id: "training-\(offset)",
                                 day: calendar.date(byAdding: .day, value: offset, to: start)!,
                                 createdAt: start,
                                 tags: [.training])
        }

        let summaries = AtriaBehaviorImpact.summaries(days: days,
                                                      journalEntries: smallEffectEntries + underpoweredEntries,
                                                      referenceDate: calendar.date(byAdding: .day, value: 11, to: start)!,
                                                      calendar: calendar)

        XCTAssertTrue(summaries.isEmpty)
    }

    func testStrainTargetUsesRecoveryCurveAndStaysStableAsProgressAccumulates() {
        XCTAssertEqual(Coach.baseStrainTarget(recovery: 20), 9, accuracy: 0.0001)
        XCTAssertEqual(Coach.baseStrainTarget(recovery: 50), 13, accuracy: 0.0001)
        XCTAssertEqual(Coach.baseStrainTarget(recovery: 80), 17, accuracy: 0.0001)

        XCTAssertEqual(Coach.liveStrainTarget(recovery: 50, accumulatedStrain: 0), 13, accuracy: 0.0001)
        XCTAssertEqual(Coach.liveStrainTarget(recovery: 50, accumulatedStrain: 10), 13, accuracy: 0.0001,
                       "Accumulating strain advances progress; it must not lower today's target")
        XCTAssertEqual(Coach.guide(recovery: 50, strain: 10).target ?? -1, 13, accuracy: 0.0001)
    }

    func testDailyStrainTargetFreezesAcrossAsyncLoadChangeAndRemintsAtDayBoundary() throws {
        let suiteName = "AtriaDailyStrainTargetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayOne = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let highLoad = TrainingLoadSummary(acuteLoad: 18,
                                           chronicLoad: 10,
                                           ratio: 1.8,
                                           monotony: 1.2,
                                           confidence: "local",
                                           readiness: "strained",
                                           acwrSignal: "bad",
                                           monotonySignal: "good",
                                           targetBand: nil,
                                           detail: "test")

        XCTAssertNil(AtriaDailyStrainTargetStore.resolve(recovery: nil,
                                                         load: .learning,
                                                         now: dayOne,
                                                         calendar: calendar,
                                                         defaults: defaults),
                     "No recovery must remain learning and must not mint a target")

        let first = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(recovery: 50,
                                                                      load: .learning,
                                                                      now: dayOne.addingTimeInterval(60),
                                                                      calendar: calendar,
                                                                      defaults: defaults))
        XCTAssertEqual(first.target, 13, accuracy: 0.0001)
        XCTAssertEqual(first.loadProvenance, "load_learning_at_mint")

        let afterAsyncLoad = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(recovery: 50,
                                                                               load: highLoad,
                                                                               now: dayOne.addingTimeInterval(3_600),
                                                                               calendar: calendar,
                                                                               defaults: defaults))
        XCTAssertEqual(afterAsyncLoad, first,
                       "Background load preparation must not move today's already-visible target")

        let dayTwo = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayOne))
        let nextDay = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(recovery: 50,
                                                                        load: highLoad,
                                                                        now: dayTwo.addingTimeInterval(60),
                                                                        calendar: calendar,
                                                                        defaults: defaults))
        XCTAssertEqual(nextDay.target, 11, accuracy: 0.0001)
        XCTAssertEqual(nextDay.loadAdjustment, -2, accuracy: 0.0001)
        XCTAssertEqual(nextDay.loadProvenance, "load_high")
        XCTAssertTrue(calendar.isDate(nextDay.day, inSameDayAs: dayTwo))
    }

    func testDailyStrainTargetDecodesLegacySnapshotWithoutProvenance() throws {
        struct LegacySnapshot: Codable {
            let day: Date
            let recovery: Int
            let target: Double
        }
        let legacy = LegacySnapshot(day: Date(timeIntervalSince1970: 1_800_000_000),
                                    recovery: 50,
                                    target: 13)
        let decoded = try JSONDecoder().decode(AtriaFrozenDailyStrainTarget.self,
                                               from: JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded.target, 13, accuracy: 0.0001)
        XCTAssertEqual(decoded.loadAdjustment, 0, accuracy: 0.0001)
        XCTAssertEqual(decoded.loadProvenance, "legacy")
        XCTAssertEqual(decoded.schemaVersion, 0)
    }

    func testDailyStrainTargetWaitsForTodayRecoveryAndSettledLoad() throws {
        let suiteName = "AtriaDailyStrainTargetEligibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let highLoad = TrainingLoadSummary(acuteLoad: 18,
                                           chronicLoad: 10,
                                           ratio: 1.8,
                                           monotony: 1.2,
                                           confidence: "local",
                                           readiness: "strained",
                                           acwrSignal: "bad",
                                           monotonySignal: "good",
                                           targetBand: nil,
                                           detail: "test")

        XCTAssertNil(AtriaDailyStrainTargetStore.resolve(recovery: 50,
                                                         load: highLoad,
                                                         recoveryIsAttributedToCurrentDay: false,
                                                         loadIsPrepared: true,
                                                         now: today,
                                                         calendar: calendar,
                                                         defaults: defaults),
                     "Yesterday's still-visible recovery cannot mint today's target at midnight")
        XCTAssertNil(AtriaDailyStrainTargetStore.resolve(recovery: 50,
                                                         load: highLoad,
                                                         recoveryIsAttributedToCurrentDay: true,
                                                         loadIsPrepared: false,
                                                         now: today,
                                                         calendar: calendar,
                                                         defaults: defaults),
                     "A transient load placeholder cannot become the frozen daily provenance")

        let ready = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(recovery: 50,
                                                                      load: highLoad,
                                                                      recoveryIsAttributedToCurrentDay: true,
                                                                      loadIsPrepared: true,
                                                                      now: today,
                                                                      calendar: calendar,
                                                                      defaults: defaults))
        XCTAssertEqual(ready.target, 11, accuracy: 0.0001)
        XCTAssertEqual(ready.loadProvenance, "load_high")
    }

    func testPersistedDailyTargetSurvivesTransientRecoveryHydration() {
        let learning = Metrics.RecoveryEstimate(percent: nil,
                                                confidence: .learning,
                                                usesHRV: false,
                                                detail: "loading persisted recovery",
                                                contributors: [])
        let guidance = Coach.guide(recovery: learning,
                                   strain: 6,
                                   load: .learning,
                                   frozenTarget: 13,
                                   frozenRecovery: 50)
        XCTAssertEqual(guidance.target ?? -1, 13, accuracy: 0.0001)
        XCTAssertEqual(guidance.state, "ready")
    }

    func testStrainTargetHapticLatchFiresOncePerDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayOne = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!
        var latch = AtriaStrainTargetHapticLatch()

        XCTAssertFalse(latch.shouldFire(strain: 11.9, target: 12, now: dayOne, calendar: calendar))
        XCTAssertTrue(latch.shouldFire(strain: 12.0, target: 12, now: dayOne, calendar: calendar))
        XCTAssertFalse(latch.shouldFire(strain: 11.5, target: 12, now: dayOne.addingTimeInterval(60), calendar: calendar))
        XCTAssertFalse(latch.shouldFire(strain: 12.4, target: 12, now: dayOne.addingTimeInterval(120), calendar: calendar))
        XCTAssertTrue(latch.shouldFire(strain: 12.1, target: 12, now: dayTwo, calendar: calendar))
    }

    func testBreathworkSummaryUsesFirstAndFinalMinuteHeartRate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(180)
        let samples = [
            AtriaBreathworkSession.HeartSample(date: start.addingTimeInterval(5), bpm: 76),
            AtriaBreathworkSession.HeartSample(date: start.addingTimeInterval(55), bpm: 74),
            AtriaBreathworkSession.HeartSample(date: start.addingTimeInterval(90), bpm: 70),
            AtriaBreathworkSession.HeartSample(date: start.addingTimeInterval(125), bpm: 66),
            AtriaBreathworkSession.HeartSample(date: start.addingTimeInterval(175), bpm: 64)
        ]

        let result = AtriaBreathworkSession.summarize(samples: samples, start: start, end: end)

        XCTAssertEqual(result.startingHR, 75)
        XCTAssertEqual(result.endingHR, 65)
        XCTAssertEqual(result.hrText, "HR 75 -> 65 · -10 bpm")
        XCTAssertNil(result.rmssdText)

        let saved = try XCTUnwrap(AtriaBreathworkSession.savedSession(samples: samples, start: start, end: end))
        XCTAssertEqual(saved.kind, "breathwork")
        XCTAssertEqual(saved.label, "Breathwork")
        XCTAssertEqual(saved.points.count, samples.count)
        XCTAssertEqual(saved.trimp(rest: 60, max: 190), 0)
    }

    func testBreathworkSummaryAddsRMSSDDeltaWhenRRWindowsHaveCoverage() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(180)
        let samples = [
            AtriaBreathworkSession.HeartSample(date: start.addingTimeInterval(5), bpm: 76),
            AtriaBreathworkSession.HeartSample(date: start.addingTimeInterval(55), bpm: 74),
            AtriaBreathworkSession.HeartSample(date: start.addingTimeInterval(125), bpm: 66),
            AtriaBreathworkSession.HeartSample(date: start.addingTimeInterval(175), bpm: 64)
        ]
        let rr = breathworkRRSamples(start: start, end: end)

        let result = AtriaBreathworkSession.summarize(samples: samples, rrSamples: rr, start: start, end: end)

        XCTAssertEqual(result.startingHR, 75)
        XCTAssertEqual(result.endingHR, 65)
        XCTAssertNotNil(result.rmssdDelta)
        XCTAssertNotNil(result.rmssdText)

        let saved = try XCTUnwrap(AtriaBreathworkSession.savedSession(samples: samples, rrSamples: rr, start: start, end: end))
        XCTAssertEqual(saved.rrSampleCount, rr.count)
        XCTAssertEqual(saved.kind, "breathwork")
        XCTAssertEqual(saved.trimp(rest: 60, max: 190), 0)
    }

    func testBreathworkSummaryOmitsRMSSDDeltaWhenFinalRRWindowIsUnderCovered() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(180)
        let samples = [
            AtriaBreathworkSession.HeartSample(date: start.addingTimeInterval(5), bpm: 76),
            AtriaBreathworkSession.HeartSample(date: start.addingTimeInterval(175), bpm: 64)
        ]
        let rr = breathworkRRSamples(start: start, end: end)
            .filter { $0.date < end.addingTimeInterval(-50) }

        let result = AtriaBreathworkSession.summarize(samples: samples, rrSamples: rr, start: start, end: end)

        XCTAssertNil(result.rmssdDelta)
        XCTAssertNil(result.rmssdText)
    }

    func testBreathworkSummaryDoesNotBridgeFragmentedRRIslands() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(180)
        var rr = breathworkRRSamples(start: start, end: end)
        rr.removeAll {
            $0.date >= start.addingTimeInterval(25)
                && $0.date <= start.addingTimeInterval(35)
        }

        let result = AtriaBreathworkSession.summarize(samples: [],
                                                       rrSamples: rr,
                                                       start: start,
                                                       end: end)

        XCTAssertNil(result.rmssdDelta)
        XCTAssertNil(result.rmssdText)
    }

    private func breathworkRRSamples(start: Date, end: Date) -> [AtriaBreathworkSession.RRSample] {
        var output: [AtriaBreathworkSession.RRSample] = []
        var date = start
        var index = 0
        while date <= end {
            let inFinalMinute = date >= end.addingTimeInterval(-60)
            let base = inFinalMinute ? 930 : 800
            let wave = (index % 6) * (inFinalMinute ? 9 : 4)
            let ms = base + wave
            output.append(AtriaBreathworkSession.RRSample(date: date, ms: ms))
            date = date.addingTimeInterval(Double(ms) / 1000.0)
            index += 1
        }
        return output
    }

    func testMaxHRSuggestionTriggersFromObservedPeakAndSuppressesDecline() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peaks = [150, 160, 165, 170, 172, 174, 176, 178, 180, 187]

        let suggestion = AtriaMaxHRSuggestionEngine.suggestion(sessionPeaks: peaks,
                                                               currentMaxHR: 183,
                                                               now: now,
                                                               calendar: calendar)
        XCTAssertEqual(suggestion?.observedPeak, 187)
        XCTAssertNil(AtriaMaxHRSuggestionEngine.suggestion(sessionPeaks: peaks,
                                                           currentMaxHR: 185,
                                                           now: now,
                                                           calendar: calendar))

        let dismissed = AtriaMaxHRSuggestionEngine.Dismissal(observedPeak: 187, dismissedAt: now)
        XCTAssertNil(AtriaMaxHRSuggestionEngine.suggestion(sessionPeaks: peaks,
                                                           currentMaxHR: 183,
                                                           dismissed: dismissed,
                                                           now: calendar.date(byAdding: .day, value: 30, to: now)!,
                                                           calendar: calendar))
        XCTAssertNotNil(AtriaMaxHRSuggestionEngine.suggestion(sessionPeaks: peaks,
                                                              currentMaxHR: 183,
                                                              dismissed: dismissed,
                                                              now: calendar.date(byAdding: .day, value: 61, to: now)!,
                                                              calendar: calendar))
    }

    func testSleepBudgetDebtDecayAndPerformance() {
        let debt = AtriaSleepBudget.sleepDebt(nights: [
            (needed: 8, slept: 7),
            (needed: 8, slept: 6),
            (needed: 8, slept: 8)
        ])
        XCTAssertEqual(debt, 1 * 0.75 * 0.75 + 2 * 0.75, accuracy: 0.0001)
        XCTAssertEqual(AtriaSleepBudget.performancePercent(slept: 7.7, needed: 8.333), 92)
        XCTAssertEqual(AtriaSleepBudget.performancePercent(slept: 12, needed: 8), 100)
        XCTAssertEqual(AtriaSleepBudget.performancePercent(slept: -1, needed: 8), 0)
    }

    func testSleepHistorySnapshotSummarizesNeedPerformanceAndNapCredit() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let mainStart = today.addingTimeInterval(23 * 60 * 60)
        let main = SleepHistorySnapshot.Night(id: "main",
                                              day: today,
                                              start: mainStart,
                                              end: mainStart.addingTimeInterval(7.7 * 3_600),
                                              duration: 7.7 * 3_600,
                                              restingHR: 56,
                                              hrv: 64,
                                              respiratoryRate: 14.2,
                                              sleepEfficiency: 0.91,
                                              confidence: "confirmed",
                                              source: "manual_sleep",
                                              confirmed: true,
                                              stageSegments: [])
        let nap = SleepHistorySnapshot.Night(id: "nap",
                                             day: today,
                                             start: today.addingTimeInterval(13 * 60 * 60),
                                             end: today.addingTimeInterval(13.5 * 60 * 60),
                                             duration: 0.5 * 3_600,
                                             restingHR: nil,
                                             hrv: nil,
                                             respiratoryRate: nil,
                                             sleepEfficiency: nil,
                                             confidence: "confirmed",
                                             source: "manual_nap",
                                             confirmed: true,
                                             stageSegments: [])
        let older = SleepHistorySnapshot.Night(id: "older",
                                               day: calendar.date(byAdding: .day, value: -1, to: today) ?? today,
                                               duration: 6.0 * 3_600,
                                               restingHR: nil,
                                               hrv: nil,
                                               respiratoryRate: nil,
                                               sleepEfficiency: nil,
                                               confidence: "confirmed",
                                               source: "manual_sleep",
                                               confirmed: true,
                                               stageSegments: [])
        let snapshot = SleepHistorySnapshot(nights: [main, nap, older],
                                            confirmedCount: 3,
                                            candidateCount: 0)

        XCTAssertEqual(snapshot.sleepNeedHours(for: main,
                                               baseNeedHours: 8,
                                               yesterdayStrain: 14,
                                               calendar: calendar),
                       // 8 base + (14-8)*0.62/7 strain adder + 1.0 debt - 0.45 nap credit
                       9.0814,
                       accuracy: 0.001)
        XCTAssertEqual(snapshot.sleepPerformancePercent(for: main,
                                                        baseNeedHours: 8,
                                                        yesterdayStrain: 14,
                                                        calendar: calendar),
                       85)
        XCTAssertTrue(snapshot.sleepPerformanceSummary(for: main,
                                                       baseNeedHours: 8,
                                                       yesterdayStrain: 14,
                                                       calendar: calendar).contains("needed · 85%"))
    }

    func testSleepHistorySnapshotSuggestsBedtimeAfterNineFromMedianWake() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = DateComponents(calendar: calendar,
                                 timeZone: calendar.timeZone,
                                 year: 2026,
                                 month: 7,
                                 day: 2).date!
        let now = day.addingTimeInterval(21 * 60 * 60)
        let wakeOffsets = [7 * 60 + 30, 7 * 60 + 40, 7 * 60 + 50]
        let nights = wakeOffsets.enumerated().map { index, wakeMinute in
            let sleepDay = calendar.date(byAdding: .day, value: -index - 1, to: day) ?? day
            let end = sleepDay.addingTimeInterval(TimeInterval(wakeMinute * 60))
            return SleepHistorySnapshot.Night(id: "sleep-\(index)",
                                              day: sleepDay,
                                              start: end.addingTimeInterval(-8 * 3_600),
                                              end: end,
                                              duration: 8 * 3_600,
                                              restingHR: nil,
                                              hrv: nil,
                                              respiratoryRate: nil,
                                              sleepEfficiency: nil,
                                              confidence: "confirmed",
                                              source: "manual_sleep",
                                              confirmed: true,
                                              stageSegments: [])
        }
        let snapshot = SleepHistorySnapshot(nights: nights, confirmedCount: nights.count, candidateCount: 0)

        XCTAssertEqual(snapshot.bedtimeSuggestionText(now: now,
                                                      targetHours: 8.333,
                                                      calendar: calendar),
                       "In bed by 11:20 to hit 8 h 20 m")
        XCTAssertNil(snapshot.bedtimeSuggestionText(now: day.addingTimeInterval(20 * 60 * 60),
                                                    targetHours: 8.333,
                                                    calendar: calendar))
    }

    func testDailyRollupStoreUpsertLastWriteWins() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let store = DailyRollupStore(url: url)
        let day = Date(timeIntervalSince1970: 1_800_000_000)

        store.upsert(DailyRollupStoreEntry(day: day, recovery: 62, rhr: 59))
        store.upsert(DailyRollupStoreEntry(day: day, recovery: 74, rhr: 57, sleepPerformance: 92))

        let rollup = store.rollup(for: day)
        XCTAssertEqual(rollup?.recovery, 74)
        XCTAssertEqual(rollup?.rhr, 57)
        XCTAssertEqual(rollup?.sleepPerformance, 92)
        XCTAssertEqual(store.rollups(last: 7).count, 1)
    }

    func testDailyRollupStoreUpsertRestampsTimezoneOffset() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let store = DailyRollupStore(url: url)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let staleOffset = -720

        store.upsert(DailyRollupStoreEntry(day: day, tzOffsetMinutes: staleOffset, recovery: 68))

        let rollup = store.rollup(for: day)
        XCTAssertEqual(rollup?.tzOffsetMinutes, TimeZone.current.secondsFromGMT(for: day) / 60)
        XCTAssertNotEqual(rollup?.tzOffsetMinutes, staleOffset)
    }

    func testDailyRollupSleepPerformanceUsesNeedDebtAndYesterdayStrain() {
        let performance = SessionStore.dailyRollupSleepPerformance(sleepDuration: 7.7 * 3_600,
                                                                   baseNeedHours: 8,
                                                                   yesterdayStrain: 14,
                                                                   priorNights: [
                                                                    (needed: 8, slept: 6),
                                                                    (needed: 8, slept: 8)
                                                                   ])

        XCTAssertEqual(performance, 83)
        XCTAssertNil(SessionStore.dailyRollupSleepPerformance(sleepDuration: nil,
                                                              baseNeedHours: 8,
                                                              yesterdayStrain: nil,
                                                              priorNights: []))
    }

    func testWakeAlarmSmartWindowFiresOnLightStageWithNonnegativeSlope() {
        let plan = AtriaWakeAlarmPlan(mode: .smartWindow, wakeByHour: 7, wakeByMinute: 30)
        let hardAlarm = Date(timeIntervalSince1970: 1_800_000_000)
        let now = hardAlarm.addingTimeInterval(-12 * 60)
        let samples = [
            AtriaWakeAlarmWindowSample(t: now.addingTimeInterval(-9 * 60), bpm: 54, stage: .sws),
            AtriaWakeAlarmWindowSample(t: now.addingTimeInterval(-4 * 60), bpm: 55, stage: .light),
            AtriaWakeAlarmWindowSample(t: now, bpm: 56, stage: .light)
        ]

        XCTAssertEqual(AtriaWakeAlarmPlanner.decision(plan: plan,
                                                      now: now,
                                                      hardAlarm: hardAlarm,
                                                      sleptHours: 7.2,
                                                      neededHours: 8.0,
                                                      samples: samples),
                       .fireNow(reason: "light_stage_hr_slope_nonnegative"))
    }

    func testWakeAlarmSmartWindowWaitsBeforeWindowAndFallsBackAtWakeBy() {
        let plan = AtriaWakeAlarmPlan(mode: .smartWindow, wakeByHour: 7, wakeByMinute: 30)
        let hardAlarm = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(AtriaWakeAlarmPlanner.decision(plan: plan,
                                                      now: hardAlarm.addingTimeInterval(-31 * 60),
                                                      hardAlarm: hardAlarm,
                                                      sleptHours: 7.5,
                                                      neededHours: 8.0,
                                                      samples: []),
                       .wait(reason: "before_smart_window"))
        XCTAssertEqual(AtriaWakeAlarmPlanner.decision(plan: plan,
                                                      now: hardAlarm,
                                                      hardAlarm: hardAlarm,
                                                      sleptHours: 7.5,
                                                      neededHours: 8.0,
                                                      samples: []),
                       .hardAlarm(reason: "wake_by_reached"))
    }

    func testWakeAlarmSleepNeedMetFiresBeforeHardAlarm() {
        let plan = AtriaWakeAlarmPlan(mode: .sleepNeedMet, wakeByHour: 7, wakeByMinute: 30)
        let hardAlarm = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(AtriaWakeAlarmPlanner.decision(plan: plan,
                                                      now: hardAlarm.addingTimeInterval(-20 * 60),
                                                      hardAlarm: hardAlarm,
                                                      sleptHours: 8.1,
                                                      neededHours: 8.0,
                                                      samples: []),
                       .fireNow(reason: "sleep_need_met"))
        XCTAssertEqual(AtriaWakeAlarmPlanner.decision(plan: plan,
                                                      now: hardAlarm.addingTimeInterval(-20 * 60),
                                                      hardAlarm: hardAlarm,
                                                      sleptHours: 7.9,
                                                      neededHours: 8.0,
                                                      samples: []),
                       .wait(reason: "sleep_need_not_met"))
    }

    func testSleepRespiratoryRateFallsBackToSavedRRPointsForSleepEvidence() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000)
        let rrPoints = (0..<360).map { index -> SavedSession.RRPoint in
            let seconds = Double(index)
            let wave = sin(2 * Double.pi * seconds / 4.0)
            return SavedSession.RRPoint(t: seconds,
                                        ms: Int((920 + wave * 70).rounded()),
                                        source: .standardHeartRateMeasurement2A37)
        }
        let points = stride(from: 0, through: 360, by: 10).map {
            SavedSession.Point(t: Double($0), bpm: 62)
        }
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(360),
                                   label: "Night",
                                   points: points,
                                   respiratoryRate: nil,
                                   rrPoints: rrPoints,
                                   sleepWakeResearchState: "sleep_research")

        let rate = session.sleepRespiratoryRate(rest: 58, maxHR: 185)

        XCTAssertNotNil(rate)
        XCTAssertEqual(rate ?? 0, 15.0, accuracy: 1.0)
    }

    // MARK: Respiratory-rate HF band floor + BLE-gap guard (2026-07-08)

    func testRespRateAcceptsRealBreathingBand() {
        let sampleRate = 4.0
        let count = Int(90 * sampleRate)
        let hf = (0..<count).map { sin(2 * Double.pi * (15.0 / 60.0) * Double($0) / sampleRate) }
        let rate = AtriaAnalytics.RespRateRsa.estimate(resampledRR: hf, sampleRate: sampleRate)
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate ?? 0, 15.0, accuracy: 1.0)
    }

    func testRespRateNeverReportsBelowBreathingFloor() {
        // A 6 bpm (0.10 Hz) oscillation is HRV low-frequency / Mayer-wave
        // territory, not breathing. The device showed 6.5-8.2 bpm reported as
        // respiratory rate — a fabrication. The estimator must now never
        // return a value below the 9 bpm HF-band floor (nil is fine).
        let sampleRate = 4.0
        let count = Int(90 * sampleRate)
        let lf = (0..<count).map { sin(2 * Double.pi * (6.0 / 60.0) * Double($0) / sampleRate) }
        if let rate = AtriaAnalytics.RespRateRsa.estimate(resampledRR: lf, sampleRate: sampleRate) {
            XCTAssertGreaterThanOrEqual(rate, 9.0, "must not report LF drift as sub-9 bpm breathing")
        }
    }

    func testRespRateFailsClosedAcrossBleDropGap() {
        // A clean 15 bpm RR series with a 12s beat-timeline hole (BLE drop).
        // The gap guard must return nil rather than interpolate LF drift
        // across the hole and mislabel it as slow breathing.
        let base = Date(timeIntervalSinceReferenceDate: 900_000)
        var samples: [(t: Date, ms: Double)] = []
        for index in 0..<220 {
            let t = Double(index) * 0.9
            let ms = 900 + 70 * sin(2 * Double.pi * (15.0 / 60.0) * t)
            samples.append((base.addingTimeInterval(t), ms))
        }
        let afterGap = samples.last!.t.addingTimeInterval(12)
        for index in 0..<120 {
            let t = Double(index) * 0.9
            let ms = 900 + 70 * sin(2 * Double.pi * (15.0 / 60.0) * t)
            samples.append((afterGap.addingTimeInterval(t), ms))
        }
        let now = samples.last!.t
        XCTAssertNil(AtriaAnalytics.RespRateRsa.estimate(samples: samples, now: now, lookback: 600))
    }

    func testSleepRespiratoryRateRejectsClockTimeAloneAsSleepEvidence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = DateComponents(calendar: calendar,
                                   timeZone: calendar.timeZone,
                                   year: 2026,
                                   month: 7,
                                   day: 1,
                                   hour: 0,
                                   minute: 30).date!
        let rrPoints = (0..<360).map { index -> SavedSession.RRPoint in
            let seconds = Double(index)
            let wave = sin(2 * Double.pi * seconds / 4.0)
            return SavedSession.RRPoint(t: seconds,
                                        ms: Int((920 + wave * 70).rounded()),
                                        source: .standardHeartRateMeasurement2A37)
        }
        let points = stride(from: 0, through: 360, by: 10).map {
            SavedSession.Point(t: Double($0), bpm: 62)
        }
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(360),
                                   label: "All-day wear",
                                   points: points,
                                   respiratoryRate: nil,
                                   rrPoints: rrPoints,
                                   sleepWakeResearchReason: "imu_missing")

        let rate = session.sleepRespiratoryRate(rest: 58, maxHR: 185, calendar: calendar)

        XCTAssertNil(rate)
    }

    func testDailyRollupRejectsRespiratoryFallbackWithoutQualifiedSleep() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = DateComponents(calendar: calendar,
                                 timeZone: calendar.timeZone,
                                 year: 2026,
                                 month: 7,
                                 day: 27).date!
        let metric = SavedDailyMetric(day: day,
                                      recoveryPercent: 46,
                                      recoveryConfidence: "unverified",
                                      hrv: nil,
                                      restingHR: 73,
                                      respiratoryRate: nil,
                                      sleepDuration: nil,
                                      sleepSpan: nil,
                                      sleepStart: nil,
                                      sleepEnd: nil,
                                      sleepSource: nil,
                                      sleepStageSegments: [],
                                      sleepConsistencyPercent: nil,
                                      strain: 11.4)

        let rollup = try XCTUnwrap(SessionStore.makeDailyRollupStoreEntries(
            metrics: [metric],
            respiratoryRateByMorningDay: [day: 12.425],
            calendar: calendar
        ).first)

        XCTAssertNil(rollup.respiratoryRate)
        XCTAssertNil(rollup.vitals?.resp)
    }

    func testDailyRollupPreservesRespiratoryFallbackForQualifiedSleep() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = DateComponents(calendar: calendar,
                                 timeZone: calendar.timeZone,
                                 year: 2026,
                                 month: 7,
                                 day: 27).date!
        let sleepEnd = day.addingTimeInterval(8 * 3_600)
        let sleepStart = sleepEnd.addingTimeInterval(-7 * 3_600)
        let metric = SavedDailyMetric(day: day,
                                      recoveryPercent: 72,
                                      recoveryConfidence: "confirmed",
                                      hrv: 48,
                                      restingHR: 58,
                                      respiratoryRate: nil,
                                      sleepDuration: 7 * 3_600,
                                      sleepSpan: 7 * 3_600,
                                      sleepStart: sleepStart,
                                      sleepEnd: sleepEnd,
                                      sleepSource: "manual_sleep",
                                      sleepStageSegments: [],
                                      sleepConsistencyPercent: 82,
                                      strain: 4.2)

        let rollup = try XCTUnwrap(SessionStore.makeDailyRollupStoreEntries(
            metrics: [metric],
            respiratoryRateByMorningDay: [day: 13.8],
            calendar: calendar
        ).first)

        XCTAssertEqual(rollup.respiratoryRate ?? 0, 13.8, accuracy: 0.001)
        XCTAssertNil(rollup.vitals?.resp,
                     "a single qualified night is not yet a respiratory baseline")
    }

    func testHealthMetricEvidenceLabelsMatchNoSleepFallbackAuthority() {
        let day = Date(timeIntervalSinceReferenceDate: 900_000)
        let summary = FrozenRecoverySummary(
            score: 46,
            confidence: Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
            source: FrozenRecoverySummary.recoveryV2Source,
            model: "recovery_v2",
            scoredDay: day,
            usesHRV: false,
            detail: "sleep and HRV unavailable",
            contributors: []
        )
        let rollup = DailyRollupStoreEntry(day: day,
                                          recoverySummary: summary,
                                          lnRMSSD: nil,
                                          rhr: 73,
                                          sleepSeconds: nil)

        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.recoveryDetail(
            rollup: rollup,
            liveRecoveryAvailable: true
        ), "limited estimate")
        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.restingHeartRateDetail(
            rollup: rollup,
            liveValueAvailable: true
        ), "wear estimate")
        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.hrvDetail(
            rollup: rollup,
            liveValueAvailable: false
        ), "needs qualified sleep")
        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.respiratoryDetail(
            valueAvailable: false
        ), "needs qualified sleep")
        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.settledRestingHeartRateDetail(
            rollup: rollup,
            now: day
        ), "wear estimate")
    }

    func testHealthMetricEvidenceLabelsPreserveQualifiedSleepClaims() {
        let rollup = DailyRollupStoreEntry(day: Date(timeIntervalSinceReferenceDate: 900_000),
                                          recovery: 72,
                                          lnRMSSD: log(48),
                                          rhr: 58,
                                          sleepSeconds: 7 * 3_600,
                                          respiratoryRate: 13.8)

        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.recoveryDetail(
            rollup: rollup,
            liveRecoveryAvailable: true
        ), "saved")
        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.restingHeartRateDetail(
            rollup: rollup,
            liveValueAvailable: true
        ), "sleep-derived")
        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.hrvDetail(
            rollup: rollup,
            liveValueAvailable: true
        ), "sleep signal")
        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.respiratoryDetail(
            valueAvailable: true
        ), "sleep average")
        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.settledRestingHeartRateDetail(
            rollup: rollup,
            now: rollup.day
        ), "this morning")
        let tomorrow = rollup.day.addingTimeInterval(24 * 60 * 60)
        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.settledHRVDetail(
            rollup: rollup,
            now: tomorrow
        ), "yesterday")
    }

    func testHealthMetricEvidenceDoesNotCallOlderSavedMorningYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026,
                                                     month: 7,
                                                     day: 29,
                                                     hour: 16))!
        let saved = calendar.date(from: DateComponents(year: 2026,
                                                       month: 7,
                                                       day: 20))!
        let rollup = DailyRollupStoreEntry(day: saved,
                                          lnRMSSD: log(48),
                                          rhr: 57,
                                          sleepSeconds: 7.16 * 3_600,
                                          calendar: calendar)

        // Migrated 2026-07-31 (device review): a multi-day-old carried HRV now
        // tells the user how to refresh it.
        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.settledHRVDetail(
            rollup: rollup,
            now: now,
            calendar: calendar
        ), "9d ago · confirm a sleep to update")
        XCTAssertEqual(AtriaHealthMetricEvidencePresentation.settledRestingHeartRateDetail(
            rollup: rollup,
            now: now,
            calendar: calendar
        ), "9d ago")
    }

    func testSleepRespiratoryRateUsesEarlierRRWindowsWhenTailIsSparse() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000)
        var rrPoints = (0..<240).map { index -> SavedSession.RRPoint in
            let seconds = Double(index)
            let wave = sin(2 * Double.pi * seconds / 4.0)
            return SavedSession.RRPoint(t: seconds,
                                        ms: Int((920 + wave * 70).rounded()),
                                        source: .standardHeartRateMeasurement2A37)
        }
        rrPoints.append(contentsOf: (0..<18).map { index in
            SavedSession.RRPoint(t: 900 + Double(index * 2),
                                 ms: 920,
                                 source: .standardHeartRateMeasurement2A37)
        })
        let points = stride(from: 0, through: 940, by: 20).map {
            SavedSession.Point(t: Double($0), bpm: 62)
        }
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(940),
                                   label: "Night",
                                   points: points,
                                   respiratoryRate: nil,
                                   rrPoints: rrPoints,
                                   sleepWakeResearchState: "sleep_research")

        let rate = session.sleepRespiratoryRate(rest: 58, maxHR: 185)

        XCTAssertNotNil(rate)
        XCTAssertEqual(rate ?? 0, 15.0, accuracy: 1.0)
    }

    func testWeeklyReportMathUsesFourteenDayRollupFixture() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = DateComponents(calendar: calendar,
                                   timeZone: calendar.timeZone,
                                   year: 2026,
                                   month: 7,
                                   day: 6).date!
        let recoveries = [80, 75, 70, 65, 60, 55, 50, 60, 58, 56, 54, 52, 50, 48]
        let bedtimes = [1_380, 1_390, 1_370, 1_385, 1_375, 1_395, 1_380,
                        1_430, 1_360, 1_410, 1_390, 1_350, 1_420, 1_400]
        let strains = [8.0, 9.5, 18.0, 7.0, 6.0, 5.5, 4.0,
                       10.0, 8.0, 7.0, 6.0, 5.0, 4.5, 4.0]
        let rollups = (0..<14).map { offset in
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                                  recovery: recoveries[offset],
                                  sleepPerformance: 90,
                                  bedtimeMinutes: bedtimes[offset],
                                  strain: strains[offset],
                                  calendar: calendar)
        }

        let report = WeeklyReport(rollups: rollups, now: today, calendar: calendar)

        XCTAssertEqual(report.recoveryAvg, 65)
        XCTAssertEqual(report.recoveryDeltaVsPriorWeek, 11)
        XCTAssertEqual(report.sleepConsistencyPct, 93)
        XCTAssertEqual(report.bestDay?.recovery, 80)
        XCTAssertEqual(report.hardestDay?.strain, 18)
        XCTAssertNil(report.strainRecoveryNote)

        let unordered = [rollups[11], rollups[2], rollups[8]]
            + rollups.enumerated()
                .filter { ![11, 2, 8].contains($0.offset) }
                .map(\.element)
        XCTAssertEqual(WeeklyReport(rollups: unordered, now: today, calendar: calendar),
                       report,
                       "Weekly report should not require pre-sorted rollups.")
    }

    func testWeeklyReportStrainRecoveryNoteFiresForBottomTwoRecoveryDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = DateComponents(calendar: calendar,
                                   timeZone: calendar.timeZone,
                                   year: 2026,
                                   month: 7,
                                   day: 6).date!
        let recoveries = [80, 75, 70, 65, 60, 55, 50]
        let strains = [8.0, 9.5, 10.0, 7.0, 6.0, 5.5, 18.0]
        let rollups = (0..<7).map { offset in
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                                  recovery: recoveries[offset],
                                  bedtimeMinutes: 1_380,
                                  strain: strains[offset],
                                  calendar: calendar)
        }

        let report = WeeklyReport(rollups: rollups, now: today, calendar: calendar)

        XCTAssertEqual(report.hardestDay?.recovery, 50)
        XCTAssertEqual(report.strainRecoveryNote, WeeklyReport.strainRecoveryNoteText)
    }

    func testWorkoutPromptEvaluatorFiresForEightMinutesAtRestPlusTwentySeven() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = syntheticHeartSamples(start: start, count: 480, bpm: 87)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 87,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: samples.last!.t)

        XCTAssertTrue(result.shouldPrompt)
        XCTAssertTrue(result.sustainedPath)
    }

    // Detection fix (2026-07-09): real BLE data drops packets, so a genuine
    // sustained effort never yields a full 480/480 elevated samples. The old
    // `elevatedSamples >= 480` gate demanded ~100% of an 8-min window with zero
    // dropout and therefore never fired on device ("no detection"). A sustained
    // effort (~5-6 min elevated, i.e. an 8-min bout with normal dropout) must fire.
    func testWorkoutPromptEvaluatorFiresForSustainedEffortWithPacketDropout() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = syntheticHeartSamples(start: start, count: 360, bpm: 87)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 87,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: samples.last!.t)

        XCTAssertTrue(result.sustainedPath, "a sustained effort must fire despite normal packet dropout")
        XCTAssertTrue(result.shouldPrompt)
    }

    // ...and a merely brief elevation must still be rejected (fail-closed).
    func testWorkoutPromptEvaluatorRejectsBriefElevation() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = syntheticHeartSamples(start: start, count: 180, bpm: 87)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 87,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: samples.last!.t)

        XCTAssertFalse(result.sustainedPath, "a brief ~3-min elevation must not trip the sustained path")
        XCTAssertFalse(result.shouldPrompt)
    }

    func testWorkoutPromptEvaluatorRejectsTwentyMinutesAtRestPlusTwenty() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = syntheticHeartSamples(start: start, count: 1_200, bpm: 80)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 80,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: samples.last!.t)

        XCTAssertFalse(result.shouldPrompt)
        XCTAssertFalse(result.sustainedPath)
        XCTAssertFalse(result.zonePath)
    }

    func testWorkoutPromptEvaluatorFiresForFourMinutesInZoneThree() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = syntheticHeartSamples(start: start, count: 120, bpm: 82)
            + syntheticHeartSamples(start: start.addingTimeInterval(120), count: 240, bpm: 151)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 151,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: samples.last!.t.addingTimeInterval(1))

        XCTAssertTrue(result.shouldPrompt)
        XCTAssertTrue(result.zonePath)
    }

    // Device-lag fix (2026-07-07): the evaluator now walks only the trailing
    // window instead of scanning the whole (up to ~80k-sample) session. These
    // lock that the long lead-in neither counts nor changes the verdict.
    func testWorkoutPromptEvaluatorScansOnlyTailOfLongSession() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // ~4h of resting samples before the window, then 8 min elevated ending now.
        let leadIn = syntheticHeartSamples(start: start, count: 14_400, bpm: 62)
        let tail = syntheticHeartSamples(start: start.addingTimeInterval(14_400), count: 480, bpm: 87)
        let samples = leadIn + tail

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 87,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: samples.last!.t)
        XCTAssertEqual(result.elevatedSamples, 480,
                       "destination-sample ownership counts the complete elevated trailing window")
        XCTAssertTrue(result.sustainedPath)
        XCTAssertTrue(result.shouldPrompt)
    }

    func testWorkoutPromptEvaluatorIgnoresElevatedDataBeforeWindow() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // Old elevated bout long ago, then the last 8 min at rest.
        let oldElevated = syntheticHeartSamples(start: start, count: 480, bpm: 120)
        let recentResting = syntheticHeartSamples(start: start.addingTimeInterval(3_600), count: 480, bpm: 62)
        let samples = oldElevated + recentResting

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 62,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: samples.last!.t)
        XCTAssertEqual(result.elevatedSamples, 0, "elevated data outside the window must not count")
        XCTAssertFalse(result.shouldPrompt)
    }

    func testWorkoutPromptEvaluatorRejectsSingleCurrentHeartRateSpike() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let resting = syntheticHeartSamples(start: start, count: 479, bpm: 62)
        let spike = syntheticHeartSamples(start: start.addingTimeInterval(479), count: 1, bpm: 151)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: resting + spike,
                                                          currentHeartRate: 151,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: spike[0].t)

        XCTAssertLessThan(result.longestElevatedBout,
                          AtriaWorkoutPromptEvaluator.minimumContinuousElevatedSamples,
                          "a single transition sample cannot prove a sustained effort")
        XCTAssertFalse(result.shouldPrompt)
    }

    func testWorkoutPromptEvaluatorRejectsFragmentedRepeatedSpikes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<480).map { offset in
            HRSample(t: start.addingTimeInterval(TimeInterval(offset)),
                     bpm: offset % 5 == 4 ? 62 : 90)
        }

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 90,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: samples.last!.t)

        XCTAssertGreaterThanOrEqual(result.elevatedSamples, 300)
        XCTAssertEqual(result.longestElevatedBout, 4)
        XCTAssertFalse(result.shouldPrompt, "fragmented optical plateaus must not be stitched into a workout")
    }

    func testWorkoutPromptEvaluatorRejectsStaleZoneEvidenceAfterHeartRateSettles() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let zoneThree = syntheticHeartSamples(start: start, count: 240, bpm: 151)
        let settled = syntheticHeartSamples(start: start.addingTimeInterval(240), count: 60, bpm: 62)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: zoneThree + settled,
                                                          currentHeartRate: 62,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: settled.last!.t)

        XCTAssertEqual(result.zoneSamples, zoneThree.count - 1)
        XCTAssertEqual(result.recentZoneSamples, 0)
        XCTAssertFalse(result.shouldPrompt)
    }

    func testWorkoutPromptEvaluatorRequiresCurrentStrapContact() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = syntheticHeartSamples(start: start, count: 480, bpm: 151)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 151,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          hasContact: false,
                                                          now: samples.last!.t)

        XCTAssertFalse(result.shouldPrompt)
    }

    func testWorkoutPromptEvaluatorRejectsStaleElevatedPlateau() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = syntheticHeartSamples(start: start, count: 480, bpm: 151)
        let now = samples.last!.t.addingTimeInterval(30)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 151,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: now)

        XCTAssertEqual(result.elevatedSamples, 0)
        XCTAssertFalse(result.shouldPrompt, "an old plateau must not be made current by the cached HR value")
    }

    func testWorkoutPromptEvaluatorRejectsSameTimestampBurst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<600).map { _ in HRSample(t: now, bpm: 151) }

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 151,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: now)

        XCTAssertEqual(result.elevatedSamples, 0)
        XCTAssertEqual(result.longestElevatedBout, 0)
        XCTAssertFalse(result.shouldPrompt, "duplicate packets cannot manufacture elapsed effort")
    }

    func testWorkoutPromptEvaluatorRejectsNonmonotonicTimestampBurst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<600).map { offset in
            HRSample(t: now.addingTimeInterval(offset.isMultiple(of: 2) ? -2 : -3),
                     bpm: 151)
        }

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 151,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: now)

        XCTAssertLessThanOrEqual(result.elevatedSamples, 2)
        XCTAssertFalse(result.shouldPrompt, "backwards packet bursts cannot manufacture a workout")
    }

    func testWorkoutPromptEvaluatorAcceptsSustainedElapsedEffortWithDropout() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<181).map { offset in
            HRSample(t: start.addingTimeInterval(TimeInterval(offset * 2)), bpm: 90)
        }
        let now = samples.last!.t.addingTimeInterval(1)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 90,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          now: now)

        XCTAssertGreaterThanOrEqual(result.elevatedSamples, 360)
        XCTAssertGreaterThanOrEqual(result.longestElevatedBout, 360)
        XCTAssertTrue(result.sustainedPath, "real elapsed effort must tolerate ordinary packet loss")
    }

    func testWorkoutPromptEvaluatorRejectsHeldAndDroppedArtifactPlateau() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = syntheticHeartSamples(start: start, count: 480, bpm: 151)
        let quality = AtriaWorkoutPromptEvaluator.SignalQuality(rawSamples: 480,
                                                                acceptedSamples: 360,
                                                                zeroSamples: 0,
                                                                heldArtifacts: 70,
                                                                droppedArtifacts: 50,
                                                                acceptedGapCount: 0,
                                                                maxAcceptedGap: 1,
                                                                rrImpliedMedianBPM: nil)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 151,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          signalQuality: quality,
                                                          now: samples.last!.t)

        XCTAssertFalse(result.shouldPrompt,
                       "an HR plateau backed by a high hold/drop share is a contact artifact, not a workout")
    }

    func testWorkoutPromptEvaluatorRejectsRRThatContradictsReportedHR() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = syntheticHeartSamples(start: start, count: 480, bpm: 151)
        let quality = AtriaWorkoutPromptEvaluator.SignalQuality(rawSamples: 480,
                                                                acceptedSamples: 480,
                                                                zeroSamples: 0,
                                                                heldArtifacts: 0,
                                                                droppedArtifacts: 0,
                                                                acceptedGapCount: 0,
                                                                maxAcceptedGap: 1,
                                                                rrImpliedMedianBPM: 75)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 151,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          signalQuality: quality,
                                                          now: samples.last!.t)

        XCTAssertFalse(result.shouldPrompt,
                       "the strap's RR channel contradicting its HR channel must fail closed")
    }

    func testWorkoutPromptEvaluatorAcceptsCleanSustainedStrapEffortWithoutPhoneMotion() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = syntheticHeartSamples(start: start, count: 480, bpm: 92)
        let quality = AtriaWorkoutPromptEvaluator.SignalQuality(rawSamples: 480,
                                                                acceptedSamples: 480,
                                                                zeroSamples: 0,
                                                                heldArtifacts: 0,
                                                                droppedArtifacts: 0,
                                                                acceptedGapCount: 0,
                                                                maxAcceptedGap: 1,
                                                                rrImpliedMedianBPM: nil)

        let result = AtriaWorkoutPromptEvaluator.evaluate(samples: samples,
                                                          currentHeartRate: 92,
                                                          restingHeartRate: 60,
                                                          maxHeartRate: 190,
                                                          signalQuality: quality,
                                                          now: samples.last!.t)

        XCTAssertTrue(result.shouldPrompt)
        XCTAssertTrue(result.sustainedPath,
                      "clean continuous strap evidence remains sufficient without RR or phone motion")
    }

    func testWorkoutPromptCooldownLatchExpiresAfterFortyFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dismissedUntil = now.addingTimeInterval(AtriaWorkoutPromptEvaluator.cooldown)

        XCTAssertTrue(AtriaWorkoutPromptEvaluator.isInCooldown(dismissedUntil: dismissedUntil,
                                                               now: now))
        XCTAssertTrue(AtriaWorkoutPromptEvaluator.isInCooldown(dismissedUntil: dismissedUntil,
                                                               now: dismissedUntil.addingTimeInterval(-1)))
        XCTAssertFalse(AtriaWorkoutPromptEvaluator.isInCooldown(dismissedUntil: dismissedUntil,
                                                                now: dismissedUntil))
        XCTAssertFalse(AtriaWorkoutPromptEvaluator.isInCooldown(dismissedUntil: nil,
                                                                now: now))
    }

    // MARK: - Phantom-workout artifact hardening (2026-07-05)
    //
    // These exercise SavedSession.workoutReadiness(rest:maxHR:) directly --
    // the pure, testable core that replaySavedWorkoutReadiness/
    // latestWorkoutReviewCandidate build on (readySessions is literally a
    // count of sessions where this same call's `.ready` is true, and the
    // review-worthy/contact-compromised gates below are what those private
    // SessionStore paths carry through unchanged).

    private func workoutFixtureSession(start: Date,
                                       end: Date,
                                       label: String,
                                       points: [SavedSession.Point],
                                       rrPoints: [SavedSession.RRPoint]? = nil,
                                       hrRaw2A37: Int = 0,
                                       hrAccepted: Int = 0,
                                       hrZero: Int = 0,
                                       hrArtifactHeld: Int = 0,
                                       hrArtifactDropped: Int = 0,
                                       hrAcceptedGaps: Int = 0,
                                       hrMaxAcceptedGap: Double = 0) -> SavedSession {
        SavedSession(id: UUID(),
                     start: start,
                     end: end,
                     label: label,
                     points: points,
                     rrPoints: rrPoints,
                     hrRaw2A37: hrRaw2A37,
                     hrAccepted: hrAccepted,
                     hrZero: hrZero,
                     hrArtifactHeld: hrArtifactHeld,
                     hrArtifactDropped: hrArtifactDropped,
                     hrAcceptedGaps: hrAcceptedGaps,
                     hrMaxAcceptedGap: hrMaxAcceptedGap)
    }

    func testArtifactContactGapNightProducesNoWorkoutCandidate() {
        // Overnight session: true resting HR ~55 for most of the night, with a
        // ~20-minute loose-contact stretch of sustained ~120bpm artifact HR at
        // 5-12s spacing (the reconnect/hr_mismatch fingerprint). Audit counters
        // carry the watchdog-cycling signature: heavy artifact hold+drop share,
        // heavy zero share, and several large accepted-HR gaps. No RR channel.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var points: [SavedSession.Point] = []
        var cursor: TimeInterval = 0
        // 20 minutes clean baseline @ 5s cadence.
        while cursor < 20 * 60 {
            points.append(SavedSession.Point(t: cursor, bpm: 55))
            cursor += 5
        }
        // ~22 minutes sustained loose-contact artifact @ ~5-12s spacing.
        var spacingToggle = false
        let artifactEnd = cursor + 22 * 60
        while cursor < artifactEnd {
            points.append(SavedSession.Point(t: cursor, bpm: 120))
            cursor += spacingToggle ? 12 : 5
            spacingToggle.toggle()
        }
        // 18 more minutes clean baseline.
        let tailEnd = cursor + 18 * 60
        while cursor < tailEnd {
            points.append(SavedSession.Point(t: cursor, bpm: 55))
            cursor += 5
        }
        let session = workoutFixtureSession(start: start,
                                            end: start.addingTimeInterval(cursor),
                                            label: "Sleep",
                                            points: points,
                                            rrPoints: nil,
                                            hrRaw2A37: 1_000,
                                            hrAccepted: 600,
                                            hrZero: 300,
                                            hrArtifactHeld: 100,
                                            hrArtifactDropped: 100,
                                            hrAcceptedGaps: 4,
                                            hrMaxAcceptedGap: 150)

        XCTAssertTrue(session.hrContactCompromised)

        let readiness = session.workoutReadiness(rest: 55, maxHR: 190)

        XCTAssertFalse(readiness.ready, "a watchdog-cycling artifact stretch must never mark a session ready")
        XCTAssertFalse(readiness.reviewWorthyCandidate, "a compromised session must never surface an auto-detect review prompt")
        XCTAssertNil(session.detectedActivity(rest: 55, maxHR: 190),
                     "diagnostic near-misses must not leak into the visible Activity timeline")
    }

    @MainActor
    func testRealWorkoutCandidateSurvivesHardening() {
        // 35-minute run: ramp 90->150 over 3 min, 28 min sustained ~150bpm,
        // 4 min cool-down. RR intervals agree with reported HR throughout
        // (ms = 60000/bpm), artifact/zero shares are zero, no accepted gaps.
        let rest = 55
        let maxHR = 190
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var points: [SavedSession.Point] = []
        var rrPoints: [SavedSession.RRPoint] = []
        var cursor: TimeInterval = 0
        func appendPhase(duration: TimeInterval, bpmAt: (TimeInterval) -> Int) {
            let phaseEnd = cursor + duration
            while cursor < phaseEnd {
                let bpm = bpmAt(cursor - (phaseEnd - duration))
                points.append(SavedSession.Point(t: cursor, bpm: bpm))
                rrPoints.append(SavedSession.RRPoint(
                    t: cursor,
                    ms: Int((60_000.0 / Double(bpm)).rounded()),
                    source: .standardHeartRateMeasurement2A37
                ))
                cursor += 2
            }
        }
        appendPhase(duration: 3 * 60) { t in 90 + Int((t / (3 * 60)) * 60) } // 90 -> 150
        appendPhase(duration: 28 * 60) { _ in 150 }
        appendPhase(duration: 4 * 60) { t in max(90, 150 - Int((t / (4 * 60)) * 60)) } // 150 -> 90

        let session = workoutFixtureSession(start: start,
                                            end: start.addingTimeInterval(cursor),
                                            label: "Run",
                                            points: points,
                                            rrPoints: rrPoints,
                                            hrRaw2A37: points.count,
                                            hrAccepted: points.count,
                                            hrZero: 0,
                                            hrArtifactHeld: 0,
                                            hrArtifactDropped: 0,
                                            hrAcceptedGaps: 0,
                                            hrMaxAcceptedGap: 2)

        XCTAssertFalse(session.hrContactCompromised)
        XCTAssertFalse(session.hrRRDisagreesWithReportedHR)

        let readiness = session.workoutReadiness(rest: rest, maxHR: maxHR)

        XCTAssertTrue(readiness.ready, "clean RR-agreeing effort must remain eligible for review")
        XCTAssertTrue(readiness.reviewWorthyCandidate)
        let detection = session.detectedActivity(rest: rest, maxHR: maxHR)
        XCTAssertEqual(detection?.kind, .activityCandidate,
                       "HR/RR alone cannot distinguish a workout from stress or driving")
        XCTAssertTrue(detection?.reason.contains("not counted as workout") == true)

        let reviewCandidate = SessionStore.makeWorkoutReviewCandidateForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertEqual(reviewCandidate?.kind, .activityCandidate,
                       "saved HR-only evidence must remain an effort candidate until its activity type is confirmed")
        XCTAssertEqual(reviewCandidate?.title, "Effort ready to review")

        let deletedWindow = AtriaDismissedWorkoutCandidate(start: start,
                                                            end: start.addingTimeInterval(cursor))
        let suppressed = SessionStore.makeWorkoutReviewCandidateForCache(
            sessions: [session],
            confirmedWorkouts: [],
            dismissedCandidates: [deletedWindow],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertNil(suppressed,
                     "deleting a workout must suppress the regenerated detector window")

        let unrelatedWindow = AtriaDismissedWorkoutCandidate(
            start: start.addingTimeInterval(-4 * 60 * 60),
            end: start.addingTimeInterval(-3 * 60 * 60)
        )
        let unaffected = SessionStore.makeWorkoutReviewCandidateForCache(
            sessions: [session],
            confirmedWorkouts: [],
            dismissedCandidates: [unrelatedWindow],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertNotNil(unaffected)

        let store = SessionStore()
        store.add(session)
        defer { store.deleteSession(id: session.id) }
        let rollup = store.dailyRollups(rest: rest, maxHR: maxHR)
            .first { Calendar.current.isDate($0.day, inSameDayAs: start) }
        XCTAssertEqual(rollup?.workouts, 0)
        XCTAssertGreaterThanOrEqual(rollup?.activityCandidates ?? 0, 1)
    }

    func testLongQuietWindowWithOneModestPeakIsNotReviewWorthy() {
        let rest = 60
        let maxHR = 190
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = (0..<107).map { minute -> SavedSession.Point in
            let bpm = minute == 40 || minute == 41 ? 126 : 82
            return SavedSession.Point(t: Double(minute) * 60, bpm: bpm)
        }
        let rrPoints = points.map {
            SavedSession.RRPoint(t: $0.t,
                                 ms: Int((60_000.0 / Double($0.bpm)).rounded()),
                                 source: .standardHeartRateMeasurement2A37)
        }
        let session = workoutFixtureSession(start: start,
                                            end: start.addingTimeInterval(106 * 60),
                                            label: "Quiet evening",
                                            points: points,
                                            rrPoints: rrPoints,
                                            hrRaw2A37: points.count,
                                            hrAccepted: points.count,
                                            hrZero: 0,
                                            hrArtifactHeld: 0,
                                            hrArtifactDropped: 0,
                                            hrAcceptedGaps: 0,
                                            hrMaxAcceptedGap: 60)

        let readiness = session.workoutReadiness(rest: rest, maxHR: maxHR)

        XCTAssertEqual(session.avg, 83)
        XCTAssertEqual(session.peak, 126)
        XCTAssertFalse(readiness.ready)
        XCTAssertFalse(readiness.strengthCandidate)
        XCTAssertFalse(readiness.moderateStrengthReviewCandidate)
        XCTAssertFalse(readiness.reviewWorthyCandidate)
    }

    func testRRContradictsElevationIsRejectedByAgreementCeiling() {
        // Reported HR sustained ~120bpm (clean stream, no artifact/zero share,
        // no gaps) -- looks like a real workout -- but RR intervals throughout
        // imply ~55bpm (ms ~1090), 65bpm outside the +/-20bpm agreement
        // tolerance. The strap's own RR channel contradicting its reported HR
        // must reject the candidate outright.
        let rest = 50
        let maxHR = 170 // HRR50 threshold = 110, so reported 120bpm clears it.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var points: [SavedSession.Point] = []
        var rrPoints: [SavedSession.RRPoint] = []
        var cursor: TimeInterval = 0
        while cursor < 20 * 60 {
            points.append(SavedSession.Point(t: cursor, bpm: 120))
            cursor += 5
        }
        var rrCursor: TimeInterval = 0
        while rrCursor < 20 * 60 {
            rrPoints.append(SavedSession.RRPoint(t: rrCursor,
                                                 ms: 1_090,
                                                 source: .standardHeartRateMeasurement2A37))
            rrCursor += 24
        }
        let session = workoutFixtureSession(start: start,
                                            end: start.addingTimeInterval(cursor),
                                            label: "Contradicted",
                                            points: points,
                                            rrPoints: rrPoints,
                                            hrRaw2A37: points.count,
                                            hrAccepted: points.count,
                                            hrZero: 0,
                                            hrArtifactHeld: 0,
                                            hrArtifactDropped: 0,
                                            hrAcceptedGaps: 0,
                                            hrMaxAcceptedGap: 5)

        XCTAssertFalse(session.hrContactCompromised)
        XCTAssertTrue(session.hrRRDisagreesWithReportedHR)

        let readiness = session.workoutReadiness(rest: rest, maxHR: maxHR)

        XCTAssertFalse(readiness.ready, "RR contradicting reported HR must reject readiness")
        XCTAssertFalse(readiness.reviewWorthyCandidate, "RR contradicting reported HR must reject review-worthiness")
    }

    func testStitchedChunksArtifactBoundaryDoesNotSeedABout() {
        // Two clean low-HR chunks stitched with a hard >15s reconnect gap
        // (mirroring stitchedObservedWorkoutPoints' resetGap), plus a brief,
        // noisy artifact blip right at the chunk-1 boundary: each transition
        // jumps >=25bpm, so every sample in the blip is an "unverified
        // reconnect blip" per the sustainedEvidence() contact mask and must
        // not seed or extend an elevated bout. The underlying chunk that saw
        // the reconnect also carried its own artifact-frame counters (as the
        // real aggregate path sums from the stitched sessions), so the
        // candidate is additionally source-compromised per item 3.
        let rest = 55
        let maxHR = 190 // HRR50 threshold ~123.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var points: [SavedSession.Point] = []
        var cursor: TimeInterval = 0
        while cursor < 15 * 60 {
            points.append(SavedSession.Point(t: cursor, bpm: 55))
            cursor += 5
        }
        // Noisy reconnect-boundary blip: alternating big up/down jumps, all
        // clearing the ~123bpm threshold on the "up" samples.
        for bpm in [130, 58, 128, 56] {
            points.append(SavedSession.Point(t: cursor, bpm: bpm))
            cursor += 6
        }
        // Hard stitch gap (workoutContinuityGapLimit + 1).
        cursor += SavedSession.workoutContinuityGapLimit + 1
        let chunk2Start = cursor
        while cursor < chunk2Start + 15 * 60 {
            points.append(SavedSession.Point(t: cursor, bpm: 55))
            cursor += 5
        }

        let session = workoutFixtureSession(start: start,
                                            end: start.addingTimeInterval(cursor),
                                            label: "Stitched observed",
                                            points: points,
                                            rrPoints: nil,
                                            hrRaw2A37: 200,
                                            hrAccepted: 170,
                                            hrZero: 0,
                                            hrArtifactHeld: 20,
                                            hrArtifactDropped: 15,
                                            hrAcceptedGaps: 0,
                                            hrMaxAcceptedGap: SavedSession.workoutContinuityGapLimit + 1)

        XCTAssertTrue(session.hrContactCompromised, "the reconnect that produced the boundary blip must show up in the source's own artifact share")

        let readiness = session.workoutReadiness(rest: rest, maxHR: maxHR)

        XCTAssertLessThan(readiness.elevatedSeconds, 30, "a noisy reconnect blip must not accumulate elevated seconds")
        XCTAssertLessThan(readiness.longestElevatedBout, 30, "a noisy reconnect blip must not seed a qualifying bout")
        XCTAssertFalse(readiness.ready)
        XCTAssertFalse(readiness.reviewWorthyCandidate)
    }

    // MARK: - July-4 stitched-ghost gating fix (2026-07-05)
    //
    // Prior to this fix, `contactCompromised`/`rrDisagreement` were only
    // consulted by `reviewWorthyCandidate` -- `strengthCandidate` and
    // `moderateStrengthReviewCandidate` themselves never guarded on them, so a
    // watchdog-cycling/loose-contact night that failed `ready` for OTHER
    // reasons (e.g. the workout-band bout/elevated-seconds hardening) could
    // still read `strengthCandidate=true` and resurface via the strength
    // review branch. These tests exercise `strengthCandidate`/
    // `moderateStrengthReviewCandidate` directly (not just
    // `reviewWorthyCandidate`) against the same fixture shapes as above.

    func testStrengthCandidateItselfRejectsContactCompromisedSession() {
        // Same watchdog-cycling artifact night as
        // testArtifactContactGapNightProducesNoWorkoutCandidate: peak 120bpm
        // over a 55bpm rest clears the strength peak-over-rest floor and sits
        // within the borderline margin of the HRR50 threshold, so pre-fix
        // this read strengthCandidate=true despite being contact-compromised.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var points: [SavedSession.Point] = []
        var cursor: TimeInterval = 0
        while cursor < 20 * 60 {
            points.append(SavedSession.Point(t: cursor, bpm: 55))
            cursor += 5
        }
        var spacingToggle = false
        let artifactEnd = cursor + 22 * 60
        while cursor < artifactEnd {
            points.append(SavedSession.Point(t: cursor, bpm: 120))
            cursor += spacingToggle ? 12 : 5
            spacingToggle.toggle()
        }
        let tailEnd = cursor + 18 * 60
        while cursor < tailEnd {
            points.append(SavedSession.Point(t: cursor, bpm: 55))
            cursor += 5
        }
        let session = workoutFixtureSession(start: start,
                                            end: start.addingTimeInterval(cursor),
                                            label: "Sleep",
                                            points: points,
                                            rrPoints: nil,
                                            hrRaw2A37: 1_000,
                                            hrAccepted: 600,
                                            hrZero: 300,
                                            hrArtifactHeld: 100,
                                            hrArtifactDropped: 100,
                                            hrAcceptedGaps: 4,
                                            hrMaxAcceptedGap: 150)

        XCTAssertTrue(session.hrContactCompromised)

        let readiness = session.workoutReadiness(rest: 55, maxHR: 190)

        XCTAssertFalse(readiness.strengthCandidate,
                       "a contact-compromised session must never read strengthCandidate=true, independent of reviewWorthyCandidate")
        XCTAssertFalse(readiness.moderateStrengthReviewCandidate,
                       "a contact-compromised session must never read moderateStrengthReviewCandidate=true")
    }

    func testStrengthCandidateItselfRejectsRRDisagreement() {
        // Same RR-contradicts-reported-HR fixture as
        // testRRContradictsElevationIsRejectedByAgreementCeiling: a clean,
        // gap-free 120bpm stream (no artifact/zero share) that clears both
        // the workout-band threshold and the strength peak-over-rest floor,
        // but whose RR channel implies ~55bpm throughout. Pre-fix this read
        // strengthCandidate=true despite the RR contradiction.
        let rest = 50
        let maxHR = 170
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var points: [SavedSession.Point] = []
        var rrPoints: [SavedSession.RRPoint] = []
        var cursor: TimeInterval = 0
        while cursor < 20 * 60 {
            points.append(SavedSession.Point(t: cursor, bpm: 120))
            cursor += 5
        }
        var rrCursor: TimeInterval = 0
        while rrCursor < 20 * 60 {
            rrPoints.append(SavedSession.RRPoint(t: rrCursor,
                                                 ms: 1_090,
                                                 source: .standardHeartRateMeasurement2A37))
            rrCursor += 24
        }
        let session = workoutFixtureSession(start: start,
                                            end: start.addingTimeInterval(cursor),
                                            label: "Contradicted",
                                            points: points,
                                            rrPoints: rrPoints,
                                            hrRaw2A37: points.count,
                                            hrAccepted: points.count,
                                            hrZero: 0,
                                            hrArtifactHeld: 0,
                                            hrArtifactDropped: 0,
                                            hrAcceptedGaps: 0,
                                            hrMaxAcceptedGap: 5)

        XCTAssertTrue(session.hrRRDisagreesWithReportedHR)

        let readiness = session.workoutReadiness(rest: rest, maxHR: maxHR)

        XCTAssertFalse(readiness.strengthCandidate,
                       "RR contradicting reported HR must reject strengthCandidate itself, not just reviewWorthyCandidate")
        XCTAssertFalse(readiness.moderateStrengthReviewCandidate)
    }

    func testPeakOverRestWithZeroRRIsTreatedAsImpliedArtifact() {
        // A clean, gap-free, non-artifact stream (no held/dropped frames, no
        // zero share, no accepted gaps) sustained 90bpm over rest for 25
        // minutes with NO RR/IBI samples anywhere in the window. A genuine
        // effort at this intensity always carries RR; zero RR at this peak
        // is the loose-contact spike fingerprint, so this must be rejected
        // even though every other counter looks clean.
        let rest = 55
        let maxHR = 190
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var points: [SavedSession.Point] = []
        var cursor: TimeInterval = 0
        while cursor < 25 * 60 {
            points.append(SavedSession.Point(t: cursor, bpm: 145)) // peakOverRest = 90
            cursor += 2
        }
        let session = workoutFixtureSession(start: start,
                                            end: start.addingTimeInterval(cursor),
                                            label: "No RR",
                                            points: points,
                                            rrPoints: nil,
                                            hrRaw2A37: points.count,
                                            hrAccepted: points.count,
                                            hrZero: 0,
                                            hrArtifactHeld: 0,
                                            hrArtifactDropped: 0,
                                            hrAcceptedGaps: 0,
                                            hrMaxAcceptedGap: 2)

        XCTAssertFalse(session.hrContactCompromised, "the raw audit counters alone are clean")

        let readiness = session.workoutReadiness(rest: rest, maxHR: maxHR)

        XCTAssertTrue(readiness.contactCompromised,
                      "peak_over_rest>=60 with zero in-window RR must be folded into contactCompromised as an implied artifact")
        XCTAssertFalse(readiness.ready)
        XCTAssertFalse(readiness.strengthCandidate)
        XCTAssertFalse(readiness.reviewWorthyCandidate)
    }

    func testWorkoutReadinessOverridesCarryWorstChunkAggregateSignal() {
        // Mirrors what makeAggregateWorkoutCandidate now threads through for
        // a stitched/aggregate candidate: the synthetic aggregate session's
        // OWN counters can look clean (diluted by stitching), and here RR
        // agrees with the reported HR (no Pillar C/RR-disagreement fold), so
        // strengthCandidate reads true on the raw counters alone -- but a
        // worst-source-chunk override must still reject it, exactly as
        // makeAggregateWorkoutCandidate now supplies from `ordered.contains {
        // $0.hrContactCompromised }` when stitching diluted a compromised
        // source chunk's counters below the aggregate's own ceilings.
        let rest = 55
        let maxHR = 190
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var points: [SavedSession.Point] = []
        var cursor: TimeInterval = 0
        while cursor < 25 * 60 {
            points.append(SavedSession.Point(t: cursor, bpm: 120)) // peakOverRest = 65
            cursor += 2
        }
        var rrPoints: [SavedSession.RRPoint] = []
        var rrCursor: TimeInterval = 0
        while rrCursor < 25 * 60 {
            rrPoints.append(SavedSession.RRPoint(
                t: rrCursor,
                ms: Int((60_000.0 / 120.0).rounded()),
                source: .standardHeartRateMeasurement2A37
            ))
            rrCursor += 24
        }
        let syntheticAggregate = workoutFixtureSession(start: start,
                                                       end: start.addingTimeInterval(cursor),
                                                       label: "Aggregate",
                                                       points: points,
                                                       rrPoints: rrPoints,
                                                       hrRaw2A37: points.count,
                                                       hrAccepted: points.count,
                                                       hrZero: 0,
                                                       hrArtifactHeld: 0,
                                                       hrArtifactDropped: 0,
                                                       hrAcceptedGaps: 0,
                                                       hrMaxAcceptedGap: 2)

        XCTAssertFalse(syntheticAggregate.hrContactCompromised)
        XCTAssertFalse(syntheticAggregate.hrRRDisagreesWithReportedHR)

        let withoutOverride = syntheticAggregate.workoutReadiness(rest: rest, maxHR: maxHR)
        XCTAssertFalse(withoutOverride.contactCompromised,
                       "sanity check: this synthetic aggregate reads clean on its own diluted/summed counters")
        XCTAssertTrue(withoutOverride.strengthCandidate,
                      "sanity check: on its own counters alone this candidate would read strengthCandidate=true")

        let withWorstChunkOverride = syntheticAggregate.workoutReadiness(rest: rest,
                                                                        maxHR: maxHR,
                                                                        contactCompromisedOverride: true,
                                                                        rrDisagreementOverride: nil,
                                                                        rrSampleCountOverride: rrPoints.count)

        XCTAssertTrue(withWorstChunkOverride.contactCompromised,
                      "a worst-source-chunk contact-compromised override must win over the diluted aggregate's own clean counters")
        XCTAssertFalse(withWorstChunkOverride.ready)
        XCTAssertFalse(withWorstChunkOverride.strengthCandidate,
                       "the strength path itself must respect the threaded worst-chunk override, not just reviewWorthyCandidate")
        XCTAssertFalse(withWorstChunkOverride.reviewWorthyCandidate)
    }

    @MainActor
    func testPendingSleepFixtureShowsProvisionalRecovery() {
        #if DEBUG
        let hero = AtriaHomeModel.debugFixtureProvisionalRecoveryHeroSnapshot(arguments: [
            "Atria",
            "--atria-ui-fixture",
            "pending-sleep-provisional-recovery"
        ])
        XCTAssertNotNil(hero)
        XCTAssertNotNil(hero?.recoveryEstimate.percent)
        XCTAssertEqual(hero?.recoveryIsProvisional, true)
        XCTAssertEqual(hero?.recoveryEstimate.confidence, .unverified)
        XCTAssertNotEqual(hero?.recoveryValue, "Learning")

        let now = Date()
        let baseline = PersonalBaseline(restingHR: 60,
                                        hrvEMA: 50,
                                        sessions: PersonalBaseline.trustedMinimumSamples,
                                        updated: now,
                                        samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                 now: now))
        let confirmed = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                         fallbackRMSSD: 56,
                                                         restingNow: 58,
                                                         baseline: baseline,
                                                         hrvReferenceValidated: false,
                                                         sleepEfficiency: 0.91,
                                                         sleepDurationHours: 7.6)
        XCTAssertNotNil(confirmed.percent)
        XCTAssertFalse(confirmed.confidence.rawValue.contains("provisional"))
        #endif
    }

    @MainActor
    func testCarriedRecoveryNamesItsPreviousSleepSource() {
        let estimate = Metrics.RecoveryEstimate(percent: 75,
                                                confidence: .personalBaseline,
                                                usesHRV: true,
                                                detail: "saved morning score",
                                                contributors: [])

        XCTAssertEqual(
            AtriaHomeModel.HeroSnapshot.recoveryDetailText(
                recoveryEstimate: estimate,
                recoveryIsProvisional: false,
                recoveryIsFromPreviousSleep: true,
                recoveryLiftedAfterNap: false
            ),
            // 2026-07-28 deterministic-presentation pass: the status line is now
            // a compact fixed-vocabulary marker rather than prose. The invariant
            // this test names is unchanged -- a carried score still says it came
            // from the previous sleep -- but it says so in 11 characters instead
            // of 44, because at 44 it wrapped and made one compact card taller
            // than the one beside it.
            "prev. sleep"
        )
        XCTAssertEqual(
            AtriaHomeModel.HeroSnapshot.recoveryDetailText(
                recoveryEstimate: estimate,
                recoveryIsProvisional: false,
                recoveryIsFromPreviousSleep: false,
                recoveryLiftedAfterNap: false
            ),
            // Same migration: the raw confidence name ("personal baseline") is
            // 17 characters and would wrap, so a confident score falls back to
            // the level's short label.
            AtriaMetricConfidenceLevel.moderate.shortLabel
        )
    }

    @MainActor
    func testHeroRecoveryWithoutScoreUsesNoValueAndKeepsReasonInDetail() {
        let estimate = Metrics.RecoveryEstimate(
            percent: nil,
            confidence: .learning,
            usesHRV: false,
            detail: "HRV unavailable",
            contributors: []
        )

        XCTAssertEqual(
            AtriaHomeModel.HeroSnapshot.recoveryValueText(
                recoveryEstimate: estimate
            ),
            AtriaCompactMetricPresentation.noValue
        )
        XCTAssertEqual(
            AtriaHomeModel.HeroSnapshot.recoveryDetailText(
                recoveryEstimate: estimate,
                recoveryIsProvisional: true,
                recoveryIsFromPreviousSleep: false,
                recoveryLiftedAfterNap: false
            ),
            "HRV pending"
        )
    }

    func testSavedSleepUnlocksUnverifiedRecoveryBeforeHRVBaselineMatures() {
        let now = Date()
        let sampleCount = 10
        let restingHRValues = [58.0, 60.0, 62.0]
        let rmssdValues = [48.0, 52.0, 56.0, 54.0, 50.0]
        var samples: [PersonalBaseline.BaselineSample] = []
        for index in 0..<sampleCount {
            samples.append(PersonalBaseline.BaselineSample(date: now.addingTimeInterval(Double(-index * 86_400)),
                                                           restingHR: restingHRValues[index % restingHRValues.count],
                                                           rmssd: index < rmssdValues.count ? rmssdValues[index] : nil,
                                                           overnight: index < rmssdValues.count))
        }
        let baseline = PersonalBaseline(restingHR: 60,
                                        hrvEMA: 52,
                                        sessions: sampleCount,
                                        updated: now,
                                        samples: samples)

        let estimate = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                        fallbackRMSSD: 65,
                                                        restingNow: 55,
                                                        baseline: baseline,
                                                        hrvReferenceValidated: false,
                                                        sleepEfficiency: 0.93,
                                                        sleepDurationHours: 8.2,
                                                        respiratoryRate: 14.6)

        XCTAssertNotNil(estimate.percent)
        XCTAssertEqual(estimate.confidence, AtriaAnalytics.Recovery.Estimate.Confidence.unverified)
        XCTAssertTrue(estimate.usesHRV)
        XCTAssertTrue((1...99).contains(estimate.percent ?? 0))
    }

    func testUnknownStrapGenerationProbeStaysFailClosed() {
        let payload: [UInt8] = [0xaa, 0x10, 0x00, 0xa1, 0x2f, 0x18, 0x05, 0xb1, 0x43, 0x2b, 0x01, 0x86]
        let summary = AtriaResearchProbe.analyze(payload: payload, source: .historical)
        XCTAssertEqual(summary.modelGeneration, .unknown)
        XCTAssertEqual(summary.layoutHead, "aa1000a12f1805b1432b0186")
        XCTAssertFalse(summary.hasAnyCandidate)
        XCTAssertFalse(summary.hasExplicitGeneration)
        XCTAssertFalse(summary.allowsGenerationSpecificDecode(strapAllowsGenerationSpecificDecode: true))
    }

    func testTrainingLoadFlagsUnsafeSpikesAndBalancedLoad() {
        let spike = AtriaAnalytics.TrainingLoad.summary(dailyStrains: Array(repeating: 16.0, count: 7)
                                                        + Array(repeating: 8.0, count: 21))
        XCTAssertEqual(spike.confidence, "local")
        XCTAssertEqual(spike.acwrSignal, "bad")
        XCTAssertEqual(spike.readiness, "rundown")

        // Foster training-monotony = mean / SD of the 7 acute days. The previous fixture
        // ([9, 10, 11, 9.5, 10.5, 11, 9] + 21x10) has mean 10 and SD ~0.80, i.e. monotony
        // ~12.5 (capped to 9.99) -- that reads as "bad" (>= 2.50), not the "balanced" week
        // the test claims to model. A day-to-day varied week that still averages to the
        // same acute/chronic load keeps ACWR == 1.0 ("good") while giving the SD room to
        // drop monotony under the "good" threshold (< 2.00):
        //   acute = [2, 18, 4, 16, 6, 14, 10], mean = 10, SD ~5.76 -> monotony ~1.74 (good)
        //   chronic (all 28, remaining 21 days at strain 10) mean = 10 -> ratio = 1.0 (good)
        let balancedHistory = [2.0, 18.0, 4.0, 16.0, 6.0, 14.0, 10.0]
            + Array(repeating: 10.0, count: 21)
        let balanced = AtriaAnalytics.TrainingLoad.summary(dailyStrains: balancedHistory)
        XCTAssertEqual(balanced.confidence, "local")
        XCTAssertEqual(balanced.acwrSignal, "good")
        XCTAssertEqual(balanced.monotonySignal, "good")
        XCTAssertEqual(balanced.readiness, "balanced")
        XCTAssertNotNil(balanced.targetBand)
    }

    func testClosedSleepCandidateWaitsForLaterFragmentsBeforeAutoConfirmation() {
        let end = Date(timeIntervalSinceReferenceDate: 805_336_121)
        XCTAssertFalse(SessionStore.sleepCandidateIsSettledForClosedAutoConfirmation(
            candidateEnd: end,
            now: end.addingTimeInterval(29 * 60 + 59)
        ))
        XCTAssertTrue(SessionStore.sleepCandidateIsSettledForClosedAutoConfirmation(
            candidateEnd: end,
            now: end.addingTimeInterval(30 * 60)
        ))
    }

    func testTargetZonesUseHandoffThresholdsAndStayBaselineGated() {
        XCTAssertEqual(AtriaAnalytics.TargetZones.recovery(67)?.level, .green)
        XCTAssertEqual(AtriaAnalytics.TargetZones.recovery(34)?.level, .yellow)
        XCTAssertEqual(AtriaAnalytics.TargetZones.recovery(33)?.level, .red)
        XCTAssertEqual(AtriaAnalytics.TargetZones.recovery(33)?.warningSystemImage,
                       "exclamationmark.triangle.fill")
        XCTAssertTrue(AtriaAnalytics.TargetZones.recovery(33)?.disclaimer.lowercased().contains("not medical advice") == true)

        XCTAssertNil(AtriaAnalytics.TargetZones.hrv(70,
                                                    baseline: 80,
                                                    baselineSamples: PersonalBaseline.trustedMinimumSamples - 1,
                                                    baselineTrusted: true))
        XCTAssertNil(AtriaAnalytics.TargetZones.restingHeartRate(66,
                                                                 baseline: 60,
                                                                 baselineSamples: PersonalBaseline.trustedMinimumSamples,
                                                                 baselineTrusted: false))

        let lowHRV = AtriaAnalytics.TargetZones.hrv(64,
                                                    baseline: 80,
                                                    baselineSamples: PersonalBaseline.trustedMinimumSamples,
                                                    baselineTrusted: true)
        XCTAssertEqual(lowHRV?.level, .red)
        XCTAssertEqual(lowHRV?.warningSystemImage, "exclamationmark.triangle.fill")
        XCTAssertTrue(lowHRV?.targetSummary.contains("Personal baseline") == true)

        let elevatedRHR = AtriaAnalytics.TargetZones.restingHeartRate(64,
                                                                     baseline: 60,
                                                                     baselineSamples: PersonalBaseline.trustedMinimumSamples,
                                                                     baselineTrusted: true)
        XCTAssertEqual(elevatedRHR?.level, .yellow)
        XCTAssertEqual(elevatedRHR?.warningSystemImage, "exclamationmark.circle")
    }

    func testPureDailyAggregationsHandleStepsCaloriesAndZones() {
        let strapSteps = AtriaAnalytics.Daily.stepsDaily([
            .init(steps: 120, distanceMeters: 80, floorsAscended: 1, floorsDescended: 0),
            .init(steps: -20, distanceMeters: nil, floorsAscended: nil, floorsDescended: 2),
            .init(steps: 380, distanceMeters: 220, floorsAscended: 3, floorsDescended: -1)
        ])

        XCTAssertEqual(strapSteps.steps, 500)
        XCTAssertEqual(strapSteps.distanceMeters, 300)
        XCTAssertEqual(strapSteps.floorsAscended, 4)
        XCTAssertEqual(strapSteps.floorsDescended, 2)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AthleteProfile(age: 35,
                                     measuredMaxHR: 185,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     weightKg: 75,
                                     heightCm: 178,
                                     updated: nil,
                                     hasCompletedOnboarding: true)
        let activeCalories = AtriaAnalytics.Daily.dayCalories(
            stride(from: 0.0, through: 120.0, by: 10.0).map { offset in
                .init(t: start.addingTimeInterval(offset),
                      bpm: offset == 0 ? 60 : (offset <= 60 ? 130 : 150))
            },
            rest: 60,
            profile: profile
        )
        XCTAssertGreaterThan(activeCalories ?? 0, 4.0)

        let gapDroppedCalories = AtriaAnalytics.Daily.dayCalories([
            .init(t: start, bpm: 60),
            .init(t: start.addingTimeInterval(600), bpm: 150)
        ], rest: 60, profile: profile)
        XCTAssertEqual(gapDroppedCalories, 0)

        let zoneSeconds = AtriaAnalytics.Strain.maxHeartRateZoneSeconds([
            (0, 90), (10, 110), (20, 130), (30, 150), (40, 170), (50, 190), (650, 190)
        ], maxHR: 200)
        XCTAssertEqual(zoneSeconds.rest, 0)
        XCTAssertEqual(zoneSeconds.warmup, 10)
        XCTAssertEqual(zoneSeconds.fatBurn, 10)
        XCTAssertEqual(zoneSeconds.aerobic, 10)
        XCTAssertEqual(zoneSeconds.anaerobic, 10)
        XCTAssertEqual(zoneSeconds.max, 10)
        XCTAssertEqual(zoneSeconds.droppedGapSeconds, 600)
    }

    func testMaxHeartRateZoneBoundariesAndBanisterCoefficientAreStable() {
        // Zone edges are inclusive-lower: exactly 50/60/70/80/90% of maxHR steps
        // up a zone; one bpm below stays in the lower zone. A silent boundary
        // shift or coefficient swap would corrupt every strain/recovery score, so
        // pin the contract these integrators depend on.
        func zone(_ bpm: Int) -> Int {
            AtriaAnalytics.Strain.maxHeartRateZoneRawValue(for: bpm, maxHR: 200)
        }
        XCTAssertEqual(zone(100), 1) // 0.50 → warmup
        XCTAssertEqual(zone(99), 0)  // just below 0.50 → rest
        XCTAssertEqual(zone(120), 2) // 0.60
        XCTAssertEqual(zone(119), 1)
        XCTAssertEqual(zone(140), 3) // 0.70
        XCTAssertEqual(zone(139), 2)
        XCTAssertEqual(zone(160), 4) // 0.80
        XCTAssertEqual(zone(159), 3)
        XCTAssertEqual(zone(180), 5) // 0.90
        XCTAssertEqual(zone(179), 4)
        XCTAssertEqual(zone(200), 5) // at max
        // Degenerate inputs fail safe to zone 0 (never crash / negative).
        XCTAssertEqual(zone(0), 0)
        XCTAssertEqual(AtriaAnalytics.Strain.maxHeartRateZoneRawValue(for: 120, maxHR: 0), 0)

        // Banister TRIMP sex weighting must not drift or swap.
        XCTAssertEqual(AtriaAnalytics.Strain.banisterCoefficient(for: .female), 1.67, accuracy: 1e-9)
        XCTAssertEqual(AtriaAnalytics.Strain.banisterCoefficient(for: .male), 1.92, accuracy: 1e-9)
        XCTAssertEqual(AtriaAnalytics.Strain.banisterCoefficient(for: .unspecified), 1.92, accuracy: 1e-9)
    }

    func testBodyAgeAndResearchZonesAreHonestEstimates() {
        let readySummary = AtriaAnalytics.BiologicalAge.summary(
            chronologicalAge: 40,
            factors: [
                AtriaAnalytics.BiologicalAge.factor(id: "vo2",
                                                    label: "VO2max",
                                                    ageEquivalent: 47,
                                                    chronologicalAge: 40,
                                                    weight: 1,
                                                    detail: "below trend")
            ]
        )
        let bodyAgeZone = AtriaAnalytics.TargetZones.biologicalAge(readySummary,
                                                                   greenOlderDelta: 0,
                                                                   yellowOlderDelta: 3)
        XCTAssertEqual(bodyAgeZone?.level, .red)
        XCTAssertTrue(bodyAgeZone?.disclaimer.lowercased().contains("estimate") == true)

        let building = BiologicalAgeSummary.building(chronologicalAge: 40,
                                                     blockers: ["14 fresh HRV baseline nights"])
        XCTAssertNil(AtriaAnalytics.TargetZones.biologicalAge(building))

        XCTAssertNil(AtriaAnalytics.TargetZones.respiratoryRate(18.0,
                                                               baseline: 16.0,
                                                               baselineSamples: 2))
        let respiratory = AtriaAnalytics.TargetZones.respiratoryRate(19.5,
                                                                    baseline: 16.0,
                                                                    baselineSamples: 3,
                                                                    greenDelta: 1.5,
                                                                    yellowDelta: 3.0)
        XCTAssertEqual(respiratory?.level, .red)
        // docs/24 COPY-1 pass (2026-07-02) removed the visible "Research ..." wording
        // app-wide; respiratory-rate zones now disclose "Early sleep-only signal" instead
        // of the old "Research sleep-only estimate" copy.
        XCTAssertTrue(respiratory?.disclaimer.contains("Early sleep-only signal") == true)
    }

    func testFullArchiveMotionDiagnosticsFailClosedOnMainThread() {
        XCTAssertTrue(Thread.isMainThread)
        HistoricalArchive.resetFullGravityLoadCountForTesting()

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let diagnostics = HistoricalArchive.motionWindowDiagnostics(start: start,
                                                                    end: start.addingTimeInterval(60))

        XCTAssertEqual(diagnostics.reason, "full_archive_requires_background")
        XCTAssertEqual(HistoricalArchive.fullGravityLoadCountForTesting, 0)
    }

    func testFullArchiveMotionSnapshotLoadsOnceForMultipleWindows() throws {
        try withCleanHistoricalArchive {
            HistoricalArchive.resetFullGravityLoadCountForTesting()
            let start = Date(timeIntervalSince1970: 1_800_000_000)

            let loadCount = runOffMain {
                let snapshot = HistoricalArchive.makeMotionArchiveSnapshot()
                _ = snapshot.diagnostics(start: start, end: start.addingTimeInterval(30 * 60))
                _ = snapshot.diagnostics(start: start.addingTimeInterval(30 * 60),
                                         end: start.addingTimeInterval(60 * 60))
                return HistoricalArchive.fullGravityLoadCountForTesting
            }

            XCTAssertEqual(loadCount, 1)
        }
    }

    func testFullArchiveSleepAggregationNeverLoadsArchiveOnMainThread() {
        XCTAssertTrue(Thread.isMainThread)
        HistoricalArchive.resetFullGravityLoadCountForTesting()
        let start = utcDate(2027, 3, 2, 0, 0)
        let session = flatHRSession(start: start,
                                    end: start.addingTimeInterval(4 * 60 * 60),
                                    bpm: 52)

        _ = SessionStore.aggregateSleepCandidates(in: [session],
                                                  rest: 50,
                                                  maxHR: 190,
                                                  calendar: utcCalendar,
                                                  historicalMotionPolicy: .fullArchive)

        XCTAssertEqual(HistoricalArchive.fullGravityLoadCountForTesting, 0)
    }

    func testFullArchiveSleepAggregationLoadsOnceAcrossCandidateWindows() throws {
        try withCleanHistoricalArchive {
            HistoricalArchive.resetFullGravityLoadCountForTesting()
            let firstStart = utcDate(2027, 3, 2, 0, 0)
            let secondStart = utcDate(2027, 3, 3, 0, 0)
            let sessions = [
                flatHRSession(start: firstStart,
                              end: firstStart.addingTimeInterval(6 * 60 * 60),
                              bpm: 52,
                              stepSeconds: 10),
                flatHRSession(start: secondStart,
                              end: secondStart.addingTimeInterval(6 * 60 * 60),
                              bpm: 52,
                              stepSeconds: 10),
            ]

            let result = runOffMain {
                let candidates = SessionStore.aggregateSleepCandidates(in: sessions,
                                                                       rest: 50,
                                                                       maxHR: 190,
                                                                       calendar: self.utcCalendar,
                                                                       historicalMotionPolicy: .fullArchive)
                return (candidates.count, HistoricalArchive.fullGravityLoadCountForTesting)
            }

            XCTAssertEqual(result.0, 2)
            XCTAssertEqual(result.1, 1)
        }
    }

    func testHistoricalArchiveStatusFailsClosedUntilArchiveIsParseable() {
        let parseFailed = SessionStore.HistoricalArchiveStatus(exists: true,
                                                               parseOK: false,
                                                               rows: 12,
                                                               metricUsableRows: 4,
                                                               currentSessionUsableRows: 4,
                                                               reason: "invalid_jsonl_row_12")
        XCTAssertFalse(parseFailed.metricReady)
        XCTAssertEqual(parseFailed.valueText, "Repair")
        // A partial row count must not make an unreadable archive look usable.
        XCTAssertEqual(parseFailed.metricGateText, "Repair needed")
        XCTAssertEqual(parseFailed.userFootnoteText, "Archive needs repair.")

        let gated = SessionStore.HistoricalArchiveStatus(exists: true,
                                                         parseOK: true,
                                                         rows: 12,
                                                         metricUsableRows: 0,
                                                         currentSessionUsableRows: 8,
                                                         reason: "ok")
        XCTAssertFalse(gated.metricReady)
        XCTAssertEqual(gated.valueText, "Saved")
        XCTAssertEqual(gated.metricGateText, "Raw only")
        XCTAssertTrue(gated.userFootnoteText.contains("raw history rows saved"))
        XCTAssertTrue(gated.userFootnoteText.contains("Missing time stays excluded"))

        let ready = SessionStore.HistoricalArchiveStatus(exists: true,
                                                         parseOK: true,
                                                         rows: 12,
                                                         metricUsableRows: 3,
                                                         currentSessionUsableRows: 3,
                                                         reason: "ok")
        XCTAssertTrue(ready.metricReady)
        XCTAssertEqual(ready.valueText, "Ready")
        XCTAssertEqual(ready.metricGateText, "Metric-ready")
    }

    func testHistoricalArchiveDiagnosticsInferReplayRowsWithoutPromotingMetrics() throws {
        try withCleanHistoricalArchive {
            let payload = historicalPayloadWithGravity(x: 0, y: 0, z: 1)
            let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                                  capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                  source: "0x2f",
                                                  layoutVersion: HistoricalArchive.layoutVersion,
                                                  sequence: 7,
                                                  command: 0x16,
                                                  unix7: 1_800_000_000,
                                                  subsec11: 0,
                                                  flash13: 42,
                                                  payloadLength: payload.count,
                                                  whoofHR17: 61,
                                                  whoofRRNum18: 2,
                                                  whoofRR19: [980, 1_010],
                                                  kRR64: [980, 1_010],
                                                  gravityX36: 0,
                                                  gravityY40: 0,
                                                  gravityZ44: 1,
                                                  gravityMagnitude: 1,
                                                  gravityValidated: true,
                                                  candidateRR: ["whoof19", "k64"],
                                                  rawPayloadHex: HistoricalArchive.hex(payload),
                                                  clockDeviceRef: 1_800_000_000,
                                                  clockWallRef: 1_800_000_000,
                                                  clockDriftSeconds: 0,
                                                  clockCorrectedUnix7: 1_800_000_000,
                                                  clockCorrectionStatus: "corrected",
                                                  currentSessionUsable: false,
                                                  metricUsable: false,
                                                  usabilityReason: "provisional_historical_layout_old_or_unvalidated")

            _ = try HistoricalArchive.append(record)

            let diagnostics = HistoricalArchive.diagnostics()
            XCTAssertTrue(diagnostics.exists)
            XCTAssertTrue(diagnostics.parseOK)
            XCTAssertEqual(diagnostics.rows, 1)
            XCTAssertEqual(diagnostics.rawPayloadRows, 1)
            XCTAssertEqual(diagnostics.gravityRows, 1)
            XCTAssertEqual(diagnostics.gravityValidatedRows, 1)
            XCTAssertEqual(diagnostics.currentSessionUsableRows, 1)
            XCTAssertEqual(diagnostics.metricUsableRows, 0)
            // A freshly appended row is served from the just-written diagnostics
            // sidecar index (no rotated segments yet), so the reason is "index_ok"
            // rather than a bare "ok". See HistoricalArchive.diagnostics().
            XCTAssertEqual(diagnostics.reason, "index_ok")

            let status = SessionStore.HistoricalArchiveStatus(diagnostics: diagnostics)
            XCTAssertEqual(status.valueText, "Saved")
            XCTAssertFalse(status.metricReady)
        }
    }

    func testHistoricalArchiveDiagnosticsRejectIncidentalRRWithoutValidatedMotion() throws {
        try withCleanHistoricalArchive {
            let payload = historicalPayloadWithGravity(x: 0, y: 0, z: 0)
            let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                                  capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                  source: "0x2f",
                                                  layoutVersion: HistoricalArchive.layoutVersion,
                                                  sequence: 8,
                                                  command: 0x16,
                                                  unix7: 1_800_000_000,
                                                  subsec11: 0,
                                                  flash13: 43,
                                                  payloadLength: payload.count,
                                                  whoofHR17: 61,
                                                  whoofRRNum18: 2,
                                                  whoofRR19: [980, 1_010],
                                                  kRR64: [],
                                                  gravityX36: 0,
                                                  gravityY40: 0,
                                                  gravityZ44: 0,
                                                  gravityMagnitude: 0,
                                                  gravityValidated: false,
                                                  candidateRR: ["whoof19", "k64"],
                                                  rawPayloadHex: HistoricalArchive.hex(payload),
                                                  clockDeviceRef: 1_800_000_000,
                                                  clockWallRef: 1_800_000_000,
                                                  clockDriftSeconds: 0,
                                                  clockCorrectedUnix7: 1_800_000_000,
                                                  clockCorrectionStatus: "corrected",
                                                  currentSessionUsable: false,
                                                  metricUsable: false,
                                                  usabilityReason: "provisional_historical_layout_old_or_unvalidated")

            _ = try HistoricalArchive.append(record)

            let diagnostics = HistoricalArchive.diagnostics()
            XCTAssertEqual(diagnostics.currentSessionUsableRows, 0)
            XCTAssertEqual(diagnostics.metricUsableRows, 0)
        }
    }

    func testVitalsHeartRateTimelineMergesArchiveGapAndLetsLiveWin() {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let historical = [
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(0), bpm: 61),
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(60), bpm: 62),
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(120), bpm: 63),
        ]
        let live = [
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(120), bpm: 91),
            AtriaHomeModel.HeartRateChartPoint(t: start.addingTimeInterval(180), bpm: 92),
        ]

        // Merge de-dups by second (live overrides historical at t=120) and
        // sorts ascending; it no longer pre-downsamples (2026-07-07 rework).
        let merged = AtriaVitalsHeartRateTimeline.mergedHeartRatePoints(live: live,
                                                                        historical: historical)

        XCTAssertEqual(merged.map { Int($0.t.timeIntervalSince(start)) }, [0, 60, 120, 180])
        XCTAssertEqual(merged.map(\.bpm), [61, 62, 91, 92])
    }

    func testHistoricalArchiveMetricHeartRatePointsRejectUnprovenRowDespiteValidatedLayout() throws {
        try withCleanHistoricalArchive {
            let anchor = Date(timeIntervalSince1970: 1_800_200_000)
            for index in 0..<5 {
                let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                                      capturedAt: anchor.addingTimeInterval(Double(index * 60)),
                                                      source: "0x2f",
                                                      layoutVersion: HistoricalArchive.layoutVersion,
                                                      sequence: index,
                                                      command: 47,
                                                      unix7: UInt32(1_800_200_000 + index * 60),
                                                      subsec11: 0,
                                                      flash13: UInt32(index),
                                                      payloadLength: 0,
                                                      whoofHR17: 60 + index,
                                                      whoofRRNum18: 0,
                                                      whoofRR19: [],
                                                      kRR64: [],
                                                      gravityX36: nil,
                                                      gravityY40: nil,
                                                      gravityZ44: nil,
                                                      gravityMagnitude: nil,
                                                      gravityValidated: false,
                                                      candidateRR: [],
                                                      rawPayloadHex: "",
                                                      clockDeviceRef: nil,
                                                      clockWallRef: nil,
                                                      clockDriftSeconds: nil,
                                                      clockCorrectedUnix7: nil,
                                                      clockCorrectionStatus: "fixture",
                                                      currentSessionUsable: true,
                                                      metricUsable: true,
                                                      usabilityReason: "fixture")
                _ = try HistoricalArchive.append(record)
            }

            let points = HistoricalArchive.metricHeartRatePoints(since: nil, limit: 3)

            XCTAssertTrue(points.isEmpty)
            XCTAssertTrue(HistoricalArchive.metricLayoutValidated(HistoricalArchive.layoutVersion))
            XCTAssertEqual(HistoricalArchive.diagnostics().metricUsableRows, 0)
            XCTAssertFalse(HistoricalArchive.quickMetricReadinessProbe().ready)
        }
    }

    private func reducedRecoveryWearSession(now: Date,
                                            bpm: Int,
                                            rrSeconds: Int,
                                            mixedProvenance: Bool) -> SavedSession {
        let start = now.addingTimeInterval(-7 * 3_600)
        let end = now.addingTimeInterval(-60 * 60)
        let points = stride(from: 0.0,
                            through: end.timeIntervalSince(start),
                            by: 60.0).map {
            SavedSession.Point(t: $0, bpm: bpm)
        }
        let rrPoints: [SavedSession.RRPoint]? = rrSeconds > 0
            ? (0...rrSeconds).map { second in
                let source: AtriaRRSourceProvenance = mixedProvenance && second == rrSeconds / 2
                    ? .validatedProprietaryRealtime
                    : .standardHeartRateMeasurement2A37
                return SavedSession.RRPoint(t: Double(second),
                                            ms: second.isMultiple(of: 2) ? 980 : 1_020,
                                            source: source)
            }
            : nil
        return SavedSession(id: UUID(),
                            start: start,
                            end: end,
                            label: "Unconfirmed clean wear",
                            points: points,
                            rrPoints: rrPoints,
                            eventTimeZoneIdentifier: utcCalendar.timeZone.identifier)
    }

    private func priorConfirmedSleepSnapshot(now: Date) -> SleepHistorySnapshot {
        let end = now.addingTimeInterval(-30 * 3_600)
        let start = end.addingTimeInterval(-8 * 3_600)
        let sleep = UserConfirmedSleep(id: "prior-main-sleep",
                                       createdAt: end,
                                       start: start,
                                       end: end,
                                       source: "manual_sleep",
                                       confidence: "manual_user_entered",
                                       sessions: 0,
                                       samples: 0,
                                       avgHR: 58,
                                       peakHR: 62,
                                       restingHR: 56,
                                       hrv: 52,
                                       hrvWindowCount: 3,
                                       duration: end.timeIntervalSince(start),
                                       span: end.timeIntervalSince(start),
                                       reason: "test prior boundary",
                                       motionSource: "manual",
                                       motionValidated: false,
                                       stageSegments: nil,
                                       eventTimeZoneIdentifier: utcCalendar.timeZone.identifier)
        return SleepHistorySnapshot(rollups: [],
                                    confirmedSleeps: [sleep],
                                    calendar: utcCalendar)
    }

    private func baselineSamples(count: Int, now: Date) -> [PersonalBaseline.BaselineSample] {
        (0..<count).map { index in
            PersonalBaseline.BaselineSample(date: now.addingTimeInterval(Double(-index * 86_400)),
                                            restingHR: [58.0, 60.0, 62.0][index % 3],
                                            rmssd: [48.0, 52.0, 56.0][index % 3],
                                            overnight: true)
        }
    }

    private func syntheticSleepSamples(start: Date) -> [AtriaSleepWakeResearch.HeartSample] {
        stride(from: 0, through: 4 * 60 * 60, by: 30).map { second in
            let minute = Double(second) / 60.0
            let bpm: Int
            switch minute {
            case ..<20:
                bpm = 74
            case ..<80:
                bpm = 61 + ((second / 30).isMultiple(of: 8) ? 1 : 0)
            case ..<150:
                bpm = (second / 30).isMultiple(of: 2) ? 64 : 72
            case ..<205:
                bpm = 66
            case ..<230:
                bpm = 69
            default:
                bpm = 73
            }
            return AtriaSleepWakeResearch.HeartSample(t: start.addingTimeInterval(TimeInterval(second)),
                                                      bpm: bpm)
        }
    }

    func testWeeklyPlanGeneratorPicksThreeTargetsFromGapFixture() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(weekday: 4, weekOfYear: 27, yearForWeekOfYear: 2026))!
        let start = calendar.date(byAdding: .day, value: -27, to: calendar.startOfDay(for: now))!
        let rhrStat = DailyRollupVitals.Stat(mean: 58, sd: 2, n: 14)
        let vitals = DailyRollupVitals(rhr: rhrStat, hrv: nil, resp: nil)
        let rollups = (0..<28).map { offset in
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day, value: offset, to: start)!,
                                  rhr: offset >= 24 ? 59 : 58,
                                  sleepSeconds: 7.5 * 3_600,
                                  bedtimeMinutes: offset >= 24 ? 23 * 60 + 50 : 23 * 60,
                                  strain: offset.isMultiple(of: 7) ? 11 : 6,
                                  vitals: vitals,
                                  calendar: calendar)
        }

        let targets = WeeklyPlan.generate(from: rollups, now: now, calendar: calendar)

        XCTAssertEqual(targets.count, 3)
        XCTAssertEqual(Set(targets.map { $0.kind }), Set(WeeklyPlanTarget.Kind.allCases))
        XCTAssertTrue(targets.allSatisfy { $0.goal > 0 })
        XCTAssertTrue(targets.allSatisfy { $0.progress >= 0 && $0.progress <= 1 })
        XCTAssertTrue(targets.allSatisfy { target in
            let shown = Double(target.progressText.split(separator: "/").first ?? "0") ?? 0
            return shown <= target.goal
        })

        let unordered = [rollups[12], rollups[3], rollups[27]]
            + rollups.enumerated()
                .filter { ![12, 3, 27].contains($0.offset) }
                .map(\.element)
        XCTAssertEqual(WeeklyPlan.generate(from: unordered, now: now, calendar: calendar),
                       targets,
                       "Weekly plan generation should not require pre-sorted rollups.")
    }

    func testWeeklyPlanStoreFreezesTargetsAndRecomputesCurrentWeekProgress() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-weekly-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WeeklyPlanStore(directory: directory)
        let monday = calendar.date(from: DateComponents(weekday: 2, weekOfYear: 27, yearForWeekOfYear: 2026))!
        let tuesday = calendar.date(byAdding: .day, value: 1, to: monday)!
        let rhrStat = DailyRollupVitals.Stat(mean: 58, sd: 2, n: 14)
        let vitals = DailyRollupVitals(rhr: rhrStat, hrv: nil, resp: nil)
        let seed = [
            DailyRollupStoreEntry(day: monday,
                                  rhr: 58,
                                  bedtimeMinutes: 23 * 60,
                                  strain: 5,
                                  vitals: vitals,
                                  calendar: calendar)
        ]
        let firstPlan = store.currentPlan(rollups: seed, now: monday, calendar: calendar)
        let updated = seed + [
            DailyRollupStoreEntry(day: tuesday,
                                  rhr: 58,
                                  bedtimeMinutes: 23 * 60,
                                  strain: 11,
                                  vitals: vitals,
                                  calendar: calendar)
        ]

        let secondPlan = store.currentPlan(rollups: updated, now: tuesday, calendar: calendar)

        XCTAssertEqual(firstPlan.targets.map { $0.id }, secondPlan.targets.map { $0.id })
        XCTAssertEqual(firstPlan.targets.map { $0.title }, secondPlan.targets.map { $0.title })
        XCTAssertGreaterThanOrEqual(secondPlan.targets.reduce(0) { $0 + $1.current },
                                    firstPlan.targets.reduce(0) { $0 + $1.current })
    }

    func testFitnessAgeUsesVO2AndClampsBoundaryOffsets() {
        XCTAssertEqual(AtriaFitnessAge.vo2MaxOffset(age: 40, vo2Max: 60, sex: .male), -6)
        XCTAssertEqual(AtriaFitnessAge.vo2MaxOffset(age: 40, vo2Max: 20, sex: .male), 6)
        XCTAssertEqual(AtriaFitnessAge.vo2MaxOffset(age: 40, vo2Max: .nan, sex: .male), 0)
        XCTAssertEqual(AtriaFitnessAge.restingHeartRateOffset(age: 40, restingHeartRate: 52), -6)
        XCTAssertEqual(AtriaFitnessAge.restingHeartRateOffset(age: 40, restingHeartRate: 72), 6)
        XCTAssertEqual(AtriaFitnessAge.zone2PlusOffset(minutes: 0), 4)
        XCTAssertEqual(AtriaFitnessAge.zone2PlusOffset(minutes: 300), -4)
        XCTAssertEqual(AtriaFitnessAge.sleepConsistencyOffset(percent: 50), 3)
        XCTAssertEqual(AtriaFitnessAge.sleepConsistencyOffset(percent: 95), -3)

        let ready = AtriaFitnessAge.summary(inputs: AtriaFitnessAge.Inputs(chronologicalAge: 40,
                                                                          biologicalSex: .male,
                                                                          vo2Max: 50,
                                                                          restingHeartRate: 52,
                                                                          hrvRMSSD: 80,
                                                                          weeklyZone2PlusMinutes: 300,
                                                                          sleepConsistencyPercent: 95,
                                                                          historyDays: 28))

        XCTAssertEqual(ready.biologicalAge, 28)
        XCTAssertEqual(ready.ageDelta, -12)
        XCTAssertEqual(ready.factors.map(\.id), ["vo2max", "rhr", "lnrmssd", "zone2", "sleep_consistency"])
        XCTAssertEqual(ready.footnote, AtriaFitnessAge.footnoteText)
        XCTAssertTrue(ready.agingPaceDetail.contains("helping"))
        XCTAssertNil(ready.earlyEstimateDayCount)
        XCTAssertFalse(ready.isEarlyEstimate)
        XCTAssertNil(ready.earlyEstimateQualifierText)
    }

    private func fitnessAgeSummary(historyDays: Int) -> BiologicalAgeSummary {
        AtriaFitnessAge.summary(inputs: AtriaFitnessAge.Inputs(chronologicalAge: 40,
                                                               biologicalSex: .female,
                                                               vo2Max: 36,
                                                               restingHeartRate: 58,
                                                               hrvRMSSD: 55,
                                                               weeklyZone2PlusMinutes: 180,
                                                               sleepConsistencyPercent: 88,
                                                               historyDays: historyDays))
    }

    func testFitnessAgeStaysCalibratingUntilFourteenDays() {
        let summary = fitnessAgeSummary(historyDays: 13)

        XCTAssertNil(summary.biologicalAge)
        XCTAssertEqual(summary.agingPaceText, "Calibrating")
        XCTAssertTrue(summary.blockers.contains("14 days of heart data"))
        XCTAssertFalse(summary.isEarlyEstimate)
        XCTAssertNil(summary.earlyEstimateQualifierText)
        XCTAssertEqual(summary.footnote, AtriaFitnessAge.footnoteText)
    }

    func testFitnessAgeShowsEarlyEstimateFromFourteenDays() {
        let summary = fitnessAgeSummary(historyDays: 14)

        XCTAssertNotNil(summary.biologicalAge)
        XCTAssertTrue(summary.blockers.isEmpty)
        XCTAssertTrue(summary.isEarlyEstimate)
        XCTAssertEqual(summary.earlyEstimateDayCount, 14)
        XCTAssertEqual(summary.earlyEstimateQualifierText, "Early estimate · day 14 of 28")
        XCTAssertEqual(summary.footnote, AtriaFitnessAge.footnoteText)
    }

    func testFitnessAgeStaysEarlyThroughDayTwentySeven() {
        let summary = fitnessAgeSummary(historyDays: 27)

        XCTAssertNotNil(summary.biologicalAge)
        XCTAssertTrue(summary.isEarlyEstimate)
        XCTAssertEqual(summary.earlyEstimateDayCount, 27)
        XCTAssertEqual(summary.earlyEstimateQualifierText, "Early estimate · day 27 of 28")
    }

    func testFitnessAgeBecomesConfidentAtTwentyEightDays() {
        let summary = fitnessAgeSummary(historyDays: 28)

        XCTAssertNotNil(summary.biologicalAge)
        XCTAssertFalse(summary.isEarlyEstimate)
        XCTAssertNil(summary.earlyEstimateDayCount)
        XCTAssertNil(summary.earlyEstimateQualifierText)
        // Same estimate as the early phase — only the confidence changed.
        XCTAssertEqual(summary.biologicalAge, fitnessAgeSummary(historyDays: 14).biologicalAge)
    }

    func testFitnessAgePaceRequiresFourWeeklyChecks() {
        let calendar = Calendar(identifier: .gregorian)
        func deltas(weeks: Int) -> [AtriaFitnessAge.DailyDelta] {
            (0..<weeks).map { offset in
                let day = calendar.date(byAdding: .weekOfYear, value: offset, to: Date(timeIntervalSince1970: 1_780_000_000))!
                return AtriaFitnessAge.DailyDelta(day: day, delta: 0)
            }
        }

        let thin = AtriaFitnessAge.paceOfAging(deltas: deltas(weeks: 3), calendar: calendar)
        XCTAssertFalse(thin.isReady)
        XCTAssertNil(thin.yearsPerCalendarYear)
        XCTAssertEqual(thin.copyText, AtriaFitnessAge.paceCalibratingCopy)

        let ready = AtriaFitnessAge.paceOfAging(deltas: deltas(weeks: 4), calendar: calendar)
        XCTAssertTrue(ready.isReady)
        XCTAssertNotNil(ready.yearsPerCalendarYear)
    }

    func testFitnessAgePaceDoesNotTreatDailyCopiesAsIndependentChecks() {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: start)!.start
        let dailyCopies = (0..<3).flatMap { week in
            (0..<7).map { day in
                AtriaFitnessAge.DailyDelta(
                    day: calendar.date(byAdding: .day, value: week * 7 + day, to: weekStart)!,
                    delta: -1
                )
            }
        }

        let observations = AtriaFitnessAge.weeklyObservations(from: dailyCopies, calendar: calendar)
        XCTAssertEqual(observations.count, 3)
        XCTAssertFalse(AtriaFitnessAge.paceOfAging(deltas: dailyCopies, calendar: calendar).isReady)
    }

    func testFitnessAgeWeeklyObservationKeepsLatestValueAndNormalizesDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = Date(timeIntervalSince1970: 1_780_000_000)
        let monday = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: anchor)?.start)
        let later = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: monday))
        let observations = AtriaFitnessAge.weeklyObservations(from: [
            .init(day: monday, delta: 2),
            .init(day: later, delta: -3)
        ], calendar: calendar)

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].delta, -3)
        XCTAssertEqual(observations[0].day, calendar.dateInterval(of: .weekOfYear, for: later)?.start)
    }

    func testFitnessAgePaceSlopeCopyMatchesDeltaTrend() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        // Fitness-age delta drifting up by exactly 1 year every 365.25 days
        // produces a 2.0 y/year biological pace, 1.0 faster than the clock.
        let agingFaster: [AtriaFitnessAge.DailyDelta] = (0..<40).map { offset in
            let day = calendar.date(byAdding: .day, value: offset * 30, to: start)!
            let delta = Int((Double(offset) * 30.0 / 365.25).rounded())
            return AtriaFitnessAge.DailyDelta(day: day, delta: delta)
        }
        let faster = AtriaFitnessAge.paceOfAging(deltas: agingFaster)
        XCTAssertTrue(faster.isReady)
        let fasterSlope = try XCTUnwrap(faster.yearsPerCalendarYear)
        XCTAssertEqual(fasterSlope, 2.0, accuracy: 0.15)
        XCTAssertTrue(faster.copyText.contains("faster than the clock"), faster.copyText)
        XCTAssertTrue(faster.copyText.hasPrefix("Aging ~"), faster.copyText)

        // A flat -1 delta means fitness age remains one year younger while both
        // ages advance together, so biological aging matches the clock at 1 y/year.
        let steadyYounger: [AtriaFitnessAge.DailyDelta] = (0..<40).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            return AtriaFitnessAge.DailyDelta(day: day, delta: -1)
        }
        let sameAsClock = AtriaFitnessAge.paceOfAging(deltas: steadyYounger)
        XCTAssertTrue(sameAsClock.isReady)
        XCTAssertEqual(sameAsClock.yearsPerCalendarYear ?? .nan, 1, accuracy: 0.01)
        XCTAssertEqual(sameAsClock.copyText,
                       "Aging ~1.0 y per calendar year, same as the clock")
    }

    @MainActor
    func testShareCardRendererOutputsStoryAndPostPNGsWithoutMetadata() throws {
        let snapshot = AtriaShareSnapshot(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            recovery: .init(title: "Recovery", value: "82%", detail: "local", tintHex: "#42f59b", fill: 0.82),
            sleep: .init(title: "Sleep", value: "7h 42m", detail: "confirmed", tintHex: "#56d7ff", fill: 0.92),
            strain: .init(title: "Strain", value: "11.4", detail: "target 13", tintHex: "#ff8a3d", fill: 0.76),
            stats: [
                .init(id: "recovery", title: "Recovery", value: "82%", detail: "local"),
                .init(id: "sleep", title: "Sleep", value: "7h 42m", detail: "confirmed"),
                .init(id: "strain", title: "Day strain", value: "11.4", detail: "target 13")
            ])
        let ids = Set(snapshot.stats.map(\.id))
        XCTAssertGreaterThanOrEqual(AtriaShareCanvasStyle.allCases.filter(\.isLight).count, 5)

        let story = try AtriaShareCardRenderer.renderPNGData(snapshot: snapshot,
                                                            format: .story,
                                                            selectedStatIDs: ids,
                                                            lightCanvas: false)
        let post = try AtriaShareCardRenderer.renderPNGData(snapshot: snapshot,
                                                           format: .post,
                                                           selectedStatIDs: ids,
                                                           lightCanvas: true)
        let photoBackground = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 640)).image { context in
            UIColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 640))
            UIColor(red: 0.18, green: 0.52, blue: 0.72, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 280))
            UIColor(red: 0.08, green: 0.30, blue: 0.24, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 280, width: 360, height: 360))
        }
        let photoStory = try AtriaShareCardRenderer.renderPNGData(snapshot: snapshot,
                                                                 format: .story,
                                                                 selectedStatIDs: ids,
                                                                 canvasStyle: .midnight,
                                                                 photoBackground: photoBackground)

        XCTAssertEqual(AtriaShareCardRenderer.pngPixelSize(story), AtriaShareFormat.story.pixelSize)
        XCTAssertEqual(AtriaShareCardRenderer.pngPixelSize(post), AtriaShareFormat.post.pixelSize)
        XCTAssertEqual(AtriaShareCardRenderer.pngPixelSize(photoStory), AtriaShareFormat.story.pixelSize)
        XCTAssertFalse(AtriaShareCardRenderer.containsEXIFOrGPS(story))
        XCTAssertFalse(AtriaShareCardRenderer.containsEXIFOrGPS(post))
        XCTAssertFalse(AtriaShareCardRenderer.containsEXIFOrGPS(photoStory))

        let workout = AtriaWorkoutShareSnapshot(
            date: snapshot.date,
            activity: "Strength",
            duration: "42m",
            strain: "9.8",
            peakHeartRate: "158",
            zoneMinutes: [
                .init(id: 1, label: "Z1", minutes: 0, tintHex: "#56d7ff"),
                .init(id: 2, label: "Z2", minutes: 0, tintHex: "#42f59b"),
                .init(id: 3, label: "Z3", minutes: 18, tintHex: "#f5d142"),
                .init(id: 4, label: "Z4", minutes: 0, tintHex: "#ff8a3d"),
                .init(id: 5, label: "Z5", minutes: 0, tintHex: "#ff4f7b")
            ],
            personalRecord: .init(exercise: "Bench press", set: "80 kg x 5", badge: "PR"))
        let workoutStory = try AtriaShareCardRenderer.renderPNGData(snapshot: workout,
                                                                    format: .story,
                                                                    lightCanvas: false)
        XCTAssertEqual(AtriaShareCardRenderer.pngPixelSize(workoutStory), AtriaShareFormat.story.pixelSize)
        XCTAssertFalse(AtriaShareCardRenderer.containsEXIFOrGPS(workoutStory))

        let weekly = AtriaWeeklyShareSnapshot(
            date: snapshot.date,
            title: "My week on Atria",
            recoveryAverage: "74%",
            recoveryDelta: "+6 vs prior week",
            sleepConsistency: "81%",
            bestDay: "Tue 30",
            hardestDay: "Fri 3",
            note: WeeklyReport.strainRecoveryNoteText)
        let weeklyPost = try AtriaShareCardRenderer.renderPNGData(snapshot: weekly,
                                                                  format: .post,
                                                                  lightCanvas: true)
        XCTAssertEqual(AtriaShareCardRenderer.pngPixelSize(weeklyPost), AtriaShareFormat.post.pixelSize)
        XCTAssertFalse(AtriaShareCardRenderer.containsEXIFOrGPS(weeklyPost))

        addShareCardAttachment(named: "story", data: story)
        addShareCardAttachment(named: "post", data: post)
        addShareCardAttachment(named: "photo-story", data: photoStory)
        addShareCardAttachment(named: "workout-story", data: workoutStory)
        addShareCardAttachment(named: "weekly-post", data: weeklyPost)

        if let artifactPath = ProcessInfo.processInfo.environment["ATRIA_SHARE_CARD_ARTIFACT_DIR"],
           !artifactPath.isEmpty {
            let directory = URL(fileURLWithPath: artifactPath, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try story.write(to: directory.appendingPathComponent("story.png"), options: .atomic)
            try post.write(to: directory.appendingPathComponent("post.png"), options: .atomic)
            try photoStory.write(to: directory.appendingPathComponent("photo-story.png"), options: .atomic)
            try workoutStory.write(to: directory.appendingPathComponent("workout-story.png"), options: .atomic)
            try weeklyPost.write(to: directory.appendingPathComponent("weekly-post.png"), options: .atomic)
        }
    }

    private func addShareCardAttachment(named name: String, data: Data) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHomeLayoutConfigValidationDropsUnknownMetricsAndCapsCards() throws {
        let config = AtriaHomeLayoutConfig(glanceMetrics: [
            "recovery", "unknown", "strain", "recovery", "sleep", "hrv", "rhr",
            "steps", "load", "stress", "calories", "bodyTemp"
        ],
                                           sizeOverrides: [
                                               "load": "wide",
                                               "unknown": "wide",
                                               "sleep": "giant"
                                           ],
                                           showLiveStrip: false,
                                           showHighlights: false,
                                           showPlan: false,
                                           showAICoach: false,
                                           ringCenterMetric: .sleep,
                                           legendStatStyle: .value,
                                           accent: .coral)

        let validated = config.validated()

        // Cap raised 8 -> 14 (2026-07-05 essentials-visible default): the 11
        // valid, deduped inputs all survive; "unknown" is still dropped.
        XCTAssertEqual(validated.glanceMetrics, ["recovery", "strain", "sleep", "hrv", "rhr", "steps", "load", "stress", "calories", "bodyTemp"])
        XCTAssertEqual(validated.sizeOverrides, ["load": "wide"])
        XCTAssertEqual(validated.ringCenterMetric, .sleep)
        XCTAssertEqual(validated.legendStatStyle, .value)
        XCTAssertFalse(validated.showLiveStrip)
    }

    func testHomeLayoutConfigResetIsByteIdenticalDefault() throws {
        let encoder = AtriaHomeLayoutCatalog.encoder()
        let reset = try AtriaHomeLayoutConfig.resetData(encoder: encoder)
        let encodedDefault = try AtriaHomeLayoutConfig.default.validated().encodedData(encoder: encoder)

        XCTAssertEqual(reset, encodedDefault)
        XCTAssertEqual(try AtriaHomeLayoutConfig.decoded(from: reset), AtriaHomeLayoutConfig.default.validated())
    }

    func testStrengthLogEpleyAndPRDetectionAreStrict() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = LoggedSet(exercise: "Bench press",
                                 weightKg: 80,
                                 reps: 5,
                                 rpe: nil,
                                 t: start)
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(60),
                                   label: "Strength",
                                   points: [],
                                   strengthSets: [existing])
        let records = AtriaStrengthLog.personalRecords(for: "bench press", in: [session])

        XCTAssertEqual(AtriaStrengthLog.estimatedOneRepMax(weightKg: 80, reps: 5) ?? 0, 93.333, accuracy: 0.01)
        XCTAssertNil(AtriaStrengthLog.estimatedOneRepMax(weightKg: 80, reps: 13))
        XCTAssertFalse(AtriaStrengthLog.isPR(existing, against: records), "equal set is not a PR")
        XCTAssertTrue(AtriaStrengthLog.isPR(LoggedSet(exercise: "Bench press",
                                                     weightKg: 82.5,
                                                     reps: 5,
                                                     rpe: nil,
                                                     t: start.addingTimeInterval(120)),
                                           against: records))
        XCTAssertTrue(AtriaStrengthLog.isPR(LoggedSet(exercise: "Bench press",
                                                     weightKg: 80,
                                                     reps: 6,
                                                     rpe: nil,
                                                     t: start.addingTimeInterval(180)),
                                           against: records))
    }

    func testStrengthHistoryProjectionKeepsLifetimePRAndBoundsExactRecentDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var sessions: [SavedSession] = []
        for day in 0..<30 {
            let date = calendar.date(byAdding: .day, value: day, to: start)!
            let ordinary = LoggedSet(exercise: day.isMultiple(of: 2) ? "Bench Press" : "bench press",
                                     weightKg: Double(50 + day),
                                     reps: 5,
                                     rpe: nil,
                                     t: date)
            let sameDayLower = LoggedSet(exercise: "Bench press",
                                         weightKg: Double(40 + day),
                                         reps: 5,
                                         rpe: nil,
                                         t: date.addingTimeInterval(60))
            sessions.append(SavedSession(id: UUID(),
                                         start: date,
                                         end: date.addingTimeInterval(120),
                                         label: "Strength",
                                         points: [],
                                         strengthSets: [ordinary, sameDayLower]))
        }
        // An old all-time best must survive even though its day is outside the
        // bounded chart payload.
        let lifetimeBest = LoggedSet(exercise: "BENCH PRESS",
                                     weightKg: 150,
                                     reps: 3,
                                     rpe: nil,
                                     t: start.addingTimeInterval(10))
        sessions[0].strengthSets?.append(lifetimeBest)

        let projection = AtriaStrengthLog.historyProjection(in: sessions,
                                                            recentDaysPerExercise: 8,
                                                            calendar: calendar)
        let history = projection.history(for: " bench press ")
        let records = projection.records(for: "Bench Press")

        XCTAssertEqual(history.count, 8)
        XCTAssertEqual(history.map { Int($0.best.weightKg ?? 0) }, Array(72...79))
        XCTAssertEqual(records.maxWeightKg, 150)
        XCTAssertFalse(AtriaStrengthLog.isPR(lifetimeBest, against: records))
        XCTAssertTrue(AtriaStrengthLog.isPR(LoggedSet(exercise: "Bench press",
                                                      weightKg: 151,
                                                      reps: 1,
                                                      rpe: nil,
                                                      t: start),
                                           against: records))
    }

    func testStrengthLogRestOverridesClampAndPersistPerExercise() {
        let defaults = UserDefaults(suiteName: "test-strength-rest-\(UUID().uuidString)")!
        defaults.removeObject(forKey: AtriaStrengthLog.restSecondsKey)

        XCTAssertEqual(AtriaStrengthLog.restSeconds(for: "Bench press", defaults: defaults), 120)

        AtriaStrengthLog.setRestSeconds(15, for: "Bench press", defaults: defaults)
        XCTAssertEqual(AtriaStrengthLog.restSeconds(for: "Bench press", defaults: defaults), 30)

        AtriaStrengthLog.setRestSeconds(900, for: "Squat", defaults: defaults)
        XCTAssertEqual(AtriaStrengthLog.restSeconds(for: "Squat", defaults: defaults), 600)
        XCTAssertEqual(AtriaStrengthLog.restSeconds(for: "Bench press", defaults: defaults), 30)
    }

    func testSavedSessionTRIMPExcludesPausedIntervals() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = stride(from: 0.0, through: 9 * 60.0, by: 10.0).map {
            SavedSession.Point(t: $0, bpm: 150)
        }
        let active = SavedSession(id: UUID(),
                                  start: start,
                                  end: start.addingTimeInterval(9 * 60),
                                  label: "Active",
                                  points: points)
        let paused = SavedSession(id: UUID(),
                                  start: start,
                                  end: start.addingTimeInterval(9 * 60),
                                  label: "Paused",
                                  points: points,
                                  excludedIntervals: [
                                      ExcludedInterval(start: start.addingTimeInterval(3 * 60),
                                                       end: start.addingTimeInterval(6 * 60))
                                  ])

        XCTAssertGreaterThan(active.trimp(rest: 60, max: 190), paused.trimp(rest: 60, max: 190))
        let activeSegments = [
            points.filter { $0.t < 3 * 60 },
            points.filter { $0.t > 6 * 60 },
        ]
        let expectedPausedTRIMP = activeSegments.reduce(0.0) { total, segment in
            total + Metrics.trimp(segment.map { (t: $0.t, bpm: $0.bpm) },
                                  rest: 60,
                                  max: 190)
        }
        XCTAssertEqual(paused.trimp(rest: 60, max: 190), expectedPausedTRIMP, accuracy: 0.0001)

        let breathwork = SavedSession(id: UUID(),
                                      start: start,
                                      end: start.addingTimeInterval(9 * 60),
                                      label: "Breathwork",
                                      points: points,
                                      kind: "breathwork")
        XCTAssertEqual(breathwork.trimp(rest: 60, max: 190), 0)

        let sleep = SavedSession(id: UUID(),
                                 start: start,
                                 end: start.addingTimeInterval(9 * 60),
                                 label: "Sleep",
                                 points: points,
                                 sleepWakeResearchState: "sleep_research")
        XCTAssertEqual(sleep.trimp(rest: 60, max: 190), 0)

        let earlyWorkout = SavedSession(id: UUID(),
                                        start: start,
                                        end: start.addingTimeInterval(9 * 60),
                                        label: "Early workout",
                                        points: points)
        XCTAssertGreaterThan(earlyWorkout.trimp(rest: 60, max: 190), 0)
    }

    func testSavedSessionPauseExcludesCaloriesAndZones() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = stride(from: 0.0, through: 9 * 60.0, by: 10.0).map {
            SavedSession.Point(t: $0, bpm: 150)
        }
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     weightKg: 78,
                                     heightCm: 178,
                                     updated: start,
                                     hasCompletedOnboarding: true)
        let active = SavedSession(id: UUID(),
                                  start: start,
                                  end: start.addingTimeInterval(9 * 60),
                                  label: "Active",
                                  points: points)
        let paused = SavedSession(id: UUID(),
                                  start: start,
                                  end: start.addingTimeInterval(9 * 60),
                                  label: "Paused",
                                  points: points,
                                  excludedIntervals: [
                                      ExcludedInterval(start: start.addingTimeInterval(3 * 60),
                                                       end: start.addingTimeInterval(6 * 60))
                                  ])

        XCTAssertGreaterThan(active.activeCalories(rest: 60, profile: profile) ?? 0,
                             paused.activeCalories(rest: 60, profile: profile) ?? 0)
        XCTAssertGreaterThan(active.timeInZone(maxHR: 190).values.reduce(0, +),
                             paused.timeInZone(maxHR: 190).values.reduce(0, +))
        let activeSegments = [
            points.filter { $0.t < 3 * 60 },
            points.filter { $0.t > 6 * 60 },
        ]
        let expectedZoneSeconds = activeSegments.reduce(0.0) { total, segment in
            total + AtriaAnalytics.Strain.maxHeartRateZoneSeconds(
                segment.map { (t: $0.t, bpm: $0.bpm) },
                maxHR: 190
            ).storage.values.reduce(0, +)
        }
        XCTAssertEqual(paused.timeInZone(maxHR: 190).values.reduce(0, +),
                       expectedZoneSeconds,
                       accuracy: 0.0001)

        let sleep = SavedSession(id: UUID(),
                                 start: start,
                                 end: start.addingTimeInterval(9 * 60),
                                 label: "Sleep",
                                 points: points,
                                 sleepWakeResearchState: "sleep_research")
        let breathwork = SavedSession(id: UUID(),
                                      start: start,
                                      end: start.addingTimeInterval(9 * 60),
                                      label: "Breathwork",
                                      points: points,
                                      kind: "breathwork")
        let interval = DateInterval(start: start, end: start.addingTimeInterval(9 * 60))
        XCTAssertNil(sleep.activeCalories(rest: 60, profile: profile))
        XCTAssertNil(sleep.activeCalories(rest: 60, profile: profile, within: interval))
        XCTAssertNil(breathwork.activeCalories(rest: 60, profile: profile))
        XCTAssertNil(breathwork.activeCalories(rest: 60, profile: profile, within: interval))
    }

    func testStrainValidationSplitsCrossMidnightSessionByCivilDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                     month: 7,
                                                                     day: 13,
                                                                     hour: 23,
                                                                     minute: 50)))
        let points = (0...120).map { sample in
            let offset = sample * 10
            return SavedSession.Point(t: Double(offset), bpm: offset < 10 * 60 ? 75 : 180)
        }
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(20 * 60),
                                   label: "Midnight workout",
                                   points: points,
                                   eventTimeZoneIdentifier: "UTC")

        let summary = SessionStore.strainValidationSummary(sessions: [session],
                                                           rest: 60,
                                                           maxHR: 190,
                                                           externalHRReferenceValidated: false,
                                                           calendar: calendar)

        XCTAssertEqual(summary.daysEvaluated, 2)
        XCTAssertTrue(calendar.isDate(try XCTUnwrap(summary.bestDay),
                                      inSameDayAs: start.addingTimeInterval(15 * 60)))
        XCTAssertEqual(summary.bestSessions, 1)
        XCTAssertEqual(summary.totalSeconds, 10 * 60, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(summary.maxHRReserve, 0.9)
    }

    func testStrainValidationUsesPauseAwareDayProjection() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                     month: 7,
                                                                     day: 13,
                                                                     hour: 12)))
        let points = (0...120).map {
            SavedSession.Point(t: Double($0 * 10), bpm: 170)
        }
        let pause = ExcludedInterval(start: start.addingTimeInterval(5 * 60),
                                     end: start.addingTimeInterval(15 * 60))
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(20 * 60),
                                   label: "Paused workout",
                                   points: points,
                                   excludedIntervals: [pause],
                                   eventTimeZoneIdentifier: "UTC")
        let day = calendar.startOfDay(for: start)
        let interval = try XCTUnwrap(EventCivilTime.interval(forCivilDay: day,
                                                             eventTimeZoneIdentifier: "UTC",
                                                             outputCalendar: calendar))
        let summary = SessionStore.strainValidationSummary(sessions: [session],
                                                           rest: 60,
                                                           maxHR: 190,
                                                           externalHRReferenceValidated: false,
                                                           calendar: calendar)

        XCTAssertEqual(summary.daysEvaluated, 1)
        XCTAssertEqual(summary.samples, 58)
        XCTAssertEqual(summary.totalSeconds, 580, accuracy: 0.001)
        XCTAssertEqual(summary.trimp,
                       session.trimp(rest: 60, max: 190, within: interval),
                       accuracy: 0.0001)
    }

    func testNutritionSummaryAutoTagsAndFuelSummary() {
        let summary = AtriaNutritionSummary(kcal: 2140,
                                            proteinG: 132,
                                            carbsG: 210,
                                            fatG: 71,
                                            waterMl: 2300,
                                            caffeineMg: 180,
                                            lastCaffeineHour: 16,
                                            alcoholDrinks: 2)

        XCTAssertEqual(summary.autoJournalTags(bodyMassKg: 80), [.alcohol, .caffeine, .protein])
        XCTAssertEqual(summary.fuelSummary, "2140 kcal · 132 g protein · 2 drinks")
        XCTAssertFalse(AtriaNutritionSummary(proteinG: 90, lastCaffeineHour: 13, alcoholDrinks: 0)
            .autoJournalTags(bodyMassKg: 80)
            .contains(.protein))
    }

    func testDailyRollupNutritionRoundTripsAsOptionalContext() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let rollup = DailyRollupStoreEntry(day: day,
                                           recovery: 70,
                                           nutrition: AtriaNutritionSummary(kcal: 2140,
                                                                            proteinG: 132,
                                                                            caffeineMg: 180,
                                                                            lastCaffeineHour: 16,
                                                                            alcoholDrinks: 2))
        let data = try JSONEncoder().encode(rollup)
        let decoded = try JSONDecoder().decode(DailyRollupStoreEntry.self, from: data)

        XCTAssertEqual(decoded.nutrition?.kcal, 2140)
        XCTAssertEqual(decoded.nutrition?.proteinG, 132)
        XCTAssertEqual(decoded.nutrition?.lastCaffeineHour, 16)
    }

    func testNutritionSummaryBuilderDropsZeroesAndCapturesCaffeineHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let caffeineDate = calendar.date(from: DateComponents(year: 2026,
                                                              month: 7,
                                                              day: 2,
                                                              hour: 15))!

        let summary = AtriaNutritionContext.summaryFromHealthKit(kcal: 0,
                                                                 proteinG: 128,
                                                                 carbsG: 210,
                                                                 fatG: 70,
                                                                 waterMl: 2400,
                                                                 caffeineMg: 180,
                                                                 latestCaffeineDate: caffeineDate,
                                                                 alcoholDrinks: 0,
                                                                 calendar: calendar)

        XCTAssertEqual(summary?.kcal, nil)
        XCTAssertEqual(summary?.proteinG, 128)
        XCTAssertEqual(summary?.waterMl, 2400)
        XCTAssertEqual(summary?.caffeineMg, 180)
        XCTAssertEqual(summary?.lastCaffeineHour, 15)
        XCTAssertNil(summary?.alcoholDrinks)
        XCTAssertNil(AtriaNutritionContext.summaryFromHealthKit(kcal: nil,
                                                                proteinG: 0,
                                                                carbsG: 0,
                                                                fatG: nil,
                                                                waterMl: nil,
                                                                caffeineMg: nil,
                                                                latestCaffeineDate: nil,
                                                                alcoholDrinks: 0,
                                                                calendar: calendar))
    }

    func testBehaviorJournalEntryDefaultsMissingHealthAutoTags() throws {
        let json = """
        {
          "id": "journal-2026-07-02",
          "day": "2026-07-02T00:00:00Z",
          "createdAt": "2026-07-02T08:00:00Z",
          "tags": ["alcohol"]
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entry = try decoder.decode(BehaviorJournalEntry.self, from: json)

        XCTAssertEqual(entry.tags, [.alcohol])
        XCTAssertTrue(entry.healthAutoTags.isEmpty)
    }

    func testRawExportPackageContainsFullResolutionRowsAndSchema() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(2),
                                   label: "Export",
                                   points: [
                                       SavedSession.Point(t: 0, bpm: 71),
                                       SavedSession.Point(t: 1, bpm: 72)
                                   ],
                                   rrPoints: [
                                       SavedSession.RRPoint(t: 0.2, ms: 840),
                                       SavedSession.RRPoint(t: 1.2, ms: 830)
                                   ])
        XCTAssertEqual(AtriaRawExport.hrRows(sessions: [session]),
                       ["1800000000000,71\n", "1800000001000,72\n"])
        XCTAssertEqual(AtriaRawExport.rrRows(sessions: [session]),
                       ["1800000000200,840\n", "1800000001200,830\n"])
        XCTAssertTrue(AtriaRawExport.schemaDocument.hasPrefix(AtriaRawExport.schemaHeader))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-raw-export-test-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        var streamedProgress: [(String, Int)] = []
        let telemetry = try AtriaRawExport.writePackage(to: url,
                                                        sessions: [session],
                                                        confirmedSleeps: [],
                                                        confirmedWorkouts: [],
                                                        rollups: [],
                                                        now: start) { file, count in
            streamedProgress.append((file, count))
        }
        XCTAssertEqual(streamedProgress.filter { $0.0 == "hr.csv" }.map(\.1), [1, 2])
        XCTAssertEqual(streamedProgress.filter { $0.0 == "rr.csv" }.map(\.1), [1, 2])
        XCTAssertGreaterThan(telemetry.peakResidentBytes, 0)
        XCTAssertGreaterThan(telemetry.peakResidentKilobytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0, 0)

        let backupRawExport = SessionBackupRawExport(schemaVersion: AtriaRawExport.schemaVersion,
                                                     schemaHeader: AtriaRawExport.schemaHeader,
                                                     schemaDocument: AtriaRawExport.schemaDocument,
                                                     hrRows: AtriaRawExport.hrRows(sessions: [session]),
                                                     rrRows: AtriaRawExport.rrRows(sessions: [session]),
                                                     hrSamples: session.points.count,
                                                     rrSamples: session.rrPoints?.count ?? 0,
                                                     sleeps: 0,
                                                     workouts: 0,
                                                     rollups: 0)
        let backup = SessionBackupEnvelope(schema: 3,
                                           createdAt: start,
                                           app: "Atria.local",
                                           sessions: [session],
                                           baseline: PersonalBaseline(),
                                           profile: AthleteProfile.load(),
                                           rawExport: backupRawExport)
        let backupData = try JSONEncoder().encode(backup)
        let decodedBackup = try JSONDecoder().decode(SessionBackupEnvelope.self, from: backupData)
        XCTAssertEqual(decodedBackup.rawExport?.schemaHeader, AtriaRawExport.schemaHeader)
        XCTAssertEqual(decodedBackup.rawExport?.hrRows.count, 2)
        XCTAssertEqual(decodedBackup.rawExport?.rrRows.count, 2)
        XCTAssertEqual(decodedBackup.rawExport?.hrSamples, 2)
        XCTAssertEqual(decodedBackup.rawExport?.rrSamples, 2)
    }

    func testCoachPayloadReceiptAndFabricationGuard() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let today = DailyRollupStoreEntry(day: day,
                                          recovery: 64,
                                          lnRMSSD: log(58),
                                          rhr: 58,
                                          sleepSeconds: 7 * 3600 + 42 * 60,
                                          strain: 8.4,
                                          skinTemperatureDeviationCelsius: 39.5)
        let payload = AtriaCoachPayload(today: today,
                                        last7: [today],
                                        now: "2026-07-02T12:00:00+05:30",
                                        weekday: "Thursday",
                                        units: "metric",
                                        baselines: ["recovery": .init(low: 0, high: 100)])
        let older = DailyRollupStoreEntry(day: day.addingTimeInterval(-86_400),
                                          recovery: 72,
                                          lnRMSSD: log(62),
                                          rhr: 55,
                                          sleepSeconds: 8 * 3600,
                                          strain: 6.2)
        let context = AtriaCoachContext(guidance: Coach.guide(recovery: Metrics.RecoveryEstimate(percent: 50,
                                                                                                  confidence: .learning,
                                                                                                  usesHRV: false,
                                                                                                  detail: "fixture",
                                                                                                  contributors: []),
                                                              strain: 4,
                                                              load: .learning),
                                        strain: 4,
                                        recoveryText: "50%",
                                        hrvText: "44",
                                        stressText: "1/3",
                                        baselineSamples: 2,
                                        sessionsCount: 3)
        let rollupPayload = AtriaCoachPayload.fromRollups(rollups: [older, today],
                                                          fallback: context,
                                                          now: Date(timeIntervalSince1970: 1_800_043_200),
                                                          calendar: Calendar(identifier: .gregorian),
                                                          units: "metric",
                                                          baselines: ["recovery": .init(low: 0, high: 100)])
        let boundaryInstant = ISO8601DateFormatter().date(from: "2026-07-02T01:15:00Z")!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        var losAngelesCalendar = Calendar(identifier: .gregorian)
        losAngelesCalendar.timeZone = losAngeles
        var kolkataCalendar = Calendar(identifier: .gregorian)
        kolkataCalendar.timeZone = kolkata
        let laPayload = AtriaCoachPayload.fromRollups(rollups: [today],
                                                      fallback: context,
                                                      now: boundaryInstant,
                                                      calendar: losAngelesCalendar,
                                                      timeZone: losAngeles,
                                                      units: "metric",
                                                      baselines: [:])
        let kolkataPayload = AtriaCoachPayload.fromRollups(rollups: [today],
                                                           fallback: context,
                                                           now: boundaryInstant,
                                                           calendar: kolkataCalendar,
                                                           timeZone: kolkata,
                                                           units: "metric",
                                                           baselines: [:])

        XCTAssertTrue(payload.receiptSummary.contains("Recovery 64 %"))
        XCTAssertTrue(payload.receiptSummary.contains("Sleep 7:42"))
        XCTAssertTrue(payload.receiptSummary.contains("HRV 58"))
        XCTAssertTrue(AtriaCoachPayload.systemPrompt.contains("Answer ONLY from DATA"))
        XCTAssertEqual(AtriaCoachPayload.fabricationFlags(response: "Recovery 64% and HRV 58 ms at 7:30.", payload: payload), [])
        XCTAssertEqual(AtriaCoachPayload.fabricationFlags(response: "Your RHR was 49 bpm.", payload: payload), ["49 bpm"])
        XCTAssertEqual(rollupPayload.today?.day, today.day)
        XCTAssertEqual(rollupPayload.today?.recovery, today.recovery)
        XCTAssertEqual(rollupPayload.last7.map(\.recovery), [64, 72])
        XCTAssertTrue(rollupPayload.now.contains("T"))
        XCTAssertFalse(rollupPayload.receiptSummary.contains("50 %"))
        XCTAssertTrue(rollupPayload.auditLines.contains("Days sent: 2"))
        XCTAssertTrue(rollupPayload.auditLines.contains("Recovery: 64 %"))
        XCTAssertTrue(rollupPayload.auditLines.contains("HRV: 58 ms"))
        XCTAssertTrue(rollupPayload.auditLines.contains("RHR: 58 bpm"))
        XCTAssertTrue(laPayload.now.hasSuffix("-07:00"))
        XCTAssertTrue(kolkataPayload.now.hasSuffix("+05:30"))
        XCTAssertEqual(laPayload.weekday, "Wednesday")
        XCTAssertEqual(kolkataPayload.weekday, "Thursday")

        let openAIData = try AtriaCoachProviderRequestBuilder.requestBody(provider: .openAI,
                                                                          model: "test-openai-model",
                                                                          payload: rollupPayload)
        let claudeData = try AtriaCoachProviderRequestBuilder.requestBody(provider: .claude,
                                                                          model: "test-claude-model",
                                                                          payload: rollupPayload)
        let openAIPreview = AtriaCoachProviderRequestBuilder.requestPreview(provider: .openAI,
                                                                            payload: rollupPayload)
        let openAI = try XCTUnwrap(JSONSerialization.jsonObject(with: openAIData) as? [String: Any])
        let claude = try XCTUnwrap(JSONSerialization.jsonObject(with: claudeData) as? [String: Any])
        XCTAssertEqual(openAI["model"] as? String, "test-openai-model")
        XCTAssertEqual(claude["model"] as? String, "test-claude-model")
        XCTAssertEqual(openAI["instructions"] as? String, AtriaCoachProviderRequestBuilder.systemPrompt(for: rollupPayload))
        XCTAssertEqual(claude["system"] as? String, AtriaCoachProviderRequestBuilder.systemPrompt(for: rollupPayload))
        let openAIInput = try XCTUnwrap(openAI["input"] as? [[String: Any]])
        let openAIContent = try XCTUnwrap(openAIInput.first?["content"] as? [[String: Any]])
        let claudeMessages = try XCTUnwrap(claude["messages"] as? [[String: Any]])
        let claudeContent = try XCTUnwrap(claudeMessages.first?["content"] as? [[String: Any]])
        let openAIText = try XCTUnwrap(openAIContent.first?["text"] as? String)
        let claudeText = try XCTUnwrap(claudeContent.first?["text"] as? String)
        XCTAssertTrue(openAIText.hasPrefix("DATA:\n{"))
        XCTAssertTrue(claudeText.hasPrefix("DATA:\n{"))
        XCTAssertTrue(openAIText.contains("\"last7\""))
        XCTAssertTrue(claudeText.contains("\"last7\""))
        XCTAssertFalse(openAIText.contains("skinTemperatureDeviationCelsius"))
        XCTAssertFalse(claudeText.contains("skinTemperatureDeviationCelsius"))
        XCTAssertFalse(openAIText.contains("39.5"))
        XCTAssertFalse(claudeText.contains("39.5"))
        XCTAssertTrue(openAIPreview.summary.contains("gpt-4.1-mini"))
        XCTAssertTrue(openAIPreview.promptLine.contains(rollupPayload.now))
        XCTAssertTrue(openAIPreview.payloadLine.contains("Recovery 64 %"))
    }

    func testHighlightsUseNewestRollupsWhenInputIsUnordered() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        func rollup(daysAgo: Int, sleepPerformance: Int?, rhr: Int?) -> DailyRollupStoreEntry {
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day, value: -daysAgo, to: today)!,
                                  rhr: rhr,
                                  sleepPerformance: sleepPerformance,
                                  calendar: calendar)
        }

        let unordered = [
            rollup(daysAgo: 4, sleepPerformance: 90, rhr: 56),
            rollup(daysAgo: 2, sleepPerformance: 100, rhr: 57),
            rollup(daysAgo: 0, sleepPerformance: 100, rhr: 50),
            rollup(daysAgo: 7, sleepPerformance: 82, rhr: 56),
            rollup(daysAgo: 1, sleepPerformance: 100, rhr: 56),
            rollup(daysAgo: 3, sleepPerformance: 80, rhr: 55)
        ]

        let highlights = AtriaHighlights.topTwo(rollups: unordered)
        XCTAssertEqual(highlights.map(\.id), ["sleep-need-streak", "lower-rhr"])
        XCTAssertEqual(highlights.first?.valuePhrase, "3 nights")
    }

    private func syntheticHeartSamples(start: Date, count: Int, bpm: Int) -> [HRSample] {
        (0..<count).map { index in
            HRSample(t: start.addingTimeInterval(TimeInterval(index)), bpm: bpm)
        }
    }

    private func savedSession(start: Date, duration: TimeInterval, bpm: Int) -> SavedSession {
        let end = start.addingTimeInterval(duration)
        let points = stride(from: 0.0, through: duration, by: 60.0).map {
            SavedSession.Point(t: $0, bpm: bpm)
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: end,
                            label: "Test",
                            points: points)
    }

    // MARK: - HR-only sleep review tier + today rollup-from-wear

    // Deliberately `Calendar.current` (device-local), not a fixed GMT calendar:
    // isStrongAutoConfirmableSleepCandidate/autoSleepClassification take no
    // `calendar` parameter and always resolve their sub-predicates against
    // `.current` internally (matching real production usage, where
    // aggregateSleepCandidates is likewise always called with `calendar: .current`).
    // These fixtures build every date through this same calendar so hour-of-day
    // gating stays self-consistent regardless of which timezone the test host runs in.
    private var utcCalendar: Calendar {
        Calendar.current
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        DateComponents(calendar: utcCalendar,
                      timeZone: utcCalendar.timeZone,
                      year: year,
                      month: month,
                      day: day,
                      hour: hour,
                      minute: minute).date!
    }

    private func flatHRSession(start: Date, end: Date, bpm: Int, stepSeconds: Double = 60) -> SavedSession {
        let duration = end.timeIntervalSince(start)
        let count = max(2, Int(duration / stepSeconds))
        let points = (0..<count).map { SavedSession.Point(t: Double($0) * stepSeconds, bpm: bpm) }
        return SavedSession(id: UUID(), start: start, end: end, label: "Test", points: points)
    }

    /// A fragmented overnight artifact night can remain reviewable from robust HR
    /// evidence, but must not auto-confirm without validated strap stillness.
    func testArtifactFragmentedOvernightRemainsReviewOnlyWithoutMotion() {
        let calendar = utcCalendar
        let rest = 50

        let frag1Start = utcDate(2027, 3, 2, 0, 10)
        let frag1End = utcDate(2027, 3, 2, 2, 0)
        let frag1 = flatHRSession(start: frag1Start, end: frag1End, bpm: 52)

        let frag2Start = utcDate(2027, 3, 2, 2, 30)
        let frag2End = utcDate(2027, 3, 2, 4, 30)
        // 120 one-minute samples: 114 true low-HR + 6 bounded ~95bpm artifact burst
        // (an accepted hr_mismatch-style spike) — a small enough fraction to stay
        // under the elevated-sample-fraction and hrP90 gates.
        let frag2Points = (0..<114).map { SavedSession.Point(t: Double($0) * 60, bpm: 52) }
            + (0..<6).map { SavedSession.Point(t: Double(114 + $0) * 60, bpm: 95) }
        let frag2 = SavedSession(id: UUID(), start: frag2Start, end: frag2End, label: "Test", points: frag2Points)

        let frag3Start = utcDate(2027, 3, 2, 5, 0)
        let frag3End = utcDate(2027, 3, 2, 7, 0)
        let frag3 = flatHRSession(start: frag3Start, end: frag3End, bpm: 52)

        let candidates = SessionStore.aggregateSleepCandidates(in: [frag1, frag2, frag3],
                                                               rest: rest,
                                                               maxHR: 190,
                                                               calendar: calendar,
                                                               historicalMotionPolicy: .boundedRecent)
        XCTAssertEqual(candidates.count, 1, "the three reconnect fragments should cluster into one overnight candidate")
        guard let candidate = candidates.first else { return }

        XCTAssertEqual(candidate.sessions, 3)
        XCTAssertFalse(SessionStore.isUnambiguousHROnlyMainSleepCandidate(candidate),
                       "fragmented (sessions>1) must fail the unambiguous single-session gate")
        XCTAssertTrue(SessionStore.isDegradedHROnlyOvernightSleepCandidate(candidate),
                      "a bounded artifact burst may clear the high-specificity review gate")
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))

        let classification = SessionStore.autoSleepClassification(for: candidate)
        XCTAssertEqual(classification.source, "sleep_review_hr_only")
        XCTAssertEqual(classification.confidence, "low")
        XCTAssertFalse(classification.motionValidated)
        XCTAssertEqual(classification.motionSource, "strap_hr_only")
        XCTAssertTrue(classification.isHROnly)
    }

    /// Physical regression (2026-07-23): the strap was worn while awake from
    /// 02:11–05:19. Three otherwise contiguous all-day fragments produced a
    /// 3-hour HR-only candidate because the old degraded-review gate accepted
    /// median baseline+7 and P90 baseline+21. No motion evidence existed, so
    /// this must remain invisible rather than asking the user to dismiss sleep.
    func testAwakeThreeHourOvernightWindowDoesNotSurfaceWithoutMotion() {
        let calendar = utcCalendar
        let rest = 71
        let first = flatHRSession(start: utcDate(2027, 3, 2, 2, 11),
                                  end: utcDate(2027, 3, 2, 2, 37),
                                  bpm: 87)
        let middleStart = utcDate(2027, 3, 2, 2, 37)
        let middleEnd = utcDate(2027, 3, 2, 4, 54)
        // A bounded awake rise (P90 92) is enough to distinguish this from
        // the low, stable fragmented-night fixture immediately above.
        let middlePoints = (0..<137).map { index in
            SavedSession.Point(t: Double(index) * 60,
                               bpm: index < 30 ? 92 : 78)
        }
        let middle = SavedSession(id: UUID(),
                                  start: middleStart,
                                  end: middleEnd,
                                  label: "Awake overnight regression",
                                  points: middlePoints)
        let last = flatHRSession(start: utcDate(2027, 3, 2, 5, 0),
                                 end: utcDate(2027, 3, 2, 5, 19),
                                 bpm: 80)

        let candidates = SessionStore.aggregateSleepCandidates(in: [first, middle, last],
                                                               rest: rest,
                                                               maxHR: 190,
                                                               calendar: calendar,
                                                               historicalMotionPolicy: .boundedRecent)
        let candidate = try! XCTUnwrap(candidates.first)
        XCTAssertFalse(candidate.motionEvidenceValidated)
        XCTAssertEqual(candidate.medianHR, 78)
        XCTAssertEqual(candidate.hrP90, 92)
        XCTAssertFalse(SessionStore.isDegradedHROnlyOvernightSleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isReviewWorthySleepCandidate(candidate))
    }

    /// An evening couch session (not overnight) must never confirm through the
    /// degraded HR-only tier: near-zero overlap with the sleep-core window (00:00-06:00)
    /// is the primary guardrail against an active/awake evening masquerading as sleep.
    func testCouchEveningSessionRejectedByDegradedTier() {
        let calendar = utcCalendar
        let rest = 50
        let start = utcDate(2027, 3, 2, 20, 0)
        let end = utcDate(2027, 3, 2, 23, 30)
        let session = flatHRSession(start: start, end: end, bpm: rest + 15)

        let candidates = SessionStore.aggregateSleepCandidates(in: [session],
                                                               rest: rest,
                                                               maxHR: 190,
                                                               calendar: calendar,
                                                               historicalMotionPolicy: .boundedRecent)
        XCTAssertTrue(candidates.isEmpty,
                      "a short HR-only couch evening must not be surfaced as sleep at all")
    }

    /// A short daytime nap must never be promotable through the degraded HR-only
    /// overnight tier (that tier is for main sleep only).
    func testShortDaytimeNapRejectedByDegradedTier() {
        let calendar = utcCalendar
        let rest = 50
        let start = utcDate(2027, 3, 2, 14, 0)
        let end = utcDate(2027, 3, 2, 14, 40)
        let session = flatHRSession(start: start, end: end, bpm: 52)

        let candidates = SessionStore.aggregateSleepCandidates(in: [session],
                                                               rest: rest,
                                                               maxHR: 190,
                                                               calendar: calendar,
                                                               historicalMotionPolicy: .boundedRecent)
        XCTAssertTrue(
            candidates.isEmpty,
            "a short daytime HR-only window must not surface as a nap review or enter the degraded overnight tier"
        )
    }

    /// Motion validation stays strictly preferred: a fragmented night with real
    /// historical-gravity low-motion evidence must confirm through the existing
    /// motion-validated path (source=auto_confirmed_sleep, motionValidated=true),
    /// never downgraded into the degraded HR-only tier even though it would also
    /// pass the degraded gates.
    func testMotionValidatedFragmentedNightPreferredOverDegradedTier() throws {
        try withCleanHistoricalArchive {
            let calendar = self.utcCalendar
            let rest = 50
            let frag1Start = self.utcDate(2027, 3, 2, 0, 10)
            let frag1End = self.utcDate(2027, 3, 2, 2, 0)
            let frag1 = self.flatHRSession(start: frag1Start, end: frag1End, bpm: 52)
            let frag2Start = self.utcDate(2027, 3, 2, 2, 30)
            let frag2End = self.utcDate(2027, 3, 2, 4, 30)
            let frag2 = self.flatHRSession(start: frag2Start, end: frag2End, bpm: 52)
            let frag3Start = self.utcDate(2027, 3, 2, 5, 0)
            let frag3End = self.utcDate(2027, 3, 2, 7, 0)
            let frag3 = self.flatHRSession(start: frag3Start, end: frag3End, bpm: 52)

            // Constant, validated, still gravity samples spanning the whole night
            // (60s cadence) so HistoricalArchive.boundedMotionWindowDiagnostics finds
            // >=30 rows, all still (stillnessRatio 1.0, movementIntensity 0).
            var index = 0
            var unix = UInt32(frag1Start.timeIntervalSince1970)
            let endUnix = UInt32(frag3End.timeIntervalSince1970)
            while unix < endUnix {
                let capturedAt = Date(timeIntervalSince1970: TimeInterval(unix))
                let payload = self.historicalPayloadWithGravity(x: 0,
                                                                y: 0,
                                                                z: 1,
                                                                counter: UInt32(index),
                                                                timestamp: unix)
                let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                                      capturedAt: capturedAt,
                                                      source: "0x2f",
                                                      layoutVersion: HistoricalArchive.layoutVersion,
                                                      sequence: 24,
                                                      command: 0x16,
                                                      unix7: unix,
                                                      subsec11: 0,
                                                      flash13: UInt32(index),
                                                      payloadLength: payload.count,
                                                      whoofHR17: 52,
                                                      whoofRRNum18: 0,
                                                      whoofRR19: [],
                                                      kRR64: [],
                                                      gravityX36: 0,
                                                      gravityY40: 0,
                                                      gravityZ44: 1,
                                                      gravityMagnitude: 1,
                                                      gravityValidated: true,
                                                      candidateRR: [],
                                                      rawPayloadHex: HistoricalArchive.hex(payload),
                                                      clockDeviceRef: unix,
                                                      clockWallRef: unix,
                                                      clockDriftSeconds: 0,
                                                      clockCorrectedUnix7: unix,
                                                      clockCorrectionStatus: "clock_ref_present",
                                                      currentSessionUsable: false,
                                                      metricUsable: false,
                                                      usabilityReason: "test_degraded_vs_motion_priority")
                _ = try? HistoricalArchive.append(record)
                index += 1
                unix += 60
            }

            // Earlier tests can leave an intentionally asynchronous bounded
            // cache warm-up in flight. Invalidate it after this fixture is
            // fully written so the off-main assertion synchronously loads the
            // archive generation created above.
            HistoricalArchive.resetRecentGravityCacheForTesting()
            let candidates = runOffMain {
                SessionStore.aggregateSleepCandidates(in: [frag1, frag2, frag3],
                                                      rest: rest,
                                                      maxHR: 190,
                                                      calendar: calendar,
                                                      historicalMotionPolicy: .boundedRecent)
            }
            XCTAssertEqual(candidates.count, 1)
            guard let candidate = candidates.first else { return }

            XCTAssertTrue(candidate.motionEvidenceValidated,
                          "constant validated low-motion gravity samples should validate motion for this window")
            XCTAssertNotEqual(candidate.confidence, .low)
            XCTAssertTrue(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))

            let classification = SessionStore.autoSleepClassification(for: candidate)
            XCTAssertEqual(classification.source, "auto_confirmed_sleep",
                          "motion-validated nights must not be downgraded to the HR-only degraded tier")
            XCTAssertTrue(classification.motionValidated)
            XCTAssertFalse(classification.isHROnly)
            XCTAssertNotEqual(classification.confidence, "hr_only")
        }
    }

    // MARK: - Wake-boundary sleep confirm (WHOOP-parity finalize-at-wake)

    /// `sustainedWakeOnset` is the wake detector the wake-boundary path relies
    /// on to trim a still-open/continuously-extending night session: it must
    /// stay silent on a flat low-HR night and on a transient mid-night
    /// artifact spike that resolves back to low HR (both would otherwise let a
    /// noisy strap falsely "wake" the aggregate), while still finding the
    /// onset of a genuine, sustained morning rise.
    func testSustainedWakeOnsetIgnoresTransientSpikeButDetectsSustainedWake() {
        let rest = 50
        let start = utcDate(2027, 3, 10, 23, 0)

        let flatNight = flatHRSession(start: start, end: start.addingTimeInterval(7 * 60 * 60), bpm: 52)
        XCTAssertNil(SessionStore.sustainedWakeOnset(in: flatNight, restingHR: rest),
                    "a flat low-HR night has no sustained wake run")

        // A single transient artifact spike mid-night that resolves back to
        // low HR through the end of the session must not read as wake — the
        // detector requires the elevated run to persist through the tail.
        var transientPoints = (0..<300).map { SavedSession.Point(t: Double($0) * 60, bpm: 52) }
        for i in 150..<155 { transientPoints[i] = SavedSession.Point(t: Double(i) * 60, bpm: 95) }
        let transientSession = SavedSession(id: UUID(),
                                            start: start,
                                            end: start.addingTimeInterval(300 * 60),
                                            label: "Test",
                                            points: transientPoints)
        XCTAssertNil(SessionStore.sustainedWakeOnset(in: transientSession, restingHR: rest),
                    "a single mid-night artifact spike that resolves back to low HR must not read as wake")

        // A genuine, sustained rise in the tail that persists through the end
        // of the session should read as wake, with the onset falling inside
        // that elevated tail — never in the preceding low-HR portion.
        let lowCount = 420 // 7h at 60s cadence
        var sustainedPoints = (0..<lowCount).map { SavedSession.Point(t: Double($0) * 60, bpm: 52) }
        let elevatedCount = 40 // 40 more minutes, clearly elevated and sustained to the end
        sustainedPoints += (0..<elevatedCount).map { SavedSession.Point(t: Double(lowCount + $0) * 60, bpm: 78) }
        let sustainedSession = SavedSession(id: UUID(),
                                            start: start,
                                            end: start.addingTimeInterval(Double(lowCount + elevatedCount) * 60),
                                            label: "Test",
                                            points: sustainedPoints)
        guard let onset = SessionStore.sustainedWakeOnset(in: sustainedSession, restingHR: rest) else {
            XCTFail("expected a sustained wake onset in the elevated tail")
            return
        }
        let elevatedTailStart = start.addingTimeInterval(Double(lowCount) * 60)
        XCTAssertGreaterThanOrEqual(onset, elevatedTailStart.addingTimeInterval(-60),
                                    "onset should not be detected before the elevated tail begins")
        XCTAssertLessThan(onset, sustainedSession.end, "onset must fall strictly before the session end")
    }

    /// The exact WHOOP-parity bug this feature fixes: a continuously
    /// checkpointed overnight session never closes — its `end` keeps
    /// extending into the awake morning — so `aggregateSleepCandidates` folds
    /// the awake tail's elevated HR into avg/SD/P90/elevated-fraction and
    /// BOTH the unambiguous and degraded auto-confirm tiers reject it, exactly
    /// as docs/23's root-cause trace describes. `wakeBoundarySleepCandidate`
    /// must trim that same still-open session at the detected wake point and
    /// produce a bounded review candidate. Without validated strap stillness it
    /// must still fail `isStrongAutoConfirmableSleepCandidate`.
    func testWakeBoundarySleepCandidateRecoversWhatTheOpenSessionBugLoses() {
        let calendar = utcCalendar
        let rest = 50
        let maxHR = 190
        let start = utcDate(2027, 3, 20, 23, 0)

        let lowCount = 420 // 7h low-HR sleep at 60s cadence
        var points = (0..<lowCount).map { SavedSession.Point(t: Double($0) * 60, bpm: 52) }
        // The still-open session keeps extending through the awake morning
        // (checkpointed continuity) instead of ending at wake.
        let awakeTailCount = 180 // 3h of moderate awake-morning HR
        points += (0..<awakeTailCount).map { SavedSession.Point(t: Double(lowCount + $0) * 60, bpm: 90) }
        let openSession = SavedSession(id: UUID(),
                                       start: start,
                                       end: start.addingTimeInterval(Double(lowCount + awakeTailCount) * 60),
                                       label: "Test",
                                       points: points)

        // Reproduce the bug: the naive whole-session candidate must fail the
        // strong auto-confirm gate because the awake tail is folded in.
        let buggyCandidates = SessionStore.aggregateSleepCandidates(in: [openSession],
                                                                    rest: rest,
                                                                    maxHR: maxHR,
                                                                    calendar: calendar,
                                                                    historicalMotionPolicy: .boundedRecent)
        XCTAssertTrue(buggyCandidates.isEmpty,
                      "the still-open whole span is rejected before it can become a sleep claim")

        // The fix: trim at the detected wake point and re-run through the
        // exact same gates.
        let fixed = SessionStore.wakeBoundarySleepCandidate(session: openSession,
                                                            windowEndMinute: 10 * 60 + 30,
                                                            rest: rest,
                                                            maxHR: maxHR,
                                                            calendar: calendar,
                                                            now: openSession.end)
        guard let fixed else {
            XCTFail("expected the wake-boundary trim to synthesize a candidate")
            return
        }
        XCTAssertEqual(fixed.kind, "overnight_sleep")
        XCTAssertLessThan(fixed.end, openSession.end, "the synthesized candidate must end at wake, not keep the awake tail")
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(fixed),
                      "wake trimming cannot substitute for validated strap stillness")
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(fixed))
    }

    /// When the tail gives no clear sustained-wake signal (e.g. a resolved
    /// mid-night artifact blip, not a real morning wake), `wakeBoundarySleepCandidate`
    /// must fall back to cutting at the learned/fallback window-end instant
    /// rather than either confirming the untrimmed (still-growing) session or
    /// refusing to confirm at all.
    func testWakeBoundarySleepCandidateFallsBackToWindowEndWithoutClearOnset() {
        let calendar = utcCalendar
        let rest = 50
        let maxHR = 190
        let start = utcDate(2027, 3, 21, 23, 0)

        let totalCount = 480 // 8h at 60s cadence
        var points = (0..<totalCount).map { SavedSession.Point(t: Double($0) * 60, bpm: 52) }
        for i in 200..<205 { points[i] = SavedSession.Point(t: Double(i) * 60, bpm: 95) } // resolved mid-night blip
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(Double(totalCount) * 60),
                                   label: "Test",
                                   points: points)
        XCTAssertNil(SessionStore.sustainedWakeOnset(in: session, restingHR: rest),
                    "a resolved mid-night blip must not read as a sustained wake onset")

        let windowEndMinute = 6 * 60 + 30 // 06:30
        let now = start.addingTimeInterval(8 * 60 * 60)
        guard let fixed = SessionStore.wakeBoundarySleepCandidate(session: session,
                                                                  windowEndMinute: windowEndMinute,
                                                                  rest: rest,
                                                                  maxHR: maxHR,
                                                                  calendar: calendar,
                                                                  now: now) else {
            XCTFail("expected the fallback window-end trim to synthesize a candidate")
            return
        }
        XCTAssertEqual(fixed.kind, "overnight_sleep")
        XCTAssertLessThan(fixed.end, session.end, "fallback trim must cut before the untrimmed session end")
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(fixed))
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(fixed))
    }

    /// Section D fix: today's frozen daily metric must exist from wear alone —
    /// independent of sleep confirmation — when an overnight-shaped session ended
    /// this morning with no RR/HRV and no confirmed sleep, even though the
    /// session's own start day (yesterday) is what `dailyRollups` buckets it under
    /// (so `computed` carries no same-day entry for today).
    func testMorningFrozenMetricFromOvernightSessionWithoutRR() {
        let calendar = utcCalendar
        let now = utcDate(2027, 3, 5, 10, 40)
        let day = calendar.startOfDay(for: now)
        let session = flatHRSession(start: utcDate(2027, 3, 4, 23, 0),
                                    end: utcDate(2027, 3, 5, 7, 0),
                                    bpm: 48)
        XCTAssertNil(session.rrPoints)

        let sleep = SleepHistorySnapshot(rollups: [], confirmedSleeps: [])
        let baseline = PersonalBaseline()

        let result = SessionStore.makeMorningFrozenDailyMetric(for: day,
                                                               computed: [],
                                                               sessions: [session],
                                                               sleep: sleep,
                                                               baseline: baseline,
                                                               maxHR: 190,
                                                               now: now,
                                                               calendar: calendar)
        XCTAssertNotNil(result, "wear alone should be enough to settle today's morning row")
        XCTAssertNotNil(result?.restingHR)
        XCTAssertNil(result?.sleepDuration, "no confirmed sleep and no dailyRollup sleep evidence exists for today")
        XCTAssertNil(
            result?.strain,
            "quiet overnight wear must not reappear as strain through the morning fallback"
        )
    }

    func testCleanQualifiedUnconfirmedWearYieldsOnlyUnverifiedRecovery() throws {
        let now = Date()
        let session = reducedRecoveryWearSession(now: now,
                                                 bpm: 58,
                                                 rrSeconds: 1_800,
                                                 mixedProvenance: false)
        let baseline = PersonalBaseline(restingHR: 60,
                                        hrvEMA: 52,
                                        sessions: PersonalBaseline.trustedMinimumSamples,
                                        updated: now,
                                        samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                 now: now))
        let sleep = priorConfirmedSleepSnapshot(now: now)
        let day = utcCalendar.startOfDay(for: session.end)

        let metric = try XCTUnwrap(SessionStore.makeMorningFrozenDailyMetric(
            for: day,
            computed: [],
            sessions: [session],
            sleep: sleep,
            baseline: baseline,
            maxHR: 190,
            now: now,
            calendar: utcCalendar
        ))

        XCTAssertNotNil(metric.hrv)
        XCTAssertNotNil(metric.recoveryPercent)
        XCTAssertEqual(metric.recoveryConfidence,
                       AtriaAnalytics.Recovery.Estimate.Confidence.unverified.rawValue)
        XCTAssertNil(metric.sleepDuration, "reduced recovery must never fabricate a sleep record")
        XCTAssertNil(metric.sleepStart)
        XCTAssertNil(metric.sleepEnd)
    }

    func testUnconfirmedRecoveryRejectsBadHRVButKeepsConservativeRHROnlyValue() {
        let now = Date()
        let baseline = PersonalBaseline(restingHR: 60,
                                        hrvEMA: 52,
                                        sessions: PersonalBaseline.trustedMinimumSamples,
                                        updated: now,
                                        samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                 now: now))
        let sleep = priorConfirmedSleepSnapshot(now: now)
        let fixtures = [
            reducedRecoveryWearSession(now: now, bpm: 58, rrSeconds: 0, mixedProvenance: false),
            reducedRecoveryWearSession(now: now, bpm: 58, rrSeconds: 1_800, mixedProvenance: true),
            reducedRecoveryWearSession(now: now, bpm: 58, rrSeconds: 500, mixedProvenance: false),
            reducedRecoveryWearSession(now: now, bpm: 82, rrSeconds: 1_800, mixedProvenance: false)
        ]

        for session in fixtures {
            let day = utcCalendar.startOfDay(for: session.end)
            let metric = SessionStore.makeMorningFrozenDailyMetric(for: day,
                                                                   computed: [],
                                                                   sessions: [session],
                                                                   sleep: sleep,
                                                                   baseline: baseline,
                                                                   maxHR: 190,
                                                                   now: now,
                                                                   calendar: utcCalendar)
            XCTAssertNil(metric?.hrv)
            XCTAssertNotNil(metric?.recoveryPercent,
                            "day-one RHR remains useful even when RR cannot qualify")
            XCTAssertEqual(metric?.recoveryConfidence,
                           AtriaAnalytics.Recovery.Estimate.Confidence.unverified.rawValue)
            XCTAssertFalse(metric?.recoverySummary?.usesHRV ?? true)
            XCTAssertNil(metric?.sleepDuration,
                         "RHR-only recovery must not manufacture a sleep record")
        }
    }

    /// Same-day wear fallback exercised specifically: a long overnight-shaped
    /// session whose OWN start/end hours don't satisfy the loose
    /// `isOvernightHRVWindow` heuristic (so the pre-existing overnight-session
    /// fallback would miss it) still settles today's row via `morningMetricDay`
    /// end-day attribution, and survives `mergeDailyMetricHistory` as exactly one
    /// today row.
    func testTodayRollupSurvivesMergeFromWearOnlySession() {
        let calendar = utcCalendar
        let now = utcDate(2027, 3, 5, 10, 40)
        let day = calendar.startOfDay(for: now)
        // startHour=19 (not >=20), endHour=11 (not <=10): isOvernightHRVWindow is
        // false for this session even though it plainly represents overnight wear.
        let session = flatHRSession(start: utcDate(2027, 3, 4, 19, 30),
                                    end: utcDate(2027, 3, 5, 11, 15),
                                    bpm: 55,
                                    stepSeconds: 900)
        XCTAssertFalse(session.isOvernightHRVWindow(calendar: calendar))

        let sleep = SleepHistorySnapshot(rollups: [], confirmedSleeps: [])
        let baseline = PersonalBaseline()

        let settled = SessionStore.makeMorningFrozenDailyMetric(for: day,
                                                                computed: [],
                                                                sessions: [session],
                                                                sleep: sleep,
                                                                baseline: baseline,
                                                                maxHR: 190,
                                                                now: now,
                                                                calendar: calendar)
        XCTAssertNotNil(settled, "the wear-only fallback (attribution by session END day) should still settle today")
        XCTAssertNotNil(settled?.restingHR)
        XCTAssertNil(settled?.sleepDuration)

        let merged = SessionStore.mergeDailyMetricHistory(existing: [],
                                                          computed: [],
                                                          sessions: [session],
                                                          sleep: sleep,
                                                          baseline: baseline,
                                                          maxHR: 190,
                                                          now: now,
                                                          calendar: calendar)
        let todayRows = merged.filter { calendar.isDate($0.day, inSameDayAs: day) }
        XCTAssertEqual(todayRows.count, 1, "today's rollup row must survive the merge from wear alone")
        XCTAssertNotNil(todayRows.first?.restingHR)
        XCTAssertNil(todayRows.first?.sleepDuration)
    }

    /// On a physical device the test host app's own container can hold a real,
    /// already-populated HistoricalArchive (thousands of rows from real strap use).
    /// These fixture-based tests assume a pristine container and are not allowed to
    /// fight (or worse, silently blend with) that real user data. Call this BEFORE
    /// any mutation (deleting/appending) so a populated real archive causes a clean
    /// skip instead of a false failure or a write into the user's own data.
    private func skipIfRealHistoricalArchivePresent() throws {
        let diagnostics = HistoricalArchive.diagnostics()
        guard !diagnostics.exists || diagnostics.rows == 0 else {
            throw XCTSkip("Requires clean container; real on-device historical archive present " +
                          "(rows=\(diagnostics.rows), reason=\(diagnostics.reason)). " +
                          "Skipping to avoid colliding with real user data.")
        }
    }

    private func withCleanHistoricalArchive(_ body: () throws -> Void) throws {
        Self.historicalArchiveTestLock.lock()
        defer { Self.historicalArchiveTestLock.unlock() }
        try skipIfRealHistoricalArchivePresent()
        HistoricalArchive.resetRecentGravityCacheForTesting()

        let fileManager = FileManager.default
        let directory = HistoricalArchive.fileURL.deletingLastPathComponent()
        let backupDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("atria-historical-test-backup-\(UUID().uuidString)", isDirectory: true)
        let hadExistingDirectory = fileManager.fileExists(atPath: directory.path)
        if hadExistingDirectory {
            try fileManager.moveItem(at: directory, to: backupDirectory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            HistoricalArchive.resetRecentGravityCacheForTesting()
            try? fileManager.removeItem(at: directory)
            if hadExistingDirectory {
                try? fileManager.moveItem(at: backupDirectory, to: directory)
            } else {
                try? fileManager.removeItem(at: backupDirectory)
            }
        }
        try body()
    }

    private func runOffMain<T>(_ body: @escaping () -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        DispatchQueue.global(qos: .userInteractive).async {
            result = body()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }

    private func historicalPayloadWithGravity(x: Float,
                                              y: Float,
                                              z: Float,
                                              counter: UInt32 = 0,
                                              timestamp: UInt32 = 0,
                                              subsecond: UInt16 = 0) -> [UInt8] {
        var payload = Array(repeating: UInt8(0), count: 80)
        payload[0] = 0x2f
        payload[1] = 24
        writeUInt32LE(counter, into: &payload, at: 3)
        writeUInt32LE(timestamp, into: &payload, at: 7)
        payload[11] = UInt8(truncatingIfNeeded: subsecond)
        payload[12] = UInt8(truncatingIfNeeded: subsecond >> 8)
        writeFloat32LE(x, into: &payload, at: 36)
        writeFloat32LE(y, into: &payload, at: 40)
        writeFloat32LE(z, into: &payload, at: 44)
        return payload
    }

    private func writeFloat32LE(_ value: Float, into payload: inout [UInt8], at offset: Int) {
        let raw = value.bitPattern
        payload[offset] = UInt8(raw & 0xff)
        payload[offset + 1] = UInt8((raw >> 8) & 0xff)
        payload[offset + 2] = UInt8((raw >> 16) & 0xff)
        payload[offset + 3] = UInt8((raw >> 24) & 0xff)
    }

    private func writeUInt32LE(_ value: UInt32, into payload: inout [UInt8], at offset: Int) {
        payload[offset] = UInt8(truncatingIfNeeded: value)
        payload[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        payload[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        payload[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
