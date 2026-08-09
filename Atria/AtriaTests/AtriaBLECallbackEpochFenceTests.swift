import XCTest
import CoreBluetooth
@testable import Atria

final class AtriaBLECallbackEpochFenceTests: XCTestCase {
    func testReconnectInvalidatesQueuedWorkFromPriorLink() throws {
        let strapID = UUID()
        let firstPeripheral = NSObject()
        let secondPeripheral = NSObject()
        let fence = AtriaBLECallbackEpochFence()
        let firstEpoch = fence.activate(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(firstPeripheral)
        )
        XCTAssertTrue(fence.accepts(
            callbackEpoch: firstEpoch,
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(firstPeripheral),
            peripheralConnected: true
        ))
        let queuedSource = try XCTUnwrap(fence.captureIfAccepted(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(firstPeripheral),
            peripheralConnected: true
        ))

        fence.invalidate(
            ifMatching: strapID,
            peripheralObjectID: ObjectIdentifier(firstPeripheral)
        )
        let secondEpoch = fence.activate(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(secondPeripheral)
        )
        XCTAssertFalse(fence.accepts(
            callbackEpoch: firstEpoch,
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(firstPeripheral),
            peripheralConnected: true
        ))
        XCTAssertFalse(fence.owns(source: queuedSource),
                       "queued HR/realtime/R10 work from the retired object must be rejected")
        XCTAssertTrue(fence.accepts(
            callbackEpoch: secondEpoch,
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(secondPeripheral),
            peripheralConnected: true
        ))
    }

    func testDistinctPeripheralObjectWithSameUUIDIsRejected() {
        let strapID = UUID()
        let activePeripheral = NSObject()
        let duplicatePeripheral = NSObject()
        let fence = AtriaBLECallbackEpochFence()
        let epoch = fence.activate(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(activePeripheral)
        )

        XCTAssertNil(fence.captureIfAccepted(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(duplicatePeripheral),
            peripheralConnected: true
        ))
        XCTAssertFalse(fence.accepts(
            callbackEpoch: epoch,
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(duplicatePeripheral),
            peripheralConnected: true
        ))
    }

    func testStaleDisconnectCannotInvalidateDifferentPeripheral() {
        let active = UUID()
        let activePeripheral = NSObject()
        let duplicatePeripheral = NSObject()
        let fence = AtriaBLECallbackEpochFence()
        let epoch = fence.activate(
            peripheralID: active,
            peripheralObjectID: ObjectIdentifier(activePeripheral)
        )

        XCTAssertEqual(fence.invalidate(ifMatching: UUID()), epoch)
        XCTAssertEqual(fence.invalidate(
            ifMatching: active,
            peripheralObjectID: ObjectIdentifier(duplicatePeripheral)
        ), epoch)
        XCTAssertTrue(fence.accepts(
            callbackEpoch: epoch,
            peripheralID: active,
            peripheralObjectID: ObjectIdentifier(activePeripheral),
            peripheralConnected: true
        ))
        XCTAssertFalse(fence.accepts(
            callbackEpoch: epoch,
            peripheralID: active,
            peripheralObjectID: ObjectIdentifier(activePeripheral),
            peripheralConnected: false
        ))
    }

    func testOwnedEpochSurvivesDisconnectedObjectForStandingReconnect() {
        let active = UUID()
        let activePeripheral = NSObject()
        let fence = AtriaBLECallbackEpochFence()
        let epoch = fence.activate(
            peripheralID: active,
            peripheralObjectID: ObjectIdentifier(activePeripheral)
        )

        XCTAssertTrue(fence.owns(
            callbackEpoch: epoch,
            peripheralID: active,
            peripheralObjectID: ObjectIdentifier(activePeripheral)
        ))
        XCTAssertFalse(fence.accepts(
            callbackEpoch: epoch,
            peripheralID: active,
            peripheralObjectID: ObjectIdentifier(activePeripheral),
            peripheralConnected: false
        ))
        XCTAssertFalse(fence.owns(
            callbackEpoch: epoch,
            peripheralID: UUID(),
            peripheralObjectID: ObjectIdentifier(activePeripheral)
        ))

        fence.invalidate(
            ifMatching: active,
            peripheralObjectID: ObjectIdentifier(activePeripheral)
        )
        XCTAssertFalse(fence.owns(
            callbackEpoch: epoch,
            peripheralID: active,
            peripheralObjectID: ObjectIdentifier(activePeripheral)
        ))
    }

