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
    enum ConnectedAdmission: Equatable {
        case acceptCanonical
        case retainPassiveDuplicate
    }

    enum TerminalAdmission: Equatable {
        case processCanonical
        case processUnclaimed
        case ignorePassiveDuplicate
    }

    private let lock = NSLock()
    private var retained: [ObjectIdentifier: AtriaBLERetainablePeripheral] = [:]
    private var canonicalByPeripheralID: [UUID: ObjectIdentifier] = [:]
    private var passiveDuplicateKeys: Set<ObjectIdentifier> = []

    static func classifyConnectedAdmission(
        callbackIsCanonical: Bool,
        canonicalIsConnected: Bool
    ) -> ConnectedAdmission {
        callbackIsCanonical || !canonicalIsConnected
            ? .acceptCanonical
            : .retainPassiveDuplicate
    }

    static func classifyTerminalAdmission(
        hasCanonical: Bool,
        callbackIsCanonical: Bool,
        callbackIsKnownPassiveDuplicate: Bool
    ) -> TerminalAdmission {
        if hasCanonical && callbackIsCanonical {
            return .processCanonical
        }
        if callbackIsKnownPassiveDuplicate || hasCanonical {
            return .ignorePassiveDuplicate
        }
        return .processUnclaimed
    }

    /// Hold `peripheral` until it is known to be disconnected. Safe to call
    /// repeatedly for the same object; re-retaining is a no-op.
    func retain(_ peripheral: AtriaBLERetainablePeripheral) {
        lock.lock()
        retained[ObjectIdentifier(peripheral)] = peripheral
        lock.unlock()
    }

    /// Retain an object-distinct representation that is already known to be a
    /// non-owning copy of the same physical peripheral.
    ///
    /// CoreBluetooth restoration can return more than one object for the saved
    /// UUID. Cancelling one may tear down the shared physical link, while
    /// treating its later terminal callback as unclaimed can run recovery
    /// twice. Keep the exact object fenced until its own callback releases it.
    func retainPassiveDuplicate(
        _ peripheral: AtriaBLERetainablePeripheral
    ) {
        let key = ObjectIdentifier(peripheral)
        lock.lock()
        retained[key] = peripheral
        if canonicalByPeripheralID[peripheral.identifier] != key {
            passiveDuplicateKeys.insert(key)
        }
        lock.unlock()
    }

    /// Drop every ordinary held instance for `peripheralID` that CoreBluetooth
    /// already reports as disconnected.
    ///
    /// Instances still in `.connected`/`.connecting` are deliberately kept: a
    /// reconnect fast lane may have re-issued a standing connect on the same
    /// object inside the disconnect callback, and releasing it there would
    /// recreate the exact deallocation this type exists to prevent. Passive
    /// same-UUID duplicates are also held until their own terminal callback so
    /// their identity fence survives either callback ordering.
    @discardableResult
    func releaseDisconnected(peripheralID: UUID) -> Int {
        lock.lock()
        let doomed = retained.filter {
            $0.value.identifier == peripheralID
                && $0.value.state == .disconnected
                && !passiveDuplicateKeys.contains($0.key)
        }
        for key in doomed.keys {
            retained.removeValue(forKey: key)
        }
        if let canonicalKey = canonicalByPeripheralID[peripheralID],
           doomed[canonicalKey] != nil {
            canonicalByPeripheralID.removeValue(forKey: peripheralID)
        }
        lock.unlock()
        return doomed.count
    }

    /// Drop this exact CoreBluetooth object.
    ///
    /// A failed or rejected callback can arrive for a stale object while a
    /// distinct instance with the same device identifier owns the current
    /// link. Releasing by UUID here would drop that live twin and recreate the
    /// forced-deallocation disconnect this retainer prevents.
    @discardableResult
    func release(_ peripheral: AtriaBLERetainablePeripheral) -> Bool {
        let key = ObjectIdentifier(peripheral)
        lock.lock()
        let removed = retained.removeValue(forKey: key)
        passiveDuplicateKeys.remove(key)
        if canonicalByPeripheralID[peripheral.identifier] == key {
            canonicalByPeripheralID.removeValue(
                forKey: peripheral.identifier
            )
        }
        lock.unlock()
        return removed != nil
    }

    /// Atomically retain and admit a successful connected callback.
    ///
    /// Only an explicitly admitted object is canonical. A passive duplicate
    /// cannot later make the canonical object's terminal callback look stale.
    /// If the previous canonical is no longer connected, the successful
    /// callback safely takes ownership.
    func admitConnected(
        _ peripheral: AtriaBLERetainablePeripheral
    ) -> ConnectedAdmission {
        let callbackKey = ObjectIdentifier(peripheral)
        let peripheralID = peripheral.identifier
        lock.lock()
        retained[callbackKey] = peripheral
        let canonicalKey = canonicalByPeripheralID[peripheralID]
        let canonical = canonicalKey.flatMap { retained[$0] }
        let admission = Self.classifyConnectedAdmission(
            callbackIsCanonical: canonicalKey == callbackKey,
            canonicalIsConnected: canonical?.state == .connected
        )
        if admission == .acceptCanonical {
            if let canonicalKey,
               canonicalKey != callbackKey,
               retained[canonicalKey] != nil {
                passiveDuplicateKeys.insert(canonicalKey)
            }
            canonicalByPeripheralID[peripheralID] = callbackKey
            passiveDuplicateKeys.remove(callbackKey)
        } else {
            passiveDuplicateKeys.insert(callbackKey)
        }
        lock.unlock()
        return admission
    }

    /// Classify a terminal callback against the explicitly admitted object.
    ///
    /// A canonical terminal callback always processes and clears its claim.
    /// While that explicit claim exists, every other same-UUID object's
    /// terminal callback is passive and ignored regardless of its sampled
    /// CoreBluetooth state. CoreBluetooth can mark both object-distinct twins
    /// disconnected before delivering either callback; consulting state here
    /// would let the passive callback run recovery. Passive identity remains
    /// fenced until its own callback is released, including when the canonical
    /// callback happened first and already cleared the canonical claim.
    func beginTerminalCallback(
        _ peripheral: AtriaBLERetainablePeripheral
    ) -> TerminalAdmission {
        let callbackKey = ObjectIdentifier(peripheral)
        let peripheralID = peripheral.identifier
        lock.lock()
        let canonicalKey = canonicalByPeripheralID[peripheralID]
        let hasCanonical = canonicalKey != nil
        let admission = Self.classifyTerminalAdmission(
            hasCanonical: hasCanonical,
            callbackIsCanonical: canonicalKey == callbackKey,
            callbackIsKnownPassiveDuplicate:
                passiveDuplicateKeys.contains(callbackKey)
        )
        if admission == .processCanonical || !hasCanonical {
            canonicalByPeripheralID.removeValue(forKey: peripheralID)
        }
        lock.unlock()
        return admission
    }

    /// Drop everything. The owning central is being discarded, so its
    /// peripherals cannot be reconnected through it anyway.
    @discardableResult
    func releaseEverything() -> Int {
        lock.lock()
        let count = retained.count
        retained.removeAll()
        canonicalByPeripheralID.removeAll()
        passiveDuplicateKeys.removeAll()
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
