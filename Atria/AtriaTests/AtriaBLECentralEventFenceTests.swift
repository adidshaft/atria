import XCTest
import CoreBluetooth
@testable import Atria

final class AtriaBLECentralEventFenceTests: XCTestCase {
    private final class CentralStub {}

    func testRetiredCentralCannotCaptureCallbackAuthority() {
        let fence = AtriaBLECentralEventFence()
        let retired = CentralStub()
        let replacement = CentralStub()

        let retiredToken = fence.install(retired)
        fence.retire(retired)
        let replacementToken = fence.install(replacement)

        XCTAssertNil(fence.capture(retired))
        XCTAssertFalse(fence.accepts(retiredToken, central: retired))
        XCTAssertTrue(fence.accepts(replacementToken, central: replacement))
    }

    func testInstallingReplacementInvalidatesQueuedWorkFromPreviousCentral() {
        let fence = AtriaBLECentralEventFence()
        let first = CentralStub()
        let second = CentralStub()
        let queuedFirstCallback = fence.install(first)

        let secondToken = fence.install(second)

        XCTAssertFalse(fence.accepts(queuedFirstCallback, central: first))
        XCTAssertTrue(fence.accepts(secondToken, central: second))
    }

    func testRetiredTokenCannotInspectOrConsumeReplacementPowerOnMarkers() {
        let fence = AtriaBLECentralEventFence()
        let retired = CentralStub()
        let replacement = CentralStub()

        let retiredToken = fence.install(retired)
        fence.markAwaitingPowerOn(
            token: retiredToken,
            standingConnect: true,
            silentStreamRebuild: false
        )
        fence.retire(retired)

        let replacementToken = fence.install(replacement)
        fence.markAwaitingPowerOn(
            token: replacementToken,
            standingConnect: true,
            silentStreamRebuild: true
        )

        XCTAssertEqual(
            fence.powerOnMarkerSnapshot(token: retiredToken),
            .init(),
            "a retired callback must not inspect replacement-generation markers"
        )
        XCTAssertEqual(
            fence.consumePowerOnMarkers(token: retiredToken),
            .init(),
            "a retired callback must not consume replacement-generation markers"
        )
        XCTAssertEqual(
            fence.powerOnMarkerSnapshot(token: replacementToken),
            .init(standingConnect: true, silentStreamRebuild: true),
            "the rejected retired consume must leave replacement markers intact"
        )
        XCTAssertEqual(
            fence.consumePowerOnMarkers(token: replacementToken),
            .init(standingConnect: true, silentStreamRebuild: true)
        )
        XCTAssertEqual(
            fence.powerOnMarkerSnapshot(token: replacementToken),
            .init()
        )
    }

    func testRetirementDrainsAnAlreadyAdmittedCallbackBeforeReplacement() {
        let fence = AtriaBLECentralEventFence()
        let callbackQueue = DispatchQueue(
            label: "com.adidshaft.atria.tests.central-callback-retirement"
        )
        let retired = CentralStub()
        let replacement = CentralStub()
        let callbackEntered = DispatchSemaphore(value: 0)
        let allowCallbackToReturn = DispatchSemaphore(value: 0)
        let retirementReturned = DispatchSemaphore(value: 0)

        let retiredToken = fence.install(retired)
        callbackQueue.async {
            guard fence.capture(retired) != nil else { return }
            callbackEntered.signal()
            allowCallbackToReturn.wait()
        }
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            fence.retire(retired, afterDraining: callbackQueue)
            retirementReturned.signal()
        }
        XCTAssertEqual(
            retirementReturned.wait(timeout: .now() + 0.05),
            .timedOut,
            "retirement must not cross an admitted callback's critical section"
        )

        allowCallbackToReturn.signal()
        XCTAssertEqual(retirementReturned.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(fence.accepts(retiredToken, central: retired))
        XCTAssertNil(fence.capture(retired))

        let replacementToken = fence.install(replacement)
        XCTAssertTrue(fence.accepts(replacementToken, central: replacement))
    }

