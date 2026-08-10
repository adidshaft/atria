import XCTest
import CoreBluetooth
@testable import Atria

/// 2026-07-26: a 150 s on-device bluetoothd capture recorded six
/// `API MISUSE: Forcing disconnection of unused peripheral` events, each
/// killing a healthy 30 ms link ~1.4 s after it came up and each matching a
/// `reason 722` teardown one-for-one. CoreBluetooth raises that when the app
/// releases its last reference to a *connected* `CBPeripheral`; the teardown
/// bypasses `cancelPeripheralConnection`, which is why the manager's
/// `app_cancel_*` breadcrumbs stayed empty while the link churned.
final class AtriaBLEConnectedPeripheralRetainerTests: XCTestCase {
    private final class StubPeripheral: AtriaBLERetainablePeripheral {
        let identifier: UUID
        var state: CBPeripheralState

        init(identifier: UUID = UUID(), state: CBPeripheralState = .disconnected) {
            self.identifier = identifier
            self.state = state
        }
    }

    func testRetainedConnectedPeripheralSurvivesLosingEveryOtherReference() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        weak var observed: StubPeripheral?

        do {
            let peripheral = StubPeripheral(identifier: id, state: .connected)
            observed = peripheral
            retainer.retain(peripheral)
        }

        XCTAssertNotNil(observed,
                        "a connected peripheral must not deallocate once the connect path has retained it")
        XCTAssertEqual(retainer.retainedCount(peripheralID: id), 1)
    }

    func testStandingDisconnectedConnectAtomicallyBlocksHistoryClaim() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let standing = StubPeripheral(
            identifier: id,
            state: .disconnected
        )
        retainer.retain(standing)

        var claimRan = false
        XCTAssertTrue(retainer.hasRetainedConnectInterest(
            peripheralIDs: [id]
        ))
        XCTAssertFalse(retainer.claimHistoryTransportIfNoRetainedConnect(
            peripheralIDs: [id]
        ) {
            claimRan = true
            return true
        })
        XCTAssertFalse(claimRan)

        XCTAssertTrue(retainer.release(standing))
        XCTAssertTrue(retainer.claimHistoryTransportIfNoRetainedConnect(
            peripheralIDs: [id]
        ) {
            claimRan = true
            return true
        })
        XCTAssertTrue(claimRan)
    }

    func testRetainedConnectingSavedIdentityBlocksHistoryClaim() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let savedID = UUID()
        let standing = StubPeripheral(
            identifier: savedID,
            state: .connecting
        )
        retainer.retain(standing)

        var claimRan = false
        XCTAssertTrue(retainer.hasRetainedConnectInterest(
            peripheralIDs: [savedID]
        ))
        XCTAssertFalse(retainer.claimHistoryTransportIfNoRetainedConnect(
            peripheralIDs: [savedID]
        ) {
            claimRan = true
            return true
        })
        XCTAssertFalse(
            claimRan,
            "the saved strap's retained connecting request owns transport before didConnect"
        )
    }

    func testRetainedConnectingPeripheralBlocksHistoryClaimWithEmptyIdentitySet() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let standing = StubPeripheral(state: .connecting)
        retainer.retain(standing)

        var claimRan = false
        XCTAssertTrue(retainer.hasRetainedConnectInterest(
            peripheralIDs: []
        ))
        XCTAssertFalse(retainer.claimHistoryTransportIfNoRetainedConnect(
            peripheralIDs: []
        ) {
            claimRan = true
            return true
        })
        XCTAssertFalse(
            claimRan,
            "an empty saved/current identity set must fail closed behind any retained connect"
        )
    }

    func testUnretainedConnectedPeripheralIsTheDeallocationThisPrevents() {
        // Guards the test itself: without the retainer the object goes away,
        // which on CoreBluetooth is the forced-disconnect path.
        weak var observed: StubPeripheral?
        do {
            let peripheral = StubPeripheral(state: .connected)
            observed = peripheral
        }
        XCTAssertNil(observed)
    }

    func testDisconnectReleaseKeepsAPeripheralTheFastLaneJustReconnected() {
        // `didDisconnectPeripheral` releases first and the fast lane then
        // re-issues a standing connect on the same object. If the release were
        // unconditional the re-connected peripheral would be dropped and torn
        // straight back down.
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let peripheral = StubPeripheral(identifier: id, state: .disconnected)
        retainer.retain(peripheral)

        peripheral.state = .connecting
        XCTAssertEqual(retainer.releaseDisconnected(peripheralID: id), 0)
        XCTAssertEqual(retainer.retainedCount(peripheralID: id), 1)

        peripheral.state = .connected
        XCTAssertEqual(retainer.releaseDisconnected(peripheralID: id), 0)
        XCTAssertEqual(retainer.retainedCount(peripheralID: id), 1)
    }

    func testDisconnectReleaseDropsAGenuinelyDisconnectedPeripheral() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let peripheral = StubPeripheral(identifier: id, state: .connected)
        retainer.retain(peripheral)

        peripheral.state = .disconnected
        XCTAssertEqual(retainer.releaseDisconnected(peripheralID: id), 1)
        XCTAssertEqual(retainer.retainedCount(peripheralID: id), 0)
        XCTAssertEqual(retainer.count, 0)
    }

    func testDistinctInstancesOfTheSameDeviceAreHeldIndependently() {
        // CoreBluetooth can hand back a different `CBPeripheral` instance for
        // the same device. Keying retention by `identifier` would evict — and
        // therefore deallocate — the live one, reproducing the original defect.
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let stale = StubPeripheral(identifier: id, state: .disconnected)
        let live = StubPeripheral(identifier: id, state: .connected)

        retainer.retain(stale)
        retainer.retain(live)
        XCTAssertEqual(retainer.retainedCount(peripheralID: id), 2)

        XCTAssertEqual(retainer.releaseDisconnected(peripheralID: id), 1)
        XCTAssertEqual(retainer.retainedCount(peripheralID: id), 1,
                       "the connected instance must outlive its stale twin")
    }

    func testRetainingTheSameObjectTwiceHoldsOneEntry() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let peripheral = StubPeripheral(state: .connected)
        retainer.retain(peripheral)
        retainer.retain(peripheral)
        XCTAssertEqual(retainer.count, 1)
    }

    func testPendingConnectClaimIsSingleFlightForExactObject() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let peripheral = StubPeripheral(state: .disconnected)

        XCTAssertTrue(retainer.retainAndClaimConnectRequest(peripheral))
        XCTAssertFalse(retainer.retainAndClaimConnectRequest(peripheral))
        XCTAssertEqual(retainer.pendingConnectCount, 1)
        XCTAssertTrue(retainer.hasPendingConnectRequest(
            peripheralID: peripheral.identifier
        ))

        XCTAssertTrue(retainer.completeConnectRequest(peripheral))
        XCTAssertFalse(retainer.completeConnectRequest(peripheral))
        XCTAssertEqual(retainer.pendingConnectCount, 0)
        XCTAssertTrue(
            retainer.retainAndClaimConnectRequest(peripheral),
            "an exact terminal/success completion must permit the next legitimate reconnect"
        )
    }

    func testObjectDistinctClaimAndCallbackCannotClearExactPendingOwner() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let owner = StubPeripheral(identifier: id, state: .disconnected)
        let twin = StubPeripheral(identifier: id, state: .disconnected)

        XCTAssertTrue(retainer.retainAndClaimConnectRequest(owner))
        XCTAssertFalse(retainer.retainAndClaimConnectRequest(twin))
        XCTAssertFalse(retainer.completeConnectRequest(twin))
        XCTAssertTrue(retainer.hasPendingConnectRequest(peripheralID: id))
        XCTAssertEqual(
            retainer.beginTerminalCallback(twin),
            .ignorePassiveDuplicate,
            "a stale same-UUID terminal callback must not release the newer standing request"
        )
        XCTAssertTrue(retainer.hasPendingConnectRequest(peripheralID: id))
        XCTAssertTrue(retainer.completeConnectRequest(owner))
        XCTAssertFalse(retainer.hasPendingConnectRequest(peripheralID: id))
    }

    func testRestoredTransitionTransfersPendingAuthorityToExactObject() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let poweredOnRepresentation = StubPeripheral(
            identifier: id,
            state: .disconnected
        )
        let restoredRepresentation = StubPeripheral(
            identifier: id,
            state: .connecting
        )

        XCTAssertTrue(retainer.retainAndClaimConnectRequest(
            poweredOnRepresentation
        ))
        XCTAssertTrue(retainer.adoptRestoredConnectTransition(
            restoredRepresentation
        ))
        XCTAssertFalse(retainer.completeConnectRequest(
            poweredOnRepresentation
        ))
        XCTAssertTrue(retainer.hasPendingConnectRequest(peripheralID: id))
        XCTAssertTrue(retainer.completeConnectRequest(
            restoredRepresentation
        ))
        XCTAssertFalse(retainer.hasPendingConnectRequest(peripheralID: id))
    }

    func testRestoredTransitionPendingClaimIsExactObjectScoped() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let restoredOwner = StubPeripheral(
            identifier: id,
            state: .connecting
        )
        let sameUUIDTwin = StubPeripheral(
            identifier: id,
            state: .connecting
        )

        XCTAssertTrue(retainer.adoptRestoredConnectTransition(restoredOwner))
        XCTAssertTrue(retainer.ownsPendingConnectRequest(restoredOwner))
        XCTAssertFalse(retainer.ownsPendingConnectRequest(sameUUIDTwin))

        XCTAssertTrue(retainer.release(restoredOwner))
        XCTAssertFalse(retainer.ownsPendingConnectRequest(restoredOwner))
        XCTAssertEqual(retainer.pendingConnectCount, 0)
    }

    func testRestoredConnectedObjectSupersedesObjectDistinctPendingPrecheck() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let poweredOnRepresentation = StubPeripheral(
            identifier: id,
            state: .disconnected
        )
        let restoredRepresentation = StubPeripheral(
            identifier: id,
            state: .connected
        )

        XCTAssertTrue(retainer.retainAndClaimConnectRequest(
            poweredOnRepresentation
        ))
        XCTAssertEqual(
            retainer.adoptRestoredConnected(restoredRepresentation),
            .acceptCanonical
        )
        XCTAssertFalse(retainer.hasPendingConnectRequest(peripheralID: id))
        XCTAssertEqual(
            retainer.beginTerminalCallback(poweredOnRepresentation),
            .ignorePassiveDuplicate,
            "the superseded precheck object must not run a second recovery lane"
        )
        XCTAssertEqual(
            retainer.beginTerminalCallback(restoredRepresentation),
            .processCanonical,
            "the already-connected restored object must own the live link"
        )
    }

    func testRestoredConnectedObjectDoesNotDisplaceLiveCanonicalOwner() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let canonical = StubPeripheral(identifier: id, state: .connected)
        let restoredTwin = StubPeripheral(identifier: id, state: .connected)

        XCTAssertEqual(retainer.admitConnected(canonical), .acceptCanonical)
        XCTAssertEqual(
            retainer.adoptRestoredConnected(restoredTwin),
            .retainPassiveDuplicate
        )
        XCTAssertEqual(
            retainer.beginTerminalCallback(restoredTwin),
            .ignorePassiveDuplicate
        )
        XCTAssertEqual(
            retainer.beginTerminalCallback(canonical),
            .processCanonical
        )
    }

    func testTerminalCallbackClearsExactPendingOwnerBeforeReconnectClaim() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let peripheral = StubPeripheral(state: .disconnected)

        XCTAssertTrue(retainer.retainAndClaimConnectRequest(peripheral))
        XCTAssertEqual(
            retainer.beginTerminalCallback(peripheral),
            .processCanonical
        )
        XCTAssertFalse(retainer.hasPendingConnectRequest(
            peripheralID: peripheral.identifier
        ))
        XCTAssertTrue(retainer.retainAndClaimConnectRequest(peripheral))
    }

    func testConcurrentDelegateAndMainActorClaimsIssueExactlyOnce() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let peripheral = StubPeripheral(state: .disconnected)
        let resultLock = NSLock()
        var admitted = 0

        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            if retainer.retainAndClaimConnectRequest(peripheral) {
                resultLock.withLock { admitted += 1 }
            }
        }

        XCTAssertEqual(admitted, 1)
        XCTAssertEqual(retainer.pendingConnectCount, 1)
        XCTAssertEqual(retainer.retainedCount(
            peripheralID: peripheral.identifier
        ), 1)
    }

    func testCentralRetirementClearsPendingClaims() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let peripheral = StubPeripheral(state: .disconnected)
        XCTAssertTrue(retainer.retainAndClaimConnectRequest(peripheral))

        XCTAssertEqual(retainer.releaseEverything(), 1)
        XCTAssertEqual(retainer.pendingConnectCount, 0)
        XCTAssertTrue(retainer.retainAndClaimConnectRequest(peripheral))
    }

    func testExclusiveConnectedCanonicalClaimRejectsPendingAndDuplicates() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let canonical = StubPeripheral(identifier: id, state: .connected)
        XCTAssertEqual(retainer.admitConnected(canonical), .acceptCanonical)

        var claimCount = 0
        XCTAssertTrue(retainer.claimExclusiveConnectedCanonicalTransport(
            canonical
        ) {
            claimCount += 1
            return true
        })
        XCTAssertEqual(claimCount, 1)

        XCTAssertTrue(retainer.retainAndClaimConnectRequest(canonical))
        XCTAssertFalse(retainer.claimExclusiveConnectedCanonicalTransport(
            canonical
        ) {
            claimCount += 1
            return true
        })
        XCTAssertEqual(claimCount, 1)
        XCTAssertTrue(retainer.completeConnectRequest(canonical))

        let duplicate = StubPeripheral(identifier: id, state: .connected)
        retainer.retainPassiveDuplicate(duplicate)
        XCTAssertFalse(retainer.claimExclusiveConnectedCanonicalTransport(
            canonical
        ) {
            claimCount += 1
            return true
        })
        XCTAssertEqual(claimCount, 1)
    }

    func testManagerRoutesEveryProductionConnectThroughSingleFlightGateway() throws {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)

        XCTAssertEqual(
            source.components(separatedBy: ".connect(").count - 1,
            3,
            "only the gateway call plus two explanatory comments may mention raw CoreBluetooth connect syntax"
        )
        let gatewayStart = try XCTUnwrap(source.range(
            of: "nonisolated private func issueSingleFlightConnect("
        ))
        let gatewayEnd = try XCTUnwrap(source.range(
            of: "/// A CoreBluetooth-disconnected peripheral",
            range: gatewayStart.upperBound..<source.endIndex
        ))
        let gateway = String(
            source[gatewayStart.lowerBound..<gatewayEnd.lowerBound]
        )
        XCTAssertTrue(gateway.contains("retainAndClaimConnectRequest"))
        XCTAssertEqual(
            gateway.components(separatedBy: ".connect(").count - 1,
            1,
            "the audited gateway must be the sole radio issuer"
        )

        let restore = try XCTUnwrap(source.range(
            of: "nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any])"
        ))
        let discover = try XCTUnwrap(source.range(
            of: "didDiscover peripheral: CBPeripheral",
            range: restore.upperBound..<source.endIndex
        ))
        let restoreBody = String(source[restore.lowerBound..<discover.lowerBound])
        XCTAssertTrue(restoreBody.contains("adoptRestoredConnectTransition"))
        XCTAssertTrue(restoreBody.contains("adoptRestoredConnected"))
        let firstDeferredTask = try XCTUnwrap(
            restoreBody.range(of: "Task { @MainActor in")
        )
        XCTAssertTrue(
            restoreBody[..<firstDeferredTask.lowerBound].contains(
                "adoptRestoredConnectTransition"
            ),
            "restored pending authority must publish before deferred lifecycle work"
        )
        XCTAssertTrue(
            restoreBody[..<firstDeferredTask.lowerBound].contains(
                "adoptRestoredConnected"
            ),
            "restored connected authority must replace a pending precheck before deferred work"
        )

        let didConnect = try XCTUnwrap(source.range(
            of: "didConnect peripheral: CBPeripheral"
        ))
        let didDisconnect = try XCTUnwrap(source.range(
            of: "didDisconnectPeripheral peripheral: CBPeripheral",
            range: didConnect.upperBound..<source.endIndex
        ))
        let didConnectBody = String(
            source[didConnect.lowerBound..<didDisconnect.lowerBound]
        )
        XCTAssertLessThan(
            try XCTUnwrap(didConnectBody.range(
                of: "completeConnectRequest(peripheral)"
            )).lowerBound,
            try XCTUnwrap(didConnectBody.range(
                of: "duplicate_connect_ignored"
            )).lowerBound
        )
    }

    func testFailedConnectReleaseDropsTheExactConnectingInstance() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let peripheral = StubPeripheral(identifier: id, state: .connecting)
        retainer.retain(peripheral)

        XCTAssertEqual(retainer.releaseDisconnected(peripheralID: id), 0)
        XCTAssertTrue(retainer.release(peripheral))
        XCTAssertEqual(retainer.count, 0)
    }

    func testFailedObjectReleasePreservesLiveTwinWithTheSameDeviceIdentifier() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        var failed: StubPeripheral? = StubPeripheral(
            identifier: id,
            state: .connecting
        )
        weak var observedLive: StubPeripheral?

        retainer.retain(failed!)
        do {
            let live = StubPeripheral(identifier: id, state: .connected)
            observedLive = live
            retainer.retain(live)
        }
        XCTAssertEqual(retainer.retainedCount(peripheralID: id), 2)

        XCTAssertTrue(retainer.release(failed!))
        failed = nil

        XCTAssertNotNil(
            observedLive,
            "releasing a stale same-UUID object must not deallocate the live link owner"
        )
        XCTAssertEqual(retainer.retainedCount(peripheralID: id), 1)
    }

    func testCanonicalAdmissionRetainsButDoesNotPromoteConnectedDuplicate() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let canonical = StubPeripheral(identifier: id, state: .connected)
        let duplicate = StubPeripheral(identifier: id, state: .connected)

        XCTAssertEqual(
            retainer.admitConnected(canonical),
            .acceptCanonical
        )
        XCTAssertEqual(
            retainer.admitConnected(duplicate),
            .retainPassiveDuplicate
        )
        XCTAssertEqual(
            retainer.admitConnected(canonical),
            .acceptCanonical,
            "a repeated callback for the canonical object remains admissible"
        )
        XCTAssertEqual(retainer.retainedCount(peripheralID: id), 2)
    }

    func testSuccessfulTwinReplacesCanonicalThatIsNoLongerConnected() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let former = StubPeripheral(identifier: id, state: .connected)
        let successful = StubPeripheral(identifier: id, state: .connected)

        XCTAssertEqual(retainer.admitConnected(former), .acceptCanonical)
        former.state = .connecting
        XCTAssertEqual(
            retainer.admitConnected(successful),
            .acceptCanonical,
            "a merely connecting former owner must not suppress didConnect"
        )
    }

    func testPassiveDuplicateTerminalIsIgnoredWhileCanonicalIsActive() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let canonical = StubPeripheral(identifier: id, state: .connected)
        let duplicate = StubPeripheral(identifier: id, state: .connected)

        XCTAssertEqual(retainer.admitConnected(canonical), .acceptCanonical)
        XCTAssertEqual(
            retainer.admitConnected(duplicate),
            .retainPassiveDuplicate
        )
        duplicate.state = .disconnected

        XCTAssertEqual(
            retainer.beginTerminalCallback(duplicate),
            .ignorePassiveDuplicate
        )
        XCTAssertTrue(retainer.release(duplicate))
        XCTAssertEqual(retainer.retainedCount(peripheralID: id), 1)
    }

    func testPassiveDuplicateTerminalArrivingFirstAfterSharedLinkLossIsIgnored() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let canonical = StubPeripheral(identifier: id, state: .connected)
        let duplicate = StubPeripheral(identifier: id, state: .connected)

        XCTAssertEqual(retainer.admitConnected(canonical), .acceptCanonical)
        XCTAssertEqual(
            retainer.admitConnected(duplicate),
            .retainPassiveDuplicate
        )

        // CoreBluetooth may update both object-distinct representations before
        // delivering either terminal callback. Callback ordering must not let
        // the passive representation steal or clear canonical ownership.
        canonical.state = .disconnected
        duplicate.state = .disconnected
        XCTAssertEqual(
            retainer.beginTerminalCallback(duplicate),
            .ignorePassiveDuplicate
        )
        XCTAssertTrue(retainer.release(duplicate))
        XCTAssertEqual(
            retainer.beginTerminalCallback(canonical),
            .processCanonical
        )
    }

    func testCanonicalTerminalProcessesEvenWhilePassiveDuplicateIsActive() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let canonical = StubPeripheral(identifier: id, state: .connected)
        let duplicate = StubPeripheral(identifier: id, state: .connected)

        XCTAssertEqual(retainer.admitConnected(canonical), .acceptCanonical)
        XCTAssertEqual(
            retainer.admitConnected(duplicate),
            .retainPassiveDuplicate
        )
        canonical.state = .disconnected

        XCTAssertEqual(
            retainer.beginTerminalCallback(canonical),
            .processCanonical,
            "a passive twin must never suppress the manager-owned link's failure"
        )
        XCTAssertEqual(
            retainer.admitConnected(duplicate),
            .acceptCanonical,
            "after the canonical terminal boundary a successful twin can claim ownership"
        )
    }

    func testPassiveDuplicateTerminalArrivingAfterCanonicalIsStillIgnored() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let canonical = StubPeripheral(identifier: id, state: .connected)
        let duplicate = StubPeripheral(identifier: id, state: .connected)

        XCTAssertEqual(retainer.admitConnected(canonical), .acceptCanonical)
        XCTAssertEqual(
            retainer.admitConnected(duplicate),
            .retainPassiveDuplicate
        )
        canonical.state = .disconnected
        duplicate.state = .disconnected

        XCTAssertEqual(
            retainer.beginTerminalCallback(canonical),
            .processCanonical
        )
        XCTAssertEqual(
            retainer.releaseDisconnected(peripheralID: id),
            1,
            "the canonical object may be released, but the passive twin stays fenced until its callback"
        )
        XCTAssertEqual(
            retainer.beginTerminalCallback(duplicate),
            .ignorePassiveDuplicate
        )
        XCTAssertTrue(retainer.release(duplicate))
        XCTAssertEqual(retainer.count, 0)
    }

    func testExplicitRestorationDuplicateFenceIgnoresDisconnectedTwin() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let canonical = StubPeripheral(identifier: id, state: .connected)
        let restoredTwin = StubPeripheral(
            identifier: id,
            state: .disconnected
        )

        XCTAssertEqual(retainer.admitConnected(canonical), .acceptCanonical)
        retainer.retainPassiveDuplicate(restoredTwin)
        XCTAssertEqual(
            retainer.beginTerminalCallback(restoredTwin),
            .ignorePassiveDuplicate
        )
        XCTAssertTrue(retainer.release(restoredTwin))
    }

    func testCanonicalFailureProcessesWhilePassiveTwinIsConnecting() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let canonical = StubPeripheral(identifier: id, state: .connected)
        let passive = StubPeripheral(identifier: id, state: .connecting)

        XCTAssertEqual(retainer.admitConnected(canonical), .acceptCanonical)
        retainer.retain(passive)
        canonical.state = .disconnected

        XCTAssertEqual(
            retainer.beginTerminalCallback(canonical),
            .processCanonical
        )
    }

    func testReleaseEverythingClearsAcrossDevices() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        retainer.retain(StubPeripheral(state: .connected))
        retainer.retain(StubPeripheral(state: .connected))
        XCTAssertEqual(retainer.releaseEverything(), 2)
        XCTAssertEqual(retainer.count, 0)
    }

    func testReleaseOnlyTouchesTheNamedDevice() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let strapID = UUID()
        let otherID = UUID()
        retainer.retain(StubPeripheral(identifier: strapID, state: .disconnected))
        retainer.retain(StubPeripheral(identifier: otherID, state: .disconnected))

        XCTAssertEqual(retainer.releaseDisconnected(peripheralID: strapID), 1)
        XCTAssertEqual(retainer.retainedCount(peripheralID: otherID), 1)
    }

    // MARK: - Structural

    private func managerSource() throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func testEveryConnectCallSiteUsesAtomicRetainAndPendingClaim() throws {
        let source = try managerSource()
        let gatewayStart = try XCTUnwrap(source.range(
            of: "nonisolated private func issueSingleFlightConnect("
        ))
        let gatewayEnd = try XCTUnwrap(source.range(
            of: "/// A CoreBluetooth-disconnected peripheral",
            range: gatewayStart.upperBound..<source.endIndex
        ))
        let gateway = String(
            source[gatewayStart.lowerBound..<gatewayEnd.lowerBound]
        )
        XCTAssertTrue(gateway.contains("retainAndClaimConnectRequest(target)"))
        XCTAssertEqual(
            gateway.components(separatedBy: ".connect(").count - 1,
            1,
            "the only raw CoreBluetooth connect must sit behind the atomic retain-and-claim"
        )
        XCTAssertEqual(
            source.components(separatedBy: ".connect(").count - 1,
            3,
            "no production path may bypass the gateway (two occurrences are explanatory comments)"
        )
    }

    func testDisconnectAndFailurePathsReleaseWhatTheyStoppedConnecting() throws {
        let source = try managerSource()
        XCTAssertTrue(
            source.contains("connectedPeripheralRetainer.releaseDisconnected(peripheralID: peripheral.identifier)"),
            "didDisconnectPeripheral must release the peripheral it just lost"
        )
        XCTAssertTrue(
            source.contains(
                "connectedPeripheralRetainer.release(peripheral)"
            ),
            "didFailToConnect must release only its exact failed object"
        )
        XCTAssertTrue(
            source.contains("connectedPeripheralRetainer.release(candidate)"),
            "restoration rejection must release only each exact rejected object"
        )
        XCTAssertFalse(
            source.contains("connectedPeripheralRetainer.releaseAll("),
            "per-callback UUID-wide release can deallocate a live same-UUID twin"
        )
        XCTAssertTrue(source.contains("connectedPeripheralRetainer.releaseEverything()"),
                      "a discarded central must not leave its peripherals held")
    }

    func testStaleTwinFencePrecedesSharedTerminalCallbackMutation() throws {
        let source = try managerSource()
        let callbacks = [
            "didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {",
            "didFailToConnect peripheral: CBPeripheral,"
        ]
        let orderedGuardTokens = [
            "connectedPeripheralRetainer.beginTerminalCallback(peripheral)",
            "if terminalAdmission == .ignorePassiveDuplicate",
            "peripheral.delegate = nil",
            "connectedPeripheralRetainer.release(peripheral)",
            "AtriaDebugLog(",
            "return"
        ]

        for callback in callbacks {
            let callbackRange = try XCTUnwrap(
                source.range(of: callback),
                "missing terminal callback \(callback)"
            )
            let firstSharedMutation = try XCTUnwrap(
                source.range(
                    of: "proprietaryFrameReassembler.reset()",
                    range: callbackRange.upperBound..<source.endIndex
                ),
                "missing first shared mutation after \(callback)"
            )
            let guardPrefix = String(
                source[callbackRange.upperBound..<firstSharedMutation.lowerBound]
            )
            var cursor = guardPrefix.startIndex
            for token in orderedGuardTokens {
                let tokenRange = try XCTUnwrap(
                    guardPrefix.range(
                        of: token,
                        range: cursor..<guardPrefix.endIndex
                    ),
                    "\(callback) must perform \(token) before shared terminal-state mutation"
                )
                cursor = tokenRange.upperBound
            }
        }
    }

    func testConnectedCallbackAdmissionPrecedesEverySharedMutation() throws {
        let source = try managerSource()
        let callbackRange = try XCTUnwrap(
            source.range(
                of: "didConnect peripheral: CBPeripheral) {"
            )
        )
        let firstSharedMutation = try XCTUnwrap(
            source.range(
                of: "proprietaryFrameReassembler.reset()",
                range: callbackRange.upperBound..<source.endIndex
            )
        )
        let admissionPrefix = String(
            source[callbackRange.upperBound..<firstSharedMutation.lowerBound]
        )
        let orderedTokens = [
            "connectedPeripheralRetainer.admitConnected(peripheral)",
            "if connectedCallbackAdmission == .retainPassiveDuplicate",
            "AtriaDebugLog(",
            "return"
        ]
        var cursor = admissionPrefix.startIndex
        for token in orderedTokens {
            let tokenRange = try XCTUnwrap(
                admissionPrefix.range(
                    of: token,
                    range: cursor..<admissionPrefix.endIndex
                ),
                "didConnect must perform \(token) before shared-state mutation"
            )
            cursor = tokenRange.upperBound
        }
        XCTAssertFalse(
            admissionPrefix.contains("cancelPeripheralConnection"),
            "duplicate admission must not cancel a potentially shared physical link"
        )
        XCTAssertFalse(
            admissionPrefix.contains("peripheral.delegate = nil"),
            "duplicate admission must not mutate delegate ownership before identity is settled"
        )
    }

    func testRetainerIsHeldStronglyAndNonisolatedByTheManager() throws {
        let source = try managerSource()
        XCTAssertTrue(
            source.contains("private nonisolated let connectedPeripheralRetainer = AtriaBLEConnectedPeripheralRetainer()"),
            "the retainer is touched from nonisolated CoreBluetooth callbacks"
        )
    }

    func testObsoleteRestorationCleanersReleaseTheirCentralSessions() throws {
        let source = try managerSource()
        XCTAssertTrue(source.contains("private var central: CBCentralManager?"))
        XCTAssertTrue(source.contains("self.central = nil"),
                      "an obsolete restoration namespace must not retain its XPC central for the process lifetime")
        XCTAssertTrue(source.contains("scheduleRelease(after: peripherals.isEmpty ? 0.5 : 2)"),
                      "restored peripherals need a finite cancellation grace period")
        XCTAssertTrue(source.contains("legacyCentralCleaners.removeAll"),
                      "completed one-shot cleaners must leave the manager's strong-retention array")
    }
}
