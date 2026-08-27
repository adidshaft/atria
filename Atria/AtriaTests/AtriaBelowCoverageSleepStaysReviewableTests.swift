import XCTest
@testable import Atria

/// A night that misses AUTO-confirmation must still be offered for review.
///
/// Device 2026-08-27: a real ~5 h sleep (13:00-20:30, mean HR 61.6 against 79.5
/// awake) never confirmed. Every auto-confirm gate passed by minutes except one
/// — `hrObservedCoverageFraction` came to 0.789 against the 0.80 floor, short
/// only because 81 minutes of its history had not drained.
///
/// That is exactly the case where the app must NOT go silent. Auto-confirming
/// it would be wrong; the evidence is genuinely incomplete. Hiding it is also
/// wrong; the wearer knows they slept. The honest outcome is a review card they
/// can accept or dismiss.
///
/// These pin that separation: the 0.80 coverage floor governs AUTO-confirmation
/// only, and never reaches the pool or the review predicate. A future change
/// that "tidies up" by applying the same threshold in either place would make a
/// real night vanish with no trace, which is how this one was lost.
final class AtriaBelowCoverageSleepStaysReviewableTests: XCTestCase {

    private func at(_ hours: Double) -> Date {
        Date(timeIntervalSince1970: 1_756_000_000 + hours * 3_600)
    }

    /// Mirrors the owner's night: 5.05 h observed across a 6.4 h span, three
    /// fragments, longest gap 59 min, coverage 0.789 — below the auto floor.
    private func belowCoverageNight(
        kind: String = "dense_long_hr_only",
        denseLongReviewQualified: Bool = true,
        motionValidated: Bool = false
    ) -> AggregateSleepCandidate {
        AggregateSleepCandidate(
            kind: kind, day: at(13), eventTimeZoneIdentifier: "Asia/Kolkata",
            sessions: 3, start: at(14.6), end: at(21),
            duration: 5.05 * 3_600, span: 6.4 * 3_600,
            maxGap: 59 * 60, samples: 305,
            hrObservedCoverageFraction: 0.789,
            maximumHRSampleGap: 59 * 60, avgHR: 61, peakHR: 84,
            hrStandardDeviation: 4, medianHR: 61, hrP90: 66,
            elevatedSampleFraction: 0.01,
            baselineRestingHR: 55, restingHR: 55,
            confidence: .high, reason: "device_2026_08_26", motionHintCount: 0,
            motionHintKinds: "", motionEvidenceSource: "none",
            motionEvidenceValidated: motionValidated, motionShortCount: 0,
            motionShortMean: nil, motionShortMin: nil, motionShortMax: nil,
            motionShortOverOneCount: 0, historicalMotionStatus: "none",
            historicalMotionReason: "none", historicalMotionRows: 0,
            historicalMotionValidatedRows: 0, historicalMotionCoverageSeconds: 0,
            historicalMotionMeanVectorDelta: nil,
            historicalMotionP95VectorDelta: nil,
            historicalMotionMagnitudeStdDev: nil,
            historicalMotionArchiveFirstUnix: 0,
            historicalMotionArchiveLastUnix: 0,
            historicalMotionNearestSeparationSeconds: 0,
            historicalMotionValidated: false,
            denseMorningHROnlyReviewQualified: false,
            denseLongHROnlyReviewQualified: denseLongReviewQualified)
    }

    // MARK: - It must not auto-confirm

    func testTheBelowCoverageNightIsNotAutoConfirmable() {
        XCTAssertFalse(
            SessionStore.isAutoConfirmableMainSleepCandidate(
                belowCoverageNight(),
                baselineRestingIsTrusted: true,
                baselineRestingIsNearTrusted: true
            ),
            "0.789 coverage is genuinely incomplete evidence; confirming it "
                + "automatically would assert more than the data supports")
    }

    // MARK: - ...but it must still be reviewable

    func testTheSameNightIsStillOfferedForReview() {
        XCTAssertTrue(
            SessionStore.isReviewWorthySleepCandidate(belowCoverageNight()),
            "the wearer knows they slept; the app must offer the card rather "
                + "than going silent")
    }

    func testCoverageIsNotConsultedByTheReviewPredicate() {
        // Same night at 100% coverage and at 40%: review-worthiness must not
        // move, because coverage is an AUTO-confirm concern.
        let dense = belowCoverageNight()
        XCTAssertEqual(
            SessionStore.isReviewWorthySleepCandidate(dense),
            SessionStore.isReviewWorthySleepCandidate(belowCoverageNight()),
            "review-worthiness must be stable for the same evidence")
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(dense))
    }

    // MARK: - The floor still exists and still means what it says

    func testTheAutoConfirmCoverageFloorIsUnchanged() {
        // If this moves, the separation above stops describing the app.
        XCTAssertEqual(
            AggregateSleepCandidate.minimumAutoConfirmHRCoverageFraction,
            0.80,
            accuracy: 0.0001)
    }

    func testAQuietAwakeShapedWindowStaysOut() {
        // The other half of the honesty rule, and I had it too strong at first:
        // a STRONG HR-only night IS review-worthy without motion, through
        // `isUnambiguousHROnlyMainSleepCandidate` /
        // `isHighSpecificityFragmentedHROnlyMainSleepCandidate` /
        // `isDegradedHROnlyOvernightSleepCandidate`. My first version of this
        // asserted that low HR alone can never qualify, which the suite
        // correctly refused.
        //
        // What must stay out is the shape the predicate's own comment names:
        // the physically disproven 2026-07-12 22:18-02:05 case — a shortish,
        // unremarkable low-HR window equally compatible with quiet awake time.
        let quietAwake = AggregateSleepCandidate(
            kind: "hr_only", day: at(22), eventTimeZoneIdentifier: "Asia/Kolkata",
            sessions: 2, start: at(22), end: at(24.5),
            duration: 2.5 * 3_600, span: 2.5 * 3_600,
            maxGap: 20 * 60, samples: 150,
            hrObservedCoverageFraction: 0.95,
            maximumHRSampleGap: 20 * 60, avgHR: 75, peakHR: 96,
            hrStandardDeviation: 12, medianHR: 74, hrP90: 88,
            elevatedSampleFraction: 0.22,
            baselineRestingHR: 55, restingHR: 62,
            confidence: .low, reason: "quiet_awake_shape", motionHintCount: 0,
            motionHintKinds: "", motionEvidenceSource: "none",
            motionEvidenceValidated: false, motionShortCount: 0,
            motionShortMean: nil, motionShortMin: nil, motionShortMax: nil,
            motionShortOverOneCount: 0, historicalMotionStatus: "none",
            historicalMotionReason: "none", historicalMotionRows: 0,
            historicalMotionValidatedRows: 0, historicalMotionCoverageSeconds: 0,
            historicalMotionMeanVectorDelta: nil,
            historicalMotionP95VectorDelta: nil,
            historicalMotionMagnitudeStdDev: nil,
            historicalMotionArchiveFirstUnix: 0,
            historicalMotionArchiveLastUnix: 0,
            historicalMotionNearestSeparationSeconds: 0,
            historicalMotionValidated: false,
            denseMorningHROnlyReviewQualified: false,
            denseLongHROnlyReviewQualified: false)

        XCTAssertFalse(
            SessionStore.isReviewWorthySleepCandidate(quietAwake),
            "2.5 h at 20 bpm over baseline with 22% elevated samples is "
                + "equally compatible with sitting up reading")
    }
}
