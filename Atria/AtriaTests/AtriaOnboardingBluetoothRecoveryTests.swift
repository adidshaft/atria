import XCTest
@testable import Atria

final class AtriaOnboardingBluetoothRecoveryTests: XCTestCase {
    func testPermissionDenialWinsOverFoldedPoweredOffTransportStatus() {
        let recovery = AtriaOnboardingBluetoothRecovery(
            status: .poweredOff,
            permissionDenied: true
        )

        XCTAssertEqual(recovery, .permissionDenied)
        XCTAssertEqual(recovery.primaryActionTitle, "Open Settings")
        XCTAssertFalse(recovery.disablesPrimaryAction,
                       "The only available permission-recovery action must remain tappable")
    }

    func testPoweredOffRadioRemainsDistinctFromPermissionDenial() {
        let recovery = AtriaOnboardingBluetoothRecovery(
            status: .poweredOff,
            permissionDenied: false
        )

        XCTAssertEqual(recovery, .radioPoweredOff)
        XCTAssertEqual(recovery.primaryActionTitle, "Turn on Bluetooth")
        XCTAssertTrue(recovery.disablesPrimaryAction)
    }

    func testAvailableTransportDoesNotOverrideNormalConnectAction() {
        for status in [AtriaBLEManager.Status.disconnected,
                       .scanning,
                       .connecting,
                       .connected] {
            let recovery = AtriaOnboardingBluetoothRecovery(
                status: status,
                permissionDenied: false
            )

            XCTAssertEqual(recovery, .none)
            XCTAssertNil(recovery.primaryActionTitle)
            XCTAssertFalse(recovery.disablesPrimaryAction)
        }
    }
}
