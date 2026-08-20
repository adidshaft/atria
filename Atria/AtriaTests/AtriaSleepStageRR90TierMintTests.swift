import XCTest
@testable import Atria

/// P2 of the 2026-08-20 sleep-stage RR track (design 1.2): the strong-RR
/// display-confidence tier is an id PREFIX minted at the estimate lane's
/// merge, never a record-level flag.
///
/// Pinned here:
/// - the mint boundary is qualified-RR coverage ≥ 0.90, INCLUSIVE at exactly
///   0.90 (the same grammar as the 0.60 admission floors);
/// - the tier changes only the minted prefix — the staged boundaries and
///   stages are element-identical across every coverage value while the
///   decision rules stay unwired;
/// - the motion lane's prefix never moves (so
///   `hasTimeAlignedResearchStageReceipt` semantics are untouched);
/// - coverage is never admission evidence: it cannot open the estimate lane
///   without the explicit opt-in (no third escape past
///   `motionBacked || allowHROnlyEstimate`).
final class AtriaSleepStageRR90TierMintTests: XCTestCase {
    // Post-2026-08-06 time base (same anchor the P0/P1 RR suites use).
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static let durationSeconds = 4 * 60 * 60

    private var start: Date { Self.base }
    private var end: Date {
        Self.base.addingTimeInterval(TimeInterval(Self.durationSeconds))
    }

    private func denseHeartSamples() -> [AtriaSleepWakeResearch.HeartSample] {
        stride(from: 0, through: Self.durationSeconds, by: 5).map { second in
            AtriaSleepWakeResearch.HeartSample(
                t: Self.base.addingTimeInterval(TimeInterval(second)),
                bpm: 61 + ((second / 30).isMultiple(of: 10) ? 1 : 0)
            )
        }
    }

