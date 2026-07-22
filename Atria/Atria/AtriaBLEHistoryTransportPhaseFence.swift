import Foundation

/// Thread-safe ownership token for proprietary history callbacks.
///
/// CoreBluetooth delegate entry runs on `centralQueue`, while the history state
/// machine is main-actor owned. Every callback captures one immutable snapshot
/// at delegate entry and must still match it when applied on the main actor.
/// This prevents an old HISTORY_COMPLETE/data frame from completing a newer
/// drain on the same physical connection.
final class AtriaBLEHistoryTransportPhaseFence: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let generation: UInt64?

        var isActive: Bool { generation != nil }
    }

    private let lock = NSLock()
    private var generation: UInt64?

    func activate(generation: UInt64) -> Snapshot {
        lock.lock()
        self.generation = generation
        let snapshot = Snapshot(generation: generation)
        lock.unlock()
        return snapshot
    }

    @discardableResult
    func deactivate(ifMatching expectedGeneration: UInt64? = nil) -> Snapshot {
        lock.lock()
        if expectedGeneration == nil || generation == expectedGeneration {
            generation = nil
        }
        let snapshot = Snapshot(generation: generation)
        lock.unlock()
        return snapshot
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(generation: generation)
        lock.unlock()
        return snapshot
    }

    func accepts(_ snapshot: Snapshot, generation expectedGeneration: UInt64) -> Bool {
        guard snapshot.generation == expectedGeneration else { return false }
        lock.lock()
        let accepted = generation == expectedGeneration
        lock.unlock()
        return accepted
    }
}
