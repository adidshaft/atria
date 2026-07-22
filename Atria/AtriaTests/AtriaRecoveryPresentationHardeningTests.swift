import XCTest
@testable import Atria

final class AtriaRecoveryPresentationHardeningTests: XCTestCase {
    func testUnverifiedNoHRVRecoveryKeepsZoneAndDisclosesEarlyEvidence() {
        XCTAssertEqual(
            AtriaRecoveryRingPresentation.detail(
                zone: "Good",
                confidence: .unverified,
                estimateDetail: "Limited confidence · sleep and HRV unavailable · RHR-only estimate",
                isProvisional: true
            ),
            "Good · Early · no HRV"
        )
    }

    func testQualifiedRecoveryKeepsCompactZoneDetail() {
        XCTAssertEqual(
            AtriaRecoveryRingPresentation.detail(
                zone: "Steady",
                confidence: .personalBaseline,
                estimateDetail: "Personal recovery baseline",
                isProvisional: false
            ),
            "Steady"
        )
    }

    func testProvisionalRecoveryDoesNotFireReadyHaptic() {
        XCTAssertFalse(
            AtriaHapticAlertCoordinator.shouldFireRecoveryReady(
                percent: 96,
                isReadyForAlert: false,
                wasReady: false
            )
        )
    }

    func testQualifiedRecoveryFiresOnceEvenAfterProvisionalScoreWasVisible() {
        XCTAssertTrue(
            AtriaHapticAlertCoordinator.shouldFireRecoveryReady(
                percent: 72,
                isReadyForAlert: true,
                wasReady: false
            )
        )
        XCTAssertFalse(
            AtriaHapticAlertCoordinator.shouldFireRecoveryReady(
                percent: 72,
                isReadyForAlert: true,
                wasReady: true
            )
        )
    }
}