    func testRetirementInvalidatesPeripheralEpochBeforeBehindBarrierCallback() throws {
        let centralFence = AtriaBLECentralEventFence()
        let peripheralFence = AtriaBLECallbackEpochFence()
        let callbackQueue = DispatchQueue(
            label: "com.adidshaft.atria.tests.atomic-central-peripheral-retirement"
        )
        let central = CentralStub()
        let peripheral = NSObject()
        let strapID = UUID()
        let callbackEntered = DispatchSemaphore(value: 0)
        let allowCallbackToReturn = DispatchSemaphore(value: 0)
        let retirementReturned = DispatchSemaphore(value: 0)
        let behindBarrierRejected = DispatchSemaphore(value: 0)
        let behindBarrierAdmitted = DispatchSemaphore(value: 0)

        _ = centralFence.install(central)
        _ = peripheralFence.activate(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(peripheral)
        )
        let source = try XCTUnwrap(peripheralFence.captureIfAccepted(
            peripheralID: strapID,
            peripheralObjectID: ObjectIdentifier(peripheral),
            peripheralConnected: true
        ))

        callbackQueue.async {
            guard peripheralFence.owns(source: source) else { return }
            callbackEntered.signal()
            allowCallbackToReturn.wait()
        }
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            centralFence.retire(
                central,
                afterDraining: callbackQueue,
                synchronizedTeardown: {
                    peripheralFence.invalidate()
                    // Enqueue from inside the retirement block itself. This is
                    // deterministically the first possible callback behind the
                    // barrier, not a timing approximation from another queue.
                    callbackQueue.async {
                        if peripheralFence.owns(source: source) {
                            behindBarrierAdmitted.signal()
                        } else {
                            behindBarrierRejected.signal()
                        }
                    }
                }
            )
            retirementReturned.signal()
        }

        XCTAssertEqual(
            retirementReturned.wait(timeout: .now() + 0.05),
            .timedOut
        )
        allowCallbackToReturn.signal()
        XCTAssertEqual(retirementReturned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            behindBarrierRejected.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertEqual(
            behindBarrierAdmitted.wait(timeout: .now() + 0.05),
            .timedOut,
            "the old peripheral epoch must be invalid before the callback lane is released"
        )
    }

    func testConditionalRetirementLetsAheadOfBarrierLiveEdgeVetoRotation() {
        let fence = AtriaBLECentralEventFence()
        let callbackQueue = DispatchQueue(
            label: "com.adidshaft.atria.tests.conditional-central-retirement"
        )
        let central = CentralStub()
        let token = fence.install(central)
        var liveEdgeObserved = false

        callbackQueue.async {
            liveEdgeObserved = true
        }
        let retired = fence.retireIfAccepted(
            central,
            token: token,
            afterDraining: callbackQueue,
            shouldRetire: { !liveEdgeObserved }
        )

        XCTAssertFalse(retired)
        XCTAssertTrue(
            fence.accepts(token, central: central),
            "a connected edge ahead of the barrier must preserve its manager"
        )
    }

    func testConditionalRetirementRunsTeardownOnceForExactToken() {
        let fence = AtriaBLECentralEventFence()
        let callbackQueue = DispatchQueue(
            label: "com.adidshaft.atria.tests.exact-central-retirement"
        )
        let central = CentralStub()
        let token = fence.install(central)
        var teardownCount = 0

        XCTAssertTrue(fence.retireIfAccepted(
            central,
            token: token,
            afterDraining: callbackQueue,
            shouldRetire: { true },
            synchronizedTeardown: { teardownCount += 1 }
        ))
        XCTAssertEqual(teardownCount, 1)
        XCTAssertFalse(fence.retireIfAccepted(
            central,
            token: token,
            afterDraining: callbackQueue,
            shouldRetire: { true },
            synchronizedTeardown: { teardownCount += 1 }
        ))
        XCTAssertEqual(teardownCount, 1)
    }
}

final class AtriaBLECentralRecoveryTests: XCTestCase {
    private let baseA = "com.adidshaft.atria.ble-central-owner-a"
    private let baseB = "com.adidshaft.atria.ble-central-owner-b"

    func testRestoreIdentifierResolvesOnlyValidSlotForMatchingBase() {
        let alternate = "\(baseA).recovery-b-v1"

        XCTAssertEqual(
            AtriaBLEManager.resolvedCentralRestoreIdentifier(
                baseIdentifier: baseA,
                persistedBaseIdentifier: nil,
                persistedOverrideIdentifier: nil
            ),
            baseA
        )
        XCTAssertEqual(
            AtriaBLEManager.resolvedCentralRestoreIdentifier(
                baseIdentifier: baseA,
                persistedBaseIdentifier: baseA,
                persistedOverrideIdentifier: baseA
            ),
            baseA
        )
        XCTAssertEqual(
            AtriaBLEManager.resolvedCentralRestoreIdentifier(
                baseIdentifier: baseA,
                persistedBaseIdentifier: baseA,
                persistedOverrideIdentifier: alternate
            ),
            alternate
        )
    }

