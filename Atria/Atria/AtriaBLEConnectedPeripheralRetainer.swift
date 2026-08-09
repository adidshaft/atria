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
    /// Exact app-side owner of the one outstanding `central.connect` request
    /// for a physical peripheral. CoreBluetooth can continue to report a just-
    /// issued request as `.disconnected`, so neither `CBPeripheral.state` nor
    /// ordinary object retention can make connect issuance single-flight.
    ///
    /// This claim intentionally spans delegate/MainActor/lifecycle lanes. It is
    /// cleared only by a terminal/success callback for the exact object, or by
    /// retiring the owning central. A stale same-UUID callback therefore cannot
    /// clear a newer request and manufacture another queued radio request.
    private var pendingConnectOwnerByPeripheralID: [UUID: ObjectIdentifier] = [:]
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

    /// Atomically retains `peripheral` and grants the sole app-side permission
    /// to call `central.connect(_:)` for its physical identifier.
    ///
    /// Callers must issue the CoreBluetooth request only when this returns
    /// `true`. Repeated claims for the exact object and object-distinct claims
    /// for the same UUID both return `false` while preserving strong retention.
    @discardableResult
    func retainAndClaimConnectRequest(
        _ peripheral: AtriaBLERetainablePeripheral
    ) -> Bool {
        let key = ObjectIdentifier(peripheral)
        let peripheralID = peripheral.identifier
        return lock.withLock {
            retained[key] = peripheral
            if let pendingKey = pendingConnectOwnerByPeripheralID[peripheralID] {
                if pendingKey != key,
                   canonicalByPeripheralID[peripheralID] != key {
                    passiveDuplicateKeys.insert(key)
                }
                return false
            }
            if let canonicalKey = canonicalByPeripheralID[peripheralID],
               canonicalKey != key,
               retained[canonicalKey]?.state == .connected {
                passiveDuplicateKeys.insert(key)
                return false
            }
            pendingConnectOwnerByPeripheralID[peripheralID] = key
            passiveDuplicateKeys.remove(key)
            return true
        }
    }

    /// Adopts a CoreBluetooth-restored `.connecting`/`.disconnecting` object as
    /// the exact owner of the already-existing OS request/transition without
    /// issuing another `central.connect` call.
    ///
    /// Restoration is authoritative for the current process. If a powered-on
    /// precheck published an object-distinct representation first, transfer the
    /// claim to the restored object and keep the earlier representation passive
    /// until its own callback or central retirement.
    @discardableResult
    func adoptRestoredConnectTransition(
        _ peripheral: AtriaBLERetainablePeripheral
    ) -> Bool {
        let key = ObjectIdentifier(peripheral)
        let peripheralID = peripheral.identifier
        return lock.withLock {
            retained[key] = peripheral
            if let canonicalKey = canonicalByPeripheralID[peripheralID],
               canonicalKey != key,
               retained[canonicalKey]?.state == .connected {
                passiveDuplicateKeys.insert(key)
                return false
            }
            if let previousKey = pendingConnectOwnerByPeripheralID[peripheralID],
               previousKey != key,
               retained[previousKey] != nil {
                passiveDuplicateKeys.insert(previousKey)
            }
            pendingConnectOwnerByPeripheralID[peripheralID] = key
            passiveDuplicateKeys.remove(key)
            return true
        }
    }

    /// Atomically adopts a CoreBluetooth-restored already-connected object.
    ///
    /// Unlike an ordinary `didConnect`, restoration is authoritative for the
    /// OS-owned link carried into this process. A powered-on precheck may have
    /// retrieved an object-distinct representation and claimed a connect just
    /// before `willRestoreState` runs. Transfer that pending identity to the
    /// restored object, fence the earlier representation as passive, and
    /// publish the restored object as canonical without issuing or cancelling
    /// a radio request. An already-connected canonical owner still wins.
    func adoptRestoredConnected(
        _ peripheral: AtriaBLERetainablePeripheral
    ) -> ConnectedAdmission {
        let restoredKey = ObjectIdentifier(peripheral)
        let peripheralID = peripheral.identifier
        return lock.withLock {
            retained[restoredKey] = peripheral
            if let canonicalKey = canonicalByPeripheralID[peripheralID],
               canonicalKey != restoredKey,
               retained[canonicalKey]?.state == .connected {
                passiveDuplicateKeys.insert(restoredKey)
                return .retainPassiveDuplicate
            }

            if let pendingKey = pendingConnectOwnerByPeripheralID[peripheralID],
               pendingKey != restoredKey,
               retained[pendingKey] != nil {
                passiveDuplicateKeys.insert(pendingKey)
            }
            pendingConnectOwnerByPeripheralID.removeValue(forKey: peripheralID)

            if let canonicalKey = canonicalByPeripheralID[peripheralID],
               canonicalKey != restoredKey,
               retained[canonicalKey] != nil {
                passiveDuplicateKeys.insert(canonicalKey)
            }
            canonicalByPeripheralID[peripheralID] = restoredKey
            passiveDuplicateKeys.remove(restoredKey)
            return .acceptCanonical
        }
    }

    /// Completes only the request owned by this exact CoreBluetooth object.
    /// A late callback from an object-distinct twin cannot release a newer
    /// pending request for the same physical UUID.
    @discardableResult
    func completeConnectRequest(
        _ peripheral: AtriaBLERetainablePeripheral
    ) -> Bool {
        let key = ObjectIdentifier(peripheral)
        return lock.withLock {
            guard pendingConnectOwnerByPeripheralID[peripheral.identifier]
                    == key else { return false }
            pendingConnectOwnerByPeripheralID.removeValue(
                forKey: peripheral.identifier
            )
            return true
        }
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
            if pendingConnectOwnerByPeripheralID[peripheralID] == key {
                pendingConnectOwnerByPeripheralID.removeValue(
                    forKey: peripheralID
                )
            }
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
        if pendingConnectOwnerByPeripheralID[peripheral.identifier] == key {
            pendingConnectOwnerByPeripheralID.removeValue(
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
        if pendingConnectOwnerByPeripheralID[peripheralID] == callbackKey {
            pendingConnectOwnerByPeripheralID.removeValue(forKey: peripheralID)
        }
        let canonicalKey = canonicalByPeripheralID[peripheralID]
        let canonical = canonicalKey.flatMap { retained[$0] }
        let pendingOwnedByDifferentObject =
            pendingConnectOwnerByPeripheralID[peripheralID].map {
                $0 != callbackKey
            } ?? false
        let admission: ConnectedAdmission
        if pendingOwnedByDifferentObject && canonicalKey == nil {
            admission = .retainPassiveDuplicate
        } else {
            admission = Self.classifyConnectedAdmission(
                callbackIsCanonical: canonicalKey == callbackKey,
                canonicalIsConnected: canonical?.state == .connected
            )
        }
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
        let pendingKey = pendingConnectOwnerByPeripheralID[peripheralID]
        let admission: TerminalAdmission
        if let canonicalKey {
            admission = canonicalKey == callbackKey
                ? .processCanonical
                : .ignorePassiveDuplicate
        } else if let pendingKey {
            admission = pendingKey == callbackKey
                ? .processCanonical
                : .ignorePassiveDuplicate
        } else {
            admission = passiveDuplicateKeys.contains(callbackKey)
                ? .ignorePassiveDuplicate
                : .processUnclaimed
        }
        if admission == .processCanonical {
            canonicalByPeripheralID.removeValue(forKey: peripheralID)
            if pendingKey == callbackKey {
                pendingConnectOwnerByPeripheralID.removeValue(
                    forKey: peripheralID
                )
            }
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
        pendingConnectOwnerByPeripheralID.removeAll()
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

    func hasPendingConnectRequest(peripheralID: UUID) -> Bool {
        lock.withLock {
            pendingConnectOwnerByPeripheralID[peripheralID] != nil
        }
    }

    var pendingConnectCount: Int {
        lock.withLock { pendingConnectOwnerByPeripheralID.count }
    }

    /// Atomically admits a non-destructive same-link transport claim only when
    /// `peripheral` is the sole retained, canonical, already-connected object
    /// and no connect request is outstanding. The claim closure must publish
    /// its transport generation/phase before returning so a connect issuer
    /// cannot enter between validation and publication.
    func claimExclusiveConnectedCanonicalTransport(
        _ peripheral: AtriaBLERetainablePeripheral,
        claim: () -> Bool
    ) -> Bool {
        let key = ObjectIdentifier(peripheral)
        return lock.withLock {
            guard canonicalByPeripheralID[peripheral.identifier] == key,
                  retained[key] != nil,
                  peripheral.state == .connected,
                  pendingConnectOwnerByPeripheralID.isEmpty,
                  retained.count == 1,
                  !passiveDuplicateKeys.contains(key) else {
                return false
            }
            return claim()
        }
    }

    /// Whether a retained object represents a standing realtime connection
    /// interest for any candidate strap identity. Retention is published before
    /// every production `central.connect`, so this remains true during the
    /// CoreBluetooth window where a just-issued request still reports
    /// `.disconnected` and no callback epoch exists yet.
    func hasRetainedConnectInterest(peripheralIDs: Set<UUID>) -> Bool {
        lock.withLock {
            if peripheralIDs.isEmpty { return !retained.isEmpty }
            return retained.values.contains {
                peripheralIDs.contains($0.identifier)
            }
        }
    }

    /// Atomically grants a history transport claim only when no standing
    /// realtime connect is retained for the candidate strap. The claim closure
    /// publishes the history phase while this same lock still excludes every
    /// production retain-before-connect path; a connect issued after unlock
    /// therefore belongs to the already-published history owner rather than
    /// racing it as an unseen realtime request.
    func claimHistoryTransportIfNoRetainedConnect(
        peripheralIDs: Set<UUID>,
        claim: () -> Bool
    ) -> Bool {
        lock.withLock {
            let hasStandingConnect: Bool
            if peripheralIDs.isEmpty {
                hasStandingConnect = !retained.isEmpty
            } else {
                hasStandingConnect = retained.values.contains {
                    peripheralIDs.contains($0.identifier)
                }
            }
            guard !hasStandingConnect else { return false }
            return claim()
        }
    }
}
