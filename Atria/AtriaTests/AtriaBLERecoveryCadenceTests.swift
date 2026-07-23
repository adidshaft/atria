import XCTest
import CoreBluetooth
@testable import Atria

final class AtriaBLERecoveryCadenceTests: XCTestCase {
    func testStandardHeartRateParserPreservesOptionalRRAndContactFlags() throws {
        // RR present + sensor-contact supported/detected + uint8 HR.
        let contactAndRR = try XCTUnwrap(AtriaBLEManager.parseHeartRateMeasurement(
            Data([0x16, 72, 0x00, 0x04])
        ))
        XCTAssertEqual(contactAndRR.hr, 72)
        XCTAssertEqual(contactAndRR.rr, [1_000])
        XCTAssertTrue(contactAndRR.rrFlagPresent)
        XCTAssertEqual(contactAndRR.sensorContactDetected, true)

        // Supported but explicitly not detected is different from unsupported.
        let noContact = try XCTUnwrap(AtriaBLEManager.parseHeartRateMeasurement(
            Data([0x04, 71])
        ))
        XCTAssertFalse(noContact.rrFlagPresent)
        XCTAssertEqual(noContact.sensorContactDetected, false)

        let unsupported = try XCTUnwrap(AtriaBLEManager.parseHeartRateMeasurement(
            Data([0x00, 70])
        ))
        XCTAssertFalse(unsupported.rrFlagPresent)
        XCTAssertNil(unsupported.sensorContactDetected)
    }

