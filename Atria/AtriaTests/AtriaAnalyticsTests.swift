import XCTest
import UIKit
@testable import Atria

final class AtriaAnalyticsTests: XCTestCase {
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
                let payload = historicalPayloadWithGravity(x: 0, y: 0, z: 1)
                let unix = UInt32(start.timeIntervalSince1970) + UInt32(index * 60)
                let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                                      capturedAt: start.addingTimeInterval(TimeInterval(index * 60)),
                                                      source: "0x2f",
                                                      layoutVersion: HistoricalArchive.layoutVersion,
                                                      sequence: index,
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
                                                      clockCorrectionStatus: "corrected",
                                                      currentSessionUsable: false,
                                                      metricUsable: false,
                                                      usabilityReason: "test_archive_stillness")
                _ = try HistoricalArchive.append(record)
            }

            let summary = try XCTUnwrap(HistoricalArchive.motionFeatureSummary(start: start,
                                                                               end: start.addingTimeInterval(30 * 60)))
            let result = AtriaSleepWakeResearch.classify(duration: 4 * 60 * 60,
                                                         averageHR: 62,
                                                         restingHR: 55,
                                                         imuStillnessRatio: summary.stillnessRatio,
                                                         imuMovementIntensity: summary.movementIntensity,
                                                         strapSteps: 0,
                                                         windowStart: start,
                                                         hrStandardDeviation: 2)
            XCTAssertEqual(result.state, "sleep_research")
            XCTAssertEqual(result.confidence, "research")
            XCTAssertEqual(result.reason, "low_motion_low_hr")
        }
    }

    func testHistoricalCurrentSessionReplayUsesCaptureAnchoredMotionWindow() throws {
        try withCleanHistoricalArchive {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let staleUnixBase: UInt32 = 1_781_000_000
            let step = 60
            let count = 300
            let batchCapturedAt = start.addingTimeInterval(TimeInterval((count - 1) * step))
            for index in 0..<count {
                let payload = historicalPayloadWithGravity(x: 0, y: 0, z: 1)
                let unix = staleUnixBase + UInt32(index * step)
                let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                                      capturedAt: batchCapturedAt,
                                                      source: "0x2f",
                                                      layoutVersion: HistoricalArchive.layoutVersion,
                                                      sequence: index,
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
                                                      clockWallRef: UInt32(batchCapturedAt.timeIntervalSince1970),
                                                      clockDriftSeconds: 9,
                                                      clockCorrectedUnix7: unix,
                                                      clockCorrectionStatus: "clock_ref_present",
                                                      currentSessionUsable: true,
                                                      metricUsable: false,
                                                      usabilityReason: "current_session_replay_ready_metric_reference_pending")
                _ = try HistoricalArchive.append(record)
            }

            let end = start.addingTimeInterval(TimeInterval((count - 1) * step))
            let diagnostics = HistoricalArchive.motionWindowDiagnostics(start: start, end: end)
            XCTAssertEqual(diagnostics.status, "ready")
            XCTAssertEqual(diagnostics.reason, "timestamp_aligned_low_motion")
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

        XCTAssertTrue(AtriaAnalytics.ManualSleep.inferredIsNap(start: day,
                                                               end: day.addingTimeInterval(45 * 60),
                                                               currentSelection: false,
                                                               calendar: calendar))
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
                       expectedHR: 60)
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
                       expectedHR: 60)
        }

        let sparse = HRVAnalyzer.analyze(sparseRR, now: now, includeTachogram: false).0
        XCTAssertEqual(sparse?.readinessReason, "gap")
        XCTAssertFalse(sparse?.isReady ?? true)
        XCTAssertGreaterThan(sparse?.maxRRGapSeconds ?? 0, HRVSnapshot.maxReadyRRGapSeconds)
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
                       expectedHR: nil)
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
                       expectedHR: 60)
        }
        samples[20] = RRInterval(t: samples[20].t, ms: 250, expectedHR: 60)
        samples[40] = RRInterval(t: samples[40].t, ms: 2_100, expectedHR: 60)
        samples[60] = RRInterval(t: samples[60].t, ms: 1_000, expectedHR: 120)

        let snapshot = HRVAnalyzer.analyze(samples, now: now, includeTachogram: false).0
        XCTAssertEqual(snapshot?.rejectedOutOfRange, 2)
        XCTAssertEqual(snapshot?.rejectedHRMismatch, 1)
        XCTAssertEqual(snapshot?.kept, 298)
        XCTAssertTrue(snapshot?.isReady == true)
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
                samples.append(PersonalBaseline.BaselineSample(date: now.addingTimeInterval(-Double(index) * 3_600),
                                                               restingHR: 55,
                                                               rmssd: 62,
                                                               overnight: true))
            }
            for index in 0..<6 {
                samples.append(PersonalBaseline.BaselineSample(date: now.addingTimeInterval(-Double(index + overnightCount) * 3_600),
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

    func testStrainTargetUsesRecoveryCurveAndAccumulatedDecay() {
        XCTAssertEqual(Coach.baseStrainTarget(recovery: 20), 9, accuracy: 0.0001)
        XCTAssertEqual(Coach.baseStrainTarget(recovery: 50), 13, accuracy: 0.0001)
        XCTAssertEqual(Coach.baseStrainTarget(recovery: 80), 17, accuracy: 0.0001)

        XCTAssertEqual(Coach.liveStrainTarget(recovery: 50, accumulatedStrain: 0), 13, accuracy: 0.0001)
        XCTAssertEqual(Coach.liveStrainTarget(recovery: 50, accumulatedStrain: 10), 12, accuracy: 0.0001)
        XCTAssertEqual(Coach.guide(recovery: 50, strain: 10).target ?? -1, 12, accuracy: 0.0001)
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
            return SavedSession.RRPoint(t: seconds, ms: Int((920 + wave * 70).rounded()))
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

    func testSleepRespiratoryRateFallsBackForOvernightHROnlyEvidence() {
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
            return SavedSession.RRPoint(t: seconds, ms: Int((920 + wave * 70).rounded()))
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

        XCTAssertNotNil(rate)
        XCTAssertEqual(rate ?? 0, 15.0, accuracy: 1.0)
    }

    func testSleepRespiratoryRateUsesEarlierRRWindowsWhenTailIsSparse() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000)
        var rrPoints = (0..<240).map { index -> SavedSession.RRPoint in
            let seconds = Double(index)
            let wave = sin(2 * Double.pi * seconds / 4.0)
            return SavedSession.RRPoint(t: seconds, ms: Int((920 + wave * 70).rounded()))
        }
        rrPoints.append(contentsOf: (0..<18).map { index in
            SavedSession.RRPoint(t: 900 + Double(index * 2), ms: 920)
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
                                                          now: samples.last!.t)

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
        XCTAssertEqual(result.elevatedSamples, 480, "only the trailing 8-min window counts")
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
    }

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
                rrPoints.append(SavedSession.RRPoint(t: cursor, ms: Int((60_000.0 / Double(bpm)).rounded())))
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

        XCTAssertTrue(readiness.ready, "a clean, RR-agreeing sustained effort must still count as a workout")
        XCTAssertTrue(readiness.reviewWorthyCandidate)
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
            rrPoints.append(SavedSession.RRPoint(t: rrCursor, ms: 1_090))
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
            rrPoints.append(SavedSession.RRPoint(t: rrCursor, ms: 1_090))
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
            rrPoints.append(SavedSession.RRPoint(t: rrCursor, ms: Int((60_000.0 / 120.0).rounded())))
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
        XCTAssertTrue(hero?.recoveryDetail.contains("provisional") == true)
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
        let activeCalories = AtriaAnalytics.Daily.dayCalories([
            .init(t: start, bpm: 60),
            .init(t: start.addingTimeInterval(60), bpm: 130),
            .init(t: start.addingTimeInterval(120), bpm: 150)
        ], rest: 60, profile: profile)
        XCTAssertGreaterThan(activeCalories ?? 0, 4.0)

        let gapDroppedCalories = AtriaAnalytics.Daily.dayCalories([
            .init(t: start, bpm: 60),
            .init(t: start.addingTimeInterval(600), bpm: 150)
        ], rest: 60, profile: profile)
        XCTAssertEqual(gapDroppedCalories, 0)

        let zoneSeconds = AtriaAnalytics.Strain.maxHeartRateZoneSeconds([
            (0, 90), (60, 110), (120, 130), (180, 150), (240, 170), (300, 190), (900, 190)
        ], maxHR: 200)
        XCTAssertEqual(zoneSeconds.rest, 0)
        XCTAssertEqual(zoneSeconds.warmup, 60)
        XCTAssertEqual(zoneSeconds.fatBurn, 60)
        XCTAssertEqual(zoneSeconds.aerobic, 60)
        XCTAssertEqual(zoneSeconds.anaerobic, 60)
        XCTAssertEqual(zoneSeconds.max, 60)
        XCTAssertEqual(zoneSeconds.droppedGapSeconds, 600)
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

    func testHistoricalArchiveStatusFailsClosedUntilArchiveIsParseable() {
        let parseFailed = SessionStore.HistoricalArchiveStatus(exists: true,
                                                               parseOK: false,
                                                               rows: 12,
                                                               metricUsableRows: 4,
                                                               currentSessionUsableRows: 4,
                                                               reason: "invalid_jsonl_row_12")
        XCTAssertFalse(parseFailed.metricReady)
        XCTAssertEqual(parseFailed.valueText, "Repair")
        // currentSessionUsableRows > 0 takes priority in metricGateText even when the
        // archive fails to parse; valueText ("Repair") still fails closed for the
        // headline status. See SessionStore.HistoricalArchiveStatus.metricGateText.
        XCTAssertEqual(parseFailed.metricGateText, "Saved only")
        XCTAssertEqual(parseFailed.userFootnoteText, "Archive needs repair.")

        let gated = SessionStore.HistoricalArchiveStatus(exists: true,
                                                         parseOK: true,
                                                         rows: 12,
                                                         metricUsableRows: 0,
                                                         currentSessionUsableRows: 8,
                                                         reason: "ok")
        XCTAssertFalse(gated.metricReady)
        XCTAssertEqual(gated.valueText, "Saved")
        XCTAssertEqual(gated.metricGateText, "Saved only")
        XCTAssertTrue(gated.userFootnoteText.contains("checking whether they can affect HRV, Recovery and Sleep"))

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

    func testHistoricalArchiveMetricHeartRatePointsCanReturnBoundedRecentSlice() throws {
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

            XCTAssertEqual(points.map(\.bpm), [62, 63, 64])
            XCTAssertEqual(points.map { Int($0.t.timeIntervalSince1970) }, [1_800_200_120, 1_800_200_180, 1_800_200_240])
        }
    }

    private func baselineSamples(count: Int, now: Date) -> [PersonalBaseline.BaselineSample] {
        (0..<count).map { index in
            PersonalBaseline.BaselineSample(date: now.addingTimeInterval(Double(-index * 86_400)),
                                            restingHR: [58.0, 60.0, 62.0][index % 3],
                                            rmssd: [48.0, 52.0, 56.0][index % 3])
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

    func testFitnessAgeUsesFourInputsAndClampsBoundaryOffsets() {
        XCTAssertEqual(AtriaFitnessAge.restingHeartRateOffset(age: 40, restingHeartRate: 52), -6)
        XCTAssertEqual(AtriaFitnessAge.restingHeartRateOffset(age: 40, restingHeartRate: 72), 6)
        XCTAssertEqual(AtriaFitnessAge.zone2PlusOffset(minutes: 0), 4)
        XCTAssertEqual(AtriaFitnessAge.zone2PlusOffset(minutes: 300), -4)
        XCTAssertEqual(AtriaFitnessAge.sleepConsistencyOffset(percent: 50), 3)
        XCTAssertEqual(AtriaFitnessAge.sleepConsistencyOffset(percent: 95), -3)

        let ready = AtriaFitnessAge.summary(inputs: AtriaFitnessAge.Inputs(chronologicalAge: 40,
                                                                          restingHeartRate: 52,
                                                                          hrvRMSSD: 80,
                                                                          weeklyZone2PlusMinutes: 300,
                                                                          sleepConsistencyPercent: 95,
                                                                          historyDays: 28))

        XCTAssertEqual(ready.biologicalAge, 28)
        XCTAssertEqual(ready.ageDelta, -12)
        XCTAssertEqual(ready.factors.map(\.id), ["rhr", "lnrmssd", "zone2", "sleep_consistency"])
        XCTAssertEqual(ready.footnote, AtriaFitnessAge.footnoteText)
        XCTAssertTrue(ready.agingPaceDetail.contains("helping"))
    }

    func testFitnessAgeStaysCalibratingUntilTwentyEightDays() {
        let summary = AtriaFitnessAge.summary(inputs: AtriaFitnessAge.Inputs(chronologicalAge: 40,
                                                                            restingHeartRate: 58,
                                                                            hrvRMSSD: 55,
                                                                            weeklyZone2PlusMinutes: 180,
                                                                            sleepConsistencyPercent: 88,
                                                                            historyDays: 27))

        XCTAssertNil(summary.biologicalAge)
        XCTAssertEqual(summary.agingPaceText, "Calibrating")
        XCTAssertTrue(summary.blockers.contains("28 days of heart data"))
    }

    func testFitnessAgePaceRequiresAtLeast28Entries() {
        let calendar = Calendar(identifier: .gregorian)
        func deltas(count: Int) -> [AtriaFitnessAge.DailyDelta] {
            (0..<count).map { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: Date(timeIntervalSince1970: 1_780_000_000))!
                return AtriaFitnessAge.DailyDelta(day: day, delta: 0)
            }
        }

        let thin = AtriaFitnessAge.paceOfAging(deltas: deltas(count: 27))
        XCTAssertFalse(thin.isReady)
        XCTAssertNil(thin.yearsPerCalendarYear)
        XCTAssertEqual(thin.copyText, AtriaFitnessAge.paceCalibratingCopy)

        let ready = AtriaFitnessAge.paceOfAging(deltas: deltas(count: 28))
        XCTAssertTrue(ready.isReady)
        XCTAssertNotNil(ready.yearsPerCalendarYear)
    }

    func testFitnessAgePaceSlopeCopyMatchesDeltaTrend() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        // Fitness-age delta drifting up by exactly 1 year every 365.25 days
        // (one calendar year) should read as aging ~1.0y/yr faster than the clock.
        let agingFaster: [AtriaFitnessAge.DailyDelta] = (0..<40).map { offset in
            let day = calendar.date(byAdding: .day, value: offset * 30, to: start)!
            let delta = Int((Double(offset) * 30.0 / 365.25).rounded())
            return AtriaFitnessAge.DailyDelta(day: day, delta: delta)
        }
        let faster = AtriaFitnessAge.paceOfAging(deltas: agingFaster)
        XCTAssertTrue(faster.isReady)
        let fasterSlope = try XCTUnwrap(faster.yearsPerCalendarYear)
        XCTAssertEqual(fasterSlope, 1.0, accuracy: 0.15)
        XCTAssertTrue(faster.copyText.contains("faster than the clock"), faster.copyText)
        XCTAssertTrue(faster.copyText.hasPrefix("Aging ~"), faster.copyText)

        // A flat -1 delta every day (no drift) should read as slower than the clock
        // (or at least never as "faster"), matching the sign of the near-zero/negative slope.
        let steadyYounger: [AtriaFitnessAge.DailyDelta] = (0..<40).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            return AtriaFitnessAge.DailyDelta(day: day, delta: -1)
        }
        let slower = AtriaFitnessAge.paceOfAging(deltas: steadyYounger)
        XCTAssertTrue(slower.isReady)
        XCTAssertEqual(slower.yearsPerCalendarYear ?? .nan, 0, accuracy: 0.01)
        XCTAssertTrue(slower.copyText.contains("slower than the clock"), slower.copyText)
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
        let points = stride(from: 0.0, through: 9 * 60.0, by: 60.0).map {
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
        XCTAssertEqual(paused.trimp(rest: 60, max: 190),
                       Metrics.trimp(points.filter { $0.t < 3 * 60 || $0.t > 6 * 60 }.map { (t: $0.t, bpm: $0.bpm) },
                                     rest: 60,
                                     max: 190),
                       accuracy: 0.0001)

        let breathwork = SavedSession(id: UUID(),
                                      start: start,
                                      end: start.addingTimeInterval(9 * 60),
                                      label: "Breathwork",
                                      points: points,
                                      kind: "breathwork")
        XCTAssertEqual(breathwork.trimp(rest: 60, max: 190), 0)
    }

    func testSavedSessionPauseExcludesCaloriesAndZones() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = stride(from: 0.0, through: 9 * 60.0, by: 60.0).map {
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
        XCTAssertEqual(paused.timeInZone(maxHR: 190).values.reduce(0, +),
                       AtriaAnalytics.Strain.maxHeartRateZoneSeconds(
                           points.filter { $0.t < 3 * 60 || $0.t > 6 * 60 }.map { (t: $0.t, bpm: $0.bpm) },
                           maxHR: 190
                       ).storage.values.reduce(0, +),
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
                                          strain: 8.4)
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
        XCTAssertEqual(rollupPayload.today, today)
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
        XCTAssertTrue(openAIPreview.summary.contains("gpt-4.1-mini"))
        XCTAssertTrue(openAIPreview.promptLine.contains(rollupPayload.now))
        XCTAssertTrue(openAIPreview.payloadLine.contains("Recovery 64 %"))
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

    // MARK: - HR-only sleep auto-confirm (degraded tier) + today rollup-from-wear

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

    /// A fragmented overnight artifact night (three watchdog-reconnect segments)
    /// with a small, bounded hr_mismatch-style burst inside the middle fragment —
    /// the exact shape the degraded HR-only auto-confirm tier exists for.
    func testArtifactFragmentedOvernightConfirmsAsDegradedHROnlySleep() {
        let calendar = utcCalendar
        let rest = 50

        let frag1Start = utcDate(2027, 3, 2, 0, 10)
        let frag1End = utcDate(2027, 3, 2, 2, 0)
        let frag1 = flatHRSession(start: frag1Start, end: frag1End, bpm: 52)

        let frag2Start = utcDate(2027, 3, 2, 2, 30)
        let frag2End = utcDate(2027, 3, 2, 4, 30)
        // 120 one-minute samples: 105 true low-HR + 15 bounded ~95bpm artifact burst
        // (an accepted hr_mismatch-style spike) — a small enough fraction to stay
        // under the elevated-sample-fraction and hrP90 gates.
        let frag2Points = (0..<105).map { SavedSession.Point(t: Double($0) * 60, bpm: 52) }
            + (0..<15).map { SavedSession.Point(t: Double(105 + $0) * 60, bpm: 95) }
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
                      "a bounded artifact burst in an otherwise low-HR fragmented night should clear the degraded gate")
        XCTAssertTrue(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))

        let classification = SessionStore.autoSleepClassification(for: candidate)
        XCTAssertEqual(classification.source, "auto_confirmed_sleep_hr_only")
        XCTAssertEqual(classification.confidence, "hr_only")
        XCTAssertFalse(classification.motionValidated)
        XCTAssertEqual(classification.motionSource, "strap_hr_only")
        XCTAssertTrue(classification.isHROnly)

        // auto_confirmed_sleep_hr_only must be registered as an explicit sleep
        // source (SleepHistorySnapshot.Night.explicitSleepSources is fileprivate,
        // so exercise the registration through the public snapshot API instead of
        // reaching into the private set directly): an unregistered source would
        // fall through to fitsNapCandidateWindow and could get misclassified as a
        // nap, breaking the rollup/recovery flow.
        let confirmed = UserConfirmedSleep(id: "test-hr-only-registration",
                                           createdAt: candidate.start,
                                           start: candidate.start,
                                           end: candidate.end,
                                           source: classification.source,
                                           confidence: classification.confidence,
                                           sessions: candidate.sessions,
                                           samples: candidate.samples,
                                           avgHR: candidate.avgHR,
                                           peakHR: candidate.peakHR,
                                           restingHR: candidate.restingHR,
                                           hrv: nil,
                                           hrvWindowCount: nil,
                                           duration: candidate.duration,
                                           span: candidate.span,
                                           reason: "test",
                                           motionSource: classification.motionSource,
                                           motionValidated: classification.motionValidated,
                                           stageSegments: nil)
        let snapshot = SleepHistorySnapshot(rollups: [], confirmedSleeps: [confirmed])
        XCTAssertEqual(snapshot.nights.first?.isNapEvidence, false,
                       "auto_confirmed_sleep_hr_only must classify as sleep, not a nap")
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
        XCTAssertEqual(candidates.count, 1)
        guard let candidate = candidates.first else { return }

        XCTAssertEqual(candidate.kind, "overnight_sleep")
        XCTAssertFalse(SessionStore.isUnambiguousHROnlyMainSleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isDegradedHROnlyOvernightSleepCandidate(candidate),
                       "a couch evening should fail on sleep-core overlap even though duration clears 3h")
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
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
        XCTAssertEqual(candidates.count, 1)
        guard let candidate = candidates.first else { return }

        XCTAssertEqual(candidate.kind, "nap_candidate")
        XCTAssertFalse(SessionStore.isUnambiguousHROnlyMainSleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isDegradedHROnlyOvernightSleepCandidate(candidate),
                       "the degraded tier is main-sleep-only and must reject nap-shaped candidates outright")
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
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
                let payload = self.historicalPayloadWithGravity(x: 0, y: 0, z: 1)
                let capturedAt = Date(timeIntervalSince1970: TimeInterval(unix))
                let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                                      capturedAt: capturedAt,
                                                      source: "0x2f",
                                                      layoutVersion: HistoricalArchive.layoutVersion,
                                                      sequence: index,
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
                                                      clockCorrectionStatus: "corrected",
                                                      currentSessionUsable: false,
                                                      metricUsable: false,
                                                      usabilityReason: "test_degraded_vs_motion_priority")
                _ = try? HistoricalArchive.append(record)
                index += 1
                unix += 60
            }

            let candidates = SessionStore.aggregateSleepCandidates(in: [frag1, frag2, frag3],
                                                                   rest: rest,
                                                                   maxHR: 190,
                                                                   calendar: calendar,
                                                                   historicalMotionPolicy: .boundedRecent)
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
    /// produce a candidate that clears `isStrongAutoConfirmableSleepCandidate`.
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
        XCTAssertEqual(buggyCandidates.count, 1)
        if let buggyCandidate = buggyCandidates.first {
            XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(buggyCandidate),
                          "the still-open session's whole span (including the awake tail) must not auto-confirm")
        }

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
        XCTAssertTrue(SessionStore.isStrongAutoConfirmableSleepCandidate(fixed),
                     "trimming the awake tail should let the sleep-only portion clear the strong auto-confirm gate")
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
        XCTAssertTrue(SessionStore.isStrongAutoConfirmableSleepCandidate(fixed))
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
        try skipIfRealHistoricalArchivePresent()

        let fileManager = FileManager.default
        let url = HistoricalArchive.fileURL
        let directory = url.deletingLastPathComponent()
        let existing = try? Data(contentsOf: url)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: url)
            if let existing {
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try? existing.write(to: url, options: .atomic)
            }
        }
        try body()
    }

    private func historicalPayloadWithGravity(x: Float, y: Float, z: Float) -> [UInt8] {
        var payload = Array(repeating: UInt8(0), count: 80)
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
}
