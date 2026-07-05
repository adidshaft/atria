import XCTest
@testable import Atria

/// Coverage for the pre-workout target picker's math (gap spec c): zone ->
/// strain-band mapping, the ease/hold/build cue, guidance fallback, and the
/// `AtriaWorkoutSession` persistence surface -- all pure, independent of the
/// live SwiftUI view and its connected stores.
final class AtriaWorkoutTargetTests: XCTestCase {
    func testWorkoutTargetPickerZoneMapsToStrainBand() {
        // Bands are built from HRZone.lowerFraction * 21 (the same 0...21
        // strain ceiling the live HUD already uses), one zone to the next.
        XCTAssertEqual(AtriaWorkoutTargetMath.strainBand(for: .rest), 0.0...(0.50 * 21))
        XCTAssertEqual(AtriaWorkoutTargetMath.strainBand(for: .aerobic), (0.70 * 21)...(0.80 * 21))
        XCTAssertEqual(AtriaWorkoutTargetMath.strainBand(for: .max), (0.90 * 21)...21.0)

        // Representative target is the band midpoint.
        let aerobicBand = AtriaWorkoutTargetMath.strainBand(for: .aerobic)
        let expectedMidpoint = ((aerobicBand.lowerBound + aerobicBand.upperBound) / 2 * 10).rounded() / 10
        XCTAssertEqual(AtriaWorkoutTargetMath.strainTarget(for: .aerobic), expectedMidpoint)
    }

    func testWorkoutSessionPersistsUserStrainTarget() {
        var session = AtriaWorkoutSession(start: Date())
        XCTAssertNil(session.targetChoice, "unset session defaults to no override")

        session = AtriaWorkoutSession(start: Date(), targetStrain: 14.5)
        XCTAssertEqual(session.targetChoice, .strain(14.5))

        session = AtriaWorkoutSession(start: Date(), targetZone: HRZone.anaerobic.rawValue)
        XCTAssertEqual(session.targetChoice, .zone(HRZone.anaerobic.rawValue))
    }

    func testWorkoutTargetCueEaseHoldPushBoundaries() {
        // No target at all: still "building", never a fabricated cue.
        XCTAssertEqual(AtriaWorkoutTargetMath.cue(strain: 10, target: nil), "building")

        // Below target: build.
        XCTAssertEqual(AtriaWorkoutTargetMath.cue(strain: 9.9, target: 10), "build")
        // At target: hold.
        XCTAssertEqual(AtriaWorkoutTargetMath.cue(strain: 10, target: 10), "hold")
        // Just under the ease threshold (target + 1.0): still hold.
        XCTAssertEqual(AtriaWorkoutTargetMath.cue(strain: 10.99, target: 10), "hold")
        // At the ease threshold: ease.
        XCTAssertEqual(AtriaWorkoutTargetMath.cue(strain: 11, target: 10), "ease")
        XCTAssertEqual(AtriaWorkoutTargetMath.cue(strain: 15, target: 10), "ease")
    }

    func testWorkoutTargetDefaultsToGuidanceWhenUnset() {
        XCTAssertEqual(AtriaWorkoutTargetMath.effectiveTarget(choice: nil, guidanceTarget: 12.0), 12.0)
        XCTAssertNil(AtriaWorkoutTargetMath.effectiveTarget(choice: nil, guidanceTarget: nil))

        // An explicit strain choice always wins over guidance.
        XCTAssertEqual(AtriaWorkoutTargetMath.effectiveTarget(choice: .strain(16.0), guidanceTarget: 12.0), 16.0)

        // A zone choice resolves to that zone's band midpoint, ignoring guidance.
        XCTAssertEqual(AtriaWorkoutTargetMath.effectiveTarget(choice: .zone(HRZone.fatBurn.rawValue), guidanceTarget: 12.0),
                       AtriaWorkoutTargetMath.strainTarget(for: .fatBurn))
    }
}