    func testRestoredEpochAuthorityPreventsDuplicateLocalConnectBeforePublication() throws {
        let strapID = UUID()
        let restoredPeripheral = NSObject()
        let unrelatedSystemObject = NSObject()
        let fence = AtriaBLECallbackEpochFence()

        _ = fence.activate(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(restoredPeripheral)
        )

        // `self.peripheral` is intentionally absent here, matching the window
        // after willRestoreState has synchronously claimed the callback epoch
        // but before its MainActor publication task runs.
        let restoredOwnsEpoch = fence.captureIfAccepted(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(restoredPeripheral),
            peripheralConnected: true
        ) != nil
        XCTAssertFalse(
            AtriaBLEManager.shouldEstablishLocalConnectionForSystemConnectedPeripheral(
                exactObjectOwnsCurrentEpoch: restoredOwnsEpoch
            ),
            "an already-restored exact object must not receive a duplicate connect request"
        )

        let unrelatedOwnsEpoch = fence.captureIfAccepted(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(unrelatedSystemObject),
            peripheralConnected: true
        ) != nil
        XCTAssertTrue(
            AtriaBLEManager.shouldEstablishLocalConnectionForSystemConnectedPeripheral(
                exactObjectOwnsCurrentEpoch: unrelatedOwnsEpoch
            ),
            "an object this central has not adopted still needs a local connection"
        )
    }

    func testStandingConnectPoliciesNeverIssueASecondRequestForAnExistingTransition() {
        XCTAssertTrue(
            AtriaBLEManager.shouldIssuePoweredOnStandingConnect(
                peripheralState: .disconnected
            )
        )
        for state in [
            CBPeripheralState.connecting,
            .connected,
            .disconnecting
        ] {
            XCTAssertFalse(
                AtriaBLEManager.shouldIssuePoweredOnStandingConnect(
                    peripheralState: state
                )
            )
        }

        XCTAssertFalse(
            AtriaBLEManager.shouldIssueMainActorDisconnectReconnect(
                synchronousReconnectIssued: true,
                peripheralState: .disconnected
            ),
            "a delegate-lane reconnect remains the sole request even while CoreBluetooth still samples disconnected"
        )
        XCTAssertTrue(
            AtriaBLEManager.shouldIssueMainActorDisconnectReconnect(
                synchronousReconnectIssued: false,
                peripheralState: .disconnected
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldIssueMainActorDisconnectReconnect(
                synchronousReconnectIssued: false,
                peripheralState: .connecting
            )
        )

        XCTAssertTrue(
            AtriaBLEManager.shouldIssueDelayedRecoveryConnect(
                peripheralState: .disconnected
            )
        )
        for state in [
            CBPeripheralState.connecting,
            .connected,
            .disconnecting
        ] {
            XCTAssertFalse(
                AtriaBLEManager.shouldIssueDelayedRecoveryConnect(
                    peripheralState: state
                )
            )
        }
    }

    func testSavedReconnectUsesExactEpochAuthorityInsteadOfMainActorPublication() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let manager = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(manager.range(
            of: "func reconnectToSavedPeripheralIfPossible(reason: String,"
        )?.lowerBound)
        let end = try XCTUnwrap(manager.range(
            of: "private func beginProtectedR10LaunchConnectionCutoverIfNeeded(",
            range: start..<manager.endIndex
        )?.lowerBound)
        let reconnect = String(manager[start..<end])

        XCTAssertTrue(reconnect.contains(
            "let savedAlreadyOwnsCurrentEpoch = bleCallbackEpochFence\n            .captureIfAccepted("
        ))
        XCTAssertFalse(reconnect.contains(
            "let savedAlreadyOwnsCurrentEpoch = self.peripheral === saved"
        ))
    }