    func testRestoreIdentifierRejectsInvalidAndDifferentBasePersistence() {
        let alternate = "\(baseA).recovery-b-v1"

        XCTAssertEqual(
            AtriaBLEManager.resolvedCentralRestoreIdentifier(
                baseIdentifier: baseA,
                persistedBaseIdentifier: baseA,
                persistedOverrideIdentifier: "\(baseA).recovery-c-invalid"
            ),
            baseA
        )
        XCTAssertEqual(
            AtriaBLEManager.resolvedCentralRestoreIdentifier(
                baseIdentifier: baseA,
                persistedBaseIdentifier: baseB,
                persistedOverrideIdentifier: alternate
            ),
            baseA,
            "a recovery slot from another protected-owner base must not leak across owners"
        )
        XCTAssertEqual(
            AtriaBLEManager.resolvedCentralRestoreIdentifier(
                baseIdentifier: baseB,
                persistedBaseIdentifier: baseA,
                persistedOverrideIdentifier: "\(baseB).recovery-b-v1"
            ),
            baseB
        )
    }

    func testRestoreIdentifierAlternatesBetweenBaseSlotAAndRecoverySlotB() {
        let alternate = "\(baseA).recovery-b-v1"

        XCTAssertEqual(
            AtriaBLEManager.nextCentralRecoveryRestoreIdentifier(
                baseIdentifier: baseA,
                currentIdentifier: baseA
            ),
            alternate
        )
        XCTAssertEqual(
            AtriaBLEManager.nextCentralRecoveryRestoreIdentifier(
                baseIdentifier: baseA,
                currentIdentifier: alternate
            ),
            baseA
        )
        XCTAssertEqual(
            AtriaBLEManager.nextCentralRecoveryRestoreIdentifier(
                baseIdentifier: baseA,
                currentIdentifier: "invalid-current-owner"
            ),
            alternate,
            "an invalid current value must recover into a known slot"
        )
    }

    func testUnavailableRecoveryPlanIsBoundedByTruthAndLifecycle() {
        let poweredOff = AtriaBLEManager.centralUnavailableRecoveryPlan(
            state: .poweredOff,
            bluetoothAuthorizationAllowed: true,
            applicationMayInteract: true,
            runningOnSimulator: false,
            hasPriorSuccessfulConnection: false,
            recoveryAlreadyPending: false
        )
        XCTAssertEqual(poweredOff, .rebuild(after: 60))

        for (state, authorized, active, simulator, priorSuccess, pending) in [
            (CBManagerState.unauthorized, true, true, false, true, false),
            (.poweredOff, true, false, false, true, false),
            (.poweredOff, true, true, true, true, false),
            (.poweredOff, true, true, false, true, true),
            (.poweredOff, false, true, false, true, false)
        ] {
            XCTAssertEqual(
                AtriaBLEManager.centralUnavailableRecoveryPlan(
                    state: state,
                    bluetoothAuthorizationAllowed: authorized,
                    applicationMayInteract: active,
                    runningOnSimulator: simulator,
                    hasPriorSuccessfulConnection: priorSuccess,
                    recoveryAlreadyPending: pending
                ),
                .none
            )
        }

        XCTAssertEqual(
            AtriaBLEManager.centralUnavailableRecoveryPlan(
                state: .unsupported,
                bluetoothAuthorizationAllowed: true,
                applicationMayInteract: true,
                runningOnSimulator: false,
                hasPriorSuccessfulConnection: false,
                recoveryAlreadyPending: false
            ),
            .rebuild(after: 1),
            "a false unsupported state must be repairable on first use"
        )
        XCTAssertEqual(
            AtriaBLEManager.centralUnavailableRecoveryPlan(
                state: .unsupported,
                bluetoothAuthorizationAllowed: true,
                applicationMayInteract: true,
                runningOnSimulator: false,
                hasPriorSuccessfulConnection: true,
                recoveryAlreadyPending: false
            ),
            .rebuild(after: 1),
            "the same bounded repair remains available after prior success"
        )
    }

