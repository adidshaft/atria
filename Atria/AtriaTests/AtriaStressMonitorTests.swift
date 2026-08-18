import XCTest
import Combine
@testable import Atria

final class AtriaStressMonitorTests: XCTestCase {
    @MainActor
    func testInactivePresentationFreezesObservableMirrorsWhileHistoryPersists() async throws {
        let (persistence, directory) = makeStressHistoryPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        var applicationIsActive = false
        let store = AtriaStressMonitorStore(
            historyPersistence: persistence,
            historyLoadNow: now,
            presentationPublishingIsActive: false,
            applicationIsActive: { applicationIsActive }
        )
        var objectWillChangeCount = 0
        let cancellable = store.objectWillChange.sink {
            objectWillChangeCount += 1
        }
        await store.waitForHistoryHydration()
        XCTAssertEqual(store.historyLoadState, .loading,
                       "background hydration must remain private until foreground")
        let baseline = makeBaseline(restingMean: 60,
                                    restingSD: 4,
                                    hrvSampleDays: 0)
        for offset in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
            store.update(heartRate: 98,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 1,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }
        await store.waitForPendingHistoryCheckpoint()

        XCTAssertEqual(objectWillChangeCount, 0)
        XCTAssertEqual(store.state, .noSignal)
        XCTAssertNil(store.liveHeartRate)
        XCTAssertNil(store.lastMeasuredAt)
        XCTAssertEqual(store.historyRevision, 0)
        XCTAssertEqual(store.distributionRevision, 0)
        XCTAssertEqual(store.history.count, 1,
                       "private stress computation must keep its minute fact")
        XCTAssertEqual(
            try XCTUnwrap(store.distributionComparison(
                now: now.addingTimeInterval(300)
            )).today.sampleCount,
            1,
            "distribution durability must continue while presentation is frozen"
        )
        guard case .loaded(let persisted) = await persistence.load(
            now: now.addingTimeInterval(300)
        ) else {
            return XCTFail("inactive stress history must still reach durable storage")
        }
        XCTAssertEqual(persisted.points.count, 1)

        store.setPresentationPublishingActive(true)
        store.publishLatestPresentation()
        XCTAssertEqual(objectWillChangeCount, 0,
                       "cached scene authority remains inert while UIApplication is inactive")
        applicationIsActive = true
        store.setPresentationPublishingActive(true)
        XCTAssertEqual(store.state.kind, .scored)
        XCTAssertEqual(store.liveHeartRate?.bpm, 98)
        XCTAssertEqual(store.lastMeasuredAt,
                       now.addingTimeInterval(300))
        XCTAssertEqual(store.historyRevision, 1)
        XCTAssertEqual(store.historyLoadState, .loaded)
        XCTAssertEqual(store.distributionRevision, 1)
        XCTAssertGreaterThan(objectWillChangeCount, 0)

        let resumedPublicationCount = objectWillChangeCount
        store.setPresentationPublishingActive(true)
        XCTAssertEqual(objectWillChangeCount, resumedPublicationCount,
                       "repeated active/tab delivery must not replay the catch-up")
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testLiveStoreCarriesOnlyExplicitQualifiedSleepContextIntoV3Fact() throws {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)
        func fact(hasSleepEvidence: Bool) throws
            -> AtriaPhysiologicalStressModel.MinuteFact {
            let store = AtriaStressMonitorStore()
            for offset in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
                store.update(heartRate: 64,
                             hasContact: true,
                             recentRRSamples: [],
                             isRecording: false,
                             zoneIndex: 0,
                             hrvSnapshot: nil,
                             baseline: baseline,
                             restingMaxHR: restingMaxHR,
                             hasActiveSleepEvidence: hasSleepEvidence,
                             now: now.addingTimeInterval(offset))
            }
            XCTAssertEqual(store.state.kind, .scored,
                           "qualified sleep is context, not score suppression")
            return try XCTUnwrap(store.state.minuteFact)
        }

