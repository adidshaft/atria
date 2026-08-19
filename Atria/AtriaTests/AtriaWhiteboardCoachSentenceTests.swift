import XCTest
import SwiftUI
@testable import Atria

/// Assessment §13.3 (2026-08-14): the daily coach sentence speaks the
/// whiteboard's vocabulary — personal HRV/RHR bands versus yesterday's
/// measured TRIMP. The Recovery→9–17 kernel is untouched; these tests pin the
/// sentence authority's fail-closed tiers and its band logic.
final class AtriaWhiteboardCoachSentenceTests: XCTestCase {
    private let kernel = Coach.Guidance(headline: "kernel headline",
                                        detail: "kernel detail",
                                        color: .blue,
                                        target: 13.0,
                                        state: "ready",
                                        reason: "strain_below_frozen_daily_target")

    private func trustedBaseline(restingHR: Int = 55, hrv: Int = 58) -> AtriaBaselineTargetSnapshot {
        var baseline = PersonalBaseline()
        let start = Date().addingTimeInterval(-15 * 86_400)
        for day in 0..<16 {
            baseline.learn(fromResting: restingHR + day % 2,
                           hrv: hrv + day % 3,
                           at: start.addingTimeInterval(Double(day) * 86_400),
                           overnight: true)
        }
        return AtriaBaselineTargetSnapshot(baseline)
    }

    /// A baseline where resting HR matured but HRV never can — the 2026-08-19
    /// field device had HRV on 1 of 43 days, because RR dropouts prevent a
    /// five-minute window from forming, so `hrvTrusted` would never flip.
    private func restingOnlyBaseline(restingHR: Int = 55) -> AtriaBaselineTargetSnapshot {
        var baseline = PersonalBaseline()
        let start = Date().addingTimeInterval(-15 * 86_400)
        for day in 0..<16 {
            // hrv: 0 is the "no HRV this night" sentinel — `learn` records
            // rmssd only when hrv > 0, so this matures the resting band alone.
            baseline.learn(fromResting: restingHR + day % 2,
                           hrv: 0,
                           at: start.addingTimeInterval(Double(day) * 86_400),
                           overnight: true)
        }
        return AtriaBaselineTargetSnapshot(baseline)
    }

    /// Field report 2026-08-19, item 13. The whiteboard withheld ALL guidance
    /// until BOTH baselines matured. On a strap that cannot deliver HRV that is
    /// permanent silence, not calibration — the wearer reads "Calibrating your
    /// baseline · 1 of 14 nights" forever while a usable resting band sits there.
    func testMatureRestingBandGuidesWhileHRVIsStillCalibrating() throws {
        let baseline = restingOnlyBaseline()
        try XCTSkipUnless(baseline.restingTrusted && !baseline.hrvTrusted,
                          "fixture must be resting-trusted and HRV-untrusted")

        let rewritten = AtriaWhiteboardCoachSentence.rewrite(
            kernel: kernel,
            context: .init(hrvMS: nil,
                           restingHR: 55,
                           baseline: baseline,
                           yesterdayTRIMP: 120,
                           yesterdayStrainDisplay: 12.0))

        XCTAssertNotEqual(rewritten.reason, "whiteboard_calibrating",
                          "a mature resting band must produce guidance, not silence")
        XCTAssertTrue(rewritten.reason.hasSuffix("_resting_only"))
        XCTAssertTrue(rewritten.detail.contains("resting HR only"),
                      "it must disclose that HRV did not contribute")
        XCTAssertFalse(rewritten.detail.contains("HRV is below"),
                       "it must never claim an HRV reading it does not have")
        XCTAssertEqual(rewritten.target, kernel.target,
                       "the kernel target survives when a real band backs it")
    }

    /// An elevated resting HR still earns the lighter-day call on its own.
    func testRestingOnlyLaneStillCallsAnElevatedRestingHeartRate() throws {
        let baseline = restingOnlyBaseline()
        try XCTSkipUnless(baseline.restingTrusted && !baseline.hrvTrusted)
        let rewritten = AtriaWhiteboardCoachSentence.rewrite(
            kernel: kernel,
            context: .init(hrvMS: nil,
                           restingHR: 75,
                           baseline: baseline,
                           yesterdayTRIMP: 120,
                           yesterdayStrainDisplay: nil))
        XCTAssertEqual(rewritten.reason, "whiteboard_lighter_resting_only")
        XCTAssertTrue(rewritten.detail.contains("Resting HR is above your typical band"))
        XCTAssertTrue(rewritten.detail.contains("resting HR only"))
    }