    func testUnavailableRecoveryRemainingDelayHonorsOriginalObservationTime() {
        let observedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            AtriaBLEManager.centralUnavailableRecoveryRemainingDelay(
                observedAt: observedAt,
                now: observedAt.addingTimeInterval(59),
                threshold: 60
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            AtriaBLEManager.centralUnavailableRecoveryRemainingDelay(
                observedAt: observedAt,
                now: observedAt.addingTimeInterval(60),
                threshold: 60
            ),
            0,
            accuracy: 0.000_001
        )
    }

    func testRecoverySlotsAreLoadedAndPersistedPerBaseDictionaryEntry() throws {
        let source = try managerSource()
        let getterStart = try XCTUnwrap(source.range(
            of: "private var centralRestoreIdentifier: String {"
        ))
        let getterEnd = try XCTUnwrap(source.range(
            of: "private var activeCentralBaseIdentifier: String {",
            range: getterStart.upperBound..<source.endIndex
        ))
        let getter = String(source[getterStart.lowerBound..<getterEnd.lowerBound])
        XCTAssertTrue(getter.contains("let persisted = slots?[baseIdentifier]"))
        XCTAssertFalse(getter.contains("slots?.values.first"))

        let persistStart = try XCTUnwrap(source.range(
            of: "private func persistCentralRecoveryRestoreIdentifier("
        ))
        let persistEnd = try XCTUnwrap(source.range(
            of: "private func centralRecoveryIsPending(",
            range: persistStart.upperBound..<source.endIndex
        ))
        let persistence = String(
            source[persistStart.lowerBound..<persistEnd.lowerBound]
        )
        XCTAssertTrue(persistence.contains("var slots = defaults.dictionary("))
        XCTAssertTrue(persistence.contains("slots[baseIdentifier] = identifier"))
        XCTAssertTrue(persistence.contains("defaults.set(slots,"))
        XCTAssertFalse(persistence.contains("removePersistentDomain"))
    }

    func testAllCentralDelegateCallbacksFenceExactManagerBeforeSideEffects() throws {
        let source = try managerSource()
        let extensionStart = try XCTUnwrap(source.range(
            of: "extension AtriaBLEManager: CBCentralManagerDelegate {"
        ))
        let delegateSource = String(source[extensionStart.lowerBound...])
        let callbackSignatures = [
            "nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {",
            "nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {",
            "didDiscover peripheral: CBPeripheral,",
            "nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {",
            "didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {",
            "didFailToConnect peripheral: CBPeripheral,"
        ]

        for signature in callbackSignatures {
            let signatureRange = try XCTUnwrap(
                delegateSource.range(of: signature),
                "missing callback signature: \(signature)"
            )
            let openingBrace: String.Index
            if signature.hasSuffix("{") {
                openingBrace = try XCTUnwrap(
                    delegateSource[signatureRange].lastIndex(of: "{")
                )
            } else {
                openingBrace = try XCTUnwrap(
                    delegateSource.range(
                        of: "{",
                        range: signatureRange.upperBound..<delegateSource.endIndex
                    )?.lowerBound
                )
            }
            let bodyPrefix = delegateSource[delegateSource.index(after: openingBrace)...]
                .drop(while: { $0.isWhitespace })
            XCTAssertTrue(
                bodyPrefix.hasPrefix(
                    "guard let centralToken = centralEventFence.capture(central) else {"
                ),
                "\(signature) must capture exact central authority before its first side effect"
            )
        }
    }

    func testStateCallbackFreezesAndSwitchesObservedState() throws {
        let source = try managerSource()
        let callbackStart = try XCTUnwrap(source.range(
            of: "nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {",
            range: try XCTUnwrap(source.range(
                of: "extension AtriaBLEManager: CBCentralManagerDelegate {"
            )).upperBound..<source.endIndex
        ))
        let callbackEnd = try XCTUnwrap(source.range(
            of: "nonisolated static func canonicalRestoredPeripheralIndex(",
            range: callbackStart.upperBound..<source.endIndex
        ))
        let callback = String(
            source[callbackStart.lowerBound..<callbackEnd.lowerBound]
        )
        let freeze = try XCTUnwrap(callback.range(
            of: "let observedState = central.state"
        ))
        let followupGuard = try XCTUnwrap(callback.range(
            of: "central.state == observedState"
        ))
        let stateSwitch = try XCTUnwrap(callback.range(of: "switch observedState"))

        XCTAssertLessThan(freeze.lowerBound, followupGuard.lowerBound)
        XCTAssertLessThan(followupGuard.lowerBound, stateSwitch.lowerBound)
        XCTAssertFalse(callback.contains("switch central.state"))
    }

