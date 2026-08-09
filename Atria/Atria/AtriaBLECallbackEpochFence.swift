import Foundation

/// Rejects work enqueued by a CoreBluetooth callback after its connection has
/// died. Delegate entry captures the returned epoch synchronously; delayed
/// main-actor work must still match both that epoch and the active peripheral.
///
/// CoreBluetooth callbacks arrive on a private delegate queue while repair and
/// lifecycle work also touches this state from MainActor. Keep the complete
/// epoch tuple and the powered-on retry markers behind one lock so callers can
/// never observe an epoch from one connection paired with another peripheral.
final class AtriaBLECallbackEpochFence: @unchecked Sendable {
    /// Immutable admission proof captured synchronously at delegate entry.
    /// A peripheral UUID is not enough: CoreBluetooth can vend two distinct
    /// `CBPeripheral` objects for the same physical strap during restoration
    /// and reconnect races. Deferred work must retain this complete tuple.
    struct Source: Hashable, Sendable {
        let epoch: UInt64
        let peripheralID: UUID
        let peripheralObjectID: ObjectIdentifier
    }

    struct PowerOnMarkers: Equatable, Sendable {
        var standingConnect = false
        var silentStreamRebuild = false
    }

    private let lock = NSLock()
    private var storedEpoch: UInt64 = 0
    private var activePeripheralID: UUID?
    private var activePeripheralObjectID: ObjectIdentifier?
    private var powerOnMarkers = PowerOnMarkers()

    var epoch: UInt64 {
        lock.withLock { storedEpoch }
    }

    /// True while an exact peripheral object owns the current callback epoch.
    /// This is intentionally independent of MainActor publication and the
    /// object's momentary CoreBluetooth state: restoration activates the epoch
    /// synchronously before `AtriaBLEManager.peripheral` can be published.
    var hasActiveOwner: Bool {
        lock.withLock {
            activePeripheralID != nil && activePeripheralObjectID != nil
        }
    }

    func activate(
        peripheralID: UUID,
        peripheralObjectID: ObjectIdentifier
    ) -> UInt64 {
        lock.withLock {
            storedEpoch &+= 1
            activePeripheralID = peripheralID
            activePeripheralObjectID = peripheralObjectID
            return storedEpoch
        }
    }

    @discardableResult
    func invalidate(
        ifMatching peripheralID: UUID? = nil,
        peripheralObjectID: ObjectIdentifier? = nil
    ) -> UInt64 {
        lock.withLock {
            if let peripheralID, activePeripheralID != peripheralID {
                return storedEpoch
            }
            if let peripheralObjectID,
               activePeripheralObjectID != peripheralObjectID {
                return storedEpoch
            }
            storedEpoch &+= 1
            activePeripheralID = nil
            activePeripheralObjectID = nil
            return storedEpoch
        }
    }

    /// Atomically captures the current source tuple only when the callback's
    /// exact peripheral object owns the live connection. Reading `epoch` and
    /// checking identity in separate lock transactions would allow a reconnect
    /// to splice a new epoch onto an old callback.
    func captureIfAccepted(
        peripheralID: UUID,
        peripheralObjectID: ObjectIdentifier,
        peripheralConnected: Bool
    ) -> Source? {
        lock.withLock {
            guard peripheralConnected,
                  activePeripheralID == peripheralID,
                  activePeripheralObjectID == peripheralObjectID else {
                return nil
            }
            return Source(
                epoch: storedEpoch,
                peripheralID: peripheralID,
                peripheralObjectID: peripheralObjectID
            )
        }
    }

    func accepts(
        callbackEpoch: UInt64,
        peripheralID: UUID,
        peripheralObjectID: ObjectIdentifier,
        peripheralConnected: Bool
    ) -> Bool {
        lock.withLock {
            callbackEpoch == storedEpoch
                && peripheralID == activePeripheralID
                && peripheralObjectID == activePeripheralObjectID
                && peripheralConnected
        }
    }

    func accepts(
        source: Source,
        peripheralConnected: Bool
    ) -> Bool {
        accepts(
            callbackEpoch: source.epoch,
            peripheralID: source.peripheralID,
            peripheralObjectID: source.peripheralObjectID,
            peripheralConnected: peripheralConnected
        )
    }

    /// Whether work still belongs to the active connection epoch, independent
    /// of the peripheral's instantaneous CoreBluetooth state. A repair-owned
    /// cancel can move the object to `.disconnected` without delivering
    /// `didDisconnect`; the recovery watchdog must distinguish that live epoch
    /// from genuinely stale queued work so it can install the standing
    /// reconnect.
    func owns(
        callbackEpoch: UInt64,
        peripheralID: UUID,
        peripheralObjectID: ObjectIdentifier
    ) -> Bool {
        lock.withLock {
            callbackEpoch == storedEpoch
                && peripheralID == activePeripheralID
                && peripheralObjectID == activePeripheralObjectID
        }
    }

    func owns(source: Source) -> Bool {
        owns(
            callbackEpoch: source.epoch,
            peripheralID: source.peripheralID,
            peripheralObjectID: source.peripheralObjectID
        )
    }

    func markAwaitingPowerOn(
        standingConnect: Bool,
        silentStreamRebuild: Bool = false
    ) {
        lock.withLock {
            powerOnMarkers.standingConnect =
                powerOnMarkers.standingConnect || standingConnect
            powerOnMarkers.silentStreamRebuild =
                powerOnMarkers.silentStreamRebuild || silentStreamRebuild
        }
    }

    func powerOnMarkerSnapshot() -> PowerOnMarkers {
        lock.withLock { powerOnMarkers }
    }

    /// The powered-on callback owns both markers as one transaction. A rebuild
    /// cannot publish one marker between two independent reads/clears.
    func consumePowerOnMarkers() -> PowerOnMarkers {
        lock.withLock {
            let consumed = powerOnMarkers
            powerOnMarkers = PowerOnMarkers()
            return consumed
        }
    }
}
