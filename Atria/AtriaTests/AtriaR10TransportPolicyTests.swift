import XCTest
@testable import Atria

final class AtriaR10TransportPolicyTests: XCTestCase {
    func testNormalLaunchDefaultsToPhysicallyVerifiedMinimalHRAndR10() {
        XCTAssertTrue(AtriaBLEManager.shouldUseStandardHROnlyAtNormalLaunch(
            userSelectedBatterySaver: false,
            persistedStandardHROnly: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldUseStandardHROnlyAtNormalLaunch(
            userSelectedBatterySaver: false,
            persistedStandardHROnly: true
        ), "automatic normal wear must use the stable minimal profile that still carries R10")
        XCTAssertTrue(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream5
        ), "the protected production profile must classify stream 5 as its strap-step source")
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream4
        ), "protected production must not expand into the full proprietary notification set")
    }

    func testNormalLaunchPreservesAnExplicitRadioProfileChoice() {
        XCTAssertTrue(AtriaBLEManager.shouldUseStandardHROnlyAtNormalLaunch(
            userSelectedBatterySaver: true,
            persistedStandardHROnly: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldUseStandardHROnlyAtNormalLaunch(
            userSelectedBatterySaver: true,
            persistedStandardHROnly: false
        ), "an explicit diagnostic full-protocol selection remains available")
    }

    func testStableR10MigrationNeverOverridesExplicitRadioChoice() {
        XCTAssertTrue(AtriaBLEManager.shouldMigrateAutomaticModeToProtectedR10(
            migrationWasRecorded: false,
            userSelectedRadioMode: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldMigrateAutomaticModeToProtectedR10(
            migrationWasRecorded: true,
            userSelectedRadioMode: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldMigrateAutomaticModeToProtectedR10(
            migrationWasRecorded: false,
            userSelectedRadioMode: true
        ))
    }

    func testProtectedProductionDiscoveryIsExactlyR10AndLeasedTX() throws {
        let characteristics = try XCTUnwrap(
            AtriaBLEManager.protectedStandardHRStrapCharacteristics(streamSuppressed: false)
        )
        XCTAssertEqual(Set(characteristics), [
            AtriaBLEManager.UUIDs.strapStream5,
            AtriaBLEManager.UUIDs.strapTX
        ])
        XCTAssertNil(AtriaBLEManager.protectedStandardHRStrapCharacteristics(
            streamSuppressed: true
        ))
    }

    func testProtectedProductionDiscoversNotifyOnlyStandardBatteryAlongsideHRAndR10() throws {
        XCTAssertEqual(
            AtriaBLEManager.protectedStandardHRServices(streamSuppressed: false),
            [
                AtriaBLEManager.UUIDs.heartRateService,
                AtriaBLEManager.UUIDs.batteryService,
                AtriaBLEManager.UUIDs.strapService
            ]
        )
        XCTAssertEqual(
            AtriaBLEManager.protectedStandardHRServices(streamSuppressed: true),
            [
                AtriaBLEManager.UUIDs.heartRateService,
                AtriaBLEManager.UUIDs.batteryService
            ],
            "R10 rollback must not also remove the safe standard battery notification path"
        )

        let batteryCharacteristics = try XCTUnwrap(
            AtriaBLEManager.protectedStandardHRCharacteristics(
                for: AtriaBLEManager.UUIDs.batteryService,
                streamSuppressed: false
            )
        )
        XCTAssertEqual(batteryCharacteristics, [AtriaBLEManager.UUIDs.batteryLevel])
        XCTAssertFalse(batteryCharacteristics.contains(AtriaBLEManager.UUIDs.batteryLevelStatus))
    }

    func testProtectedProductionIngestMatchesDiscoveryPolicy() {
        XCTAssertTrue(AtriaBLEManager.shouldAcceptProtectedProprietaryNotification(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream5,
            streamSuppressed: false,
            pendingOneShotBatteryResponse: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAcceptProtectedProprietaryNotification(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream5,
            streamSuppressed: true,
            pendingOneShotBatteryResponse: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAcceptProtectedProprietaryNotification(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream4,
            streamSuppressed: false,
            pendingOneShotBatteryResponse: false
        ), "the physically rejected event subscription must stay outside protected production")
        XCTAssertTrue(AtriaBLEManager.shouldAcceptProtectedProprietaryNotification(
            characteristicUUID: AtriaBLEManager.UUIDs.strapRX,
            streamSuppressed: true,
            pendingOneShotBatteryResponse: true
        ))
    }

    func testEveryDecodedR10PathRecordsSourceFreshness() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("private func recordValidR10MotionEvidence(receivedAt: Date)"))
        XCTAssertTrue(source.contains("assignIfChanged(\\.liveStrapMotionCapturedAt, receivedAt)"))
        XCTAssertTrue(source.contains("recordValidR10MotionEvidence(receivedAt: receivedAt)"))
        XCTAssertTrue(source.contains("forKey: RadioDefaults.passiveR10LastValidAt"))
    }

    func testR10NotificationRepairOnlyTargetsInactiveExpectedStream() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(AtriaBLEManager.shouldRepairR10Notification(
            expected: true,
            connected: true,
            isNotifying: false,
            lastRepairAt: nil,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRepairR10Notification(
            expected: true,
            connected: true,
            isNotifying: true,
            lastRepairAt: nil,
            now: now
        ), "A healthy CCCD must never be toggled")
        XCTAssertFalse(AtriaBLEManager.shouldRepairR10Notification(
            expected: false,
            connected: true,
            isNotifying: false,
            lastRepairAt: nil,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRepairR10Notification(
            expected: true,
            connected: false,
            isNotifying: false,
            lastRepairAt: nil,
            now: now
        ))
    }

    func testR10NotificationRepairIsPaced() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertFalse(AtriaBLEManager.shouldRepairR10Notification(
            expected: true,
            connected: true,
            isNotifying: false,
            lastRepairAt: now.addingTimeInterval(-29),
            now: now
        ))
        XCTAssertTrue(AtriaBLEManager.shouldRepairR10Notification(
            expected: true,
            connected: true,
            isNotifying: false,
            lastRepairAt: now.addingTimeInterval(-30),
            now: now
        ))
    }
}
