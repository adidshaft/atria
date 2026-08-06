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
    struct PowerOnMarkers: Equatable, Sendable {
        var standingConnect = false
        var silentStreamRebuild = false
    }

    private let lock = NSLock()
    private var storedEpoch: UInt64 = 0
    private var activePeripheralID: UUID?
    private var powerOnMarkers = PowerOnMarkers()

    var epoch: UInt64 {
        lock.withLock { storedEpoch }
    }

    func activate(peripheralID: UUID) -> UInt64 {
        lock.withLock {
            storedEpoch &+= 1
            activePeripheralID = peripheralID
            return storedEpoch
        }
    }

    @discardableResult
    func invalidate(ifMatching peripheralID: UUID? = nil) -> UInt64 {
        lock.withLock {
            if let peripheralID, activePeripheralID != peripheralID {
                return storedEpoch
            }
            storedEpoch &+= 1
            activePeripheralID = nil
            return storedEpoch
        }
    }

    func accepts(
        callbackEpoch: UInt64,
        peripheralID: UUID,
        peripheralConnected: Bool
    ) -> Bool {
        lock.withLock {
            callbackEpoch == storedEpoch
                && peripheralID == activePeripheralID
                && peripheralConnected
        }
    }

    /// Whether work still belongs to the active connection epoch, independent
    /// of the peripheral's instantaneous CoreBluetooth state. A repair-owned
    /// cancel can move the object to `.disconnected` without delivering
    /// `didDisconnect`; the recovery watchdog must distinguish that live epoch
    /// from genuinely stale queued work so it can install the standing
    /// reconnect.
    func owns(
        callbackEpoch: UInt64,
        peripheralID: UUID
    ) -> Bool {
        lock.withLock {
            callbackEpoch == storedEpoch
                && peripheralID == activePeripheralID
        }
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