    func testCentralTeardownDrainsDelegateLaneBeforeEpochOrDelegateMutation() throws {
        let source = try managerSource()

        let rebuildStart = try XCTUnwrap(source.range(
            of: "private func rebuildCentralForWedgedSessionOnce("
        ))
        let rebuildEnd = try XCTUnwrap(source.range(
            of: "private func reconcileCentralUnavailableRecovery(",
            range: rebuildStart.upperBound..<source.endIndex
        ))
        let rebuild = String(source[rebuildStart.lowerBound..<rebuildEnd.lowerBound])
        let drainedRetire = try XCTUnwrap(rebuild.range(
            of: "centralEventFence.retire(\n            retiredCentral,\n            afterDraining: centralDelegateQueue,"
        ))
        XCTAssertTrue(rebuild.contains("synchronizedTeardown: {"))
        let epochInvalidation = try XCTUnwrap(rebuild.range(
            of: "bleCallbackEpochFence.invalidate()"
        ))
        let delegateClear = try XCTUnwrap(rebuild.range(
            of: "retiredCentral.delegate = nil"
        ))
        XCTAssertLessThan(drainedRetire.lowerBound, epochInvalidation.lowerBound)
        XCTAssertLessThan(drainedRetire.lowerBound, delegateClear.lowerBound)

        let suspensionStart = try XCTUnwrap(source.range(
            of: "func suspendForCanonicalRestoreFailure() {"
        ))
        let suspensionEnd = try XCTUnwrap(source.range(
            of: "private func cancelPeripheralConnection(",
            range: suspensionStart.upperBound..<source.endIndex
        ))
        let suspension = String(
            source[suspensionStart.lowerBound..<suspensionEnd.lowerBound]
        )
        let suspensionDrain = try XCTUnwrap(suspension.range(
            of: "afterDraining: centralDelegateQueue"
        ))
        XCTAssertTrue(suspension.contains("synchronizedTeardown: {"))
        XCTAssertTrue(suspension.contains("bleCallbackEpochFence.invalidate()"))
        let stopScan = try XCTUnwrap(suspension.range(of: "central.stopScan()"))
        let suspensionDelegateClear = try XCTUnwrap(suspension.range(
            of: "central.delegate = nil"
        ))
        XCTAssertLessThan(suspensionDrain.lowerBound, stopScan.lowerBound)
        XCTAssertLessThan(
            suspensionDrain.lowerBound,
            suspensionDelegateClear.lowerBound
        )
    }

    func testCentralReplacementRetiresOldUnavailableScheduleBeforeConstruction() throws {
        let source = try managerSource()
        let rebuildStart = try XCTUnwrap(source.range(
            of: "private func rebuildCentralForWedgedSessionOnce("
        ))
        let rebuildEnd = try XCTUnwrap(source.range(
            of: "private func reconcileCentralUnavailableRecovery(",
            range: rebuildStart.upperBound..<source.endIndex
        ))
        let rebuild = String(source[rebuildStart.lowerBound..<rebuildEnd.lowerBound])

        let scheduleInvalidation = try XCTUnwrap(rebuild.range(
            of: "centralUnavailableRecoveryScheduleGeneration &+= 1"
        ))
        let taskCancellation = try XCTUnwrap(rebuild.range(
            of: "centralUnavailableRecoveryTask?.cancel()"
        ))
        let taskClear = try XCTUnwrap(rebuild.range(
            of: "centralUnavailableRecoveryTask = nil"
        ))
        let stateClear = try XCTUnwrap(rebuild.range(
            of: "centralUnavailableObservedState = nil"
        ))
        let timeClear = try XCTUnwrap(rebuild.range(
            of: "centralUnavailableObservedAt = nil"
        ))
        let replacement = try XCTUnwrap(rebuild.range(
            of: "central = CBCentralManager(delegate: self"
        ))

        for retiredState in [
            scheduleInvalidation,
            taskCancellation,
            taskClear,
            stateClear,
            timeClear
        ] {
            XCTAssertLessThan(
                retiredState.lowerBound,
                replacement.lowerBound,
                "replacement callbacks must observe a fresh unavailable-state episode"
            )
        }
    }

    private func managerSource() throws -> String {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        return try String(contentsOf: managerURL, encoding: .utf8)
    }
}
