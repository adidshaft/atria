import XCTest
@testable import Atria

/// P3 of the 2026-08-20 sleep-stage RR track (design 1.1 step 4) — the ONLY
/// behavior-changing engine phase. Everything here pins the two
/// refinement-only rules and their hard fences:
///
/// - Deep hedge (estimate-lane epochs only): a legacy deep call with valid RR
///   must also beat the tightened ceilings (DoG ≤ 1.0, variability ≤ 3.0) and
///   sit strictly BELOW the night-median RMSSD; failed hedges fall to LIGHT —
///   never sws (which display-folds to deep) and never awake.
/// - REM edge admission (recall-widening only, both lanes): an epoch in the
///   documented widened shell of the untouched REM band becomes REM when its
///   local RMSSD is elevated strictly above 1.2× the night median.
/// - Reconcile neutrality: awake decisions never read RR, so awake runs are
///   bit-identical with and without RR on every fixture in this file.
///
/// All fixtures are pure synthetic nights on a post-2026-08-06 time base fed
/// straight into the engine — no store state, no defaults.
final class AtriaSleepStageRRDecisionRefinementTests: XCTestCase {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static let nightSeconds = 4 * 60 * 60

    private var nightStart: Date { Self.base }
    private var nightEnd: Date {
        Self.base.addingTimeInterval(TimeInterval(Self.nightSeconds))
    }

    // MARK: - Comparison helpers

    private struct Run: Equatable, CustomStringConvertible {
        let start: Int
        let end: Int
        let stage: SleepStageKind

        var description: String { "(\(start), \(end), \(stage.rawValue))" }
    }

    private func runs(_ segments: [SleepStageSegment]) -> [Run] {
        segments.map {
            Run(start: Int($0.start.timeIntervalSince(Self.base)),
                end: Int($0.end.timeIntervalSince(Self.base)),
                stage: $0.stage)
        }
    }

    private func awakeRuns(_ segments: [SleepStageSegment]) -> [Run] {
        runs(segments).filter { $0.stage == .awake }
    }

    private func seconds(of stage: SleepStageKind,
                         in segments: [SleepStageSegment]) -> TimeInterval {
        segments.filter { $0.stage == stage }
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    private func stage(at offset: Int,
                       in segments: [SleepStageSegment]) -> SleepStageKind? {
        let t = Self.base.addingTimeInterval(TimeInterval(offset))
        return segments.first { $0.start <= t && t < $0.end }?.stage
    }

    // MARK: - Fixture builders

    private func heartSamples(bpm: (Int) -> Int) -> [AtriaSleepWakeResearch.HeartSample] {
        stride(from: 0, through: Self.nightSeconds, by: 5).map { offset in
            AtriaSleepWakeResearch.HeartSample(
                t: Self.base.addingTimeInterval(TimeInterval(offset)),
                bpm: bpm(offset)
            )
        }
    }

    /// 1 Hz tachogram; alternating ±swing around a mean makes every epoch's
    /// local RMSSD equal exactly the full swing (successive diffs are all
    /// ±swing), so night-median arithmetic is closed-form.
    private func rrSamples(ms: (Int) -> Double) -> [AtriaSleepWakeResearch.RRSample] {
        stride(from: 0, through: Self.nightSeconds, by: 1).map { offset in
            AtriaSleepWakeResearch.RRSample(
                t: Self.base.addingTimeInterval(TimeInterval(offset)),
                ms: ms(offset)
            )
        }
    }

    private func fullMotion() -> [AtriaRecoveredMotionEpoch] {
        (0..<(Self.nightSeconds / 30)).map { index in
            let epochStart = Self.base.addingTimeInterval(Double(index) * 30)
            return AtriaRecoveredMotionEpoch(
                start: epochStart,
                end: min(nightEnd, epochStart.addingTimeInterval(30)),
                rows: 15,
                validatedRows: 15,
                stillnessRatio: 1,
                movementIntensity: 0,
                p95VectorDelta: 0,
                maximumGapSeconds: 2,
                measurementValidated: true,
                lowMotionQualified: true,
                reason: "rr-p3-fixture"
            )
        }
    }

    private func estimateSegments(
        samples: [AtriaSleepWakeResearch.HeartSample],
        rr: [AtriaSleepWakeResearch.RRSample]
    ) -> [SleepStageSegment] {
        AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: nightStart,
            end: nightEnd,
            restingHR: 60,
            isNap: false,
            motionValidated: false,
            motionEpochs: [],
            rrSamples: rr,
            qualifiedRRCoverageFraction: rr.isEmpty ? 0 : 1,
            allowHROnlyEstimate: true
        )
    }

