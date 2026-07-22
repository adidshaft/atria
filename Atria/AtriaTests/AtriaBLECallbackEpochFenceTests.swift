import XCTest
@testable import Atria

final class AtriaBLECallbackEpochFenceTests: XCTestCase {
    func testReconnectInvalidatesQueuedWorkFromPriorLink() {
        let strapID = UUID()
        var fence = AtriaBLECallbackEpochFence()
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
        var fence = AtriaBLECallbackEpochFence()
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
}
