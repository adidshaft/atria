import XCTest
@testable import Atria

/// P0/P1 of the 2026-08-20 sleep-stage RR track.
///
/// P0 is the parity fence: the RR parameters are defaulted, and with
/// `rrSamples: []` the engine's STAGED output (every boundary and stage) is
/// ELEMENT-IDENTICAL to the pre-RR engine — no RR input means no behavior
/// change, in every phase. The expected timelines below were captured from
/// the unmodified engine on 2026-08-20 and remain the rr-empty regression
/// fence for the whole track. Two later phases deliberately moved the
/// with-RR expectations: P2 (design 1.2) mints the strong-RR estimate prefix
/// at coverage ≥ 0.90 (pinned in AtriaSleepStageRR90TierMintTests), and P3
/// (design 1.1 step 4) consumes `rrRMSSDLocal` through two refinement-only
/// decision rules — the with-RR pins in this file state the P3 expectations,
/// and the full refinement behavior lives in
/// AtriaSleepStageRRDecisionRefinementTests.
///
/// P1 pins the plumbing rules: qualified-provenance gather (2A37 + verified
/// WHOOP4 historical V24 only, 300–2000 ms clamp), per-epoch RR validity
/// (≥15 qualified beats inside the exact 30-second epoch), no cross-epoch
/// borrowing, and the RR work ledger (`rrVisits`) never leaking into the
/// pinned `sampleVisits` accounting.
final class AtriaSleepStageRRFeatureTests: XCTestCase {
    // MARK: - Fixed synthetic parity night (post-2026-08-06 time base)

    private static let parityBase = Date(timeIntervalSince1970: 1_800_000_000)
    private static let parityDurationSeconds = 4 * 60 * 60

    private var parityStart: Date { Self.parityBase }
    private var parityEnd: Date {
        Self.parityBase.addingTimeInterval(TimeInterval(Self.parityDurationSeconds))
    }

    private func parityBPM(_ offset: Int) -> Int {
        switch offset {
        case ..<2_400: return 72
        case ..<5_400: return 62
        case ..<9_000: return 66
        case ..<12_000: return (offset / 5).isMultiple(of: 2) ? 66 : 74
        default: return 85
        }
    }

    private func paritySamples() -> [AtriaSleepWakeResearch.HeartSample] {
        stride(from: 0, through: Self.parityDurationSeconds, by: 5).map { offset in
            AtriaSleepWakeResearch.HeartSample(
                t: Self.parityBase.addingTimeInterval(TimeInterval(offset)),
                bpm: parityBPM(offset)
            )
        }
    }

    private func parityMotionEpochs() -> [AtriaRecoveredMotionEpoch] {
        (0..<(Self.parityDurationSeconds / 30)).map { index in
            let epochStart = Self.parityBase.addingTimeInterval(Double(index) * 30)
            return AtriaRecoveredMotionEpoch(
                start: epochStart,
                end: min(parityEnd, epochStart.addingTimeInterval(30)),
                rows: 15,
                validatedRows: 15,
                stillnessRatio: 1,
                movementIntensity: 0,
                p95VectorDelta: 0,
                maximumGapSeconds: 2,
                measurementValidated: true,
                lowMotionQualified: true,
                reason: "rr-parity-fixture"
            )
        }
    }

    /// Captured from the pre-RR engine on 2026-08-20. Both lanes stage the
    /// identical boundaries on this night; only the minted id prefix differs.
    private let expectedParityRuns: [(start: Int, end: Int, stage: SleepStageKind)] = [
        (0, 870, .awake),
        (870, 2_400, .light),
        (2_400, 2_610, .sws),
        (2_610, 5_370, .deep),
        (5_370, 8_940, .sws),
        (8_940, 11_100, .rem),
        (11_100, 12_000, .light),
        (12_000, 14_400, .awake),
    ]

    /// P3 (design 1.1 step 4) estimate-lane expectation for the parity night
    /// under a dense UNIFORM tachogram: every epoch's local RMSSD equals the
    /// night median exactly, so the REM edge admission never fires (elevation
    /// requires strictly above 1.2× median) and the deep hedge's
    /// strictly-below-median requirement fails everywhere. The deep run —
    /// and only the deep run — falls to light; awake, sws, rem and every
    /// boundary are bit-identical to the pre-RR pins.
    private let hedgedEstimateParityRuns: [(start: Int, end: Int, stage: SleepStageKind)] = [
        (0, 870, .awake),
        (870, 2_400, .light),
        (2_400, 2_610, .sws),
        (2_610, 5_370, .light),
        (5_370, 8_940, .sws),
        (8_940, 11_100, .rem),
        (11_100, 12_000, .light),
        (12_000, 14_400, .awake),
    ]