        XCTAssertEqual(try fact(hasSleepEvidence: false).sleepContext, .unavailable)
        XCTAssertEqual(try fact(hasSleepEvidence: true).sleepContext, .asleep)
    }

    // Warm-up is anchored to accepted-HR continuity. A brief contact flicker
    // must not restart the complete five-minute window; a sustained loss
    // longer than the continuity grace must.
    @MainActor
    func testWarmUpSurvivesBriefContactFlicker() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)
        let store = AtriaStressMonitorStore()

        func tick(atOffset offset: TimeInterval, hasContact: Bool) {
            store.update(heartRate: hasContact ? 62 : 0,
                         hasContact: hasContact,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }

        tick(atOffset: 0, hasContact: true)
        XCTAssertEqual(store.state.kind, .warmingUp)
        tick(atOffset: 50, hasContact: true)
        XCTAssertEqual(store.state.kind, .warmingUp)

        // 100s in, one flicker (single zero-contact tick), contact resumes.
        tick(atOffset: 100, hasContact: false)
        XCTAssertEqual(store.state.kind, .noSignal)
        tick(atOffset: 106, hasContact: true)

        // Complete the original five-minute horizon. The six-second flicker
        // did not reset its clock or create an internal HR gap.
        tick(atOffset: 125, hasContact: true)
        tick(atOffset: 180, hasContact: true)
        tick(atOffset: 240, hasContact: true)
        tick(atOffset: 300, hasContact: true)
        XCTAssertEqual(store.state.kind, .scored)
    }

    @MainActor
    func testWarmUpRestartsAfterSustainedContactLoss() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)
        let store = AtriaStressMonitorStore()

        func tick(atOffset offset: TimeInterval, hasContact: Bool) {
            store.update(heartRate: hasContact ? 62 : 0,
                         hasContact: hasContact,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }

        tick(atOffset: 0, hasContact: true)
        tick(atOffset: 50, hasContact: true)
        tick(atOffset: 100, hasContact: true)
        // A 75s outage — past the 60s continuity grace.
        tick(atOffset: 130, hasContact: false)
        tick(atOffset: 175, hasContact: false)
        // Contact returns: this is fresh contact and warm-up restarts, so at
        // +40s of the new epoch the tile is still honestly warming up.
        tick(atOffset: 180, hasContact: true)
        tick(atOffset: 220, hasContact: true)
        XCTAssertEqual(store.state.kind, .warmingUp)
        // ...and completes five minutes after the new contact epoch.
        tick(atOffset: 260, hasContact: true)
        tick(atOffset: 300, hasContact: true)
        tick(atOffset: 360, hasContact: true)
        tick(atOffset: 420, hasContact: true)
        tick(atOffset: 480, hasContact: true)
        XCTAssertEqual(store.state.kind, .scored)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let restingMaxHR: (rest: Int, max: Int) = (rest: 60, max: 190)

    // MARK: Baseline fixture

    /// Builds a `PersonalBaseline` with `dayCount` distinct fresh days (all
    /// overnight), each contributing a resting-HR sample alternating
    /// `restingMean +/- restingSD`. When `lnRMSSDMean`/`lnRMSSDSD` are supplied,
    /// the first `hrvSampleDays` of those days also carry an RMSSD value
    /// alternating around the given ln-space mean/sd, so the HRV trust gate
    /// (14 distinct days) can be controlled independently of the resting gate.
    private func makeBaseline(restingMean: Double,
                              restingSD: Double,
                              lnRMSSDMean: Double? = nil,
                              lnRMSSDSD: Double? = nil,
                              hrvSampleDays: Int = 0,
                              dayCount: Int = 20) -> PersonalBaseline {
        var samples: [PersonalBaseline.BaselineSample] = []
        for day in 0..<dayCount {
            let date = now.addingTimeInterval(-Double(day + 1) * 24 * 60 * 60)
            let sign = (day % 2 == 0) ? 1.0 : -1.0
            let restingHR = restingMean + sign * restingSD
            var rmssd: Double?
            if day < hrvSampleDays, let lnRMSSDMean, let lnRMSSDSD {
                rmssd = exp(lnRMSSDMean + sign * lnRMSSDSD)
            }
            samples.append(PersonalBaseline.BaselineSample(date: date,
                                                            restingHR: restingHR,
                                                            rmssd: rmssd,
                                                            overnight: true))
        }
        let hrvEMA = lnRMSSDMean.map(exp)
        return PersonalBaseline(restingHR: restingMean, hrvEMA: hrvEMA,
                                sessions: dayCount, updated: now, samples: samples)
    }

    /// A continuous, artifact-screenable five-minute tachogram whose adjacent
    /// intervals alternate by `rmssd` milliseconds. The resulting RMSSD is
    /// exactly `rmssd`, making evidence-mode transition tests deterministic.
    private func qualifiedRRSamples(endingAt end: Date,
                                    rmssd: Int = 100,
                                    heartRate: Int = 98) -> [AtriaBreathworkSession.RRSample] {
        let center = 60_000 / heartRate
        let lower = center - rmssd / 2
        let upper = center + rmssd / 2
        var samples: [AtriaBreathworkSession.RRSample] = []
        var clock = end.addingTimeInterval(-300)
        var index = 0
        while clock <= end {
            let milliseconds = index.isMultiple(of: 2) ? lower : upper
            samples.append(.init(date: clock,
                                 ms: milliseconds,
                                 source: .standardHeartRateMeasurement2A37))
            clock = clock.addingTimeInterval(Double(milliseconds) / 1_000)
            index += 1
        }
        return samples
    }

    private var historicalPersonalization: AtriaPhysiologicalStressModel.Personalization {
        .init(restingHeartRate: 60,
              maximumHeartRate: 190,
              restingBaselineDayCount: 20,
              hrvBaseline: .init(medianLnRMSSD: log(80),
                                 robustScale: 0.2,
                                 qualifiedDayCount: 20))
    }

    private func replayAuthority(cardiac: String = "v1:0000000000000001",
                                 calibration: String = "v1:0000000000000001",
                                 context: String = "v1:0000000000000001")
        -> AtriaStressReplayAuthority {
        AtriaStressReplayAuthority(cardiacInputRevision: cardiac,
                                   calibrationRevision: calibration,
                                   contextRevision: context)
    }

    private func replayFact(
        at date: Date,
        score: Double,
        meanHeartRate: Double = 132,
        rmssd: Double? = 42,
        hrStress: Double = 0.82,
        hrvStress: Double? = 0.74,
        heartRateWeight: Double = 0.62,
        motion: AtriaPhysiologicalStressModel.MotionContext = .unavailable,
        sleep: AtriaPhysiologicalStressModel.SleepContext = .unavailable,
        confidence: AtriaPhysiologicalStressModel.Confidence = .medium,
        baselineLearning: Bool = false
    ) -> AtriaPhysiologicalStressModel.MinuteFact {
        .init(date: date,
              score: score,
              unsmoothedScore: score,
              meanHeartRate: meanHeartRate,
              rmssd: rmssd,
              hrStress: hrStress,
              hrvStress: hrvStress,
              heartRateWeight: heartRateWeight,
              motionContext: motion,
              sleepContext: sleep,
              confidence: confidence,
              baselineLearning: baselineLearning)
    }

    private func replayResult(
        _ facts: [AtriaPhysiologicalStressModel.MinuteFact],
        authorities: [AtriaStressReplayAuthority],
        managedRanges: [AtriaHistoricalStressReplay.ManagedRange] = []
    ) -> AtriaHistoricalStressReplay.Result {
        XCTAssertEqual(facts.count, authorities.count)
        return AtriaHistoricalStressReplay.Result(
            facts: facts,
            heartRates: facts.map {
                .init(date: $0.date, bpm: Int($0.meanHeartRate.rounded()))
            },
            authorityByDate: Dictionary(uniqueKeysWithValues:
                zip(facts.map(\.date), authorities)),
            managedRanges: managedRanges
        )
    }

    private func historicalHeartRates(endingAt end: Date,
                                      duration: TimeInterval = 420,
                                      bpm: Int = 75) -> [AtriaHistoricalStressReplay.HeartRateRow] {
        let sampleCount = Int(duration / 30)
        return (0...sampleCount).map { index in
            .init(date: end.addingTimeInterval(-duration + Double(index) * 30),
                  bpm: bpm)
        }
    }

    private func historicalRR(endingAt end: Date,
                              duration: TimeInterval = 420,
                              source: AtriaRRSourceProvenance)
        -> [AtriaHistoricalStressReplay.RRRow] {
        var rows: [AtriaHistoricalStressReplay.RRRow] = []
        var clock = end.addingTimeInterval(-duration)
        var index = 0
        while clock <= end {
            let milliseconds = index.isMultiple(of: 2) ? 760 : 840
            rows.append(.init(date: clock,
                              milliseconds: milliseconds,
                              source: source))
            clock = clock.addingTimeInterval(Double(milliseconds) / 1_000)
            index += 1
        }
        return rows
    }

    func testRRHeartRateMismatchUsesTimeAlignedObservationNotLatestHR() {
        let start = now.addingTimeInterval(-300)
        let samples = [
            AtriaBreathworkSession.RRSample(
                date: start.addingTimeInterval(1),
                ms: 1_000,
                source: .standardHeartRateMeasurement2A37
            ),
            AtriaBreathworkSession.RRSample(
                date: now.addingTimeInterval(-1),
                ms: 500,
                source: .standardHeartRateMeasurement2A37
            ),
        ]
        let aligned = AtriaStressMonitorStore.timeAlignedRRIntervals(
            samples,
            heartRates: [(t: start, bpm: 60), (t: now, bpm: 120)],
            start: start,
            end: now
        )

        XCTAssertEqual(aligned.map(\.expectedHR), [60, 120])
        XCTAssertTrue(aligned.allSatisfy {
            $0.source == .standardHeartRateMeasurement2A37
        })
    }

    func testRRHeartRateAlignmentFailsClosedOnClockRegression() {
        let samples = [
            AtriaBreathworkSession.RRSample(date: now, ms: 800),
            AtriaBreathworkSession.RRSample(
                date: now.addingTimeInterval(-1),
                ms: 800
            ),
        ]
        XCTAssertTrue(AtriaStressMonitorStore.timeAlignedRRIntervals(
            samples,
            heartRates: [(t: now, bpm: 75)],
            start: now.addingTimeInterval(-300),
            end: now
        ).isEmpty)
    }

    func testOnlyIndependentlyQualifiedActiveSleepBecomesStressContext() {
        func sleep(source: String,
                   confidence: String,
                   motionValidated: Bool) -> UserConfirmedSleep {
            let start = now.addingTimeInterval(-2 * 3_600)
            let end = now.addingTimeInterval(2 * 3_600)
            return UserConfirmedSleep(
                id: UUID().uuidString,
                createdAt: now,
                start: start,
                end: end,
                source: source,
                confidence: confidence,
                sessions: 1,
                samples: 1,
                avgHR: 60,
                peakHR: 70,
                restingHR: 55,
                hrv: nil,
                hrvWindowCount: nil,
                duration: end.timeIntervalSince(start),
                span: end.timeIntervalSince(start),
                reason: "test",
                motionSource: motionValidated ? "validated" : "none",
                motionValidated: motionValidated,
                stageSegments: nil
            )
        }

        XCTAssertFalse(AtriaStressMonitorStore.hasQualifiedActiveSleepEvidence(
            in: [sleep(source: "detected", confidence: "low", motionValidated: false)],
            at: now
        ))
        XCTAssertTrue(AtriaStressMonitorStore.hasQualifiedActiveSleepEvidence(
            in: [sleep(source: "detected", confidence: "high", motionValidated: true)],
            at: now
        ))
        XCTAssertTrue(AtriaStressMonitorStore.hasQualifiedActiveSleepEvidence(
            in: [sleep(source: "manual_sleep",
                       confidence: "user_confirmed_manual",
                       motionValidated: false)],
            at: now
        ))
    }

    // MARK: Scored cases

    func testCalmAtPersonalBaselineHROnly() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 60,
                                             hrWindow: [60, 60, 60],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .scored)
        XCTAssertEqual(state.level, .calm)
        XCTAssertFalse(state.hrvAvailable)
        XCTAssertEqual(state.detail, "HR-only estimate · lower confidence")
    }

    func testDebugCompatibilityAdapterExpandsFiveValuesAtRawCadence() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)
        let state = AtriaStressMonitor.score(
            hrNow: 64,
            hrWindow: [60, 61, 62, 63, 64],
            rrWindowMs: [],
            hrvFallbackRMSSD: nil,
            baseline: baseline,
            restingMaxHR: restingMaxHR,
            workoutActive: false,
            zoneIndex: 0,
            inSleepWindow: false,
            hasContact: true,
            contactAgeSeconds: 300,
            now: now
        )

        XCTAssertEqual(state.kind, .scored)
        XCTAssertNotNil(state.minuteFact,
                        "five legacy values must expand to six cadence-safe points")
    }

    func testEvidenceProjectionSeparatesNumericStressFromCardiacArousalAndClampsBounds() {
        let stress = AtriaStressEvidenceProjection(activation: 1.5,
                                                   mode: .physiologicalStress)
        XCTAssertEqual(stress.activation, 1)
        XCTAssertEqual(stress.displayValue, 3)
        XCTAssertEqual(stress.numericStressScore, 3)
        XCTAssertNil(stress.cardiacArousalValue)

        let arousal = AtriaStressEvidenceProjection(activation: -0.5,
                                                    mode: .cardiacArousal)
        XCTAssertEqual(arousal.activation, 0)
        XCTAssertEqual(arousal.displayValue, 0)
        XCTAssertEqual(arousal.numericStressScore, 0,
                       "HR-only remains numeric but explicitly lower-confidence")
        XCTAssertEqual(arousal.cardiacArousalValue, 0)

        let nonFinite = AtriaStressEvidenceProjection(activation: .infinity,
                                                      mode: .physiologicalStress)
        XCTAssertEqual(nonFinite.activation, 0, "invalid input fails closed")
    }

    func testProductScaleThresholdsExactlyMatchCanonicalBandSemantics() {
        XCTAssertEqual(AtriaStressEvidenceProjection.lowStartsAt, 1, accuracy: 1e-12)
        XCTAssertEqual(AtriaStressEvidenceProjection.mediumStartsAt, 1, accuracy: 1e-12)
        XCTAssertEqual(AtriaStressEvidenceProjection.highStartsAt, 2, accuracy: 1e-12)

        XCTAssertEqual(AtriaStressMonitor.band(AtriaStressMonitor.calmUpperBound.nextDown),
                       AtriaStressLevel.calm.rawValue)
        XCTAssertEqual(AtriaStressMonitor.band(AtriaStressMonitor.calmUpperBound),
                       AtriaStressLevel.medium.rawValue)
        XCTAssertEqual(AtriaStressMonitor.band(AtriaStressMonitor.lowUpperBound),
                       AtriaStressLevel.medium.rawValue)
        XCTAssertEqual(AtriaStressMonitor.band(AtriaStressMonitor.mediumUpperBound),
                       AtriaStressLevel.high.rawValue)
    }

    func testUntimestampedHRVFallbackCannotFabricateQualifiedHRV() throws {
        let baseline = makeBaseline(restingMean: 60,
                                    restingSD: 4,
                                    lnRMSSDMean: log(100),
                                    lnRMSSDSD: 0.15,
                                    hrvSampleDays: 20)
        let state = AtriaStressMonitor.score(
            hrNow: 60,
            hrWindow: [60, 60, 60],
            rrWindowMs: [],
            hrvFallbackRMSSD: 100,
            baseline: baseline,
            restingMaxHR: restingMaxHR,
            workoutActive: false,
            zoneIndex: 0,
            inSleepWindow: false,
            hasContact: true,
            contactAgeSeconds: 300,
            awakeReference: (center: 75, spread: 14),
            now: now
        )

        XCTAssertEqual(state.evidenceMode, .physiologicalStress)
        XCTAssertFalse(state.hrvAvailable)
        XCTAssertTrue(try XCTUnwrap(state.minuteFact).isHROnly)
        let presentation = AtriaStressPresentation.make(state: state)
        XCTAssertNotNil(presentation.numericScore)
        XCTAssertTrue(presentation.narrative.contains("heart rate only"))
        XCTAssertTrue(presentation.narrative.contains("not a psychological diagnosis"))
    }

    func testHROnlyPresentationIsNumericLowerConfidenceAndSeparatelyQueryable() throws {
        let state = AtriaStressState(level: .medium,
                                     label: "Medium",
                                     detail: "HR-only",
                                     kind: .scored,
                                     confidence: 0.55,
                                     rawActivation: AtriaStressMonitor.mediumUpperBound,
                                     hrvAvailable: false)
        let presentation = AtriaStressPresentation.make(state: state)

        XCTAssertEqual(presentation.evidenceMode, .cardiacArousal)
        XCTAssertEqual(presentation.metricTitle, "Physiological stress")
        XCTAssertEqual(try XCTUnwrap(presentation.numericScore), 2, accuracy: 1e-12)
        XCTAssertEqual(
            try XCTUnwrap(state.evidenceProjection?.cardiacArousalValue),
            AtriaStressEvidenceProjection.highStartsAt,
            accuracy: 1e-12
        )
        XCTAssertTrue(presentation.detail.contains("HR-only estimate"))
        XCTAssertTrue(presentation.narrative.contains("lower-confidence estimate"))
    }

    func testV3DynamicWeightCombinesOnlyQualifiedRRWithHR() throws {
        let baseline = makeBaseline(restingMean: 55, restingSD: 3,
                                    lnRMSSDMean: log(45), lnRMSSDSD: 0.15,
                                    hrvSampleDays: 20)
        let awake = (center: 72.0, spread: 12.0)
        func result(hr: Int, rmssd: Int) -> AtriaStressState {
            let lower = 1_000 - rmssd / 2
            let upper = 1_000 + rmssd / 2
            let rr = (0...180).map { $0.isMultiple(of: 2) ? lower : upper }
            return AtriaStressMonitor.score(hrNow: hr, hrWindow: [hr, hr, hr], rrWindowMs: rr,
                                     hrvFallbackRMSSD: nil, baseline: baseline,
                                     restingMaxHR: restingMaxHR, workoutActive: false,
                                     zoneIndex: 0, inSleepWindow: false, hasContact: true,
                                     contactAgeSeconds: 300, awakeReference: awake, now: now)
        }
        let normalHRV = result(hr: 95, rmssd: 45)
        let suppressedHRV = result(hr: 95, rmssd: 6)
        XCTAssertTrue(normalHRV.hrvAvailable)
        XCTAssertTrue(suppressedHRV.hrvAvailable)
        XCTAssertGreaterThan(suppressedHRV.rawActivation, normalHRV.rawActivation)
        XCTAssertLessThanOrEqual(try XCTUnwrap(normalHRV.minuteFact).heartRateWeight, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(normalHRV.minuteFact).heartRateWeight, 0.5)
    }

    func testHROnlyFallbackUsesEntireContinuousScaleAtLowConfidence() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 2, hrvSampleDays: 0)
        let state = AtriaStressMonitor.score(hrNow: 180,
                                             hrWindow: [180, 179, 180],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .scored)
        XCTAssertFalse(state.hrvAvailable)
        XCTAssertEqual(state.detail, "HR-only estimate · lower confidence")
        XCTAssertEqual(state.level, .high)
        XCTAssertEqual(state.confidence,
                       AtriaPhysiologicalStressModel.Confidence.low.numericValue)
        XCTAssertTrue(state.minuteFact?.isHROnly == true)
    }

    /// Superseded 2026-08-19 (field report item 8). v3 deliberately neutered the
    /// awake reference so it "cannot fork v3 scoring", and that invariant was
    /// correct: a versioned kernel must not be silently reinterpreted or
    /// persisted facts stop meaning what they meant when written.
    ///
    /// But neutering it is exactly what made the metric unusable. Measured over
    /// the field device's own 130,480 quiet-awake samples, the whole observed
    /// awake range 65-97 bpm scored 0.60-1.87 and High (>= 2.0) needed >= 100.1
    /// bpm — above the wearer's observed maximum — so High was unreachable by
    /// construction. The HR reserve was 17x wider than their real awake spread.
    ///
    /// So v3 is left untouched and the reference-anchored kernel ships as v4.
    /// The invariant this test defended still holds; it now holds by version
    /// boundary rather than by discarding the reference.
    func testAwakeReferenceForksTheKernelOnlyByVersionBump() {
        XCTAssertEqual(AtriaPhysiologicalStressModel.scoringVersion, 4,
                       "the recalibration must ship as a new version, not edit v3 in place")

        let baseline = makeBaseline(restingMean: 56, restingSD: 3, hrvSampleDays: 0)
        let awake = (center: 85.0, spread: 2.97) // the field device's learned reference

        func activation(hr: Int, awake: (center: Double, spread: Double)?) -> Double {
            AtriaStressMonitor.score(hrNow: hr, hrWindow: [hr, hr, hr], rrWindowMs: [],
                                     hrvFallbackRMSSD: nil, baseline: baseline,
                                     restingMaxHR: restingMaxHR, workoutActive: false,
                                     zoneIndex: 0, inSleepWindow: false, hasContact: true,
                                     contactAgeSeconds: 300, awakeReference: awake, now: now)
                .rawActivation
        }
        // A wearer with no learned reference is scored exactly as before.
        XCTAssertEqual(activation(hr: 85, awake: nil),
                       activation(hr: 85, awake: nil),
                       accuracy: 1e-12)
        // With a reference, the same HR now means something specific to them.
        XCTAssertNotEqual(activation(hr: 85, awake: awake),
                          activation(hr: 85, awake: nil),
                          accuracy: 1e-9)
        // And the zone edges are theirs: center +/- halfWidth. Note
        // `rawActivation` is `fact.score / 3`, so the Calm/Moderate and
        // Moderate/High edges sit at 1/3 and 2/3, not 1 and 2.
        XCTAssertLessThan(activation(hr: 78, awake: awake), 1.0 / 3,
                          "center - halfWidth must be the Calm edge")
        XCTAssertGreaterThanOrEqual(activation(hr: 92, awake: awake), 2.0 / 3,
                                    "center + halfWidth must be the High edge — the whole point of item 8")
    }

    func testAwakeReferenceLearnsRobustMedianOnceWarm() {
        let base = Date(timeIntervalSince1970: 1_786_000_000)
        // 70 samples over 10 min, mostly ~72 bpm with a couple of stray spikes.
        var buffer: [(t: Date, bpm: Int)] = []
        for i in 0..<70 {
            let bpm = (i == 10 || i == 40) ? 150 : 72
            buffer.append((t: base.addingTimeInterval(Double(i) * 9), bpm: bpm))
        }
        let ref = AtriaStressMonitorStore.awakeReference(from: buffer, now: base.addingTimeInterval(700))
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref!.center, 72, accuracy: 0.5, "median ignores the two spikes")

        // Too few samples / too short a span → nil (scorer uses its default).
        let cold = Array(buffer.prefix(10))
        XCTAssertNil(AtriaStressMonitorStore.awakeReference(from: cold, now: base.addingTimeInterval(90)))
    }

    // Persisted awake reference (2026-08-08 §"persist awake reference"): the
    // 45-min buffer takes ~8 min of quiet-awake wear to warm up, so without a
    // seed every cold launch scores the first minutes against the fixed
    // physiological default. Store A learns and persists a reference; a fresh
    // Store B on the same suite must seed from it and score the wearer's own
    // (high-for-most-people) awake HR as Calm on its very first scored tick —
    // before its own buffer can warm — where an unseeded Store C does not.
    @MainActor
    func testAwakeReferencePersistsAndSeedsFreshLaunchBeforeBufferWarms() throws {
        let baseline = makeBaseline(restingMean: 56, restingSD: 3, hrvSampleDays: 0)
        let awakeHR = 85 // this wearer's real awake HR, well above rest (60)

        let suiteName = "atria.stress.awakeref.test.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Store A: warm the awake buffer past its 60-sample / 8-min trust gate so
        // a reference is learned and written to the injected suite.
        let storeA = AtriaStressMonitorStore(defaults: suite)
        for i in 0..<70 {
            storeA.update(heartRate: (i % 2 == 0) ? 84 : 86,
                          hasContact: true,
                          recentRRSamples: [],
                          isRecording: false,
                          zoneIndex: 0,
                          hrvSnapshot: nil,
                          baseline: baseline,
                          restingMaxHR: restingMaxHR,
                          hasActiveSleepEvidence: false,
                          now: now.addingTimeInterval(Double(i) * 9))
        }
        let persisted = try XCTUnwrap(
            AtriaStressMonitorStore.loadPersistedAwakeReference(defaults: suite),
            "a warm awake buffer must persist its learned reference")
        XCTAssertEqual(persisted.center, 85, accuracy: 1.0)

        // Drive a fresh store to its first scored minute fact. As of v4 the
        // restored seed DOES anchor the kernel — that is the point of persisting
        // it, and it is what the 2026-08-08 note above always intended.
        func warmToFirstScoredTick(_ store: AtriaStressMonitorStore) {
            for offset in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
                store.update(heartRate: awakeHR,
                             hasContact: true,
                             recentRRSamples: [],
                             isRecording: false,
                             zoneIndex: 0,
                             hrvSnapshot: nil,
                             baseline: baseline,
                             restingMaxHR: restingMaxHR,
                             hasActiveSleepEvidence: false,
                             now: now.addingTimeInterval(1020 + offset))
            }
        }

        // Store B restores the seed, and still scores through v3.
        let storeB = AtriaStressMonitorStore(defaults: suite)
        warmToFirstScoredTick(storeB)
        XCTAssertEqual(storeB.state.kind, .scored)
        XCTAssertEqual(storeB.state.minuteFact?.scoringVersion,
                       AtriaPhysiologicalStressModel.scoringVersion)

        // Store C: fresh launch on an EMPTY suite -> no seed -> it falls back to
        // the reserve coordinate, so the same 85 bpm scores differently. This is
        // the whole value of persisting the reference: the seeded launch scores
        // the wearer against themselves from its very first tick.
        let emptyName = "atria.stress.awakeref.test.empty.\(UUID().uuidString)"
        let emptySuite = try XCTUnwrap(UserDefaults(suiteName: emptyName))
        defer { emptySuite.removePersistentDomain(forName: emptyName) }
        let storeC = AtriaStressMonitorStore(defaults: emptySuite)
        warmToFirstScoredTick(storeC)
        XCTAssertEqual(storeC.state.kind, .scored)
        XCTAssertNotEqual(storeC.state.rawActivation, storeB.state.rawActivation,
                          accuracy: 1e-9,
                          "a seeded launch must score against the wearer's own reference")
    }

    // A persisted reference older than the seed max-age must be ignored — awake
    // HR drifts with fitness/illness/season, so a stale seed is worse than the
    // default. A ~30-day-old seed for a low-awake-HR profile must NOT drag a
    // genuinely-typical reading; the store falls back to the default instead.
    @MainActor
    func testStaleAwakeReferenceSeedIsIgnored() throws {
        let baseline = makeBaseline(restingMean: 56, restingSD: 3, hrvSampleDays: 0)

        let suiteName = "atria.stress.awakeref.stale.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Hand-write a seed stamped 30 days ago (past the 14-day max-age).
        let stale = AtriaAwakeReferenceSnapshot(center: 120,
                                                spread: 6,
                                                updatedAt: now.addingTimeInterval(-30 * 24 * 3600))
        suite.set(try JSONEncoder().encode(stale), forKey: "atria.stress.awakeReference.v1")

        func score(using defaults: UserDefaults) -> AtriaStressState {
            let store = AtriaStressMonitorStore(defaults: defaults)
            for offset in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
                store.update(heartRate: 85,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                             now: now.addingTimeInterval(offset))
            }
            return store.state
        }
        let staleState = score(using: suite)
        let emptyName = "atria.stress.awakeref.stale.empty.\(UUID().uuidString)"
        let emptySuite = try XCTUnwrap(UserDefaults(suiteName: emptyName))
        defer { emptySuite.removePersistentDomain(forName: emptyName) }
        let emptyState = score(using: emptySuite)
        XCTAssertEqual(staleState.kind, .scored)
        XCTAssertEqual(staleState.rawActivation, emptyState.rawActivation, accuracy: 1e-12)
    }

    @MainActor
    func testHROnlyModePublishesContinuousLowConfidenceV3Fact() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4, hrvSampleDays: 0)
        let store = AtriaStressMonitorStore()

        for offset in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
            store.update(heartRate: 180,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 1,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }

        XCTAssertEqual(store.state.kind, .scored)
        XCTAssertEqual(store.state.level, .high)
        XCTAssertFalse(store.state.hrvAvailable)
        XCTAssertGreaterThan(store.state.rawActivation,
                             AtriaStressMonitor.mediumUpperBound)
        XCTAssertEqual(store.state.confidence,
                       AtriaPhysiologicalStressModel.Confidence.low.numericValue)

        // The separately queryable persisted point carries the same bounded value.
        guard let recorded = store.history.last else {
            return XCTFail("a scored tick must record a history point")
        }
        XCTAssertEqual(recorded.activation, store.state.rawActivation, accuracy: 1e-12)
        XCTAssertEqual(recorded.minuteFact?.scoringVersion,
                       AtriaPhysiologicalStressModel.scoringVersion)
        XCTAssertEqual(recorded.evidenceMode, .physiologicalStress)
        XCTAssertNotNil(recorded.evidenceProjection.numericStressScore)
        XCTAssertNil(recorded.evidenceProjection.cardiacArousalValue)
    }

    @MainActor
    func testHROnlyToFullEvidenceTransitionUsesSameV3EMAState() throws {
        let baseline = makeBaseline(restingMean: 60,
                                    restingSD: 4,
                                    lnRMSSDMean: log(100),
                                    lnRMSSDSD: 0.15,
                                    hrvSampleDays: 20)
        let store = AtriaStressMonitorStore()

        for offset in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
            store.update(heartRate: 98,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 1,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }
        XCTAssertEqual(store.state.evidenceMode, .physiologicalStress)
        let previous = try XCTUnwrap(store.state.minuteFact)

        let fullEvidenceAt = now.addingTimeInterval(360)
        store.update(heartRate: 98,
                     hasContact: true,
                     recentRRSamples: qualifiedRRSamples(endingAt: fullEvidenceAt),
                     isRecording: false,
                     zoneIndex: 1,
                     hrvSnapshot: nil,
                     baseline: baseline,
                     restingMaxHR: restingMaxHR,
                     hasActiveSleepEvidence: false,
                     now: fullEvidenceAt)

        XCTAssertEqual(store.state.evidenceMode, .physiologicalStress)
        let current = try XCTUnwrap(store.state.minuteFact)
        let alpha = 1 - exp(-log(2.0) / 3.0)
        XCTAssertEqual(current.score,
                       previous.score + alpha * (current.unsmoothedScore - previous.score),
                       accuracy: 1e-12,
                       "evidence availability does not fork the v3 smoothing kernel")
    }

    @MainActor
    func testFullEvidenceExpiresToHROnlyWithoutFabricatingFreshRR() throws {
        let baseline = makeBaseline(restingMean: 60,
                                    restingSD: 4,
                                    lnRMSSDMean: log(100),
                                    lnRMSSDSD: 0.15,
                                    hrvSampleDays: 20)
        let store = AtriaStressMonitorStore()

        for offset in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
            let tick = now.addingTimeInterval(offset)
            store.update(heartRate: 98,
                         hasContact: true,
                         recentRRSamples: qualifiedRRSamples(endingAt: tick),
                         isRecording: false,
                         zoneIndex: 1,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: tick)
        }
        XCTAssertEqual(store.state.evidenceMode, .physiologicalStress)

        for offset in stride(from: 360.0, through: 660.0, by: 60.0) {
            store.update(heartRate: 98,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 1,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }

        XCTAssertEqual(store.state.evidenceMode, .physiologicalStress)
        XCTAssertTrue(try XCTUnwrap(store.state.minuteFact).isHROnly)
        XCTAssertNotNil(store.state.evidenceProjection?.numericStressScore)
    }

    @MainActor
    func testDailyStressDistributionIncludesCompleteHROnlyFactsWithProvenance() throws {
        let suiteName = "atria.stress.mode-distribution.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let baseline = makeBaseline(restingMean: 60,
                                    restingSD: 4,
                                    lnRMSSDMean: log(100),
                                    lnRMSSDSD: 0.15,
                                    hrvSampleDays: 20)
        let store = AtriaStressMonitorStore(defaults: suite)

        for offset in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
            store.update(heartRate: 98,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 1,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }

        let hrOnlyComparison = try XCTUnwrap(
            store.distributionComparison(now: now.addingTimeInterval(300))
        )
        XCTAssertEqual(hrOnlyComparison.today.sampleCount, 1)
        XCTAssertEqual(store.history.last?.evidenceMode, .physiologicalStress)
        XCTAssertTrue(store.history.last?.minuteFact?.isHROnly == true)

        let fullEvidenceAt = now.addingTimeInterval(360)
        store.update(heartRate: 98,
                     hasContact: true,
                     recentRRSamples: qualifiedRRSamples(endingAt: fullEvidenceAt),
                     isRecording: false,
                     zoneIndex: 1,
                     hrvSnapshot: nil,
                     baseline: baseline,
                     restingMaxHR: restingMaxHR,
                     hasActiveSleepEvidence: false,
                     now: fullEvidenceAt)

        let comparison = try XCTUnwrap(store.distributionComparison(now: fullEvidenceAt))
        XCTAssertEqual(comparison.today.sampleCount, 2)
        XCTAssertEqual(store.history.map(\.evidenceMode),
                       [.physiologicalStress, .physiologicalStress])
    }

    func testHistoricalFramingUsesExactFiveMinuteWindowsAndMatchesSharedBatchKernel() {
        let end = now.addingTimeInterval(600)
        let heartRates = historicalHeartRates(endingAt: end)
        let snapshot = AtriaHistoricalStressReplay.Snapshot(
            sessions: [
                .init(id: UUID(),
                      start: end.addingTimeInterval(-420),
                      end: end,
                      heartRates: heartRates,
                      rrIntervals: []),
            ],
            personalization: historicalPersonalization,
            now: end
        )

        let replay = AtriaHistoricalStressReplay.evaluate(snapshot)
        let expectedEnds = [end.addingTimeInterval(-120),
                            end.addingTimeInterval(-60),
                            end]
        let batchInputs = expectedEnds.map { windowEnd in
            AtriaPhysiologicalStressModel.WindowInput(
                end: windowEnd,
                heartRates: heartRates.filter {
                    $0.date >= windowEnd.addingTimeInterval(-300)
                        && $0.date <= windowEnd
                }.map {
                    .init(date: $0.date, bpm: $0.bpm)
                },
                rrIntervals: [],
                personalization: historicalPersonalization
            )
        }

        XCTAssertEqual(replay.facts,
                       AtriaPhysiologicalStressModel.evaluate(batchInputs),
                       "historical framing must use the exact live v3 kernel")
        XCTAssertEqual(replay.facts.map(\.date), expectedEnds)
        XCTAssertTrue(zip(replay.facts, replay.facts.dropFirst()).allSatisfy { pair in
            pair.1.date.timeIntervalSince(pair.0.date)
                == AtriaPhysiologicalStressModel.evaluationCadence
        })
    }

    func testReplayAuthorityTracksCardiacCalibrationAndContextIndependently() throws {
        let end = now.addingTimeInterval(600)
        let session = AtriaHistoricalStressReplay.Session(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000077")!,
            start: end.addingTimeInterval(-420),
            end: end,
            heartRates: historicalHeartRates(endingAt: end),
            rrIntervals: []
        )
        let baseSnapshot = AtriaHistoricalStressReplay.Snapshot(
            sessions: [session],
            personalization: historicalPersonalization,
            now: end
        )
        let contextSnapshot = AtriaHistoricalStressReplay.Snapshot(
            sessions: [session],
            activityContexts: [
                .init(start: end.addingTimeInterval(-420),
                      end: end,
                      intensity: 0.8),
            ],
            personalization: historicalPersonalization,
            now: end
        )
        let recalibratedSnapshot = AtriaHistoricalStressReplay.Snapshot(
            sessions: [session],
            personalization: .init(restingHeartRate: 54,
                                   maximumHeartRate: 188,
                                   restingBaselineDayCount: 22,
                                   hrvBaseline: historicalPersonalization.hrvBaseline),
            now: end
        )

        let base = AtriaHistoricalStressReplay.evaluate(baseSnapshot)
        XCTAssertEqual(base, AtriaHistoricalStressReplay.evaluate(baseSnapshot),
                       "authority fingerprints must be deterministic")
        let withContext = AtriaHistoricalStressReplay.evaluate(contextSnapshot)
        let recalibrated = AtriaHistoricalStressReplay.evaluate(recalibratedSnapshot)
        let date = try XCTUnwrap(base.facts.last?.date)
        let baseAuthority = try XCTUnwrap(base.authorityByDate[date])
        let contextAuthority = try XCTUnwrap(withContext.authorityByDate[date])
        let calibrationAuthority = try XCTUnwrap(recalibrated.authorityByDate[date])

        XCTAssertEqual(baseAuthority.cardiacInputRevision,
                       contextAuthority.cardiacInputRevision)
        XCTAssertEqual(baseAuthority.calibrationRevision,
                       contextAuthority.calibrationRevision)
        XCTAssertNotEqual(baseAuthority.contextRevision,
                          contextAuthority.contextRevision)
        XCTAssertEqual(baseAuthority.cardiacInputRevision,
                       calibrationAuthority.cardiacInputRevision)
        XCTAssertNotEqual(baseAuthority.calibrationRevision,
                          calibrationAuthority.calibrationRevision)
        XCTAssertEqual(baseAuthority.contextRevision,
                       calibrationAuthority.contextRevision)
    }

    func testHistoricalStandardRRUsesSharedQualityGateWhileV24RemainsHROnly() throws {
        let end = now.addingTimeInterval(1_200)
        let heartRates = historicalHeartRates(endingAt: end)
        func replay(source: AtriaRRSourceProvenance)
            -> AtriaHistoricalStressReplay.Result {
            AtriaHistoricalStressReplay.evaluate(
                .init(
                    sessions: [
                        .init(id: UUID(),
                              start: end.addingTimeInterval(-420),
                              end: end,
                              heartRates: heartRates,
                              rrIntervals: historicalRR(endingAt: end,
                                                        source: source)),
                    ],
                    personalization: historicalPersonalization,
                    now: end
                )
            )
        }

        let standard = try XCTUnwrap(
            replay(source: .standardHeartRateMeasurement2A37).facts.last
        )
        let historicalV24 = try XCTUnwrap(
            replay(source: .verifiedWhoop4HistoricalV24).facts.last
        )
        XCTAssertFalse(standard.isHROnly,
                       "qualified standard RR may contribute after the shared gate")
        XCTAssertNotNil(standard.rmssd)
        XCTAssertTrue(historicalV24.isHROnly,
                      "v24 provenance must not be promoted to standard live RR")
        XCTAssertNil(historicalV24.rmssd)
        XCTAssertEqual(historicalV24.confidence, .low)
    }

    @MainActor
    func testHistoricalStorageSnapshotDefersScalarRowMaterializationOffMainActor() async throws {
        let end = now.addingTimeInterval(1_800)
        let start = end.addingTimeInterval(-420)
        var session = SavedSession(
            id: UUID(),
            start: start,
            end: end,
            label: "Recovered strap history",
            points: stride(from: 0.0, through: 420.0, by: 30.0).map {
                .init(t: $0, bpm: 92)
            }
        )
        session.rrPoints = stride(from: 0.0, through: 420.0, by: 1.0).map {
            .init(t: $0,
                  ms: 800,
                  source: .standardHeartRateMeasurement2A37)
        }
        session.recoveredMotionEpochs = [
            .init(start: end.addingTimeInterval(-300),
                  end: end,
                  rows: 300,
                  validatedRows: 300,
                  stillnessRatio: 0.1,
                  movementIntensity: 0.9,
                  p95VectorDelta: 0.8,
                  maximumGapSeconds: 1,
                  measurementValidated: true,
                  lowMotionQualified: false,
                  reason: "qualified recovered activity"),
            .init(start: end.addingTimeInterval(-300),
                  end: end,
                  rows: 300,
                  validatedRows: 0,
                  stillnessRatio: 0.1,
                  movementIntensity: 1,
                  p95VectorDelta: 0.9,
                  maximumGapSeconds: 1,
                  measurementValidated: false,
                  lowMotionQualified: false,
                  reason: "unvalidated motion must stay unavailable"),
            .init(start: end.addingTimeInterval(-300),
                  end: end,
                  rows: 300,
                  validatedRows: 300,
                  stillnessRatio: 0.99,
                  movementIntensity: 0.01,
                  p95VectorDelta: 0.01,
                  maximumGapSeconds: 1,
                  measurementValidated: true,
                  lowMotionQualified: true,
                  reason: "validated stillness is not activity"),
            .init(start: end.addingTimeInterval(-300),
                  end: end,
                  rows: 300,
                  validatedRows: 300,
                  stillnessRatio: 0.99,
                  movementIntensity: 0.01,
                  p95VectorDelta: 0.01,
                  maximumGapSeconds: 1,
                  measurementValidated: true,
                  lowMotionQualified: false,
                  reason: "not-sleep-qualified alone is not activity authority"),
        ]
        func sleep(id: String,
                   source: String,
                   confidence: String,
                   motionValidated: Bool) -> UserConfirmedSleep {
            let sleepStart = end.addingTimeInterval(-4 * 3_600)
            return UserConfirmedSleep(
                id: id,
                createdAt: end,
                start: sleepStart,
                end: end,
                source: source,
                confidence: confidence,
                sessions: 1,
                samples: 480,
                avgHR: 56,
                peakHR: 68,
                restingHR: 52,
                hrv: nil,
                hrvWindowCount: nil,
                respiratoryRate: nil,
                duration: end.timeIntervalSince(sleepStart),
                span: end.timeIntervalSince(sleepStart),
                reason: "historical context fixture",
                motionSource: motionValidated ? "validated" : "none",
                motionValidated: motionValidated,
                stageSegments: nil
            )
        }
        let qualifiedSleep = sleep(id: "manual-qualified",
                                   source: "manual_sleep",
                                   confidence: "user_confirmed_manual",
                                   motionValidated: false)
        let unqualifiedSleep = sleep(id: "inferred-only",
                                     source: "automatic_sleep",
                                     confidence: "low",
                                     motionValidated: false)

        let storage = try XCTUnwrap(AtriaHistoricalStressReplay.snapshot(
            sessions: [session],
            confirmedSleeps: [qualifiedSleep, unqualifiedSleep],
            personalization: historicalPersonalization,
            now: end
        ))
        XCTAssertEqual(storage.sessions.count, 1)

        let scalar = await Task.detached(priority: .utility) {
            AtriaHistoricalStressReplay.materialize(storage)
        }.value
        let materialized = try XCTUnwrap(scalar)
        XCTAssertEqual(materialized.heartRateRowCount, session.points.count)
        XCTAssertEqual(materialized.rrRowCount, session.rrPoints?.count ?? 0)
        XCTAssertEqual(materialized.activityContexts, [
            .init(start: end.addingTimeInterval(-300),
                  end: end,
                  intensity: 0.9),
        ])
        XCTAssertEqual(materialized.sleepContexts, [
            .init(start: qualifiedSleep.start, end: qualifiedSleep.end),
        ])

        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaStressMonitor.swift"),
            encoding: .utf8
        )
        let snapshotStart = try XCTUnwrap(
            source.range(of: "@MainActor\n    static func snapshot")
        ).lowerBound
        let materializeStart = try XCTUnwrap(
            source.range(of: "    static func materialize(",
                         range: snapshotStart..<source.endIndex)
        ).lowerBound
        let mainActorSnapshotBody = String(source[snapshotStart..<materializeStart])
        XCTAssertFalse(mainActorSnapshotBody.contains("for point in session.points"))
        XCTAssertFalse(mainActorSnapshotBody.contains("heartRates.append"))
        XCTAssertFalse(mainActorSnapshotBody.contains("rrIntervals.append"))
        let detachedMaterializer = String(source[materializeStart...])
        XCTAssertTrue(detachedMaterializer.contains("for point in session.points"))
        XCTAssertTrue(detachedMaterializer.contains("heartRates.append"))
        XCTAssertTrue(detachedMaterializer.contains("rrIntervals.append"))
    }

    func testHistoricalFactsRequireQualifiedActivityAndSleepAuthority() throws {
        let end = now.addingTimeInterval(2_400)
        let session = AtriaHistoricalStressReplay.Session(
            id: UUID(),
            start: end.addingTimeInterval(-420),
            end: end,
            heartRates: historicalHeartRates(endingAt: end, bpm: 135),
            rrIntervals: []
        )
        func replay(
            activity: AtriaHistoricalStressReplay.ActivityContextInterval? = nil,
            sleep: AtriaHistoricalStressReplay.SleepContextInterval? = nil
        ) throws -> AtriaPhysiologicalStressModel.MinuteFact {
            let result = AtriaHistoricalStressReplay.evaluate(
                .init(sessions: [session],
                      activityContexts: activity.map { [$0] } ?? [],
                      sleepContexts: sleep.map { [$0] } ?? [],
                      personalization: historicalPersonalization,
                      now: end)
            )
            return try XCTUnwrap(result.facts.last)
        }
        let contextStart = end.addingTimeInterval(-300)
        let noContext = try replay()
        let unqualifiedActivity = try replay(activity: .init(
            start: contextStart,
            end: end,
            intensity: 1,
            qualified: false
        ))
        let qualifiedActivity = try replay(activity: .init(
            start: contextStart,
            end: end,
            intensity: 1
        ))
        let unqualifiedSleep = try replay(sleep: .init(
            start: contextStart,
            end: end,
            qualified: false
        ))
        let qualifiedSleep = try replay(sleep: .init(
            start: contextStart,
            end: end
        ))

        XCTAssertEqual(noContext.motionContext, .unavailable)
        XCTAssertEqual(unqualifiedActivity.motionContext, .unavailable)
        XCTAssertEqual(unqualifiedActivity.score, noContext.score, accuracy: 1e-12)
        XCTAssertEqual(qualifiedActivity.motionContext,
                       .qualifiedActivity(intensity: 1))
        XCTAssertLessThan(qualifiedActivity.score, noContext.score,
                          "only qualified activity may attenuate exercise elevation")
        XCTAssertEqual(unqualifiedSleep.sleepContext, .unavailable)
        XCTAssertEqual(qualifiedSleep.sleepContext, .asleep)

        func chartReading(
            from fact: AtriaPhysiologicalStressModel.MinuteFact
        ) -> AtriaStressDetailReading {
            AtriaStressDetailReading(historyPoint: .init(
                t: fact.date,
                activation: fact.score / 3,
                level: fact.zone == .calm
                    ? .calm : (fact.zone == .moderate ? .medium : .high),
                confidence: fact.confidence.numericValue,
                hrvAvailable: !fact.isHROnly,
                minuteFact: fact
            ))
        }
        XCTAssertEqual(chartReading(from: qualifiedActivity).motionContext,
                       .qualifiedActivity(intensity: 1),
                       "historical activity authority must survive into chart overlays")
        XCTAssertEqual(chartReading(from: qualifiedSleep).sleepContext, .asleep,
                       "historical sleep authority must survive into chart overlays")
    }

    func testStressHistoryDurabilityLedgerIsRevisionSafeAcrossOverlappingWriters() {
        let firstMinute = now
        let secondMinute = now.addingTimeInterval(60)
        var ledger = AtriaStressHistoryDurabilityLedger()
        ledger.markDirty(firstMinute)
        let checkpoint = ledger.submission(for: [firstMinute])
        let fullSave = ledger.submission(for: [firstMinute])

        // A replacement at the same timestamp and a new minute arrive while
        // both writers still hold the older fact revision.
        ledger.markDirty(firstMinute)
        ledger.markDirty(secondMinute)
        XCTAssertEqual(ledger.complete(fullSave, succeeded: true), 0)
        XCTAssertEqual(ledger.complete(checkpoint, succeeded: true), 0)
        XCTAssertEqual(ledger.dirtyCount, 2)
        XCTAssertTrue(ledger.isDirty(firstMinute))
        XCTAssertTrue(ledger.isDirty(secondMinute))

        let currentFullSave = ledger.submission(for: [firstMinute, secondMinute])
        XCTAssertEqual(ledger.complete(currentFullSave, succeeded: false), 0)
        XCTAssertEqual(ledger.dirtyCount, 2,
                       "a failed writer must never declare facts durable")
        XCTAssertEqual(ledger.complete(currentFullSave, succeeded: true), 2)
        XCTAssertTrue(ledger.isEmpty)

        // Overlapping successful submissions clear each exact revision once,
        // regardless of completion order.
        ledger.markDirty(firstMinute)
        ledger.markDirty(secondMinute)
        let overlappingCheckpoint = ledger.submission(for: [firstMinute])
        let overlappingFullSave = ledger.submission(for: [firstMinute, secondMinute])
        XCTAssertEqual(ledger.complete(overlappingCheckpoint, succeeded: true), 1)
        XCTAssertEqual(ledger.complete(overlappingFullSave, succeeded: true), 1)
        XCTAssertTrue(ledger.isEmpty)
    }

    @MainActor
    func testQualifiedReplayEnrichesPriorReplayWithoutRegressingCardiacAuthority() async throws {
        let date = now.addingTimeInterval(-60)
        func fact(score: Double,
                  motion: AtriaPhysiologicalStressModel.MotionContext,
                  includeHRV: Bool) -> AtriaPhysiologicalStressModel.MinuteFact {
            .init(date: date,
                  score: score,
                  unsmoothedScore: score,
                  meanHeartRate: 132,
                  rmssd: includeHRV ? 42 : nil,
                  hrStress: 0.82,
                  hrvStress: includeHRV ? 0.74 : nil,
                  heartRateWeight: includeHRV ? 0.62 : 1,
                  motionContext: motion,
                  sleepContext: .unavailable,
                  confidence: includeHRV ? .high : .low,
                  baselineLearning: false)
        }
        func replay(_ fact: AtriaPhysiologicalStressModel.MinuteFact)
            -> AtriaHistoricalStressReplay.Result {
            .init(facts: [fact], heartRates: [.init(date: date, bpm: 132)])
        }

        let store = AtriaStressMonitorStore()
        let preConfirmation = fact(score: 2.5,
                                   motion: .unavailable,
                                   includeHRV: true)
        await store.mergeHistoricalMinuteFacts(replay(preConfirmation), now: now)
        XCTAssertEqual(try XCTUnwrap(store.history.last).factSource,
                       .historicalReplay)

        let lowerAuthorityCandidate = fact(
            score: 1.6,
            motion: .qualifiedActivity(intensity: 0.9),
            includeHRV: false
        )
        await store.mergeHistoricalMinuteFacts(replay(lowerAuthorityCandidate), now: now)
        XCTAssertEqual(try XCTUnwrap(store.history.last).minuteFact,
                       preConfirmation,
                       "qualified context cannot erase already-qualified RR authority")

        let qualifiedEnrichment = fact(
            score: 1.6,
            motion: .qualifiedActivity(intensity: 0.9),
            includeHRV: true
        )
        await store.mergeHistoricalMinuteFacts(replay(qualifiedEnrichment), now: now)
        let enriched = try XCTUnwrap(store.history.last)
        XCTAssertEqual(enriched.factSource, .historicalReplay)
        XCTAssertEqual(enriched.minuteFact, qualifiedEnrichment)
        XCTAssertEqual(enriched.activation, qualifiedEnrichment.score / 3,
                       accuracy: 1e-12)

        let contextRegression = fact(score: 2.5,
                                     motion: .unavailable,
                                     includeHRV: true)
        await store.mergeHistoricalMinuteFacts(replay(contextRegression), now: now)
        XCTAssertEqual(try XCTUnwrap(store.history.last).minuteFact,
                       qualifiedEnrichment,
                       "a later replay cannot remove qualified context authority")
    }

    @MainActor
    func testCurrentContextRevisionRemovesDeletedAndShrunkReplayOverlays() async throws {
        let firstDate = now.addingTimeInterval(-120)
        let secondDate = now.addingTimeInterval(-60)
        let firstCardiac = "v1:0000000000000011"
        let secondCardiac = "v1:0000000000000012"
        let calibration = "v1:0000000000000021"
        let originalContext = "v1:0000000000000031"
        let shrunkContext = "v1:0000000000000032"
        let deletedContext = "v1:0000000000000033"
        let activity = AtriaPhysiologicalStressModel.MotionContext
            .qualifiedActivity(intensity: 0.8)

        let store = AtriaStressMonitorStore()
        let original = [
            replayFact(at: firstDate, score: 1.5, motion: activity,
                       confidence: .high),
            replayFact(at: secondDate, score: 1.6, motion: activity,
                       confidence: .high),
        ]
        await store.mergeHistoricalMinuteFacts(
            replayResult(original, authorities: [
                replayAuthority(cardiac: firstCardiac,
                                calibration: calibration,
                                context: originalContext),
                replayAuthority(cardiac: secondCardiac,
                                calibration: calibration,
                                context: originalContext),
            ]),
            now: now
        )

        let shrunk = [
            replayFact(at: firstDate, score: 2.4, motion: .unavailable,
                       confidence: .medium),
            replayFact(at: secondDate, score: 1.6, motion: activity,
                       confidence: .high),
        ]
        await store.mergeHistoricalMinuteFacts(
            replayResult(shrunk, authorities: [
                replayAuthority(cardiac: firstCardiac,
                                calibration: calibration,
                                context: shrunkContext),
                replayAuthority(cardiac: secondCardiac,
                                calibration: calibration,
                                context: shrunkContext),
            ]),
            now: now
        )
        XCTAssertEqual(store.history.compactMap(\.minuteFact), shrunk)
        XCTAssertEqual(store.history.first?.minuteFact?.motionContext, .unavailable,
                       "tightening the confirmed boundary must remove the old overlay")

        let deleted = [
            replayFact(at: firstDate, score: 2.4, motion: .unavailable,
                       confidence: .medium),
            replayFact(at: secondDate, score: 2.5, motion: .unavailable,
                       confidence: .medium),
        ]
        await store.mergeHistoricalMinuteFacts(
            replayResult(deleted, authorities: [
                replayAuthority(cardiac: firstCardiac,
                                calibration: calibration,
                                context: deletedContext),
                replayAuthority(cardiac: secondCardiac,
                                calibration: calibration,
                                context: deletedContext),
            ]),
            now: now
        )
        XCTAssertEqual(store.history.compactMap(\.minuteFact), deleted)
        XCTAssertTrue(store.history.allSatisfy {
            $0.minuteFact?.motionContext == .unavailable
        }, "deleting confirmed authority must remove every replay-origin overlay")
    }

    @MainActor
    func testCurrentCalibrationRevisionRecomputesReplayFromSameCardiacInput() async throws {
        let date = now.addingTimeInterval(-60)
        let cardiac = "v1:0000000000000041"
        let oldCalibration = "v1:0000000000000042"
        let newCalibration = "v1:0000000000000043"
        let oldFact = replayFact(at: date,
                                 score: 1.3,
                                 hrStress: 0.55,
                                 hrvStress: 0.45,
                                 heartRateWeight: 0.72,
                                 confidence: .medium)
        let recalibrated = replayFact(at: date,
                                      score: 2.2,
                                      hrStress: 0.78,
                                      hrvStress: 0.67,
                                      heartRateWeight: 0.58,
                                      sleep: .asleep,
                                      confidence: .high)
        let store = AtriaStressMonitorStore()
        await store.mergeHistoricalMinuteFacts(
            replayResult([oldFact], authorities: [
                replayAuthority(cardiac: cardiac,
                                calibration: oldCalibration,
                                context: "v1:0000000000000044"),
            ]),
            now: now
        )
        await store.mergeHistoricalMinuteFacts(
            replayResult([recalibrated], authorities: [
                replayAuthority(cardiac: cardiac,
                                calibration: newCalibration,
                                context: "v1:0000000000000045"),
            ]),
            now: now
        )

        XCTAssertEqual(try XCTUnwrap(store.history.last?.minuteFact), recalibrated,
                       "confirmed-sleep baseline changes must fully recompute replay facts")
    }

    @MainActor
    func testMotionConfidenceCannotAuthorizeUnrelatedCardiacMutation() async throws {
        let date = now.addingTimeInterval(-60)
        let authority = replayAuthority(cardiac: "v1:0000000000000051",
                                        calibration: "v1:0000000000000052",
                                        context: "v1:0000000000000053")
        let original = replayFact(at: date,
                                  score: 2.3,
                                  rmssd: 42,
                                  hrvStress: 0.74,
                                  motion: .unavailable,
                                  confidence: .medium)
        let unrelatedMutation = replayFact(
            at: date,
            score: 1.5,
            rmssd: 58,
            hrvStress: 0.51,
            motion: .qualifiedActivity(intensity: 0.9),
            confidence: .high
        )
        let store = AtriaStressMonitorStore()
        await store.mergeHistoricalMinuteFacts(
            replayResult([original], authorities: [authority]),
            now: now
        )
        await store.mergeHistoricalMinuteFacts(
            replayResult([unrelatedMutation], authorities: [
                replayAuthority(cardiac: authority.cardiacInputRevision,
                                calibration: authority.calibrationRevision,
                                context: "v1:0000000000000054"),
            ]),
            now: now
        )

        XCTAssertEqual(try XCTUnwrap(store.history.last?.minuteFact), original,
                       "motion-driven confidence cannot mutate RMSSD/HRV stress")
    }

    @MainActor
    func testSimultaneousCardiacCalibrationAndContextRevisionConvergesAtomically() async throws {
        let date = now.addingTimeInterval(-60)
        let original = replayFact(
            at: date,
            score: 2.4,
            meanHeartRate: 132,
            rmssd: nil,
            hrvStress: nil,
            heartRateWeight: 1,
            motion: .qualifiedActivity(intensity: 0.8),
            sleep: .asleep,
            confidence: .low,
            baselineLearning: true
        )
        let currentReplay = replayFact(
            at: date,
            score: 1.7,
            meanHeartRate: 134,
            rmssd: 56,
            hrStress: 0.77,
            hrvStress: 0.48,
            heartRateWeight: 0.58,
            motion: .unavailable,
            sleep: .unavailable,
            confidence: .medium,
            baselineLearning: false
        )
        let originalAuthority = replayAuthority(
            cardiac: "v1:0000000000000061",
            calibration: "v1:0000000000000062",
            context: "v1:0000000000000063"
        )
        let currentAuthority = replayAuthority(
            cardiac: "v1:0000000000000064",
            calibration: "v1:0000000000000065",
            context: "v1:0000000000000066"
        )
        let store = AtriaStressMonitorStore()
        await store.mergeHistoricalMinuteFacts(
            replayResult([original], authorities: [originalAuthority]),
            now: now
        )
        await store.mergeHistoricalMinuteFacts(
            replayResult([currentReplay], authorities: [currentAuthority]),
            now: now
        )

        XCTAssertEqual(try XCTUnwrap(store.history.last?.minuteFact), currentReplay)
        XCTAssertEqual(store.history.last?.replayAuthority, currentAuthority)
        let convergedRevision = store.historyRevision
        await store.mergeHistoricalMinuteFacts(
            replayResult([currentReplay], authorities: [currentAuthority]),
            now: now
        )
        XCTAssertEqual(store.historyRevision, convergedRevision,
                       "an identical current replay must remain idempotent after convergence")
    }

    @MainActor
    func testChangedCardiacRowsCanRemoveDeletedContextInSameReplay() async throws {
        let date = now.addingTimeInterval(-60)
        let calibration = "v1:0000000000000071"
        let original = replayFact(
            at: date,
            score: 1.4,
            meanHeartRate: 128,
            rmssd: 44,
            hrvStress: 0.70,
            motion: .qualifiedActivity(intensity: 0.9),
            sleep: .asleep,
            confidence: .high
        )
        let afterDelete = replayFact(
            at: date,
            score: 2.5,
            meanHeartRate: 129,
            rmssd: 43,
            hrvStress: 0.72,
            motion: .unavailable,
            sleep: .unavailable,
            confidence: .medium
        )
        let store = AtriaStressMonitorStore()
        await store.mergeHistoricalMinuteFacts(
            replayResult([original], authorities: [
                replayAuthority(cardiac: "v1:0000000000000072",
                                calibration: calibration,
                                context: "v1:0000000000000073"),
            ]),
            now: now
        )
        await store.mergeHistoricalMinuteFacts(
            replayResult([afterDelete], authorities: [
                replayAuthority(cardiac: "v1:0000000000000074",
                                calibration: calibration,
                                context: "v1:0000000000000075"),
            ]),
            now: now
        )

        let merged = try XCTUnwrap(store.history.last?.minuteFact)
        XCTAssertEqual(merged, afterDelete)
        XCTAssertEqual(merged.motionContext, .unavailable)
        XCTAssertEqual(merged.sleepContext, .unavailable)
    }

    @MainActor
    func testAuthoritativeManagedRangeDeletesShrunkAndRemovedReplayGaps() async throws {
        let firstDate = now.addingTimeInterval(-180)
        let removedDate = now.addingTimeInterval(-120)
        let finalDate = now.addingTimeInterval(-60)
        let managed = AtriaHistoricalStressReplay.ManagedRange(
            start: firstDate.addingTimeInterval(-60),
            end: now
        )
        let original = [
            replayFact(at: firstDate, score: 1.2),
            replayFact(at: removedDate, score: 1.5),
            replayFact(at: finalDate, score: 1.8),
        ]
        let authorities = [
            replayAuthority(cardiac: "v1:0000000000000081"),
            replayAuthority(cardiac: "v1:0000000000000082"),
            replayAuthority(cardiac: "v1:0000000000000083"),
        ]
        let store = AtriaStressMonitorStore()
        await store.mergeHistoricalMinuteFacts(
            replayResult(original,
                         authorities: authorities,
                         managedRanges: [managed]),
            now: now
        )
        XCTAssertEqual(store.history.map(\.t), [firstDate, removedDate, finalDate])
        XCTAssertEqual(store.heartRateHistory.map(\.t),
                       [firstDate, removedDate, finalDate])

        let shrunkFacts = [original[0], original[2]]
        await store.mergeHistoricalMinuteFacts(
            replayResult(shrunkFacts,
                         authorities: [authorities[0], authorities[2]],
                         managedRanges: [managed]),
            now: now
        )
        XCTAssertEqual(store.history.map(\.t), [firstDate, finalDate],
                       "an absent minute inside the managed source becomes a real graph gap")
        XCTAssertEqual(store.heartRateHistory.map(\.t), [firstDate, finalDate],
                       "the matching replay-owned HR observation must also disappear")

        let emptyFullReplay = AtriaHistoricalStressReplay.evaluate(
            .init(sessions: [],
                  personalization: historicalPersonalization,
                  now: now)
        )
        XCTAssertEqual(emptyFullReplay.managedRanges.count, 1,
                       "a validated empty source carries deletion authority")
        await store.mergeHistoricalMinuteFacts(emptyFullReplay, now: now)
        XCTAssertTrue(store.history.isEmpty,
                      "deleting the authoritative session removes its replay facts")
        XCTAssertTrue(store.heartRateHistory.isEmpty,
                      "deleting the authoritative session removes its replay HR")
    }

    @MainActor
    func testAuthoritativeEmptyReplayPreservesGenuineLiveFactAndHeartRate() async throws {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4,
                                    hrvSampleDays: 0)
        let store = AtriaStressMonitorStore()
        for offset in [-300.0, -240.0, -180.0, -120.0, -60.0, 0.0] {
            store.update(heartRate: 75,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         now: now.addingTimeInterval(offset))
        }
        let liveFact = try XCTUnwrap(store.history.last)
        let liveHeartRate = try XCTUnwrap(store.heartRateHistory.last)
        XCTAssertEqual(liveFact.factSource, .live)
        XCTAssertEqual(liveHeartRate.factSource, .live)

        await store.mergeHistoricalMinuteFacts(
            .init(facts: [],
                  heartRates: [],
                  managedRanges: [.init(start: now.addingTimeInterval(-60),
                                        end: now)]),
            now: now
        )
        XCTAssertEqual(store.history.last, liveFact)
        XCTAssertEqual(store.heartRateHistory.last, liveHeartRate)
    }

    @MainActor
    func testMalformedFullReplayCannotClaimManagedDeletionAuthority() async throws {
        let date = now.addingTimeInterval(-60)
        let original = replayFact(at: date, score: 1.4)
        let store = AtriaStressMonitorStore()
        await store.mergeHistoricalMinuteFacts(
            replayResult(
                [original],
                authorities: [replayAuthority(
                    cardiac: "v1:0000000000000091"
                )],
                managedRanges: [.init(
                    start: date.addingTimeInterval(-60),
                    end: now
                )]
            ),
            now: now
        )

        let malformed = AtriaHistoricalStressReplay.evaluate(
            .init(
                sessions: [.init(
                    id: UUID(),
                    start: date.addingTimeInterval(-300),
                    end: date,
                    heartRates: [
                        .init(date: date, bpm: 75),
                        .init(date: date.addingTimeInterval(-30), bpm: 75),
                    ],
                    rrIntervals: []
                )],
                personalization: historicalPersonalization,
                now: now
            )
        )
        XCTAssertTrue(malformed.managedRanges.isEmpty,
                      "malformed source input must fail non-destructively")
        await store.mergeHistoricalMinuteFacts(malformed, now: now)
        XCTAssertEqual(store.history.map(\.t), [date])
        XCTAssertEqual(store.heartRateHistory.map(\.t), [date])
    }

    func testCalibrationPublicationGateTracksExactV3FieldsAndDefersRecoveredIntermediate() {
        func fingerprint(rest: Double = 60,
                         maximum: Double = 190,
                         restingDays: Int = 20,
                         median: Double? = log(80),
                         scale: Double = 0.2,
                         hrvDays: Int = 20)
            -> AtriaHistoricalStressCalibrationFingerprint {
            let hrv = median.map {
                AtriaPhysiologicalStressModel.HRVBaseline(
                    medianLnRMSSD: $0,
                    robustScale: scale,
                    qualifiedDayCount: hrvDays
                )
            }
            return AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: rest,
                      maximumHeartRate: maximum,
                      restingBaselineDayCount: restingDays,
                      hrvBaseline: hrv)
            )
        }

        var gate = AtriaHistoricalStressCalibrationPublicationGate()
        let initial = fingerprint()
        XCTAssertFalse(gate.accepts(initial, publicationDeferred: false),
                       "the initial Combine publication only seeds dedup state")
        XCTAssertFalse(gate.accepts(initial, publicationDeferred: false))
        XCTAssertTrue(gate.accepts(fingerprint(maximum: 196),
                                   publicationDeferred: false),
                      "an independent max-HR/profile change must replay")
        XCTAssertTrue(gate.accepts(fingerprint(maximum: 196,
                                               median: log(64),
                                               scale: 0.31,
                                               hrvDays: 21),
                                   publicationDeferred: false),
                      "the exact median/MAD/sample calibration must replay")
        let recoveredIntermediate = fingerprint(rest: 58,
                                                maximum: 196,
                                                median: log(64),
                                                scale: 0.31,
                                                hrvDays: 21)
        XCTAssertFalse(gate.accepts(recoveredIntermediate,
                                    publicationDeferred: true),
                       "intermediate recovered baseline state waits for its final fence")
        XCTAssertFalse(gate.accepts(recoveredIntermediate,
                                    publicationDeferred: false),
                       "a rollback callback after ticket release remains pending until the typed terminal edge")
        XCTAssertTrue(gate.releaseDeferred(final: recoveredIntermediate),
                      "the exact final fingerprint releases one deferred replay")
        XCTAssertFalse(gate.releaseDeferred(final: recoveredIntermediate))
    }

    func testFallbackRestChangePublishesIndependentLearningCalibrationRevision() {
        func learningFingerprint(rest: Double)
            -> AtriaHistoricalStressCalibrationFingerprint {
            AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: rest,
                      maximumHeartRate: 190,
                      restingBaselineDayCount: 0,
                      hrvBaseline: nil)
            )
        }
        var gate = AtriaHistoricalStressCalibrationPublicationGate()
        XCTAssertFalse(gate.accepts(learningFingerprint(rest: 60),
                                    publicationDeferred: false))
        XCTAssertTrue(gate.accepts(learningFingerprint(rest: 61),
                                   publicationDeferred: false),
                      "the actual fallback rest input is a v3 calibration field")
        XCTAssertFalse(gate.accepts(learningFingerprint(rest: 61),
                                    publicationDeferred: false),
                       "unchanged fallback rest must not wake another replay")
    }

    func testProfileOnlyChangeSurvivingFailedRecoveryReleasesFinalCalibration() {
        func fingerprint(maximum: Double)
            -> AtriaHistoricalStressCalibrationFingerprint {
            AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: 60,
                      maximumHeartRate: maximum,
                      restingBaselineDayCount: 20,
                      hrvBaseline: nil)
            )
        }
        var gate = AtriaHistoricalStressCalibrationPublicationGate()
        XCTAssertFalse(gate.accepts(fingerprint(maximum: 190),
                                    publicationDeferred: false))
        XCTAssertFalse(gate.accepts(fingerprint(maximum: 196),
                                    publicationDeferred: true))
        XCTAssertTrue(gate.releaseDeferred(final: fingerprint(maximum: 196)),
                      "a profile mutation outside the rollback image survives failure and must replay")
        XCTAssertFalse(gate.releaseDeferred(final: fingerprint(maximum: 196)))
    }

    func testFallbackRestOnlyChangeSurvivingFailedRecoveryReleasesFinalCalibration() {
        func fingerprint(rest: Double)
            -> AtriaHistoricalStressCalibrationFingerprint {
            AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: rest,
                      maximumHeartRate: 190,
                      restingBaselineDayCount: 0,
                      hrvBaseline: nil)
            )
        }
        var gate = AtriaHistoricalStressCalibrationPublicationGate()
        XCTAssertFalse(gate.accepts(fingerprint(rest: 60),
                                    publicationDeferred: false))
        XCTAssertFalse(gate.accepts(fingerprint(rest: 61),
                                    publicationDeferred: true))
        XCTAssertTrue(gate.releaseDeferred(final: fingerprint(rest: 61)),
                      "the live fallback-rest input survives recovered rollback and must replay")
        XCTAssertFalse(gate.accepts(fingerprint(rest: 61),
                                    publicationDeferred: false))
    }

    func testProvisionalRollbackBaselineCannotReplayBetweenTicketClearAndTerminalEdge() {
        func fingerprint(rest: Double, days: Int)
            -> AtriaHistoricalStressCalibrationFingerprint {
            AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: rest,
                      maximumHeartRate: 190,
                      restingBaselineDayCount: days,
                      hrvBaseline: nil)
            )
        }
        let settled = fingerprint(rest: 60, days: 20)
        var gate = AtriaHistoricalStressCalibrationPublicationGate()
        XCTAssertFalse(gate.accepts(settled, publicationDeferred: false))
        XCTAssertFalse(gate.accepts(fingerprint(rest: 55, days: 21),
                                    publicationDeferred: true))

        // AtriaRecoveredDataMutationTransaction deliberately clears its active
        // ticket before invoking rollback callbacks. This non-deferred callback
        // must update only pending state, never publish an intermediate replay.
        XCTAssertFalse(gate.accepts(settled, publicationDeferred: false))
        XCTAssertFalse(gate.releaseDeferred(final: settled),
                       "rollback to the already-settled baseline needs no replay")
        XCTAssertFalse(gate.accepts(settled, publicationDeferred: false))
    }

    func testFailedNonRetainedRestoreReleasesFallbackRestPendingCalibration() {
        func fingerprint(rest: Double)
            -> AtriaHistoricalStressCalibrationFingerprint {
            AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: rest,
                      maximumHeartRate: 190,
                      restingBaselineDayCount: 0,
                      hrvBaseline: nil)
            )
        }
        var gate = AtriaHistoricalStressCalibrationPublicationGate()
        XCTAssertFalse(gate.accepts(fingerprint(rest: 60),
                                    publicationDeferred: false))
        XCTAssertFalse(gate.accepts(fingerprint(rest: 62),
                                    publicationDeferred: true))
        XCTAssertTrue(gate.releaseDeferred(final: fingerprint(rest: 62)),
                      "failed restore fence release must settle a surviving fallback-rest change")
        XCTAssertFalse(gate.releaseDeferred(final: fingerprint(rest: 62)))
    }

    func testMixedProvisionalBaselineAndSurvivingProfileReleaseFinalCalibrationAtomically() {
        func fingerprint(rest: Double, maximum: Double, days: Int)
            -> AtriaHistoricalStressCalibrationFingerprint {
            AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: rest,
                      maximumHeartRate: maximum,
                      restingBaselineDayCount: days,
                      hrvBaseline: nil)
            )
        }
        let settled = fingerprint(rest: 60, maximum: 190, days: 20)
        let provisional = fingerprint(rest: 55, maximum: 196, days: 21)
        let final = fingerprint(rest: 60, maximum: 196, days: 20)
        var gate = AtriaHistoricalStressCalibrationPublicationGate()
        XCTAssertFalse(gate.accepts(settled, publicationDeferred: false))
        XCTAssertFalse(gate.accepts(provisional, publicationDeferred: true))
        XCTAssertFalse(gate.accepts(final, publicationDeferred: false),
                       "ticket-clear rollback callback must remain pending")
        XCTAssertTrue(gate.releaseDeferred(final: final),
                      "the settled result must retain profile authority while discarding provisional baseline authority")
        XCTAssertFalse(gate.accepts(final, publicationDeferred: false))
    }

    func testCommitRejectedRollbackCleanupReleasesPendingCalibration() {
        func fingerprint(maximum: Double)
            -> AtriaHistoricalStressCalibrationFingerprint {
            AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: 60,
                      maximumHeartRate: maximum,
                      restingBaselineDayCount: 20,
                      hrvBaseline: nil)
            )
        }
        var gate = AtriaHistoricalStressCalibrationPublicationGate()
        XCTAssertFalse(gate.accepts(fingerprint(maximum: 190),
                                    publicationDeferred: false))
        XCTAssertFalse(gate.accepts(fingerprint(maximum: 195),
                                    publicationDeferred: true))
        XCTAssertTrue(gate.releaseDeferred(final: fingerprint(maximum: 195)),
                      "commit rejection must roll back the active ticket and release the surviving final calibration")
        XCTAssertFalse(gate.releaseDeferred(final: fingerprint(maximum: 195)))
    }

    func testOverlappingFailureTerminalOrderMatrixWaitsForFinalFence() {
        func fingerprint(rest: Double, maximum: Double, days: Int)
            -> AtriaHistoricalStressCalibrationFingerprint {
            AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: rest,
                      maximumHeartRate: maximum,
                      restingBaselineDayCount: days,
                      hrvBaseline: nil)
            )
        }
        let settled = fingerprint(rest: 60, maximum: 190, days: 20)
        let provisional = fingerprint(rest: 55, maximum: 196, days: 21)
        let final = fingerprint(rest: 60, maximum: 196, days: 20)

        for order in [
            "restore failure while recovered remains active",
            "recovered failure while restore remains active"
        ] {
            var gate = AtriaHistoricalStressCalibrationPublicationGate()
            XCTAssertFalse(gate.accepts(settled, publicationDeferred: false), order)
            XCTAssertFalse(gate.accepts(provisional, publicationDeferred: true), order)
            XCTAssertFalse(
                gate.recordTerminal(
                    sourceReplayRequired: false,
                    publicationDeferred: true
                ),
                "\(order) must not consume the other fence's provisional authority"
            )
            XCTAssertFalse(
                gate.accepts(final, publicationDeferred: false),
                "the callback between last-fence clear and its terminal edge remains pending"
            )
            XCTAssertTrue(gate.recordTerminal(
                sourceReplayRequired: false,
                publicationDeferred: false
            ), order)
            XCTAssertTrue(gate.releaseDeferred(final: final), order)
            XCTAssertFalse(gate.releaseDeferred(final: final),
                           "\(order) must drain exactly once")
        }
    }

    func testOverlappingTwoFailuresDiscardRollbackOnlyBaselineInEitherOrder() {
        func fingerprint(rest: Double, days: Int)
            -> AtriaHistoricalStressCalibrationFingerprint {
            AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: rest,
                      maximumHeartRate: 190,
                      restingBaselineDayCount: days,
                      hrvBaseline: nil)
            )
        }
        let settled = fingerprint(rest: 60, days: 20)
        let provisional = fingerprint(rest: 54, days: 21)

        for order in ["restore then recovered", "recovered then restore"] {
            var gate = AtriaHistoricalStressCalibrationPublicationGate()
            XCTAssertFalse(gate.accepts(settled, publicationDeferred: false), order)
            XCTAssertFalse(gate.accepts(provisional, publicationDeferred: true), order)
            XCTAssertFalse(gate.recordTerminal(
                sourceReplayRequired: false,
                publicationDeferred: true
            ), order)
            XCTAssertFalse(gate.accepts(settled, publicationDeferred: false), order)
            XCTAssertTrue(gate.recordTerminal(
                sourceReplayRequired: false,
                publicationDeferred: false
            ), "pending calibration must be drained only at final authority")
            XCTAssertFalse(gate.releaseDeferred(final: settled),
                           "\(order) must not replay a rolled-back baseline")
            XCTAssertFalse(gate.releaseDeferred(final: settled), order)
        }
    }

    func testOverlappingSuccessfulSourceMatrixPreservesReplayUntilFinalFence() {
        func fingerprint(maximum: Double = 190)
            -> AtriaHistoricalStressCalibrationFingerprint {
            AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: 60,
                      maximumHeartRate: maximum,
                      restingBaselineDayCount: 20,
                      hrvBaseline: nil)
            )
        }
        let settled = fingerprint()

        for firstSource in ["recovered success", "restore success"] {
            for secondFenceAlsoPublishesSource in [false, true] {
                let scenario = "\(firstSource), second source=\(secondFenceAlsoPublishesSource)"
                var gate = AtriaHistoricalStressCalibrationPublicationGate()
                XCTAssertFalse(gate.accepts(settled,
                                            publicationDeferred: false),
                               scenario)
                XCTAssertFalse(gate.recordTerminal(
                    sourceReplayRequired: true,
                    publicationDeferred: true
                ), "\(scenario) must wait for the other active fence")
                XCTAssertFalse(gate.accepts(settled,
                                            publicationDeferred: false),
                               "source intent keeps pre-terminal callbacks pending")
                XCTAssertTrue(gate.recordTerminal(
                    sourceReplayRequired: secondFenceAlsoPublishesSource,
                    publicationDeferred: false
                ), scenario)
                XCTAssertTrue(gate.releaseDeferred(final: settled),
                              "\(scenario) owes one source replay")
                XCTAssertFalse(gate.releaseDeferred(final: settled),
                               "\(scenario) must coalesce both terminal edges")
            }
        }
    }

    func testOverlappingFailureFirstThenSuccessfulSourceDrainsOnceInEitherOrder() {
        let settled = AtriaHistoricalStressCalibrationFingerprint(
            .init(restingHeartRate: 60,
                  maximumHeartRate: 190,
                  restingBaselineDayCount: 20,
                  hrvBaseline: nil)
        )

        for order in [
            "restore failure then recovered success",
            "recovered failure then restore success"
        ] {
            var gate = AtriaHistoricalStressCalibrationPublicationGate()
            XCTAssertFalse(gate.accepts(settled, publicationDeferred: false), order)
            XCTAssertFalse(gate.recordTerminal(
                sourceReplayRequired: false,
                publicationDeferred: true
            ), "\(order) must wait for the still-active source fence")
            XCTAssertTrue(gate.recordTerminal(
                sourceReplayRequired: true,
                publicationDeferred: false
            ), "\(order) final success must retain one source replay")
            XCTAssertTrue(gate.releaseDeferred(final: settled), order)
            XCTAssertFalse(gate.releaseDeferred(final: settled),
                           "\(order) must drain exactly once")
        }
    }

    func testOverlappingSourceAndCalibrationDrainAtomicallyWithoutCardiacLoop() {
        func fingerprint(maximum: Double)
            -> AtriaHistoricalStressCalibrationFingerprint {
            AtriaHistoricalStressCalibrationFingerprint(
                .init(restingHeartRate: 60,
                      maximumHeartRate: maximum,
                      restingBaselineDayCount: 20,
                      hrvBaseline: nil)
            )
        }
        let settled = fingerprint(maximum: 190)
        let final = fingerprint(maximum: 196)
        var gate = AtriaHistoricalStressCalibrationPublicationGate()
        XCTAssertFalse(gate.accepts(settled, publicationDeferred: false))
        XCTAssertFalse(gate.recordTerminal(
            sourceReplayRequired: true,
            publicationDeferred: true
        ))
        XCTAssertFalse(gate.accepts(final, publicationDeferred: true))
        XCTAssertTrue(gate.recordTerminal(
            sourceReplayRequired: false,
            publicationDeferred: false
        ))
        XCTAssertTrue(gate.releaseDeferred(final: final),
                      "source and final calibration authority drain atomically")
        XCTAssertFalse(gate.accepts(final, publicationDeferred: false),
                       "the drained fingerprint must not loop another replay")
        XCTAssertFalse(gate.recordTerminal(
            sourceReplayRequired: false,
            publicationDeferred: false
        ))
    }

    @MainActor
    func testBackdatedMinuteMergeIsIdempotentLeavesDistributionUntouchedAndLiveWinsCollision() async throws {
        let suiteName = "atria.stress.historical-merge.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = AtriaStressMonitorStore(defaults: suite)
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)
        for offset in [-300.0, -240.0, -180.0, -120.0, -60.0, 0.0] {
            store.update(heartRate: 75,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         now: now.addingTimeInterval(offset))
        }
        let live = try XCTUnwrap(store.history.last)
        XCTAssertEqual(live.factSource, .live)
        let distributionBefore = try XCTUnwrap(
            store.distributionComparison(now: now)
        ).today.sampleCount

        func fact(at date: Date, score: Double) -> AtriaPhysiologicalStressModel.MinuteFact {
            .init(date: date,
                  score: score,
                  unsmoothedScore: score,
                  meanHeartRate: 75,
                  rmssd: nil,
                  hrStress: score / 3,
                  hrvStress: nil,
                  heartRateWeight: 1,
                  motionContext: .unavailable,
                  sleepContext: .unavailable,
                  confidence: .low,
                  baselineLearning: false)
        }
        let replay = AtriaHistoricalStressReplay.Result(
            facts: [fact(at: now.addingTimeInterval(-60), score: 2.2),
                    fact(at: now, score: 2.8)],
            heartRates: [
                .init(date: now.addingTimeInterval(-60), bpm: 75),
            ]
        )

        await store.mergeHistoricalMinuteFacts(replay, now: now)
        XCTAssertEqual(store.history.map(\.t), [now.addingTimeInterval(-60), now])
        XCTAssertEqual(try XCTUnwrap(store.history.last).activation,
                       live.activation,
                       accuracy: 1e-12,
                       "the in-process live fact must win an exact-clock collision")
        XCTAssertEqual(try XCTUnwrap(store.history.last).factSource, .live)
        XCTAssertEqual(try XCTUnwrap(store.distributionComparison(now: now))
            .today.sampleCount, distributionBefore)
        let revisionAfterFirstMerge = store.historyRevision

        await store.mergeHistoricalMinuteFacts(replay, now: now)
        XCTAssertEqual(store.historyRevision, revisionAfterFirstMerge,
                       "replaying the same minute identities must be a no-op")
        XCTAssertEqual(try XCTUnwrap(store.distributionComparison(now: now))
            .today.sampleCount, distributionBefore)
    }

    func testRapidRecoveredPublicationGenerationCancelsOlderResultAuthority() {
        var gate = AtriaHistoricalStressReplayGenerationGate()
        let first = gate.begin()
        let second = gate.begin()

        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
    }

    func testHistoricalReplayCapsLargeSnapshotsAndFailsClosed() {
        XCTAssertTrue(AtriaHistoricalStressReplay.isWithinSnapshotBounds(
            sessionCount: AtriaHistoricalStressReplay.maximumSessionCount,
            heartRateRowCount: AtriaHistoricalStressReplay.maximumHeartRateRowCount,
            rrRowCount: AtriaHistoricalStressReplay.maximumRRRowCount
        ))
        XCTAssertFalse(AtriaHistoricalStressReplay.isWithinSnapshotBounds(
            sessionCount: AtriaHistoricalStressReplay.maximumSessionCount + 1,
            heartRateRowCount: 0,
            rrRowCount: 0
        ))
        XCTAssertFalse(AtriaHistoricalStressReplay.isWithinSnapshotBounds(
            sessionCount: 1,
            heartRateRowCount: AtriaHistoricalStressReplay.maximumHeartRateRowCount + 1,
            rrRowCount: 0
        ))

        let emptySession = AtriaHistoricalStressReplay.Session(
            id: UUID(),
            start: now,
            end: now,
            heartRates: [],
            rrIntervals: []
        )
        let oversized = AtriaHistoricalStressReplay.Snapshot(
            sessions: Array(repeating: emptySession,
                            count: AtriaHistoricalStressReplay.maximumSessionCount + 1),
            personalization: historicalPersonalization,
            now: now
        )
        XCTAssertEqual(AtriaHistoricalStressReplay.evaluate(oversized), .empty)
    }

    func testHomeObservesExactRecoveredStoreAndCancelsPriorStressReplayWorker() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "SessionStore.recoveredDataRecomputeDidPublishNotification"
        ))
        XCTAssertTrue(source.contains(
            "SessionStore.stressContextDidPublishNotification"
        ))
        XCTAssertTrue(source.contains(
            "SessionStore.stressReplayDidPublishNotification"
        ))
        XCTAssertTrue(source.contains(
            "SessionStore.stressCalibrationFenceDidReleaseNotification"
        ))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy:
                "publishingStore === self.store").count - 1,
            4,
            "every recovered/context/terminal edge must be exact-store scoped"
        )
        XCTAssertFalse(source.contains(
            "AtriaHistoricalStressSleepPublicationRevision"
        ), "Home must not walk whole sleep-history arrays to detect context changes")
        XCTAssertTrue(source.contains(
            "Publishers.CombineLatest3("
        ))
        XCTAssertTrue(source.contains(
            "historicalStressFallbackRestSubject.removeDuplicates()"
        ))
        XCTAssertTrue(source.contains(
            "historicalStressFallbackRestSubject.send(liveSessionDerived.rest)"
        ))
        XCTAssertTrue(source.contains(
            "AtriaHistoricalStressCalibrationFingerprint"
        ))
        XCTAssertTrue(source.contains(".removeDuplicates()"))
        XCTAssertTrue(source.contains(
            "historicalStressCalibrationPublicationGate.accepts"
        ))
        XCTAssertTrue(source.contains(
            "historicalStressCalibrationPublicationGate.releaseDeferred"
        ))
        XCTAssertTrue(source.contains(
            "historicalStressCalibrationPublicationGate.recordTerminal"
        ))
        XCTAssertTrue(source.contains(
            "releaseDeferredHistoricalStressCalibration()"
        ))
        XCTAssertTrue(source.contains(
            "publicationDeferred: store.stressReplayPublicationIsDeferred"
        ), "every terminal must recheck the combined recovered/restore fence")
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy:
                "handleHistoricalStressTerminal(").count - 1,
            5,
            "all four exact-store terminal/source observers share one multi-fence helper"
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy:
                "sourceReplayRequired: true").count - 1,
            3,
            "recovered, context, and generic replay sources must retain replay intent"
        )
        XCTAssertTrue(source.contains("sourceReplayRequired: false"))
        XCTAssertFalse(source.contains(
            "_ = self.releaseDeferredHistoricalStressCalibration()"
        ), "source observers must not clear pending state while another fence remains")
        XCTAssertTrue(source.contains("historicalStressReplayTriggerSubject"))
        XCTAssertTrue(source.contains(
            ".debounce(for: .milliseconds(750), scheduler: RunLoop.main)"
        ))
        XCTAssertTrue(source.contains(
            "private func invalidateAndEnqueueHistoricalStressReplay()"
        ))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy:
                "historicalStressReplayGate.begin()").count - 1,
            2,
            "publication must invalidate authority before debounce and again when starting"
        )
        XCTAssertTrue(source.contains("historicalStressReplayWorker?.cancel()"))
        XCTAssertTrue(source.contains("AtriaHistoricalStressReplay.snapshot("))
        XCTAssertFalse(source.contains("!snapshot.sessions.isEmpty"),
                       "an authoritative empty source must clear obsolete replay gaps")
        XCTAssertTrue(source.contains("confirmedWorkouts: store.confirmedWorkouts"))
        XCTAssertTrue(source.contains("confirmedSleeps: store.confirmedSleeps"))
        XCTAssertTrue(source.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(source.contains("waitForHistoryHydration()"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy:
                "historicalStressReplayGate.accepts(generation)").count - 1,
            2,
            "generation authority must be rechecked after hydration suspension"
        )
        XCTAssertTrue(source.contains("mergeHistoricalMinuteFacts("))
    }

    // MARK: Bounded local stress-history continuity

    private func makeStressHistoryPersistence() -> (AtriaStressHistoryPersistence, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-stress-history-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        return (AtriaStressHistoryPersistence(directoryURL: directory), directory)
    }

    private func persistedPoint(
        t: Date,
        activation: Double,
        level _: AtriaStressLevel,
        confidence: Double,
        hrvAvailable: Bool,
        minuteFact customMinuteFact: AtriaPhysiologicalStressModel.MinuteFact? = nil,
        factSource: AtriaStressHistoryFactSource = .live,
        replayAuthority: AtriaStressReplayAuthority? = nil,
        scoringVersion: Int = AtriaStressMonitor.scoringVersion
    ) -> AtriaStressHistoryArchive.Point {
        let confidenceBand: AtriaPhysiologicalStressModel.Confidence = hrvAvailable
            ? (confidence >= 0.8 ? .high : (confidence >= 0.6 ? .medium : .low))
            : .low
        let score = min(max(activation * 3, 0), 3)
        let generatedFact = AtriaPhysiologicalStressModel.MinuteFact(
            date: t,
            score: score,
            unsmoothedScore: score,
            meanHeartRate: 80,
            rmssd: hrvAvailable ? 50 : nil,
            hrStress: activation,
            hrvStress: hrvAvailable ? activation : nil,
            heartRateWeight: hrvAvailable ? 0.75 : 1,
            motionContext: confidenceBand == .high ? .qualifiedStill : .unavailable,
            sleepContext: .unavailable,
            confidence: confidenceBand,
            baselineLearning: confidenceBand != .high,
            scoringVersion: scoringVersion
        )
        let minuteFact = customMinuteFact ?? generatedFact
        let resolvedLevel: AtriaStressLevel
        switch minuteFact.zone {
        case .calm: resolvedLevel = .calm
        case .moderate: resolvedLevel = .medium
        case .high: resolvedLevel = .high
        }
        return AtriaStressHistoryArchive.Point(
            t: t,
            activation: minuteFact.score / 3,
            level: resolvedLevel,
            confidence: minuteFact.confidence.numericValue,
            hrvAvailable: hrvAvailable,
            minuteFact: minuteFact,
            factSource: factSource,
            replayAuthority: replayAuthority,
            scoringVersion: scoringVersion
        )
    }

    func testStressPersistenceUsesV3NamespacesAndFailsClosedOnLegacySemantics() throws {
        XCTAssertEqual(AtriaStressMonitor.scoringVersion, 3)
        XCTAssertEqual(AtriaStressHistoryArchive.currentSchemaVersion, 3)
        XCTAssertEqual(AtriaStressHistoryPersistence.filenamePrefix, "stress-minute-v3-")
        XCTAssertEqual(AtriaStressHistoryPersistence.productionDirectoryName,
                       "Atria/stress-history-v3")
        XCTAssertEqual(AtriaStressDistributionArchive.defaultsKey,
                       "atria.stress.distribution.v3")

        let legacyPoint = AtriaStressHistoryArchive.Point(
            t: now,
            activation: 0.3,
            level: .low,
            confidence: 0.7,
            hrvAvailable: true,
            scoringVersion: 1
        )
        XCTAssertThrowsError(
            try AtriaStressHistoryArchive(points: [legacyPoint])
                .validatedAndPruned(now: now)
        )
        let incompleteV3 = AtriaStressHistoryArchive.Point(
            t: now,
            activation: 0.3,
            level: .calm,
            confidence: 0.7,
            hrvAvailable: false
        )
        XCTAssertThrowsError(
            try AtriaStressHistoryArchive(points: [incompleteV3])
                .validatedAndPruned(now: now),
            "v3 records require their complete versioned minute fact"
        )

        let suiteName = "atria.stress.legacy-distribution.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let legacyArchive = AtriaStressDistributionArchive(days: [
            .init(day: now,
                  distribution: .init(calmSamples: 4,
                                      mediumSamples: 3,
                                      highSamples: 2),
                  lastSampleAt: now),
        ])
        suite.set(try JSONEncoder().encode(legacyArchive),
                  forKey: "atria.stress.distribution.v2")
        XCTAssertTrue(AtriaStressDistributionArchive.load(defaults: suite).days.isEmpty,
                      "v2 mixed-semantics aggregates are ignored, not relabelled v3")
    }

    func testStressHistoryArchiveRoundTripPreservesTimestampsGapsAndProvenance() async throws {
        let (persistence, directory) = makeStressHistoryPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_800_100_000)
        let minuteFact = AtriaPhysiologicalStressModel.MinuteFact(
            date: base.addingTimeInterval(30),
            score: 1.11,
            unsmoothedScore: 1.2,
            meanHeartRate: 84,
            rmssd: 52,
            hrStress: 0.45,
            hrvStress: 0.32,
            heartRateWeight: 0.8,
            motionContext: .qualifiedStill,
            sleepContext: .awake,
            confidence: .high,
            baselineLearning: false
        )
        let points = [
            persistedPoint(t: base,
                                            activation: 0.18,
                                            level: .calm,
                                            confidence: 0.62,
                                            hrvAvailable: false),
            persistedPoint(t: base.addingTimeInterval(30),
                                            activation: 0.37,
                                            level: .low,
                                            confidence: 0.75,
                                            hrvAvailable: true,
                                            minuteFact: minuteFact,
                                            factSource: .historicalReplay,
                                            replayAuthority: replayAuthority(
                                                cardiac: "v1:0000000000000061",
                                                calibration: "v1:0000000000000062",
                                                context: "v1:0000000000000063"
                                            )),
            // Deliberate 9.5-minute hole: persistence must not invent points.
            persistedPoint(t: base.addingTimeInterval(600),
                                            activation: 0.68,
                                            level: .medium,
                                            confidence: 0.91,
                                            hrvAvailable: true),
        ]
        let archive = AtriaStressHistoryArchive(points: points)
        let didSave = await persistence.save(archive,
                                             now: base.addingTimeInterval(600))
        XCTAssertTrue(didSave)

        let result = await persistence.load(now: base.addingTimeInterval(600))
        guard case .loaded(let restored) = result else {
            return XCTFail("a complete atomic checkpoint must round-trip")
        }
        XCTAssertEqual(restored, archive)
        XCTAssertEqual(restored.points.map(\.t), points.map(\.t))
        XCTAssertEqual(restored.points[1].confidence, 0.9, accuracy: 1e-12)
        XCTAssertTrue(restored.points[1].hrvAvailable)
        XCTAssertEqual(restored.points[1].minuteFact, minuteFact)
        XCTAssertEqual(restored.points[1].resolvedFactSource, .historicalReplay)
        XCTAssertEqual(restored.points[1].replayAuthority?.contextRevision,
                       "v1:0000000000000063")
        XCTAssertFalse(restored.points[0].hrvAvailable)
        XCTAssertEqual(restored.points[2].scoringVersion,
                       AtriaStressMonitor.scoringVersion)
        XCTAssertEqual(restored.points[2].t.timeIntervalSince(restored.points[1].t),
                       570,
                       "the real disconnected interval must remain an unfilled gap")
    }

    func testStressHistoryArchivePrunesExpiredPointsAndEnforcesHardPointBound() async throws {
        let (persistence, directory) = makeStressHistoryPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }

        let end = Date(timeIntervalSince1970: 1_800_200_000)
        var points = [
            persistedPoint(
                t: end.addingTimeInterval(-AtriaStressHistoryArchive.retentionWindow - 1),
                activation: 0.1,
                level: .calm,
                confidence: 0.5,
                hrvAvailable: false
            ),
        ]
        // More than 48 hours of minute facts exercise exact retention and the
        // independent 2,880-point hard cap without exceeding 64 points/hour.
        points += (0..<3_000).map { index in
            persistedPoint(
                t: end.addingTimeInterval(-Double(2_999 - index) * 60),
                activation: 0.4,
                level: .low,
                confidence: 0.8,
                hrvAvailable: index.isMultiple(of: 2)
            )
        }
        let didSave = await persistence.save(AtriaStressHistoryArchive(points: points),
                                             now: end)
        XCTAssertTrue(didSave)
        guard case .loaded(let restored) = await persistence.load(now: end) else {
            return XCTFail("bounded checkpoint must load")
        }
        XCTAssertEqual(restored.points.count, AtriaStressHistoryArchive.maximumPointCount)
        XCTAssertEqual(restored.points.last?.t, end)
        XCTAssertTrue(restored.points.allSatisfy {
            end.timeIntervalSince($0.t) <= AtriaStressHistoryArchive.retentionWindow
        })

        // The same complete archive is legitimately empty once every exact
        // sample timestamp falls outside the 48-hour retention window.
        let expiredAt = end.addingTimeInterval(AtriaStressHistoryArchive.retentionWindow + 1)
        guard case .loaded(let expired) = await persistence.load(now: expiredAt) else {
            return XCTFail("expiry is a valid empty archive, not an I/O failure")
        }
        XCTAssertTrue(expired.points.isEmpty)
    }

    func testMaximumStressHourShardStaysInsideMeasuredWriteBudget() async throws {
        let (persistence, directory) = makeStressHistoryPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hourStart = Date(timeIntervalSince1970: 1_800_000_000)
        let points = (0..<AtriaStressHistoryPersistence.maximumPointsPerShard).map { index in
            persistedPoint(
                t: hourStart.addingTimeInterval(Double(index) * 28),
                activation: 0.987_654_321_098_765_4,
                level: .high,
                confidence: 0.876_543_210_987_654_3,
                hrvAvailable: true
            )
        }
        let end = try XCTUnwrap(points.last?.t)
        let didSave = await persistence.save(AtriaStressHistoryArchive(points: points),
                                             now: end)
        XCTAssertTrue(didSave)
        let bytes = try Data(contentsOf: persistence.shardURL(containing: hourStart)).count
        XCTAssertLessThanOrEqual(bytes,
                                 AtriaStressHistoryPersistence.maximumEncodedBytesPerShard)
    }

    @MainActor
    func testStressHistoryRelaunchHydrationMergesLiveTailAndDeduplicatesExactClock() async throws {
        let (persistence, directory) = makeStressHistoryPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_800_300_000)
        let liveClock = base.addingTimeInterval(300)
        let persisted = AtriaStressHistoryArchive(points: [
            persistedPoint(t: base.addingTimeInterval(-600),
                                            activation: 0.2,
                                            level: .calm,
                                            confidence: 0.6,
                                            hrvAvailable: false),
            // This exact timestamp will also be produced live before the async
            // restore completes. The live publication must win, not duplicate.
            persistedPoint(t: liveClock,
                                            activation: 0.1,
                                            level: .calm,
                                            confidence: 0.1,
                                            hrvAvailable: true),
        ])
        let didSave = await persistence.save(persisted, now: liveClock)
        XCTAssertTrue(didSave)

        let store = AtriaStressMonitorStore(historyPersistence: persistence,
                                            historyLoadNow: liveClock)
        XCTAssertEqual(store.historyLoadState, .loading)
        let baseline = makeBaseline(restingMean: 60, restingSD: 4, hrvSampleDays: 0)
        // No suspension between store init and these updates: this creates a
        // real live tail while the serial filesystem restore is pending.
        for offset in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
            store.update(heartRate: 75,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: base.addingTimeInterval(offset))
        }
        let livePoint = try XCTUnwrap(store.history.last)
        XCTAssertEqual(livePoint.t, liveClock)

        await store.waitForHistoryHydration()
        XCTAssertEqual(store.historyLoadState, .loaded)
        XCTAssertEqual(store.history.count, 2,
                       "one restored point plus one exact-clock live winner")
        XCTAssertEqual(store.history.map(\.t), [base.addingTimeInterval(-600), liveClock])
        let mergedTail = try XCTUnwrap(store.history.last)
        XCTAssertEqual(mergedTail.activation, livePoint.activation, accuracy: 1e-12)
        XCTAssertEqual(mergedTail.confidence, livePoint.confidence, accuracy: 1e-12)
        XCTAssertEqual(mergedTail.hrvAvailable, livePoint.hrvAvailable,
                       "live HR-only provenance must replace stale duplicate provenance")
        XCTAssertEqual(mergedTail.t.timeIntervalSince(store.history[0].t), 900,
                       "hydration must preserve the real gap")
    }

    @MainActor
    func testCorruptStressHistoryReportsUnavailableInsteadOfTrueEmpty() async throws {
        let (persistence, directory) = makeStressHistoryPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        // Keep the fixture on the scorer's exact one-minute frame. The v3
        // kernel intentionally rejects a partial (<290 s) five-minute window;
        // an off-minute start would never create the valid replacement fact
        // this persistence recovery test is meant to exercise.
        let loadNow = Date(timeIntervalSince1970: 1_800_400_020)
        let olderCorruptHour = loadNow.addingTimeInterval(-3 * 3_600)
        try Data("not-json".utf8).write(
            to: persistence.shardURL(containing: olderCorruptHour),
            options: .atomic
        )

        let store = AtriaStressMonitorStore(historyPersistence: persistence,
                                            historyLoadNow: loadNow)
        await store.waitForHistoryHydration()
        XCTAssertEqual(store.historyLoadState, .unavailable)
        XCTAssertTrue(store.history.isEmpty)

        // A new valid live checkpoint atomically replaces the corrupt current
        // hour. Once the background writer confirms it, the live tail is again
        // an available (shorter, honest) archive rather than a permanent error.
        let baseline = makeBaseline(restingMean: 60, restingSD: 4, hrvSampleDays: 0)
        for offset in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
            store.update(heartRate: 75,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: loadNow.addingTimeInterval(offset))
        }
        await store.waitForPendingHistoryCheckpoint()
        XCTAssertEqual(store.historyLoadState, .loaded)
        // A brand-new persistence instance models the next process launch. The
        // older corrupt shard must have been cleared before `.loaded` published.
        let relaunched = AtriaStressHistoryPersistence(directoryURL: directory)
        guard case .loaded(let recovered) = await relaunched.load(
            now: loadNow.addingTimeInterval(300)
        ) else {
            return XCTFail("a confirmed replacement must become readable")
        }
        XCTAssertEqual(recovered.points.count, 1)
        XCTAssertEqual(recovered.points.first?.t, loadNow.addingTimeInterval(300))
    }

    func testInvalidStressCheckpointIsRejectedWithoutReplacingLastValidShard() async throws {
        let (persistence, directory) = makeStressHistoryPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_500_000)
        let valid = AtriaStressHistoryArchive(points: [
            persistedPoint(t: now,
                                            activation: 0.3,
                                            level: .low,
                                            confidence: 0.7,
                                            hrvAvailable: false),
        ])
        let didSave = await persistence.save(valid, now: now)
        XCTAssertTrue(didSave)
        let validFact = try XCTUnwrap(valid.points.first?.minuteFact)
        let futureClock = now.addingTimeInterval(
            AtriaStressHistoryArchive.maximumFutureSkew + 1
        )
        let futureFact = AtriaPhysiologicalStressModel.MinuteFact(
            date: futureClock,
            score: validFact.score,
            unsmoothedScore: validFact.unsmoothedScore,
            meanHeartRate: validFact.meanHeartRate,
            rmssd: validFact.rmssd,
            hrStress: validFact.hrStress,
            hrvStress: validFact.hrvStress,
            heartRateWeight: validFact.heartRateWeight,
            motionContext: validFact.motionContext,
            sleepContext: validFact.sleepContext,
            confidence: validFact.confidence,
            baselineLearning: validFact.baselineLearning
        )

        let invalidClaims = [
            // Every failure keeps a complete fact and corrupts one outer claim.
            AtriaStressHistoryArchive.Point(t: now,
                                            activation: validFact.score / 3,
                                            level: .high,
                                            confidence: validFact.confidence.numericValue,
                                            hrvAvailable: !validFact.isHROnly,
                                            minuteFact: validFact),
            AtriaStressHistoryArchive.Point(t: now,
                                            activation: validFact.score / 3,
                                            level: .calm,
                                            confidence: 1.1,
                                            hrvAvailable: !validFact.isHROnly,
                                            minuteFact: validFact),
            AtriaStressHistoryArchive.Point(t: now,
                                            activation: validFact.score / 3,
                                            level: .calm,
                                            confidence: validFact.confidence.numericValue,
                                            hrvAvailable: !validFact.isHROnly,
                                            minuteFact: validFact,
                                            scoringVersion: AtriaStressMonitor.scoringVersion + 1),
            AtriaStressHistoryArchive.Point(
                t: futureClock,
                activation: futureFact.score / 3,
                level: .calm,
                confidence: futureFact.confidence.numericValue,
                hrvAvailable: !futureFact.isHROnly,
                minuteFact: futureFact
            ),
        ]
        for invalid in invalidClaims {
            let didSaveInvalid = await persistence.save(
                AtriaStressHistoryArchive(points: [invalid]),
                now: now
            )
            XCTAssertFalse(didSaveInvalid)
        }

        guard case .loaded(let restored) = await persistence.load(now: now) else {
            return XCTFail("rejected writes must leave the previous valid shard intact")
        }
        XCTAssertEqual(restored, valid)
    }

    @MainActor
    func testDelayedBackgroundFlushAnchorsSubCadenceTailToItsSampleHour() async throws {
        let (persistence, directory) = makeStressHistoryPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_800_600_000)
        let seed = AtriaStressHistoryArchive(points: [
            persistedPoint(t: base.addingTimeInterval(-600),
                                            activation: 0.2,
                                            level: .calm,
                                            confidence: 0.6,
                                            hrvAvailable: false),
        ])
        let didSave = await persistence.save(seed, now: base)
        XCTAssertTrue(didSave)
        let store = AtriaStressMonitorStore(historyPersistence: persistence,
                                            historyLoadNow: base)
        await store.waitForHistoryHydration()

        let baseline = makeBaseline(restingMean: 60, restingSD: 4, hrvSampleDays: 0)
        for offset in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0] {
            store.update(heartRate: 75,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: base.addingTimeInterval(offset))
        }
        // One new point is below the ordinary ten-sample cadence because a
        // durable seed already exists. The lifecycle hook must still enqueue it.
        // Backgrounding three hours after scoring must still write the hour that
        // owns the unsaved sample, not wall-now's empty current/previous hours.
        let delayedBackground = base.addingTimeInterval(3 * 3_600)
        store.flushHistoryCheckpoint(now: delayedBackground)
        await store.waitForPendingHistoryCheckpoint()
        guard case .loaded(let restored) = await persistence.load(
            now: delayedBackground
        ) else {
            return XCTFail("background flush must leave a readable archive")
        }
        XCTAssertEqual(restored.points.map(\.t),
                       [base.addingTimeInterval(-600), base.addingTimeInterval(300)])
    }

    @MainActor
    func testCadenceCheckpointRestoresDisconnectedSubCadenceDirtyHourAfterRelaunch() async throws {
        let (persistence, directory) = makeStressHistoryPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Keep both scored islands comfortably inside their respective hours.
        // The first contributes three dirty minute facts; two later facts bring
        // the global count to the five-fact persistence cadence.
        let firstStart = now.addingTimeInterval(600)
        let secondStart = firstStart.addingTimeInterval(3 * 3_600)
        let seedClock = firstStart.addingTimeInterval(-600)
        let didSeed = await persistence.save(
            AtriaStressHistoryArchive(points: [
                persistedPoint(t: seedClock,
                                                activation: 0.2,
                                                level: .calm,
                                                confidence: 0.6,
                                                hrvAvailable: false),
            ]),
            now: firstStart
        )
        XCTAssertTrue(didSeed)

        let store = AtriaStressMonitorStore(historyPersistence: persistence,
                                            historyLoadNow: firstStart)
        await store.waitForHistoryHydration()
        let baseline = makeBaseline(restingMean: 60, restingSD: 4, hrvSampleDays: 0)

        func feedIsland(start: Date, scoredPointCount: Int) {
            let offsets = [0.0, 60.0, 120.0, 180.0, 240.0]
                + (0..<scoredPointCount).map { 300.0 + Double($0) * 60 }
            for offset in offsets {
                store.update(heartRate: 75,
                             hasContact: true,
                             recentRRSamples: [],
                             isRecording: false,
                             zoneIndex: 0,
                             hrvSnapshot: nil,
                             baseline: baseline,
                             restingMaxHR: restingMaxHR,
                             hasActiveSleepEvidence: false,
                             now: start.addingTimeInterval(offset))
            }
        }

        feedIsland(start: firstStart, scoredPointCount: 3)
        feedIsland(start: secondStart, scoredPointCount: 2)
        await store.waitForPendingHistoryCheckpoint()

        // A new persistence object and store model a process relaunch. Both
        // dirty islands must survive; the three-hour discontinuity stays empty.
        let relaunchNow = secondStart.addingTimeInterval(480)
        let relaunchedPersistence = AtriaStressHistoryPersistence(directoryURL: directory)
        let relaunchedStore = AtriaStressMonitorStore(
            historyPersistence: relaunchedPersistence,
            historyLoadNow: relaunchNow
        )
        await relaunchedStore.waitForHistoryHydration()

        let firstClocks = (0..<3).map {
            firstStart.addingTimeInterval(300 + Double($0) * 60)
        }
        let secondClocks = (0..<2).map {
            secondStart.addingTimeInterval(300 + Double($0) * 60)
        }
        XCTAssertEqual(relaunchedStore.history.map(\.t),
                       [seedClock] + firstClocks + secondClocks)
        XCTAssertEqual(relaunchedStore.history.count, 6)
        XCTAssertGreaterThan(
            try XCTUnwrap(secondClocks.first).timeIntervalSince(
                try XCTUnwrap(firstClocks.last)
            ),
            2 * 3_600,
            "persistence must retain the real gap instead of synthesizing samples"
        )
    }

    func testStressHistoryCheckpointCadenceIsNotPerSample() {
        XCTAssertEqual(AtriaStressMonitorStore.boundedUnsavedHistorySampleCount(
            6_000,
            retainedPointCount: AtriaStressHistoryArchive.maximumPointCount
        ), AtriaStressHistoryArchive.maximumPointCount)
        XCTAssertEqual(AtriaStressMonitorStore.boundedUnsavedHistorySampleCount(
            10,
            retainedPointCount: 3
        ), 3, "expired dirty samples cannot outlive the retained suffix")
        XCTAssertFalse(AtriaStressMonitorStore.shouldPersistHistory(
            hasDurableCheckpoint: false,
            unsavedSampleCount: 0
        ))
        XCTAssertTrue(AtriaStressMonitorStore.shouldPersistHistory(
            hasDurableCheckpoint: false,
            unsavedSampleCount: 1
        ), "the first point makes a short session relaunch-visible")
        for pending in 1..<5 {
            XCTAssertFalse(AtriaStressMonitorStore.shouldPersistHistory(
                hasDurableCheckpoint: true,
                unsavedSampleCount: pending
            ), "an existing checkpoint must not write on sample \(pending)")
        }
        XCTAssertTrue(AtriaStressMonitorStore.shouldPersistHistory(
            hasDurableCheckpoint: true,
            unsavedSampleCount: 5
        ), "five minute facts checkpoint at most once per five minutes")
    }

    // MARK: Slow multi-day awake baseline (audit B3, recording-only)

    private func fillBaselineDay(_ archive: inout AtriaAwakeBaselineArchive,
                                 day: Date,
                                 bpm: Int,
                                 count: Int,
                                 calendar: Calendar) {
        for i in 0..<count {
            _ = archive.record(bpm: bpm,
                               at: day.addingTimeInterval(Double(i) * 30),
                               calendar: calendar)
        }
    }

    func testAwakeBaselineDayMedianFromHistogram() throws {
        var day = AtriaAwakeBaselineArchive.Day(day: now, histogram: [:], lastSampleAt: .distantPast)
        // 70,70,72,74,74 → median 72; a stray 150 is one of six → still 72/73.
        day.histogram = [70: 2, 72: 1, 74: 2]
        XCTAssertEqual(try XCTUnwrap(day.median), 72, accuracy: 0.001)
        day.histogram[150] = 1 // 6 samples: sorted 70,70,72,74,74,150 → median (72+74)/2
        XCTAssertEqual(try XCTUnwrap(day.median), 73, accuracy: 0.001)
    }

    func testAwakeBaselineIgnoresASingleStressedDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let d0 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        var archive = AtriaAwakeBaselineArchive()

        // Three calm days at 72 bpm, then a whole stressed day at 95 bpm.
        for offset in 0..<3 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: d0))
            fillBaselineDay(&archive, day: day, bpm: 72, count: 40, calendar: calendar)
        }
        let stressedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: d0))
        fillBaselineDay(&archive, day: stressedDay, bpm: 95, count: 40, calendar: calendar)

        XCTAssertEqual(archive.qualifyingDayCount, 4)
        // median of daily medians [72,72,72,95] = 72 — the stressed day is one
        // outlier and cannot move the baseline. THIS is the B3 property.
        XCTAssertEqual(try XCTUnwrap(archive.multiDayCenter()), 72, accuracy: 0.001)
    }

    func testAwakeBaselineWithheldUntilEnoughQualifyingDaysAndSamples() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let d0 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        var archive = AtriaAwakeBaselineArchive()

        // Two well-sampled days: below the 3-day floor → nil.
        for offset in 0..<2 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: d0))
            fillBaselineDay(&archive, day: day, bpm: 70, count: 40, calendar: calendar)
        }
        XCTAssertNil(archive.multiDayCenter(), "two days is below the qualifying-day floor")

        // A third day but under the per-day sample floor must not qualify it.
        let thinDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: d0))
        fillBaselineDay(&archive, day: thinDay, bpm: 70, count: 10, calendar: calendar)
        XCTAssertEqual(archive.qualifyingDayCount, 2)
        XCTAssertNil(archive.multiDayCenter(), "a day under the per-day sample floor does not count")

        // Filling it past the floor unlocks the center.
        fillBaselineDay(&archive,
                        day: thinDay.addingTimeInterval(1000),
                        bpm: 70,
                        count: 30,
                        calendar: calendar)
        XCTAssertEqual(archive.qualifyingDayCount, 3)
        XCTAssertEqual(try XCTUnwrap(archive.multiDayCenter()), 70, accuracy: 0.001)
    }

    func testAwakeBaselineRetentionDropsOldDaysAndRoundTrips() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let d0 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 9)))
        var archive = AtriaAwakeBaselineArchive()
        fillBaselineDay(&archive, day: d0, bpm: 70, count: 5, calendar: calendar)
        // A sample 40 days later must evict the original day (30-day retention).
        let farLater = try XCTUnwrap(calendar.date(byAdding: .day, value: 40, to: d0))
        _ = archive.record(bpm: 71, at: farLater, calendar: calendar)
        XCTAssertEqual(archive.days.count, 1)

        let suiteName = "atria.stress.awakebaseline.test.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        archive.save(defaults: suite)
        let reloaded = AtriaAwakeBaselineArchive.load(defaults: suite)
        XCTAssertEqual(reloaded, archive, "archive must survive a persistence round-trip")
    }

    // Integration: admitted quiet-awake samples fed through the live store must
    // flow into the slow baseline, and the exposed center must match the pure
    // archive's median-of-daily-medians.
    @MainActor
    func testStoreAccumulatesSlowAwakeBaselineFromAdmittedSamples() throws {
        let suiteName = "atria.stress.awakebaseline.store.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let baseline = makeBaseline(restingMean: 60, restingSD: 4, hrvSampleDays: 0)
        let store = AtriaStressMonitorStore(defaults: suite)

        XCTAssertNil(store.slowAwakeBaselineCenter(), "no center before any days accumulate")

        // 72 bpm is admitted for rest 60 (above rest+8, below rest+40, zone 0).
        // Three feeding-days spaced a full day apart. The store records with the
        // CURRENT calendar (not injectable), so a feeding-day could straddle
        // local midnight; 70 samples guarantees at least one calendar-day per
        // feeding-day clears the per-day sample floor regardless of the split.
        for dayOffset in 0..<3 {
            let dayBase = now.addingTimeInterval(Double(dayOffset) * 86_400)
            for i in 0..<70 {
                store.update(heartRate: 72,
                             hasContact: true,
                             recentRRSamples: [],
                             isRecording: false,
                             zoneIndex: 0,
                             hrvSnapshot: nil,
                             baseline: baseline,
                             restingMaxHR: restingMaxHR,
                             hasActiveSleepEvidence: false,
                             now: dayBase.addingTimeInterval(Double(i) * 60))
            }
        }

        XCTAssertGreaterThanOrEqual(store.slowAwakeBaselineQualifyingDayCount, 3)
        XCTAssertEqual(try XCTUnwrap(store.slowAwakeBaselineCenter()), 72, accuracy: 0.001,
                       "every admitted sample is 72, so the median of daily medians is 72")
    }

    // MARK: Qualified context

    func testRecordingAttenuatesButDoesNotSuppressV3Score() throws {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let adjusted = AtriaStressMonitor.score(hrNow: 150,
                                             hrWindow: [150],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: true,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)
        let unadjusted = AtriaStressMonitor.score(hrNow: 150,
                                                  hrWindow: [150],
                                                  rrWindowMs: [],
                                                  hrvFallbackRMSSD: nil,
                                                  baseline: baseline,
                                                  restingMaxHR: restingMaxHR,
                                                  workoutActive: false,
                                                  zoneIndex: 0,
                                                  inSleepWindow: false,
                                                  hasContact: true,
                                                  contactAgeSeconds: 300,
                                                  now: now)

        XCTAssertEqual(adjusted.kind, .scored)
        XCTAssertEqual(try XCTUnwrap(adjusted.minuteFact).motionContext.kind,
                       .activity)
        XCTAssertLessThan(adjusted.rawActivation, unadjusted.rawActivation)
        XCTAssertGreaterThan(adjusted.rawActivation, 0)
    }

    func testZoneOnlyCannotAttenuateOrSuppressV3Score() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let zoneTwo = AtriaStressMonitor.score(hrNow: 130,
                                             hrWindow: [130],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 2,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)
        let zoneZero = AtriaStressMonitor.score(hrNow: 130,
                                                hrWindow: [130],
                                                rrWindowMs: [],
                                                hrvFallbackRMSSD: nil,
                                                baseline: baseline,
                                                restingMaxHR: restingMaxHR,
                                                workoutActive: false,
                                                zoneIndex: 0,
                                                inSleepWindow: false,
                                                hasContact: true,
                                                contactAgeSeconds: 300,
                                                now: now)

        XCTAssertEqual(zoneTwo.kind, .scored)
        XCTAssertEqual(zoneTwo.rawActivation, zoneZero.rawActivation, accuracy: 1e-12)
        XCTAssertEqual(zoneTwo.minuteFact?.motionContext, .unavailable)
    }

    func testQualifiedSleepIsContextAndDoesNotEraseScore() throws {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 58,
                                             hrWindow: [58],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: true,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .scored)
        XCTAssertEqual(try XCTUnwrap(state.minuteFact).sleepContext, .asleep)
        XCTAssertNotNil(state.level)
    }

    func testNoSignalWhenContactLost() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 0,
                                             hrWindow: [],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: nil,
                                             inSleepWindow: false,
                                             hasContact: false,
                                             contactAgeSeconds: 0,
                                             now: now)

        XCTAssertEqual(state.kind, .noSignal)
        XCTAssertNil(state.level)
        let presentation = AtriaStressPresentation.make(state: state)
        XCTAssertEqual(
            presentation.value,
            AtriaCompactMetricPresentation.noValue
        )
        XCTAssertEqual(presentation.detail, "Waiting for a fresh strap signal")
    }

    func testImmatureBaselineUsesNumericLearningEstimate() throws {
        let baseline = makeBaseline(restingMean: 60,
                                    restingSD: 4,
                                    dayCount: PersonalBaseline.trustedMinimumSamples - 1)
        let state = AtriaStressMonitor.score(hrNow: 72,
                                             hrWindow: [72, 72, 72],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        let presentation = AtriaStressPresentation.make(state: state)
        XCTAssertEqual(state.kind, .scored)
        XCTAssertTrue(try XCTUnwrap(state.minuteFact).baselineLearning)
        XCTAssertNotNil(presentation.numericScore)
        XCTAssertTrue(presentation.value.contains("/ 3"))
    }

    func testMatureRestPresentationIsIdenticalForEverySurfaceConsumer() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)
        let state = AtriaStressMonitor.score(hrNow: 60,
                                             hrWindow: [60, 60, 60],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        let homeProjection = AtriaStressPresentation.make(state: state)
        let healthProjection = AtriaStressPresentation.make(state: state)
        XCTAssertEqual(homeProjection, healthProjection)
        XCTAssertEqual(homeProjection.value, "0.4 / 3")
        XCTAssertEqual(homeProjection.metricTitle, "Physiological stress")
        XCTAssertTrue(homeProjection.detail.contains("HR-only estimate"))
        XCTAssertNotNil(homeProjection.numericScore)
        XCTAssertTrue(homeProjection.narrative.contains("lower-confidence estimate"))
    }

    func testCoachCopyUsesPhysiologicalStressAndDisclosesHROnlyConfidence() {
        let guidance = Coach.guide(recovery: 0, strain: 0)
        let hrOnly = AtriaCoachContext(guidance: guidance,
                                       strain: 0,
                                       recoveryText: "--",
                                       hrvText: "--",
                                       stressText: "2.0 / 3",
                                       stressMetricTitle: "Cardiac arousal",
                                       stressEvidenceMode: .cardiacArousal,
                                       stressIsHROnlyEstimate: true,
                                       baselineSamples: 0,
                                       sessionsCount: 0)
        XCTAssertEqual(
            AtriaCoachStressPresentation.clause(context: hrOnly),
            "Physiological stress 2.0 / 3 (HR-only estimate; lower confidence)"
        )

        let physiological = AtriaCoachContext(guidance: guidance,
                                               strain: 0,
                                               recoveryText: "--",
                                               hrvText: "--",
                                               stressText: "1.4 / 3",
                                               stressMetricTitle: "Stress",
                                               stressEvidenceMode: .physiologicalStress,
                                               baselineSamples: 0,
                                               sessionsCount: 0)
        XCTAssertEqual(AtriaCoachStressPresentation.clause(context: physiological),
                       "Physiological stress 1.4 / 3")
    }

    func testWarmingUpBeforeCompleteFiveMinuteWindow() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 62,
                                             hrWindow: [62],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 30,
                                             now: now)

        XCTAssertEqual(state.kind, .warmingUp)
        XCTAssertNil(state.level)
        XCTAssertEqual(AtriaStressPresentation.make(state: state).detail,
                       "5 min of continuous signal")
    }

    // MARK: Honesty gating

    func testNoHistoricalBaselineUsesConservativeLearningFallback() throws {
        let baseline = PersonalBaseline() // no samples at all

        let state = AtriaStressMonitor.score(hrNow: 62,
                                             hrWindow: [62],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .scored)
        XCTAssertTrue(try XCTUnwrap(state.minuteFact).baselineLearning)
        XCTAssertEqual(state.confidence,
                       AtriaPhysiologicalStressModel.Confidence.low.numericValue)
    }

    func testPartialHistoricalBaselineRemainsExplicitlyLearning() throws {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4, dayCount: 5)

        let state = AtriaStressMonitor.score(hrNow: 62,
                                             hrWindow: [62],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .scored)
        XCTAssertTrue(try XCTUnwrap(state.minuteFact).baselineLearning)
    }

    func testStressDistributionTypicalRequiresThreeComparableMeasuredDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                       month: 7,
                                                                       day: 6,
                                                                       hour: 12)))
        var archive = AtriaStressDistributionArchive()

        for dayOffset in [0, 1, 2] {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: dayOffset, to: monday))
            for sample in 0..<10 {
                let date = day.addingTimeInterval(TimeInterval(sample * 30))
                XCTAssertTrue(archive.record(level: dayOffset == 1 ? .high : .calm,
                                             at: date,
                                             calendar: calendar))
            }
        }

        let thursday = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: monday))
        XCTAssertTrue(archive.record(level: .medium, at: thursday, calendar: calendar))
        let comparison = try XCTUnwrap(archive.comparison(at: thursday, calendar: calendar))

        XCTAssertEqual(comparison.comparisonDayCount, 3)
        XCTAssertEqual(comparison.today.mediumSamples, 1)
        XCTAssertEqual(comparison.typical?.calmSamples, 20)
        XCTAssertEqual(comparison.typical?.highSamples, 10)
    }

    func testStressDistributionDoesNotCountRestoredDuplicateSample() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                    month: 7,
                                                                    day: 13,
                                                                    hour: 10)))
        var archive = AtriaStressDistributionArchive()

        XCTAssertTrue(archive.record(level: .medium, at: date, calendar: calendar))
        XCTAssertFalse(archive.record(level: .high, at: date, calendar: calendar))
        XCTAssertEqual(archive.comparison(at: date, calendar: calendar)?.today.mediumSamples, 1)
        XCTAssertEqual(archive.comparison(at: date, calendar: calendar)?.today.highSamples, 0)
    }

    // Activity "heart & stress" card (2026-08-04): the store republishes the
    // contact-backed live HR it is already fed. Contract: set on contact,
    // cleared on lost contact, stamp refreshed on steady bpm so freshness
    // gating never hides a delivering strap.
    @MainActor
    func testLiveHeartRatePublishesOnContactAndClearsOnLoss() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)
        let store = AtriaStressMonitorStore()

        func tick(atOffset offset: TimeInterval, bpm: Int, hasContact: Bool) {
            store.update(heartRate: bpm,
                         hasContact: hasContact,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }

        tick(atOffset: 0, bpm: 64, hasContact: true)
        XCTAssertEqual(store.liveHeartRate?.bpm, 64)
        XCTAssertEqual(store.liveHeartRate?.at, now)

        // Steady bpm: the stamp refreshes once the old one ages past 30s.
        tick(atOffset: 10, bpm: 64, hasContact: true)
        XCTAssertEqual(store.liveHeartRate?.at, now, "stamp must not churn under 30s")
        tick(atOffset: 40, bpm: 64, hasContact: true)
        XCTAssertEqual(store.liveHeartRate?.at, now.addingTimeInterval(40))

        tick(atOffset: 45, bpm: 71, hasContact: true)
        XCTAssertEqual(store.liveHeartRate?.bpm, 71)

        tick(atOffset: 50, bpm: 0, hasContact: false)
        XCTAssertNil(store.liveHeartRate, "lost contact must clear the readout, not cache it")

        let reading = AtriaStressMonitorStore.LiveHeartRateReading(bpm: 70, at: now)
        XCTAssertTrue(reading.isFresh(now: now.addingTimeInterval(60)))
        XCTAssertFalse(reading.isFresh(now: now.addingTimeInterval(120)))
    }
}
