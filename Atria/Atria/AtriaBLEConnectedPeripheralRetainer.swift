import Foundation
import CoreBluetooth

/// Keeps a strong reference to every `CBPeripheral` that has an outstanding
/// `central.connect(_:)` request.
///
/// CoreBluetooth does not retain a peripheral on the app's behalf. When the
/// last app-side reference to a *connected* `CBPeripheral` goes away, the
/// framework logs
///
///     API MISUSE: Forcing disconnection of unused peripheral.
///     Did you forget to cancel the connection?
///
/// and tears the live link down. That path never reaches
/// `cancelPeripheralConnection`, so it leaves no app-owned cancellation marker
/// and no `app_cancel_*` breadcrumb — the disconnect looks like it came from
/// the radio.
///
/// 2026-07-26, measured on device: a 150 s bluetoothd capture held 6 of these
/// forced disconnects, each landing ~1.4 s into an otherwise healthy 30 ms
/// link, and each matching a `reason 722` teardown exactly. The reconnect fast
/// lane in `didDisconnectPeripheral` issues `central.connect` on the callback's
/// peripheral without adopting it into `self.peripheral`, so when a later
/// MainActor path reassigned that property the just-connected object was
/// deallocated mid-link.
///
/// Retention is keyed by object identity, not by `identifier`: CoreBluetooth
/// may hand back a distinct `CBPeripheral` instance for the same device, and
/// keying by UUID would evict — and therefore deallocate — the live one.
///
/// The retainer works through `AtriaBLERetainablePeripheral` rather than
/// `CBPeripheral` directly so its release rules can be exercised in tests —
/// `CBPeripheral` has no public initializer.
protocol AtriaBLERetainablePeripheral: AnyObject {
    var identifier: UUID { get }
    var state: CBPeripheralState { get }
}

extension CBPeripheral: AtriaBLERetainablePeripheral {}

final class AtriaBLEConnectedPeripheralRetainer: @unchecked Sendable {
    private let lock = NSLock()
    private var retained: [ObjectIdentifier: AtriaBLERetainablePeripheral] = [:]

    /// Hold `peripheral` until it is known to be disconnected. Safe to call
    /// repeatedly for the same object; re-retaining is a no-op.
    func retain(_ peripheral: AtriaBLERetainablePeripheral) {
        lock.lock()
        retained[ObjectIdentifier(peripheral)] = peripheral
        lock.unlock()
    }

    /// Drop every held instance for `peripheralID` that CoreBluetooth already
    /// reports as disconnected.
    ///
    /// Instances still in `.connected`/`.connecting` are deliberately kept: a
    /// reconnect fast lane may have re-issued a standing connect on the same
    /// object inside the disconnect callback, and releasing it there would
    /// recreate the exact deallocation this type exists to prevent.
    @discardableResult
    func releaseDisconnected(peripheralID: UUID) -> Int {
        lock.lock()
        let doomed = retained.filter {
            $0.value.identifier == peripheralID && $0.value.state == .disconnected
        }
        for key in doomed.keys {
            retained.removeValue(forKey: key)
        }
        lock.unlock()
        return doomed.count
    }

    /// Drop every held instance for `peripheralID` regardless of state. Used
    /// where the app is deliberately giving up the link (failed connect, or a
    /// central that is being replaced wholesale).
    @discardableResult
    func releaseAll(peripheralID: UUID) -> Int {
        lock.lock()
        let doomed = retained.filter { $0.value.identifier == peripheralID }
        for key in doomed.keys {
            retained.removeValue(forKey: key)
        }
        lock.unlock()
        return doomed.count
    }

    /// Drop everything. The owning central is being discarded, so its
    /// peripherals cannot be reconnected through it anyway.
    @discardableResult
    func releaseEverything() -> Int {
        lock.lock()
        let count = retained.count
        retained.removeAll()
        lock.unlock()
        return count
    }

    var count: Int {
        lock.lock()
        let value = retained.count
        lock.unlock()
        return value
    }

    /// Number of held instances for `peripheralID`, for diagnostics.
    func retainedCount(peripheralID: UUID) -> Int {
        lock.lock()
        let value = retained.values.filter { $0.identifier == peripheralID }.count
        lock.unlock()
        return value
    }
}
