import XCTest
@testable import Atria

/// Pure-logic coverage for the 2026-07-05 Today-surface additions: the
/// shared under/optimal/over zone tints and the daily HR-zone tile text.
final class AtriaTodayTileLogicTests: XCTestCase {

    func testRingAchievementTintChangesOnlyWithRealProgress() {
        XCTAssertEqual(Metrics.ringAchievementTint(fill: nil), .secondary)
        XCTAssertEqual(Metrics.ringAchievementTint(fill: 0.25), .orange)
        XCTAssertEqual(Metrics.ringAchievementTint(fill: 0.60), .yellow)
        XCTAssertEqual(Metrics.ringAchievementTint(fill: 0.999), .yellow)
        XCTAssertEqual(Metrics.ringAchievementTint(fill: 1.0), .green)
        XCTAssertEqual(Metrics.ringAchievementTint(fill: 1.20), .green)
    }

    func testConfirmedEightHourFiveMinuteSleepMeetsEightHourRingGoal() {
        let confirmedSleepSeconds = 29_097.122655034065
        let goalSeconds = 8.0 * 3_600
        let fill = min(max(confirmedSleepSeconds / goalSeconds, 0), 1)

        XCTAssertEqual(fill, 1, accuracy: 1e-12)
        XCTAssertEqual(Metrics.ringAchievementTint(fill: fill), .green)
        XCTAssertEqual(Metrics.sleepDurationZone(confirmedSleepSeconds / 3_600,
                                                 goalHours: 8)?.level,
                       .green)
    }

    // MARK: zoneTint bands

