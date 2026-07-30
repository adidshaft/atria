import XCTest
@testable import Atria

final class AtriaBLECallbackEpochFenceTests: XCTestCase {
    func testReconnectInvalidatesQueuedWorkFromPriorLink() {
        let strapID = UUID()
        let fence = AtriaBLECallbackEpochFence()
        let firstEpoch = fence.activate(peripheralID: strapID)
        XCTAssertTrue(fence.accepts(
            callbackEpoch: firstEpoch,
            peripheralID: strapID,
            peripheralConnected: true
        ))

        fence.invalidate(ifMatching: strapID)
        let secondEpoch = fence.activate(peripheralID: strapID)
        XCTAssertFalse(fence.accepts(
            callbackEpoch: firstEpoch,
            peripheralID: strapID,
            peripheralConnected: true
        ))
        XCTAssertTrue(fence.accepts(
            callbackEpoch: secondEpoch,
            peripheralID: strapID,
            peripheralConnected: true
        ))
    }

    func testStaleDisconnectCannotInvalidateDifferentPeripheral() {
        let active = UUID()
        let fence = AtriaBLECallbackEpochFence()
        let epoch = fence.activate(peripheralID: active)

        XCTAssertEqual(fence.invalidate(ifMatching: UUID()), epoch)
        XCTAssertTrue(fence.accepts(
            callbackEpoch: epoch,
            peripheralID: active,
            peripheralConnected: true
        ))
        XCTAssertFalse(fence.accepts(
            callbackEpoch: epoch,
            peripheralID: active,
            peripheralConnected: false
        ))
    }

    func testOwnedEpochSurvivesDisconnectedObjectForStandingReconnect() {
        let active = UUID()
        let fence = AtriaBLECallbackEpochFence()
        let epoch = fence.activate(peripheralID: active)

        XCTAssertTrue(fence.owns(
            callbackEpoch: epoch,
            peripheralID: active
        ))
        XCTAssertFalse(fence.accepts(
            callbackEpoch: epoch,
            peripheralID: active,
            peripheralConnected: false
        ))
        XCTAssertFalse(fence.owns(
            callbackEpoch: epoch,
            peripheralID: UUID()
        ))

        fence.invalidate(ifMatching: active)
        XCTAssertFalse(fence.owns(
            callbackEpoch: epoch,
            peripheralID: active
        ))
    }

    func testPoweredOnMarkersAreConsumedTogetherExactlyOnce() {
        let fence = AtriaBLECallbackEpochFence()
        fence.markAwaitingPowerOn(
            standingConnect: true,
            silentStreamRebuild: true
        )

        XCTAssertEqual(
            fence.consumePowerOnMarkers(),
            .init(standingConnect: true, silentStreamRebuild: true)
        )
        XCTAssertEqual(fence.consumePowerOnMarkers(), .init())
    }

    func testConcurrentEpochMutationLeavesCoherentFinalTuple() {
        let fence = AtriaBLECallbackEpochFence()
        let strapID = UUID()
        let otherID = UUID()
        let queue = DispatchQueue(
            label: "atria.tests.ble-callback-epoch",
            attributes: .concurrent
        )
        let group = DispatchGroup()

        for iteration in 0..<2_000 {
            group.enter()
            queue.async {
                if iteration % 3 == 0 {
                    _ = fence.activate(peripheralID: strapID)
                } else if iteration % 3 == 1 {
                    _ = fence.invalidate(ifMatching: strapID)
                } else {
                    _ = fence.activate(peripheralID: otherID)
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let finalEpoch = fence.activate(peripheralID: strapID)
        XCTAssertTrue(fence.accepts(
            callbackEpoch: finalEpoch,
            peripheralID: strapID,
            peripheralConnected: true
        ))
        XCTAssertFalse(fence.accepts(
            callbackEpoch: finalEpoch,
            peripheralID: otherID,
            peripheralConnected: true
        ))
    }
}