    /// With NEITHER band mature the original calibrating tier is unchanged.
    func testNoMatureBandStillCalibrates() {
        let rewritten = AtriaWhiteboardCoachSentence.rewrite(
            kernel: kernel,
            context: .init(hrvMS: 58,
                           restingHR: 55,
                           baseline: AtriaBaselineTargetSnapshot(PersonalBaseline()),
                           yesterdayTRIMP: 120,
                           yesterdayStrainDisplay: 12.0))
        XCTAssertEqual(rewritten.reason, "whiteboard_calibrating")
        XCTAssertNil(rewritten.target)
    }

    func testUntrustedBaselineCalibratesAndHidesTheTarget() {
        let rewritten = AtriaWhiteboardCoachSentence.rewrite(
            kernel: kernel,
            context: .init(hrvMS: 58,
                           restingHR: 55,
                           baseline: AtriaBaselineTargetSnapshot(PersonalBaseline()),
                           yesterdayTRIMP: 120,
                           yesterdayStrainDisplay: 12.0))
        XCTAssertEqual(rewritten.reason, "whiteboard_calibrating")
        XCTAssertNil(rewritten.target,
                     "an untrusted band must not ship a numeric strain target")
        XCTAssertEqual(rewritten.state, kernel.state,
                       "the kernel's state survives the sentence rewrite")
        XCTAssertTrue(rewritten.detail.contains("of 14 nights"))
    }

    func testTrustedBandsWithUnmeasuredMorningWaits() {
        let rewritten = AtriaWhiteboardCoachSentence.rewrite(
            kernel: kernel,
            context: .init(hrvMS: nil,
                           restingHR: nil,
                           baseline: trustedBaseline(),
                           yesterdayTRIMP: 120,
                           yesterdayStrainDisplay: 12.0))
        XCTAssertEqual(rewritten.reason, "whiteboard_awaiting")
        XCTAssertEqual(rewritten.target, kernel.target,
                       "waiting on today's numbers keeps the kernel's frozen target")
    }

    func testInsideBandsRecommendsMatchingYesterdayTRIMP() {
        let rewritten = AtriaWhiteboardCoachSentence.rewrite(
            kernel: kernel,
            context: .init(hrvMS: 59,
                           restingHR: 55,
                           baseline: trustedBaseline(),
                           yesterdayTRIMP: 188.4,
                           yesterdayStrainDisplay: 15.0))
        XCTAssertEqual(rewritten.reason, "whiteboard_match")
        XCTAssertTrue(rewritten.detail.contains("188 TRIMP"),
                      "yesterday's measured TRIMP is the reference, got: \(rewritten.detail)")
        XCTAssertEqual(rewritten.target, kernel.target)
    }

    func testSuppressedHRVRecommendsLighterThanYesterday() {
        // Baseline lnRMSSD center ≈ ln(59); 40 ms is far below one personal SD.
        let rewritten = AtriaWhiteboardCoachSentence.rewrite(
            kernel: kernel,
            context: .init(hrvMS: 40,
                           restingHR: 55,
                           baseline: trustedBaseline(),
                           yesterdayTRIMP: 188.4,
                           yesterdayStrainDisplay: 15.0))
        XCTAssertEqual(rewritten.reason, "whiteboard_lighter")
        XCTAssertEqual(rewritten.headline, "Take today lighter than yesterday")
        XCTAssertTrue(rewritten.detail.contains("HRV is below your typical band"))
        XCTAssertTrue(rewritten.detail.contains("go easier than yesterday's 188 TRIMP"),
                      "got: \(rewritten.detail)")
    }

    func testElevatedRHRFallsBackToStrainSkinWhenNoTRIMPTruth() {
        let rewritten = AtriaWhiteboardCoachSentence.rewrite(
            kernel: kernel,
            context: .init(hrvMS: 59,
                           restingHR: 70,
                           baseline: trustedBaseline(),
                           yesterdayTRIMP: nil,
                           yesterdayStrainDisplay: 12.4))
        XCTAssertEqual(rewritten.reason, "whiteboard_lighter")
        XCTAssertTrue(rewritten.detail.contains("Resting HR is above your typical band"))
        XCTAssertTrue(rewritten.detail.contains("Strain 12.4"),
                      "legacy days fall back to the display skin, got: \(rewritten.detail)")
    }

    func testInsideBandsWithNoYesterdayEvidenceGoesByFeel() {
        let rewritten = AtriaWhiteboardCoachSentence.rewrite(
            kernel: kernel,
            context: .init(hrvMS: 59,
                           restingHR: 55,
                           baseline: trustedBaseline(),
                           yesterdayTRIMP: nil,
                           yesterdayStrainDisplay: nil))
        XCTAssertEqual(rewritten.headline, "Inside your typical bands")
        XCTAssertTrue(rewritten.detail.contains("no strain recorded yesterday"))
    }
}
