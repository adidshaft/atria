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

    func testEveryConnectCallSiteRetainsThePeripheralItConnects() throws {
        let lines = try managerSource().split(separator: "\n", omittingEmptySubsequences: false)
        var unguarded: [Int] = []
        for (index, line) in lines.enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("central.connect(")
                    || text.hasPrefix("self.central.connect(")
                    || text.hasPrefix("callbackCentral.connect(")
            else { continue }
            guard let open = text.firstIndex(of: "("),
                  let comma = text[open...].firstIndex(of: ",") else {
                unguarded.append(index + 1)
                continue
            }
            let argument = text[text.index(after: open)..<comma]
                .trimmingCharacters(in: .whitespaces)
            let guardWindowStart = max(0, index - 24)
            let guardWindow = lines[guardWindowStart..<index].joined(
                separator: "\n"
            )
            if !guardWindow.contains(
                "connectedPeripheralRetainer.retain(\(argument))"
            ) {
                unguarded.append(index + 1)
            }
        }
        XCTAssertTrue(unguarded.isEmpty,
                      "CoreBluetooth connect without an adjacent retain at line(s) \(unguarded); "
                        + "an unreferenced connected peripheral is force-disconnected by CoreBluetooth")
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