    private func motionSegments(
        samples: [AtriaSleepWakeResearch.HeartSample],
        rr: [AtriaSleepWakeResearch.RRSample]
    ) -> [SleepStageSegment] {
        AtriaSleepWakeResearch.stageSegments(
            samples: samples,
            start: nightStart,
            end: nightEnd,
            restingHR: 60,
            isNap: false,
            motionValidated: true,
            motionEpochs: fullMotion(),
            rrSamples: rr,
            qualifiedRRCoverageFraction: rr.isEmpty ? 0 : 1
        )
    }

    // Constant 61 bpm: delta 1, variability 0, DoG 0 — every epoch sits deep
    // in the legacy deep region AND inside the tightened ceilings, isolating
    // the below-median RMSSD requirement.
    private func deepNightHR() -> [AtriaSleepWakeResearch.HeartSample] {
        heartSamples { _ in 61 }
    }

    // Alternating 67/72 every 5 s: epoch delta ≈ 9.14 (light — above the sws
    // ceiling of 7), local variability ≈ 2.5 (inside the REM edge shell's
    // 2.4 floor but below the legacy band's 3.2), DoG ≈ 0. The whole night is
    // light until RR speaks.
    private func lightNightHR() -> [AtriaSleepWakeResearch.HeartSample] {
        heartSamples { offset in (offset / 5).isMultiple(of: 2) ? 67 : 72 }
    }

    // MARK: - Deep hedge (estimate lane)

    func testEstimateDeepHedgesToLightWhenLocalRMSSDIsNotBelowTheNightMedian() {
        let samples = deepNightHR()

        let before = estimateSegments(samples: samples, rr: [])
        XCTAssertEqual(runs(before), [Run(start: 0, end: 14_400, stage: .deep)],
                       "rr-empty baseline: the whole night is a single legacy deep run")

        // Uniform alternating ±40 ms: every epoch's RMSSD is exactly the night
        // median, so the strictly-below-median requirement fails everywhere
        // even though the tightened ceilings (var 0 ≤ 3.0, DoG 0 ≤ 1.0) pass.
        let uniform = rrSamples { offset in offset.isMultiple(of: 2) ? 980 : 1_020 }
        let after = estimateSegments(samples: samples, rr: uniform)
        XCTAssertEqual(runs(after), [Run(start: 0, end: 14_400, stage: .light)],
                       "a failed deep hedge falls to LIGHT — not sws, which would display-fold back to deep")
        XCTAssertEqual(seconds(of: .sws, in: after), 0)
        XCTAssertEqual(awakeRuns(after), awakeRuns(before),
                       "awake runs are bit-identical: the hedge is reconcile-neutral")
        XCTAssertEqual(seconds(of: .awake, in: after),
                       seconds(of: .awake, in: before))
    }

    func testEstimateDeepIsRetainedOnlyWhereLocalRMSSDSitsBelowTheNightMedian() {
        let samples = deepNightHR()
        // Baseline swing 60 ms; a mid-night window [3600, 7200) drops to a
        // 20 ms swing around a distinct mean. Night median = 60, so only the
        // low-RMSSD window keeps its deep calls. The distinct means make the
        // two epoch-boundary transition diffs (140 ms into the window, 60 ms
        // out of it) land the boundary epochs deterministically: the entering
        // epoch [3570, 3600] computes RMSSD ≈ 64.3 (not below median → light),
        // the exiting epoch [7170, 7200] ≈ 22.5 (below → deep).
        let windowed = rrSamples { offset in
            if offset >= 3_600, offset < 7_200 {
                return offset.isMultiple(of: 2) ? 890 : 910
            }
            return offset.isMultiple(of: 2) ? 970 : 1_030
        }

        let before = estimateSegments(samples: samples, rr: [])
        let after = estimateSegments(samples: samples, rr: windowed)
        XCTAssertEqual(runs(before), [Run(start: 0, end: 14_400, stage: .deep)])
        XCTAssertEqual(runs(after), [
            Run(start: 0, end: 3_600, stage: .light),
            Run(start: 3_600, end: 7_200, stage: .deep),
            Run(start: 7_200, end: 14_400, stage: .light),
        ], "deep survives the hedge exactly where local RMSSD sits strictly below the night median")
        XCTAssertEqual(awakeRuns(after), awakeRuns(before))
    }

