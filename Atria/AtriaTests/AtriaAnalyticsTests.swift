import XCTest
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
}
