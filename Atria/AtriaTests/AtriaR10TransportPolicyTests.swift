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

    func testSuppressedR10FuseOverridesStaleFullProtocolPreference() {
        XCTAssertTrue(
            AtriaBLEManager.shouldForceStableTransportForSuppressedR10(
                streamSuppressed: true,
                explicitFullProtocolDiagnostic: false
            ),
            "a production launch must not rediscover proprietary services after the disconnect-storm fuse isolated them"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldForceStableTransportForSuppressedR10(
                streamSuppressed: false,
                explicitFullProtocolDiagnostic: false
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldForceStableTransportForSuppressedR10(
                streamSuppressed: true,
                explicitFullProtocolDiagnostic: true
            ),
            "the command-line transport diagnostic remains an explicit opt-in"
        )
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
        XCTAssertEqual(batteryCharacteristics, [
            AtriaBLEManager.UUIDs.batteryLevel,
            AtriaBLEManager.UUIDs.batteryLevelStatus
        ])
        XCTAssertTrue(batteryCharacteristics.contains(AtriaBLEManager.UUIDs.batteryLevelStatus),
                      "2A1B is the standard current-link charger-state source; it must not be replaced with a proprietary stream")
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
        XCTAssertTrue(AtriaBLEManager.shouldAcceptProtectedProprietaryNotification(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream4,
            streamSuppressed: true,
            pendingOneShotBatteryResponse: false,
            historyRecoveryActive: true
        ), "an active bounded history transaction must be able to ingest its response and data characteristics")
        XCTAssertTrue(AtriaBLEManager.shouldAcceptProtectedProprietaryNotification(
            characteristicUUID: AtriaBLEManager.UUIDs.strapRX,
            streamSuppressed: true,
            pendingOneShotBatteryResponse: false,
            historyRecoveryActive: true
        ), "WHOOP command responses must reach the history state machine in protected mode")
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

    func testKnownR10TransportBoundaryRetiresOnlyLiveFreshnessUntilNewFrame() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)

        let helperStart = try XCTUnwrap(source.range(
            of: "private func retireLiveR10MotionFreshness"
        ))
        let helperEnd = try XCTUnwrap(source.range(
            of: "private func markStepCalibrationMotionStreamReady",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helper = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
        XCTAssertTrue(helper.contains("assignIfChanged(\\.liveStrapMotionCapturedAt, nil)"))
        XCTAssertTrue(helper.contains("assignIfChanged(\\.liveStrapStepCountCapturedAt, nil)"))
        XCTAssertTrue(helper.contains("assignIfChanged(\\.liveStrapStepResearchState, state)"))
        XCTAssertTrue(helper.contains("removeObject(forKey: RadioDefaults.passiveR10LastValidAt)"),
                      "the dashboard reads the persisted R10 clock, so it must retire at the same boundary")
        XCTAssertFalse(helper.contains("liveStrapStepResearchCount = 0"),
                       "an unavailable transport retires freshness, never the monotonic saved count")

        let fallbackStart = try XCTUnwrap(source.range(
            of: "private func persistProtectedR10CleanOwnerFallback"
        ))
        let fallbackEnd = try XCTUnwrap(source.range(
            of: "private func requestProtectedR10InitialProfileNotificationIfAllowed",
            range: fallbackStart.upperBound..<source.endIndex
        ))
        let fallback = String(source[fallbackStart.lowerBound..<fallbackEnd.lowerBound])
        XCTAssertTrue(fallback.contains("retireLiveR10MotionFreshness("))
        XCTAssertTrue(fallback.contains("state: \"passive_r10_unavailable\""))

        let subscriptionStart = try XCTUnwrap(source.range(
            of: "private func markPassiveR10SubscriptionConfirmed"
        ))
        let subscriptionEnd = try XCTUnwrap(source.range(
            of: "private func retireLiveR10MotionFreshness",
            range: subscriptionStart.upperBound..<source.endIndex
        ))
        let subscription = String(source[subscriptionStart.lowerBound..<subscriptionEnd.lowerBound])
        XCTAssertTrue(subscription.contains("retireLiveR10MotionFreshness("))
        XCTAssertTrue(subscription.contains("state: \"passive_r10_waiting\""))

        let applyStart = try XCTUnwrap(source.range(of: "private func applyR10MotionSnapshot"))
        let applyEnd = try XCTUnwrap(source.range(
            of: "private func scheduleTrailingStrapStepCheckpoint",
            range: applyStart.upperBound..<source.endIndex
        ))
        let apply = String(source[applyStart.lowerBound..<applyEnd.lowerBound])
        XCTAssertTrue(apply.contains("assignIfChanged(\\.liveStrapStepCountCapturedAt, capturedAt)"),
                      "the first fresh detector snapshot must restore live step freshness")
        XCTAssertTrue(source.contains("assignIfChanged(\\.liveStrapMotionCapturedAt, receivedAt)"),
                      "a newly CRC-valid R10 frame must restore live motion freshness")
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