    func testTightenedVariabilityCeilingHedgesDeepEvenWithBelowMedianRMSSD() {
        // Period-5 HR (four 58s then one 66): epoch delta ≈ −0.86/+0.29 and
        // local variability ≈ 3.1–3.25 — inside the LEGACY deep ceiling (3.5)
        // but above the tightened one (3.0). The rr-empty baseline calls the
        // whole night deep; with valid RR every epoch must fail the hedge —
        // including the low-RMSSD window [6000, 9000) whose RMSSD 20 passes
        // the below-median rule but not the variability ceiling. This is the
        // proof the tightened thresholds bind beyond the median rule alone.
        let samples = heartSamples { offset in (offset / 5) % 5 == 4 ? 66 : 58 }
        let windowed = rrSamples { offset in
            if offset >= 6_000, offset < 9_000 {
                return offset.isMultiple(of: 2) ? 890 : 910
            }
            return offset.isMultiple(of: 2) ? 970 : 1_030
        }

        let before = estimateSegments(samples: samples, rr: [])
        let after = estimateSegments(samples: samples, rr: windowed)
        XCTAssertEqual(runs(before), [Run(start: 0, end: 14_400, stage: .deep)])
        XCTAssertEqual(runs(after), [Run(start: 0, end: 14_400, stage: .light)])
        XCTAssertEqual(stage(at: 7_500, in: after), .light,
                       "below-median RMSSD alone cannot rescue a deep call whose variability exceeds the tightened 3.0 ceiling")
        XCTAssertEqual(awakeRuns(after), awakeRuns(before))
    }

    func testMotionLaneDeepIsNeverHedgedRegardlessOfRR() {
        // Identical fixture to the estimate-lane hedge case, but with a full
        // validated motion receipt: motion-validated epochs keep the legacy
        // deep rule verbatim, so the output — ids included — is
        // element-identical with and without a dense tachogram.
        let samples = deepNightHR()
        let uniform = rrSamples { offset in offset.isMultiple(of: 2) ? 980 : 1_020 }

        let before = motionSegments(samples: samples, rr: [])
        let after = motionSegments(samples: samples, rr: uniform)
        XCTAssertEqual(runs(before), [Run(start: 0, end: 14_400, stage: .deep)])
        XCTAssertEqual(after, before,
                       "the deep hedge is estimate-lane only: the motion lane is bit-identical, ids included")
        XCTAssertTrue(after.allSatisfy {
            $0.id.hasPrefix(SleepStageSegment.motionReceiptIDPrefix)
        })
    }

    // MARK: - REM edge admission

    func testRRAdmitsREMOnlyAtTheBandEdgesUnderElevatedLocalRMSSD() {
        let samples = lightNightHR()
        // Baseline swing 40 ms (RMSSD 40 == night median); the window
        // [7200, 8400) swings 200 ms (RMSSD 200 > 1.2 × 40). Only that window
        // clears the elevation bar — the entering boundary epoch [7170, 7200]
        // mixes one 120 ms transition diff into 29 baseline diffs
        // (RMSSD ≈ 45.0 < 48) and stays light, so the REM run is exactly the
        // elevated window.
        let elevated = rrSamples { offset in
            if offset >= 7_200, offset < 8_400 {
                return offset.isMultiple(of: 2) ? 900 : 1_100
            }
            return offset.isMultiple(of: 2) ? 980 : 1_020
        }

        let before = estimateSegments(samples: samples, rr: [])
        XCTAssertEqual(runs(before), [Run(start: 0, end: 14_400, stage: .light)],
                       "rr-empty baseline: variability 2.5 misses the legacy REM band's 3.2 floor, so the night is all light")

        let after = estimateSegments(samples: samples, rr: elevated)
        XCTAssertEqual(runs(after), [
            Run(start: 0, end: 7_200, stage: .light),
            Run(start: 7_200, end: 8_400, stage: .rem),
            Run(start: 8_400, end: 14_400, stage: .light),
        ], "elevated local RMSSD admits REM inside the widened band shell — and nowhere else")
        XCTAssertEqual(awakeRuns(after), awakeRuns(before),
                       "REM edge admission is recall-widening only; awake is untouched")

        // The strengthening is deliberately NOT estimate-lane-gated: the same
        // elevated tachogram admits the same REM run on the motion lane.
        let motionAfter = motionSegments(samples: samples, rr: elevated)
        XCTAssertEqual(runs(motionAfter), runs(after))
    }