    private func expectedParitySegments(
        prefix: String,
        runs: [(start: Int, end: Int, stage: SleepStageKind)]? = nil
    ) -> [SleepStageSegment] {
        (runs ?? expectedParityRuns).enumerated().map { index, run in
            SleepStageSegment(
                id: "\(prefix)\(1_800_000_000 + run.start)-\(index)-\(run.stage.rawValue)",
                start: Self.parityBase.addingTimeInterval(TimeInterval(run.start)),
                end: Self.parityBase.addingTimeInterval(TimeInterval(run.end)),
                stage: run.stage
            )
        }
    }

    private func denseParityRR(strideSeconds: Int = 1) -> [AtriaSleepWakeResearch.RRSample] {
        stride(from: 0, through: Self.parityDurationSeconds, by: strideSeconds).map { offset in
            AtriaSleepWakeResearch.RRSample(
                t: Self.parityBase.addingTimeInterval(TimeInterval(offset)),
                ms: offset.isMultiple(of: 2) ? 950 : 1_050
            )
        }
    }

    // MARK: - P0 parity fence

    func testEmptyRRSamplesLeaveBothLanesElementIdenticalToThePinnedTimelines() throws {
        let samples = paritySamples()
        let motion = parityMotionEpochs()

        let motionBacked = AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: parityStart,
            end: parityEnd,
            restingHR: 60,
            isNap: false,
            motionValidated: true,
            motionEpochs: motion,
            rrSamples: []
        )
        XCTAssertEqual(
            motionBacked,
            expectedParitySegments(prefix: SleepStageSegment.motionReceiptIDPrefix),
            "rr-empty motion lane must match the pre-RR engine exactly"
        )

