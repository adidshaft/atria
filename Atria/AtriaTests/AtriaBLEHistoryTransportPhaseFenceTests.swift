import XCTest
@testable import Atria

final class AtriaBLEHistoryTransportPhaseFenceTests: XCTestCase {
    func testQueuedSnapshotCannotCrossGenerationBoundary() {
        let fence = AtriaBLEHistoryTransportPhaseFence()
        let first = fence.activate(generation: 7)
        XCTAssertTrue(fence.accepts(first, generation: 7))

        _ = fence.deactivate(ifMatching: 7)
        let second = fence.activate(generation: 8)

        XCTAssertFalse(fence.accepts(first, generation: 7))
        XCTAssertFalse(fence.accepts(first, generation: 8))
        XCTAssertTrue(fence.accepts(second, generation: 8))
    }

    func testStaleFinishCannotDeactivateNewerGeneration() {
        let fence = AtriaBLEHistoryTransportPhaseFence()
        _ = fence.activate(generation: 10)
        _ = fence.activate(generation: 11)

        XCTAssertTrue(fence.deactivate(ifMatching: 10).isActive)
        XCTAssertEqual(fence.snapshot().generation, 11)
        XCTAssertFalse(fence.deactivate(ifMatching: 11).isActive)
    }

    func testProtectedV9HistoryDiscoveryUsesGenericHistoryRoute() {
        XCTAssertFalse(AtriaBLEManager.shouldUseProtectedV9CharacteristicHandler(
            standardHROnlyMode: true,
            historyRecoveryActive: true,
            strapService: true,
            protectedV9Owner: true,
            launchOrProofActive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldUseProtectedV9CharacteristicHandler(
            standardHROnlyMode: true,
            historyRecoveryActive: false,
            strapService: true,
            protectedV9Owner: true,
            launchOrProofActive: true
        ))
    }
}
