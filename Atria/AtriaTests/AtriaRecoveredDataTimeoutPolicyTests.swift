import XCTest
@testable import Atria

final class AtriaRecoveredDataTimeoutPolicyTests: XCTestCase {
    func testPhysicalDerivedLeaseHasMeasuredPerComponentHeadroom() {
        let policy = AtriaRecoveredDataTimeoutPolicy.physicalSessionStore

        XCTAssertGreaterThan(policy.derivedComponentLeaseSeconds, 96)
        XCTAssertEqual(policy.derivedComponentLeaseSeconds, 150)
        XCTAssertLessThanOrEqual(policy.derivedComponentLeaseSeconds, 180,
                                 "the progress lease must remain bounded")
    }

    func testSessionPublicationWaitCoversEveryFiniteInternalLease() {
        let policy = AtriaRecoveredDataTimeoutPolicy.physicalSessionStore
        let componentCount = AtriaRecoveredDataRecomputeCoordinator
            .sessionStoreComponents.count
        let expected = policy.projectionLeaseSeconds
            + componentCount * policy.derivedComponentLeaseSeconds
            + policy.publicationSchedulingGraceSeconds

        XCTAssertEqual(SessionStore.recoveredDataMaximumPipelineWaitSeconds,
                       expected)
        XCTAssertEqual(expected, 1_320)
    }

    func testShortRequestedWaitCannotUndercutInternalPipelineBound() {
        let policy = AtriaRecoveredDataTimeoutPolicy.physicalSessionStore
        let componentCount = AtriaRecoveredDataRecomputeCoordinator
            .sessionStoreComponents.count

        XCTAssertEqual(policy.publicationWaitSeconds(
            requestedSeconds: 25,
            requiredDerivedComponentCount: componentCount
        ), 1_320)
        XCTAssertEqual(policy.publicationWaitSeconds(
            requestedSeconds: 2_000,
            requiredDerivedComponentCount: componentCount
        ), 2_000)
        XCTAssertEqual(SessionStore.recoveredDataPublicationWaitDuration(
            requested: .seconds(25)
        ), .seconds(1_320))
        XCTAssertEqual(SessionStore.recoveredDataPublicationWaitDuration(
            requested: .seconds(2_000)
        ), .seconds(2_000))
    }
}
