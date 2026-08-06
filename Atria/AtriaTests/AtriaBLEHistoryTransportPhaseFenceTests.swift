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

    func testExplicitHistoryProfileIsScopedToItsOwningGeneration() {
        let fence = AtriaBLEHistoryTransportPhaseFence()
        let explicit = fence.activate(generation: 21, usesExplicitHistoryProfile: true)
        XCTAssertTrue(explicit.usesExplicitHistoryProfile)
        XCTAssertTrue(fence.snapshot().usesExplicitHistoryProfile)

        // A stale completion must neither release nor clear the active repair.
        XCTAssertTrue(fence.deactivate(ifMatching: 20).usesExplicitHistoryProfile)
        XCTAssertTrue(fence.snapshot().usesExplicitHistoryProfile)

        XCTAssertFalse(fence.deactivate(ifMatching: 21).isActive)
        XCTAssertFalse(fence.snapshot().usesExplicitHistoryProfile)

        // Ordinary recovery starts clean, even after an explicit repair.
        XCTAssertFalse(fence.activate(generation: 22).usesExplicitHistoryProfile)
    }

    func testRealtimeRestoreRetiresOnlyExactGenerationAndBindsExactEpoch() {
        let fence = AtriaBLEHistoryTransportPhaseFence()
        let peripheralID = UUID()
        let peripheral = NSObject()
        let objectID = ObjectIdentifier(peripheral)
        _ = fence.activate(generation: 31)

        XCTAssertTrue(fence.retireForRealtimeRestore(
            ifMatching: 31,
            peripheralID: peripheralID
        ))
        XCTAssertFalse(fence.snapshot().isActive)
        XCTAssertEqual(fence.claimRealtimeRestore(
            peripheralID: peripheralID,
            peripheralObjectID: objectID,
            callbackEpoch: 4
        ), 31)
        XCTAssertTrue(fence.acceptsRealtimeRestoreClaim(
            peripheralID: peripheralID,
            peripheralObjectID: objectID,
            interruptedGeneration: 31,
            callbackEpoch: 4
        ))
        XCTAssertFalse(fence.settleRealtimeRestoreClaim(
            peripheralID: peripheralID,
            peripheralObjectID: objectID,
            interruptedGeneration: 31,
            callbackEpoch: 3
        ), "a stale callback epoch must not consume the handoff")
        XCTAssertTrue(fence.settleRealtimeRestoreClaim(
            peripheralID: peripheralID,
            peripheralObjectID: objectID,
            interruptedGeneration: 31,
            callbackEpoch: 4
        ))
        XCTAssertNil(fence.realtimeRestoreHandoffSnapshot())
    }

    func testRealtimeRestoreCannotRetireOrOverrideNewerGeneration() {
        let fence = AtriaBLEHistoryTransportPhaseFence()
        let peripheralID = UUID()
        _ = fence.activate(generation: 40)
        _ = fence.activate(generation: 41)

        XCTAssertFalse(fence.retireForRealtimeRestore(
            ifMatching: 40,
            peripheralID: peripheralID
        ))
        XCTAssertEqual(fence.snapshot().generation, 41)
        XCTAssertNil(fence.realtimeRestoreHandoffSnapshot())
    }

    func testFreshHistoryActivationInvalidatesOlderRealtimeRestoreHandoff() {
        let fence = AtriaBLEHistoryTransportPhaseFence()
        let peripheralID = UUID()
        let peripheral = NSObject()
        _ = fence.activate(generation: 50)
        XCTAssertTrue(fence.retireForRealtimeRestore(
            ifMatching: 50,
            peripheralID: peripheralID
        ))

        _ = fence.activate(generation: 51)

        XCTAssertEqual(fence.snapshot().generation, 51)
        XCTAssertNil(fence.claimRealtimeRestore(
            peripheralID: peripheralID,
            peripheralObjectID: ObjectIdentifier(peripheral),
            callbackEpoch: 8
        ))
    }

    func testStaleConnectedCallbackCanBeReboundWithoutClearingHandoff() {
        let fence = AtriaBLEHistoryTransportPhaseFence()
        let peripheralID = UUID()
        let stalePeripheral = NSObject()
        let currentPeripheral = NSObject()
        _ = fence.activate(generation: 60)
        XCTAssertTrue(fence.retireForRealtimeRestore(
            ifMatching: 60,
            peripheralID: peripheralID
        ))
        XCTAssertEqual(fence.claimRealtimeRestore(
            peripheralID: peripheralID,
            peripheralObjectID: ObjectIdentifier(stalePeripheral),
            callbackEpoch: 10
        ), 60)

        XCTAssertEqual(fence.claimRealtimeRestore(
            peripheralID: peripheralID,
            peripheralObjectID: ObjectIdentifier(currentPeripheral),
            callbackEpoch: 11
        ), 60)
        XCTAssertFalse(fence.acceptsRealtimeRestoreClaim(
            peripheralID: peripheralID,
            peripheralObjectID: ObjectIdentifier(stalePeripheral),
            interruptedGeneration: 60,
            callbackEpoch: 10
        ))
        XCTAssertTrue(fence.acceptsRealtimeRestoreClaim(
            peripheralID: peripheralID,
            peripheralObjectID: ObjectIdentifier(currentPeripheral),
            interruptedGeneration: 60,
            callbackEpoch: 11
        ))
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
