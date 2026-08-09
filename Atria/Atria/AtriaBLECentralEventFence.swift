import Foundation

/// Identifies the one `CBCentralManager` instance whose delegate callbacks are
/// allowed to affect Atria. CoreBluetooth may still deliver work queued by a
/// manager after its delegate is cleared; object identity, not a mutable
/// manager property, is therefore the authority.
final class AtriaBLECentralEventFence: @unchecked Sendable {
    struct PowerOnMarkers: Equatable, Sendable {
        var standingConnect = false
        var silentStreamRebuild = false
    }

    struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let objectID: ObjectIdentifier
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeObjectID: ObjectIdentifier?
    private var powerOnMarkers = PowerOnMarkers()

    @discardableResult
    func install(_ central: AnyObject) -> Token {
        lock.withLock {
            generation &+= 1
            let objectID = ObjectIdentifier(central)
            activeObjectID = objectID
            powerOnMarkers = PowerOnMarkers()
            return Token(generation: generation, objectID: objectID)
        }
    }

    func retire(_ central: AnyObject) {
        lock.withLock {
            guard activeObjectID == ObjectIdentifier(central) else { return }
            generation &+= 1
            activeObjectID = nil
            powerOnMarkers = PowerOnMarkers()
        }
    }

    /// Retires a manager only after every callback already executing on its
    /// private serial delegate lane has returned. A point-in-time token check
    /// alone cannot stop an admitted callback from crossing a concurrent
    /// replacement boundary and mutating the new manager's peripheral epoch.
    ///
    /// Production calls this from `MainActor`, never from `delegateQueue`.
    /// When CoreBluetooth is explicitly configured to use the main queue,
    /// `delegateQueue` is nil and MainActor serialization already supplies the
    /// same critical-section guarantee.
    func retire(
        _ central: AnyObject,
        afterDraining delegateQueue: DispatchQueue?,
        synchronizedTeardown: () -> Void = {}
    ) {
        if let delegateQueue {
            delegateQueue.sync {
                retire(central)
                synchronizedTeardown()
            }
        } else {
            retire(central)
            synchronizedTeardown()
        }
    }

    /// Captures callback authority at delegate entry. A callback from a
    /// retired manager receives no token and must return before side effects.
    func capture(_ central: AnyObject) -> Token? {
        lock.withLock {
            let objectID = ObjectIdentifier(central)
            guard activeObjectID == objectID else { return nil }
            return Token(generation: generation, objectID: objectID)
        }
    }

    /// Delayed work must revalidate the exact entry token. This rejects both a
    /// retired manager and queued work from an earlier generation of an object.
    func accepts(_ token: Token, central: AnyObject) -> Bool {
        lock.withLock {
            token.generation == generation
                && token.objectID == ObjectIdentifier(central)
                && activeObjectID == token.objectID
        }
    }

    func markAwaitingPowerOn(
        token: Token,
        standingConnect: Bool,
        silentStreamRebuild: Bool
    ) {
        lock.withLock {
            guard token.generation == generation,
                  activeObjectID == token.objectID else { return }
            powerOnMarkers.standingConnect =
                powerOnMarkers.standingConnect || standingConnect
            powerOnMarkers.silentStreamRebuild =
                powerOnMarkers.silentStreamRebuild || silentStreamRebuild
        }
    }

    func powerOnMarkerSnapshot(token: Token) -> PowerOnMarkers {
        lock.withLock {
            guard token.generation == generation,
                  activeObjectID == token.objectID else {
                return PowerOnMarkers()
            }
            return powerOnMarkers
        }
    }

    func consumePowerOnMarkers(token: Token) -> PowerOnMarkers {
        lock.withLock {
            guard token.generation == generation,
                  activeObjectID == token.objectID else {
                return PowerOnMarkers()
            }
            let consumed = powerOnMarkers
            powerOnMarkers = PowerOnMarkers()
            return consumed
        }
    }
}