    func testHistoryProbeRearmsWhenTXArrivesAfterBoundedDiscoveryWait() {
        XCTAssertTrue(AtriaBLEManager.shouldRearmHistoryOnlyProbeAfterTXDiscovery(
            historyOnlyProbeEnabled: true,
            historyOnlyProbeMode: true,
            historyOnlyProbeArmed: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRearmHistoryOnlyProbeAfterTXDiscovery(
            historyOnlyProbeEnabled: true,
            historyOnlyProbeMode: true,
            historyOnlyProbeArmed: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRearmHistoryOnlyProbeAfterTXDiscovery(
            historyOnlyProbeEnabled: false,
            historyOnlyProbeMode: true,
            historyOnlyProbeArmed: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRearmHistoryOnlyProbeAfterTXDiscovery(
            historyOnlyProbeEnabled: true,
            historyOnlyProbeMode: false,
            historyOnlyProbeArmed: false
        ))
    }

    func testUnavailableFallbackOpensCoverageGapWithoutTreatingHistoryAsLoss() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertTrue(AtriaBLEManager.shouldOpenWorkoutMotionGapForUnavailableR10(
            motionLeaseHeld: true,
            historyOwnsTransport: false,
            r10TransportExpected: false,
            lastFrameAt: now.addingTimeInterval(-16),
            now: now
        ))
        XCTAssertTrue(AtriaBLEManager.shouldOpenWorkoutMotionGapForUnavailableR10(
            motionLeaseHeld: true,
            historyOwnsTransport: false,
            r10TransportExpected: false,
            lastFrameAt: nil,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldOpenWorkoutMotionGapForUnavailableR10(
            motionLeaseHeld: true,
            historyOwnsTransport: false,
            r10TransportExpected: false,
            lastFrameAt: now.addingTimeInterval(-15),
            now: now
        ), "the exact live boundary is still fresh")
        XCTAssertFalse(AtriaBLEManager.shouldOpenWorkoutMotionGapForUnavailableR10(
            motionLeaseHeld: true,
            historyOwnsTransport: true,
            r10TransportExpected: false,
            lastFrameAt: now.addingTimeInterval(-60),
            now: now
        ), "history ownership is a deliberate handoff, not a movement gap")
        XCTAssertFalse(AtriaBLEManager.shouldOpenWorkoutMotionGapForUnavailableR10(
            motionLeaseHeld: true,
            historyOwnsTransport: false,
            r10TransportExpected: true,
            lastFrameAt: now.addingTimeInterval(-60),
            now: now
        ), "an expected live transport remains owned by its liveness repair policy")
    }

    func testUnexpectedLongWearDisconnectDefersHistoryUntilRealtimeReconnectIsInstalled() {
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticHistoryUntilAfterRealtimeReconnect(
            preservesLongWearSession: true,
            rangeLossBackfillPending: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticHistoryUntilAfterRealtimeReconnect(
            preservesLongWearSession: false,
            rangeLossBackfillPending: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticHistoryUntilAfterRealtimeReconnect(
            preservesLongWearSession: true,
            rangeLossBackfillPending: false
        ))
    }
    func testR10ReplayWatermarkUsesSerialOrderingIncludingWrap() {
        XCTAssertEqual(AtriaBLEManager.newestR10DeviceTimestamp(existing: nil,
                                                                incoming: 100), 100)
        XCTAssertEqual(AtriaBLEManager.newestR10DeviceTimestamp(existing: 100,
                                                                incoming: 101), 101)
        XCTAssertEqual(AtriaBLEManager.newestR10DeviceTimestamp(existing: 101,
                                                                incoming: 100), 101)
        XCTAssertEqual(AtriaBLEManager.newestR10DeviceTimestamp(existing: UInt32.max - 1,
                                                                incoming: 1), 1)
    }

    func testHRContinuityTimeoutDoesNotAttackHealthySparseStrapCadence() {
        XCTAssertEqual(AtriaBLEManager.hrContinuityWatchdogTimeout(
            acceptedHRTimeout: 45
        ), 30)
        XCTAssertEqual(AtriaBLEManager.hrContinuityWatchdogTimeout(
            acceptedHRTimeout: 35
        ), 35 * (2.0 / 3.0), accuracy: 0.000_1)
        XCTAssertEqual(AtriaBLEManager.hrContinuityWatchdogTimeout(
            acceptedHRTimeout: 20
        ), 20)
        XCTAssertEqual(AtriaBLEManager.hrContinuityWatchdogTimeout(
            acceptedHRTimeout: 180
        ), 45)
    }

    func testHRContinuityAtFourteenSecondsOnlyObserves() {
        XCTAssertEqual(AtriaBLEManager.heartRateContinuityRecoveryDisposition(
            rawHeartRateGap: 14,
            usefulGattGap: 14,
            adaptiveTimeout: 20,
            peripheralConnected: true,
            hasHeartRateCharacteristic: true,
            heartRateIsNotifying: true,
            canReadHeartRate: true,
            canNotifyHeartRate: true
        ), .observe)
    }

    func testHRContinuityAtThresholdReadsActiveNotificationWithoutToggling() {
        XCTAssertEqual(AtriaBLEManager.heartRateContinuityRecoveryDisposition(
            rawHeartRateGap: 30,
            usefulGattGap: 30,
            adaptiveTimeout: 30,
            peripheralConnected: true,
            hasHeartRateCharacteristic: true,
            heartRateIsNotifying: true,
            canReadHeartRate: true,
            canNotifyHeartRate: true
        ), .readHeartRate)
        XCTAssertEqual(AtriaBLEManager.heartRateContinuityRecoveryDisposition(
            rawHeartRateGap: 30,
            usefulGattGap: 30,
            adaptiveTimeout: 30,
            peripheralConnected: true,
            hasHeartRateCharacteristic: true,
            heartRateIsNotifying: true,
            canReadHeartRate: false,
            canNotifyHeartRate: true
        ), .observe)
    }

    func testHRContinuityEnablesAnInactiveNotificationOnce() {
        XCTAssertEqual(AtriaBLEManager.heartRateContinuityRecoveryDisposition(
            rawHeartRateGap: 30,
            usefulGattGap: 30,
            adaptiveTimeout: 30,
            peripheralConnected: true,
            hasHeartRateCharacteristic: true,
            heartRateIsNotifying: false,
            canReadHeartRate: true,
            canNotifyHeartRate: true
        ), .enableHeartRateNotifications)
    }

    func testHRContinuityRediscoveryRearmsAStaleUnreadableActiveSubscription() {
        // WHOOP's standard HR characteristic can be notify-only. Previously
        // this exact 30-second outage merely observed the dead subscription,
        // leaving the live stream stale until a much later all-GATT timeout.
        XCTAssertEqual(AtriaBLEManager.heartRateContinuityRecoveryDisposition(
            rawHeartRateGap: 30,
            usefulGattGap: 2,
            adaptiveTimeout: 30,
            peripheralConnected: true,
            hasHeartRateCharacteristic: true,
            heartRateIsNotifying: true,
            canReadHeartRate: false,
            canNotifyHeartRate: true
        ), .rediscoverHeartRateService)
    }

    func testHRContinuityDefersRepairWhileHistoryOwnsTheTransport() {
        XCTAssertTrue(AtriaBLEManager.shouldDeferHRContinuityRepairForHistoryOwnership(
            historyTransportActive: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldDeferHRContinuityRepairForHistoryOwnership(
            historyTransportActive: false
        ))
    }

    func testDenseFreshWithAcceptedHRStaleAlwaysProducesRepairAction() {
        XCTAssertEqual(AtriaBLEManager.heartRateContinuityRecoveryDisposition(
            rawHeartRateGap: 5,
            usefulGattGap: 1,
            adaptiveTimeout: 30,
            peripheralConnected: true,
            hasHeartRateCharacteristic: true,
            heartRateIsNotifying: true,
            canReadHeartRate: false,
            canNotifyHeartRate: true,
            denseStreamFresh: true,
            acceptedHeartRateGap: 60
        ), .rediscoverHeartRateService)
    }

    func testFreshR10EvidencePreventsTeardownDuringSixtySecondHRGap() {
        XCTAssertEqual(AtriaBLEManager.heartRateContinuityRecoveryDisposition(
            rawHeartRateGap: 60,
            usefulGattGap: 2,
            adaptiveTimeout: 30,
            peripheralConnected: true,
            hasHeartRateCharacteristic: true,
            heartRateIsNotifying: true,
            canReadHeartRate: true,
            canNotifyHeartRate: true
        ), .readHeartRate)
    }

    func testAllUsefulGattSilenceAtTwoMinutesRequestsOneRebuild() {
        XCTAssertEqual(AtriaBLEManager.heartRateContinuityRecoveryDisposition(
            rawHeartRateGap: 120,
            usefulGattGap: 120,
            adaptiveTimeout: 30,
            peripheralConnected: true,
            hasHeartRateCharacteristic: true,
            heartRateIsNotifying: true,
            canReadHeartRate: true,
            canNotifyHeartRate: true
        ), .rebuildConnection)
        XCTAssertEqual(AtriaBLEManager.heartRateContinuityRecoveryDisposition(
            rawHeartRateGap: 300,
            usefulGattGap: 1,
            adaptiveTimeout: 30,
            peripheralConnected: true,
            hasHeartRateCharacteristic: true,
            heartRateIsNotifying: true,
            canReadHeartRate: true,
            canNotifyHeartRate: true
        ), .rebuildConnection)
    }

    func testCoreBluetoothDisconnectedPathReconnectsKnownPeripheralImmediately() {
        XCTAssertEqual(AtriaBLEManager.heartRateContinuityRecoveryDisposition(
            rawHeartRateGap: 1,
            usefulGattGap: 1,
            adaptiveTimeout: 30,
            peripheralConnected: false,
            hasHeartRateCharacteristic: true,
            heartRateIsNotifying: true,
            canReadHeartRate: true,
            canNotifyHeartRate: true
        ), .reconnectKnownPeripheral)
    }

    func testPeerRemovedPairingErrorRequiresFreshIdentityScan() {
        let staleBond = NSError(
            domain: CBErrorDomain,
            code: CBError.peerRemovedPairingInformation.rawValue
        )
        XCTAssertTrue(AtriaBLEManager.isPeerRemovedPairingError(staleBond))
        XCTAssertFalse(AtriaBLEManager.isPeerRemovedPairingError(nil))
        XCTAssertFalse(AtriaBLEManager.isPeerRemovedPairingError(
            NSError(domain: CBErrorDomain, code: CBError.connectionTimeout.rawValue)
        ))
        XCTAssertFalse(AtriaBLEManager.isPeerRemovedPairingError(
            NSError(domain: "UnrelatedDomain", code: staleBond.code)
        ))
    }

    func testContinuityWatchdogsNeverToggleAnActiveHeartRateSubscription() throws {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)

        let continuityStart = try XCTUnwrap(source.range(
            of: "private func performHRContinuityWatchdogAction"
        ))
        let continuityEnd = try XCTUnwrap(source.range(
            of: "private func persistHRContinuityWatchdogResult",
            range: continuityStart.upperBound..<source.endIndex
        ))
        let continuityBody = String(source[continuityStart.lowerBound..<continuityEnd.lowerBound])
        XCTAssertFalse(continuityBody.contains("resetHeartRateNotifyIfNeeded"))
        XCTAssertFalse(continuityBody.contains("setNotifyValue(false"))

        let keepaliveStart = try XCTUnwrap(source.range(
            of: "private func runForegroundKeepaliveTick"
        ))
        let keepaliveEnd = try XCTUnwrap(source.range(
            of: "private func stopForegroundKeepaliveWatchdog",
            range: keepaliveStart.upperBound..<source.endIndex
        ))
        let keepaliveBody = String(source[keepaliveStart.lowerBound..<keepaliveEnd.lowerBound])
        XCTAssertFalse(keepaliveBody.contains("resetHeartRateNotifyIfNeeded"))
        XCTAssertFalse(keepaliveBody.contains("setNotifyValue(false"))
    }

    func testHeartRateNotificationEnableGateCoalescesAndRetriesAfterSettlement() {
        let peripheralID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var gate = AtriaBLEManager.HeartRateNotificationEnableGate()

        XCTAssertEqual(gate.disposition(
            now: now,
            peripheralID: peripheralID,
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: false
        ), .request)
        XCTAssertEqual(gate.disposition(
            now: now.addingTimeInterval(1),
            peripheralID: peripheralID,
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: false
        ), .waitForInFlight)

        // Success, inactive completion and error all arrive through the same
        // CoreBluetooth callback, so settlement must permit a later retry.
        gate.settle(peripheralID: peripheralID)
        XCTAssertEqual(gate.disposition(
            now: now.addingTimeInterval(2),
            peripheralID: peripheralID,
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: false
        ), .request)
        XCTAssertEqual(gate.disposition(
            now: now.addingTimeInterval(33),
            peripheralID: peripheralID,
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: false
        ), .request, "a lost callback cannot suppress retries forever")
        XCTAssertEqual(gate.disposition(
            now: now.addingTimeInterval(34),
            peripheralID: peripheralID,
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: true
        ), .alreadyActive)
    }

    func testHeartRateNotificationEnablePureDispositionFailsClosed() {
        XCTAssertEqual(AtriaBLEManager.heartRateNotificationEnableDisposition(
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: false,
            requestInFlight: false
        ), .request)
        XCTAssertEqual(AtriaBLEManager.heartRateNotificationEnableDisposition(
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: false,
            requestInFlight: true
        ), .waitForInFlight)
        XCTAssertEqual(AtriaBLEManager.heartRateNotificationEnableDisposition(
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: true,
            requestInFlight: false
        ), .alreadyActive)
        XCTAssertEqual(AtriaBLEManager.heartRateNotificationEnableDisposition(
            peripheralConnected: false,
            supportsNotifications: true,
            isNotifying: false,
            requestInFlight: false
        ), .unavailable)
    }

    func testInactiveHeartRateCallbackImmediatelyRetriesOnceWhileLockedLinkIsLive() {
        XCTAssertTrue(AtriaBLEManager.shouldImmediatelyReenableInactiveHeartRateNotification(
            peripheralMatches: true,
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: false,
            sparseSentinel: false,
            retryAlreadyIssued: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldImmediatelyReenableInactiveHeartRateNotification(
            peripheralMatches: true,
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: false,
            sparseSentinel: false,
            retryAlreadyIssued: true
        ), "a refusing CCCD must not create a tight callback loop")
    }

    func testInactiveHeartRateCallbackDoesNotUndoIntentionalSparseDisable() {
        XCTAssertFalse(AtriaBLEManager.shouldImmediatelyReenableInactiveHeartRateNotification(
            peripheralMatches: true,
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: false,
            sparseSentinel: true,
            retryAlreadyIssued: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldImmediatelyReenableInactiveHeartRateNotification(
            peripheralMatches: false,
            peripheralConnected: true,
            supportsNotifications: true,
            isNotifying: false,
            sparseSentinel: false,
            retryAlreadyIssued: false
        ), "stale callbacks from a retired peripheral cannot mutate the live link")
    }

    func testDiscoveryRequestsContinuousHeartRateBeforeMainActorCanSuspend() throws {
        XCTAssertTrue(AtriaBLEManager.shouldSynchronouslyEnableDiscoveredHeartRateNotification(
            continuousCaptureWanted: true,
            supportsNotifications: true,
            isNotifying: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldSynchronouslyEnableDiscoveredHeartRateNotification(
            continuousCaptureWanted: false,
            supportsNotifications: true,
            isNotifying: false
        ), "intentional sparse capture must retain its disabled CCCD")
        XCTAssertFalse(AtriaBLEManager.shouldSynchronouslyEnableDiscoveredHeartRateNotification(
            continuousCaptureWanted: true,
            supportsNotifications: true,
            isNotifying: true
        ), "a restored active CCCD must remain untouched")

        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)
        let callbackStart = try XCTUnwrap(source.range(
            of: "didDiscoverCharacteristicsFor service: CBService, error: Error?"
        ))
        let callbackEnd = try XCTUnwrap(source.range(
            of: "didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?",
            range: callbackStart.upperBound..<source.endIndex
        ))
        let callback = String(source[callbackStart.lowerBound..<callbackEnd.lowerBound])
        let synchronousEnable = try XCTUnwrap(callback.range(
            of: "peripheral.setNotifyValue(true, for: ch)"
        ))
        let actorHop = try XCTUnwrap(callback.range(
            of: "Task { @MainActor in",
            range: synchronousEnable.upperBound..<callback.endIndex
        ))
        XCTAssertLessThan(synchronousEnable.lowerBound, actorHop.lowerBound,
                          "the initial CCCD write must precede the actor hop")
    }

    func testConnectStartsProductionHeartRateDiscoveryBeforeMainActorCanSuspend() throws {
        XCTAssertTrue(AtriaBLEManager.shouldSynchronouslyDiscoverHeartRateAfterConnect(
            continuousCaptureWanted: true,
            peripheralConnected: true,
            historyRecoveryActive: false,
            diagnosticActive: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldSynchronouslyDiscoverHeartRateAfterConnect(
            continuousCaptureWanted: false,
            peripheralConnected: true,
            historyRecoveryActive: false,
            diagnosticActive: false
        ), "intentional sparse capture must not be converted into continuous capture")
        XCTAssertFalse(AtriaBLEManager.shouldSynchronouslyDiscoverHeartRateAfterConnect(
            continuousCaptureWanted: true,
            peripheralConnected: true,
            historyRecoveryActive: true,
            diagnosticActive: false
        ), "explicit history owns its restricted discovery transaction")
        XCTAssertFalse(AtriaBLEManager.shouldSynchronouslyDiscoverHeartRateAfterConnect(
            continuousCaptureWanted: true,
            peripheralConnected: true,
            historyRecoveryActive: false,
            diagnosticActive: true
        ), "diagnostic links must retain their consented service profile")

        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)
        let connectStart = try XCTUnwrap(source.range(
            of: "didConnect peripheral: CBPeripheral"
        ))
        let disconnectStart = try XCTUnwrap(source.range(
            of: "didDisconnectPeripheral peripheral: CBPeripheral",
            range: connectStart.upperBound..<source.endIndex
        ))
        let callback = String(source[connectStart.lowerBound..<disconnectStart.lowerBound])
        let discovery = try XCTUnwrap(callback.range(
            of: "beginSynchronousHeartRateDiscoveryFastLane("
        ))
        let actorHop = try XCTUnwrap(callback.range(of: "Task { @MainActor in"))
        XCTAssertLessThan(discovery.lowerBound, actorHop.lowerBound,
                          "180D discovery must begin in didConnect's callback execution slice")
        let helperStart = try XCTUnwrap(source.range(
            of: "nonisolated private func beginSynchronousHeartRateDiscoveryFastLane("
        ))
        let helperEnd = try XCTUnwrap(source.range(
            of: "// MARK: - CBCentralManagerDelegate",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helper = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
        XCTAssertTrue(helper.contains("bleCallbackEpochFence.accepts"),
                      "the synchronous radio call must be fenced to the active link epoch")
        XCTAssertTrue(helper.contains("cachedService"))
        XCTAssertTrue(helper.contains("cachedMeasurement"))
        XCTAssertTrue(helper.contains("peripheral.setNotifyValue(true, for: cachedMeasurement)"),
                      "a retained 2A37 must be enabled without waiting for any discovery callback")
        XCTAssertTrue(helper.contains("peripheral.discoverCharacteristics"),
                      "a retained 180D service must start 2A37 discovery in the same callback slice")
        XCTAssertTrue(helper.contains("BackgroundHRDiscoveryDefaults.stage"),
                      "locked reconnect forensics need a durable delegate-stage breadcrumb")
    }

    func testDiscoveryRadioCallbacksRejectRetiredConnectionEpochs() throws {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)
        let servicesStart = try XCTUnwrap(source.range(
            of: "didDiscoverServices error: Error?"
        ))
        let characteristicsStart = try XCTUnwrap(source.range(
            of: "didDiscoverCharacteristicsFor service: CBService, error: Error?",
            range: servicesStart.upperBound..<source.endIndex
        ))
        let updateNotificationStart = try XCTUnwrap(source.range(
            of: "didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?",
            range: characteristicsStart.upperBound..<source.endIndex
        ))
        let services = String(source[servicesStart.lowerBound..<characteristicsStart.lowerBound])
        let characteristics = String(source[characteristicsStart.lowerBound..<updateNotificationStart.lowerBound])
        XCTAssertTrue(services.contains("bleCallbackEpochFence.accepts"))
        XCTAssertTrue(services.contains("stale_service_callback"))
        XCTAssertTrue(characteristics.contains("bleCallbackEpochFence.accepts"))
        XCTAssertTrue(characteristics.contains("stale_characteristic_callback"))
    }

    func testEveryProductionHeartRateWatchdogEnableUsesSharedGate() throws {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)

        func body(_ startMarker: String, _ endMarker: String) throws -> String {
            let start = try XCTUnwrap(source.range(of: startMarker))
            let end = try XCTUnwrap(source.range(
                of: endMarker,
                range: start.upperBound..<source.endIndex
            ))
            return String(source[start.lowerBound..<end.lowerBound])
        }

        let paths = try [
            body("private func runForegroundKeepaliveTick", "private func stopForegroundKeepaliveWatchdog"),
            body("private func recoverNoDataWatchdog", "private func scheduleHRContinuityWatchdogIfNeeded"),
            body("private func performHRContinuityWatchdogAction", "private func persistHRContinuityWatchdogResult"),
            body("private func recoverRRPresenceWatchdog", "private func persistRRPresenceWatchdogResult"),
            body("private func recoverAcceptedHRWatchdog", "private func persistWatchdogRecovery")
        ]
        for path in paths {
            XCTAssertTrue(path.contains("requestHeartRateNotificationEnableIfNeeded"))
            XCTAssertFalse(path.contains("setNotifyValue(true"))
        }

        let callback = try body(
            "didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?",
            "didUpdateValueFor characteristic: CBCharacteristic, error: Error?"
        )
        XCTAssertTrue(callback.contains("heartRateNotificationEnableGate.settle"))

        let disconnect = try body(
            "didDisconnectPeripheral peripheral: CBPeripheral, error: Error?",
            "didFailToConnect peripheral: CBPeripheral"
        )
        XCTAssertTrue(disconnect.contains("heartRateNotificationEnableGate.reset"))
    }

    func testSparseAndLowBatterySilenceNeverStartWatchdogRepair() throws {
        XCTAssertFalse(AtriaBLEManager.shouldPerformForegroundKeepaliveHardRebuild(
            isSparseSentinel: true,
            disposition: .rebuildConnection
        ))
        XCTAssertTrue(AtriaBLEManager.shouldPerformForegroundKeepaliveHardRebuild(
            isSparseSentinel: false,
            disposition: .rebuildConnection
        ))
        XCTAssertTrue(AtriaBLEManager.shouldSuppressWatchdogForStrapStreamState(
            .lowBatteryShutoff
        ))
        XCTAssertFalse(AtriaBLEManager.shouldSuppressWatchdogForStrapStreamState(
            .live
        ))

        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)
        let keepaliveStart = try XCTUnwrap(source.range(of: "private func runForegroundKeepaliveTick"))
        let keepaliveEnd = try XCTUnwrap(source.range(
            of: "private func stopForegroundKeepaliveWatchdog",
            range: keepaliveStart.upperBound..<source.endIndex
        ))
        let keepalive = String(source[keepaliveStart.lowerBound..<keepaliveEnd.lowerBound])
        let sparse = try XCTUnwrap(keepalive.range(of: "sparse_expected_silence"))
        let rebuild = try XCTUnwrap(keepalive.range(
            of: "continuityDisposition == .rebuildConnection"
        ) ?? keepalive.range(of: "shouldPerformForegroundKeepaliveHardRebuild"))
        XCTAssertLessThan(sparse.lowerBound, rebuild.lowerBound)

        for markers in [
            ("private func recoverNoDataWatchdog", "private func scheduleHRContinuityWatchdogIfNeeded"),
            ("private func performHRContinuityWatchdogAction", "private func persistHRContinuityWatchdogResult"),
            ("private func recoverAcceptedHRWatchdog", "private func persistWatchdogRecovery")
        ] {
            let start = try XCTUnwrap(source.range(of: markers.0))
            let end = try XCTUnwrap(source.range(of: markers.1,
                                                 range: start.upperBound..<source.endIndex))
            let watchdog = String(source[start.lowerBound..<end.lowerBound])
            let suppression = try XCTUnwrap(watchdog.range(
                of: "shouldSuppressWatchdogForStrapStreamState"
            ))
            let checkpointOrRepair = try XCTUnwrap(
                watchdog.range(of: "let snapshot")
                    ?? watchdog.range(of: "beginStalledStreamRepair")
            )
            XCTAssertLessThan(suppression.lowerBound, checkpointOrRepair.lowerBound)
        }
    }

    func testMotionDiagnosticRequiresProfileConsentForR10IMUSequence() {
        let base = [
            AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.enableArgument,
            AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.confirmationArgument,
            AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.runIDArgument,
            "profile-test"
        ]

        XCTAssertNil(AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.parse(
            arguments: base + [
                AtriaBLEManager.MotionHandshakeDiagnosticConfiguration
                    .r10IMUSequenceConsentArgument
            ]
        ))

        let configuration = AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.parse(
            arguments: base + [
                AtriaBLEManager.MotionHandshakeDiagnosticConfiguration
                    .responseEventDataProfileArgument,
                AtriaBLEManager.MotionHandshakeDiagnosticConfiguration
                    .r10IMUSequenceConsentArgument,
                AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.addHRDelayArgument,
                "15"
            ]
        )
        XCTAssertEqual(configuration?.runID, "profile-test")
        XCTAssertEqual(configuration?.addHRDelay, 15)
        XCTAssertEqual(configuration?.useResponseEventDataProfile, true)
        XCTAssertEqual(configuration?.sendR10IMUSequence, true)
        XCTAssertEqual(configuration?.sendSingleR10Activation, false)
    }

    func testMotionDiagnosticProfileSubscribesResponseEventThenData() {
        XCTAssertEqual(
            AtriaBLEManager.motionHandshakeNotifyOrder(
                useResponseEventDataProfile: true
            ),
            [AtriaBLEManager.UUIDs.strapRX,
             AtriaBLEManager.UUIDs.strapStream4,
             AtriaBLEManager.UUIDs.strapStream5]
        )
        XCTAssertEqual(
            AtriaBLEManager.motionHandshakeNotifyOrder(
                useResponseEventDataProfile: false
            ),
            [AtriaBLEManager.UUIDs.strapStream5]
        )
    }

    func testProtectedV9UsesPhysicallyProvenProfileAndTiming() {
        XCTAssertEqual(
            AtriaBLEManager.protectedR10ResponseEventDataNotifyOrder,
            [AtriaBLEManager.UUIDs.strapRX,
             AtriaBLEManager.UUIDs.strapStream4,
             AtriaBLEManager.UUIDs.strapStream5]
        )
        XCTAssertEqual(AtriaBLEManager.protectedR10CommandPacingDelay,
                       0.120,
                       accuracy: 0.000_1)
        XCTAssertEqual(
            AtriaBLEManager.protectedStandardHRStrapCharacteristics(
                streamSuppressed: false,
                cleanOwner: .protectedV9
            ),
            [AtriaBLEManager.UUIDs.strapRX,
             AtriaBLEManager.UUIDs.strapStream4,
             AtriaBLEManager.UUIDs.strapStream5,
             AtriaBLEManager.UUIDs.strapTX]
        )
    }

    func testAlwaysOnLongWearMigrationRepairsOrphanedDisabledCapture() throws {
        let suite = "AtriaBLERecoveryCadenceTests.alwaysOn.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AtriaBLEManager.CaptureDefaults.configured)
        defaults.set(false, forKey: AtriaBLEManager.LongWearDefaults.enabled)
        defaults.set(true, forKey: AtriaBLEManager.LongWearDefaults.userSelected)

        XCTAssertTrue(AtriaBLEManager.migrateAlwaysOnLongWearIfNeeded(
            defaults: defaults,
            arguments: []
        ))
        XCTAssertTrue(defaults.bool(forKey: AtriaBLEManager.LongWearDefaults.enabled))
        XCTAssertFalse(defaults.bool(forKey: AtriaBLEManager.LongWearDefaults.userSelected))
        XCTAssertTrue(defaults.bool(forKey: AtriaBLEManager.CaptureDefaults.alwaysOnLongWearMigrated))
        XCTAssertFalse(AtriaBLEManager.migrateAlwaysOnLongWearIfNeeded(
            defaults: defaults,
            arguments: []
        ), "the migration must be one-shot")
    }

    func testAlwaysOnLongWearMigrationDoesNotMutateDiagnosticLaunch() throws {
        let suite = "AtriaBLERecoveryCadenceTests.alwaysOnDiagnostic.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AtriaBLEManager.CaptureDefaults.configured)
        defaults.set(false, forKey: AtriaBLEManager.LongWearDefaults.enabled)

        XCTAssertFalse(AtriaBLEManager.migrateAlwaysOnLongWearIfNeeded(
            defaults: defaults,
            arguments: ["--atria-full-protocol-mode"]
        ))
        XCTAssertFalse(defaults.bool(forKey: AtriaBLEManager.LongWearDefaults.enabled))
        XCTAssertFalse(defaults.bool(forKey: AtriaBLEManager.CaptureDefaults.alwaysOnLongWearMigrated))
    }

    func testStrapStepCheckpointIsBoundedByCountAndTime() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertFalse(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 111,
            persistedSteps: 100,
            lastCheckpointAt: now.addingTimeInterval(-14.9),
            now: now
        ), "Eleven fresh steps inside fifteen seconds stay in the bounded in-memory window")
        XCTAssertTrue(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 112,
            persistedSteps: 100,
            lastCheckpointAt: now.addingTimeInterval(-1),
            now: now
        ), "The twelfth confirmed step must force a durable checkpoint")
        XCTAssertTrue(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 101,
            persistedSteps: 100,
            lastCheckpointAt: now.addingTimeInterval(-15),
            now: now
        ), "A small trailing remainder must not wait indefinitely for twelve steps")
    }

    func testStrapStepCheckpointNeverInventsProgressAndFailsSafeOnClockEdges() {
        let now = Date(timeIntervalSince1970: 20_000)

        XCTAssertFalse(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 100,
            persistedSteps: 100,
            lastCheckpointAt: now.addingTimeInterval(-1_000),
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 99,
            persistedSteps: 100,
            lastCheckpointAt: nil,
            now: now
        ), "A regressed/stale snapshot is not new step evidence")
        XCTAssertTrue(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 101,
            persistedSteps: 100,
            lastCheckpointAt: nil,
            now: now
        ), "The first confirmed step after an absent checkpoint establishes durability")
        XCTAssertTrue(AtriaBLEManager.shouldCheckpointStrapSteps(
            currentSteps: 101,
            persistedSteps: 100,
            lastCheckpointAt: now.addingTimeInterval(60),
            now: now
        ), "A future checkpoint clock must not suppress writes indefinitely")
    }

    func testCleanOwnerV7MigrationCutsSuppressedUsersToFreshProtectedV7Once() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerV7.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.streamSuppressed")
        defaults.set(3, forKey: "atria.protectedR10.passiveReprobeFailureCount")
        defaults.set(123.0, forKey: "atria.protectedR10.passiveReprobeAttemptAt")
        defaults.set(true, forKey: "atria.protectedR10.passiveReprobePending")
        defaults.set(true, forKey: "atria.protectedR10.passiveRetryMigrationV4")

        XCTAssertEqual(
            AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
            .migratedToProtectedV7
        )
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwner"),
                       "protected_v7")
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "protected_launch_pending")
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.rollback"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.cleanOwnerConnectionCutoverV7"))
        XCTAssertEqual(defaults.integer(forKey: "atria.protectedR10.passiveReprobeFailureCount"), 0)
        XCTAssertNil(defaults.object(forKey: "atria.protectedR10.passiveReprobeAttemptAt"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.passiveReprobePending"))

        defaults.set(2, forKey: "atria.protectedR10.passiveReprobeFailureCount")
        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .none)
        XCTAssertEqual(defaults.integer(forKey: "atria.protectedR10.passiveReprobeFailureCount"), 2,
                       "the one-time launch migration must not erase later proof failures")
    }

    func testPhysicallyProvenV9MigratesSuppressedPureHRV8ExactlyOnce() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerV7Retry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.cleanOwnerMigrationV6")
        defaults.set("pure_hr_v8", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_pending", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set("clean_owner_stream5_notification_lost",
                     forKey: "atria.protectedR10.cleanOwnerFailureReason")
        defaults.set(true, forKey: "atria.protectedR10.streamSuppressed")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .migratedPureHRV8ToProtectedV9)
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwner"),
                       "protected_redp_v9")
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "protected_launch_pending")
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.responseEventDataMigrationV9"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.responseEventDataConnectionCutoverV9"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.responseEventDataSequenceSentV9"))

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .none,
                       "the physically-proven owner migration must be one-shot")
    }

    func testCleanOwnerMigrationLeavesUnsuppressedLegacyOwnerUnchanged() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerLegacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "atria.protectedR10.streamSuppressed")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .none)
        XCTAssertNil(defaults.string(forKey: "atria.protectedR10.cleanOwner"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.cleanOwnerMigrationV7"))
    }

    func testCleanOwnerFallbackActivatesPureHRV8OnlyAtNextProcessLaunch() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.cleanOwnerMigrationV7")
        defaults.set("pure_hr_v8", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_pending", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set(false, forKey: "atria.protectedR10.streamSuppressed")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .activatedPureHRV8Fallback)
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "fallback_active")
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.rollback"))
    }

    func testV10FallbackActivatesOnlyAtNextProcessLaunch() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerV10Fallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataMigrationV9")
        defaults.set("pure_hr_v10", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_pending", forKey: "atria.protectedR10.cleanOwnerState")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .activatedPureHRV10Fallback)
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "fallback_active")
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.rollback"))
    }

    func testFallbackRequalifyPolicyRequiresPhysicalProofAndCooldown() {
        let now = 2_000_000_000.0
        let cooldown = AtriaBLEManager.protectedR10FallbackRequalifyCooldown
        // Never requalify a transport that has no physical qualification.
        XCTAssertFalse(AtriaBLEManager.protectedR10FallbackShouldRequalify(
            priorQualifiedAt: nil, fallbackAt: now - 10 * cooldown,
            lastAttemptAt: nil, now: now))
        // A fresh fallback or a recent attempt must wait out the cooldown.
        XCTAssertFalse(AtriaBLEManager.protectedR10FallbackShouldRequalify(
            priorQualifiedAt: now - 86_400, fallbackAt: now - cooldown + 60,
            lastAttemptAt: nil, now: now))
        XCTAssertFalse(AtriaBLEManager.protectedR10FallbackShouldRequalify(
            priorQualifiedAt: now - 86_400, fallbackAt: now - 10 * cooldown,
            lastAttemptAt: now - cooldown + 60, now: now))
        XCTAssertTrue(AtriaBLEManager.protectedR10FallbackShouldRequalify(
            priorQualifiedAt: now - 86_400, fallbackAt: now - cooldown - 60,
            lastAttemptAt: now - cooldown - 60, now: now))
        // Installs demoted before the fallback timestamp existed recover on
        // their next launch instead of being stranded (2026-07-16 regression).
        XCTAssertTrue(AtriaBLEManager.protectedR10FallbackShouldRequalify(
            priorQualifiedAt: now - 86_400, fallbackAt: nil,
            lastAttemptAt: nil, now: now))
    }

    func testExplicitlyAuthorizedV10FallbackRequalifiesOncePerCooldown() throws {
        let suite = "AtriaBLERecoveryCadenceTests.v10Requalify.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataMigrationV9")
        defaults.set(true, forKey: "atria.protectedR10.cleanOwnerMigrationV7")
        defaults.set("pure_hr_v10", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_active", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set(true, forKey: "atria.protectedR10.streamSuppressed")
        defaults.set(true, forKey: "atria.protectedR10.rollback")
        defaults.set(true, forKey: "atria.protectedR10.pureHRV10InProcessCutover")
        defaults.set(now.timeIntervalSince1970 - 86_400,
                     forKey: "atria.protectedR10.stableTransportQualifiedAt")

        XCTAssertEqual(
            AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(
                defaults: defaults,
                allowFallbackRequalification: true,
                now: now
            ),
            .requalifiedProtectedV9FromFallback
        )
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwner"),
                       "protected_redp_v9")
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "protected_launch_pending")
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.rollback"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.pureHRV10InProcessCutover"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.responseEventDataSequenceSentV9"))
        XCTAssertNotNil(defaults.object(forKey: "atria.protectedR10.stableTransportQualifiedAt"),
                        "the physical credential must survive so later cooldown attempts stay authorized")
        XCTAssertNotNil(defaults.object(forKey: "atria.protectedR10.requalifyAttemptAt"))

        // A failed attempt that falls back again must NOT retry within the
        // cooldown: the transport degrades to pure HR instead of flapping.
        defaults.set("pure_hr_v10", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_active", forKey: "atria.protectedR10.cleanOwnerState")
        XCTAssertEqual(
            AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(
                defaults: defaults,
                allowFallbackRequalification: true,
                now: now.addingTimeInterval(60)
            ),
            .none
        )
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))

        // After the cooldown the bounded attempt is available again.
        XCTAssertEqual(
            AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(
                defaults: defaults,
                allowFallbackRequalification: true,
                now: now.addingTimeInterval(
                    AtriaBLEManager.protectedR10FallbackRequalifyCooldown + 61)
            ),
            .requalifiedProtectedV9FromFallback
        )
    }

    func testExplicitNewWorkoutCanRequalifyQualifiedV8FallbackOnlyAtLaunch() throws {
        let suite = "AtriaBLERecoveryCadenceTests.v8WorkoutRequalify.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // The v9 migration was already consumed before this persisted
        // fallback was observed. This is the state that formerly stranded an
        // explicit Walking workout on pure HR forever.
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataMigrationV9")
        defaults.set(true, forKey: "atria.protectedR10.cleanOwnerMigrationV7")
        defaults.set("pure_hr_v8", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_active", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set(true, forKey: "atria.protectedR10.streamSuppressed")
        defaults.set(true, forKey: "atria.protectedR10.rollback")
        defaults.set(now.timeIntervalSince1970 - 86_400,
                     forKey: "atria.protectedR10.stableTransportQualifiedAt")

        XCTAssertEqual(
            AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(
                defaults: defaults,
                allowFallbackRequalification: true,
                now: now
            ),
            .requalifiedProtectedV9FromFallback
        )
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwner"),
                       "protected_redp_v9")
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "protected_launch_pending")
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.rollback"))
        XCTAssertNotNil(defaults.object(forKey: "atria.protectedR10.requalifyAttemptAt"))

        // A v8 fallback without a past dense qualification remains safely
        // suppressed even for an explicit workout launch.
        defaults.set("pure_hr_v8", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_active", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set(true, forKey: "atria.protectedR10.streamSuppressed")
        defaults.set(true, forKey: "atria.protectedR10.rollback")
        defaults.removeObject(forKey: "atria.protectedR10.stableTransportQualifiedAt")
        XCTAssertEqual(
            AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(
                defaults: defaults,
                allowFallbackRequalification: true,
                bypassCooldownForNewWorkoutLease: true,
                now: now.addingTimeInterval(1)
            ),
            .none
        )
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
    }

    func testV8WorkoutInProcessCutoverRequiresIntentProofAndNewLease() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let allowed = AtriaBLEManager.protectedR10V8WorkoutCutoverMayStart(
            owner: .pureHRV8,
            state: .fallbackActive,
            streamSuppressed: true,
            manualWorkoutActive: true,
            priorQualifiedAt: start.timeIntervalSince1970 - 86_400,
            priorCutoverLeaseAt: nil,
            workoutStartedAt: start
        )
        XCTAssertTrue(allowed)

        XCTAssertTrue(AtriaBLEManager.protectedR10V8WorkoutCutoverMayStart(
            owner: .pureHRV10,
            state: .fallbackActive,
            streamSuppressed: true,
            manualWorkoutActive: true,
            priorQualifiedAt: start.timeIntervalSince1970 - 86_400,
            priorCutoverLeaseAt: nil,
            workoutStartedAt: start
        ), "a qualified v10 fallback needs the same one-shot fresh-owner path for a manual workout")

        XCTAssertFalse(AtriaBLEManager.protectedR10V8WorkoutCutoverMayStart(
            owner: .pureHRV8,
            state: .fallbackActive,
            streamSuppressed: true,
            manualWorkoutActive: false,
            priorQualifiedAt: start.timeIntervalSince1970 - 86_400,
            priorCutoverLeaseAt: nil,
            workoutStartedAt: start
        ), "all-day motion must not trigger the fresh-owner cutover")
        XCTAssertFalse(AtriaBLEManager.protectedR10V8WorkoutCutoverMayStart(
            owner: .pureHRV8,
            state: .fallbackActive,
            streamSuppressed: true,
            manualWorkoutActive: true,
            priorQualifiedAt: nil,
            priorCutoverLeaseAt: nil,
            workoutStartedAt: start
        ), "an unqualified fallback must remain pure HR")
        XCTAssertFalse(AtriaBLEManager.protectedR10V8WorkoutCutoverMayStart(
            owner: .pureHRV8,
            state: .fallbackActive,
            streamSuppressed: true,
            manualWorkoutActive: true,
            priorQualifiedAt: start.timeIntervalSince1970 - 86_400,
            priorCutoverLeaseAt: start.timeIntervalSince1970,
            workoutStartedAt: start
        ), "duplicate Start/lifecycle callbacks get no second cutover")
    }

    func testNormalLaunchKeepsPhysicallyQualifiedFallbackOnPureHR() throws {
        let suite = "AtriaBLERecoveryCadenceTests.v10LowBatteryFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataMigrationV9")
        defaults.set(true, forKey: "atria.protectedR10.cleanOwnerMigrationV7")
        defaults.set("pure_hr_v10", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_active", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set(true, forKey: "atria.protectedR10.streamSuppressed")
        defaults.set(true, forKey: "atria.protectedR10.rollback")
        defaults.set(now.timeIntervalSince1970 - 86_400,
                     forKey: "atria.protectedR10.stableTransportQualifiedAt")

        XCTAssertEqual(
            AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(
                defaults: defaults,
                now: now
            ),
            .none
        )
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwner"),
                       "pure_hr_v10")
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "fallback_active")
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.rollback"))
        XCTAssertNil(defaults.object(forKey: "atria.protectedR10.requalifyAttemptAt"))

        let source = try leaseManagerSource()
        let launchCall = try XCTUnwrap(source.range(
            of: "let cleanOwnerPreparation = Self.prepareProtectedR10CleanOwnerAtLaunch"
        ))
        let launchBody = String(source[launchCall.lowerBound...].prefix(900))
        XCTAssertTrue(launchBody.contains(
            "allowFallbackRequalification: explicitWorkoutNeedsMotion"
        ))
        XCTAssertTrue(String(source[..<launchCall.lowerBound].suffix(1_500)).contains(
            "let explicitWorkoutNeedsMotion = explicitWorkoutIntentActive"
        ), "ordinary process launch must gate motion requalification on an explicit workout lease")
    }

    func testInterruptedProofCannotRetainQualifiedOwnerWithoutStableTransport() throws {
        let source = try leaseManagerSource()
        let fb = try XCTUnwrap(source.range(of: "private func persistProtectedR10CleanOwnerFallback"))
        let fbBody = String(source[fb.lowerBound...].prefix(4_500))
        XCTAssertTrue(fbBody.contains("pure_hr_fallback_no_false_qualification"))
        XCTAssertFalse(fbBody.contains("retain_qualified_owner_retry_next_connection"),
                       "a historical qualification cannot certify a failed current density proof")
        XCTAssertTrue(fbBody.contains("protectedR10FallbackAtKey"),
                      "an honored fallback must stamp its time so requalification is cooldown-bounded")
        XCTAssertFalse(AtriaBLEManager.protectedR10QualificationIsEvidenceConsistent(
            cleanOwnerState: .qualified,
            stableTransportProven: false
        ))
        XCTAssertTrue(AtriaBLEManager.protectedR10QualificationIsEvidenceConsistent(
            cleanOwnerState: .qualified,
            stableTransportProven: true
        ))
        XCTAssertTrue(AtriaBLEManager.protectedR10QualificationIsEvidenceConsistent(
            cleanOwnerState: .fallbackPending,
            stableTransportProven: false
        ))
    }

    func testInterruptedV9ProofFallsBackOnFirstDisconnect() {
        XCTAssertEqual(
            AtriaBLEManager.protectedR10ProofDisconnectDecision(
                proofWasActive: true,
                cleanOwner: .protectedV9,
                activationWasSent: true,
                framesAfterActivation: 2,
                proofDuration: 10,
                lastFrameAge: 7,
                userRequestedDisconnect: false,
                atriaOwnedOfflineSyncDisconnect: false
            ),
            .fallbackToPureHR
        )
    }

    func testV9ProofDisconnectFallbackIgnoresUserOrOfflineDisconnect() {
        XCTAssertEqual(
            AtriaBLEManager.protectedR10ProofDisconnectDecision(
                proofWasActive: true,
                cleanOwner: .protectedV9,
                activationWasSent: true,
                framesAfterActivation: 2,
                proofDuration: 10,
                lastFrameAge: 7,
                userRequestedDisconnect: true,
                atriaOwnedOfflineSyncDisconnect: false
            ),
            .none
        )
        XCTAssertEqual(
            AtriaBLEManager.protectedR10ProofDisconnectDecision(
                proofWasActive: true,
                cleanOwner: .protectedV9,
                activationWasSent: true,
                framesAfterActivation: 2,
                proofDuration: 10,
                lastFrameAge: 7,
                userRequestedDisconnect: false,
                atriaOwnedOfflineSyncDisconnect: true
            ),
            .none
        )
        XCTAssertEqual(
            AtriaBLEManager.protectedR10ProofDisconnectDecision(
                proofWasActive: false,
                cleanOwner: .protectedV9,
                activationWasSent: true,
                framesAfterActivation: 2,
                proofDuration: 10,
                lastFrameAge: 7,
                userRequestedDisconnect: false,
                atriaOwnedOfflineSyncDisconnect: false
            ),
            .none
        )
    }

    func testV9ProofDisconnectFallbackRequiresCurrentCrcBurstOnShortV9Link() {
        let invalid: [(AtriaBLEManager.ProtectedR10CleanOwner, Bool, Int, TimeInterval)] = [
            (.protectedV7, true, 2, 42),
            (.protectedV9, false, 2, 42),
            (.protectedV9, true, 0, 42),
            (.protectedV9, true, 2, 0),
            (.protectedV9, true, 2, 91),
        ]
        for (owner, activationSent, frames, duration) in invalid {
            XCTAssertEqual(
                AtriaBLEManager.protectedR10ProofDisconnectDecision(
                    proofWasActive: true,
                    cleanOwner: owner,
                    activationWasSent: activationSent,
                    framesAfterActivation: frames,
                    proofDuration: duration,
                    lastFrameAge: 7,
                    userRequestedDisconnect: false,
                    atriaOwnedOfflineSyncDisconnect: false
                ),
                .none
            )
        }
        XCTAssertEqual(
            AtriaBLEManager.protectedR10ProofDisconnectDecision(
                proofWasActive: true,
                cleanOwner: .protectedV9,
                activationWasSent: true,
                framesAfterActivation: 2,
                proofDuration: 40,
                lastFrameAge: 21,
                userRequestedDisconnect: false,
                atriaOwnedOfflineSyncDisconnect: false
            ),
            .none,
            "a stale historical frame cannot authorize command replay"
        )
    }

    func testInterruptedV9ProcessWithFreshCrcBurstFallsBackWithoutReplay() throws {
        let suite = "AtriaBLERecoveryCadenceTests.processRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataMigrationV9")
        defaults.set(true, forKey: "atria.protectedR10.cleanOwnerMigrationV7")
        defaults.set("protected_redp_v9", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("proving", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataSequenceSentV9")
        defaults.set(now.timeIntervalSince1970 - 40,
                     forKey: "atria.protectedR10.activationSentAt")
        defaults.set(now.timeIntervalSince1970 - 5,
                     forKey: "atria.radio.passiveR10LastValidAt")
        defaults.set(1, forKey: "atria.protectedR10.proofChurnFailures")

        XCTAssertEqual(
            AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(
                defaults: defaults, now: now
            ),
            .activatedPureHRV10Fallback
        )
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwner"),
                       "pure_hr_v10")
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "fallback_active")
        XCTAssertEqual(defaults.integer(forKey: "atria.protectedR10.proofChurnFailures"), 2)
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.responseEventDataSequenceSentV9"),
                      "an interrupted command lease must remain consumed")
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.rollback"))
    }

    func testLegacyInterruptedProofFallbackNeverRestoresV9AtLaunch() throws {
        let suite = "AtriaBLERecoveryCadenceTests.processRetryMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataMigrationV9")
        defaults.set(true, forKey: "atria.protectedR10.cleanOwnerMigrationV7")
        defaults.set("pure_hr_v10", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("fallback_active", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set("clean_owner_proof_interrupted_retry_1",
                     forKey: "atria.protectedR10.cleanOwnerFailureReason")
        defaults.set(1, forKey: "atria.protectedR10.proofChurnFailures")
        defaults.set(now.timeIntervalSince1970 - 86_400,
                     forKey: "atria.protectedR10.stableTransportQualifiedAt")

        XCTAssertEqual(
            AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(
                defaults: defaults, now: now
            ),
            .none
        )
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwner"),
                       "pure_hr_v10")
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "fallback_active")
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.rollback"))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.processProofRetryMigrationV1"))
    }

    func testV9ProofDisconnectHandlerCutsOverWithoutFreshProofRetry() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(of: "didDisconnectPeripheral peripheral"))
        let disconnectTail = source[start.lowerBound...]
        let end = try XCTUnwrap(disconnectTail.range(of: "didFailToConnect peripheral"))
        let body = String(disconnectTail[..<end.lowerBound])
        XCTAssertTrue(body.contains("let protectedActivationStartedAt = protectedR10ActivationAt"))
        XCTAssertTrue(body.contains("proofDuration: protectedActivationStartedAt.map"))
        XCTAssertTrue(body.contains("if cleanOwnerProofWasActive || pureHRV10CutoverWasPending"))
        XCTAssertTrue(body.contains("persistProtectedR10CleanOwnerFallback"))
        XCTAssertTrue(body.contains("previousProofInterruptions + 1"),
                      "the first proof failure remains diagnosable")
        XCTAssertTrue(body.contains("if cleanOwnerProofWasActive"))
        XCTAssertTrue(body.contains("beginProtectedR10PureHRV10InProcessCutoverIfNeeded"))
        XCTAssertFalse(body.contains("retryProtectedProofOnFreshConnection"))
        XCTAssertFalse(body.contains("clean_owner_v9_fresh_connection_retry"))

        let qualify = try XCTUnwrap(source.range(of: "private func qualifyProtectedR10RecoveryIfNeeded"))
        let qualifyBody = String(source[qualify.lowerBound...].prefix(2_500))
        XCTAssertTrue(qualifyBody.contains("protectedR10ProofChurnFailureCountKey"))
        XCTAssertTrue(qualifyBody.contains("defaults.set(0"),
                      "only an evidence-qualified window clears proof churn")
    }

    func testV9ShortBurstGetsOneBoundedSameConnectionRetry() {
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(AtriaBLEManager.shouldRetryProtectedR10ShortBurst(
            proofActive: true,
            connected: true,
            heartRateNotifying: true,
            priorPhysicalQualification: false,
            framesAfterActivation: 2,
            lastFrameAge: 21,
            connectedAt: connectedAt,
            retryConnectionAt: nil
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRetryProtectedR10ShortBurst(
            proofActive: true,
            connected: true,
            heartRateNotifying: true,
            priorPhysicalQualification: false,
            framesAfterActivation: 2,
            lastFrameAge: 21,
            connectedAt: connectedAt,
            retryConnectionAt: connectedAt
        ), "the persisted epoch stamp must make watchdog replays one-shot")
        XCTAssertTrue(AtriaBLEManager.shouldRetryProtectedR10ShortBurst(
            proofActive: true,
            connected: true,
            heartRateNotifying: true,
            priorPhysicalQualification: false,
            framesAfterActivation: 2,
            lastFrameAge: 21,
            connectedAt: connectedAt.addingTimeInterval(60),
            retryConnectionAt: connectedAt
        ), "a later physical connection receives its own bounded recovery")
    }

    func testV9ShortBurstRetryFailsClosedUntilCrcEvidenceIsStale() {
        let connectedAt = Date(timeIntervalSince1970: 2_000)
        for (frames, age) in [(0, 30.0), (2, 19.9), (75, 30.0)] {
            XCTAssertFalse(AtriaBLEManager.shouldRetryProtectedR10ShortBurst(
                proofActive: true,
                connected: true,
                heartRateNotifying: true,
                priorPhysicalQualification: false,
                framesAfterActivation: frames,
                lastFrameAge: age,
                connectedAt: connectedAt,
                retryConnectionAt: nil
            ))
        }
        XCTAssertFalse(AtriaBLEManager.shouldRetryProtectedR10ShortBurst(
            proofActive: true,
            connected: true,
            heartRateNotifying: false,
            priorPhysicalQualification: false,
            framesAfterActivation: 2,
            lastFrameAge: 30,
            connectedAt: connectedAt,
            retryConnectionAt: nil
        ), "motion recovery must never take priority over standard HR/RR")
    }

    func testPriorQualifiedV9ZeroFrameProofGetsOneBoundedRecovery() {
        let connectedAt = Date(timeIntervalSince1970: 3_000)
        XCTAssertTrue(AtriaBLEManager.shouldRetryProtectedR10ShortBurst(
            proofActive: true,
            connected: true,
            heartRateNotifying: true,
            priorPhysicalQualification: true,
            framesAfterActivation: 0,
            lastFrameAge: nil,
            connectedAt: connectedAt,
            retryConnectionAt: nil
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRetryProtectedR10ShortBurst(
            proofActive: true,
            connected: true,
            heartRateNotifying: true,
            priorPhysicalQualification: false,
            framesAfterActivation: 0,
            lastFrameAge: nil,
            connectedAt: connectedAt,
            retryConnectionAt: nil
        ), "zero frames from a never-qualified owner prove no safe retry profile")
        XCTAssertFalse(AtriaBLEManager.shouldRetryProtectedR10ShortBurst(
            proofActive: true,
            connected: true,
            heartRateNotifying: true,
            priorPhysicalQualification: true,
            framesAfterActivation: 0,
            lastFrameAge: nil,
            connectedAt: connectedAt,
            retryConnectionAt: connectedAt
        ), "the zero-frame recovery shares the persisted once-per-connection guard")
    }

    func testV9ShortBurstRetryReceivesAReachableFullDensityWindow() throws {
        let source = try leaseManagerSource()
        let retry = try XCTUnwrap(source.range(
            of: "private func retryProtectedR10ShortBurstIfEligible"
        ))
        let body = String(source[retry.lowerBound...].prefix(6_000))
        XCTAssertTrue(body.contains("protectedR10StabilityTask?.cancel()"))
        XCTAssertTrue(body.contains("Self.protectedR10EarlyDisconnectWindow"))
        XCTAssertTrue(body.contains("protectedR10StabilityWindowIsProven"))
        XCTAssertTrue(body.contains("response_event_data_short_burst_retry_insufficient_density"))
        XCTAssertTrue(body.contains("response_event_data_retry_receiving_crc_valid"))
    }

    func testInterruptedV9ProofSelectsFreshPureHRV10WithoutReplayingCommands() throws {
        let suite = "AtriaBLERecoveryCadenceTests.interruptedV9.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataMigrationV9")
        defaults.set(true, forKey: "atria.protectedR10.responseEventDataSequenceSentV9")
        defaults.set("protected_redp_v9", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("proving", forKey: "atria.protectedR10.cleanOwnerState")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .activatedPureHRV10Fallback)
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwner"),
                       "pure_hr_v10")
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "fallback_active")
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.rollback"))
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.responseEventDataSequenceSentV9"),
                      "the persisted command lease remains consumed")
    }

    func testInterruptedV7ProofRestartsPassiveEpochWithoutBreakingCommandLease() throws {
        let suite = "AtriaBLERecoveryCadenceTests.cleanOwnerResume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.cleanOwnerMigrationV7")
        defaults.set("protected_v7", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("proving", forKey: "atria.protectedR10.cleanOwnerState")
        defaults.set(123.0, forKey: "atria.protectedR10.cleanOwnerProofStartedAt")
        defaults.set(456.0, forKey: "atria.protectedR10.activationSentAt")

        XCTAssertEqual(AtriaBLEManager.prepareProtectedR10CleanOwnerAtLaunch(defaults: defaults),
                       .resumedProtectedV7Proof)
        XCTAssertEqual(defaults.string(forKey: "atria.protectedR10.cleanOwnerState"),
                       "protected_launch_pending")
        XCTAssertNil(defaults.object(forKey: "atria.protectedR10.cleanOwnerProofStartedAt"))
        XCTAssertEqual(defaults.double(forKey: "atria.protectedR10.activationSentAt"), 456,
                       "process recovery must preserve the persisted 3F01 lease")
    }

    func testCleanOwnerNamespacePolicyIsExplicitAndNeverReusesContaminatedOwner() {
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: "diagnostic-owner",
            cleanOwner: .protectedV7,
            streamSuppressed: false
        ), "diagnostic-owner")
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: nil,
            cleanOwner: .protectedV7,
            streamSuppressed: false
        ), "com.adidshaft.atria.ble-central-v7-protected")
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: nil,
            cleanOwner: .pureHRV8,
            streamSuppressed: true
        ), "com.adidshaft.atria.ble-central-v8-pure-hr")
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: nil,
            cleanOwner: .protectedV9,
            streamSuppressed: false
        ), "com.adidshaft.atria.ble-central-v9-response-event-data")
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: nil,
            cleanOwner: .pureHRV10,
            streamSuppressed: true
        ), "com.adidshaft.atria.ble-central-v10-pure-hr")
        XCTAssertEqual(AtriaBLEManager.protectedR10CentralRestoreIdentifier(
            diagnosticRestoreIdentifier: nil,
            cleanOwner: .legacy,
            streamSuppressed: true
        ), "com.adidshaft.atria.ble-central-v6-pure-hr")
    }

    func testCleanOwnerFencesHistoryOnlyDuringRadioTransitions() {
        for owner in [AtriaBLEManager.ProtectedR10CleanOwner.protectedV7,
                      .pureHRV8, .protectedV9, .pureHRV10] {
            for state in [AtriaBLEManager.ProtectedR10CleanOwnerState.protectedLaunchPending,
                          .proving, .fallbackPending] {
                XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
                    cleanOwner: owner,
                    state: state,
                    explicitUserRequest: false,
                    linkConnected: true
                ))
                XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
                    cleanOwner: owner,
                    state: state,
                    explicitUserRequest: true,
                    linkConnected: true
                ))
            }
        }
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
            cleanOwner: .legacy,
            state: .none,
            explicitUserRequest: false,
            linkConnected: true
        ))
    }

    func testConnectedAutomaticHistoryRequiresQualifiedProtectedV9CleanOwner() {
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
            cleanOwner: .protectedV9,
            state: .qualified,
            explicitUserRequest: false,
            linkConnected: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
            cleanOwner: .pureHRV10,
            state: .fallbackActive,
            explicitUserRequest: false,
            linkConnected: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
            cleanOwner: .protectedV7,
            state: .qualified,
            explicitUserRequest: false,
            linkConnected: true
        ))
    }

    func testFallbackOwnerCanRecoverHistoryWhenDisconnectedOrExplicitlyRequested() {
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
            cleanOwner: .pureHRV10,
            state: .fallbackActive,
            explicitUserRequest: false,
            linkConnected: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
            cleanOwner: .pureHRV10,
            state: .fallbackActive,
            explicitUserRequest: true,
            linkConnected: true
        ))
    }

    func testVerifiedExactGapAdmissionBypassesFallbackOwnerDeferral() {
        let handoff = AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: true,
            exactGapPending: true,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: false
        )
        XCTAssertTrue(handoff)
        XCTAssertFalse(
            !handoff && AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
                cleanOwner: .pureHRV10,
                state: .fallbackActive,
                explicitUserRequest: false,
                linkConnected: true
            ),
            "a durable verified exact gap must not be starved by the fallback owner"
        )
    }

    func testCleanOwnerProofWindowExpiresBoundedly() {
        XCTAssertFalse(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: false,
            attemptAge: 10_000
        ))
        XCTAssertFalse(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: true,
            attemptAge: 119.9
        ))
        XCTAssertFalse(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: true,
            attemptAge: 120
        ))
        XCTAssertTrue(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: true,
            attemptAge: 150
        ))
        XCTAssertTrue(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: true,
            attemptAge: nil
        ))
        XCTAssertTrue(AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
            proofActive: true,
            attemptAge: -1
        ), "a future/corrupt attempt epoch must fail closed")
    }

    func testCleanOwnerRuntimeNeverTogglesStream5OrStartsHistoryOnProofFailure() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "private func beginProtectedR10CleanOwnerProofIfNeeded"
        ))
        let end = try XCTUnwrap(source.range(
            of: "/// Stream 5 may be subscribed exactly once",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(body.contains("setNotifyValue"))
        XCTAssertFalse(body.contains("discoverServices"))
        XCTAssertFalse(body.contains("discoverCharacteristics"))
        XCTAssertFalse(body.contains("cancelPeripheralConnection"))
        XCTAssertFalse(body.contains("startOfflineHistoricalSync"))
        XCTAssertTrue(source.contains("sendProtectedR10ActivationIfReady"))
        XCTAssertTrue(source.contains("ProtectedR10RecoveryDecision"))
        XCTAssertTrue(source.contains("sendSingleLeasedActivation"))
        XCTAssertFalse(source.contains("beginProtectedR10PassiveReprobeIfEligible"))
        XCTAssertFalse(source.contains("resuppressProtectedR10Recovery"))
        XCTAssertTrue(source.contains("action=keep_current_link_untouched_select_fresh_pure_hr_next_process_no_history"))
        XCTAssertTrue(body.contains("protectedR10CleanOwnerState == .protectedLaunchPending"))
        XCTAssertTrue(body.contains("strapStream5NotifyConfirmed"))
        XCTAssertTrue(body.contains("forKey: Self.protectedR10CleanOwnerProofStartedAtKey"))

        let repairStart = try XCTUnwrap(source.range(
            of: "private func reassertR10NotificationIfConnected"
        ))
        let firstServiceLookup = try XCTUnwrap(source.range(
            of: "guard let strapService",
            range: repairStart.upperBound..<source.endIndex
        ))
        let protectedRepairGate = String(source[repairStart.lowerBound..<firstServiceLookup.lowerBound])
        XCTAssertTrue(protectedRepairGate.contains("if standardHROnlyMode"))
        XCTAssertTrue(protectedRepairGate.contains("return"))
        XCTAssertFalse(protectedRepairGate.contains("setNotifyValue"))
        XCTAssertFalse(protectedRepairGate.contains("discoverServices"))
        XCTAssertFalse(protectedRepairGate.contains("persistProtectedR10CleanOwnerFallback"))
        XCTAssertTrue(source.contains("persistProtectedR10FallbackForStream5Callback"))
        XCTAssertTrue(source.contains("clean_owner_stream5_notification_error"))
        XCTAssertTrue(source.contains("clean_owner_stream5_notification_inactive"))

        let cutoverStart = try XCTUnwrap(source.range(
            of: "private func beginProtectedR10LaunchConnectionCutoverIfNeeded"
        ))
        let cutoverEnd = try XCTUnwrap(source.range(
            of: "/// Explicit user action",
            range: cutoverStart.upperBound..<source.endIndex
        ))
        let cutoverBody = String(source[cutoverStart.lowerBound..<cutoverEnd.lowerBound])
        XCTAssertTrue(cutoverBody.contains("protectedR10CleanOwnerState == .protectedLaunchPending"))
        XCTAssertTrue(cutoverBody.contains("protectedR10CleanOwnerConnectionCutoverKey"))
        XCTAssertTrue(cutoverBody.contains("central.cancelPeripheralConnection(peripheral)"))
        XCTAssertFalse(cutoverBody.contains("startOfflineHistoricalSync"))
        XCTAssertTrue(source.contains("allowCleanOwnerLaunchCutover: true"))

        let protectedDiscoveryStart = try XCTUnwrap(source.range(
            of: "if discoveryUsesProtectedStandardHR,\n                   !protectedR10StreamSuppressed,\n                   ch.uuid == Self.UUIDs.strapStream5"
        ))
        let protectedDiscoveryEnd = try XCTUnwrap(source.range(
            of: "} else if discoveryUsesProtectedStandardHR, UUIDs.allNotify.contains(ch.uuid)",
            range: protectedDiscoveryStart.upperBound..<source.endIndex
        ))
        let protectedDiscovery = String(source[
            protectedDiscoveryStart.lowerBound..<protectedDiscoveryEnd.lowerBound
        ])
        XCTAssertTrue(protectedDiscovery.contains("protectedStream5NeedingInitialSubscribe = ch"))
        XCTAssertFalse(protectedDiscovery.contains("setNotifyValue"))

        let restoredStreamStart = try XCTUnwrap(source.range(
            of: "if let cachedStream5, cachedStream5.properties.contains(.notify)"
        ))
        let restoredStreamEnd = try XCTUnwrap(source.range(
            of: "if let cachedBattery",
            range: restoredStreamStart.upperBound..<source.endIndex
        ))
        let restoredStreamBody = String(source[
            restoredStreamStart.lowerBound..<restoredStreamEnd.lowerBound
        ])
        XCTAssertTrue(restoredStreamBody.contains("requestProtectedR10InitialProfileNotificationIfAllowed"))
        XCTAssertFalse(restoredStreamBody.contains("setNotifyValue"))
    }

    func testProtectedV9SequenceAndV10CutoverAreSingleBoundedOperations() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)

        let sequenceStart = try XCTUnwrap(source.range(
            of: "private func sendProtectedR10ResponseEventDataSequenceIfReady"
        ))
        let sequenceEnd = try XCTUnwrap(source.range(
            of: "private func scheduleProtectedR10BatteryDiscovery",
            range: sequenceStart.upperBound..<source.endIndex
        ))
        let sequenceBody = String(source[sequenceStart.lowerBound..<sequenceEnd.lowerBound])
        XCTAssertEqual(sequenceBody.components(separatedBy: "Cmd.sendR10R11Realtime").count - 1, 1)
        XCTAssertEqual(sequenceBody.components(separatedBy: "Cmd.toggleIMUMode").count - 1, 1)
        XCTAssertTrue(sequenceBody.contains("protectedR10CommandPacingDelay"))
        XCTAssertTrue(sequenceBody.contains("scheduleProtectedR10BatteryDiscovery"))
        let firstCommand = try XCTUnwrap(sequenceBody.range(of: "Cmd.sendR10R11Realtime"))
        let secondCommand = try XCTUnwrap(sequenceBody.range(of: "Cmd.toggleIMUMode"))
        let discovery = try XCTUnwrap(sequenceBody.range(
            of: "scheduleProtectedR10BatteryDiscovery"
        ))
        XCTAssertLessThan(firstCommand.lowerBound, secondCommand.lowerBound)
        XCTAssertLessThan(secondCommand.lowerBound, discovery.lowerBound)
        XCTAssertFalse(sequenceBody.contains("cancelPeripheralConnection"))
        XCTAssertFalse(sequenceBody.contains("startOfflineHistoricalSync"))

        XCTAssertEqual(AtriaBLEManager.protectedR10ResponseEventDataNotifyOrder,
                       AtriaBLEManager.motionHandshakeNotifyOrder(
                        useResponseEventDataProfile: true
                       ))
        XCTAssertEqual(AtriaBLEManager.protectedR10PostCommandStandardDiscoveryDelay, 15)

        let bringUpStart = try XCTUnwrap(source.range(
            of: "private func beginHRFirstDenseBringUpIfNeeded"
        ))
        let bringUpEnd = try XCTUnwrap(source.range(
            of: "private func beginProtectedR10BringUpForCurrentEpoch",
            range: bringUpStart.upperBound..<source.endIndex
        ))
        let bringUpBody = String(source[bringUpStart.lowerBound..<bringUpEnd.lowerBound])
        XCTAssertTrue(bringUpBody.contains("protectedR10CleanOwnerState == .protectedLaunchPending"))
        XCTAssertTrue(bringUpBody.contains("diagnostic_order"))
        XCTAssertLessThan(
            try XCTUnwrap(bringUpBody.range(of: "diagnostic_order")).lowerBound,
            try XCTUnwrap(bringUpBody.range(of: "heartRateCharacteristic?.isNotifying")).lowerBound
        )

        let standardDiscoveryStart = try XCTUnwrap(source.range(
            of: "private func scheduleProtectedR10BatteryDiscovery"
        ))
        let standardDiscoveryEnd = try XCTUnwrap(source.range(
            of: "private func sendProtectedR10ActivationIfReady",
            range: standardDiscoveryStart.upperBound..<source.endIndex
        ))
        let standardDiscoveryBody = String(source[
            standardDiscoveryStart.lowerBound..<standardDiscoveryEnd.lowerBound
        ])
        XCTAssertTrue(standardDiscoveryBody.contains("protectedR10PostCommandStandardDiscoveryDelay"))
        XCTAssertTrue(standardDiscoveryBody.contains("Self.UUIDs.heartRateService"))
        XCTAssertTrue(standardDiscoveryBody.contains("Self.UUIDs.batteryService"))

        let cutoverStart = try XCTUnwrap(source.range(
            of: "private func beginProtectedR10PureHRV10InProcessCutoverIfNeeded"
        ))
        let cutoverEnd = try XCTUnwrap(source.range(
            of: "/// A diagnostic restoration identifier",
            range: cutoverStart.upperBound..<source.endIndex
        ))
        let cutoverBody = String(source[cutoverStart.lowerBound..<cutoverEnd.lowerBound])
        XCTAssertEqual(cutoverBody.components(separatedBy: "CBCentralManager(").count - 1, 1)
        XCTAssertTrue(cutoverBody.contains("protectedR10PureHRV10InProcessCutoverKey"))
        XCTAssertTrue(cutoverBody.contains("fallbackActive.rawValue"))
        XCTAssertFalse(cutoverBody.contains("central.connect"))
        XCTAssertFalse(cutoverBody.contains("cancelPeripheralConnection"))
        XCTAssertFalse(cutoverBody.contains("writeValue"))
        XCTAssertFalse(cutoverBody.contains("startOfflineHistoricalSync"))
    }

    func testProtectedR10RecoveryDecisionIsPassiveFirstAndLeaseBounded() {
        typealias Decision = AtriaBLEManager.ProtectedR10RecoveryDecision
        func decide(age: TimeInterval = 20,
                    lease: TimeInterval = 0,
                    hrAge: TimeInterval? = 1,
                    battery: Int = 50,
                    notifying: Bool = true) -> Decision {
            AtriaBLEManager.protectedR10RecoveryDecision(
                pending: true,
                connected: true,
                stream5Notifying: notifying,
                activationSent: false,
                passiveObservationAge: age,
                activationAge: nil,
                activationLeaseRemaining: lease,
                stableHRDuration: 180,
                latestHRAge: hrAge,
                batteryLevel: battery,
                isCharging: false,
                frames: 0,
                lastFrameAge: nil
            )
        }

        XCTAssertEqual(decide(age: 19.9), .observePassive)
        XCTAssertEqual(decide(lease: 1), .observePassive)
        XCTAssertEqual(decide(hrAge: 10.1), .observePassive)
        XCTAssertEqual(decide(battery: 10), .observePassive)
        XCTAssertEqual(decide(notifying: false), .observePassive)
        XCTAssertEqual(decide(), .sendSingleLeasedActivation)
    }

    func testProtectedR10RecoveryDecisionRequiresDenseFreshProofOrResuppresses() {
        func decide(connected: Bool = true,
                    activationAge: TimeInterval? = 90,
                    frames: Int,
                    lastFrameAge: TimeInterval?) -> AtriaBLEManager.ProtectedR10RecoveryDecision {
            AtriaBLEManager.protectedR10RecoveryDecision(
                pending: true,
                connected: connected,
                stream5Notifying: true,
                activationSent: true,
                passiveObservationAge: 110,
                activationAge: activationAge,
                activationLeaseRemaining: 0,
                stableHRDuration: 300,
                latestHRAge: 1,
                batteryLevel: 50,
                isCharging: false,
                frames: frames,
                lastFrameAge: lastFrameAge
            )
        }

        XCTAssertEqual(decide(connected: false, frames: 0, lastFrameAge: nil), .resuppress)
        XCTAssertEqual(decide(activationAge: 19.9, frames: 0, lastFrameAge: nil), .awaitDensityProof)
        XCTAssertEqual(decide(activationAge: 20, frames: 0, lastFrameAge: nil), .resuppress)
        XCTAssertEqual(decide(frames: 74, lastFrameAge: 1), .resuppress)
        XCTAssertEqual(decide(frames: 75, lastFrameAge: 5.1), .resuppress)
        XCTAssertEqual(decide(frames: 75, lastFrameAge: 5), .qualify)
        XCTAssertEqual(AtriaBLEManager.protectedR10RecoveryDecision(
            pending: false,
            connected: true,
            stream5Notifying: true,
            activationSent: false,
            passiveObservationAge: 20,
            activationAge: nil,
            activationLeaseRemaining: 0,
            stableHRDuration: 300,
            latestHRAge: 1,
            batteryLevel: 50,
            isCharging: false,
            frames: 0,
            lastFrameAge: nil
        ), .none)
    }

    func testProductionBatteryProbeRemainsDisabledUntilItPreservesR10() {
        XCTAssertFalse(AtriaBLEManager.proprietaryBatteryRefreshEnabled)
    }

    func testAutomaticHistoryNeverSeizesQualifiedProtectedR10Transport() {
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForProtectedR10Continuity(
            standardHROnlyMode: true,
            explicitUserRequest: false
        ), "qualification must not release automatic history onto the live proprietary pipe")
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForProtectedR10Continuity(
            standardHROnlyMode: true,
            explicitUserRequest: true
        ), "a deliberate user request may proceed through the later capability gates")
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForProtectedR10Continuity(
            standardHROnlyMode: false,
            explicitUserRequest: false
        ))
    }

    func testProprietaryBatteryRefreshRequiresQualifiedQuietTransport() {
        let now = Date(timeIntervalSince1970: 20_000)
        let qualified = now.addingTimeInterval(-120)
        let common = (
            lastFrame: now.addingTimeInterval(-1),
            lastAttempt: Optional<Date>.none,
            circuit: Optional<Date>.none
        )

        XCTAssertTrue(AtriaBLEManager.shouldRequestProprietaryBatteryRefresh(
            standardHROnlyMode: true,
            stableTransportProven: true,
            connected: true,
            currentConnectionR10Frames: 120,
            lastR10FrameAt: common.lastFrame,
            transportQualifiedAt: qualified,
            batteryIsFresh: false,
            activeWorkout: false,
            historyActive: false,
            requestPending: false,
            lastAttemptAt: common.lastAttempt,
            circuitOpenUntil: common.circuit,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRequestProprietaryBatteryRefresh(
            standardHROnlyMode: true,
            stableTransportProven: true,
            connected: true,
            currentConnectionR10Frames: 120,
            lastR10FrameAt: common.lastFrame,
            transportQualifiedAt: now.addingTimeInterval(-119.999),
            batteryIsFresh: false,
            activeWorkout: false,
            historyActive: false,
            requestPending: false,
            lastAttemptAt: nil,
            circuitOpenUntil: nil,
            now: now
        ), "the extra two-minute post-qualification grace is strict")
    }

    func testProprietaryBatteryRefreshFailsClosedForSensitiveStatesAndCooldowns() {
        let now = Date(timeIntervalSince1970: 30_000)
        func eligible(workout: Bool = false,
                      history: Bool = false,
                      pending: Bool = false,
                      batteryFresh: Bool = false,
                      lastAttempt: Date? = nil,
                      circuit: Date? = nil) -> Bool {
            AtriaBLEManager.shouldRequestProprietaryBatteryRefresh(
                standardHROnlyMode: true,
                stableTransportProven: true,
                connected: true,
                currentConnectionR10Frames: 180,
                lastR10FrameAt: now,
                transportQualifiedAt: now.addingTimeInterval(-300),
                batteryIsFresh: batteryFresh,
                activeWorkout: workout,
                historyActive: history,
                requestPending: pending,
                lastAttemptAt: lastAttempt,
                circuitOpenUntil: circuit,
                now: now
            )
        }
        XCTAssertFalse(eligible(workout: true))
        XCTAssertFalse(eligible(history: true))
        XCTAssertFalse(eligible(pending: true))
        XCTAssertFalse(eligible(batteryFresh: true))
        XCTAssertFalse(eligible(lastAttempt: now.addingTimeInterval(-30 * 60 + 1)))
        XCTAssertFalse(eligible(circuit: now.addingTimeInterval(1)))
        XCTAssertTrue(eligible(lastAttempt: now.addingTimeInterval(-30 * 60)))
        XCTAssertTrue(eligible(circuit: now))
    }

    func testProprietaryBatteryResponseParsesOnlyMatchingValidatedCommand() {
        let response: [UInt8] = [0x24, 0x23, 0x1A, 0x0A, 0x01, 0xFF, 0x00,
                                 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(AtriaBLEManager.parseProprietaryBatteryResponse(
            response,
            expectedSequence: 0x23
        ), 26)
        XCTAssertNil(AtriaBLEManager.parseProprietaryBatteryResponse(
            response,
            expectedSequence: 0x22
        ))
        XCTAssertNil(AtriaBLEManager.parseProprietaryBatteryResponse(
            [0x24, 0x23, 0x1A, 0x0A, 0x00, 0xFF, 0x00],
            expectedSequence: 0x23
        ))
        XCTAssertNil(AtriaBLEManager.parseProprietaryBatteryResponse(
            [0x24, 0x23, 0x1A, 0x0A, 0x01, 0xE9, 0x03],
            expectedSequence: 0x23
        ), "100.1% is outside the protocol range")
    }

    func testAutonomousBatteryEventParsesCorroboratedFieldsAndRejectsMalformedFrames() throws {
        var frame = [UInt8](repeating: 0, count: 27)
        frame[0] = 0xAA
        frame[4] = 0x30
        frame[6] = 0x03
        frame[17] = 0xAE // 43.0% == 430 tenths
        frame[18] = 0x01
        frame[21] = 0x74 // 3700 mV
        frame[22] = 0x0E
        frame[26] = 1
        XCTAssertEqual(AtriaBLEManager.parseBatteryLevelEventFrame(frame),
                       AtriaBLEManager.BatteryEventReading(level: 43,
                                                           millivolts: 3_700,
                                                           isCharging: true))

        var wrongEvent = frame
        wrongEvent[6] = 0x04
        XCTAssertNil(AtriaBLEManager.parseBatteryLevelEventFrame(wrongEvent))
        var badSOC = frame
        badSOC[17] = 0xE9
        badSOC[18] = 0x03 // 100.1%
        XCTAssertNil(AtriaBLEManager.parseBatteryLevelEventFrame(badSOC))
        var badVoltage = frame
        badVoltage[21] = 0xB7
        badVoltage[22] = 0x0B // 2999 mV
        XCTAssertNil(AtriaBLEManager.parseBatteryLevelEventFrame(badVoltage))
        var badCharge = frame
        badCharge[26] = 2
        XCTAssertNil(AtriaBLEManager.parseBatteryLevelEventFrame(badCharge))
    }

    func testAutonomousMidrangeBatteryEventIsImmediatelyTrustedButContradictoryBoundaryIsNot() {
        let now = Date(timeIntervalSince1970: 50_000)
        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 65,
            previousAcceptedAt: now.addingTimeInterval(-86_400),
            reading: .init(level: 43, millivolts: 3_700, isCharging: false),
            receivedAt: now,
            pending: nil,
            previousIsCached: true,
            requiresFreshConfirmation: true
        ), .accept)

        guard case .quarantine = AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 43,
            previousAcceptedAt: now.addingTimeInterval(-60),
            reading: .init(level: 100, millivolts: 4_100, isCharging: true),
            receivedAt: now,
            pending: nil,
            previousIsCached: true,
            requiresFreshConfirmation: true
        ) else {
            return XCTFail("a 100% event at only 4.1 V without a near-full trajectory must remain quarantined")
        }
    }

    func testAutonomousBatteryEventAcceptsTrueFullAfterChargeEvidence() {
        let now = Date(timeIntervalSince1970: 50_000)
        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 97,
            previousAcceptedAt: now.addingTimeInterval(-8 * 60),
            reading: .init(level: 100, millivolts: 4_110, isCharging: true),
            receivedAt: now,
            pending: nil,
            previousIsCached: false,
            requiresFreshConfirmation: false,
            previousChargeStatus: .charging
        ), .accept, "CRC-backed SOC, high voltage, active charging and a near-full trajectory prove full")

        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 43,
            previousAcceptedAt: now.addingTimeInterval(-8 * 60),
            reading: .init(level: 100, millivolts: 4_220, isCharging: true),
            receivedAt: now,
            pending: nil,
            previousIsCached: true,
            requiresFreshConfirmation: true
        ), .accept, "an unmistakable near-4.2 V charging event can prove full after an app-off charge")

        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 99,
            previousAcceptedAt: now.addingTimeInterval(-8 * 60),
            reading: .init(level: 100, millivolts: 4_190, isCharging: false),
            receivedAt: now,
            pending: nil,
            previousIsCached: false,
            requiresFreshConfirmation: false,
            previousChargeStatus: .charging
        ), .accept, "full remains provable immediately after the charger clears its charging bit")
    }

    func testAutonomousBatteryEventAcceptsGradualLowAndEmptyOnlyWithElectricalProof() {
        let now = Date(timeIntervalSince1970: 50_000)
        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 14,
            previousAcceptedAt: now.addingTimeInterval(-10 * 60),
            reading: .init(level: 10, millivolts: 3_480, isCharging: false),
            receivedAt: now,
            pending: nil
        ), .accept)
        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 4,
            previousAcceptedAt: now.addingTimeInterval(-10 * 60),
            reading: .init(level: 0, millivolts: 3_180, isCharging: false),
            receivedAt: now,
            pending: nil
        ), .accept)

        for reading in [
            AtriaBLEManager.BatteryEventReading(level: 10, millivolts: 3_800, isCharging: false),
            AtriaBLEManager.BatteryEventReading(level: 10, millivolts: 3_480, isCharging: true),
            AtriaBLEManager.BatteryEventReading(level: 0, millivolts: 3_600, isCharging: false),
        ] {
            guard case .quarantine = AtriaBLEManager.batteryEventAcceptanceDecision(
                previousLevel: reading.level == 0 ? 4 : 14,
                previousAcceptedAt: now.addingTimeInterval(-10 * 60),
                reading: reading,
                receivedAt: now,
                pending: nil
            ) else {
                return XCTFail("electrically contradictory low/empty events must remain quarantined: \(reading)")
            }
        }
    }

    func testAutonomousBoundaryEventRejectsStaleOrImplausibleTrajectory() {
        let now = Date(timeIntervalSince1970: 50_000)
        let candidates: [(Int, Date?, AtriaBLEManager.BatteryEventReading)] = [
            (89, now.addingTimeInterval(-60), .init(level: 10, millivolts: 3_450, isCharging: false)),
            (14, now.addingTimeInterval(-(7 * 60 * 60)), .init(level: 10, millivolts: 3_450, isCharging: false)),
            (43, now.addingTimeInterval(-60), .init(level: 0, millivolts: 3_150, isCharging: false)),
            (43, now.addingTimeInterval(-60), .init(level: 100, millivolts: 4_220, isCharging: false)),
        ]
        for (previous, previousAt, reading) in candidates {
            guard case .quarantine = AtriaBLEManager.batteryEventAcceptanceDecision(
                previousLevel: previous,
                previousAcceptedAt: previousAt,
                reading: reading,
                receivedAt: now,
                pending: nil,
                previousIsCached: true,
                requiresFreshConfirmation: true
            ) else {
                return XCTFail("restoration-like boundary event must remain quarantined: \(reading)")
            }
        }
    }

    func testRelaunchNotificationCannotPromoteBoundaryButStrongEventCan() {
        let now = Date(timeIntervalSince1970: 50_000)
        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 96,
            previousAcceptedAt: now.addingTimeInterval(-5 * 60),
            incomingLevel: 100,
            receivedAt: now,
            pending: nil,
            previousIsCached: true,
            requiresFreshConfirmation: true,
            trustedCurrentConnectionNotification: true
        ) else {
            return XCTFail("a current 2A19 notification is transport proof, not electrical boundary proof")
        }

        XCTAssertEqual(AtriaBLEManager.batteryEventAcceptanceDecision(
            previousLevel: 96,
            previousAcceptedAt: now.addingTimeInterval(-5 * 60),
            reading: .init(level: 100, millivolts: 4_100, isCharging: true),
            receivedAt: now,
            pending: nil,
            previousIsCached: true,
            requiresFreshConfirmation: true,
            previousChargeStatus: .charging
        ), .accept, "the same relaunch may accept independently corroborated autonomous boundary truth")
    }

    func testProtectedR10OwnsTransportAcrossQualificationForAutomaticRecovery() {
        XCTAssertTrue(AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
            standardHROnlyMode: true,
            stableTransportProven: false
        ), "history must not contaminate the protected R10 stability trial")
        XCTAssertTrue(AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
            standardHROnlyMode: true,
            stableTransportProven: true
        ), "automatic history must not seize the proprietary pipe after qualification")
        XCTAssertFalse(AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
            standardHROnlyMode: true,
            stableTransportProven: true,
            explicitUserRequest: true
        ), "an explicit action may deliberately enter the separately guarded history path")
        XCTAssertFalse(AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
            standardHROnlyMode: false,
            stableTransportProven: false
        ))
    }

    func testProtectedR10StabilityRequiresDenseFreshCurrentEpochFrames() {
        let activation = Date(timeIntervalSince1970: 1_000)
        let now = activation.addingTimeInterval(90)
        XCTAssertTrue(AtriaBLEManager.protectedR10StabilityWindowIsProven(
            framesAfterActivation: 88,
            lastFrameAt: now.addingTimeInterval(-1),
            connectedAt: activation.addingTimeInterval(-5),
            activationAt: activation,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.protectedR10StabilityWindowIsProven(
            framesAfterActivation: 1,
            lastFrameAt: activation.addingTimeInterval(1),
            connectedAt: activation.addingTimeInterval(-5),
            activationAt: activation,
            now: now
        ), "one early frame must not qualify a silent transport")
        XCTAssertFalse(AtriaBLEManager.protectedR10StabilityWindowIsProven(
            framesAfterActivation: 88,
            lastFrameAt: now.addingTimeInterval(-10),
            connectedAt: activation.addingTimeInterval(-5),
            activationAt: activation,
            now: now
        ), "the final frame must still be fresh")
        XCTAssertFalse(AtriaBLEManager.protectedR10StabilityWindowIsProven(
            framesAfterActivation: 88,
            lastFrameAt: activation.addingTimeInterval(-1),
            connectedAt: activation.addingTimeInterval(-5),
            activationAt: activation,
            now: now
        ), "a restored frame from before this arm cannot qualify")
    }

    func testProtectedR10RollbackNeedsRepeatedEarlyDisconnects() {
        XCTAssertFalse(AtriaBLEManager.shouldLatchProtectedR10RollbackForEarlyDisconnect(
            activationSent: true,
            connectedDuration: 30,
            previousEarlyDisconnects: 0
        ))
        XCTAssertTrue(AtriaBLEManager.shouldLatchProtectedR10RollbackForEarlyDisconnect(
            activationSent: true,
            connectedDuration: 30,
            previousEarlyDisconnects: 1
        ))
        XCTAssertFalse(AtriaBLEManager.shouldLatchProtectedR10RollbackForEarlyDisconnect(
            activationSent: true,
            connectedDuration: 91,
            previousEarlyDisconnects: 4
        ))
        XCTAssertFalse(AtriaBLEManager.shouldLatchProtectedR10RollbackForEarlyDisconnect(
            activationSent: false,
            connectedDuration: 10,
            previousEarlyDisconnects: 4
        ))
    }

    func testProtectedR10MissingFrameRollbackRequiresSentActivationAndZeroFrames() {
        XCTAssertTrue(AtriaBLEManager.shouldLatchProtectedR10RollbackForMissingFrames(
            activationSent: true,
            framesAfterActivation: 0
        ))
        XCTAssertFalse(AtriaBLEManager.shouldLatchProtectedR10RollbackForMissingFrames(
            activationSent: true,
            framesAfterActivation: 1
        ))
        XCTAssertFalse(AtriaBLEManager.shouldLatchProtectedR10RollbackForMissingFrames(
            activationSent: false,
            framesAfterActivation: 0
        ))
    }

    func testProtectedR10ClassifiesPassiveFrameEpochWithoutTreatingItAsSessionArm() {
        let connectedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(AtriaBLEManager.protectedR10FrameBelongsToCurrentConnection(
            lastFrameAt: connectedAt.addingTimeInterval(0.2),
            connectedAt: connectedAt
        ))
        XCTAssertFalse(AtriaBLEManager.protectedR10FrameBelongsToCurrentConnection(
            lastFrameAt: connectedAt.addingTimeInterval(-0.1),
            connectedAt: connectedAt
        ))
        XCTAssertFalse(AtriaBLEManager.protectedR10FrameBelongsToCurrentConnection(
            lastFrameAt: nil,
            connectedAt: connectedAt
        ))
    }

    func testProtectedR10ActivationLeaseSurvivesReconnect() {
        let now = Date(timeIntervalSince1970: 50_000)

        XCTAssertEqual(AtriaBLEManager.protectedR10ActivationLeaseDelay(
            lastActivationAt: nil,
            now: now,
            minimumInterval: 600
        ), 0)
        XCTAssertEqual(AtriaBLEManager.protectedR10ActivationLeaseDelay(
            lastActivationAt: now.addingTimeInterval(-125),
            now: now,
            minimumInterval: 600
        ), 475,
        accuracy: 0.001)
        XCTAssertEqual(AtriaBLEManager.protectedR10ActivationLeaseDelay(
            lastActivationAt: now.addingTimeInterval(-900),
            now: now,
            minimumInterval: 600
        ), 0)
    }

    func testMotionHandshakeDiagnosticRequiresDoubleConsentAndUniqueRunID() throws {
        let type = AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.self
        XCTAssertNil(type.parse(arguments: [type.enableArgument]))
        XCTAssertNil(type.parse(arguments: [
            type.enableArgument, type.confirmationArgument
        ]))
        XCTAssertNil(type.parse(arguments: [
            type.enableArgument, type.confirmationArgument,
            type.runIDArgument, "invalid/run"
        ]))

        let configuration = try XCTUnwrap(type.parse(arguments: [
            type.enableArgument, type.confirmationArgument,
            type.runIDArgument, "trial-001",
            type.addHRDelayArgument, "75"
        ]))
        XCTAssertEqual(configuration.runID, "trial-001")
        XCTAssertEqual(configuration.addHRDelay, 75)
        XCTAssertFalse(configuration.sendSingleR10Activation)
        XCTAssertEqual(configuration.restoreIdentifier,
                       "com.adidshaft.atria.ble-motion-diagnostic-trial-001")

        let activated = try XCTUnwrap(type.parse(arguments: [
            type.enableArgument, type.confirmationArgument,
            type.runIDArgument, "trial-002",
            type.activationConsentArgument
        ]))
        XCTAssertTrue(activated.sendSingleR10Activation)
    }

    func testMotionHandshakeDiagnosticBoundsHRDelay() throws {
        let type = AtriaBLEManager.MotionHandshakeDiagnosticConfiguration.self
        let arguments = [
            type.enableArgument, type.confirmationArgument,
            type.runIDArgument, "bounded",
            type.addHRDelayArgument, "2"
        ]
        XCTAssertEqual(try XCTUnwrap(type.parse(arguments: arguments)).addHRDelay, 60)
    }

    func testProtectedStandardHRObservesOnlyProductionR10Stream() {
        XCTAssertTrue(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream5
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapRX
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream4
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapStream7
        ))
        XCTAssertFalse(AtriaBLEManager.shouldObservePassiveR10InProtectedStandardHR(
            characteristicUUID: AtriaBLEManager.UUIDs.strapTX
        ))
    }

    func testProtectedBackgroundPreservesPersistedSafeRadioMode() {
        XCTAssertTrue(AtriaBLEManager.shouldUseStandardHROnlyInProtectedBackground(
            userSelectedBatterySaver: false,
            persistedStandardHROnly: true
        ), "A background edge must not undo the production-safe HR transport")
        XCTAssertFalse(AtriaBLEManager.shouldUseStandardHROnlyInProtectedBackground(
            userSelectedBatterySaver: true,
            persistedStandardHROnly: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldUseStandardHROnlyInProtectedBackground(
            userSelectedBatterySaver: true,
            persistedStandardHROnly: true
        ), "An explicit battery-saver choice remains authoritative")
    }

    func testLongWearSupervisorRunsInFullProtocolAndBatterySaverModes() {
        XCTAssertTrue(AtriaBLEManager.shouldRunLongWearSupervisor(
            longWearEnabled: true,
            standardHROnlyMode: false
        ), "Full protocol must retain checkpoints, workout analysis and watchdog recovery")
        XCTAssertTrue(AtriaBLEManager.shouldRunLongWearSupervisor(
            longWearEnabled: true,
            standardHROnlyMode: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRunLongWearSupervisor(
            longWearEnabled: false,
            standardHROnlyMode: false
        ))
    }

    func testUnexpectedDisconnectPreservesExplicitWorkoutWithoutLongWear() {
        XCTAssertTrue(AtriaBLEManager.shouldPreserveSessionOnUnexpectedDisconnect(
            longWearEnabled: false,
            activeExplicitWorkout: true,
            userRequestedDisconnect: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPreserveSessionOnUnexpectedDisconnect(
            longWearEnabled: false,
            activeExplicitWorkout: true,
            userRequestedDisconnect: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldPreserveSessionOnUnexpectedDisconnect(
            longWearEnabled: false,
            activeExplicitWorkout: false,
            userRequestedDisconnect: false
        ), "transient reconnects must not create hundreds of sub-minute saved fragments")
    }

    func testExplicitWorkoutAlwaysDefersHistoricalRadioTakeover() {
        XCTAssertTrue(AtriaBLEManager.shouldDeferOfflineSyncForExplicitWorkout(
            activeExplicitWorkout: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldDeferOfflineSyncForExplicitWorkout(
            activeExplicitWorkout: false
        ))
    }

    func testAutomaticHistoryAdmissionDefersUnderThermalPressure() {
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForThermalPressure(
            thermalPressure: true,
            explicitUserRequest: false
        ), "an aged automatic retry must preserve live capture under serious pressure")
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForThermalPressure(
            thermalPressure: false,
            explicitUserRequest: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForThermalPressure(
            thermalPressure: true,
            explicitUserRequest: true
        ), "an explicit user/research request remains authoritative")
    }

    func testThermalHistoryDeferralRetainsAndReschedulesRangeLossRecovery() throws {
        let source = try leaseManagerSource()
        XCTAssertTrue(source.contains(
            "shouldDeferAutomaticOfflineSyncForThermalPressure("
        ))
        XCTAssertTrue(source.contains(
            "defaults.set(\"deferred_thermal_pressure\""
        ))
        XCTAssertTrue(source.contains(
            "self.scheduleRangeLossBackfillIfNeeded(reason: \"thermal_pressure_recovered\")"
        ), "recovery must actively retry the durable gap, not merely reconcile metadata")
    }

    func testConnectedAutomaticHistoryRunsOnlyForVerifiedExactGapRecovery() {
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: true,
            explicitUserRequest: false
        ), "aged/forced automatic retries must not interrupt a healthy connected stream")
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: false,
            explicitUserRequest: false
        ), "pending recovery may arm before reconnect when the transport is already down")
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: false,
            linkConnecting: true,
            explicitUserRequest: false
        ), "an automatic drain must not cancel CoreBluetooth's standing realtime reconnect")
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: false,
            linkConnecting: true,
            explicitUserRequest: true
        ), "an explicit request queues behind an in-flight reconnect instead of manufacturing churn")
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: true,
            explicitUserRequest: true
        ), "a deliberate user sync remains authoritative")
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: true,
            explicitUserRequest: false,
            exactGapPending: true,
            verifiedMetricRecovery: true
        ), "a verified gap still needs the stable-reconnect handoff policy")
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: true,
            explicitUserRequest: false,
            exactGapPending: true,
            verifiedMetricRecovery: true,
            automaticConnectedHandoffAllowed: true
        ), "a separately qualified handoff must reach the journaled fresh-owner cutover")
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: true,
            explicitUserRequest: false,
            exactGapPending: true,
            verifiedMetricRecovery: false
        ), "an unverified decoder must never seize the live pipe")
    }

    func testAutomaticConnectedHistoryHandoffRequiresFreshnessAndBackoff() {
        let now = Date(timeIntervalSince1970: 50_000)
        let eligible: (Bool, Bool, Date?, Date?, Date?, Date?) -> Bool = {
            workout, verified, connectedAt, acceptedAt, requestedAt, lastAttemptAt in
            AtriaBLEManager.shouldAttemptAutomaticConnectedHistoricalHandoff(
                linkConnected: true,
                exactGapPending: true,
                verifiedMetricRecovery: verified,
                activeExplicitWorkout: workout,
                syncInProgress: false,
                connectedAt: connectedAt,
                hasContact: true,
                acceptedSampleCount: 20,
                lastAcceptedHRAt: acceptedAt,
                requestedAt: requestedAt,
                lastAttemptAt: lastAttemptAt,
                now: now
            )
        }

        XCTAssertTrue(eligible(false, true,
                                now.addingTimeInterval(-61),
                                now.addingTimeInterval(-5),
                                now.addingTimeInterval(-91),
                                now.addingTimeInterval(-121)),
                      "all gates admit one journaled fresh-owner cutover")
        XCTAssertFalse(eligible(true, true,
                                now.addingTimeInterval(-61),
                                now.addingTimeInterval(-5),
                                now.addingTimeInterval(-91), nil))
        XCTAssertFalse(eligible(false, false,
                                now.addingTimeInterval(-61),
                                now.addingTimeInterval(-5),
                                now.addingTimeInterval(-91), nil))
        XCTAssertFalse(eligible(false, true,
                                now.addingTimeInterval(-20),
                                now.addingTimeInterval(-5),
                                now.addingTimeInterval(-91), nil))
        XCTAssertFalse(eligible(false, true,
                                now.addingTimeInterval(-61),
                                now.addingTimeInterval(-50),
                                now.addingTimeInterval(-91), nil))
        XCTAssertFalse(eligible(false, true,
                                now.addingTimeInterval(-61),
                                now.addingTimeInterval(-5),
                                now.addingTimeInterval(-91),
                                now.addingTimeInterval(-30)))
    }

    func testAcceptedHRQualifiesPendingRecoveryWithoutTimerReliance() throws {
        let source = try leaseManagerSource()
        let methodStart = try XCTUnwrap(source.range(
            of: "private func attemptQualifiedRangeLossBackfillAfterAcceptedHRIfNeeded"
        ))
        let methodEnd = try XCTUnwrap(source.range(
            of: "private func scheduleStaleArmedRangeLossBackfillReconciliation",
            range: methodStart.upperBound..<source.endIndex
        ))
        let method = String(source[methodStart.lowerBound..<methodEnd.lowerBound])
        XCTAssertTrue(method.contains("!foregroundInteractiveMode"))
        XCTAssertTrue(method.contains("automaticConnectedHistoricalHandoffIsEligible(now: now)"))
        XCTAssertTrue(method.contains("allowConnectedAutomaticHandoff: true"))
        XCTAssertTrue(method.contains("rangeLossBackfillTask?.cancel()"),
                      "the accepted-HR event must replace a suspended retry timer")

        let acceptedStart = try XCTUnwrap(source.range(of: "private func acceptHeartRate"))
        let acceptedEnd = try XCTUnwrap(source.range(
            of: "private func beginAcceptedHeartRateBatch",
            range: acceptedStart.upperBound..<source.endIndex
        ))
        let accepted = String(source[acceptedStart.lowerBound..<acceptedEnd.lowerBound])
        XCTAssertTrue(accepted.contains(
            "attemptQualifiedRangeLossBackfillAfterAcceptedHRIfNeeded(\n                now: sampleTime"
        ))
    }

    func testOnlyDeliberateUIActionsCountAsConnectedHistoricalSyncIntent() {
        XCTAssertTrue(AtriaBLEManager.isExplicitUserOfflineSyncReason("manual_user_request"))
        XCTAssertTrue(AtriaBLEManager.isExplicitUserOfflineSyncReason("pull_to_refresh"))
        XCTAssertTrue(AtriaBLEManager.isExplicitUserOfflineSyncReason("home_missed_data_banner"))
        XCTAssertFalse(AtriaBLEManager.isExplicitUserOfflineSyncReason("confirmed_workout_archive_gap"))
        XCTAssertFalse(AtriaBLEManager.isExplicitUserOfflineSyncReason("sleep_auto_confirm_retry"))
        XCTAssertFalse(AtriaBLEManager.isExplicitUserOfflineSyncReason("bg_processing"))
    }

    func testProtectedHistoryRecoveryOwnsVerifiedGapAcrossImmediateReconnect() {
        let now = Date(timeIntervalSince1970: 20_000)
        XCTAssertTrue(AtriaBLEManager.hasValidRangeLossBackfillRequest(
            pending: true,
            requestedAt: now.timeIntervalSince1970 - 30,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.hasValidRangeLossBackfillRequest(
            pending: true,
            requestedAt: nil,
            now: now
        ), "a stranded pending bit is not enough to seize the history transport")
        XCTAssertFalse(AtriaBLEManager.hasValidRangeLossBackfillRequest(
            pending: true,
            requestedAt: now.timeIntervalSince1970 + 60,
            now: now
        ), "a corrupt future request must fail closed")

        let disconnectedGapAllowed = AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: false,
            exactGapPending: true,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: false
        )
        XCTAssertTrue(disconnectedGapAllowed)
        let continuityDeferred = !disconnectedGapAllowed
            && AtriaBLEManager.shouldDeferAutomaticOfflineSyncForProtectedR10Continuity(
                standardHROnlyMode: true,
                explicitUserRequest: false
            )
        let qualificationDeferred = !disconnectedGapAllowed
            && AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
                standardHROnlyMode: true,
                stableTransportProven: true,
                explicitUserRequest: false
            )
        XCTAssertFalse(continuityDeferred)
        XCTAssertFalse(qualificationDeferred,
                       "the protected guards must not make the admitted history-first reconnect unreachable")
        XCTAssertTrue(AtriaBLEManager.shouldDeferOfflineSyncForProtectedR10Qualification(
            standardHROnlyMode: true,
            stableTransportProven: true,
            explicitUserRequest: false
        ), "without the narrow admission, protected realtime remains authoritative")
        XCTAssertTrue(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: true,
            exactGapPending: true,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: false
        ), "the standing reconnect must not permanently starve a verified exact-gap drain")
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: false,
            exactGapPending: false,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: false
        ))
    }

    func testUnknownRestoredProtectedLinkQualifiesPendingHistoryByServiceDiscovery() {
        XCTAssertTrue(AtriaBLEManager.shouldQualifyPendingHistoryByServiceDiscovery(
            exactGapPending: true,
            verifiedHistoryCapability: false,
            model: .unknown,
            linkConnected: true,
            activeExplicitWorkout: false,
            syncInProgress: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldQualifyPendingHistoryByServiceDiscovery(
            exactGapPending: true,
            verifiedHistoryCapability: true,
            model: .unknown,
            linkConnected: true,
            activeExplicitWorkout: false,
            syncInProgress: false
        ), "a previously verified peripheral needs no extra discovery")
        XCTAssertFalse(AtriaBLEManager.shouldQualifyPendingHistoryByServiceDiscovery(
            exactGapPending: true,
            verifiedHistoryCapability: false,
            model: .strap4Class,
            linkConnected: true,
            activeExplicitWorkout: false,
            syncInProgress: false
        ), "a known hardware class must proceed through the ordinary gate")
        XCTAssertFalse(AtriaBLEManager.shouldQualifyPendingHistoryByServiceDiscovery(
            exactGapPending: true,
            verifiedHistoryCapability: false,
            model: .unknown,
            linkConnected: true,
            activeExplicitWorkout: true,
            syncInProgress: false
        ), "service qualification must never compete with a workout")
        XCTAssertFalse(AtriaBLEManager.shouldQualifyPendingHistoryByServiceDiscovery(
            exactGapPending: false,
            verifiedHistoryCapability: false,
            model: .unknown,
            linkConnected: true,
            activeExplicitWorkout: false,
            syncInProgress: false
        ), "ordinary live wear does not need proprietary discovery")
    }

    func testProtectedHistoryRecoveryNeverPreemptsWorkoutOrUnverifiedHardware() {
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: false,
            exactGapPending: true,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: true,
            syncInProgress: false,
            explicitUserRequest: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: false,
            exactGapPending: true,
            verifiedHistoryCapability: false,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: false,
            exactGapPending: true,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: true,
            explicitUserRequest: false
        ))
    }

    func testDecodedHistoryLayoutIsNotMisrepresentedAsTransactionRecovery() {
        XCTAssertTrue(AtriaBLEManager.supportsVerifiedHistoricalRecovery(
            model: .strap4Class,
            previouslyVerified: false
        ))
        XCTAssertFalse(AtriaBLEManager.supportsDecodedHistoricalMetricLayout(
            model: .strap4Class,
            previouslyVerified: false,
            hasValidatedMetricLayout: false
        ), "raw archive support cannot repair HR or steps without a validated layout")
        XCTAssertTrue(AtriaBLEManager.supportsDecodedHistoricalMetricLayout(
            model: .strap4Class,
            previouslyVerified: false,
            hasValidatedMetricLayout: true
        ), "the decoder can be valid while the recovery transaction remains unproven")
        XCTAssertFalse(AtriaBLEManager.supportsDecodedHistoricalMetricLayout(
            model: .unknown,
            previouslyVerified: false,
            hasValidatedMetricLayout: true
        ), "a decoder alone cannot assert an unverified hardware transport")

        XCTAssertFalse(AtriaBLEManager.supportsVerifiedHistoricalTransactionRecovery(
            model: .strap4Class,
            previouslyVerified: false,
            hasValidatedMetricLayout: true,
            exactRangeTransportEnabledAndProven: false,
            clockAuthorityEnabledAndProven: true
        ), "clock authority cannot compensate for an unproven exact selector")
        XCTAssertFalse(AtriaBLEManager.supportsVerifiedHistoricalTransactionRecovery(
            model: .strap4Class,
            previouslyVerified: false,
            hasValidatedMetricLayout: true,
            exactRangeTransportEnabledAndProven: true,
            clockAuthorityEnabledAndProven: false
        ), "an exact selector cannot compensate for unverified timestamp authority")
        XCTAssertTrue(AtriaBLEManager.supportsVerifiedHistoricalTransactionRecovery(
            model: .strap4Class,
            previouslyVerified: false,
            hasValidatedMetricLayout: true,
            exactRangeTransportEnabledAndProven: true,
            clockAuthorityEnabledAndProven: true
        ))
    }

    func testProductionAutomaticHistoryCapabilityUsesVerifiedFullDrainPath() {
        XCTAssertFalse(
            AtriaBLEManager.productionHistoricalExactRangeTransportEnabledAndProven
        )
        XCTAssertTrue(
            AtriaBLEManager.productionHistoricalClockAuthorityEnabledAndProven
        )
        let transactionReady = AtriaBLEManager.supportsVerifiedHistoricalTransactionRecovery(
            model: .strap4Class,
            previouslyVerified: true,
            hasValidatedMetricLayout: true,
            fullDrainGapRecoveryEnabled:
                AtriaBLEManager.productionHistoricalFullDrainGapRecoveryEnabled
        )
        XCTAssertTrue(transactionReady)

        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(AtriaBLEManager.shouldAttemptAutomaticConnectedHistoricalHandoff(
            linkConnected: true,
            exactGapPending: true,
            verifiedMetricRecovery: transactionReady,
            activeExplicitWorkout: false,
            syncInProgress: false,
            connectedAt: now.addingTimeInterval(-120),
            hasContact: true,
            acceptedSampleCount: 100,
            lastAcceptedHRAt: now.addingTimeInterval(-1),
            requestedAt: now.addingTimeInterval(-120),
            lastAttemptAt: nil,
            now: now
        ), "a verified exact gap may use the journaled fresh-owner handoff after the live-link safety gates pass")
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: true,
            explicitUserRequest: false,
            exactGapPending: true,
            verifiedMetricRecovery: transactionReady,
            automaticConnectedHandoffAllowed: true
        ))
    }

    func testRawOnlyGapArchiveRunsOnceAtASafeNaturalDisconnect() {
        XCTAssertTrue(AtriaBLEManager.shouldAttemptRawOnlyHistoricalRecovery(
            exactGapPending: true,
            rawHistoryVerified: true,
            metricHistoryVerified: false,
            linkConnected: false,
            activeExplicitWorkout: false,
            explicitUserRequest: false,
            rawGapAlreadyArchived: false
        ))

        let unsafeVariants: [(Bool, Bool, Bool, Bool, Bool, Bool, Bool)] = [
            (false, true, false, false, false, false, false),
            (true, false, false, false, false, false, false),
            (true, true, true, false, false, false, false),
            (true, true, false, true, false, false, false),
            (true, true, false, false, true, false, false),
            (true, true, false, false, false, true, false),
            (true, true, false, false, false, false, true),
        ]
        for variant in unsafeVariants {
            XCTAssertFalse(AtriaBLEManager.shouldAttemptRawOnlyHistoricalRecovery(
                exactGapPending: variant.0,
                rawHistoryVerified: variant.1,
                metricHistoryVerified: variant.2,
                linkConnected: variant.3,
                activeExplicitWorkout: variant.4,
                explicitUserRequest: variant.5,
                rawGapAlreadyArchived: variant.6
            ))
        }
    }

    func testHistoricalGapFingerprintIsStableAndChangesWithExactRange() throws {
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let first = AtriaHistoricalGapLedger.Window(
            id: firstID,
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 130),
            reason: "disconnect"
        )
        let second = AtriaHistoricalGapLedger.Window(
            id: secondID,
            start: Date(timeIntervalSince1970: 200),
            end: Date(timeIntervalSince1970: 260),
            reason: "accepted_hr_gap"
        )

        let forward = try XCTUnwrap(AtriaBLEManager.historicalGapFingerprint([first, second]))
        XCTAssertEqual(forward,
                       AtriaBLEManager.historicalGapFingerprint([second, first]))
        var changed = second
        changed.end = Date(timeIntervalSince1970: 261)
        XCTAssertNotEqual(forward,
                          AtriaBLEManager.historicalGapFingerprint([first, changed]))
        XCTAssertNil(AtriaBLEManager.historicalGapFingerprint([]))
    }

    func testLegacyRequestedGapAlsoHasAStableOneShotFingerprint() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_300)
        let first = try XCTUnwrap(AtriaBLEManager.historicalGapFingerprint(
            windows: [],
            recoveryStart: start,
            recoveryEnd: end,
            requestedAt: 900
        ))
        XCTAssertEqual(first, AtriaBLEManager.historicalGapFingerprint(
            windows: [],
            recoveryStart: start,
            recoveryEnd: end,
            requestedAt: 900
        ))
        XCTAssertNotEqual(first, AtriaBLEManager.historicalGapFingerprint(
            windows: [],
            recoveryStart: start,
            recoveryEnd: end.addingTimeInterval(1),
            requestedAt: 900
        ))
        XCTAssertNil(AtriaBLEManager.historicalGapFingerprint(
            windows: [],
            recoveryStart: nil,
            recoveryEnd: nil,
            requestedAt: nil
        ))
    }

    func testSameLevelBatteryReadPreservesOnlyFreshIndependentChargingProof() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(AtriaBLEManager.shouldPreserveFreshChargingEvidence(
            currentStatus: .charging,
            lastEvidenceAt: now.addingTimeInterval(-90),
            receivedAt: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPreserveFreshChargingEvidence(
            currentStatus: .charging,
            lastEvidenceAt: now.addingTimeInterval(-91),
            receivedAt: now
        ), "proof-building may take minutes, but stale Charging must still fail closed after 90 seconds")
        XCTAssertTrue(AtriaBLEManager.shouldPreserveFreshChargingEvidence(
            currentStatus: .charging,
            lastEvidenceAt: now.addingTimeInterval(-480),
            receivedAt: now,
            maximumAge: 600
        ), "a percentage-only callback must not erase the physical event between its normal reports")
        XCTAssertFalse(AtriaBLEManager.shouldPreserveFreshChargingEvidence(
            currentStatus: .charging,
            lastEvidenceAt: now.addingTimeInterval(-601),
            receivedAt: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPreserveFreshChargingEvidence(
            currentStatus: .levelOnly,
            lastEvidenceAt: now,
            receivedAt: now,
            maximumAge: 600
        ), "2A19 cannot originate charging state")
        XCTAssertFalse(AtriaBLEManager.shouldPreserveFreshChargingEvidence(
            currentStatus: .charging,
            lastEvidenceAt: nil,
            receivedAt: now,
            maximumAge: 600
        ))
        XCTAssertTrue(AtriaBLEManager.hasFreshBatteryRiseEvidence(
            lastRiseAt: now.addingTimeInterval(-599),
            receivedAt: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.hasFreshBatteryRiseEvidence(
            lastRiseAt: now.addingTimeInterval(-601),
            receivedAt: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.hasFreshBatteryRiseEvidence(
            lastRiseAt: nil,
            receivedAt: now,
            maximumAge: 600
        ))
    }

    func testChargingTrajectoryNeedsMultipleAcceptedMidrangeRisesAcrossTime() throws {
        let start = Date(timeIntervalSince1970: 20_000)
        let first = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 22,
            previousAcceptedAt: start,
            newLevel: 23,
            receivedAt: start.addingTimeInterval(20)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRiseCandidateProvesCharging(first))
        let second = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: first,
            previousLevel: 23,
            previousAcceptedAt: start.addingTimeInterval(20),
            newLevel: 24,
            receivedAt: start.addingTimeInterval(65)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRiseCandidateProvesCharging(second))
        let third = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: second,
            previousLevel: 24,
            previousAcceptedAt: start.addingTimeInterval(65),
            newLevel: 25,
            receivedAt: start.addingTimeInterval(100)
        ))
        XCTAssertTrue(AtriaBLEManager.batteryRiseCandidateProvesCharging(third))
        XCTAssertNil(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: third,
            previousLevel: 25,
            previousAcceptedAt: start.addingTimeInterval(100),
            newLevel: 24,
            receivedAt: start.addingTimeInterval(125)
        ), "a decline immediately revokes the charge trajectory")
    }

    func testReconnectBaselineDoesNotEraseFreshPersistedChargingTruth() {
        let now = Date(timeIntervalSince1970: 15_000)
        XCTAssertTrue(AtriaBLEManager.shouldRetainPersistedChargingAcrossReconnect(
            persistedStatus: .charging,
            persistedAt: now.addingTimeInterval(-599),
            batteryRecentlyDropping: false,
            now: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRetainPersistedChargingAcrossReconnect(
            persistedStatus: .charging,
            persistedAt: now.addingTimeInterval(-601),
            batteryRecentlyDropping: false,
            now: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRetainPersistedChargingAcrossReconnect(
            persistedStatus: .levelOnly,
            persistedAt: now,
            batteryRecentlyDropping: false,
            now: now,
            maximumAge: 600
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRetainPersistedChargingAcrossReconnect(
            persistedStatus: .charging,
            persistedAt: now,
            batteryRecentlyDropping: true,
            now: now,
            maximumAge: 600
        ))
    }

    func testRiseCandidateSurvivesOnlySameStrapShortReconnect() throws {
        let start = Date(timeIntervalSince1970: 16_000)
        let strapID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let otherID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let candidate = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 30,
            previousAcceptedAt: start,
            newLevel: 31,
            receivedAt: start.addingTimeInterval(20)
        ))

        XCTAssertEqual(AtriaBLEManager.batteryRiseCandidateAfterReconnect(
            candidate,
            candidatePeripheralID: strapID,
            connectedPeripheralID: strapID,
            now: start.addingTimeInterval(40),
            maximumAge: 600
        ), candidate)
        XCTAssertNil(AtriaBLEManager.batteryRiseCandidateAfterReconnect(
            candidate,
            candidatePeripheralID: strapID,
            connectedPeripheralID: otherID,
            now: start.addingTimeInterval(40),
            maximumAge: 600
        ))
        XCTAssertNil(AtriaBLEManager.batteryRiseCandidateAfterReconnect(
            candidate,
            candidatePeripheralID: strapID,
            connectedPeripheralID: strapID,
            now: start.addingTimeInterval(621),
            maximumAge: 600
        ))
        XCTAssertNil(AtriaBLEManager.batteryRiseCandidateAfterReconnect(
            candidate,
            candidatePeripheralID: strapID,
            connectedPeripheralID: strapID,
            now: start,
            maximumAge: 600
        ))
    }

    func testChargingTrajectoryRejectsSingleJumpSentinelsAndFastCorrections() throws {
        let start = Date(timeIntervalSince1970: 30_000)
        let jump = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 22,
            previousAcceptedAt: start,
            newLevel: 34,
            receivedAt: start.addingTimeInterval(90)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRiseCandidateProvesCharging(jump),
                       "one large correction cannot claim external power")
        XCTAssertNil(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 99,
            previousAcceptedAt: start,
            newLevel: 100,
            receivedAt: start.addingTimeInterval(60)
        ))
        let rapidSecond = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: jump,
            previousLevel: 34,
            previousAcceptedAt: start.addingTimeInterval(90),
            newLevel: 35,
            receivedAt: start.addingTimeInterval(95)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRiseCandidateProvesCharging(rapidSecond),
                       "one correction plus one later rise cannot claim charging with production defaults")
        let sustainedThird = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: rapidSecond,
            previousLevel: 35,
            previousAcceptedAt: start.addingTimeInterval(95),
            newLevel: 36,
            receivedAt: start.addingTimeInterval(130)
        ))
        XCTAssertTrue(AtriaBLEManager.batteryRiseCandidateProvesCharging(sustainedThird),
                      "two post-correction rises may establish a new trajectory")
    }

    func testChargingTrajectoryAcceptsCoalescedSixPointRiseAcrossRealTime() throws {
        let start = Date(timeIntervalSince1970: 35_000)
        let candidate = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 11,
            previousAcceptedAt: start,
            newLevel: 17,
            receivedAt: start.addingTimeInterval(90)
        ))

        XCTAssertEqual(candidate.startLevel, 11)
        XCTAssertEqual(candidate.lastLevel, 17)
        XCTAssertTrue(AtriaBLEManager.batteryRiseCandidateProvesCharging(candidate),
                      "a bounded coalesced rise should surface the charging bolt")

        let instantCorrection = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 43,
            previousAcceptedAt: start,
            newLevel: 49,
            receivedAt: start.addingTimeInterval(5)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRiseCandidateProvesCharging(instantCorrection))
    }

    func testInitialBatteryValueAfterDidConnectBelongsToCurrentPhysicalLink() {
        let connectedAt = Date(timeIntervalSince1970: 36_000)

        XCTAssertTrue(AtriaBLEManager.batteryValueBelongsToCurrentConnection(
            peripheralConnected: true,
            connectionStartedAt: connectedAt,
            receivedAt: connectedAt.addingTimeInterval(0.2)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryValueBelongsToCurrentConnection(
            peripheralConnected: false,
            connectionStartedAt: connectedAt,
            receivedAt: connectedAt.addingTimeInterval(0.2)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryValueBelongsToCurrentConnection(
            peripheralConnected: true,
            connectionStartedAt: nil,
            receivedAt: connectedAt.addingTimeInterval(0.2)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryValueBelongsToCurrentConnection(
            peripheralConnected: true,
            connectionStartedAt: connectedAt,
            receivedAt: connectedAt.addingTimeInterval(-0.2)
        ))
    }

    func testR10DisconnectStormFuseRequiresConsecutiveCurrentFailures() {
        XCTAssertFalse(AtriaBLEManager.shouldIsolateRecentProtectedR10DisconnectStorm(
            alreadySuppressed: false,
            consecutiveEarlyDisconnects: 0,
            lastDisconnectAge: 2,
            connectedDuration: 11,
            lastR10Age: 8
        ), "a large lifetime disconnect total must not turn one install edge into a storm")
        XCTAssertFalse(AtriaBLEManager.shouldIsolateRecentProtectedR10DisconnectStorm(
            alreadySuppressed: false,
            consecutiveEarlyDisconnects: 1,
            lastDisconnectAge: 2,
            connectedDuration: 11,
            lastR10Age: 8
        ))
        XCTAssertTrue(AtriaBLEManager.shouldIsolateRecentProtectedR10DisconnectStorm(
            alreadySuppressed: false,
            consecutiveEarlyDisconnects: 2,
            lastDisconnectAge: 2,
            connectedDuration: 11,
            lastR10Age: 8
        ))
        XCTAssertFalse(AtriaBLEManager.shouldIsolateRecentProtectedR10DisconnectStorm(
            alreadySuppressed: false,
            consecutiveEarlyDisconnects: 2,
            lastDisconnectAge: 301,
            connectedDuration: 11,
            lastR10Age: 8
        ))
    }

    func testLegacyLifetimeDisconnectStormSuppressionIsClearedExactlyOnce() throws {
        let suite = "AtriaBLERecoveryCadenceTests.falseStormMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atria.protectedR10.streamSuppressed")
        defaults.set("short_links_with_fresh_r10",
                     forKey: "atria.protectedR10.disconnectStormReason")
        defaults.set(0, forKey: "atria.protectedR10.earlyDisconnects")
        defaults.set(true, forKey: "atria.protectedR10.stableTransport")
        defaults.set("protected_redp_v9", forKey: "atria.protectedR10.cleanOwner")
        defaults.set("qualified", forKey: "atria.protectedR10.cleanOwnerState")

        XCTAssertTrue(AtriaBLEManager.migrateLegacyFalseR10StormSuppressionIfNeeded(
            defaults: defaults
        ))
        XCTAssertFalse(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
        XCTAssertNil(defaults.string(forKey: "atria.protectedR10.disconnectStormReason"))
        XCTAssertEqual(defaults.string(forKey: "atria.radio.passiveR10Status"),
                       "qualified_migration_resume")

        defaults.set(true, forKey: "atria.protectedR10.streamSuppressed")
        XCTAssertFalse(AtriaBLEManager.migrateLegacyFalseR10StormSuppressionIfNeeded(
            defaults: defaults
        ), "the repair must never clear a later genuine suppression")
        XCTAssertTrue(defaults.bool(forKey: "atria.protectedR10.streamSuppressed"))
    }

    func testExplicitNotChargingAndFullResetBatteryRiseTrajectory() throws {
        let start = Date(timeIntervalSince1970: 40_000)
        let candidate = try XCTUnwrap(AtriaBLEManager.updatedBatteryRiseCandidate(
            current: nil,
            previousLevel: 42,
            previousAcceptedAt: start,
            newLevel: 43,
            receivedAt: start.addingTimeInterval(30)
        ))

        XCTAssertNil(AtriaBLEManager.batteryRiseCandidateAfterExplicitChargeStatus(
            .notCharging,
            current: candidate
        ))
        XCTAssertNil(AtriaBLEManager.batteryRiseCandidateAfterExplicitChargeStatus(
            .full,
            current: candidate
        ))
        XCTAssertEqual(AtriaBLEManager.batteryRiseCandidateAfterExplicitChargeStatus(
            .charging,
            current: candidate
        ), candidate)
        XCTAssertEqual(AtriaBLEManager.batteryRiseCandidateAfterExplicitChargeStatus(
            .levelOnly,
            current: candidate
        ), candidate)
    }

    func testHistoryCompletionStatusReportsRawOnlyAndExactCoverageTruthfully() {
        XCTAssertEqual(AtriaBLEManager.historicalSyncCompletionStatus(
            newRows: 0,
            requestedWindowMetricProgress: false,
            ledgerCoverageResolved: false,
            hasValidatedMetricLayout: false
        ), "no_rows")
        XCTAssertEqual(AtriaBLEManager.historicalSyncCompletionStatus(
            newRows: 20,
            requestedWindowMetricProgress: false,
            ledgerCoverageResolved: false,
            hasValidatedMetricLayout: false
        ), "raw_archived_metric_unverified")
        XCTAssertEqual(AtriaBLEManager.historicalSyncCompletionStatus(
            newRows: 20,
            requestedWindowMetricProgress: false,
            ledgerCoverageResolved: false,
            hasValidatedMetricLayout: true
        ), "archived_gap_unresolved")
        XCTAssertEqual(AtriaBLEManager.historicalSyncCompletionStatus(
            newRows: 20,
            requestedWindowMetricProgress: true,
            ledgerCoverageResolved: false,
            hasValidatedMetricLayout: true
        ), "metric_progress")
        XCTAssertEqual(AtriaBLEManager.historicalSyncCompletionStatus(
            newRows: 20,
            requestedWindowMetricProgress: true,
            ledgerCoverageResolved: true,
            hasValidatedMetricLayout: true
        ), "gap_recovered")
    }

    func testHistoricalDrainTimeoutMeasuresIdleProgressNotWholeDrainAge() {
        XCTAssertFalse(AtriaBLEManager.historicalSyncHasStalled(
            lastProgressUptime: 10_000,
            nowUptime: 10_179.999,
            idleTimeout: 180
        ))
        XCTAssertTrue(AtriaBLEManager.historicalSyncHasStalled(
            lastProgressUptime: 10_000,
            nowUptime: 10_180,
            idleTimeout: 180
        ))

        // A multi-hour drain remains healthy when the newest batch made recent
        // progress. The old fixed whole-operation deadline could not express it.
        XCTAssertFalse(AtriaBLEManager.historicalSyncHasStalled(
            lastProgressUptime: 50_000,
            nowUptime: 50_010,
            idleTimeout: 180
        ))
    }

    func testHistoricalDrainAllowsPhysicalFullRingServeSilenceUntilThirtyMinuteDeadline() {
        let lastProgressUptime: TimeInterval = 10_000
        let idleTimeout: TimeInterval = 30 * 60

        // Physical WHOOP 4 captures have resumed after both an approximately
        // 1,100-second pause and a 142-second pause. Neither may be mistaken
        // for a failed transaction while the full-ring watchdog is active.
        for silence in [TimeInterval(1_100), 1_420] {
            XCTAssertFalse(AtriaBLEManager.historicalSyncHasStalled(
                lastProgressUptime: lastProgressUptime,
                nowUptime: lastProgressUptime + silence,
                idleTimeout: idleTimeout
            ))
        }

        XCTAssertTrue(AtriaBLEManager.historicalSyncHasStalled(
            lastProgressUptime: lastProgressUptime,
            nowUptime: lastProgressUptime + idleTimeout,
            idleTimeout: idleTimeout
        ))
    }

    func testHistoricalDrainIdleWatchdogFailsClosedOnInvalidMonotonicState() {
        XCTAssertTrue(AtriaBLEManager.historicalSyncHasStalled(
            lastProgressUptime: nil,
            nowUptime: 100,
            idleTimeout: 180
        ))
        XCTAssertTrue(AtriaBLEManager.historicalSyncHasStalled(
            lastProgressUptime: 101,
            nowUptime: 100,
            idleTimeout: 180
        ))
        XCTAssertTrue(AtriaBLEManager.historicalSyncHasStalled(
            lastProgressUptime: 100,
            nowUptime: 101,
            idleTimeout: 0
        ))
    }

    func testHistoricalDuplicateReplayCannotRenewIdleLease() {
        XCTAssertTrue(AtriaBLEManager.historicalFrameRenewsIdleLease(
            persistenceSucceeded: true,
            insertedNewFrame: true
        ))
        XCTAssertFalse(AtriaBLEManager.historicalFrameRenewsIdleLease(
            persistenceSucceeded: true,
            insertedNewFrame: false
        ))
        XCTAssertFalse(AtriaBLEManager.historicalFrameRenewsIdleLease(
            persistenceSucceeded: false,
            insertedNewFrame: true
        ))
    }

    func testHistoricalFrameCallbackDoesNotRenewLeaseBeforeDeduplication() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(of: "private func handleHistoricalData("))
        let end = try XCTUnwrap(source.range(
            of: "private func applyHistoricalArchivePersistenceResult(",
            range: start.upperBound..<source.endIndex
        ))
        let callbackBody = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(callbackBody.contains("reason: \"historical_frame\""))

        let persistenceEnd = try XCTUnwrap(source.range(
            of: "private func commitDurableHistoricalMetricFacts(",
            range: end.upperBound..<source.endIndex
        ))
        let persistenceBody = String(source[end.lowerBound..<persistenceEnd.lowerBound])
        XCTAssertTrue(persistenceBody.contains("historicalFrameRenewsIdleLease"))
        XCTAssertTrue(persistenceBody.contains("insertedNewFrame: result.inserted"))
    }

    func testExplicitProtectedHistoryRequestStillHonorsSafetyGates() {
        XCTAssertTrue(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: true,
            exactGapPending: false,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: true,
            exactGapPending: false,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: true,
            syncInProgress: false,
            explicitUserRequest: true
        ))
    }

    func testForcedOfflineSyncOwnsHistoryFromConnectedV10FallbackWithoutWeakeningSafetyGates() {
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticHistoryForCleanOwner(
            cleanOwner: .pureHRV10,
            state: .fallbackActive,
            explicitUserRequest: true,
            linkConnected: true
        ), "an explicit production drain must be able to take the shared transport from the v10 fallback")
        XCTAssertTrue(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: true,
            exactGapPending: false,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: false,
            syncInProgress: false,
            explicitUserRequest: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: true,
            explicitUserRequest: true
        ), "explicit ownership must not be mistaken for an automatic connected handoff")

        XCTAssertFalse(AtriaBLEManager.shouldAllowProtectedHistoricalRecovery(
            linkConnected: true,
            exactGapPending: true,
            verifiedHistoryCapability: true,
            activeExplicitWorkout: true,
            syncInProgress: false,
            explicitUserRequest: true
        ), "force never preempts the durable workout/live-radio boundary")
        XCTAssertTrue(AtriaBLEManager.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: false,
            linkConnecting: true,
            explicitUserRequest: true
        ), "force waits for the standing realtime reconnect instead of cancelling it")
    }

    func testForcedExplicitHistoryRequestSurvivesWeakerAutomaticCoalescing() {
        let forced = AtriaBLEManager.coalescedPendingOfflineHistoricalSyncRequest(
            existing: nil,
            reason: "physical_fixture",
            force: true,
            explicitRequest: true
        )
        let retained = AtriaBLEManager.coalescedPendingOfflineHistoricalSyncRequest(
            existing: forced,
            reason: "bg_processing",
            force: false,
            explicitRequest: false
        )

        XCTAssertEqual(retained.reason, "physical_fixture")
        XCTAssertTrue(retained.force)
        XCTAssertTrue(retained.explicitRequest)
    }

    func testStrongerExplicitHistoryRequestUpgradesPendingAutomaticRequest() {
        let automatic = AtriaBLEManager.PendingOfflineHistoricalSyncRequest(
            reason: "range_loss_retry",
            force: false,
            explicitRequest: false
        )
        let upgraded = AtriaBLEManager.coalescedPendingOfflineHistoricalSyncRequest(
            existing: automatic,
            reason: "physical_fixture",
            force: true,
            explicitRequest: true
        )

        XCTAssertEqual(upgraded.reason, "physical_fixture")
        XCTAssertTrue(upgraded.force)
        XCTAssertTrue(upgraded.explicitRequest)
    }

    func testFreshHistoryOwnerCutoverRequiresConnectedExplicitForce() {
        XCTAssertTrue(AtriaBLEManager.shouldUseFreshHistoryOwnerCutover(
            linkConnected: true,
            force: true,
            explicitRequest: true,
            activeExplicitWorkout: false,
            cutoverAlreadyPending: false
        ))
        for denied in [
            (false, true, true, false, false),
            (true, false, true, false, false),
            (true, true, false, false, false),
            (true, true, true, true, false),
            (true, true, true, false, true),
        ] {
            XCTAssertFalse(AtriaBLEManager.shouldUseFreshHistoryOwnerCutover(
                linkConnected: denied.0,
                force: denied.1,
                explicitRequest: denied.2,
                activeExplicitWorkout: denied.3,
                cutoverAlreadyPending: denied.4
            ))
        }
    }

    func testFreshHistoryOwnerResearchBoundaryAcceptsDurableSuperset() {
        let target = AtriaBLEManager.ResearchAggregates(
            sensorProbeFrames: 3,
            spo2CandidateFrames: 2,
            skinTempCandidateFrames: 4,
            skinTempCandidateValueSum: 120,
            skinTempCandidateValueCount: 4,
            strapSteps: 12,
            strapRawSteps: 14,
            strapDeviceTimestamp: 99,
            strapStepState: "target",
            gyroCadenceResearchSteps: 8
        )
        let saved = AtriaBLEManager.ResearchAggregates(
            sensorProbeFrames: 4,
            spo2CandidateFrames: 2,
            skinTempCandidateFrames: 5,
            skinTempCandidateValueSum: 150,
            skinTempCandidateValueCount: 5,
            strapSteps: 13,
            strapRawSteps: 16,
            strapDeviceTimestamp: 101,
            strapStepState: "later",
            gyroCadenceResearchSteps: 9
        )
        XCTAssertTrue(AtriaBLEManager.researchAggregates(saved, cover: target))
        XCTAssertFalse(AtriaBLEManager.researchAggregates(
            .init(sensorProbeFrames: 4,
                  spo2CandidateFrames: 2,
                  skinTempCandidateFrames: 5,
                  skinTempCandidateValueSum: 150,
                  skinTempCandidateValueCount: 5,
                  strapSteps: 13,
                  strapRawSteps: 13,
                  strapDeviceTimestamp: 101,
                  strapStepState: "later",
                  gyroCadenceResearchSteps: 9),
            cover: target
        ))
    }

    func testRangeLossRetryReasonIsStableAcrossRecursiveScheduling() {
        XCTAssertEqual(
            AtriaBLEManager.stableRangeLossBackfillRetryReason("accepted_hr_gap"),
            "accepted_hr_gap_retry"
        )
        XCTAssertEqual(
            AtriaBLEManager.stableRangeLossBackfillRetryReason(
                "accepted_hr_gap_retry_retry_retry"
            ),
            "accepted_hr_gap_retry"
        )
    }

    func testForceOfflineSyncLaunchArgumentRequestsExplicitProductionOwnership() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func applyOfflineSyncForDebugLaunch(arguments: [String])"
        ))
        let body = String(source[start.lowerBound...].prefix(2_000))

        XCTAssertTrue(body.contains("arguments.contains(\"--atria-force-offline-sync\")"))
        XCTAssertTrue(body.contains("let livePersistenceReady"))
        XCTAssertTrue(body.contains("guard livePersistenceReady else"))
        XCTAssertTrue(body.contains("retainPendingOfflineHistoricalSyncRequest("))
        XCTAssertTrue(body.contains("force: true"),
                      "the fixture launch must bypass cadence, not silently become an automatic retry")
        XCTAssertTrue(body.contains("explicitRequest: true"),
                      "the launch flag must retain explicit ownership while waiting for a persisted live sample")
        XCTAssertTrue(body.contains("explicitResearchRequest: true"),
                      "a live-ready launch must deliberately acquire connected history ownership")
        XCTAssertTrue(body.contains("requestOfflineHistoricalSyncIfNeeded"))

        let resumeStart = try XCTUnwrap(source.range(
            of: "private func resumePendingForcedHistoricalSyncAfterLivePersistenceIfNeeded"
        ))
        let resumeBody = String(source[resumeStart.lowerBound...].prefix(1_500))
        XCTAssertTrue(resumeBody.contains("lastAcceptedHRAt >= connectedAt"))
        XCTAssertTrue(resumeBody.contains(
            "shouldDeferInterruptedFullDrainRelaunchAfterLivePersistence"
        ))
        XCTAssertTrue(resumeBody.contains(
            "deferred_interrupted_full_drain_live_priority"
        ))
        XCTAssertTrue(resumeBody.contains(
            "retain_exact_gap_no_fresh_owner_cutover"
        ))

        XCTAssertTrue(AtriaBLEManager
            .shouldDeferInterruptedFullDrainRelaunchAfterLivePersistence(
                pendingReason: "interrupted_full_drain_relaunch"
            ))
        XCTAssertFalse(AtriaBLEManager
            .shouldDeferInterruptedFullDrainRelaunchAfterLivePersistence(
                pendingReason: "user_requested_history_diagnostic"
            ))

        XCTAssertTrue(source.contains(
            "persistActiveSessionJournalIfNeeded(reason: \"accepted_hr\", force: false)"
        ))
        XCTAssertTrue(source.contains(
            "resumePendingForcedHistoricalSyncAfterLivePersistenceIfNeeded(\n                reason: \"accepted_hr\""
        ), "the accepted-HR path must persist first, then evaluate a forced request")
    }

    func testInterruptedFullDrainRelaunchResumesOnlyPendingTransportAuthority() {
        typealias Status = AtriaHistoricalFullDrainCoverageStore.Authority.Status

        XCTAssertTrue(AtriaBLEManager.shouldResumeInterruptedFullDrainAtLaunch(
            rangeLossBackfillPending: true,
            authorityStatus: Status.draining,
            exactGapFingerprintStillPending: true
        ))
        for terminalStatus in [
            Status.historyComplete,
            .coverageProven,
            .gapResolvedConsumersPending,
            .consumersCommitted,
            .resolved
        ] {
            XCTAssertFalse(AtriaBLEManager.shouldResumeInterruptedFullDrainAtLaunch(
                rangeLossBackfillPending: true,
                authorityStatus: terminalStatus,
                exactGapFingerprintStillPending: true
            ), "terminal publication state must not reacquire the BLE history owner")
        }
        XCTAssertFalse(AtriaBLEManager.shouldResumeInterruptedFullDrainAtLaunch(
            rangeLossBackfillPending: false,
            authorityStatus: Status.draining,
            exactGapFingerprintStillPending: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldResumeInterruptedFullDrainAtLaunch(
            rangeLossBackfillPending: true,
            authorityStatus: nil,
            exactGapFingerprintStillPending: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldResumeInterruptedFullDrainAtLaunch(
            rangeLossBackfillPending: true,
            authorityStatus: Status.draining,
            exactGapFingerprintStillPending: false
        ))
    }

    func testProductionHistoryOwnershipPersistsLiveJournalBeforePhaseCutover() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func startOfflineHistoricalSync(reason: String,\n                                            force: Bool,\n                                            explicitRequest: Bool,\n                                            connectedChunkedBackfill: Bool,"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func noteOfflineHistoricalSyncProgress(",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let journalFlush = try XCTUnwrap(body.range(
            of: "flushActiveSessionJournal(reason: \"offline_sync_preflight_"
        ))
        let ownership = try XCTUnwrap(body.range(
            of: "historyTransportPhaseFence.activate(generation: syncGeneration)"
        ))

        XCTAssertLessThan(journalFlush.lowerBound, ownership.lowerBound,
                          "live workout/session state must be durable before history owns callbacks")
        XCTAssertFalse(body.contains("flushLifecycleRealtimeState("),
                       "history ownership must not close or reset the active live session")
        XCTAssertFalse(body.contains("cancelPeripheralConnection"),
                       "the connected production handoff must preserve the physical live link")
    }

    func testDeferredForcedHistoryReplayPreservesForceAndExplicitAuthority() throws {
        let source = try leaseManagerSource()
        XCTAssertTrue(source.contains(
            "reason: pending.reason,\n                force: pending.force,\n                explicitResearchRequest: pending.explicitRequest"
        ), "terminal replay must restore the authority which admitted the deferred request")
        XCTAssertTrue(source.contains(
            "reason: pending.reason,\n                        force: pending.force,\n                        explicitResearchRequest: pending.explicitRequest"
        ), "materialization replay must restore the authority which admitted the deferred request")

        let start = try XCTUnwrap(source.range(
            of: "private func startOfflineHistoricalSync(reason: String,\n                                            force: Bool,\n                                            explicitRequest: Bool,"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func noteOfflineHistoricalSyncProgress(",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains(
            "reason: reason, force: force,\n                explicitRequest: explicitRequest"
        ), "a transaction-boundary reconnect race must retain the full forced request")
    }

    func testAutomaticRangeRecoveryCannotRaceExplicitSequenceConfirmationReplay() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "func requestOfflineHistoricalSyncIfNeeded("
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func startOfflineHistoricalSync(reason: String,",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("historySequenceConfirmationRetryTask != nil"))
        XCTAssertTrue(body.contains("!explicitHistoricalRequest"))
        XCTAssertTrue(body.contains("deferred_sequence_confirmation_replay"))
        XCTAssertTrue(body.contains("retain_automatic_gap_until_explicit_replay_finishes"))
        XCTAssertTrue(source.contains(
            "reason: retryReason,\n                    force: true,\n                    explicitResearchRequest: true"
        ), "the exact sequence-confirmation replay must retain explicit authority")
    }

    func testProductionHistoricalRecoverySendsOnlyServedHistoryCommand() {
        let commands = AtriaBLEManager.productionHistoricalRecoveryInitCommands()

        XCTAssertEqual(commands, [
            [AtriaBLEManager.Cmd.sendHistoricalData, 0x00],
        ])
        XCTAssertEqual(commands.last, [AtriaBLEManager.Cmd.sendHistoricalData, 0x00])
        XCTAssertTrue(
            AtriaBLEManager.permitsRawFullDrainForwardDiscontinuity(
                fullDrainWriteConfirmed: true,
                historyStartReceived: true
            ),
            "A confirmed full drain retains raw WHOOP flash-layout jumps; it does not resolve a local gap"
        )
        XCTAssertFalse(
            AtriaBLEManager.permitsRawFullDrainForwardDiscontinuity(
                fullDrainWriteConfirmed: true,
                historyStartReceived: false
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.permitsRawFullDrainForwardDiscontinuity(
                fullDrainWriteConfirmed: false,
                historyStartReceived: true
            )
        )
        XCTAssertFalse(commands.contains { $0.first == AtriaBLEManager.Cmd.sendR10R11Realtime })
        XCTAssertFalse(commands.contains { $0.first == AtriaBLEManager.Cmd.toggleRealtimeHR })
        XCTAssertFalse(commands.contains { $0.first == AtriaBLEManager.Cmd.abortHistoricalTransmits })
        XCTAssertFalse(commands.contains { $0.first == AtriaBLEManager.Cmd.enterHighFreqSync })
        XCTAssertFalse(AtriaBLEManager.shouldStopRealtimeBeforeHistoricalRecovery(
            diagnosticSelectorOrRangeProbe: false
        ), "production full-drain must keep standard 2A37 live")
        XCTAssertTrue(AtriaBLEManager.shouldStopRealtimeBeforeHistoricalRecovery(
            diagnosticSelectorOrRangeProbe: true
        ), "only an explicit research probe may retain the stop-first handshake")
        XCTAssertEqual(
            AtriaBLEManager.UUIDs.productionHistoryNotify,
            [AtriaBLEManager.UUIDs.strapRX, AtriaBLEManager.UUIDs.strapStream5]
        )
        XCTAssertTrue(
            AtriaBLEManager.UUIDs.productionHistoryNotify.contains(
                AtriaBLEManager.UUIDs.strapStream5
            ),
            "physical 0x16/00 evidence delivers historical type-47 rows on stream 5"
        )
        XCTAssertFalse(
            AtriaBLEManager.UUIDs.productionHistoryNotify.contains(
                AtriaBLEManager.UUIDs.strapStream4
            ),
            "stream 4 did not carry rows in the direct WHOOP 4.0 history capture"
        )
        XCTAssertFalse(
            AtriaBLEManager.UUIDs.productionHistoryNotify.contains(
                AtriaBLEManager.UUIDs.strapStream7
            )
        )
        XCTAssertEqual(
            AtriaBLEManager.UUIDs.historyNotifyCharacteristics(observeMotionChannels: false),
            AtriaBLEManager.UUIDs.productionHistoryNotify,
            "shipping history must retain the physically verified narrow subscription set"
        )
        XCTAssertEqual(
            AtriaBLEManager.UUIDs.historyNotifyCharacteristics(observeMotionChannels: true),
            AtriaBLEManager.UUIDs.allNotify,
            "the explicit observation profile passively covers every known notify channel"
        )
    }

    func testProductionHistoryNeverBlocksOnOptionalGetClockPreflight() {
        XCTAssertFalse(AtriaBLEManager.shouldUseProductionHistoryReadPreflight(
            explicitRequest: true, force: false, reason: "settings"
        ))
        XCTAssertFalse(AtriaBLEManager.shouldUseProductionHistoryReadPreflight(
            explicitRequest: false, force: true, reason: "stale_gap"
        ))
        XCTAssertFalse(AtriaBLEManager.shouldUseProductionHistoryReadPreflight(
            explicitRequest: false, force: false, reason: "onboarding_strap"
        ))
        XCTAssertFalse(AtriaBLEManager.shouldUseProductionHistoryReadPreflight(
            explicitRequest: false, force: false, reason: "automatic_connected"
        ))
    }

    func testWHOOP4DataRangeCursorObservationDecodesWrappedAndCaughtUpBacklog() {
        func response(write: UInt32, read: UInt32, capacity: UInt32) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 26)
            func put(_ value: UInt32, at offset: Int) {
                data[offset] = UInt8(value & 0xff)
                data[offset + 1] = UInt8((value >> 8) & 0xff)
                data[offset + 2] = UInt8((value >> 16) & 0xff)
                data[offset + 3] = UInt8((value >> 24) & 0xff)
            }
            put(write, at: 10)
            put(read, at: 14)
            put(capacity, at: 22)
            return [0x24, 0x91, 0x22, 0x07] + data
        }

        let caughtUp = AtriaWhoop4HistoryCursorRange.parseCommandResponse(
            response(write: 73_521, read: 73_521, capacity: 131_072)
        )
        XCTAssertEqual(caughtUp?.requestSequenceEcho, 0x07)
        XCTAssertEqual(caughtUp?.pendingRecords, 0)

        let wrapped = AtriaWhoop4HistoryCursorRange.parseCommandResponse(
            response(write: 20, read: 131_000, capacity: 131_072)
        )
        XCTAssertEqual(wrapped?.pendingRecords, 92)
        XCTAssertNil(AtriaWhoop4HistoryCursorRange.parseCommandResponse(
            response(write: 20, read: 30, capacity: 0)
        ))
    }

    func testHistoricalServeStartDeclarationFailsClosedWithoutMutationOrRetry() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "if cmd == Cmd.sendHistoricalData,"
        ))
        let end = try XCTUnwrap(source.range(
            of: "if index < historyInitSweepCommands.count - 1",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("cursorRange.pendingRecords > 0"))
        XCTAssertTrue(body.contains("let initialServeDeadline = Date().addingTimeInterval(30)"))
        XCTAssertTrue(body.contains("while acceptedHistoryStartSequence == nil"))
        XCTAssertTrue(body.contains("for: .milliseconds(250)"))
        XCTAssertTrue(body.contains("guard acceptedHistoryStartSequence != nil else"))
        XCTAssertTrue(body.contains(
            "wait_s=30 action=rebuild_link_without_ack_or_abort_retain_gap"
        ))
        XCTAssertTrue(body.contains("history_start_timeout_transport_reset"))
        XCTAssertTrue(body.contains("interruptOfflineHistoricalSyncForTransportLoss"))
        XCTAssertFalse(body.contains("Cmd.abortHistoricalTransmits"))
        XCTAssertFalse(body.contains("Cmd.exitHighFreqSync"))
        XCTAssertFalse(body.contains("historyServeKickRetryGeneration"))
        XCTAssertFalse(body.contains("serve_retry_exhausted"))
    }

    func testRetainedHistoricalGapCannotChurnEveryReconnectAfterFailedAttempt() {
        let now = Date(timeIntervalSince1970: 90_000)
        let base: (Bool, Date?) -> Bool = { verified, lastAttemptAt in
            AtriaBLEManager.shouldAttemptAutomaticConnectedHistoricalHandoff(
                linkConnected: true,
                exactGapPending: true,
                verifiedMetricRecovery: verified,
                activeExplicitWorkout: false,
                syncInProgress: false,
                connectedAt: now.addingTimeInterval(-600),
                hasContact: true,
                acceptedSampleCount: 100,
                lastAcceptedHRAt: now.addingTimeInterval(-2),
                requestedAt: now.addingTimeInterval(-3_600),
                lastAttemptAt: lastAttemptAt,
                now: now,
                attemptCooldown: 6 * 60 * 60
            )
        }

        XCTAssertFalse(base(false, nil),
                       "an unverified retained request must never own the live protocol")
        XCTAssertFalse(base(true, now.addingTimeInterval(-5 * 60)),
                       "a failed automatic attempt must not repeat on the next reconnect")
        XCTAssertTrue(base(true, now.addingTimeInterval(-(6 * 60 * 60 + 1))),
                      "a verified exact gap must receive one bounded automatic handoff after the six-hour anti-churn cooldown")
    }

    func testFullHistoryDumpCannotBindArbitraryExactGapAuthority() {
        XCTAssertFalse(AtriaBLEManager.shouldBindExactHistoricalRequestAuthority(
            exactRangeWasEncodedAndTransmitted: false,
            acceptedResponseDurablyTiedToAttempt: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldBindExactHistoricalRequestAuthority(
            exactRangeWasEncodedAndTransmitted: false,
            acceptedResponseDurablyTiedToAttempt: true
        ), "A response to a full dump is not exact-range acceptance")
        XCTAssertFalse(AtriaBLEManager.shouldBindExactHistoricalRequestAuthority(
            exactRangeWasEncodedAndTransmitted: true,
            acceptedResponseDurablyTiedToAttempt: false
        ), "Transmission without durable accepted-attempt evidence is insufficient")
        XCTAssertTrue(AtriaBLEManager.shouldBindExactHistoricalRequestAuthority(
            exactRangeWasEncodedAndTransmitted: true,
            acceptedResponseDurablyTiedToAttempt: true
        ))
    }

    func testHistoricalRecoveryCapabilityFailsClosedExceptVerifiedFourClass() {
        XCTAssertFalse(AtriaBLEManager.supportsVerifiedHistoricalRecovery(model: .unknown,
                                                                           previouslyVerified: false))
        XCTAssertFalse(AtriaBLEManager.supportsVerifiedHistoricalRecovery(model: .strap5,
                                                                           previouslyVerified: false))
        XCTAssertTrue(AtriaBLEManager.supportsVerifiedHistoricalRecovery(model: .strap4Class,
                                                                          previouslyVerified: false))
        XCTAssertTrue(AtriaBLEManager.supportsVerifiedHistoricalRecovery(model: .strap4,
                                                                          previouslyVerified: false))
        XCTAssertTrue(AtriaBLEManager.supportsVerifiedHistoricalRecovery(model: .unknown,
                                                                          previouslyVerified: true))
    }

    func testHistoricalRecoveryRestoresTheExactPreSyncRadioMode() {
        XCTAssertFalse(AtriaBLEManager.standardHROnlyModeAfterOfflineSync(
            modeBeforeSync: false
        ), "A full-protocol step stream must not be downgraded after recovery")
        XCTAssertTrue(AtriaBLEManager.standardHROnlyModeAfterOfflineSync(
            modeBeforeSync: true
        ), "An explicit Battery Saver mode must also survive recovery")
    }

    func testAutomaticRadioModeMigratesOnceToStableHRPlusR10() {
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

        XCTAssertTrue(AtriaBLEManager.standardHROnlyModeAfterFullProtocolOverride(
            modeBeforeOverride: true,
            userSelectedBatterySaver: false
        ), "diagnostic expiry must restore the stable automatic HR + R10 profile")
        XCTAssertTrue(AtriaBLEManager.standardHROnlyModeAfterFullProtocolOverride(
            modeBeforeOverride: true,
            userSelectedBatterySaver: true
        ))
        XCTAssertFalse(AtriaBLEManager.standardHROnlyModeAfterFullProtocolOverride(
            modeBeforeOverride: false,
            userSelectedBatterySaver: true
        ))
    }

    func testBackgroundRadioDowngradeIsSuppressedDuringExplicitWorkout() {
        XCTAssertFalse(AtriaBLEManager.shouldRestoreProtectedLongWearRadioInBackground(
            activeExplicitWorkout: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldRestoreProtectedLongWearRadioInBackground(
            activeExplicitWorkout: false
        ))
    }

    func testExplicitWorkoutOwnsBLEContinuityWithoutLongWear() {
        XCTAssertTrue(AtriaBLEManager.isBLEContinuityRelevant(
            longWearEnabled: false,
            activeExplicitWorkout: true
        ))
        XCTAssertTrue(AtriaBLEManager.isBLEContinuityRelevant(
            longWearEnabled: true,
            activeExplicitWorkout: false
        ))
        XCTAssertFalse(AtriaBLEManager.isBLEContinuityRelevant(
            longWearEnabled: false,
            activeExplicitWorkout: false
        ))
    }

    func testRangeLossBackfillNeedsExactLedgerCoverageBeforeClearing() {
        XCTAssertFalse(AtriaBLEManager.rangeLossBackfillCanClear(newRows: 0))
        XCTAssertFalse(AtriaBLEManager.rangeLossBackfillCanClear(newRows: 1),
                       "row count alone is never recovery evidence")
        XCTAssertTrue(AtriaBLEManager.rangeLossBackfillCanClear(
            newRows: 1,
            hasRequestedWindow: false,
            requestedWindowMetricProgress: false,
            ledgerCoverageResolved: true
        ))
        XCTAssertFalse(AtriaBLEManager.rangeLossBackfillCanClear(
            newRows: 20,
            hasRequestedWindow: true,
            requestedWindowMetricProgress: false,
            ledgerCoverageResolved: true
        ))
        XCTAssertFalse(AtriaBLEManager.rangeLossBackfillCanClear(
            newRows: 1,
            hasRequestedWindow: true,
            requestedWindowMetricProgress: true,
            ledgerCoverageResolved: true
        ), "Exact workout recovery must wait for coverage-aware rehydration")
    }

    func testRequestedRecoveryProgressRequiresMetricUsableRowInsideExactWindow() {
        let start = 1_783_768_620.0
        let end = start + 3_000

        XCTAssertFalse(AtriaBLEManager.requestedRecoveryRowProvidesMetricProgress(
            metricUsable: false,
            effectiveUnix: UInt32(start + 60),
            requestedStart: start,
            requestedEnd: end
        ), "An overlapping diagnostic frame cannot resolve or advance HR recovery")
        XCTAssertFalse(AtriaBLEManager.requestedRecoveryRowProvidesMetricProgress(
            metricUsable: true,
            effectiveUnix: UInt32(start - 1),
            requestedStart: start,
            requestedEnd: end
        ))
        XCTAssertTrue(AtriaBLEManager.requestedRecoveryRowProvidesMetricProgress(
            metricUsable: true,
            effectiveUnix: UInt32(start + 60),
            requestedStart: start,
            requestedEnd: end
        ))
    }

    func testRestoredProprietaryNotificationStateIncludesAlreadyActiveStream() {
        let active = AtriaBLEManager.alreadyActiveProprietaryNotifications([
            (AtriaBLEManager.UUIDs.strapRX, true),
            (AtriaBLEManager.UUIDs.strapStream5, true),
            (AtriaBLEManager.UUIDs.strapStream7, false),
            (AtriaBLEManager.UUIDs.heartRateMeasure, true),
        ])

        XCTAssertEqual(active, [
            AtriaBLEManager.UUIDs.strapRX,
            AtriaBLEManager.UUIDs.strapStream5,
        ])
    }

    func testR10ArmHealthRejectsFrameFromBeforeCurrentArm() {
        let arm = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertFalse(AtriaBLEManager.r10FrameConfirmsCurrentArm(
            lastFrameAt: arm.addingTimeInterval(-0.1),
            armSentAt: arm,
            now: arm.addingTimeInterval(4)
        ), "A just-received frame from the old stream must not suppress reconnect recovery")
        XCTAssertTrue(AtriaBLEManager.r10FrameConfirmsCurrentArm(
            lastFrameAt: arm.addingTimeInterval(0.1),
            armSentAt: arm,
            now: arm.addingTimeInterval(4)
        ))
    }

    func testR10ArmHealthRejectsStaleOrFutureFrames() {
        let arm = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertFalse(AtriaBLEManager.r10FrameConfirmsCurrentArm(
            lastFrameAt: arm.addingTimeInterval(1),
            armSentAt: arm,
            now: arm.addingTimeInterval(7)
        ))
        XCTAssertFalse(AtriaBLEManager.r10FrameConfirmsCurrentArm(
            lastFrameAt: arm.addingTimeInterval(5),
            armSentAt: arm,
            now: arm.addingTimeInterval(4)
        ))
    }

    func testR10FramePermanentlyProvesCurrentArmEpoch() {
        let arm = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertFalse(AtriaBLEManager.r10FrameProvesCurrentArm(
            lastFrameAt: nil,
            evidenceEpoch: arm,
            now: arm.addingTimeInterval(120)
        ))
        XCTAssertFalse(AtriaBLEManager.r10FrameProvesCurrentArm(
            lastFrameAt: arm.addingTimeInterval(-0.001),
            evidenceEpoch: arm,
            now: arm.addingTimeInterval(120)
        ))
        XCTAssertTrue(AtriaBLEManager.r10FrameProvesCurrentArm(
            lastFrameAt: arm.addingTimeInterval(60),
            evidenceEpoch: arm,
            now: arm.addingTimeInterval(120)
        ))
        XCTAssertFalse(AtriaBLEManager.r10FrameProvesCurrentArm(
            lastFrameAt: arm.addingTimeInterval(121),
            evidenceEpoch: arm,
            now: arm.addingTimeInterval(120)
        ))
    }

    func testStepCalibrationOverridesLowBatteryMotionDeferral() {
        XCTAssertFalse(AtriaBLEManager.shouldArmHighFrequencyMotion(
            batteryLevel: 10,
            isCharging: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(
            batteryLevel: 10,
            isCharging: false,
            calibrationActive: true
        ), "An explicitly armed calibration must capture motion even at low battery")
    }

    func testR10LivenessIgnoresFreshFramesAndIneligibleModes() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: now.addingTimeInterval(-2),
            lastRearmAt: nil,
            lastRediscoveryAt: nil,
            now: now
        ), .none)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: false,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: nil,
            lastRearmAt: nil,
            lastRediscoveryAt: nil,
            now: now
        ), .none)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: false,
            realtimeArmed: true,
            lastFrameAt: nil,
            lastRearmAt: nil,
            lastRediscoveryAt: nil,
            now: now
        ), .none)
    }

    func testR10LivenessRearmsAStaleStreamDespiteHealthyHRLink() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: now.addingTimeInterval(-61),
            lastRearmAt: nil,
            lastRediscoveryAt: nil,
            now: now
        ), .rearm)
    }

    func testR10LivenessEscalatesAfterGraceAndHonorsRediscoveryCooldown() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let staleFrame = now.addingTimeInterval(-61)
        let rearm = now.addingTimeInterval(-61)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: staleFrame,
            lastRearmAt: rearm,
            lastRediscoveryAt: nil,
            now: now
        ), .rediscover)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: staleFrame,
            lastRearmAt: rearm,
            lastRediscoveryAt: now.addingTimeInterval(-30),
            now: now
        ), .none)
        XCTAssertEqual(AtriaBLEManager.r10LivenessAction(
            eligible: true,
            connected: true,
            realtimeArmed: true,
            lastFrameAt: staleFrame,
            lastRearmAt: now.addingTimeInterval(-601),
            lastRediscoveryAt: now.addingTimeInterval(-30),
            now: now
        ), .rearm, "A command re-arm is rate-limited to once per ten minutes")
    }

    func testImplausibleBatteryDropRequiresCorroborationEvenWithOlderCache() {
        let acceptedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertTrue(AtriaBLEManager.shouldQuarantineBatteryLevel(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: acceptedAt.addingTimeInterval(5)
        ))
        XCTAssertTrue(AtriaBLEManager.shouldQuarantineBatteryLevel(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: acceptedAt.addingTimeInterval(60)
        ))
        XCTAssertFalse(AtriaBLEManager.shouldQuarantineBatteryLevel(
            previousLevel: 74,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 73,
            receivedAt: acceptedAt.addingTimeInterval(5)
        ))
    }

    func testFirstOppositeExtremeLiveReadDoesNotReplaceHydratedDisplayCache() {
        let cachedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let decision = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: cachedAt,
            incomingLevel: 10,
            receivedAt: cachedAt.addingTimeInterval(5),
            pending: nil,
            previousIsCached: true
        )
        guard case .quarantine(let candidate) = decision else {
            return XCTFail("A reconnect must not flash cached 100% down to a one-off 10% read")
        }
        XCTAssertEqual(candidate.level, 10)
        XCTAssertEqual(candidate.confirmations, 1)
    }

    func testCachedLowBatteryRejectsOneOffHundredPercentSpike() {
        let cachedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let firstAt = cachedAt.addingTimeInterval(5)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 10,
            previousAcceptedAt: cachedAt,
            incomingLevel: 100,
            receivedAt: firstAt,
            pending: nil,
            previousIsCached: true
        )
        guard case .quarantine(let candidate) = first else {
            return XCTFail("A one-off cached-low to 100% jump must not flash as full")
        }
        XCTAssertEqual(candidate.level, 100)
        XCTAssertEqual(candidate.confirmations, 1)
    }

    func testCachedLowBatteryNeverAcceptsHundredPercentFromRepetitionAlone() {
        let cachedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let firstAt = cachedAt.addingTimeInterval(5)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 10,
            previousAcceptedAt: cachedAt,
            incomingLevel: 100,
            receivedAt: firstAt,
            pending: nil,
            previousIsCached: true
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("Expected initial upward spike quarantine")
        }
        let second = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 10,
            previousAcceptedAt: cachedAt,
            incomingLevel: 100,
            receivedAt: firstAt.addingTimeInterval(30),
            pending: firstCandidate,
            previousIsCached: true
        )
        guard case .quarantine(let secondCandidate) = second else {
            return XCTFail("Expected second upward reading to remain quarantined")
        }
        guard case .quarantine(let finalCandidate) = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 10,
            previousAcceptedAt: cachedAt,
            incomingLevel: 100,
            receivedAt: firstAt.addingTimeInterval(15 * 60),
            pending: secondCandidate,
            previousIsCached: true
        ) else {
            return XCTFail("A physically disproven 100% sentinel must not become truth through repetition")
        }
        XCTAssertGreaterThanOrEqual(finalCandidate.confirmations, 3)
    }

    func testImplausibleBatteryDropRequiresThreeReadingsAcrossOneMinute() {
        let acceptedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let firstAt = acceptedAt.addingTimeInterval(5)

        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: firstAt,
            pending: nil
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("The first implausible drop must remain quarantined")
        }

        let second = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: firstAt.addingTimeInterval(7.6),
            pending: firstCandidate
        )
        guard case .quarantine(let secondCandidate) = second else {
            return XCTFail("A repeated transient reading after 7.6 seconds must not replace 100%")
        }
        XCTAssertEqual(secondCandidate.confirmations, 2)

        let earlyThird = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: firstAt.addingTimeInterval(30),
            pending: secondCandidate
        )
        guard case .quarantine(let thirdCandidate) = earlyThird else {
            return XCTFail("Three readings inside one minute must remain quarantined")
        }

        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: firstAt.addingTimeInterval(15 * 60),
            pending: thirdCandidate
        ) else {
            return XCTFail("A 100% to 10% restoration sentinel must remain quarantined")
        }
    }

    func testLiveMidrangeToTenPercentCannotBecomeTruthAfterOneMinute() {
        let acceptedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 89,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: acceptedAt.addingTimeInterval(5),
            pending: nil
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("A live 89% to 10% jump must be treated as a restoration sentinel")
        }
        let oneMinute = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 89,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: acceptedAt.addingTimeInterval(66),
            pending: firstCandidate
        )
        guard case .quarantine(let sustainedCandidate) = oneMinute else {
            return XCTFail("A repeated boundary sentinel must remain hidden after one minute")
        }
        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 89,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 10,
            receivedAt: acceptedAt.addingTimeInterval(15 * 60 + 5),
            pending: sustainedCandidate
        ) else {
            return XCTFail("A repeated 10% sentinel must not replace the credible 89% level")
        }
    }

    func testPlausibleBatteryChangeClearsAnyPendingDrop() {
        let acceptedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let pending = AtriaBLEManager.BatteryDropCandidate(level: 10,
                                                           firstSeenAt: acceptedAt,
                                                           lastSeenAt: acceptedAt,
                                                           confirmations: 1)
        XCTAssertEqual(AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 100,
            previousAcceptedAt: acceptedAt,
            incomingLevel: 99,
            receivedAt: acceptedAt.addingTimeInterval(5),
            pending: pending
        ), .accept)
    }

    func testCachedRapidTransitionInvalidatesBothValuesAndRequiresFreshConfirmation() throws {
        let suite = "AtriaBLERecoveryCadenceTests.battery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(10, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(89, forKey: AtriaBLEManager.BatteryDefaults.previousLevel)
        defaults.set(1_000.0, forKey: AtriaBLEManager.BatteryDefaults.previousAt)
        defaults.set(1_094.0, forKey: AtriaBLEManager.BatteryDefaults.dropAt)
        defaults.set(79, forKey: AtriaBLEManager.BatteryDefaults.dropDelta)

        defaults.set(AtriaBLEManager.BatteryChargeStatus.full.rawValue,
                     forKey: AtriaBLEManager.BatteryDefaults.chargeStatus)
        defaults.set(1_000.0, forKey: AtriaBLEManager.BatteryDefaults.chargeAt)
        defaults.set(AtriaBLEManager.StrapStreamState.lowBatteryShutoff.rawValue,
                     forKey: AtriaBLEManager.StrapStreamDefaults.state)
        defaults.set(0, forKey: AtriaBLEManager.StrapStreamDefaults.batteryLevel)
        defaults.set(true, forKey: AtriaBLEManager.StrapStreamDefaults.lowBatteryReconnectSuppressed)

        XCTAssertTrue(AtriaBLEManager.invalidateImplausibleCachedBatteryTransitionIfNeeded(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.level))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.at))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.previousLevel))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.previousAt))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.dropDelta))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.dropAt))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.chargeStatus))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.chargeAt))
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.BatteryDefaults.source),
                       "disputed_rapid_transition")
        XCTAssertTrue(defaults.bool(forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation))
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.StrapStreamDefaults.state),
                       AtriaBLEManager.StrapStreamState.unknown.rawValue)
        XCTAssertEqual(defaults.integer(forKey: AtriaBLEManager.StrapStreamDefaults.batteryLevel), -1)
        XCTAssertFalse(defaults.bool(forKey: AtriaBLEManager.StrapStreamDefaults.lowBatteryReconnectSuppressed))
    }

    func testDisputedBatterySourceCancelsNotificationFallout() throws {
        let notificationSource = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/LocalNotificationScheduler.swift"), encoding: .utf8)

        XCTAssertTrue(notificationSource.contains("if !battery.usable, battery.source == \"disputed_rapid_transition\""))
        XCTAssertTrue(notificationSource.contains("removePendingNotificationRequests(withIdentifiers: identifiers)"))
        XCTAssertTrue(notificationSource.contains("removeDeliveredNotifications(withIdentifiers: identifiers)"))
        XCTAssertTrue(notificationSource.contains("defaults.removeObject(forKey: strapChargeReminderLastScheduledKey)"))
    }

    func testAsyncBatteryAlertIsRevalidatedBeforeDelivery() {
        XCTAssertFalse(LocalNotificationScheduler.batteryAlertStillValid(level: -1,
                                                                         usable: false,
                                                                         isCharging: false))
        XCTAssertFalse(LocalNotificationScheduler.batteryAlertStillValid(level: 10,
                                                                         usable: true,
                                                                         isCharging: true))
        XCTAssertFalse(LocalNotificationScheduler.batteryAlertStillValid(level: 43,
                                                                         usable: true,
                                                                         isCharging: false))
        XCTAssertTrue(LocalNotificationScheduler.batteryAlertStillValid(level: 10,
                                                                        usable: true,
                                                                        isCharging: false))
    }

    func testDisputedCachedTransitionNeedsFreshStableSeriesEvenWithoutPreviousLevel() {
        let firstAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 74,
            receivedAt: firstAt,
            pending: nil,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("A disputed cache must not accept the first fresh level")
        }

        let second = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 75,
            receivedAt: firstAt.addingTimeInterval(6),
            pending: firstCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let secondCandidate) = second else {
            return XCTFail("A disputed cache must remain unavailable before one minute")
        }

        XCTAssertEqual(AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 74,
            receivedAt: firstAt.addingTimeInterval(12),
            pending: secondCandidate,
            requiresFreshConfirmation: true
        ), .accept)
    }

    func testFreshLaunchRejectsTransientHundredAndZeroBeforeStableLiveLevel() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let hundred = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 100,
            receivedAt: start, pending: nil, requiresFreshConfirmation: true
        )
        guard case .quarantine(let hundredCandidate) = hundred else {
            return XCTFail("A launch-time 100% read must stay hidden")
        }
        let zero = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 0,
            receivedAt: start.addingTimeInterval(5), pending: hundredCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let zeroCandidate) = zero else {
            return XCTFail("A transient 0% read must stay hidden")
        }
        XCTAssertEqual(zeroCandidate.confirmations, 1)

        let live1 = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 43,
            receivedAt: start.addingTimeInterval(8), pending: zeroCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let liveCandidate1) = live1 else {
            return XCTFail("The first correct live read still needs corroboration")
        }
        let live2 = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 43,
            receivedAt: start.addingTimeInterval(14), pending: liveCandidate1,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let liveCandidate2) = live2 else {
            return XCTFail("The correct series must span the stability window")
        }
        XCTAssertEqual(AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 43,
            receivedAt: start.addingTimeInterval(20), pending: liveCandidate2,
            requiresFreshConfirmation: true
        ), .accept)
    }

    func testFreshLaunchBoundaryValuesNeedExtendedStabilityBeforeDisplay() {
        XCTAssertEqual(AtriaBLEManager.freshBatteryMinimumConfirmationSpan(incomingLevel: 0), 15 * 60)
        XCTAssertEqual(AtriaBLEManager.freshBatteryMinimumConfirmationSpan(incomingLevel: 10), 15 * 60)
        XCTAssertEqual(AtriaBLEManager.freshBatteryMinimumConfirmationSpan(incomingLevel: 100), 15 * 60)
        XCTAssertEqual(AtriaBLEManager.freshBatteryMinimumConfirmationSpan(incomingLevel: 43), 12)

        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 10,
            receivedAt: start, pending: nil, requiresFreshConfirmation: true
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("A launch-time 10% read must remain hidden")
        }
        let second = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 10,
            receivedAt: start.addingTimeInterval(6), pending: firstCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let secondCandidate) = second else {
            return XCTFail("A repeated 10% read must remain hidden")
        }
        let atTwelve = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 10,
            receivedAt: start.addingTimeInterval(12), pending: secondCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine = atTwelve else {
            return XCTFail("The transient boundary must not use the mid-range 12-second gate")
        }

        var candidate = secondCandidate
        for elapsed in [4, 8, 12].map({ TimeInterval($0 * 60) }) {
            let decision = AtriaBLEManager.batteryLevelAcceptanceDecision(
                previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 10,
                receivedAt: start.addingTimeInterval(elapsed), pending: candidate,
                requiresFreshConfirmation: true
            )
            guard case .quarantine(let next) = decision else {
                return XCTFail("A boundary reading must remain hidden before fifteen minutes")
            }
            XCTAssertEqual(next.firstSeenAt, start, "The long-lived boundary candidate must not reset at five minutes")
            candidate = next
        }

        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 10,
            receivedAt: start.addingTimeInterval(15 * 60), pending: candidate,
            requiresFreshConfirmation: true
        ) else {
            return XCTFail("A launch sentinel without a credible trajectory must remain hidden")
        }

        let changedBoundary = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1, previousAcceptedAt: nil, incomingLevel: 100,
            receivedAt: start.addingTimeInterval(13 * 60), pending: candidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let restarted) = changedBoundary else {
            return XCTFail("A conflicting boundary value must restart confirmation")
        }
        XCTAssertEqual(restarted.confirmations, 1)
        XCTAssertEqual(restarted.firstSeenAt, start.addingTimeInterval(13 * 60))
    }

    func testBoundaryRequiresPlausibleGradualTrajectory() {
        XCTAssertFalse(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: 82, incomingLevel: 100
        ))
        XCTAssertFalse(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: 43, incomingLevel: 0
        ))
        XCTAssertFalse(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: -1, incomingLevel: 100
        ))
        XCTAssertTrue(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: 99, incomingLevel: 100
        ))
        XCTAssertTrue(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: 5, incomingLevel: 0
        ))
        XCTAssertTrue(AtriaBLEManager.isPlausibleBatterySentinelTransition(
            previousLevel: 14, incomingLevel: 10
        ))
    }

    func testBareStandardBatteryBoundaryRemainsQuarantinedDespiteNearbyPrior() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 99,
            previousAcceptedAt: now.addingTimeInterval(-120),
            incomingLevel: 100,
            receivedAt: now,
            pending: nil
        ) else {
            return XCTFail("a nearby prior does not independently prove a bare restoration 100% value")
        }
        guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: 4,
            previousAcceptedAt: now.addingTimeInterval(-120),
            incomingLevel: 0,
            receivedAt: now,
            pending: nil
        ) else {
            return XCTFail("a bare 0% BAS value must wait for CRC-backed voltage and trajectory proof")
        }
    }

    func testRawPoweredStatusCannotOriginateChargingButValidatedFullCanTerminateIt() {
        XCTAssertNil(AtriaBLEManager.acceptedBatteryChargeStatus(
            .charging, batteryLevel: 82, hasPlausibleRiseEvidence: false
        ))
        XCTAssertEqual(AtriaBLEManager.acceptedBatteryChargeStatus(
            .full, batteryLevel: 100, hasPlausibleRiseEvidence: false
        ), .full, "Full also requires the independently accepted 100% level boundary")
        XCTAssertNil(AtriaBLEManager.acceptedBatteryChargeStatus(
            .full, batteryLevel: 82, hasPlausibleRiseEvidence: true
        ))
        XCTAssertNil(AtriaBLEManager.acceptedBatteryChargeStatus(
            .charging, batteryLevel: 83, hasPlausibleRiseEvidence: true
        ))
        XCTAssertEqual(AtriaBLEManager.acceptedBatteryChargeStatus(
            .full, batteryLevel: 100, hasPlausibleRiseEvidence: true
        ), .full)
        XCTAssertEqual(AtriaBLEManager.acceptedBatteryChargeStatus(
            .notCharging, batteryLevel: 82, hasPlausibleRiseEvidence: false
        ), .notCharging)
        XCTAssertNil(AtriaBLEManager.chargeEvidenceFromBatteryLevelChange(
            previousLevel: 82, newLevel: 83
        ), "one percentage-point rise cannot claim the strap is charging")
        XCTAssertEqual(AtriaBLEManager.chargeEvidenceFromBatteryLevelChange(
            previousLevel: 82, newLevel: 81
        ), .notCharging)
        XCTAssertEqual(AtriaBLEManager.chargeEvidenceFromBatteryLevelChange(
            previousLevel: 99, newLevel: 100
        ), .full)
    }

    func testAccepted2A19CallbackUsesSustainedRiseProofAsItsOnlyChargingAuthority() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let callbackStart = try XCTUnwrap(source.range(of: "if uuid == UUIDs.batteryLevel"))
        let callbackEnd = try XCTUnwrap(source.range(
            of: "if uuid == UUIDs.batteryLevelStatus",
            range: callbackStart.upperBound..<source.endIndex
        ))
        let callback = String(source[callbackStart.lowerBound..<callbackEnd.lowerBound])

        XCTAssertTrue(callback.contains("Self.batteryRiseCandidateProvesCharging("),
                      "the production 2A19 callback must consume the bounded trajectory proof")
        XCTAssertTrue(callback.contains("source: \"live_2A19_charge_trajectory\""))
        XCTAssertTrue(callback.contains("reason: \"battery_rise_trajectory\""))
        XCTAssertFalse(callback.contains("lastRiseAt: lastUncorroboratedChargingStatusAt"),
                       "a raw powered bit plus one rise must not authorize Charging")
    }

    func testRawPoweredCallbackCannotRenewOrEraseStrongerChargeTruth() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let callbackStart = try XCTUnwrap(source.range(of: "if uuid == UUIDs.batteryLevelStatus"))
        let callback = String(source[callbackStart.lowerBound...].prefix(8_000))

        XCTAssertTrue(callback.contains("reason=fresh_rise_trajectory_owns_authority"))
        XCTAssertTrue(callback.contains("reason=terminal_status_owns_authority"))
        XCTAssertTrue(callback.contains("status == .notCharging || status == .full"),
                      "accepted terminal states must reset the accumulated rise trajectory")
        XCTAssertFalse(callback.contains("recordBatteryChargeEvidence(\n                                .charging"),
                       "the raw status callback must never create or renew a Charging lease")
    }

    func testPersistedBoundaryIsInvalidatedWithoutDeletingLastCredibleLevel() throws {
        let suite = "AtriaBLERecoveryCadenceTests.boundary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(100, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(1_100.0, forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set(82, forKey: AtriaBLEManager.BatteryDefaults.credibleLevel)
        defaults.set(1_000.0, forKey: AtriaBLEManager.BatteryDefaults.credibleAt)
        defaults.set(AtriaBLEManager.BatteryChargeStatus.full.rawValue,
                     forKey: AtriaBLEManager.BatteryDefaults.chargeStatus)
        defaults.set(true,
                     forKey: AtriaBLEManager.StrapStreamDefaults.lowBatteryReconnectSuppressed)

        XCTAssertTrue(AtriaBLEManager.invalidateUnverifiedCachedBatterySentinelIfNeeded(
            defaults: defaults
        ))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.level))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.at))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.BatteryDefaults.chargeStatus))
        XCTAssertEqual(defaults.integer(forKey: AtriaBLEManager.BatteryDefaults.credibleLevel), 82)
        XCTAssertEqual(defaults.double(forKey: AtriaBLEManager.BatteryDefaults.credibleAt), 1_000)
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.BatteryDefaults.source),
                       "disputed_boundary_sentinel")
        XCTAssertTrue(defaults.bool(forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation))
        XCTAssertFalse(defaults.bool(
            forKey: AtriaBLEManager.StrapStreamDefaults.lowBatteryReconnectSuppressed
        ))
    }

    func testBatteryRefreshCadenceAndVisibleFreshnessFailClosed() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(AtriaBLEManager.shouldRequestBatteryRefresh(lastRequestedAt: nil, now: now))
        XCTAssertFalse(AtriaBLEManager.shouldRequestBatteryRefresh(
            lastRequestedAt: now.addingTimeInterval(-119), now: now
        ))
        XCTAssertTrue(AtriaBLEManager.shouldRequestBatteryRefresh(
            lastRequestedAt: now.addingTimeInterval(-120), now: now
        ))

        XCTAssertFalse(AtriaBLEManager.batteryLevelIsFresh(lastAcceptedAt: nil, now: now))
        XCTAssertTrue(AtriaBLEManager.batteryLevelIsFresh(
            lastAcceptedAt: now.addingTimeInterval(-600), now: now
        ))
        XCTAssertFalse(AtriaBLEManager.batteryLevelIsFresh(
            lastAcceptedAt: now.addingTimeInterval(-601), now: now
        ))
    }

    func testStaleLowBatteryCannotDisableMotionOrSteps() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(AtriaBLEManager.resolvedMotionBatteryLevel(
            liveLevel: 10,
            liveAcceptedAt: now.addingTimeInterval(-601),
            cachedLevel: 10,
            cachedAt: now.addingTimeInterval(-601),
            now: now
        ), -1)
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(
            batteryLevel: -1,
            isCharging: false
        ))
        XCTAssertEqual(AtriaBLEManager.resolvedMotionBatteryLevel(
            liveLevel: 10,
            liveAcceptedAt: now.addingTimeInterval(-599),
            cachedLevel: nil,
            cachedAt: nil,
            now: now
        ), 10)
        XCTAssertFalse(AtriaBLEManager.shouldArmHighFrequencyMotion(
            batteryLevel: 10,
            isCharging: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(
            batteryLevel: 10,
            isCharging: false,
            calibrationActive: true
        ))
    }

    @MainActor
    func testBatteryNotificationSnapshotRequiresFreshPersistedEvidence() throws {
        let suite = "AtriaBLERecoveryCadenceTests.notificationBattery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set(10, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set("live_2A19", forKey: AtriaBLEManager.BatteryDefaults.source)

        defaults.set(now.addingTimeInterval(-601).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.at)
        XCTAssertFalse(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 10,
            liveChargeStatus: .notCharging,
            defaults: defaults,
            now: now
        ).usable)

        defaults.set(now.addingTimeInterval(-599).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.at)
        XCTAssertFalse(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 10,
            liveChargeStatus: .notCharging,
            defaults: defaults,
            now: now
        ).usable, "a cached boundary value cannot retain live trajectory proof")

        defaults.set(43, forKey: AtriaBLEManager.BatteryDefaults.level)
        XCTAssertTrue(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 43,
            liveChargeStatus: .notCharging,
            defaults: defaults,
            now: now
        ).usable)

        defaults.set(true, forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)
        XCTAssertFalse(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 43,
            liveChargeStatus: .notCharging,
            defaults: defaults,
            now: now
        ).usable, "a reconnect cache is comparison evidence, not display truth")
        defaults.removeObject(forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)

        defaults.removeObject(forKey: AtriaBLEManager.BatteryDefaults.at)
        XCTAssertFalse(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 43,
            liveChargeStatus: .levelOnly,
            defaults: defaults,
            now: now
        ).usable)
    }

    @MainActor
    func testBatteryNotificationAndWidgetConsumersHonorActiveMidrangeLease() throws {
        let suite = "AtriaBLERecoveryCadenceTests.notificationBatteryLease.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set(12, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set("live_2A19", forKey: AtriaBLEManager.BatteryDefaults.source)
        defaults.set(now.addingTimeInterval(-40 * 60).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set(now.addingTimeInterval(-20).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.notificationLeaseAt)
        defaults.set(now.addingTimeInterval(-5 * 60).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.notificationConfirmedAt)

        XCTAssertTrue(AtriaBLEManager.cachedBattery(
            maxAge: 10 * 60,
            defaults: defaults,
            now: now,
            permitActiveNotificationLease: true
        ).usable)
        XCTAssertTrue(LocalNotificationScheduler.batterySnapshot(
            liveLevel: 12,
            liveChargeStatus: .levelOnly,
            defaults: defaults,
            now: now
        ).usable)

        defaults.set(true, forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)
        XCTAssertFalse(AtriaBLEManager.cachedBattery(
            maxAge: 10 * 60,
            defaults: defaults,
            now: now,
            permitActiveNotificationLease: true
        ).usable)
        defaults.set(false, forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)
        defaults.set(10, forKey: AtriaBLEManager.BatteryDefaults.level)
        XCTAssertFalse(AtriaBLEManager.cachedBattery(
            maxAge: 10 * 60,
            defaults: defaults,
            now: now,
            permitActiveNotificationLease: true
        ).usable, "restoration sentinels must remain unavailable even under an active lease")
    }

    @MainActor
    func testCachedBatteryAcceptsOnlyVerifiedLivePercentageSources() throws {
        let suite = "AtriaBLERecoveryCadenceTests.batterySource.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set(43, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(now.timeIntervalSince1970, forKey: AtriaBLEManager.BatteryDefaults.at)

        for source in ["live_2A19", "live_battery_event", "live_proprietary_1a"] {
            defaults.set(source, forKey: AtriaBLEManager.BatteryDefaults.source)
            XCTAssertTrue(AtriaBLEManager.cachedBattery(defaults: defaults, now: now).usable,
                          source)
        }

        for source in ["cached_2A19", "disputed_boundary_sentinel", "unknown"] {
            defaults.set(source, forKey: AtriaBLEManager.BatteryDefaults.source)
            XCTAssertFalse(AtriaBLEManager.cachedBattery(defaults: defaults, now: now).usable,
                           source)
        }
    }

    @MainActor
    func testCachedBoundaryBatteryNeverLeaksToWidgetsOrNotifications() throws {
        let suite = "AtriaBLERecoveryCadenceTests.batteryBoundary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set("live_2A19", forKey: AtriaBLEManager.BatteryDefaults.source)
        defaults.set(now.timeIntervalSince1970, forKey: AtriaBLEManager.BatteryDefaults.at)

        for level in [0, 10, 100] {
            defaults.set(level, forKey: AtriaBLEManager.BatteryDefaults.level)
            XCTAssertFalse(AtriaBLEManager.cachedBattery(defaults: defaults, now: now).usable,
                           "\(level)% is a physically observed replay sentinel")
        }
    }

    func testProductionBatteryRefreshNeverUsesPhysicallyUnstableExplicitRead() {
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: true, canNotify: true, isNotifying: true
        ), .awaitNotification)
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: true, canNotify: true, isNotifying: false
        ), .subscribe)
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: true,
            canNotify: false,
            isNotifying: false
        ), .unavailable)
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: true,
            canNotify: false,
            isNotifying: false,
            explicitReadResearchEnabled: true
        ), .read)
    }

    func testFirstTrustedMidrangeNotificationResolvesPendingButSentinelsDoNot() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 43,
            receivedAt: now,
            pending: nil,
            requiresFreshConfirmation: true,
            trustedCurrentConnectionNotification: true
        ), .accept)

        for level in [0, 10, 100] {
            guard case .quarantine = AtriaBLEManager.batteryLevelAcceptanceDecision(
                previousLevel: -1,
                previousAcceptedAt: nil,
                incomingLevel: level,
                receivedAt: now,
                pending: nil,
                requiresFreshConfirmation: true,
                trustedCurrentConnectionNotification: true
            ) else {
                return XCTFail("A restoration sentinel must remain hidden: \(level)")
            }
        }
    }

    @MainActor
    func testActiveBatteryNotificationLeaseDoesNotRewriteLevelSampleAge() throws {
        let suite = "AtriaBLERecoveryCadenceTests.battery-notification-lease"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set(43, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set("live_2A19", forKey: AtriaBLEManager.BatteryDefaults.source)
        defaults.set(now.addingTimeInterval(-3_600).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set(now.addingTimeInterval(-30).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.notificationLeaseAt)
        defaults.set(false,
                     forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)

        let cached = AtriaBLEManager.cachedBattery(maxAge: 10 * 60,
                                                   defaults: defaults,
                                                   now: now)
        XCTAssertFalse(cached.usable,
                       "a transport lease must not make a one-hour-old percentage fresh")
        XCTAssertEqual(cached.age, 3_600, accuracy: 0.001)
        defaults.set(true,
                     forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)
        XCTAssertFalse(AtriaBLEManager.cachedBattery(maxAge: 10 * 60,
                                                      defaults: defaults,
                                                      now: now).usable)
    }

    func testNotificationLeaseBridgesOnlyAConnectedMidrangeLive2A19Restoration() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let leaseAt = now.addingTimeInterval(-30)
        XCTAssertTrue(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
            level: 43,
            source: "live_2A19",
            requiresFreshConfirmation: false,
            linkConnected: true,
            notificationLeaseAt: leaseAt,
            now: now
        ))
        for level in [0, 10, 100] {
            XCTAssertFalse(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
                level: level,
                source: "live_2A19",
                requiresFreshConfirmation: false,
                linkConnected: true,
                notificationLeaseAt: leaseAt,
                now: now
            ))
        }
        XCTAssertFalse(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
            level: 43,
            source: "live_battery_event",
            requiresFreshConfirmation: false,
            linkConnected: true,
            notificationLeaseAt: leaseAt,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
            level: 43,
            source: "live_2A19",
            requiresFreshConfirmation: true,
            linkConnected: true,
            notificationLeaseAt: leaseAt,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
            level: 43,
            source: "live_2A19",
            requiresFreshConfirmation: false,
            linkConnected: false,
            notificationLeaseAt: leaseAt,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.notificationLeaseSupportsBatteryDisplay(
            level: 43,
            source: "live_2A19",
            requiresFreshConfirmation: false,
            linkConnected: true,
            notificationLeaseAt: now.addingTimeInterval(-601),
            now: now
        ))
    }

    func testBatteryValueErrorInvalidatesTransportEvenWhenCharacteristicStillNotifying() {
        XCTAssertFalse(AtriaBLEManager.batteryNotificationTransportEvidenceIsUsable(
            characteristicIsNotifying: true,
            confirmationSupportsCurrentConnection: true,
            lastError: "The connection is invalid"
        ))
        XCTAssertTrue(AtriaBLEManager.batteryNotificationTransportEvidenceIsUsable(
            characteristicIsNotifying: true,
            confirmationSupportsCurrentConnection: false,
            lastError: nil
        ))
        XCTAssertTrue(AtriaBLEManager.batteryNotificationTransportEvidenceIsUsable(
            characteristicIsNotifying: false,
            confirmationSupportsCurrentConnection: true,
            lastError: nil
        ))
    }

    func testBatteryValueErrorRevokesLeaseAndForcesSubscriptionCycleWithoutErasingLevel() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "private func recoverBatteryNotificationAfterValueError"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func recordBatteryChargeEvidence",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("revokeBatteryNotificationLease"))
        XCTAssertTrue(body.contains("pendingNotifyReenableUUIDs.insert"))
        XCTAssertTrue(body.contains("setNotifyValue(false"))
        XCTAssertTrue(body.contains("setNotifyValue(true"))
        XCTAssertFalse(body.contains("batteryLevel = -1"),
                       "a transport error must not erase a separately packet-fresh accepted value")

        let callback = try XCTUnwrap(source.range(of:
            "didUpdateValueFor characteristic: CBCharacteristic, error: Error?)"))
        let callbackBody = String(source[callback.lowerBound...])
        XCTAssertTrue(callbackBody.contains("recoverBatteryNotificationAfterValueError"))
        XCTAssertTrue(callbackBody.contains("errorDescription: \"missing 2A19 characteristic value\""),
                      "a nil 2A19 callback must revoke the same transport lease as a CoreBluetooth error")
        XCTAssertTrue(callbackBody.contains("errorDescription: \"malformed 2A19 payload\""),
                      "a malformed percentage must not leave a previously confirmed lease authoritative")
        XCTAssertTrue(callbackBody.contains("if self.batteryNotificationTransportIsActive(now: receivedAt)"))
        XCTAssertTrue(callbackBody.contains("removeObject(\n                            forKey: BatteryDefaults.notificationLeaseAt"),
                      "a fresh value may remain visible, but must not renew the failed transport lease")
    }

    func testBatteryOffErrorRecoveryRetriesThenRediscoversAndReconnects() throws {
        XCTAssertEqual(AtriaBLEManager.batteryNotificationRecoveryAction(
            connected: true,
            isNotifying: true,
            attempt: 0
        ), .retryDisable,
        "a failed setNotify(false) must not be mistaken for a completed off transition")
        XCTAssertEqual(AtriaBLEManager.batteryNotificationRecoveryAction(
            connected: true,
            isNotifying: false,
            attempt: 0
        ), .enable)
        XCTAssertEqual(AtriaBLEManager.batteryNotificationRecoveryAction(
            connected: true,
            isNotifying: true,
            attempt: 1
        ), .rediscover)
        XCTAssertEqual(AtriaBLEManager.batteryNotificationRecoveryAction(
            connected: true,
            isNotifying: true,
            attempt: 2
        ), .reconnect)
        XCTAssertEqual(AtriaBLEManager.batteryNotificationRecoveryAction(
            connected: false,
            isNotifying: true,
            attempt: 0
        ), .waitForConnection)

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let callbackStart = try XCTUnwrap(source.range(of:
            "didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?)"))
        let callback = String(source[callbackStart.lowerBound...])
        let batteryStart = try XCTUnwrap(callback.range(of:
            "if characteristic.uuid == Self.UUIDs.batteryLevel"))
        let batteryEnd = try XCTUnwrap(callback.range(
            of: "if self.motionHandshakeDiagnostic != nil",
            range: batteryStart.upperBound..<callback.endIndex
        ))
        let batteryBranch = String(callback[batteryStart.lowerBound..<batteryEnd.lowerBound])
        XCTAssertTrue(batteryBranch.contains("armBatteryNotificationRecoveryWatchdog"))
        XCTAssertTrue(batteryBranch.contains("completeBatteryNotificationRecovery"))
        XCTAssertFalse(batteryBranch.contains("pendingNotifyReenableUUIDs.remove(characteristic.uuid)\n                self.dbgLast"),
                       "the generic error handler must not consume the battery retry marker")

        let watchdogStart = try XCTUnwrap(source.range(of:
            "private func armBatteryNotificationRecoveryWatchdog"))
        let watchdogEnd = try XCTUnwrap(source.range(of:
            "private func completeBatteryNotificationRecovery",
            range: watchdogStart.upperBound..<source.endIndex))
        let watchdog = String(source[watchdogStart.lowerBound..<watchdogEnd.lowerBound])
        XCTAssertTrue(watchdog.contains("peripheral.discoverServices([Self.UUIDs.batteryService])"))
        XCTAssertTrue(watchdog.contains("requestFreshScanReconnect"))
    }

    func testBatteryHydrationRevokesOldLeaseAndNotifyActivationRetriesPromotion() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let hydrateStart = try XCTUnwrap(source.range(of: "private func hydrateCachedBatteryStateIfFresh"))
        let hydrateEnd = try XCTUnwrap(source.range(
            of: "private func promoteReconnectBatteryBaselineIfSafe",
            range: hydrateStart.upperBound..<source.endIndex
        ))
        let hydrateBody = String(source[hydrateStart.lowerBound..<hydrateEnd.lowerBound])
        XCTAssertTrue(hydrateBody.contains("defaults.removeObject(forKey: BatteryDefaults.notificationLeaseAt)"))
        XCTAssertTrue(hydrateBody.contains("defaults.set(true, forKey: BatteryDefaults.requiresFreshConfirmation)"))
        XCTAssertTrue(hydrateBody.contains("permitPendingReconnectBaseline: true"))

        XCTAssertTrue(source.contains("reason: \"2A19_notify_became_active\""))
        XCTAssertTrue(source.contains("reason: \"2A19_restored_cache_notify_active\""))
        XCTAssertTrue(source.contains("reason: \"2A19_existing_notify_active\""))
    }

    @MainActor
    func testHydrationMayRetainOnlyTrustedMidrangeWhileFreshConfirmationIsPending() {
        let suite = "AtriaBLERecoveryCadenceTests.pendingHydration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 50_000)

        defaults.set(18, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(now.addingTimeInterval(-25 * 60).timeIntervalSince1970,
                     forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set("live_battery_event", forKey: AtriaBLEManager.BatteryDefaults.source)
        defaults.set(true, forKey: AtriaBLEManager.BatteryDefaults.requiresFreshConfirmation)

        XCTAssertFalse(AtriaBLEManager.cachedBattery(
            maxAge: 36 * 60 * 60,
            defaults: defaults,
            now: now
        ).usable, "ordinary consumers must still fail closed while confirmation is pending")
        XCTAssertTrue(AtriaBLEManager.cachedBattery(
            maxAge: 36 * 60 * 60,
            defaults: defaults,
            now: now,
            permitPendingReconnectBaseline: true
        ).usable, "launch hydration must retain accepted 18% as an aged reconnect baseline")

        defaults.set(100, forKey: AtriaBLEManager.BatteryDefaults.level)
        XCTAssertFalse(AtriaBLEManager.cachedBattery(
            maxAge: 36 * 60 * 60,
            defaults: defaults,
            now: now,
            permitPendingReconnectBaseline: true
        ).usable, "restored boundary sentinels remain ineligible")

        defaults.set(18, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set("disputed_rapid_transition", forKey: AtriaBLEManager.BatteryDefaults.source)
        XCTAssertFalse(AtriaBLEManager.cachedBattery(
            maxAge: 36 * 60 * 60,
            defaults: defaults,
            now: now,
            permitPendingReconnectBaseline: true
        ).usable, "disputed sources remain ineligible")
    }

    func testNonReadableBatteryRefreshOnlyStartsANewSubscriptionOnce() {
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: false, canNotify: true, isNotifying: false
        ), .subscribe)
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: false, canNotify: true, isNotifying: true
        ), .awaitNotification)
        XCTAssertEqual(AtriaBLEManager.standardBatteryRefreshAction(
            canRead: false, canNotify: false, isNotifying: false
        ), .unavailable)
    }

    func testCachedNotifyingBatteryCharacteristicRefreshesOnlyAnUnconfirmedEpoch() {
        XCTAssertEqual(AtriaBLEManager.existingBatteryNotificationAction(
            currentEpochConfirmed: false,
            recoveryInFlight: false
        ), .refreshUnconfirmedEpoch)
        XCTAssertEqual(AtriaBLEManager.existingBatteryNotificationAction(
            currentEpochConfirmed: true,
            recoveryInFlight: false
        ), .awaitCurrentEpoch)
        XCTAssertEqual(AtriaBLEManager.existingBatteryNotificationAction(
            currentEpochConfirmed: false,
            recoveryInFlight: true
        ), .awaitRecovery,
        "keepalive refreshes must not stack duplicate CCCD off/on cycles")
    }

    func testValidatedCurrentConnectionR10CanPromoteBatteryWithoutPostReconnectHR() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let base = (
            level: 42,
            acceptedAt: Optional(now.addingTimeInterval(-40 * 60)),
            source: "live_2A19"
        )
        XCTAssertTrue(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: base.level,
            acceptedAt: base.acceptedAt,
            source: base.source,
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            notificationActive: true,
            linkConnected: true,
            currentConnectionHasHeartRate: false,
            currentConnectionHasValidatedR10: true,
            now: now
        ), "CRC-valid current-link R10 is strap/link proof even when 2A37 is temporarily silent")
        XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: base.level,
            acceptedAt: base.acceptedAt,
            source: base.source,
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            notificationActive: true,
            linkConnected: true,
            currentConnectionHasHeartRate: false,
            currentConnectionHasValidatedR10: false,
            now: now
        ), "a cached percentage still needs current-link strap evidence")
    }

    func testFreshRenewedBatteryLeaseDoesNotExpireWithOriginalCCCDCallback() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(AtriaBLEManager.persistedBatteryNotificationLeaseSupportsDisplay(
            level: 42,
            source: "live_2A19",
            requiresFreshConfirmation: false,
            notificationLeaseAt: now.addingTimeInterval(-30),
            notificationConfirmedAt: now.addingTimeInterval(-3 * 60 * 60),
            now: now
        ), "a healthy live app's fresh lease remains authoritative on a long-lived link")
        XCTAssertFalse(AtriaBLEManager.persistedBatteryNotificationLeaseSupportsDisplay(
            level: 42,
            source: "live_2A19",
            requiresFreshConfirmation: false,
            notificationLeaseAt: now.addingTimeInterval(-11 * 60),
            notificationConfirmedAt: now.addingTimeInterval(-3 * 60 * 60),
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.persistedBatteryNotificationLeaseSupportsDisplay(
            level: 42,
            source: "live_2A19",
            requiresFreshConfirmation: true,
            notificationLeaseAt: now.addingTimeInterval(-30),
            notificationConfirmedAt: now.addingTimeInterval(-3 * 60 * 60),
            now: now
        ))
    }

    func testReconnectEvictsBoundarySentinelAndRestoresRecentCredibleLevel() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(AtriaBLEManager.reconnectBatteryDisplayLevel(
            currentLevel: 100,
            credibleLevel: 43,
            credibleAt: now.addingTimeInterval(-60),
            now: now
        ), 43)
        XCTAssertEqual(AtriaBLEManager.reconnectBatteryDisplayLevel(
            currentLevel: 0,
            credibleLevel: 43,
            credibleAt: now.addingTimeInterval(-6 * 60 * 60 - 1),
            now: now,
            maxAge: AtriaBLEManager.reconnectBatteryBaselineMaximumAge
        ), -1)
        XCTAssertEqual(AtriaBLEManager.reconnectBatteryDisplayLevel(
            currentLevel: 0,
            credibleLevel: 43,
            credibleAt: now.addingTimeInterval(-20 * 60),
            now: now,
            maxAge: AtriaBLEManager.reconnectBatteryBaselineMaximumAge
        ), 43, "cold launch must retain the same bounded baseline promotion can safely lease")
        XCTAssertEqual(AtriaBLEManager.reconnectBatteryDisplayLevel(
            currentLevel: 43,
            credibleLevel: 70,
            credibleAt: now,
            now: now
        ), 43)
    }

    func testStableNotificationReconnectPromotesRecentValidatedMidrangeBaseline() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let acceptedAt = now.addingTimeInterval(-20 * 60)
        XCTAssertTrue(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: 30,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            notificationActive: true,
            linkConnected: true,
            currentConnectionHasHeartRate: true,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ), "change-driven 2A19 must not leave a recent trusted value Pending forever")

        for sentinel in [0, 10, 100] {
            XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
                level: sentinel,
                acceptedAt: acceptedAt,
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                notificationActive: true,
                linkConnected: true,
                currentConnectionHasHeartRate: true,
                hasPendingDisputedReading: false,
                currentNotificationEpochHadRejectedCallback: false,
                now: now
            ), "restoration sentinel \(sentinel) must remain quarantined")
        }

        let common = (
            level: 30,
            acceptedAt: Optional(acceptedAt),
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            notificationActive: true,
            linkConnected: true,
            currentConnectionHasHeartRate: true
        )
        XCTAssertTrue(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: now.addingTimeInterval(-6 * 60 * 60 - 1),
            source: common.source,
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ), "a proven current 2A19 subscription must not turn a valid mid-range level Pending after six hours")
        XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: now.addingTimeInterval(-36 * 60 * 60 - 1),
            source: common.source,
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ), "a transport lease cannot make a percentage older than the overnight bridge current")
        XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: now.addingTimeInterval(
                -AtriaBLEManager.activeBatterySubscriptionBaselineMaximumAge - 1
            ),
            source: common.source,
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ), "even a proven subscription must not carry a percentage beyond the bounded overnight bridge")
        XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: common.acceptedAt,
            source: "unknown",
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: common.acceptedAt,
            source: common.source,
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: false,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: common.acceptedAt,
            source: common.source,
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: false,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ))

        XCTAssertTrue(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: common.level,
            acceptedAt: common.acceptedAt,
            source: "live_battery_event",
            displayedIsCached: common.displayedIsCached,
            requiresFreshConfirmation: common.requiresFreshConfirmation,
            notificationActive: common.notificationActive,
            linkConnected: common.linkConnected,
            currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ), "a recent CRC + voltage validated battery event is safe recent baseline truth")

        for rejectedSource in ["live_proprietary_1a", "cached_2A19", "unknown"] {
            XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
                level: common.level,
                acceptedAt: common.acceptedAt,
                source: rejectedSource,
                displayedIsCached: common.displayedIsCached,
                requiresFreshConfirmation: common.requiresFreshConfirmation,
                notificationActive: common.notificationActive,
                linkConnected: common.linkConnected,
                currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
                hasPendingDisputedReading: false,
                currentNotificationEpochHadRejectedCallback: false,
                now: now
            ), "an unqualified source must never inherit the standard notification lease")
        }

        for (pending, rejectedEpochCallback) in [(true, false), (false, true)] {
            XCTAssertFalse(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
                level: common.level,
                acceptedAt: common.acceptedAt,
                source: common.source,
                displayedIsCached: common.displayedIsCached,
                requiresFreshConfirmation: common.requiresFreshConfirmation,
                notificationActive: common.notificationActive,
                linkConnected: common.linkConnected,
                currentConnectionHasHeartRate: common.currentConnectionHasHeartRate,
                hasPendingDisputedReading: pending,
                currentNotificationEpochHadRejectedCallback: rejectedEpochCallback,
                now: now
            ), "a disputed or unadjudicated current-link callback must remain Pending")
        }
    }

    func testKeepaliveRetainsReconnectBatteryBaselineUntilProofCanArrive() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let acceptedAt = now.addingTimeInterval(-25 * 60)
        let validationStartedAt = now.addingTimeInterval(-8)

        XCTAssertTrue(AtriaBLEManager.reconnectBatteryBaselineIsAwaitingProof(
            level: 12,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            validationStartedAt: validationStartedAt,
            now: now
        ), "the first keepalive tick must not erase a valid baseline before HR promotion")

        XCTAssertFalse(AtriaBLEManager.reconnectBatteryBaselineIsAwaitingProof(
            level: 12,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            validationStartedAt: now.addingTimeInterval(-91),
            now: now
        ), "a failed reconnect must not retain an undisplayable baseline indefinitely")

        for sentinel in [0, 10, 100] {
            XCTAssertFalse(AtriaBLEManager.reconnectBatteryBaselineIsAwaitingProof(
                level: sentinel,
                acceptedAt: acceptedAt,
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                linkConnected: true,
                sameSavedPeripheral: true,
                validationStartedAt: validationStartedAt,
                now: now
            ))
        }
    }

    func testTrustedCurrentConnectionBatteryNotificationIsRadioProfileIndependent() throws {
        XCTAssertTrue(AtriaBLEManager.batteryReconnectBaselineSourceIsLeaseEligible("live_2A19"))
        XCTAssertTrue(AtriaBLEManager.batteryReconnectBaselineSourceIsLeaseEligible("live_battery_event"))
        XCTAssertFalse(AtriaBLEManager.batteryReconnectBaselineSourceIsLeaseEligible("live_proprietary_1a"))
        XCTAssertFalse(AtriaBLEManager.batteryReconnectBaselineSourceIsLeaseEligible("disputed_boundary_sentinel"))

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let callbackStart = try XCTUnwrap(source.range(of: "if uuid == UUIDs.batteryLevel"))
        let callbackEnd = try XCTUnwrap(source.range(
            of: "if uuid == UUIDs.batteryLevelStatus",
            range: callbackStart.upperBound..<source.endIndex
        ))
        let callback = String(source[callbackStart.lowerBound..<callbackEnd.lowerBound])
        XCTAssertTrue(callback.contains("trustedCurrentConnectionNotification: Self.batteryValueBelongsToCurrentConnection("))
        XCTAssertTrue(callback.contains("connectionStartedAt: self.connectedAt"))
        XCTAssertFalse(callback.contains("&& self.standardHROnlyMode"),
                       "standard 2A19 validity must not depend on the unrelated R10 radio profile")
    }

    func testRelaunchChainKeepsConfirmedNotificationLeaseWhenCoreBluetoothReplacesCharacteristic() {
        let acceptedAt = Date(timeIntervalSince1970: 10_000)
        let relaunchedAt = acceptedAt.addingTimeInterval(12 * 60)
        let confirmedAt = relaunchedAt.addingTimeInterval(1)
        let liveHRAt = confirmedAt.addingTimeInterval(1)

        XCTAssertTrue(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: nil,
            connectionStartedAt: relaunchedAt,
            linkConnected: true,
            now: liveHRAt
        ), "a current-epoch CCCD confirmation survives replacement of the restored characteristic object")
        XCTAssertTrue(AtriaBLEManager.shouldPromoteReconnectBatteryBaseline(
            level: 26,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            notificationActive: true,
            linkConnected: true,
            currentConnectionHasHeartRate: true,
            now: liveHRAt
        ))

        XCTAssertFalse(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: "inactive",
            connectionStartedAt: relaunchedAt,
            linkConnected: true,
            now: liveHRAt
        ))
        XCTAssertFalse(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: relaunchedAt.addingTimeInterval(-1),
            lastError: nil,
            connectionStartedAt: relaunchedAt,
            linkConnected: true,
            now: liveHRAt
        ), "a confirmation from the previous process/connection cannot cross the launch boundary")
        XCTAssertFalse(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: nil,
            connectionStartedAt: relaunchedAt,
            linkConnected: false,
            now: liveHRAt
        ))

        let restoredProcessAt = confirmedAt.addingTimeInterval(20 * 60)
        let savedID = UUID()
        XCTAssertTrue(AtriaBLEManager.batteryRestorationPreservesNotificationEpoch(
            restoredPeripheralIdentifier: savedID,
            savedPeripheralIdentifier: savedID,
            restoredPeripheralIsConnected: true
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRestorationPreservesNotificationEpoch(
            restoredPeripheralIdentifier: UUID(),
            savedPeripheralIdentifier: savedID,
            restoredPeripheralIsConnected: true
        ))
        XCTAssertFalse(AtriaBLEManager.batteryRestorationPreservesNotificationEpoch(
            restoredPeripheralIdentifier: savedID,
            savedPeripheralIdentifier: savedID,
            restoredPeripheralIsConnected: false
        ))
        XCTAssertTrue(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: nil,
            connectionStartedAt: nil,
            linkConnected: true,
            now: restoredProcessAt
        ), "CoreBluetooth restoration may resume the same subscribed link without didConnect")
        XCTAssertFalse(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: nil,
            connectionStartedAt: nil,
            linkConnected: true,
            now: confirmedAt.addingTimeInterval(61 * 60)
        ), "a persisted restoration proof remains bounded")

        XCTAssertFalse(AtriaBLEManager.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: confirmedAt,
            lastError: nil,
            connectionStartedAt: restoredProcessAt,
            linkConnected: true,
            now: restoredProcessAt.addingTimeInterval(1)
        ), "the same timestamps must fail for a genuine didConnect epoch")
    }

    func testRestoredSamePeripheralExplicitlyBypassesSyntheticConnectedAtForBatteryProof() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(
            "connectionStartedAt: batteryConnectionRestoredSamePeripheral ? nil : connectedAt"
        ))
        XCTAssertTrue(source.contains("self.batteryConnectionRestoredSamePeripheral ="))
        XCTAssertTrue(source.contains("restoredPeripheralIdentifier: restoredPeripheral.identifier"))
        XCTAssertTrue(source.contains("self.batteryConnectionRestoredSamePeripheral = false"))
        XCTAssertTrue(source.contains("defaults.removeObject(forKey: BatteryDefaults.notificationConfirmedAt)"))
        XCTAssertTrue(source.contains("forKey: BatteryDefaults.notificationLastError"))
    }

    func testRestoredCachedBatteryFlagCannotMintOrRepairNotificationEpoch() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let confirmedAt = now.addingTimeInterval(-60)
        XCTAssertTrue(AtriaBLEManager.restoredCachedBatteryNotificationCanReuseEpoch(
            characteristicIsNotifying: true,
            restoredSamePeripheral: true,
            confirmedAt: confirmedAt,
            lastError: nil,
            linkConnected: true,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.restoredCachedBatteryNotificationCanReuseEpoch(
            characteristicIsNotifying: true,
            restoredSamePeripheral: false,
            confirmedAt: confirmedAt,
            lastError: nil,
            linkConnected: true,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.restoredCachedBatteryNotificationCanReuseEpoch(
            characteristicIsNotifying: true,
            restoredSamePeripheral: true,
            confirmedAt: confirmedAt,
            lastError: "value callback failed",
            linkConnected: true,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.restoredCachedBatteryNotificationCanReuseEpoch(
            characteristicIsNotifying: true,
            restoredSamePeripheral: true,
            confirmedAt: nil,
            lastError: nil,
            linkConnected: true,
            now: now
        ))

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "if let cachedBattery {"))
        let end = try XCTUnwrap(source.range(
            of: "AtriaDebugLog(\"ATRIADBG protected_r10 status=restored_cache_rehydrated",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("forKey: BatteryDefaults.notificationConfirmedAt)\n                    defaults.removeObject"))
        XCTAssertFalse(body.contains("removeObject(forKey: BatteryDefaults.notificationLastError)"),
                       "cached isNotifying must never clear a prior transport error")
        XCTAssertTrue(body.contains("restoredCachedBatteryNotificationCanReuseEpoch"))
        XCTAssertTrue(body.contains("setNotifyValue(false, for: cachedBattery)"))
    }

    func testRecentValidatedMidrangeBaselineRemainsVisibleAcrossGenuineReconnectWithoutBecomingLive() {
        let acceptedAt = Date(timeIntervalSince1970: 10_000)
        let now = acceptedAt.addingTimeInterval(10 * 60 + 35)
        XCTAssertTrue(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
            level: 25,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            currentConnectionHasHeartRate: true,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ))

        for sentinel in [0, 10, 100] {
            XCTAssertFalse(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
                level: sentinel,
                acceptedAt: acceptedAt,
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                linkConnected: true,
                sameSavedPeripheral: true,
                currentConnectionHasHeartRate: true,
                hasPendingDisputedReading: false,
                currentNotificationEpochHadRejectedCallback: false,
                now: now
            ))
        }

        for (sameSaved, liveHR) in [
            (false, true),
            (true, false)
        ] {
            XCTAssertFalse(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
                level: 25,
                acceptedAt: acceptedAt,
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                linkConnected: true,
                sameSavedPeripheral: sameSaved,
                currentConnectionHasHeartRate: liveHR,
                hasPendingDisputedReading: false,
                currentNotificationEpochHadRejectedCallback: false,
                now: now
            ))
        }
        for (pending, rejected) in [(true, false), (false, true), (true, true)] {
            XCTAssertTrue(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
                level: 25,
                acceptedAt: acceptedAt,
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                linkConnected: true,
                sameSavedPeripheral: true,
                currentConnectionHasHeartRate: true,
                hasPendingDisputedReading: pending,
                currentNotificationEpochHadRejectedCallback: rejected,
                now: now
            ), "current-epoch disputes must block promotion, not the explicitly Recent baseline")
        }
        XCTAssertFalse(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
            level: 25,
            acceptedAt: acceptedAt,
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            currentConnectionHasHeartRate: true,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: acceptedAt.addingTimeInterval(6 * 60 * 60 + 1)
        ))
        XCTAssertFalse(AtriaBLEManager.recentReconnectBatteryBaselineIsDisplayEligible(
            level: 25,
            acceptedAt: acceptedAt,
            source: "cached_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            currentConnectionHasHeartRate: true,
            hasPendingDisputedReading: false,
            currentNotificationEpochHadRejectedCallback: false,
            now: now
        ))
    }

    func testRecentReconnectBaselineIsDisplayOnlyAndSurvivesKeepaliveStalenessGate() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let displayStart = try XCTUnwrap(source.range(of: "func displayableBatteryLevel"))
        let displayEnd = try XCTUnwrap(source.range(
            of: "var lastVerifiedBatteryLevelAt",
            range: displayStart.upperBound..<source.endIndex
        ))
        let displayBody = String(source[displayStart.lowerBound..<displayEnd.lowerBound])
        XCTAssertTrue(displayBody.contains("if recentReconnectBaseline { return batteryLevel }"))
        XCTAssertFalse(displayBody.contains("removeObject(forKey: BatteryDefaults.requiresFreshConfirmation)"))

        let keepaliveStart = try XCTUnwrap(source.range(of: "private func runForegroundKeepaliveTick"))
        let keepaliveEnd = try XCTUnwrap(source.range(
            of: "private func stopForegroundKeepaliveWatchdog",
            range: keepaliveStart.upperBound..<source.endIndex
        ))
        let keepaliveBody = String(source[keepaliveStart.lowerBound..<keepaliveEnd.lowerBound])
        XCTAssertTrue(keepaliveBody.contains("!recentReconnectBatteryBaselineDisplayable"))
    }

    func testFreshConnectedCachedBatteryBaselineDisplaysDuringSilentLiveRefresh() {
        let now = Date(timeIntervalSince1970: 1_800_200_000)

        XCTAssertTrue(AtriaBLEManager.freshConnectedCachedBatteryBaselineIsDisplayEligible(
            level: 14,
            acceptedAt: now.addingTimeInterval(-30),
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            now: now
        ))

        for invalidLevel in [0, 10, 100] {
            XCTAssertFalse(AtriaBLEManager.freshConnectedCachedBatteryBaselineIsDisplayEligible(
                level: invalidLevel,
                acceptedAt: now.addingTimeInterval(-30),
                source: "live_2A19",
                displayedIsCached: true,
                requiresFreshConfirmation: true,
                linkConnected: true,
                sameSavedPeripheral: true,
                now: now
            ))
        }
        XCTAssertFalse(AtriaBLEManager.freshConnectedCachedBatteryBaselineIsDisplayEligible(
            level: 14,
            acceptedAt: now.addingTimeInterval(-AtriaBLEManager.batteryDisplayFreshnessLimit - 1),
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.freshConnectedCachedBatteryBaselineIsDisplayEligible(
            level: 14,
            acceptedAt: now.addingTimeInterval(-30),
            source: "cached_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: true,
            sameSavedPeripheral: true,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.freshConnectedCachedBatteryBaselineIsDisplayEligible(
            level: 14,
            acceptedAt: now.addingTimeInterval(-30),
            source: "live_2A19",
            displayedIsCached: true,
            requiresFreshConfirmation: true,
            linkConnected: false,
            sameSavedPeripheral: true,
            now: now
        ))
    }

    func testFirstAcceptedHRPublishesRecentBatteryBaselineProjectionOnce() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let methodStart = try XCTUnwrap(source.range(
            of: "private func publishRecentReconnectBatteryBaselineIfNeeded"
        ))
        let methodEnd = try XCTUnwrap(source.range(
            of: "private func revokeBatteryNotificationLease",
            range: methodStart.upperBound..<source.endIndex
        ))
        let method = String(source[methodStart.lowerBound..<methodEnd.lowerBound])
        XCTAssertTrue(method.contains("!recentReconnectBatteryBaselineProjectionPublished"))
        XCTAssertTrue(method.contains("recentReconnectBatteryBaselineIsDisplayable(now: now)"))
        XCTAssertTrue(method.contains("recentReconnectBatteryBaselineProjectionPublished = true"))
        XCTAssertTrue(method.contains("batteryProjectionRevision &+= 1"))

        let acceptedStart = try XCTUnwrap(source.range(of: "private func recordAcceptedHRSample"))
        let acceptedEnd = try XCTUnwrap(source.range(
            of: "fileprivate func record(_ rate:",
            range: acceptedStart.upperBound..<source.endIndex
        ))
        let accepted = String(source[acceptedStart.lowerBound..<acceptedEnd.lowerBound])
        XCTAssertTrue(accepted.contains("publishRecentReconnectBatteryBaselineIfNeeded(now: sampleTime)"))
    }

    func testKeepaliveUsesDurableBatteryNotificationTransportProof() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func runForegroundKeepaliveTick"))
        let end = try XCTUnwrap(source.range(
            of: "private func stopForegroundKeepaliveWatchdog",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("let batteryNotificationTransportActive = batteryNotificationTransportIsActive"))
        XCTAssertTrue(body.contains("!(batteryNotificationTransportActive"))
        XCTAssertTrue(body.contains("batteryNotificationTransportActive,"))
        XCTAssertFalse(body.contains("batteryLevelCharacteristic?.isNotifying == true"),
                       "the stale-value watchdog must not revoke a confirmed lease because CoreBluetooth replaced its object")
    }

    func testRestoredConnectionUsesProcessBatteryValidationEpochWhenDidConnectIsAbsent() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("let connectionStartedAt = connectedAt ?? batteryBaselineValidationStartedAt"))
        XCTAssertTrue(source.contains("let currentConnectionHasHeartRate = heartRateReceivedAt.map"))
        XCTAssertTrue(source.contains("let currentConnectionHasValidatedR10 = validatedR10ReceivedAt.map"))
        XCTAssertTrue(source.contains("validatedR10ReceivedAt: receivedAt"),
                      "a decoded CRC-valid R10 frame must retry reconnect battery promotion")
        XCTAssertTrue(source.contains("batteryBaselineValidationStartedAt = Date()"))
    }

    func testChargeStatusPacketDoesNotRefreshPersistedBatteryLevelEvidence() throws {
        let suite = "AtriaBLERecoveryCadenceTests.chargeStatus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(43, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(1_000.0, forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set("live_2A19", forKey: AtriaBLEManager.BatteryDefaults.source)

        AtriaBLEManager.persistBatteryChargeStatusProjection(
            .notCharging,
            source: "live_2A1B",
            defaults: defaults,
            now: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(defaults.integer(forKey: AtriaBLEManager.BatteryDefaults.level), 43)
        XCTAssertEqual(defaults.double(forKey: AtriaBLEManager.BatteryDefaults.at), 1_000)
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.BatteryDefaults.source), "live_2A19")
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.BatteryDefaults.chargeStatus),
                       AtriaBLEManager.BatteryChargeStatus.notCharging.rawValue)
        XCTAssertEqual(defaults.double(forKey: AtriaBLEManager.BatteryDefaults.chargeAt), 2_000)
    }

    func testBatteryConfirmationRetriesAreBoundedInsteadOfTightLooping() {
        XCTAssertEqual(AtriaBLEManager.batteryConfirmationRetryDelay(incomingLevel: 43), 6)
        XCTAssertEqual(AtriaBLEManager.batteryConfirmationRetryDelay(incomingLevel: 0), 30)
        XCTAssertEqual(AtriaBLEManager.batteryConfirmationRetryDelay(incomingLevel: 10), 30)
        XCTAssertEqual(AtriaBLEManager.batteryConfirmationRetryDelay(incomingLevel: 100), 30)
    }

    func testDisputedCacheFreshConfirmationRestartsWhenReadingsDisagree() {
        let firstAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 74,
            receivedAt: firstAt,
            pending: nil,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let firstCandidate) = first else {
            return XCTFail("Expected a quarantined fresh candidate")
        }
        let disagreement = AtriaBLEManager.batteryLevelAcceptanceDecision(
            previousLevel: -1,
            previousAcceptedAt: nil,
            incomingLevel: 10,
            receivedAt: firstAt.addingTimeInterval(30),
            pending: firstCandidate,
            requiresFreshConfirmation: true
        )
        guard case .quarantine(let restarted) = disagreement else {
            return XCTFail("A disagreement must restart confirmation")
        }
        XCTAssertEqual(restarted.level, 10)
        XCTAssertEqual(restarted.confirmations, 1)
        XCTAssertEqual(restarted.firstSeenAt, firstAt.addingTimeInterval(30))
    }

    func testBatteryLevelParserRejectsMalformedPayloadsInsteadOfInventingZero() {
        XCTAssertNil(AtriaBLEManager.parseBatteryLevel(Data()))
        XCTAssertNil(AtriaBLEManager.parseBatteryLevel(Data([101])))
        XCTAssertNil(AtriaBLEManager.parseBatteryLevel(Data([80, 79])))
        XCTAssertEqual(AtriaBLEManager.parseBatteryLevel(Data([0])), 0)
        XCTAssertEqual(AtriaBLEManager.parseBatteryLevel(Data([80])), 80)
        XCTAssertEqual(AtriaBLEManager.parseBatteryLevel(Data([100])), 100)
    }

    func testDayScopedStrapStepsExcludeThePreviousDaysSessionTotal() {
        XCTAssertEqual(AtriaBLEManager.dayScopedStrapStepCount(sessionCount: 8_240,
                                                               dayBaseline: 8_000), 240)
        XCTAssertEqual(AtriaBLEManager.dayScopedStrapStepCount(sessionCount: 240,
                                                               dayBaseline: 0), 240)
        XCTAssertEqual(AtriaBLEManager.dayScopedStrapStepCount(sessionCount: 10,
                                                               dayBaseline: 20), 0)
    }

    func testLowerR10SnapshotCannotOverwritePersistedSessionStepPrefix() {
        let reconciled = AtriaBLEManager.monotonicStrapStepTotals(
            currentSteps: 123,
            currentRawSteps: 111,
            incomingSteps: 4,
            incomingRawSteps: 4
        )

        XCTAssertEqual(reconciled, .init(steps: 123, rawSteps: 111))
    }

    func testR10SnapshotGenerationRejectsDelayedPreResetCallback() {
        XCTAssertTrue(AtriaBLEManager.shouldApplyR10MotionSnapshot(
            snapshotGeneration: 8,
            activeGeneration: 8
        ))
        XCTAssertFalse(AtriaBLEManager.shouldApplyR10MotionSnapshot(
            snapshotGeneration: 7,
            activeGeneration: 8
        ))
        XCTAssertFalse(AtriaBLEManager.shouldApplyR10MotionSnapshot(
            snapshotGeneration: 9,
            activeGeneration: 8
        ))
    }

    func testFreshR10SnapshotAdvancesBothCumulativeStepCounters() {
        let reconciled = AtriaBLEManager.monotonicStrapStepTotals(
            currentSteps: 123,
            currentRawSteps: 111,
            incomingSteps: 140,
            incomingRawSteps: 126
        )

        XCTAssertEqual(reconciled, .init(steps: 140, rawSteps: 126))
    }

    func testStepReconciliationClampsMalformedNegativeSnapshotWithoutLosingState() {
        let reconciled = AtriaBLEManager.monotonicStrapStepTotals(
            currentSteps: 123,
            currentRawSteps: 111,
            incomingSteps: -1,
            incomingRawSteps: -1
        )

        XCTAssertEqual(reconciled, .init(steps: 123, rawSteps: 111))
        XCTAssertEqual(AtriaBLEManager.monotonicStrapStepTotals(currentSteps: 0,
                                                                 currentRawSteps: 0,
                                                                 incomingSteps: -1,
                                                                 incomingRawSteps: -1),
                       .init(steps: 0, rawSteps: 0))
    }

    func testRecoveryHRVEligibilityUsesMeasurementTimeInsteadOfScreenOpenHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let morning = calendar.date(from: DateComponents(year: 2026,
                                                         month: 7,
                                                         day: 10,
                                                         hour: 7))!
        let afternoon = calendar.date(from: DateComponents(year: 2026,
                                                           month: 7,
                                                           day: 10,
                                                           hour: 17))!
        let daytimeMeasurement = calendar.date(from: DateComponents(year: 2026,
                                                                    month: 7,
                                                                    day: 10,
                                                                    hour: 14))!

        XCTAssertTrue(readyHRVSnapshot(measurementEnd: morning).isRecoveryEligible(
            on: afternoon,
            calendar: calendar
        ))
        XCTAssertFalse(readyHRVSnapshot(measurementEnd: daytimeMeasurement).isRecoveryEligible(
            on: afternoon,
            calendar: calendar
        ))
        XCTAssertFalse(readyHRVSnapshot(measurementEnd: morning).isRecoveryEligible(
            on: calendar.date(byAdding: .day, value: 1, to: afternoon)!,
            calendar: calendar
        ))
    }

    func testReadyHRVSnapshotRoundTripsAndExpiresFromRelaunchCache() throws {
        let measuredAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = readyHRVSnapshot(measurementEnd: measuredAt)
        let data = try XCTUnwrap(AtriaBLEManager.encodedReadyHRVSnapshot(snapshot))

        XCTAssertEqual(AtriaBLEManager.decodedReadyHRVSnapshot(
            data,
            now: measuredAt.addingTimeInterval(4 * 60 * 60)
        ), snapshot)
        XCTAssertNil(AtriaBLEManager.decodedReadyHRVSnapshot(
            data,
            now: measuredAt.addingTimeInterval(AtriaBLEManager.maxPersistedReadyHRVAge + 1)
        ))
    }

    func testLegacyCachedHRVSnapshotFailsReadinessWithoutAdjacencyEvidence() throws {
        let measuredAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = readyHRVSnapshot(measurementEnd: measuredAt)
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "successiveDifferenceCount")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(HRVSnapshot.self, from: legacyData)

        XCTAssertNil(decoded.successiveDifferenceCount)
        XCTAssertFalse(decoded.isReady)
        XCTAssertEqual(decoded.readinessReason, "differences")
        XCTAssertNil(AtriaBLEManager.decodedReadyHRVSnapshot(legacyData,
                                                             now: measuredAt.addingTimeInterval(60)))
    }

    func testProprietaryRealtimeRRRemainsResearchOnlyUntilLayoutValidation() {
        XCTAssertTrue(AtriaBLEManager.validatedProprietaryRealtimeRRLayoutVersions.isEmpty)
        XCTAssertFalse(AtriaBLEManager.shouldUseProprietaryRealtimeRRForMetrics(
            standardRecentlyActive: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldUseProprietaryRealtimeRRForMetrics(
            standardRecentlyActive: true
        ))
    }

    func testLiveStressRejectsPersistedOrOldReadyHRV() {
        let measuredAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = readyHRVSnapshot(measurementEnd: measuredAt)

        XCTAssertTrue(snapshot.isLiveStressEligible(on: measuredAt.addingTimeInterval(599)))
        XCTAssertFalse(snapshot.isLiveStressEligible(on: measuredAt.addingTimeInterval(601)))

        let persisted = HRVSnapshot(rmssd: snapshot.rmssd,
                                    sdnn: snapshot.sdnn,
                                    pnn50: snapshot.pnn50,
                                    lnRMSSD: snapshot.lnRMSSD,
                                    confidence: snapshot.confidence,
                                    kept: snapshot.kept,
                                    raw: snapshot.raw,
                                    rejectedOutOfRange: snapshot.rejectedOutOfRange,
                                    rejectedDeltaOver20Percent: snapshot.rejectedDeltaOver20Percent,
                                    rejectedHRMismatch: snapshot.rejectedHRMismatch,
                                    interpolated: snapshot.interpolated,
                                    successiveDifferenceCount: snapshot.successiveDifferenceCount,
                                    windowSeconds: snapshot.windowSeconds,
                                    maxRRGapSeconds: snapshot.maxRRGapSeconds,
                                    respiratoryRate: snapshot.respiratoryRate,
                                    measurementStart: snapshot.measurementStart,
                                    measurementEnd: snapshot.measurementEnd,
                                    analyzedAt: snapshot.analyzedAt,
                                    provenance: .unknown)
        XCTAssertFalse(persisted.isLiveStressEligible(on: measuredAt.addingTimeInterval(60)))
    }

    func testLinkValidOpcodeRemainsResearchOnlyWithoutProductionHeartbeat() throws {
        XCTAssertEqual(AtriaBLEManager.Cmd.linkValid, 0x01)
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("func startProtocolHeartbeat"))
        XCTAssertFalse(source.contains("sendCommand(Cmd.linkValid"))
    }

    func testLowBatteryPreservesHeartRateUntilMotionTransportIsSafe() {
        XCTAssertFalse(AtriaBLEManager.shouldArmHighFrequencyMotion(batteryLevel: 10,
                                                                   isCharging: false))
        XCTAssertFalse(AtriaBLEManager.shouldArmHighFrequencyMotion(batteryLevel: 25,
                                                                   isCharging: false))
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(batteryLevel: 26,
                                                                  isCharging: false))
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(batteryLevel: 10,
                                                                  isCharging: true))
        XCTAssertTrue(AtriaBLEManager.shouldArmHighFrequencyMotion(batteryLevel: -1,
                                                                  isCharging: false))
    }

    func testMotionChargingOverrideRequiresTypedAndBooleanAgreement() {
        XCTAssertFalse(AtriaBLEManager.hasCredibleChargingForMotion(
            isCharging: true,
            chargeStatus: .levelOnly
        ))
        XCTAssertFalse(AtriaBLEManager.hasCredibleChargingForMotion(
            isCharging: false,
            chargeStatus: .charging
        ))
        XCTAssertTrue(AtriaBLEManager.hasCredibleChargingForMotion(
            isCharging: true,
            chargeStatus: .charging
        ))
    }

    private func readyHRVSnapshot(measurementEnd: Date) -> HRVSnapshot {
        HRVSnapshot(rmssd: 54,
                    sdnn: 62,
                    pnn50: 18,
                    lnRMSSD: log(54),
                    confidence: 0.98,
                    kept: 300,
                    raw: 304,
                    rejectedOutOfRange: 2,
                    rejectedDeltaOver20Percent: 2,
                    rejectedHRMismatch: 0,
                    interpolated: 0,
                    successiveDifferenceCount: 298,
                    windowSeconds: 300,
                    maxRRGapSeconds: 1.2,
                    respiratoryRate: 14.2,
                    measurementStart: measurementEnd.addingTimeInterval(-300),
                    measurementEnd: measurementEnd,
                    analyzedAt: measurementEnd,
                    provenance: .localRRWindow)
    }

    func testStalledStreamRepairCooldownIsSharedAndBoundaryInclusive() {
        let lastRepair = Date(timeIntervalSince1970: 10_000)
        let cooldown = AtriaBLEManager.stalledStreamRepairCooldown

        XCTAssertFalse(AtriaBLEManager.shouldBeginStalledStreamRepair(
            lastRepairAt: lastRepair,
            now: lastRepair.addingTimeInterval(cooldown - 0.001)
        ))
        XCTAssertTrue(AtriaBLEManager.shouldBeginStalledStreamRepair(
            lastRepairAt: lastRepair,
            now: lastRepair.addingTimeInterval(cooldown)
        ))
        XCTAssertTrue(AtriaBLEManager.shouldBeginStalledStreamRepair(
            lastRepairAt: nil,
            now: lastRepair
        ))
    }

    func testReconnectBackoffRequiresRealCharacteristicData() {
        XCTAssertFalse(AtriaBLEManager.shouldResetRecoveryBackoff(for: .connected))
        XCTAssertTrue(AtriaBLEManager.shouldResetRecoveryBackoff(for: .characteristicValue))
    }

    func testNotifyEnableIsIdempotent() {
        XCTAssertFalse(AtriaBLEManager.shouldEnableNotifications(isNotifying: true))
        XCTAssertTrue(AtriaBLEManager.shouldEnableNotifications(isNotifying: false))
    }

    func testForegroundReturnPreservesHealthyHeartRateSubscription() {
        let now = Date(timeIntervalSince1970: 20_000)

        XCTAssertTrue(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: true,
            lastRawNotificationAt: now.addingTimeInterval(-2),
            now: now
        ))
        XCTAssertTrue(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: true,
            lastRawNotificationAt: now.addingTimeInterval(-12),
            now: now
        ))
    }

    func testForegroundReturnRepairsMissingOrStaleHeartRateSubscription() {
        let now = Date(timeIntervalSince1970: 20_000)

        XCTAssertFalse(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: false,
            lastRawNotificationAt: now.addingTimeInterval(-1),
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: true,
            lastRawNotificationAt: nil,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: true,
            lastRawNotificationAt: now.addingTimeInterval(-13),
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldPreserveHeartRateNotificationOnForeground(
            isNotifying: true,
            lastRawNotificationAt: now.addingTimeInterval(1),
            now: now
        ))
    }

    func testNormalWearHRVAnalysisRunsEveryFourHoursInForegroundAndBackground() {
        let fourHours: TimeInterval = 4 * 60 * 60
        XCTAssertEqual(AtriaBLEManager.hrvRefreshMinimumInterval(
            isRecording: false,
            foregroundInteractive: true
        ), fourHours)
        XCTAssertEqual(AtriaBLEManager.hrvRefreshMinimumInterval(
            isRecording: false,
            foregroundInteractive: false
        ), fourHours)
    }

    func testNormalWearHRVGateSurvivesWindowResetAndIsNotThermallyStretched() {
        let lastAnalysis = Date(timeIntervalSince1970: 20_000)
        let fourHours: TimeInterval = 4 * 60 * 60

        XCTAssertFalse(AtriaBLEManager.shouldRefreshHRVAnalysis(
            now: lastAnalysis.addingTimeInterval(fourHours - 1),
            lastAnalysisAt: lastAnalysis,
            isRecording: false,
            foregroundInteractive: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldRefreshHRVAnalysis(
            now: lastAnalysis.addingTimeInterval(fourHours),
            lastAnalysisAt: lastAnalysis,
            isRecording: false,
            foregroundInteractive: false
        ))
    }

    func testExplicitRecordingHRVAnalysisRemainsOnePointFiveSeconds() {
        let lastAnalysis = Date(timeIntervalSince1970: 30_000)

        XCTAssertEqual(AtriaBLEManager.hrvRefreshMinimumInterval(
            isRecording: true,
            foregroundInteractive: false
        ), 1.5)
        XCTAssertFalse(AtriaBLEManager.shouldRefreshHRVAnalysis(
            now: lastAnalysis.addingTimeInterval(1.499),
            lastAnalysisAt: lastAnalysis,
            isRecording: true,
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldRefreshHRVAnalysis(
            now: lastAnalysis.addingTimeInterval(1.5),
            lastAnalysisAt: lastAnalysis,
            isRecording: true,
            foregroundInteractive: true
        ))
    }

    func testNormalWearWaitsForFiveMinuteCleanWindowBeforeFirstAnalysis() {
        let now = Date(timeIntervalSince1970: 40_000)

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: now,
            lastReadyAnalysisAt: nil,
            lastAttemptAt: nil,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 299.999,
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: now,
            lastReadyAnalysisAt: nil,
            lastAttemptAt: nil,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            foregroundInteractive: true
        ))
    }

    func testLearningHRVFailureRetriesAfterNewCleanFiveMinuteWindow() {
        let attempt = Date(timeIntervalSince1970: 50_000)
        let retry: TimeInterval = 5 * 60

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: attempt.addingTimeInterval(retry - 0.001),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: attempt,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            latestRRSampleAt: attempt.addingTimeInterval(retry - 0.001),
            foregroundInteractive: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: attempt.addingTimeInterval(retry),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: attempt,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            latestRRSampleAt: attempt.addingTimeInterval(retry),
            foregroundInteractive: false
        ))
    }

    func testFailedAutomaticRefreshWithOlderReadySnapshotRetriesOnFreshEvidence() {
        let ready = Date(timeIntervalSince1970: 50_000)
        let failedAttempt = ready.addingTimeInterval(4 * 60 * 60)
        let retry: TimeInterval = 5 * 60

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: failedAttempt.addingTimeInterval(retry - 0.001),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: failedAttempt,
            isRecording: false,
            hasReadySnapshot: true,
            cleanWindowSeconds: 300,
            latestRRSampleAt: failedAttempt.addingTimeInterval(retry - 0.001),
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: failedAttempt.addingTimeInterval(retry),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: failedAttempt,
            isRecording: false,
            hasReadySnapshot: true,
            cleanWindowSeconds: 300,
            latestRRSampleAt: failedAttempt.addingTimeInterval(retry),
            foregroundInteractive: true
        ))
    }

    func testFailedNormalWearHRVDoesNotRetryWithoutNewRREvidence() {
        let attempt = Date(timeIntervalSince1970: 56_000)
        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: attempt.addingTimeInterval(30 * 60),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: attempt,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            latestRRSampleAt: attempt,
            foregroundInteractive: true
        ))
    }

    func testNormalWearAttemptMarkerPersistsAcrossRelaunch() throws {
        let suiteName = "AtriaBLERecoveryCadenceTests.hrv.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let attempt = Date(timeIntervalSince1970: 55_000)

        XCTAssertNil(AtriaBLEManager.readNormalWearHRVAnalysisAttemptDate(
            userDefaults: defaults
        ))
        AtriaBLEManager.persistNormalWearHRVAnalysisAttemptDate(
            attempt,
            userDefaults: defaults
        )
        XCTAssertEqual(AtriaBLEManager.readNormalWearHRVAnalysisAttemptDate(
            userDefaults: defaults
        ), attempt)
        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: attempt.addingTimeInterval(60),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: AtriaBLEManager.readNormalWearHRVAnalysisAttemptDate(
                userDefaults: defaults
            ),
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            foregroundInteractive: false
        ))
    }

    func testExplicitCaptureCadenceIgnoresPersistedNormalWearAttempt() {
        let captureAttempt = Date(timeIntervalSince1970: 58_000)

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: captureAttempt.addingTimeInterval(1.499),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: captureAttempt,
            isRecording: true,
            hasReadySnapshot: false,
            cleanWindowSeconds: 0,
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: captureAttempt.addingTimeInterval(1.5),
            lastReadyAnalysisAt: nil,
            lastAttemptAt: captureAttempt,
            isRecording: true,
            hasReadySnapshot: false,
            cleanWindowSeconds: 0,
            foregroundInteractive: true
        ))
    }

    func testReadyNormalWearHRVStillUsesFourHourGate() {
        let ready = Date(timeIntervalSince1970: 60_000)

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: ready.addingTimeInterval(4 * 60 * 60 - 1),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: ready,
            isRecording: false,
            hasReadySnapshot: true,
            cleanWindowSeconds: 300,
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: ready.addingTimeInterval(4 * 60 * 60),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: ready,
            isRecording: false,
            hasReadySnapshot: true,
            cleanWindowSeconds: 300,
            foregroundInteractive: true
        ))
    }

    func testReadyNormalWearGateSurvivesSnapshotAndAttemptReset() {
        let ready = Date(timeIntervalSince1970: 70_000)

        XCTAssertFalse(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: ready.addingTimeInterval(10 * 60),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: nil,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 10 * 60,
            foregroundInteractive: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: ready.addingTimeInterval(4 * 60 * 60),
            lastReadyAnalysisAt: ready,
            lastAttemptAt: nil,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 10 * 60,
            foregroundInteractive: true
        ))
    }

    func testNormalWearHRVCadenceRecoversFromClockRollback() {
        let now = Date(timeIntervalSince1970: 80_000)
        let futureMarker = now.addingTimeInterval(60 * 60)

        XCTAssertTrue(AtriaBLEManager.shouldRefreshHRVAnalysis(
            now: now,
            lastAnalysisAt: futureMarker,
            isRecording: false,
            foregroundInteractive: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: now,
            lastReadyAnalysisAt: futureMarker,
            lastAttemptAt: futureMarker,
            isRecording: false,
            hasReadySnapshot: true,
            cleanWindowSeconds: 300,
            foregroundInteractive: false
        ))
    }

    func testLearningHRVRetryRecoversFromClockRollback() {
        let now = Date(timeIntervalSince1970: 90_000)
        let futureAttempt = now.addingTimeInterval(60 * 60)

        XCTAssertTrue(AtriaBLEManager.shouldAttemptHRVAnalysis(
            now: now,
            lastReadyAnalysisAt: nil,
            lastAttemptAt: futureAttempt,
            isRecording: false,
            hasReadySnapshot: false,
            cleanWindowSeconds: 300,
            foregroundInteractive: true
        ))
    }

    func testProductionBatteryCallSiteKeepsExplicitReadResearchDisabled() throws {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let policyURL = managerURL
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaBLEBatteryTransportPolicy.swift")
        let managerSource = try String(contentsOf: managerURL, encoding: .utf8)
        let policySource = try String(contentsOf: policyURL, encoding: .utf8)

        XCTAssertTrue(policySource.contains("explicitReadResearchEnabled: Bool = false"))
        XCTAssertFalse(policySource.contains("explicitReadResearchEnabled: true"))
        XCTAssertFalse(managerSource.contains("readValue(for: batteryStatusCharacteristic)"))
        XCTAssertTrue(managerSource.contains("return [UUIDs.batteryLevel]"))
        XCTAssertFalse(managerSource.contains("detail=protected_r10_minimal_no_battery_gatt"))
        XCTAssertTrue(managerSource.contains("source=2A19_existing_subscription"))
    }

    func testOfflineRecoveryNeverSeizesAHealthyConnectedRealtimePipe() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(AtriaBLEManager.shouldProtectConnectedLinkForOfflineSync(
            connected: true,
            connectedAt: now.addingTimeInterval(-20),
            hasContact: false,
            acceptedSampleCount: 0,
            lastAcceptedHRAt: nil,
            now: now
        ))
        XCTAssertTrue(AtriaBLEManager.shouldProtectConnectedLinkForOfflineSync(
            connected: true,
            connectedAt: now.addingTimeInterval(-120),
            hasContact: true,
            acceptedSampleCount: 30,
            lastAcceptedHRAt: now.addingTimeInterval(-5),
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldProtectConnectedLinkForOfflineSync(
            connected: true,
            connectedAt: now.addingTimeInterval(-120),
            hasContact: false,
            acceptedSampleCount: 30,
            lastAcceptedHRAt: now.addingTimeInterval(-5),
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldProtectConnectedLinkForOfflineSync(
            connected: false,
            connectedAt: nil,
            hasContact: true,
            acceptedSampleCount: 30,
            lastAcceptedHRAt: now,
            now: now
        ))
    }


    // MARK: Workout motion ownership lease

    private func leaseManagerSource() throws -> String {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        return try String(contentsOf: managerURL, encoding: .utf8)
    }

    func testQualifiedOwnerWithSilentStreamAndActiveWorkoutActivatesOnce() {
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        let leaseStartedAt = Date(timeIntervalSince1970: 1_010)
        let now = leaseStartedAt.addingTimeInterval(30)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: connectedAt,
            stream5Confirmed: true,
            hrNotifying: true,
            lastFrameAt: nil,
            denseFrameCount: 1,
            lastActivationConnectionAt: nil,
            now: now
        ), .activate)
    }

    func testFreshDenseFrameDuringGraceSuppressesActivation() {
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        let leaseStartedAt = Date(timeIntervalSince1970: 1_010)
        let now = leaseStartedAt.addingTimeInterval(8)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: connectedAt,
            stream5Confirmed: true,
            hrNotifying: true,
            lastFrameAt: now.addingTimeInterval(-2),
            denseFrameCount: 15,
            lastActivationConnectionAt: nil,
            now: now
        ), .markLive)
    }

    func testRepeatLifecycleOnSameConnectionNeverResendsActivation() {
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        let leaseStartedAt = Date(timeIntervalSince1970: 1_010)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: connectedAt,
            stream5Confirmed: true,
            hrNotifying: true,
            lastFrameAt: nil,
            denseFrameCount: 1,
            lastActivationConnectionAt: connectedAt,
            now: leaseStartedAt.addingTimeInterval(600)
        ), .alreadyAttempted)
    }

    func testNewConnectionDuringActiveWorkoutEarnsOneNewBoundedAttempt() {
        let previousConnection = Date(timeIntervalSince1970: 1_000)
        let newConnection = Date(timeIntervalSince1970: 2_000)
        let leaseStartedAt = Date(timeIntervalSince1970: 1_010)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: newConnection,
            stream5Confirmed: true,
            hrNotifying: true,
            lastFrameAt: nil,
            denseFrameCount: 1,
            lastActivationConnectionAt: previousConnection,
            now: newConnection.addingTimeInterval(30)
        ), .activate)
    }

    func testStaleSparsePassiveFrameCannotMarkWorkoutMotionLive() {
        let newConnection = Date(timeIntervalSince1970: 2_000)
        let leaseStartedAt = Date(timeIntervalSince1970: 1_010)
        let now = newConnection.addingTimeInterval(30)
        // Frame captured before the current connection epoch: never live.
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: newConnection,
            stream5Confirmed: true,
            hrNotifying: true,
            lastFrameAt: newConnection.addingTimeInterval(-5),
            denseFrameCount: 1,
            lastActivationConnectionAt: nil,
            now: now
        ), .activate)
        // Old frame on the current connection past the fresh window: not live.
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: newConnection,
            stream5Confirmed: true,
            hrNotifying: true,
            lastFrameAt: newConnection.addingTimeInterval(2),
            denseFrameCount: 1,
            lastActivationConnectionAt: nil,
            now: newConnection.addingTimeInterval(120)
        ), .activate)
    }

    func testLeaseWaitsOutPassiveGraceBeforeAnyCommand() {
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        let leaseStartedAt = Date(timeIntervalSince1970: 1_010)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: connectedAt,
            stream5Confirmed: true,
            hrNotifying: true,
            lastFrameAt: nil,
            denseFrameCount: 1,
            lastActivationConnectionAt: nil,
            now: leaseStartedAt.addingTimeInterval(5)
        ), .awaitGrace)
    }

    func testLeaseRequiresLiveStandardHeartRateBeforeDenseBringUp() {
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        let leaseStartedAt = Date(timeIntervalSince1970: 1_010)
        let now = leaseStartedAt.addingTimeInterval(60)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: connectedAt,
            stream5Confirmed: true,
            hrNotifying: false,
            lastFrameAt: nil,
            denseFrameCount: 1,
            lastActivationConnectionAt: nil,
            now: now
        ), .awaitHeartRate)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: false,
            connectedAt: connectedAt,
            stream5Confirmed: true,
            hrNotifying: true,
            lastFrameAt: nil,
            denseFrameCount: 1,
            lastActivationConnectionAt: nil,
            now: now
        ), .none)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: nil,
            connected: true,
            connectedAt: connectedAt,
            stream5Confirmed: true,
            hrNotifying: true,
            lastFrameAt: nil,
            denseFrameCount: 1,
            lastActivationConnectionAt: nil,
            now: now
        ), .none)
    }

    func testUnconfirmedStreamEscalatesExactlyOncePerConnectionEpoch() {
        let leaseStartedAt = Date(timeIntervalSince1970: 900)
        let firstConnection = Date(timeIntervalSince1970: 1_000)
        let secondConnection = Date(timeIntervalSince1970: 2_000)

        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: firstConnection,
            stream5Confirmed: false,
            hrNotifying: true,
            lastFrameAt: nil,
            denseFrameCount: 0,
            lastActivationConnectionAt: nil,
            now: firstConnection.addingTimeInterval(1)
        ), .beginBringUp)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: firstConnection,
            stream5Confirmed: false,
            hrNotifying: true,
            lastFrameAt: nil,
            denseFrameCount: 0,
            lastActivationConnectionAt: firstConnection,
            now: firstConnection.addingTimeInterval(30)
        ), .alreadyAttempted)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: secondConnection,
            stream5Confirmed: false,
            hrNotifying: true,
            lastFrameAt: nil,
            denseFrameCount: 0,
            lastActivationConnectionAt: firstConnection,
            now: secondConnection.addingTimeInterval(1)
        ), .beginBringUp)
    }

    func testConnectedLeaseWithoutEpochIsHardInvariantFailure() {
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: Date(timeIntervalSince1970: 900),
            connected: true,
            connectedAt: nil,
            stream5Confirmed: false,
            hrNotifying: true,
            lastFrameAt: nil,
            denseFrameCount: 0,
            lastActivationConnectionAt: nil,
            now: Date(timeIntervalSince1970: 1_000)
        ), .missingConnectionEpoch)
    }

    func testProtectedPureHRFallbackKeepsLeaseOutOfBringUpPath() {
        let connectedAt = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: Date(timeIntervalSince1970: 1_000),
            connected: true,
            connectedAt: connectedAt,
            stream5Confirmed: false,
            hrNotifying: true,
            lastFrameAt: nil,
            denseFrameCount: 0,
            lastActivationConnectionAt: nil,
            protectedPureHRFallback: true,
            now: connectedAt.addingTimeInterval(60)
        ), .unavailablePureHRFallback)
    }

    func testConnectAndRestoreUseCommonHRFirstEpochCoordinator() throws {
        let source = try leaseManagerSource()
        let restore = try XCTUnwrap(source.range(of: "state_restore_connected"))
        let restoreBody = String(source[restore.lowerBound...].prefix(7_000))
        let restoreEpoch = try XCTUnwrap(restoreBody.range(of: "beginConnectionEpoch"))
        let restoreBringUp = try XCTUnwrap(restoreBody.range(of: "beginHRFirstDenseBringUpIfNeeded"))
        XCTAssertLessThan(restoreEpoch.lowerBound, restoreBringUp.lowerBound)

        let connect = try XCTUnwrap(source.range(of: "didConnect peripheral: CBPeripheral"))
        let connectBody = String(source[connect.lowerBound...].prefix(10_000))
        let connectEpoch = try XCTUnwrap(connectBody.range(of: "beginConnectionEpoch"))
        let connectBringUp = try XCTUnwrap(connectBody.range(of: "beginHRFirstDenseBringUpIfNeeded"))
        XCTAssertLessThan(connectEpoch.lowerBound, connectBringUp.lowerBound)

        let coordinator = try XCTUnwrap(source.range(of: "private func beginHRFirstDenseBringUpIfNeeded"))
        let orderedProfile = try XCTUnwrap(source.range(of: "private func beginProtectedR10BringUpForCurrentEpoch",
                                                        range: coordinator.upperBound..<source.endIndex))
        let hrFirstBody = String(source[coordinator.lowerBound..<orderedProfile.lowerBound])
        XCTAssertTrue(hrFirstBody.contains("heartRateCharacteristic?.isNotifying == true"))
        XCTAssertTrue(hrFirstBody.contains("heartRateService"))
        XCTAssertFalse(hrFirstBody.contains("setNotifyValue(false"))
    }

    func testForegroundKeepaliveObservesOnlyWhileHistoryOwnsTransport() {
        XCTAssertTrue(AtriaBLEManager.shouldKeepaliveObserveOnlyDuringHistory(
            offlineHistoricalSyncInProgress: true,
            historyOnlyProbeEnabled: false,
            historyTransportPhaseActive: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldKeepaliveObserveOnlyDuringHistory(
            offlineHistoricalSyncInProgress: false,
            historyOnlyProbeEnabled: true,
            historyTransportPhaseActive: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldKeepaliveObserveOnlyDuringHistory(
            offlineHistoricalSyncInProgress: false,
            historyOnlyProbeEnabled: false,
            historyTransportPhaseActive: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldKeepaliveObserveOnlyDuringHistory(
            offlineHistoricalSyncInProgress: false,
            historyOnlyProbeEnabled: false,
            historyTransportPhaseActive: false
        ))
    }

    func testHistoryOwnershipStartsAtIntentAndCoversEveryCutoverStage() {
        func active(
            explicitRequestPending: Bool = false,
            cutoverPending: Bool = false,
            connectionArmed: Bool = false,
            launchIntentPending: Bool = false
        ) -> Bool {
            AtriaBLEManager.historicalTransportOwnershipIsActive(
                offlineSyncInProgress: false,
                historyProbeEnabled: false,
                historyPhaseActive: false,
                readOnlyRequested: false,
                readOnlyActive: false,
                postHistoryLiveRestorationPending: false,
                explicitRequestPending: explicitRequestPending,
                freshOwnerCutoverPending: cutoverPending,
                freshOwnerConnectionArmed: connectionArmed,
                explicitLaunchIntentPending: launchIntentPending
            )
        }

        XCTAssertTrue(active(explicitRequestPending: true))
        XCTAssertTrue(active(cutoverPending: true))
        XCTAssertTrue(active(connectionArmed: true))
        XCTAssertTrue(active(launchIntentPending: true))
        XCTAssertFalse(active())
        XCTAssertFalse(AtriaBLEManager.shouldAllowAncillaryGATTRefresh(
            historyTransportOwnsLink: true
        ))
        XCTAssertTrue(AtriaBLEManager.shouldAllowAncillaryGATTRefresh(
            historyTransportOwnsLink: false
        ))
    }

    func testInterruptedHistoryOwnerCannotSuppressLiveReconnectDiscovery() {
        XCTAssertTrue(
            AtriaBLEManager.shouldReleaseInterruptedHistoryOwnerForLiveReconnect(
                offlineSyncInProgress: true,
                historyPhaseActive: true,
                disconnectObservedWithHistoryOwner: true,
                freshOwnerCutoverPending: false,
                freshOwnerAdmissionPending: false,
                freshOwnerConnectionArmed: false
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.shouldReleaseInterruptedHistoryOwnerForLiveReconnect(
                offlineSyncInProgress: false,
                historyPhaseActive: true,
                disconnectObservedWithHistoryOwner: true,
                freshOwnerCutoverPending: false,
                freshOwnerAdmissionPending: false,
                freshOwnerConnectionArmed: false
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldReleaseInterruptedHistoryOwnerForLiveReconnect(
                offlineSyncInProgress: true,
                historyPhaseActive: true,
                disconnectObservedWithHistoryOwner: true,
                freshOwnerCutoverPending: false,
                freshOwnerAdmissionPending: true,
                freshOwnerConnectionArmed: false
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldReleaseInterruptedHistoryOwnerForLiveReconnect(
                offlineSyncInProgress: true,
                historyPhaseActive: true,
                disconnectObservedWithHistoryOwner: false,
                freshOwnerCutoverPending: false,
                freshOwnerAdmissionPending: false,
                freshOwnerConnectionArmed: false
            )
        )
    }

    func testHistoryOwnedBatteryRefreshOnlySubscribesToStandardNotifications() {
        XCTAssertEqual(
            AtriaBLEManager.historyOwnedBatteryRefreshAction(
                canNotify: true,
                isNotifying: false
            ),
            .subscribe
        )
        XCTAssertEqual(
            AtriaBLEManager.historyOwnedBatteryRefreshAction(
                canNotify: true,
                isNotifying: true
            ),
            .awaitNotification
        )
        XCTAssertEqual(
            AtriaBLEManager.historyOwnedBatteryRefreshAction(
                canNotify: false,
                isNotifying: false
            ),
            .unavailable
        )
    }

    func testDidConnectFastLaneHonorsThreadSafeHistoryPhaseFence() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)"
        ))
        let end = try XCTUnwrap(source.range(
            of: "nonisolated func centralManager(_ central: CBCentralManager,\n                        didDisconnectPeripheral",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let phaseFence = try XCTUnwrap(body.range(
            of: "historyTransportPhaseFence.snapshot().isActive"
        ))
        let synchronousDiscovery = try XCTUnwrap(body.range(
            of: "beginSynchronousHeartRateDiscoveryFastLane("
        ))
        let historyResume = try XCTUnwrap(body.range(
            of: "resumeFreshHistoryOwnerConnectionIfNeeded"
        ))
        XCTAssertLessThan(phaseFence.lowerBound, synchronousDiscovery.lowerBound)
        XCTAssertLessThan(synchronousDiscovery.lowerBound, historyResume.lowerBound)
        XCTAssertTrue(body.contains("historyRecoveryActive: historyRecoveryActive"))

        let helperStart = try XCTUnwrap(source.range(
            of: "nonisolated private func beginSynchronousHeartRateDiscoveryFastLane("
        ))
        let helperEnd = try XCTUnwrap(source.range(
            of: "// MARK: - CBCentralManagerDelegate",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helperBody = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
        let helperPolicy = try XCTUnwrap(helperBody.range(
            of: "shouldSynchronouslyDiscoverHeartRateAfterConnect("
        ))
        let helperRadioCall = try XCTUnwrap(helperBody.range(
            of: "peripheral.discoverServices([Self.UUIDs.heartRateService])"
        ))
        XCTAssertLessThan(helperPolicy.lowerBound, helperRadioCall.lowerBound)
    }

    func testFreshHistoryCutoverClaimsReconnectThatWinsMainActorRace() throws {
        let source = try leaseManagerSource()
        let disconnectStart = try XCTUnwrap(source.range(
            of: "nonisolated func centralManager(_ central: CBCentralManager,\n                        didDisconnectPeripheral"
        ))
        let disconnectEnd = try XCTUnwrap(source.range(
            of: "didFailToConnect peripheral",
            range: disconnectStart.upperBound..<source.endIndex
        ))
        let body = String(source[disconnectStart.lowerBound..<disconnectEnd.lowerBound])
        let generationArm = try XCTUnwrap(body.range(
            of: "self.freshHistoryOwnerConnectionGeneration ="
        ))
        let connectedRace = try XCTUnwrap(body.range(
            of: "if peripheral.state == .connected",
            range: generationArm.upperBound..<body.endIndex
        ))
        let immediateClaim = try XCTUnwrap(body.range(
            of: "resumeFreshHistoryOwnerConnectionIfNeeded(",
            range: connectedRace.upperBound..<body.endIndex
        ))
        let disconnectedRace = try XCTUnwrap(body.range(
            of: "else if peripheral.state == .disconnected",
            range: immediateClaim.upperBound..<body.endIndex
        ))
        let standingConnect = try XCTUnwrap(body.range(
            of: "central.connect(peripheral, options: nil)",
            range: disconnectedRace.upperBound..<body.endIndex
        ))

        XCTAssertLessThan(generationArm.lowerBound, connectedRace.lowerBound)
        XCTAssertLessThan(connectedRace.lowerBound, immediateClaim.lowerBound)
        XCTAssertLessThan(immediateClaim.lowerBound, disconnectedRace.lowerBound)
        XCTAssertLessThan(disconnectedRace.lowerBound, standingConnect.lowerBound)
    }

    func testReadOnlyHistoryRejectsRestoredConnectedEpochBeforeDiscovery() throws {
        let source = try leaseManagerSource()
        let restoreStart = try XCTUnwrap(source.range(
            of: "nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict"
        ))
        let restoreEnd = try XCTUnwrap(source.range(
            of: "didDiscover peripheral",
            range: restoreStart.upperBound..<source.endIndex
        ))
        let restoreBody = String(source[restoreStart.lowerBound..<restoreEnd.lowerBound])
        let readOnlyCutover = try XCTUnwrap(restoreBody.range(
            of: "if self.readOnlyHistoryCaptureRequested"
        ))
        let normalEpoch = try XCTUnwrap(restoreBody.range(of: "self.beginConnectionEpoch"))
        XCTAssertLessThan(readOnlyCutover.lowerBound, normalEpoch.lowerBound)

        let cutoverBody = String(restoreBody[readOnlyCutover.lowerBound..<normalEpoch.lowerBound])
        XCTAssertTrue(cutoverBody.contains("readOnlyHistoryRestoreCutoverPending = true"))
        XCTAssertTrue(cutoverBody.contains("cancelPeripheralConnection"))
        XCTAssertTrue(cutoverBody.contains("request_preserved=1"))
        XCTAssertFalse(cutoverBody.contains("sendCommand("))
        XCTAssertFalse(cutoverBody.contains("readOnlyHistoryCaptureRequested = false"))

        let disconnectStart = try XCTUnwrap(source.range(of: "didDisconnectPeripheral peripheral"))
        let disconnectEnd = try XCTUnwrap(source.range(
            of: "didFailToConnect peripheral",
            range: disconnectStart.upperBound..<source.endIndex
        ))
        let disconnectBody = String(source[disconnectStart.lowerBound..<disconnectEnd.lowerBound])
        let pendingCutover = try XCTUnwrap(disconnectBody.range(
            of: "if self.readOnlyHistoryRestoreCutoverPending"
        ))
        let genericCancellation = try XCTUnwrap(disconnectBody.range(
            of: "cancelReadOnlyHistoryCaptureAfterDisconnect"
        ))
        XCTAssertLessThan(pendingCutover.lowerBound, genericCancellation.lowerBound)
        XCTAssertTrue(disconnectBody.contains(
            "startScan(reason: \"read_only_history_restored_cutover\")"
        ))

        let scanStart = try XCTUnwrap(source.range(of: "func startScan(reason:"))
        let scanEnd = try XCTUnwrap(source.range(
            of: "private func shouldUseBroadScanImmediately",
            range: scanStart.upperBound..<source.endIndex
        ))
        let scanBody = String(source[scanStart.lowerBound..<scanEnd.lowerBound])
        XCTAssertTrue(scanBody.contains("!isReadOnlyHistoryFreshCutoverScanReason(reason)"))
        XCTAssertTrue(source.contains(
            "reason.hasPrefix(\"read_only_history_restored_cutover\")"
        ))
    }

    func testStaleLinkCallbacksCannotClearCurrentEpoch() throws {
        let source = try leaseManagerSource()
        XCTAssertTrue(source.contains("status=stale_disconnect_ignored"))
        XCTAssertTrue(source.contains("status=stale_connect_failure_ignored"))
        XCTAssertTrue(source.contains("guard self.peripheral?.identifier == peripheral.identifier"))
    }

    func testProtectedWatchdogObserveBranchConsultsWorkoutLease() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func requestBoundedR10ActivationForSilentStream"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func evaluateR10Liveness",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let leaseCall = try XCTUnwrap(body.range(of: "evaluateWorkoutMotionLease"))
        let observedLog = try XCTUnwrap(body.range(
            of: "action=no_mid_link_cccd_or_epoch_reset"
        ))
        XCTAssertLessThan(leaseCall.lowerBound, observedLog.lowerBound)
    }

    func testWorkoutMotionActivationPairNeverTouchesLinkOrHeartRate() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func sendWorkoutMotionActivationPair"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func recordWorkoutMotionFrameIfNeeded",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("Cmd.sendR10R11Realtime"))
        XCTAssertTrue(body.contains("Cmd.toggleIMUMode"))
        XCTAssertTrue(body.contains("protectedR10CommandPacingDelay"))
        // Per-link bring-up may ENABLE a companion notification that a bonded
        // reconnect left inactive, but only behind the !isNotifying guard —
        // an established subscription is never toggled and never disabled.
        XCTAssertTrue(body.contains("!characteristic.isNotifying"))
        XCTAssertFalse(body.contains("setNotifyValue(false"))
        XCTAssertFalse(body.contains("cancelPeripheralConnection"))
        XCTAssertFalse(body.contains("discoverServices"))
        XCTAssertFalse(body.contains("heartRateCharacteristic?.isNotifying == false"))
    }

    func testLeaseReleaseCancelsActivationAndCommandTasks() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(of: "func endWorkoutMotionLease"))
        let end = try XCTUnwrap(source.range(
            of: "func restoreWorkoutMotionLeaseIfNeeded",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("workoutMotionActivationTask?.cancel()"))
        XCTAssertTrue(body.contains("workoutMotionCommandTask?.cancel()"))
        XCTAssertTrue(body.contains(
            "removeObject(forKey: WorkoutMotionDefaults.ownerStartedAt)"
        ))
    }

    func testConnectionAndRestorationPathsReadoptPersistedLease() throws {
        let source = try leaseManagerSource()
        let didConnect = try XCTUnwrap(source.range(of: "didConnect peripheral: CBPeripheral"))
        let didConnectTail = String(source[didConnect.upperBound...].prefix(8_000))
        XCTAssertTrue(didConnectTail.contains(
            "restoreWorkoutMotionLeaseIfNeeded(reason: \"did_connect\")"
        ))
        XCTAssertTrue(source.contains(
            "restoreWorkoutMotionLeaseIfNeeded(reason: \"state_restore_connected\")"
        ))
    }

    func testWorkoutMotionBackfillStatusNeverClaimsStrapHistory() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func recordWorkoutMotionGapClosureIfNeeded"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func setWorkoutMotionStatus",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("r10_range_unrecovered"))
        XCTAssertFalse(body.lowercased().contains("historical_archive_request"))
        XCTAssertFalse(body.contains("startHistoricalSync"))
    }


    func testSparsePassiveFramesNeverSuppressWorkoutActivation() {
        // Regression for the 2026-07-15 20:34 IST walk: sparse passive frames
        // (~1 per 15 s) kept single-frame freshness "live" and no activation
        // was ever issued (20/309 frames, 6.5% coverage). A fresh-but-sparse
        // frame must still activate.
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        let leaseStartedAt = Date(timeIntervalSince1970: 1_010)
        let now = leaseStartedAt.addingTimeInterval(25)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: connectedAt,
            stream5Confirmed: true,
            hrNotifying: true,
            lastFrameAt: now.addingTimeInterval(-3),
            denseFrameCount: 2,
            lastActivationConnectionAt: nil,
            now: now
        ), .activate)
        XCTAssertGreaterThanOrEqual(
            AtriaBLEManager.workoutMotionDenseFrameThreshold, 10,
            "Dense threshold must exceed any plausible sparse passive cadence"
        )
    }


    func testFrameOnCurrentConnectionProvesStream5WithoutConfirmedFlag() {
        // Regression for the 2026-07-15 gym workout: a reconnected qualified
        // owner never re-sets strapStream5NotifyConfirmed, so the flag alone
        // blocked every activation while sparse frames kept arriving.
        let connectedAt = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(AtriaBLEManager.workoutMotionStream5IsProven(
            notifyConfirmed: false,
            lastFrameAt: connectedAt.addingTimeInterval(30),
            connectedAt: connectedAt
        ))
        XCTAssertTrue(AtriaBLEManager.workoutMotionStream5IsProven(
            notifyConfirmed: true, lastFrameAt: nil, connectedAt: nil
        ))
        // A frame from a previous connection proves nothing about this link.
        XCTAssertFalse(AtriaBLEManager.workoutMotionStream5IsProven(
            notifyConfirmed: false,
            lastFrameAt: connectedAt.addingTimeInterval(-5),
            connectedAt: connectedAt
        ))
        XCTAssertFalse(AtriaBLEManager.workoutMotionStream5IsProven(
            notifyConfirmed: false, lastFrameAt: nil, connectedAt: connectedAt
        ))
    }


    func testLinkChurnDoesNotDeadlockActivationGrace() {
        // Regression for 2026-07-16 00:21 IST: the strap reconnected every
        // 15-25 s, so a per-connection grace never elapsed and activation
        // never fired. Once the workout itself is past grace, a brand-new
        // connection must activate immediately.
        let leaseStartedAt = Date(timeIntervalSince1970: 1_000)
        let freshConnection = Date(timeIntervalSince1970: 1_100)
        XCTAssertEqual(AtriaBLEManager.workoutMotionLeaseAction(
            leaseStartedAt: leaseStartedAt,
            connected: true,
            connectedAt: freshConnection,
            stream5Confirmed: true,
            hrNotifying: true,
            lastFrameAt: freshConnection.addingTimeInterval(2),
            denseFrameCount: 1,
            lastActivationConnectionAt: Date(timeIntervalSince1970: 1_050),
            now: freshConnection.addingTimeInterval(3)
        ), .activate)
    }


    func testLeaseBringUpFailureAndReleaseNeverRestoreFalseQualification() throws {
        let source = try leaseManagerSource()
        let fb = try XCTUnwrap(source.range(of: "private func persistProtectedR10CleanOwnerFallback"))
        let fbBody = String(source[fb.lowerBound...].prefix(1_800))
        XCTAssertTrue(fbBody.contains("if workoutMotionLeaseProfileArmed {"),
                      "an interrupted lease bring-up must clear its in-flight ownership")
        XCTAssertTrue(fbBody.contains("pure_hr_fallback_no_false_qualification"))
        XCTAssertFalse(fbBody.contains("ProtectedR10CleanOwnerState.qualified.rawValue"))
        let end = try XCTUnwrap(source.range(of: "func endWorkoutMotionLease"))
        let endBody = String(source[end.lowerBound...].prefix(2_200))
        XCTAssertTrue(endBody.contains("workoutMotionLeaseProfileArmed = false"))
        XCTAssertTrue(endBody.contains("lease_released_before_density_proof"))
        XCTAssertFalse(endBody.contains("ProtectedR10CleanOwnerState.qualified.rawValue"))
        XCTAssertTrue(source.contains("status=lease_full_bring_up_armed"))
    }


    func testCalibrationArmOwnsDenseMotionLikeAWorkout() throws {
        let source = try leaseManagerSource()
        let arm = try XCTUnwrap(source.range(of: "func armStepCalibrationCapture"))
        let armBody = String(source[arm.lowerBound...].prefix(2_400))
        XCTAssertTrue(armBody.contains("beginWorkoutMotionLease(startedAt: now, reason: \"step_calibration_arm\")"),
                      "the guided card must never depend on a hand-started parallel workout")
        XCTAssertTrue(armBody.contains("workoutMotionCalibrationHoldUntil = captureUntil"))
        let ready = try XCTUnwrap(source.range(of: "private func markStepCalibrationMotionStreamReady"))
        let readyBody = String(source[ready.lowerBound...].prefix(1_400))
        XCTAssertTrue(readyBody.contains("workoutMotionDenseFrameCount"),
                      "a single sparse frame must not mark the calibration stream ready (8% rest-stage capture, 2026-07-16)")
        let finish = try XCTUnwrap(source.range(of: "func finishStepCalibrationCapture"))
        let finishBody = String(source[finish.lowerBound...].prefix(1_600))
        XCTAssertTrue(finishBody.contains("workoutMotionCalibrationHoldUntil = nil"))
        XCTAssertTrue(finishBody.contains("endWorkoutMotionLease(reason: \"step_calibration_\\(reason)\")"))
    }

    // MARK: - All-day dense motion governor

    func testAllDayMotionGovernorAlwaysYieldsToWorkoutAndCalibration() {
        // The governor must be a strictly lowest-priority holder: with a
        // workout intent or calibration hold active it takes no action in any
        // combination of desire, connection, or lease state.
        for wantsHold in [true, false] {
            for leaseHeld in [true, false] {
                XCTAssertEqual(AtriaBLEManager.allDayMotionGovernorAction(
                    wantsHold: wantsHold, connected: true,
                    workoutIntentActive: true, calibrationHoldActive: false,
                    leaseHeld: leaseHeld
                ), .none)
                XCTAssertEqual(AtriaBLEManager.allDayMotionGovernorAction(
                    wantsHold: wantsHold, connected: true,
                    workoutIntentActive: false, calibrationHoldActive: true,
                    leaseHeld: leaseHeld
                ), .none)
            }
        }
    }

    func testAllDayMotionGovernorNeverPreemptsHistoricalTransportOwner() {
        for wantsHold in [true, false] {
            for leaseHeld in [true, false] {
                XCTAssertEqual(AtriaBLEManager.allDayMotionGovernorAction(
                    wantsHold: wantsHold,
                    connected: true,
                    workoutIntentActive: false,
                    calibrationHoldActive: false,
                    historyOwnerActive: true,
                    leaseHeld: leaseHeld
                ), .none)
            }
        }
    }

    func testAllDayMotionGovernorAcquiresAndReleases() {
        XCTAssertEqual(AtriaBLEManager.allDayMotionGovernorAction(
            wantsHold: true, connected: true,
            workoutIntentActive: false, calibrationHoldActive: false,
            leaseHeld: false
        ), .hold)
        // Never acquire without a live connection; never double-acquire.
        XCTAssertEqual(AtriaBLEManager.allDayMotionGovernorAction(
            wantsHold: true, connected: false,
            workoutIntentActive: false, calibrationHoldActive: false,
            leaseHeld: false
        ), .none)
        XCTAssertEqual(AtriaBLEManager.allDayMotionGovernorAction(
            wantsHold: true, connected: true,
            workoutIntentActive: false, calibrationHoldActive: false,
            leaseHeld: true
        ), .none)
        // Release its own hold when the desire ends (battery or disabled),
        // even while disconnected, so the lease never outlives the policy.
        XCTAssertEqual(AtriaBLEManager.allDayMotionGovernorAction(
            wantsHold: false, connected: false,
            workoutIntentActive: false, calibrationHoldActive: false,
            leaseHeld: true
        ), .release)
        XCTAssertEqual(AtriaBLEManager.allDayMotionGovernorAction(
            wantsHold: false, connected: true,
            workoutIntentActive: false, calibrationHoldActive: false,
            leaseHeld: false
        ), .none)
    }

    func testAllDayMotionWantsHoldUsesProvenBatteryPolicyWithResumeHysteresis() {
        // Same physically derived gate that protects HR continuity: a 13%
        // proof delivered frames but destabilized the link within seconds.
        XCTAssertFalse(AtriaBLEManager.allDayMotionWantsHold(
            enabled: true, batteryLevel: 20, isCharging: false, suspendedForBattery: false))
        XCTAssertTrue(AtriaBLEManager.allDayMotionWantsHold(
            enabled: true, batteryLevel: 26, isCharging: false, suspendedForBattery: false))
        XCTAssertFalse(AtriaBLEManager.allDayMotionWantsHold(
            enabled: false, batteryLevel: 90, isCharging: false, suspendedForBattery: false))
        // Unknown battery (-1) and credible charging follow the proven gate.
        XCTAssertTrue(AtriaBLEManager.allDayMotionWantsHold(
            enabled: true, batteryLevel: -1, isCharging: false, suspendedForBattery: false))
        XCTAssertTrue(AtriaBLEManager.allDayMotionWantsHold(
            enabled: true, batteryLevel: 10, isCharging: true, suspendedForBattery: false))
        // After a battery-pressure release the strap must recover past the
        // resume margin before re-arming, so the link cannot flap at 25%.
        XCTAssertFalse(AtriaBLEManager.allDayMotionWantsHold(
            enabled: true, batteryLevel: 27, isCharging: false, suspendedForBattery: true))
        XCTAssertTrue(AtriaBLEManager.allDayMotionWantsHold(
            enabled: true, batteryLevel: 31, isCharging: false, suspendedForBattery: true))
        XCTAssertTrue(AtriaBLEManager.allDayMotionWantsHold(
            enabled: true, batteryLevel: 27, isCharging: true, suspendedForBattery: true))
    }

    func testAllDayGovernorUsesTheProvenLeaseMachineryAndNeverWritesDirectly() throws {
        let source = try leaseManagerSource()
        let gov = try XCTUnwrap(source.range(of: "func evaluateAllDayMotionGovernor"))
        let govBody = String(source[gov.lowerBound...].prefix(2_600))
        XCTAssertTrue(govBody.contains("beginWorkoutMotionLease(startedAt: Date(), reason: \"all_day_\\(reason)\")"),
                      "the governor must acquire through the physically proven lease path, not a parallel one")
        XCTAssertTrue(govBody.contains("endWorkoutMotionLease("),
                      "the governor must release through the lease path so gaps are recorded honestly")
        XCTAssertFalse(govBody.contains("writeValue"),
                       "the governor itself must never write to the strap")
        // The lease lifecycle must recognize the governor as a legitimate
        // holder, or the 60 s stale-intent audit would release its own hold.
        let over = try XCTUnwrap(source.range(of: "private func workoutMotionLeaseIntentIsDefinitivelyOver"))
        let overBody = String(source[over.lowerBound...].prefix(1_400))
        XCTAssertTrue(overBody.contains("allDayMotionGovernorWantsHold()"))
        // Released leases hand ownership back to the governor so dense
        // capture resumes after every workout or calibration.
        let end = try XCTUnwrap(source.range(of: "func endWorkoutMotionLease"))
        let endBody = String(source[end.lowerBound...].prefix(3_000))
        XCTAssertTrue(endBody.contains("evaluateAllDayMotionGovernor(reason: \"post_lease_release\")"))
        // Both connection paths and the liveness audit evaluate the governor,
        // and the connect-path evaluation happens before the launch-style
        // bring-up check so a governor hold gets the full profile.
        XCTAssertTrue(source.contains("evaluateAllDayMotionGovernor(reason: \"did_connect\")"))
        XCTAssertTrue(source.contains("evaluateAllDayMotionGovernor(reason: \"state_restore_connected\")"))
        XCTAssertTrue(source.contains("evaluateAllDayMotionGovernor(reason: \"\\(reason)_all_day_audit\")"))
        let didConnect = try XCTUnwrap(source.range(of: "evaluateAllDayMotionGovernor(reason: \"did_connect\")"))
        let afterGovernor = String(source[didConnect.upperBound...].prefix(1_200))
        XCTAssertTrue(afterGovernor.contains("workoutMotionOwnerStartedAt != nil"),
                      "governor acquisition must precede the per-connection bring-up gate")
    }


    // MARK: Background link audit (BGTask recovery window)

    func testBackgroundTaskAuditsLinkBeforeDurableFlush() throws {
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaApp.swift")
        let source = try String(contentsOf: appURL, encoding: .utf8)
        let handler = try XCTUnwrap(source.range(
            of: "private static func handleBackgroundTask"
        ))
        let body = String(source[handler.lowerBound...].prefix(3_000))
        let audit = try XCTUnwrap(body.range(of: "performBackgroundLinkAudit(reason: reason)"))
        let flush = try XCTUnwrap(body.range(of: "flushActiveSessionJournal(reason: reason)"))
        XCTAssertLessThan(audit.lowerBound, flush.lowerBound,
                          "The BG window must audit the link before spending its budget on flushes")
    }

    func testBackgroundProcessingUsesTheSameAuditedConnectedHandoffGate() throws {
        let manager = try leaseManagerSource()
        let awaitStart = try XCTUnwrap(manager.range(
            of: "func requestOfflineHistoricalSyncAwaitingCompletion"
        ))
        let awaitEnd = try XCTUnwrap(manager.range(
            of: "private func recordMotionHandshakeEvidence",
            range: awaitStart.upperBound..<manager.endIndex
        ))
        let awaitBody = String(manager[awaitStart.lowerBound..<awaitEnd.lowerBound])
        XCTAssertTrue(awaitBody.contains("automaticConnectedHistoricalHandoffIsEligible"))
        XCTAssertTrue(awaitBody.contains("allowConnectedAutomaticHandoff: automaticConnectedHandoff"))
        XCTAssertTrue(awaitBody.contains("force: force || automaticConnectedHandoff"))

        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaApp.swift")
        let app = try String(contentsOf: appURL, encoding: .utf8)
        let handler = try XCTUnwrap(app.range(of: "private static func handleBackgroundTask"))
        let body = String(app[handler.lowerBound...].prefix(5_000))
        XCTAssertTrue(body.contains("admitAutomaticConnectedHandoffIfEligible: true"),
                      "BGProcessing must not depend on a foreground-only timer to authorize exact-gap recovery")
    }

    func testSceneBackgroundUsesTheSameAuditedConnectedHandoffGate() throws {
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaApp.swift")
        let app = try String(contentsOf: appURL, encoding: .utf8)
        let start = try XCTUnwrap(app.range(of: "private func performSceneBackgroundMaintenance"))
        let end = try XCTUnwrap(app.range(of: "private func scheduleBackgroundMaintenance",
                                          range: start.upperBound..<app.endIndex))
        let body = String(app[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("admitAutomaticConnectedHandoffIfEligible: true"),
                      "scene backgrounding must use the audited exact-gap handoff before deferring to a later BGProcessing window")
    }

    func testAutomaticConnectedHistoryHandoffUsesEvidenceGatesAtAnyHour() throws {
        let manager = try leaseManagerSource()
        let start = try XCTUnwrap(manager.range(
            of: "private func automaticConnectedHistoricalHandoffIsEligible"
        ))
        let end = try XCTUnwrap(manager.range(
            of: "let defaults = UserDefaults.standard",
            range: start.upperBound..<manager.endIndex
        ))
        let admissionPrefix = String(manager[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(admissionPrefix.contains("isRRProtectedSleepWindow"))
    }

    func testBackgroundLinkAuditOnlyRoutesThroughAuditedPolicies() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(of: "func performBackgroundLinkAudit"))
        let end = try XCTUnwrap(source.range(
            of: "private func evaluateR10Liveness",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("evaluateR10Liveness"))
        XCTAssertTrue(body.contains("performHRContinuityWatchdogAction"))
        XCTAssertTrue(body.contains("immediateConnectedRebuild: true"),
                      "A BGTask must not defer a zombie-link rebuild into a Task that iOS can suspend")
        XCTAssertFalse(body.contains("setNotifyValue"))
        XCTAssertFalse(body.contains("cancelPeripheralConnection"))
        XCTAssertFalse(body.contains("writeValue"))
        XCTAssertFalse(body.contains("connect("))
    }

    func testBackgroundZombieLinkRebuildCancelsInsideGrantedExecutionWindow() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func forceHardReconnectForPacketStall"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func reconnectKnownPeripheralImmediately",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let immediate = try XCTUnwrap(body.range(
            of: "let cancelImmediately = immediateConnectedRebuild"
        ))
        XCTAssertTrue(body.contains("if !cancelImmediately,"),
                      "A previously deferred watchdog request must not cooldown-block the BGTask's immediate repair")
        let cancel = try XCTUnwrap(body.range(
            of: "cancelPeripheralConnection(",
            range: immediate.upperBound..<body.endIndex
        ))
        let deferred = try XCTUnwrap(body.range(
            of: "requestFreshScanReconnect(",
            range: cancel.upperBound..<body.endIndex
        ))
        XCTAssertLessThan(cancel.lowerBound, deferred.lowerBound,
                          "The background branch must cancel before the ordinary deferred backoff path")
        XCTAssertTrue(body.contains("forceFreshScanAfterDisconnect = false"),
                      "didDisconnect must reconnect the known peripheral instead of entering an open scan")
        XCTAssertTrue(body.contains("pendingRecoveryReconnectReason = nil"))
        XCTAssertTrue(body.contains("freshScanFallbackTask?.cancel()"))
    }

    func testDiagnosticClockParserBindsWHOOPRequestSequenceEcho() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func logClockCommandResponse"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func maybeSendHistorySelectorSweep",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("let responseSequence = payload[1]"))
        XCTAssertTrue(body.contains("let requestSequenceEcho = payload[3]"))
        XCTAssertTrue(body.contains(
            "pendingHistoryClockCommandSequence == requestSequenceEcho"
        ))
        XCTAssertTrue(body.contains(
            "acceptedHistoryClockResponseSequence = requestSequenceEcho"
        ))
        XCTAssertFalse(body.contains(
            "pendingHistoryClockCommandSequence == responseSequence"
        ))
    }

    func testProductionBootstrapUsesMatchedRangeClockAndNoGetClock() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func beginProductionHistoricalAdmissionAttempt"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func sendHistoryDataRange",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains(
            "sendCommand(Cmd.getDataRange, [0x00], mode: .withResponse)"
        ))
        XCTAssertTrue(body.contains("expected.payload == [0x00]"))
        XCTAssertTrue(body.contains(
            "observed.requestSequenceEcho == expected.sequence"
        ))
        XCTAssertTrue(body.contains("validatedClockAuthority"))
        XCTAssertTrue(body.contains("source=2200"))
        XCTAssertTrue(body.contains("performProductionHistoryReadPreflight"))
        XCTAssertTrue(body.contains("sendCommand(Cmd.getClock"),
                      "the optional read-only transport preflight remains structurally isolated")
        XCTAssertFalse(AtriaBLEManager.shouldUseProductionHistoryReadPreflight(
            explicitRequest: true,
            force: true,
            reason: "production"
        ), "production policy must keep the optional GET_CLOCK preflight disabled")
        XCTAssertFalse(body.contains("sendCommand(Cmd.setClock"))
        XCTAssertFalse(body.contains("Cmd.abortHistoricalTransmits"))
        XCTAssertFalse(body.contains("Cmd.exitHighFreqSync"))
    }

    func testStandardGattHeartbeatEnforcesHistoryIdleTimeoutIndependently() throws {
        let source = try leaseManagerSource()
        let callbackStart = try XCTUnwrap(source.range(
            of: "nonisolated func peripheral(_ peripheral: CBPeripheral,\n                    didUpdateValueFor characteristic: CBCharacteristic"
        ))
        let callback = String(source[callbackStart.lowerBound..<source.endIndex])

        XCTAssertTrue(callback.contains(
            "enforceHistoricalIdleTimeoutFromGattHeartbeatIfNeeded"
        ))
        XCTAssertTrue(source.contains(
            "reason: \"history_idle_timeout_gatt_heartbeat_transport_reset\""
        ))
        let start = try XCTUnwrap(source.range(
            of: "private func enforceHistoricalIdleTimeoutFromGattHeartbeatIfNeeded("
        ))
        let end = try XCTUnwrap(source.range(
            of: "/// A short whole-drain deadline",
            range: start.upperBound..<source.endIndex
        ))
        let watchdog = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(watchdog.contains("pendingHistoricalTransportEvents.isEmpty"),
                       "a queue stalled beyond the full idle deadline must not pin history ownership")
        XCTAssertFalse(watchdog.contains("pendingHistoryEndACK == nil"),
                       "an ACK boundary that never receives a callback must fail closed at the idle deadline")
        XCTAssertFalse(watchdog.contains("!historyACKGate.requiresHistoryCallbackDeferral"),
                       "a missing ACK callback must not suppress the independent liveness reset")
        XCTAssertFalse(watchdog.contains("!historicalAdmissionBatchInFlight"),
                       "a hung local persistence batch must not retain the BLE owner indefinitely")
    }

    func testPostHistoryStuckSavedReconnectGetsOneBoundedReissue() throws {
        let source = try leaseManagerSource()
        XCTAssertTrue(source.contains(
            "historyFailureReconnectReissuePending = true"
        ))
        XCTAssertTrue(source.contains(
            "action=cancel_stuck_post_history_connect_once"
        ))
        XCTAssertTrue(source.contains(
            "historyFailureReconnectReissuePending = false"
        ))
        XCTAssertTrue(source.contains(
            "reason: \"post_history_stuck_connect_reissue\""
        ))
    }

    func testHistoricalFramesRemainQueuedAcrossDurableBatchBoundary() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func drainNextHistoricalTransportEventBurst()"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func processAdmittedHistoricalFrame",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("guard historyDrain.canReceiveFrame"))
        XCTAssertTrue(body.contains("action=retain_until_ack"))
        XCTAssertTrue(source.contains(
            "completeHistoricalACKAcceptance"
        ))
        XCTAssertTrue(source.contains(
            "scheduleHistoricalTransportEventDrain()"
        ))
    }

    func testFreshOwnerReconnectRaceCannotReenterConnectedDeferralLoop() throws {
        let source = try leaseManagerSource()
        XCTAssertTrue(source.contains(
            "freshOwnerCutoverCompleted: Bool = false"
        ))
        XCTAssertTrue(source.contains(
            "automaticConnectedHandoffAllowed: allowConnectedAutomaticHandoff\n                || freshOwnerCutoverCompleted"
        ))
        XCTAssertTrue(source.contains(
            "if !freshOwnerCutoverCompleted,\n           Self.shouldUseFreshHistoryOwnerCutover"
        ))
        XCTAssertTrue(source.contains(
            "freshOwnerCutoverCompleted: true,\n                        explicitResearchRequest: pending.explicitRequest"
        ))
        XCTAssertTrue(source.contains(
            "freshHistoryOwnerAdmissionPending = true"
        ))
        XCTAssertTrue(source.contains(
            "status=fresh_owner_admitted_on_did_connect"
        ))
        XCTAssertTrue(source.contains(
            "if !freshOwnerCutoverCompleted,\n           Self.shouldDeferAutomaticOfflineSyncForConnectedLink"
        ))
    }

    func testR10StepLeaseGrantsOnlyForFreshManualWorkoutHR() {
        let connection = Date(timeIntervalSince1970: 1_000)
        let started = Date(timeIntervalSince1970: 1_005)
        XCTAssertEqual(AtriaR10StepLeasePolicy.decision(
            manualWorkoutActive: true,
            historyOwnsTransport: false,
            connected: true,
            connectionStartedAt: connection,
            leaseConnectionStartedAt: nil,
            leaseStartedAt: started,
            lastAcceptedHeartRateAt: Date(timeIntervalSince1970: 1_010),
            now: Date(timeIntervalSince1970: 1_015)
        ), .grant)
        XCTAssertEqual(AtriaR10StepLeasePolicy.decision(
            manualWorkoutActive: true,
            historyOwnsTransport: false,
            connected: true,
            connectionStartedAt: connection,
            leaseConnectionStartedAt: connection,
            leaseStartedAt: started,
            lastAcceptedHeartRateAt: Date(timeIntervalSince1970: 1_010),
            now: Date(timeIntervalSince1970: 1_015)
        ), .keep)
    }

    func testR10StepLeaseNeverCompetesWithHistoryOrHR() {
        let connection = Date(timeIntervalSince1970: 1_000)
        let started = Date(timeIntervalSince1970: 1_005)
        let freshHR = Date(timeIntervalSince1970: 1_010)
        XCTAssertEqual(AtriaR10StepLeasePolicy.decision(
            manualWorkoutActive: true, historyOwnsTransport: true,
            connected: true, connectionStartedAt: connection,
            leaseConnectionStartedAt: connection, leaseStartedAt: started,
            lastAcceptedHeartRateAt: freshHR, now: Date(timeIntervalSince1970: 1_015)
        ), .revoke(.historyOwnsTransport))
        XCTAssertEqual(AtriaR10StepLeasePolicy.decision(
            manualWorkoutActive: true, historyOwnsTransport: false,
            connected: true, connectionStartedAt: connection,
            leaseConnectionStartedAt: connection, leaseStartedAt: started,
            lastAcceptedHeartRateAt: freshHR, now: Date(timeIntervalSince1970: 1_026)
        ), .revoke(.heartRateNotFresh))
    }

    func testR10StepLeaseRevokesAcrossReconnectAndAtBound() {
        let oldConnection = Date(timeIntervalSince1970: 1_000)
        let newConnection = Date(timeIntervalSince1970: 1_100)
        let started = Date(timeIntervalSince1970: 1_005)
        XCTAssertEqual(AtriaR10StepLeasePolicy.decision(
            manualWorkoutActive: true, historyOwnsTransport: false,
            connected: true, connectionStartedAt: newConnection,
            leaseConnectionStartedAt: oldConnection, leaseStartedAt: started,
            lastAcceptedHeartRateAt: newConnection, now: Date(timeIntervalSince1970: 1_105)
        ), .revoke(.connectionChanged))
        XCTAssertEqual(AtriaR10StepLeasePolicy.decision(
            manualWorkoutActive: true, historyOwnsTransport: false,
            connected: true, connectionStartedAt: oldConnection,
            leaseConnectionStartedAt: oldConnection, leaseStartedAt: started,
            lastAcceptedHeartRateAt: Date(timeIntervalSince1970: 11_800),
            now: Date(timeIntervalSince1970: 11_806)
        ), .revoke(.expired))
    }

    func testUserApprovedClockRepairIsExplicitAndSingleFlight() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func performUserApprovedHistoryClockSync"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func performProductionHistoryReadPreflight",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("guard historyClockSyncEnabled else { return .confirmed }"))
        XCTAssertTrue(body.contains("command: Cmd.setClock"))
        XCTAssertTrue(body.contains("sendHistoryCommandAwaitingWriteConfirmation"))
        XCTAssertTrue(body.contains("payload = withUnsafeBytes(of: unixSeconds.littleEndian)"))
        XCTAssertTrue(body.contains("+ [0, 0, 0, 0]"))
        XCTAssertTrue(body.contains("Task.sleep(for: .milliseconds(800))"))
        XCTAssertTrue(body.contains("atria.offlineSync.clockRepairStatus.v1"),
                      "the physical repair must leave a durable, inspectable write outcome")
        XCTAssertTrue(body.contains("historyClockSyncEnabled = false"),
                      "an explicit approval is single-use and must not leak into automatic recovery")
        XCTAssertFalse(body.contains("Cmd.forceTrim"))
        XCTAssertFalse(body.contains("Cmd.abortHistoricalTransmits"))
        XCTAssertFalse(body.contains("Cmd.reboot"))
    }

    func testClockRepairApprovalSurvivesHistoryGenerationSetup() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(of: "let preserveUserApprovedHistoryClockRepair"))
        let end = try XCTUnwrap(source.range(of: "probeCommandMode = .withResponse",
                                              range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("preserveUserApprovedHistoryClockRepair = historyClockSyncEnabled"))
        XCTAssertTrue(body.contains("historyClockSyncEnabled = preserveDebugHistoryRangeProbe"))
        XCTAssertTrue(body.contains("|| preserveUserApprovedHistoryClockRepair"),
                      "generation setup must not erase the explicit clock-repair approval")
    }

    func testHistoryServeWaitDoesNotCancelADeepBacklogAtThirtySeconds() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(of: "let initialServeWaitSeconds: TimeInterval = 75"))
        let end = try XCTUnwrap(source.range(of: "guard acceptedHistoryStartSequence != nil else",
                                              range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("Date().addingTimeInterval(\n                            initialServeWaitSeconds\n                        )"))
        XCTAssertFalse(body.contains("sendHistoryCommand"),
                       "waiting for a served page must not issue a second command")
        XCTAssertFalse(body.contains("Cmd.abortHistoricalTransmits"))
    }

    func testExplicitHistoryRepairUsesCaptureProvenMinimalServedProfile() throws {
        let source = try leaseManagerSource()
        XCTAssertTrue(source.contains("22/00, a 2.1-second settle, then 16/00"))
        XCTAssertTrue(source.contains("reason=explicit_minimal_served_profile action=preserve_2200_settle_1600"))
        XCTAssertFalse(source.contains("explicit_profile_bond_confirmed"))
        XCTAssertFalse(source.contains("listeners=03,04,05 action=allow_1600"))
        XCTAssertFalse(source.contains("command: Cmd.getBatteryLevel,\n                    payload: [0x00],\n                    generation: syncGeneration"))
        XCTAssertFalse(source.contains("command: Cmd.forceTrim"))
        XCTAssertFalse(source.contains("command: Cmd.abortHistoricalTransmits"))
        XCTAssertFalse(source.contains("command: Cmd.reboot"))
    }

    func testFreshHistoryOwnerReconnectRetainsExplicitListenerProfile() throws {
        let source = try leaseManagerSource()
        let start = try XCTUnwrap(source.range(of:
            "private func resumeFreshHistoryOwnerConnectionIfNeeded"
        ))
        let end = try XCTUnwrap(source.range(of: "private func", options: [],
                                              range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains(
            "let usesExplicitHistoryProfile = historyTransportPhaseFence.snapshot()\n            .usesExplicitHistoryProfile"
        ))
        XCTAssertTrue(body.contains(
            "usesExplicitHistoryProfile: usesExplicitHistoryProfile"
        ))
    }

}