    private func fullCoverageMotionEpochs() -> [AtriaRecoveredMotionEpoch] {
        (0..<(Self.durationSeconds / 30)).map { index in
            let epochStart = Self.base.addingTimeInterval(Double(index) * 30)
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
                reason: "rr90-mint-fixture"
            )
        }
    }

    private func estimateLaneSegments(
        coverage: Double
    ) -> [SleepStageSegment] {
        AtriaSleepWakeResearch.stageSegments(
            samples: denseHeartSamples(),
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: false,
            motionEpochs: [],
            rrSamples: [],
            qualifiedRRCoverageFraction: coverage,
            allowHROnlyEstimate: true
        )
    }

    /// The timeline with provenance erased: whatever the tier mints, the
    /// staged content (boundaries, stages, per-segment id remainders) must
    /// be byte-identical across coverage values.
    private func contentFingerprint(
        _ segments: [SleepStageSegment],
        strippingPrefix prefix: String
    ) -> [String] {
        segments.map { segment in
            XCTAssertTrue(segment.id.hasPrefix(prefix),
                          "unexpected prefix on \(segment.id)")
            let remainder = String(segment.id.dropFirst(prefix.count))
            return "\(remainder)|\(segment.start.timeIntervalSince1970)|" +
                "\(segment.end.timeIntervalSince1970)|\(segment.stage.rawValue)"
        }
    }

    // MARK: - The 0.90 boundary (inclusive, ≥0.60-floor grammar)

    func testCoverageAtExactlyPointNineMintsTheStrongRREstimatePrefix() {
        let strong = estimateLaneSegments(coverage: 0.90)
        XCTAssertFalse(strong.isEmpty,
                       "dense HR must stage on the deliberate estimate lane")
        XCTAssertTrue(strong.allSatisfy {
            $0.id.hasPrefix(SleepStageSegment.hrEstimateStrongRRIDPrefix)
        }, "coverage exactly 0.90 is INSIDE the strong tier (inclusive boundary)")
        XCTAssertFalse(strong.contains {
            $0.id.hasPrefix(SleepStageSegment.motionReceiptIDPrefix)
        }, "the estimate lane must never mint the motion receipt")

        // The strong tier is still estimate provenance at the choke point,
        // and it is never the plain-v1 prefix.
        XCTAssertTrue(SleepStageSegment.allHREstimateProvenance(strong))
        XCTAssertFalse(strong.contains {
            $0.id.hasPrefix(SleepStageSegment.hrEstimateIDPrefix)
        })
    }

    func testCoverageBelowPointNineKeepsThePlainEstimatePrefix() {
        for coverage in [0.899_999_999, 0.89, 0.60, 0.0] {
            let plain = estimateLaneSegments(coverage: coverage)
            XCTAssertFalse(plain.isEmpty)
            XCTAssertTrue(plain.allSatisfy {
                $0.id.hasPrefix(SleepStageSegment.hrEstimateIDPrefix)
            }, "coverage \(coverage) must stay in the plain estimate tier")
            XCTAssertFalse(plain.contains {
                $0.id.hasPrefix(SleepStageSegment.hrEstimateStrongRRIDPrefix)
            })
        }
    }

    func testTierChangesOnlyThePrefixNeverTheStagedTimeline() {
        let plain = estimateLaneSegments(coverage: 0.89)
        let strong = estimateLaneSegments(coverage: 0.90)
        let saturated = estimateLaneSegments(coverage: 1)

        XCTAssertEqual(
            contentFingerprint(plain,
                               strippingPrefix: SleepStageSegment.hrEstimateIDPrefix),
            contentFingerprint(strong,
                               strippingPrefix: SleepStageSegment.hrEstimateStrongRRIDPrefix),
            "the tier is a display-confidence receipt: boundaries, stages, and id remainders are identical"
        )
        XCTAssertEqual(
            contentFingerprint(strong,
                               strippingPrefix: SleepStageSegment.hrEstimateStrongRRIDPrefix),
            contentFingerprint(saturated,
                               strippingPrefix: SleepStageSegment.hrEstimateStrongRRIDPrefix)
        )
    }

    // MARK: - Lane isolation

    func testMotionLanePrefixIsUnchangedByAnyCoverageValue() {
        for coverage in [0.0, 0.90, 1.0] {
            let stages = AtriaSleepWakeResearch.stageSegments(
                samples: denseHeartSamples(),
                start: start,
                end: end,
                restingHR: 60,
                isNap: false,
                motionValidated: true,
                motionEpochs: fullCoverageMotionEpochs(),
                rrSamples: [],
                qualifiedRRCoverageFraction: coverage
            )
            XCTAssertFalse(stages.isEmpty)
            XCTAssertTrue(stages.allSatisfy {
                $0.id.hasPrefix(SleepStageSegment.motionReceiptIDPrefix)
            }, "the motion lane's prefix never moves — the time-aligned receipt semantics stay pinned")
            XCTAssertFalse(stages.contains { segment in
                SleepStageSegment.hrEstimateIDPrefixes.contains {
                    segment.id.hasPrefix($0)
                }
            })
        }
    }

    func testStrongRRCoverageIsNeverAdmissionEvidence() {
        // No motion, no opt-in: perfect claimed coverage must not open a
        // third escape past `motionBacked || allowHROnlyEstimate`.
        let withheld = AtriaSleepWakeResearch.stageSegments(
            samples: denseHeartSamples(),
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: false,
            motionEpochs: [],
            rrSamples: [],
            qualifiedRRCoverageFraction: 1
        )
        XCTAssertTrue(withheld.isEmpty,
                      "coverage is a display-confidence input, never admission evidence")
    }

    // MARK: - Checked lane parity

    func testCheckedLaneMintsTheSameTierAsTheUncheckedLane() throws {
        let unchecked = estimateLaneSegments(coverage: 0.90)
        let checked = try AtriaSleepWakeResearch.stageSegments(
            samples: denseHeartSamples(),
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: false,
            motionEpochs: [],
            rrSamples: [],
            qualifiedRRCoverageFraction: 0.90,
            allowHROnlyEstimate: true,
            cooperativeDeadline: .init(
                uptimeNanoseconds: .max,
                monotonicNow: { 0 }
            )
        )
        XCTAssertEqual(checked, unchecked,
                       "deadline-checked staging must mint the identical tier")
    }
}