    func testElevatedRMSSDNeverConvertsAnAwakeRuleEpochToREM() {
        // The awake-rule guard: the elevated-RMSSD window sits exactly on a
        // block the awake rules own (constant 85 bpm, delta 25 ≥ 18). Awake
        // rules run before any RR branch and never read RR, so the entire
        // timeline — not just awake — is bit-identical with and without the
        // tachogram.
        let samples = heartSamples { offset in
            if offset >= 7_200, offset < 8_400 { return 85 }
            return (offset / 5).isMultiple(of: 2) ? 67 : 72
        }
        let elevatedOverAwake = rrSamples { offset in
            if offset >= 7_200, offset < 8_400 {
                return offset.isMultiple(of: 2) ? 900 : 1_100
            }
            return offset.isMultiple(of: 2) ? 980 : 1_020
        }

        let before = estimateSegments(samples: samples, rr: [])
        let after = estimateSegments(samples: samples, rr: elevatedOverAwake)
        XCTAssertEqual(stage(at: 7_800, in: before), .awake)
        XCTAssertEqual(stage(at: 7_800, in: after), .awake,
                       "hugely elevated RMSSD cannot make REM out of an epoch the awake rules call awake")
        XCTAssertEqual(runs(after), runs(before))
        let awakeSeconds = seconds(of: .awake, in: before)
        XCTAssertGreaterThan(awakeSeconds, 0)
        XCTAssertEqual(seconds(of: .awake, in: after), awakeSeconds)
    }

    // MARK: - Fixture-night before/after delta

    /// The realistic mixed night shared with the parity pins in
    /// AtriaSleepStageRRFeatureTests, staged on the estimate lane before and
    /// after RR. Documented delta under a dense uniform tachogram (every
    /// epoch's RMSSD == the night median, so REM edge admission never fires
    /// and the deep hedge's strictly-below-median requirement fails
    /// everywhere): the deep run (2610, 5370) — and ONLY the deep run — falls
    /// to light. Awake (3270 s across two runs), sws, rem and every boundary
    /// are bit-identical.
    func testMixedFixtureNightDeltaIsExactlyTheDeepRunFallingToLight() {
        let samples = heartSamples { offset in
            switch offset {
            case ..<2_400: return 72
            case ..<5_400: return 62
            case ..<9_000: return 66
            case ..<12_000: return (offset / 5).isMultiple(of: 2) ? 66 : 74
            default: return 85
            }
        }
        let uniform = rrSamples { offset in offset.isMultiple(of: 2) ? 950 : 1_050 }

        let before = estimateSegments(samples: samples, rr: [])
        let after = estimateSegments(samples: samples, rr: uniform)

        XCTAssertEqual(runs(before), [
            Run(start: 0, end: 870, stage: .awake),
            Run(start: 870, end: 2_400, stage: .light),
            Run(start: 2_400, end: 2_610, stage: .sws),
            Run(start: 2_610, end: 5_370, stage: .deep),
            Run(start: 5_370, end: 8_940, stage: .sws),
            Run(start: 8_940, end: 11_100, stage: .rem),
            Run(start: 11_100, end: 12_000, stage: .light),
            Run(start: 12_000, end: 14_400, stage: .awake),
        ])
        XCTAssertEqual(runs(after), [
            Run(start: 0, end: 870, stage: .awake),
            Run(start: 870, end: 2_400, stage: .light),
            Run(start: 2_400, end: 2_610, stage: .sws),
            Run(start: 2_610, end: 5_370, stage: .light),
            Run(start: 5_370, end: 8_940, stage: .sws),
            Run(start: 8_940, end: 11_100, stage: .rem),
            Run(start: 11_100, end: 12_000, stage: .light),
            Run(start: 12_000, end: 14_400, stage: .awake),
        ])

        XCTAssertEqual(seconds(of: .deep, in: before), 2_760)
        XCTAssertEqual(seconds(of: .deep, in: after), 0)
        XCTAssertEqual(awakeRuns(after), awakeRuns(before))
        XCTAssertEqual(seconds(of: .awake, in: after), 3_270)
        XCTAssertEqual(seconds(of: .sws, in: after), seconds(of: .sws, in: before))
        XCTAssertEqual(seconds(of: .rem, in: after), seconds(of: .rem, in: before))
    }
}
