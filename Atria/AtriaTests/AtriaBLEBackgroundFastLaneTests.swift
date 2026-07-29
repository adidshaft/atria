import XCTest
import CoreBluetooth
@testable import Atria

final class AtriaBLEBackgroundFastLaneTests: XCTestCase {
    func testCallbackPolicyPublishesOneCoherentDiscoverySnapshot() {
        let state = AtriaBLECallbackPolicyState(standardHROnly: true)
        XCTAssertEqual(
            state.snapshot(),
            .init(
                standardHROnly: true,
                onboardingPairingPreflight: false,
                historySkipsDataRange: false,
                protectedProfileIsEmpty: true,
                protectedStandardDiscoveryStarted: false
            )
        )

        state.update {
            $0.standardHROnly = false
            $0.onboardingPairingPreflight = true
            $0.historySkipsDataRange = true
            $0.protectedProfileIsEmpty = false
            $0.protectedStandardDiscoveryStarted = true
        }

        XCTAssertEqual(
            state.snapshot(),
            .init(
                standardHROnly: false,
                onboardingPairingPreflight: true,
                historySkipsDataRange: true,
                protectedProfileIsEmpty: false,
                protectedStandardDiscoveryStarted: true
            )
        )
    }

    func testRestorationSelectsSavedPeripheralInsteadOfFirstEntry() {
        let stale = UUID()
        let saved = UUID()

        XCTAssertEqual(
            AtriaBLEManager.canonicalRestoredPeripheralIndex(
                identifiers: [stale, saved],
                states: [.connected, .disconnected],
                savedPeripheralIdentifier: saved
            ),
            1
        )
        XCTAssertNil(
            AtriaBLEManager.canonicalRestoredPeripheralIndex(
                identifiers: [stale, saved],
                states: [.connected, .connected],
                savedPeripheralIdentifier: UUID()
            )
        )
        XCTAssertEqual(
            AtriaBLEManager.canonicalRestoredPeripheralIndex(
                identifiers: [saved],
                states: [.connected],
                savedPeripheralIdentifier: nil
            ),
            0
        )
        XCTAssertNil(
            AtriaBLEManager.canonicalRestoredPeripheralIndex(
                identifiers: [stale, saved],
                states: [.connected, .connected],
                savedPeripheralIdentifier: nil
            )
        )
        XCTAssertEqual(
            AtriaBLEManager.canonicalRestoredPeripheralIndex(
                identifiers: [saved, saved],
                states: [.disconnected, .connected],
                savedPeripheralIdentifier: saved
            ),
            1,
            "an already-connected restored twin must own discovery because it will not emit didConnect"
        )
        XCTAssertEqual(
            AtriaBLEManager.canonicalRestoredPeripheralIndex(
                identifiers: [saved, saved, saved],
                states: [.disconnected, .connecting, .disconnecting],
                savedPeripheralIdentifier: saved
            ),
            1
        )
        XCTAssertNil(
            AtriaBLEManager.canonicalRestoredPeripheralIndex(
                identifiers: [saved],
                states: [],
                savedPeripheralIdentifier: saved
            ),
            "mismatched restoration facts must fail closed"
        )
    }

