import CoreBluetooth
import XCTest
@testable import Atria

final class AtriaHeartRateBroadcasterTests: XCTestCase {
    func testPeripheralManagerStopCommandsRequirePoweredOnState() {
        XCTAssertTrue(
            AtriaHeartRateBroadcaster.canIssueStopCommands(
                peripheralState: .poweredOn
            )
        )
        for state: CBManagerState in [
            .unknown,
            .resetting,
            .unsupported,
            .unauthorized,
            .poweredOff,
        ] {
            XCTAssertFalse(
                AtriaHeartRateBroadcaster.canIssueStopCommands(
                    peripheralState: state
                )
            )
        }
    }
}