        let estimate = AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: parityStart,
            end: parityEnd,
            restingHR: 60,
            isNap: false,
            motionValidated: false,
            motionEpochs: [],
            rrSamples: [],
            allowHROnlyEstimate: true
        )
        XCTAssertEqual(
            estimate,
            expectedParitySegments(prefix: SleepStageSegment.hrEstimateIDPrefix),
            "rr-empty estimate lane must match the pre-RR engine exactly"
        )

        // Every pre-existing caller compiles against the defaulted parameters
        // and must observe byte-identical behavior.
        let defaulted = AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: parityStart,
            end: parityEnd,
            restingHR: 60,
            isNap: false,
            motionValidated: true,
            motionEpochs: motion
        )
        XCTAssertEqual(defaulted, motionBacked)

        // The checked entry carries the same defaults and the same parity.
        let checked = try AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: parityStart,
            end: parityEnd,
            restingHR: 60,
            isNap: false,
            motionValidated: true,
            motionEpochs: motion,
            rrSamples: [],
            cooperativeDeadline: .init(
                uptimeNanoseconds: .max,
                monotonicNow: { 0 }
            )
        )
        XCTAssertEqual(checked, motionBacked)
    }

    func testDenseRRLeavesMotionLanePinnedAndHedgesOnlyTheEstimateDeepRun() throws {
        // P3 (design 1.1 step 4) REPLACED the former P1 pin that RR could not
        // change the staged timeline: RR is now a deliberate refinement input.
        // On this fixture's dense UNIFORM tachogram (every epoch's RMSSD ==
        // the night median) the refinements resolve exactly as documented at
        // `hedgedEstimateParityRuns`:
        // - motion lane: bit-identical to the pre-RR pins, ids included — the
        //   deep hedge is estimate-lane only and REM edge admission requires
        //   RMSSD elevation this tachogram never shows;
        // - estimate lane: the deep run falls to light; awake/sws/rem and
        //   every boundary stay pinned, and coverage 1 ≥ 0.90 still mints the
        //   strong-RR estimate prefix (P2, pinned in
        //   AtriaSleepStageRR90TierMintTests).
        let samples = paritySamples()
        let denseRR = denseParityRR()

        let motionBacked = AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: parityStart,
            end: parityEnd,
            restingHR: 60,
            isNap: false,
            motionValidated: true,
            motionEpochs: parityMotionEpochs(),
            rrSamples: denseRR,
            qualifiedRRCoverageFraction: 1
        )
        XCTAssertEqual(
            motionBacked,
            expectedParitySegments(prefix: SleepStageSegment.motionReceiptIDPrefix),
            "dense RR must leave the motion lane element-identical to the pre-RR pins"
        )

        let estimate = try AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: parityStart,
            end: parityEnd,
            restingHR: 60,
            isNap: false,
            motionValidated: false,
            motionEpochs: [],
            rrSamples: denseRR,
            qualifiedRRCoverageFraction: 1,
            allowHROnlyEstimate: true,
            cooperativeDeadline: .init(
                uptimeNanoseconds: .max,
                monotonicNow: { 0 }
            )
        )
        XCTAssertEqual(
            estimate,
            expectedParitySegments(prefix: SleepStageSegment.hrEstimateStrongRRIDPrefix,
                                   runs: hedgedEstimateParityRuns),
            "estimate lane under a uniform tachogram: exactly the deep run is hedged to light; awake stays bit-identical"
        )
    }

    // MARK: - P1 per-epoch RR validity

    private static let probeBase = Date(timeIntervalSince1970: 1_800_000_000)
    private static let probeDurationSeconds = 30 * 60

    private var probeEnd: Date {
        Self.probeBase.addingTimeInterval(TimeInterval(Self.probeDurationSeconds))
    }

    private func probeHeartSamples() -> [AtriaSleepWakeResearch.HeartSample] {
        stride(from: 0, through: Self.probeDurationSeconds, by: 5).map {
            AtriaSleepWakeResearch.HeartSample(
                t: Self.probeBase.addingTimeInterval(TimeInterval($0)),
                bpm: 62
            )
        }
    }

    private func alternatingProbeRR() -> [AtriaSleepWakeResearch.RRSample] {
        stride(from: 0, through: Self.probeDurationSeconds, by: 1).map {
            AtriaSleepWakeResearch.RRSample(
                t: Self.probeBase.addingTimeInterval(TimeInterval($0)),
                ms: $0.isMultiple(of: 2) ? 950 : 1_050
            )
        }
    }

    func testRRFeatureArithmeticMatchesClosedFormsOnSyntheticBeats() throws {
        // Alternating 950/1050 ms at 1 Hz: every 30-second epoch holds 31
        // in-epoch beats (16 at 950), so the exact in-epoch median is 950 and
        // RMSSD of the ±100 ms successive differences is exactly 100.
        let alternating = AtriaSleepWakeResearch.rrFeatureDiagnosticsForTesting(
            samples: probeHeartSamples(),
            rrSamples: alternatingProbeRR(),
            start: Self.probeBase,
            end: probeEnd
        )
        XCTAssertEqual(alternating.count, 60)
        XCTAssertTrue(alternating.allSatisfy(\.rrEpochValid))
        for epoch in alternating {
            XCTAssertEqual(epoch.rrMedianMs, 950)
            XCTAssertEqual(epoch.rrRMSSDLocal, 100)
        }

        // A constant 1000 ms tachogram smooths to 1000 at both sigmas, so the
        // difference-of-Gaussians is zero everywhere.
        let constantRR = stride(from: 0, through: Self.probeDurationSeconds, by: 1).map {
            AtriaSleepWakeResearch.RRSample(
                t: Self.probeBase.addingTimeInterval(TimeInterval($0)),
                ms: 1_000
            )
        }
        let constant = AtriaSleepWakeResearch.rrFeatureDiagnosticsForTesting(
            samples: probeHeartSamples(),
            rrSamples: constantRR,
            start: Self.probeBase,
            end: probeEnd
        )
        XCTAssertEqual(constant.count, 60)
        for epoch in constant {
            XCTAssertTrue(epoch.rrEpochValid)
            XCTAssertEqual(epoch.rrMedianMs, 1_000)
            XCTAssertEqual(epoch.rrRMSSDLocal, 0)
            XCTAssertEqual(try XCTUnwrap(epoch.rrShortSmooth), 1_000, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(epoch.rrLongSmooth), 1_000, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(epoch.rrDoG), 0, accuracy: 1e-9)
        }
    }

    func testSparseRREpochKeepsNilFeaturesAndNeverBorrowsFromDenseNeighbors() {
        // Remove every beat inside the [600, 630] epoch. Its neighbors stay
        // dense; the holed epoch itself must stay invalid with nil features —
        // RR evidence is never interpolated or borrowed across epochs.
        let holed = alternatingProbeRR().filter { sample in
            let offset = sample.t.timeIntervalSince(Self.probeBase)
            return !(offset >= 600 && offset <= 630)
        }
        let features = AtriaSleepWakeResearch.rrFeatureDiagnosticsForTesting(
            samples: probeHeartSamples(),
            rrSamples: holed,
            start: Self.probeBase,
            end: probeEnd
        )
        let holedEpoch = features.first {
            Int($0.start.timeIntervalSince(Self.probeBase)) == 600
        }
        XCTAssertEqual(holedEpoch?.rrEpochValid, false)
        XCTAssertNil(holedEpoch?.rrMedianMs)
        XCTAssertNil(holedEpoch?.rrRMSSDLocal)
        XCTAssertNil(holedEpoch?.rrShortSmooth)
        XCTAssertNil(holedEpoch?.rrLongSmooth)
        XCTAssertNil(holedEpoch?.rrDoG)

        let neighborBefore = features.first {
            Int($0.start.timeIntervalSince(Self.probeBase)) == 570
        }
        let neighborAfter = features.first {
            Int($0.start.timeIntervalSince(Self.probeBase)) == 660
        }
        XCTAssertEqual(neighborBefore?.rrEpochValid, true)
        XCTAssertEqual(neighborAfter?.rrEpochValid, true)
    }

    func testFifteenQualifiedBeatsInsideTheExactEpochIsTheValidityBoundary() {
        func holedEpochFeature(beats: Int) -> AtriaSleepWakeResearch.RRFeatureDiagnostics? {
            var rr = alternatingProbeRR().filter { sample in
                let offset = sample.t.timeIntervalSince(Self.probeBase)
                return !(offset >= 600 && offset <= 630)
            }
            for index in 0..<beats {
                rr.append(.init(
                    t: Self.probeBase.addingTimeInterval(601 + Double(index)),
                    ms: 1_000
                ))
            }
            return AtriaSleepWakeResearch.rrFeatureDiagnosticsForTesting(
                samples: probeHeartSamples(),
                rrSamples: rr,
                start: Self.probeBase,
                end: probeEnd
            ).first { Int($0.start.timeIntervalSince(Self.probeBase)) == 600 }
        }

        let atFloor = holedEpochFeature(beats: 15)
        XCTAssertEqual(atFloor?.rrEpochValid, true,
                       "exactly 15 in-epoch qualified beats must validate the epoch")
        XCTAssertEqual(atFloor?.rrMedianMs, 1_000)

        let belowFloor = holedEpochFeature(beats: 14)
        XCTAssertEqual(belowFloor?.rrEpochValid, false,
                       "14 in-epoch beats stay below the floor no matter how dense the neighbors are")
        XCTAssertNil(belowFloor?.rrMedianMs)
    }

    // MARK: - P1 qualified-provenance gather

    private func rrSession(start: Date,
                           end: Date,
                           label: String,
                           rrPoints: [SavedSession.RRPoint]) -> SavedSession {
        SavedSession(
            id: UUID(),
            start: start,
            end: end,
            label: label,
            points: [SavedSession.Point(t: 0, bpm: 60)],
            hrv: nil,
            rrPoints: rrPoints
        )
    }

    func testGatherAdmitsOnlyQualifiedProvenanceAndClampsTheMsBand() throws {
        let start = Self.probeBase
        let end = start.addingTimeInterval(600)

        let qualified2A37 = rrSession(
            start: start,
            end: end,
            label: "2a37",
            rrPoints: (0..<60).map {
                SavedSession.RRPoint(t: Double($0),
                                     ms: 1_000,
                                     source: .standardHeartRateMeasurement2A37)
            }
        )
        let qualifiedV24 = rrSession(
            start: start.addingTimeInterval(120),
            end: end,
            label: "v24",
            rrPoints: (0..<40).map {
                SavedSession.RRPoint(t: Double($0),
                                     ms: 900,
                                     source: .verifiedWhoop4HistoricalV24)
            }
        )
        // One unlabeled legacy beat disqualifies the WHOLE session: the
        // provenance rule is allSatisfy, never a per-beat salvage.
        let mixedLegacy = rrSession(
            start: start,
            end: end,
            label: "mixed",
            rrPoints: [
                SavedSession.RRPoint(t: 1, ms: 1_000,
                                     source: .standardHeartRateMeasurement2A37),
                SavedSession.RRPoint(t: 2, ms: 1_000),
            ]
        )
        // validatedProprietaryRealtime is qualified-STANDARD-adjacent but not
        // a qualified RR transport for local physiology.
        let proprietary = rrSession(
            start: start,
            end: end,
            label: "proprietary",
            rrPoints: (0..<30).map {
                SavedSession.RRPoint(t: Double($0),
                                     ms: 1_000,
                                     source: .validatedProprietaryRealtime)
            }
        )
        // Clamp: 300 and 2000 are inclusive; 299 and 2001 are physiologically
        // rejected even with qualified provenance.
        let clampEdges = rrSession(
            start: start,
            end: end,
            label: "clamp",
            rrPoints: [
                SavedSession.RRPoint(t: 10, ms: 300,
                                     source: .standardHeartRateMeasurement2A37),
                SavedSession.RRPoint(t: 11, ms: 2_000,
                                     source: .standardHeartRateMeasurement2A37),
                SavedSession.RRPoint(t: 12, ms: 299,
                                     source: .standardHeartRateMeasurement2A37),
                SavedSession.RRPoint(t: 13, ms: 2_001,
                                     source: .standardHeartRateMeasurement2A37),
            ]
        )
        // Out-of-window beats from a qualified overlapping session are
        // excluded by the window bound.
        let overlapping = rrSession(
            start: start.addingTimeInterval(-120),
            end: start.addingTimeInterval(60),
            label: "overlap",
            rrPoints: [
                SavedSession.RRPoint(t: 0, ms: 1_000,
                                     source: .standardHeartRateMeasurement2A37),
                SavedSession.RRPoint(t: 150, ms: 1_000,
                                     source: .standardHeartRateMeasurement2A37),
            ]
        )

        let gathered = try SessionStore.sleepStageQualifiedRRInputs(
            from: [qualified2A37, qualifiedV24, mixedLegacy,
                   proprietary, clampEdges, overlapping],
            start: start,
            end: end,
            maximumRows: nil,
            cooperativeDeadline: nil
        )

        // 60 (2A37) + 40 (V24) + 2 (clamp edges) + 1 (in-window overlap beat).
        XCTAssertEqual(gathered.rrSamples.count, 103)
        XCTAssertEqual(
            gathered.qualifiedRRCoverageFraction,
            103.0 / 600.0,
            accuracy: 1e-12,
            "coverage uses the auto-confirm samples-per-second convention over the window"
        )
        XCTAssertFalse(gathered.rrSamples.contains { $0.ms < 300 || $0.ms > 2_000 })
        XCTAssertFalse(gathered.rrSamples.contains { $0.t < start || $0.t > end })
        XCTAssertTrue(gathered.rrSamples.contains { $0.ms == 900 },
                      "verified WHOOP4 historical V24 beats are qualified")

        let checked = try SessionStore.sleepStageQualifiedRRInputs(
            from: [qualified2A37, qualifiedV24, mixedLegacy,
                   proprietary, clampEdges, overlapping],
            start: start,
            end: end,
            maximumRows: nil,
            cooperativeDeadline: .init(
                uptimeNanoseconds: .max,
                monotonicNow: { 0 }
            )
        )
        XCTAssertEqual(checked.rrSamples, gathered.rrSamples)
        XCTAssertEqual(checked.qualifiedRRCoverageFraction,
                       gathered.qualifiedRRCoverageFraction)
    }

    func testGatherCoverageSaturatesAtOneAndOverBudgetInputIsDroppedWhole() throws {
        let start = Self.probeBase
        let end = start.addingTimeInterval(60)
        // 121 qualified beats over 60 seconds: raw samples-per-second exceeds
        // 1 and the fraction must clamp to exactly 1.
        let dense = rrSession(
            start: start,
            end: end,
            label: "dense",
            rrPoints: (0...120).map {
                SavedSession.RRPoint(t: Double($0) * 0.5,
                                     ms: 500,
                                     source: .standardHeartRateMeasurement2A37)
            }
        )
        let saturated = try SessionStore.sleepStageQualifiedRRInputs(
            from: [dense],
            start: start,
            end: end,
            maximumRows: nil,
            cooperativeDeadline: nil
        )
        XCTAssertEqual(saturated.rrSamples.count, 121)
        XCTAssertEqual(saturated.qualifiedRRCoverageFraction, 1)

        // RR is a refinement input, never admission evidence: exceeding the
        // row budget drops the RR stream whole (empty, zero coverage) so the
        // night still stages under its HR-only rules; it must not truncate
        // beats into a fake-but-plausible tachogram.
        let overBudget = try SessionStore.sleepStageQualifiedRRInputs(
            from: [dense],
            start: start,
            end: end,
            maximumRows: 100,
            cooperativeDeadline: nil
        )
        XCTAssertTrue(overBudget.rrSamples.isEmpty)
        XCTAssertEqual(overBudget.qualifiedRRCoverageFraction, 0)

        // At exactly the budget the gather keeps the full stream.
        let atBudget = try SessionStore.sleepStageQualifiedRRInputs(
            from: [dense],
            start: start,
            end: end,
            maximumRows: 121,
            cooperativeDeadline: nil
        )
        XCTAssertEqual(atBudget.rrSamples.count, 121)
    }

    // MARK: - P1 diagnostics ledger

    func testRRInputNeverPerturbsSampleVisitsAndRRVisitsIsMonotonicAndDeterministic() {
        let start = Self.probeBase
        let durationSeconds = 60 * 60
        let end = start.addingTimeInterval(TimeInterval(durationSeconds))
        let samples = stride(from: 0, through: durationSeconds, by: 5).map {
            AtriaSleepWakeResearch.HeartSample(
                t: start.addingTimeInterval(TimeInterval($0)),
                bpm: 62
            )
        }
        let motion = (0..<(durationSeconds / 30)).map { index -> AtriaRecoveredMotionEpoch in
            let epochStart = start.addingTimeInterval(Double(index) * 30)
            return AtriaRecoveredMotionEpoch(
                start: epochStart,
                end: min(end, epochStart.addingTimeInterval(30)),
                rows: 15,
                validatedRows: 15,
                stillnessRatio: 1,
                movementIntensity: 0,
                p95VectorDelta: 0,
                maximumGapSeconds: 2,
                measurementValidated: true,
                lowMotionQualified: true,
                reason: "rr-diagnostics-fixture"
            )
        }
        func rr(strideSeconds: Int) -> [AtriaSleepWakeResearch.RRSample] {
            stride(from: 0, through: durationSeconds, by: strideSeconds).map {
                AtriaSleepWakeResearch.RRSample(
                    t: start.addingTimeInterval(TimeInterval($0)),
                    ms: 1_000
                )
            }
        }
        func diagnostics(rrSamples: [AtriaSleepWakeResearch.RRSample])
            -> AtriaSleepWakeResearch.FallbackStageDiagnostics
        {
            AtriaSleepWakeResearch.fallbackStageDiagnostics(
                samples: samples,
                start: start,
                end: end,
                restingHR: 60,
                isNap: false,
                motionValidated: true,
                motionEpochs: motion,
                rrSamples: rrSamples
            )
        }

        let empty = diagnostics(rrSamples: [])
        let sparse = diagnostics(rrSamples: rr(strideSeconds: 2))
        let dense = diagnostics(rrSamples: rr(strideSeconds: 1))

        XCTAssertFalse(empty.segments.isEmpty)
        XCTAssertEqual(empty.rrVisits, 0,
                       "an rr-empty run must record zero RR work")
        XCTAssertEqual(sparse.sampleVisits, empty.sampleVisits,
                       "RR work must live in its own ledger, never in the pinned sampleVisits")
        XCTAssertEqual(dense.sampleVisits, empty.sampleVisits)
        XCTAssertGreaterThan(sparse.rrVisits, 0)
        XCTAssertGreaterThan(dense.rrVisits, sparse.rrVisits,
                             "a denser tachogram must record strictly more RR inspections")
        XCTAssertEqual(diagnostics(rrSamples: rr(strideSeconds: 1)).rrVisits,
                       dense.rrVisits,
                       "the RR work receipt must be deterministic")

        // The staged timelines stay identical across every RR density on THIS
        // fixture: it is motion-backed with full validated motion (the P3
        // deep hedge is estimate-lane only) and its constant-1000 ms
        // tachogram has zero RMSSD everywhere (REM edge admission requires
        // elevation strictly above the night median, and 0 > 0 never holds).
        XCTAssertEqual(sparse.segments, empty.segments)
        XCTAssertEqual(dense.segments, empty.segments)
    }
}