    func testSleepZoneBands() {
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 70), Metrics.electricYellow)
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 84.9), Metrics.electricYellow)
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 85), Metrics.electricGreen)
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 104), Metrics.electricGreen)
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 110), Metrics.electricGreen)
        // Oversleep reads cool, never alarming.
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 125), Metrics.electricStrain)
    }

    func testConfiguredRingZonesOwnRecoveryAndStrainState() {
        let recoveryTarget = AtriaMetricTarget.recovery(greenLower: 80, yellowLower: 50)
        XCTAssertNil(Metrics.recoveryZone(nil, target: recoveryTarget))
        XCTAssertEqual(Metrics.recoveryZone(49, target: recoveryTarget)?.level, .red)
        XCTAssertEqual(Metrics.recoveryZone(70, target: recoveryTarget)?.level, .yellow)
        XCTAssertEqual(Metrics.recoveryZone(80, target: recoveryTarget)?.level, .green)

        XCTAssertNil(Metrics.strainZone(strain: 12, target: nil,
                                        greenBand: 1.5, yellowBand: 3))
        XCTAssertEqual(Metrics.strainZone(strain: 12, target: 10,
                                          greenBand: 1.5, yellowBand: 3)?.level,
                       .yellow)
        XCTAssertEqual(Metrics.strainZone(strain: 12, target: 10,
                                          greenBand: 2.5, yellowBand: 3)?.level,
                       .green)
    }

    func testRingProgressRequiresRealTargetAndUsesDisplayedEvidence() {
        XCTAssertEqual(AtriaRingMetricProjection.strainFill(strain: 8) ?? -1,
                       8.0 / 21.0,
                       accuracy: 0.0001)
        XCTAssertNil(AtriaRingMetricProjection.strainFill(strain: 8, isPending: true))
        XCTAssertNil(AtriaRingMetricProjection.strainTargetProgress(strain: 8, target: nil))
        XCTAssertEqual(AtriaRingMetricProjection.strainTargetProgress(strain: 8, target: 10), 0.8)
        XCTAssertEqual(AtriaRingMetricProjection.strainTargetProgress(strain: 12, target: 10), 1.2)
        XCTAssertNil(AtriaRingMetricProjection.strainTargetFraction(nil))
        XCTAssertEqual(AtriaRingMetricProjection.strainTargetFraction(10) ?? -1,
                       10.0 / 21.0,
                       accuracy: 0.0001)

        XCTAssertEqual(AtriaRingMetricProjection.higherIsBetterProgress(
            value: 46, baseline: 40, baselineIsTrusted: true
        ) ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertNil(AtriaRingMetricProjection.higherIsBetterProgress(
            value: 46, baseline: 40, baselineIsTrusted: false
        ))
        XCTAssertEqual(AtriaRingMetricProjection.lowerIsBetterProgress(
            value: 50, baseline: 55, baselineIsTrusted: true
        ) ?? -1, 1.1, accuracy: 0.0001)

        XCTAssertEqual(AtriaRingMetricProjection.achievementTintHex(fill: nil),
                       AtriaRingMetricProjection.neutralTintHex)
        XCTAssertEqual(AtriaRingMetricProjection.achievementTintHex(fill: 0.8), "#f5d142")
        XCTAssertEqual(AtriaRingMetricProjection.achievementTintHex(fill: 1), "#42f59b")
        XCTAssertEqual(AtriaRingMetricProjection.zoneTintHex(nil),
                       AtriaRingMetricProjection.neutralTintHex)
        XCTAssertEqual(AtriaRingMetricProjection.zoneTintHex(.red), "#ff4f7b")
    }

    func testMeasuredStrainKeepsIdentityColorUntilRecoveryProvidesTarget() {
        let actualFill = AtriaRingMetricProjection.strainFill(strain: 0.43)

        XCTAssertEqual(AtriaRingMetricProjection.strainTint(
            targetProgress: nil,
            actualFill: actualFill
        ), Metrics.electricStrain)
        XCTAssertEqual(AtriaRingMetricProjection.strainTintHex(
            targetProgress: nil,
            actualFill: actualFill
        ), AtriaRingMetricProjection.strainIdentityTintHex)
        XCTAssertEqual(AtriaRingMetricProjection.strainTint(
            targetProgress: nil,
            actualFill: nil
        ), .secondary)
        XCTAssertEqual(AtriaRingMetricProjection.strainTint(
            targetProgress: 0.75,
            actualFill: actualFill
        ), .yellow)
    }

    func testRecoveryFailureNamesMissingEvidenceInsteadOfClaimingDayFourCompletion() {
        XCTAssertEqual(AtriaRecoveryAvailabilityPresentation.detail(
            estimateDetail: "learning: need saved sleep",
            hrvBaselineSamples: 3,
            restingBaselineSamples: 3
        ), "Save sleep to score")
        XCTAssertEqual(AtriaRecoveryAvailabilityPresentation.detail(
            estimateDetail: "learning: need a steady HRV window",
            hrvBaselineSamples: 3,
            restingBaselineSamples: 4
        ), "Needs steady HRV")
        XCTAssertEqual(AtriaRecoveryAvailabilityPresentation.detail(
            estimateDetail: "learning: need resting HR",
            hrvBaselineSamples: 4,
            restingBaselineSamples: 0
        ), "Needs resting HR")
        XCTAssertEqual(AtriaRecoveryAvailabilityPresentation.detail(
            estimateDetail: "learning RHR baseline 3/14",
            hrvBaselineSamples: 3,
            restingBaselineSamples: 3
        ), "RHR baseline 3 of 14 days")
    }

    // MARK: TodayHRZoneMinutes text

    func testHRZonesNoWearIsHonest() {
        let empty = TodayHRZoneMinutes.empty
        XCTAssertEqual(empty.valueText, "--")
        XCTAssertEqual(empty.detailText, "No wear today")
        XCTAssertEqual(empty.accessibilityDetailText, "No heart rate zone data today.")
    }

    func testHRZonesRestingOnlyDay() {
        let resting = TodayHRZoneMinutes(restMinutes: 300, warmupMinutes: 12,
                                         fatBurnMinutes: 0, aerobicMinutes: 0,
                                         anaerobicMinutes: 0, maxMinutes: 0,
                                         hasSamples: true)
        XCTAssertEqual(resting.activeMinutes, 0)
        XCTAssertEqual(resting.valueText, "0m")
        XCTAssertEqual(resting.detailText, "Resting")
    }

    func testHRZonesSplitOmitsZeroBuckets() {
        let day = TodayHRZoneMinutes(restMinutes: 200, warmupMinutes: 30,
                                     fatBurnMinutes: 22, aerobicMinutes: 15,
                                     anaerobicMinutes: 0, maxMinutes: 2,
                                     hasSamples: true)
        XCTAssertEqual(day.activeMinutes, 39)
        XCTAssertEqual(day.valueText, "39m")
        XCTAssertEqual(day.detailText, "Z2 22 · Z3 15 · Z5 2")
        XCTAssertTrue(day.accessibilityDetailText.contains("22 minutes in zone 2"))
        XCTAssertFalse(day.accessibilityDetailText.contains("zone 4"))
    }
}