    func testFailedSavedConnectInstallsStandingReconnectBeforeMainActorBookkeeping() {
        XCTAssertTrue(
            AtriaBLEManager.shouldSynchronouslyReconnectAfterFailedConnect(
                disposition: .reconnectRealtime,
                failedPeripheralIsSaved: true,
                peripheralIsDisconnected: true
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldSynchronouslyReconnectAfterFailedConnect(
                disposition: .suppressHistoryOwner,
                failedPeripheralIsSaved: true,
                peripheralIsDisconnected: true
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.acceptsFailedConnectCallback(
                trackedPeripheralIsFailedInstance: false,
                trackedPeripheralIsAbsent: true,
                synchronousReconnectIssued: true,
                callbackEpochIsCurrent: true
            ),
            "the callback must survive the pre-MainActor bookkeeping window"
        )
        XCTAssertFalse(
            AtriaBLEManager.acceptsFailedConnectCallback(
                trackedPeripheralIsFailedInstance: false,
                trackedPeripheralIsAbsent: true,
                synchronousReconnectIssued: false,
                callbackEpochIsCurrent: true
            ),
            "a stale object must not be admitted merely because it shares the current strap UUID"
        )
        XCTAssertTrue(
            AtriaBLEManager.acceptsFailedConnectCallback(
                trackedPeripheralIsFailedInstance: true,
                trackedPeripheralIsAbsent: false,
                synchronousReconnectIssued: false,
                callbackEpochIsCurrent: true
            ),
            "the currently tracked failed object remains a terminal callback"
        )
        XCTAssertFalse(
            AtriaBLEManager.acceptsFailedConnectCallback(
                trackedPeripheralIsFailedInstance: false,
                trackedPeripheralIsAbsent: false,
                synchronousReconnectIssued: true,
                callbackEpochIsCurrent: true
            ),
            "a synchronous retry must not overwrite a distinct tracked owner"
        )
        XCTAssertFalse(
            AtriaBLEManager.acceptsFailedConnectCallback(
                trackedPeripheralIsFailedInstance: true,
                trackedPeripheralIsAbsent: false,
                synchronousReconnectIssued: true,
                callbackEpochIsCurrent: false
            ),
            "a newer connected epoch must supersede queued failure bookkeeping"
        )
    }

    func testDisconnectFollowupRequiresExactObjectAndUnchangedEpoch() {
        XCTAssertTrue(
            AtriaBLEManager.acceptsDisconnectCallbackFollowup(
                trackedPeripheralIsDisconnectedInstance: true,
                terminalEpochIsCurrent: true
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.acceptsDisconnectCallbackFollowup(
                trackedPeripheralIsDisconnectedInstance: false,
                terminalEpochIsCurrent: true
            ),
            "a same-UUID object-distinct owner must not be reset"
        )
        XCTAssertFalse(
            AtriaBLEManager.acceptsDisconnectCallbackFollowup(
                trackedPeripheralIsDisconnectedInstance: true,
                terminalEpochIsCurrent: false
            ),
            "a newer didConnect epoch supersedes queued terminal work"
        )
    }

    func testUnexpectedDisconnectReconnectsButEveryAppOwnedCancelIsConsumedOnce() {
        let fence = AtriaBLEManager.BackgroundReconnectFence(markerMaximumAge: 30)
        let peripheralID = UUID()
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(fence.consumeDisposition(
            peripheralID: peripheralID,
            continuousCaptureWanted: true,
            historyTransportActive: false,
            diagnosticActive: false,
            now: now
        ), .reconnectRealtime)

        fence.markAppOwnedCancellation(peripheralID: peripheralID, at: now)
        XCTAssertEqual(fence.consumeDisposition(
            peripheralID: peripheralID,
            continuousCaptureWanted: true,
            historyTransportActive: false,
            diagnosticActive: false,
            now: now
        ), .suppressAppOwnedCancellation)
        XCTAssertEqual(fence.consumeDisposition(
            peripheralID: peripheralID,
            continuousCaptureWanted: true,
            historyTransportActive: false,
            diagnosticActive: false,
            now: now
        ), .reconnectRealtime)
    }

    func testHistoryDiagnosticAndInactiveCaptureCannotUseRealtimeFastLane() {
        let fence = AtriaBLEManager.BackgroundReconnectFence()
        let peripheralID = UUID()
        let now = Date(timeIntervalSince1970: 20_000)

        XCTAssertEqual(fence.consumeDisposition(
            peripheralID: peripheralID,
            continuousCaptureWanted: true,
            historyTransportActive: true,
            diagnosticActive: false,
            now: now
        ), .suppressHistoryOwner)
        XCTAssertEqual(fence.consumeDisposition(
            peripheralID: peripheralID,
            continuousCaptureWanted: true,
            historyTransportActive: false,
            diagnosticActive: true,
            now: now
        ), .suppressDiagnostic)
        XCTAssertEqual(fence.consumeDisposition(
            peripheralID: peripheralID,
            continuousCaptureWanted: false,
            historyTransportActive: false,
            diagnosticActive: false,
            now: now
        ), .suppressCaptureInactive)
    }

    func testStaleMarkerCannotSuppressARealLaterDisconnect() {
        let fence = AtriaBLEManager.BackgroundReconnectFence(markerMaximumAge: 10)
        let peripheralID = UUID()
        let now = Date(timeIntervalSince1970: 30_000)
        fence.markAppOwnedCancellation(
            peripheralID: peripheralID,
            at: now.addingTimeInterval(-11)
        )
        XCTAssertEqual(fence.consumeDisposition(
            peripheralID: peripheralID,
            continuousCaptureWanted: true,
            historyTransportActive: false,
            diagnosticActive: false,
            now: now
        ), .reconnectRealtime)
    }

    func testFastLaneRadioCallsPrecedeMainActorAndShareOneGuardedHelper() throws {
        let source = try managerSource()

        let disconnectStart = try XCTUnwrap(source.range(
            of: "didDisconnectPeripheral peripheral: CBPeripheral"
        ))
        let disconnectEnd = try XCTUnwrap(source.range(
            of: "didFailToConnect peripheral: CBPeripheral",
            range: disconnectStart.upperBound..<source.endIndex
        ))
        let disconnect = String(source[disconnectStart.lowerBound..<disconnectEnd.lowerBound])
        let disposition = try XCTUnwrap(disconnect.range(of: "consumeDisposition("))
        let synchronousConnect = try XCTUnwrap(disconnect.range(
            of: "central.connect(peripheral, options: nil)",
            range: disposition.upperBound..<disconnect.endIndex
        ))
        let mainActor = try XCTUnwrap(disconnect.range(of: "Task { @MainActor in"))
        XCTAssertLessThan(synchronousConnect.lowerBound, mainActor.lowerBound)
        XCTAssertTrue(disconnect.contains("if peripheral.state == .disconnected"))
        XCTAssertTrue(disconnect.contains("action=keep_existing_standing_request"))

        let restoreStart = try XCTUnwrap(source.range(
            of: "nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict"
        ))
        let restoreEnd = try XCTUnwrap(source.range(
            of: "didDiscover peripheral",
            range: restoreStart.upperBound..<source.endIndex
        ))
        let restore = String(source[restoreStart.lowerBound..<restoreEnd.lowerBound])
        let canonicalAdmission = try XCTUnwrap(
            restore.range(of: "connectedPeripheralRetainer.admitConnected(restoredPeripheral)")
        )
        let epochActivation = try XCTUnwrap(
            restore.range(of: "bleCallbackEpochFence.activate(")
        )
        let delegate = try XCTUnwrap(restore.range(of: "restoredPeripheral.delegate = self"))
        let restoreFastLane = try XCTUnwrap(restore.range(
            of: "beginSynchronousHeartRateDiscoveryFastLane(",
            range: delegate.upperBound..<restore.endIndex
        ))
        let restoreMainActor = try XCTUnwrap(restore.range(of: "Task { @MainActor in"))
        XCTAssertLessThan(canonicalAdmission.lowerBound, epochActivation.lowerBound)
        XCTAssertLessThan(delegate.lowerBound, restoreMainActor.lowerBound)
        XCTAssertLessThan(restoreFastLane.lowerBound, restoreMainActor.lowerBound)
        XCTAssertTrue(restore.contains(
            "historyRecoveryActive: historyTransportPhaseFence.snapshot().isActive"
        ))
        XCTAssertTrue(restore.contains("diagnosticActive: motionHandshakeDiagnostic != nil"))

        XCTAssertEqual(
            source.components(separatedBy: "nonisolated private func beginSynchronousHeartRateDiscoveryFastLane(").count - 1,
            1
        )
        let helperStart = try XCTUnwrap(source.range(
            of: "nonisolated private func beginSynchronousHeartRateDiscoveryFastLane("
        ))
        let helperEnd = try XCTUnwrap(source.range(
            of: "// MARK: - CBCentralManagerDelegate",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helper = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
        let policy = try XCTUnwrap(helper.range(
            of: "shouldSynchronouslyDiscoverHeartRateAfterConnect("
        ))
        let notify = try XCTUnwrap(helper.range(of: "setNotifyValue(true"))
        let discovery = try XCTUnwrap(helper.range(
            of: "discoverServices([Self.UUIDs.heartRateService])"
        ))
        XCTAssertLessThan(policy.lowerBound, notify.lowerBound)
        XCTAssertLessThan(policy.lowerBound, discovery.lowerBound)
    }

    func testQueuedTerminalWorkIsFencedByExactObjectAndConnectionEpoch() throws {
        let source = try managerSource()
        let disconnectStart = try XCTUnwrap(source.range(
            of: "didDisconnectPeripheral peripheral: CBPeripheral"
        ))
        let failedStart = try XCTUnwrap(source.range(
            of: "didFailToConnect peripheral: CBPeripheral",
            range: disconnectStart.upperBound..<source.endIndex
        ))
        let disconnect = String(
            source[disconnectStart.lowerBound..<failedStart.lowerBound]
        )
        XCTAssertTrue(
            disconnect.contains("Self.acceptsDisconnectCallbackFollowup(")
        )
        XCTAssertTrue(disconnect.contains("self.peripheral === peripheral"))
        XCTAssertTrue(
            disconnect.contains(
                "self.bleCallbackEpochFence.epoch == terminalCallbackEpoch"
            )
        )

        let failedEnd = try XCTUnwrap(source.range(
            of: "// MARK: - CBPeripheralDelegate",
            range: failedStart.upperBound..<source.endIndex
        ))
        let failed = String(source[failedStart.lowerBound..<failedEnd.lowerBound])
        XCTAssertTrue(failed.contains("trackedPeripheralIsAbsent: self.peripheral == nil"))
        XCTAssertTrue(
            failed.contains(
                "self.bleCallbackEpochFence.epoch == failedCallbackEpoch"
            )
        )
    }

    func testSharedDiscoveryPolicyFailsClosedForHistoryReadOnlyAndDiagnostics() {
        XCTAssertFalse(AtriaBLEManager.shouldSynchronouslyDiscoverHeartRateAfterConnect(
            continuousCaptureWanted: true,
            peripheralConnected: true,
            historyRecoveryActive: true,
            diagnosticActive: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldSynchronouslyDiscoverHeartRateAfterConnect(
            continuousCaptureWanted: true,
            peripheralConnected: true,
            historyRecoveryActive: false,
            diagnosticActive: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldSynchronouslyDiscoverHeartRateAfterConnect(
            continuousCaptureWanted: false,
            peripheralConnected: true,
            historyRecoveryActive: false,
            diagnosticActive: false
        ))
        XCTAssertTrue(AtriaBLEManager.shouldSynchronouslyDiscoverHeartRateAfterConnect(
            continuousCaptureWanted: true,
            peripheralConnected: true,
            historyRecoveryActive: false,
            diagnosticActive: false
        ))
    }

    private func managerSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
