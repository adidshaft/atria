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

    func testFailedConnectReleaseDropsEvenAConnectingInstance() {
        let retainer = AtriaBLEConnectedPeripheralRetainer()
        let id = UUID()
        let peripheral = StubPeripheral(identifier: id, state: .connecting)
        retainer.retain(peripheral)

        XCTAssertEqual(retainer.releaseDisconnected(peripheralID: id), 0)
        XCTAssertEqual(retainer.releaseAll(peripheralID: id), 1)
        XCTAssertEqual(retainer.count, 0)
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
            source.contains("connectedPeripheralRetainer.releaseAll(")
                && source.contains("peripheralID: peripheral.identifier"),
            "didFailToConnect must release the failed peripheral when no synchronous replacement request owns it"
        )
        XCTAssertTrue(source.contains("connectedPeripheralRetainer.releaseEverything()"),
                      "a discarded central must not leave its peripherals held")
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