    func testRelaunchAndDisconnectPathsEnforceOneConnectRequestPerObject() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let manager = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaBLEManager.swift"),
            encoding: .utf8
        )

        let didConnectStart = try XCTUnwrap(manager.range(
            of: "nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)"
        )?.lowerBound)
        let didDisconnectStart = try XCTUnwrap(manager.range(
            of: "didDisconnectPeripheral peripheral: CBPeripheral",
            range: didConnectStart..<manager.endIndex
        )?.lowerBound)
        let didConnect = String(manager[didConnectStart..<didDisconnectStart])
        let exactDuplicateGuard = try XCTUnwrap(didConnect.range(
            of: "if bleCallbackEpochFence.captureIfAccepted("
        ))
        let retainerAdmission = try XCTUnwrap(didConnect.range(
            of: "connectedPeripheralRetainer.admitConnected(peripheral)"
        ))
        let epochActivation = try XCTUnwrap(didConnect.range(
            of: "let callbackEpoch = bleCallbackEpochFence.activate("
        ))
        XCTAssertLessThan(exactDuplicateGuard.lowerBound, retainerAdmission.lowerBound)
        XCTAssertLessThan(exactDuplicateGuard.lowerBound, epochActivation.lowerBound)

        let didFailStart = try XCTUnwrap(manager.range(
            of: "didFailToConnect peripheral: CBPeripheral",
            range: didDisconnectStart..<manager.endIndex
        )?.lowerBound)
        let didDisconnect = String(manager[didDisconnectStart..<didFailStart])
        let synchronousClaim = try XCTUnwrap(didDisconnect.range(
            of: "let synchronousReconnectIssued ="
        ))
        let mainActor = try XCTUnwrap(didDisconnect.range(
            of: "Task { @MainActor in",
            range: synchronousClaim.upperBound..<didDisconnect.endIndex
        ))
        let singleRequestReturn = try XCTUnwrap(didDisconnect.range(
            of: "action=single_synchronous_request_no_mainactor_duplicate",
            range: mainActor.upperBound..<didDisconnect.endIndex
        ))
        let freshScan = try XCTUnwrap(didDisconnect.range(
            of: "if useFreshScan",
            range: singleRequestReturn.upperBound..<didDisconnect.endIndex
        ))
        XCTAssertLessThan(singleRequestReturn.lowerBound, freshScan.lowerBound)
        XCTAssertTrue(didDisconnect.contains(
            "shouldIssueMainActorDisconnectReconnect("
        ))
        XCTAssertTrue(didDisconnect.contains(
            "action=use_existing_synchronous_reconnect_no_duplicate"
        ))
        XCTAssertTrue(didDisconnect.contains(
            "standingReconnectAlreadyIssued:\n                        synchronousReconnectIssued"
        ))

        let restoreStart = try XCTUnwrap(manager.range(
            of: "nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict"
        )?.lowerBound)
        let discoverStart = try XCTUnwrap(manager.range(
            of: "didDiscover peripheral: CBPeripheral",
            range: restoreStart..<manager.endIndex
        )?.lowerBound)
        let restore = String(manager[restoreStart..<discoverStart])
        let disconnectedCase = try XCTUnwrap(restore.range(
            of: "case .disconnected:"
        )?.lowerBound)
        let unknownCase = try XCTUnwrap(restore.range(
            of: "@unknown default:",
            range: disconnectedCase..<restore.endIndex
        )?.lowerBound)
        XCTAssertFalse(
            String(restore[disconnectedCase..<unknownCase]).contains(
                "issueSingleFlightConnect("
            ),
            "the powered-on delegate precheck is the sole owner of a disconnected restored object's connect"
        )

        let stateStart = try XCTUnwrap(manager.range(
            of: "nonisolated func centralManagerDidUpdateState"
        )?.lowerBound)
        let stateEnd = try XCTUnwrap(manager.range(
            of: "nonisolated static func canonicalRestoredPeripheralIndex(",
            range: stateStart..<manager.endIndex
        )?.lowerBound)
        XCTAssertTrue(String(manager[stateStart..<stateEnd]).contains(
            "Self.shouldIssuePoweredOnStandingConnect("
        ))

        let attachStart = try XCTUnwrap(manager.range(
            of: "fileprivate func attach(to p: CBPeripheral, name: String)"
        )?.lowerBound)
        let attachEnd = try XCTUnwrap(manager.range(
            of: "func disconnect()",
            range: attachStart..<manager.endIndex
        )?.lowerBound)
        let attach = String(manager[attachStart..<attachEnd])
        let attachEpochClaim = try XCTUnwrap(attach.range(
            of: "let exactObjectOwnsCurrentEpoch"
        ))
        let attachNoConnect = try XCTUnwrap(attach.range(
            of: "action=no_duplicate_connect"
        ))
        let attachConnect = try XCTUnwrap(attach.range(
            of: "issueSingleFlightConnect("
        ))
        XCTAssertLessThan(attachEpochClaim.lowerBound, attachNoConnect.lowerBound)
        XCTAssertLessThan(attachNoConnect.lowerBound, attachConnect.lowerBound)

        let delayedRecoveryStart = try XCTUnwrap(manager.range(
            of: "private func requestFreshScanReconnect(peripheral target: CBPeripheral,"
        )?.lowerBound)
        let delayedRecoveryEnd = try XCTUnwrap(manager.range(
            of: "private func recoveryReconnectDelay(",
            range: delayedRecoveryStart..<manager.endIndex
        )?.lowerBound)
        let delayedRecoveryBody = String(
            manager[delayedRecoveryStart..<delayedRecoveryEnd]
        )
        XCTAssertTrue(delayedRecoveryBody.contains(
            "target.state != .disconnecting"
        ))
        XCTAssertTrue(delayedRecoveryBody.contains(
            "Self.shouldIssueDelayedRecoveryConnect("
        ))

        let disconnectStart = try XCTUnwrap(manager.range(
            of: "func disconnect()"
        )?.lowerBound)
        let disconnectEnd = try XCTUnwrap(manager.range(
            of: "func suspendForCanonicalRestoreFailure()",
            range: disconnectStart..<manager.endIndex
        )?.lowerBound)
        let explicitDisconnect = String(manager[disconnectStart..<disconnectEnd])
        let fallbackCancellation = try XCTUnwrap(explicitDisconnect.range(
            of: "freshScanFallbackTask?.cancel()"
        ))
        let userIntent = try XCTUnwrap(explicitDisconnect.range(
            of: "userRequestedDisconnect = true"
        ))
        XCTAssertLessThan(fallbackCancellation.lowerBound, userIntent.lowerBound)

        let peripheralDelegateStart = try XCTUnwrap(manager.range(
            of: "// MARK: - CBPeripheralDelegate",
            range: didFailStart..<manager.endIndex
        )?.lowerBound)
        let didFail = String(manager[didFailStart..<peripheralDelegateStart])
        XCTAssertTrue(didFail.contains(
            "&& !Self.isPeerRemovedPairingError(error)"
        ))
        let failedSingleRequest = try XCTUnwrap(didFail.range(
            of: "action=single_synchronous_request_no_delayed_duplicate"
        ))
        let delayedRecovery = try XCTUnwrap(didFail.range(
            of: "let disposition = Self.failedConnectRecoveryDisposition("
        ))
        XCTAssertLessThan(failedSingleRequest.lowerBound, delayedRecovery.lowerBound)
        XCTAssertTrue(
            String(didFail[failedSingleRequest.lowerBound..<delayedRecovery.lowerBound])
                .contains("return")
        )
        XCTAssertTrue(didFail.contains(
            "standingReconnectAlreadyIssued:\n                        synchronousReconnectIssued"
        ))

        let v10HelperStart = try XCTUnwrap(manager.range(
            of: "private func beginProtectedR10PureHRV10InProcessCutoverIfNeeded("
        )?.lowerBound)
        let v10HelperEnd = try XCTUnwrap(manager.range(
            of: "private func beginProtectedR10V8WorkoutCutoverIfNeeded(",
            range: v10HelperStart..<manager.endIndex
        )?.lowerBound)
        let v10Helper = String(manager[v10HelperStart..<v10HelperEnd])
        let existingRequestGate = try XCTUnwrap(v10Helper.range(
            of: "if !standingReconnectAlreadyIssued {"
        ))
        let v10Connect = try XCTUnwrap(v10Helper.range(
            of: "issueSingleFlightConnect("
        ))
        XCTAssertLessThan(existingRequestGate.lowerBound, v10Connect.lowerBound)

        let gatewayStart = try XCTUnwrap(manager.range(
            of: "nonisolated private func issueSingleFlightConnect("
        )?.lowerBound)
        let gatewayEnd = try XCTUnwrap(manager.range(
            of: "private func reconnectKnownPeripheralImmediately(",
            range: gatewayStart..<manager.endIndex
        )?.lowerBound)
        let gateway = String(manager[gatewayStart..<gatewayEnd])
        XCTAssertEqual(
            manager.components(
                separatedBy: "callbackCentral.connect(target, options: nil)"
            ).count - 1,
            1,
            "all connect issuers must converge on one raw CoreBluetooth call"
        )
        XCTAssertTrue(gateway.contains(".retainAndClaimConnectRequest(target)"))
        XCTAssertTrue(gateway.contains(
            "callbackCentral.connect(target, options: nil)"
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
        let strapPeripheral = NSObject()
        let otherPeripheral = NSObject()
        let queue = DispatchQueue(
            label: "atria.tests.ble-callback-epoch",
            attributes: .concurrent
        )
        let group = DispatchGroup()

        for iteration in 0..<2_000 {
            group.enter()
            queue.async {
                if iteration % 3 == 0 {
                    _ = fence.activate(
                        peripheralID: strapID,
                        peripheralObjectID: ObjectIdentifier(strapPeripheral)
                    )
                } else if iteration % 3 == 1 {
                    _ = fence.invalidate(
                        ifMatching: strapID,
                        peripheralObjectID: ObjectIdentifier(strapPeripheral)
                    )
                } else {
                    _ = fence.activate(
                        peripheralID: otherID,
                        peripheralObjectID: ObjectIdentifier(otherPeripheral)
                    )
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let finalEpoch = fence.activate(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(strapPeripheral)
        )
        XCTAssertTrue(fence.accepts(
            callbackEpoch: finalEpoch,
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(strapPeripheral),
            peripheralConnected: true
        ))
        XCTAssertFalse(fence.accepts(
            callbackEpoch: finalEpoch,
            peripheralID: otherID,
            peripheralObjectID: ObjectIdentifier(otherPeripheral),
            peripheralConnected: true
        ))
    }

    func testQueuedDiscoverySideEffectsFromRetiredSameUUIDObjectAreRejected() throws {
        let strapID = UUID()
        let retiredPeripheral = NSObject()
        let replacementPeripheral = NSObject()
        let fence = AtriaBLECallbackEpochFence()

        _ = fence.activate(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(retiredPeripheral)
        )
        let queuedSource = try XCTUnwrap(fence.captureIfAccepted(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(retiredPeripheral),
            peripheralConnected: true
        ))

        fence.invalidate(
            ifMatching: strapID,
            peripheralObjectID: ObjectIdentifier(retiredPeripheral)
        )
        _ = fence.activate(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(replacementPeripheral)
        )

        var effects = DiscoverySideEffects()
        applyDiscoverySideEffects(
            ifAcceptedBy: fence,
            source: queuedSource,
            to: &effects
        )
        XCTAssertEqual(effects, DiscoverySideEffects(),
                       "a retired same-UUID peripheral must not install HR/TX or issue discovery/protocol commands")

        let replacementSource = try XCTUnwrap(fence.captureIfAccepted(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(replacementPeripheral),
            peripheralConnected: true
        ))
        applyDiscoverySideEffects(
            ifAcceptedBy: fence,
            source: replacementSource,
            to: &effects
        )
        XCTAssertEqual(
            effects,
            DiscoverySideEffects(
                heartRateInstalls: 1,
                txInstalls: 1,
                characteristicDiscoveryRequests: 1,
                protocolCommandRequests: 1
            ),
            "the current exact object and epoch still admit the complete discovery transaction"
        )
    }

    func testDiscoveryCallbacksFenceEveryDeferredTaskAndSynchronousRadioBoundary() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let manager = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let servicesStart = try XCTUnwrap(manager.range(
            of: "nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)"
        )?.lowerBound)
        let callbacksEnd = try XCTUnwrap(manager.range(
            of: "nonisolated func peripheral(_ peripheral: CBPeripheral,\n                    didWriteValueFor characteristic:",
            range: servicesStart..<manager.endIndex
        )?.lowerBound)
        let discoveryCallbacks = String(manager[servicesStart..<callbacksEnd])

        let deferredTasks = discoveryCallbacks.components(
            separatedBy: "Task { @MainActor in"
        ).dropFirst()
        XCTAssertGreaterThanOrEqual(deferredTasks.count, 11)
        for (index, task) in deferredTasks.enumerated() {
            let firstStatement = task.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(
                firstStatement.hasPrefix("guard self.acceptsBLECallback(\n"),
                "deferred discovery task \(index + 1) must revalidate before its first side effect"
            )
            XCTAssertTrue(
                String(firstStatement.prefix(220)).contains("source: callbackSource"),
                "deferred discovery task \(index + 1) must use the exact captured source"
            )
        }

        XCTAssertTrue(discoveryCallbacks.contains(
            "guard bleCallbackEpochFence.accepts(\n                source: callbackSource,\n                peripheralConnected: peripheral.state == .connected\n            ) else"
        ), "characteristic discovery requests must revalidate at the radio boundary")
        XCTAssertTrue(discoveryCallbacks.contains(
            "if requestedSynchronously,\n                           bleCallbackEpochFence.accepts(\n                            source: callbackSource"
        ), "the synchronous 2A37 notify request must reject a retired source")
        XCTAssertTrue(discoveryCallbacks.contains(
            "if bleCallbackEpochFence.accepts(\n                    source: callbackSource,\n                    peripheralConnected: peripheral.state == .connected\n                ) {\n                    peripheral.readValue(for: ch)"
        ), "information reads must reject a retired source")
        XCTAssertTrue(discoveryCallbacks.contains(
            "} else if !ch.isNotifying,\n                              bleCallbackEpochFence.accepts(\n                                source: callbackSource"
        ), "proprietary notification requests must reject a retired source")
    }

    private struct DiscoverySideEffects: Equatable {
        var heartRateInstalls = 0
        var txInstalls = 0
        var characteristicDiscoveryRequests = 0
        var protocolCommandRequests = 0
    }

    private func applyDiscoverySideEffects(
        ifAcceptedBy fence: AtriaBLECallbackEpochFence,
        source: AtriaBLECallbackEpochFence.Source,
        to effects: inout DiscoverySideEffects
    ) {
        guard fence.accepts(source: source, peripheralConnected: true) else {
            return
        }
        effects.heartRateInstalls += 1
        effects.txInstalls += 1
        effects.characteristicDiscoveryRequests += 1
        effects.protocolCommandRequests += 1
    }
}
