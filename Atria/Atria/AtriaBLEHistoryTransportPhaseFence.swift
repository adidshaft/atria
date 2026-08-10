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
        let usesExplicitHistoryProfile: Bool
        /// Non-nil only after this generation has issued its own first 0x16
        /// serve request. Captured synchronously at CoreBluetooth delegate
        /// entry so work queued before the request cannot acquire authority
        /// later on the MainActor.
        let serveToken: UInt64?

        init(generation: UInt64?,
             usesExplicitHistoryProfile: Bool = false,
             serveToken: UInt64? = nil) {
            self.generation = generation
            self.usesExplicitHistoryProfile = usesExplicitHistoryProfile
            self.serveToken = serveToken
        }

        var isActive: Bool { generation != nil }
    }

    struct RealtimeRestoreHandoff: Equatable, Sendable {
        let peripheralID: UUID
        let interruptedGeneration: UInt64
        let claimedPeripheralObjectID: ObjectIdentifier?
        let claimedCallbackEpoch: UInt64?
    }

    private let lock = NSLock()
    private var generation: UInt64?
    private var usesExplicitHistoryProfile = false
    private var serveToken: UInt64?
    private var nextServeToken: UInt64 = 0
    private var realtimeRestoreHandoff: RealtimeRestoreHandoff?

    func activate(generation: UInt64,
                  usesExplicitHistoryProfile: Bool = false) -> Snapshot {
        lock.lock()
        // A newly admitted history generation always outranks an older,
        // not-yet-consumed live-restore handoff. This is the fail-closed edge
        // that prevents standard 2A37 discovery from overlapping a fresh
        // proprietary history owner.
        realtimeRestoreHandoff = nil
        self.generation = generation
        self.usesExplicitHistoryProfile = usesExplicitHistoryProfile
        serveToken = nil
        let snapshot = Snapshot(generation: generation,
                                usesExplicitHistoryProfile: usesExplicitHistoryProfile,
                                serveToken: nil)
        lock.unlock()
        return snapshot
    }

    @discardableResult
    func deactivate(ifMatching expectedGeneration: UInt64? = nil) -> Snapshot {
        lock.lock()
        if expectedGeneration == nil || generation == expectedGeneration {
            generation = nil
            usesExplicitHistoryProfile = false
            serveToken = nil
        }
        let snapshot = Snapshot(generation: generation,
                                usesExplicitHistoryProfile: usesExplicitHistoryProfile,
                                serveToken: serveToken)
        lock.unlock()
        return snapshot
    }

    /// Atomically retires exactly one interrupted history generation and
    /// transfers its identity to the replacement realtime connection.
    ///
    /// This is called only after the physical history link is already down. A
    /// stale terminal callback can therefore never retire a newer generation.
    @discardableResult
    func retireForRealtimeRestore(
        ifMatching expectedGeneration: UInt64,
        peripheralID: UUID
    ) -> Bool {
        lock.lock()
        guard generation == expectedGeneration else {
            lock.unlock()
            return false
        }
        generation = nil
        usesExplicitHistoryProfile = false
        serveToken = nil
        realtimeRestoreHandoff = RealtimeRestoreHandoff(
            peripheralID: peripheralID,
            interruptedGeneration: expectedGeneration,
            claimedPeripheralObjectID: nil,
            claimedCallbackEpoch: nil
        )
        lock.unlock()
        return true
    }

    /// Binds an interrupted-owner handoff to one concrete CoreBluetooth
    /// callback object and epoch. A failed/stale callback may be superseded by
    /// a later connection, but a newly active history generation refuses it.
    func claimRealtimeRestore(
        peripheralID: UUID,
        peripheralObjectID: ObjectIdentifier,
        callbackEpoch: UInt64
    ) -> UInt64? {
        lock.lock()
        guard generation == nil,
              let handoff = realtimeRestoreHandoff,
              handoff.peripheralID == peripheralID else {
            lock.unlock()
            return nil
        }
        realtimeRestoreHandoff = RealtimeRestoreHandoff(
            peripheralID: peripheralID,
            interruptedGeneration: handoff.interruptedGeneration,
            claimedPeripheralObjectID: peripheralObjectID,
            claimedCallbackEpoch: callbackEpoch
        )
        lock.unlock()
        return handoff.interruptedGeneration
    }

    func acceptsRealtimeRestoreClaim(
        peripheralID: UUID,
        peripheralObjectID: ObjectIdentifier,
        interruptedGeneration: UInt64,
        callbackEpoch: UInt64
    ) -> Bool {
        lock.lock()
        let accepted = generation == nil
            && realtimeRestoreHandoff == RealtimeRestoreHandoff(
                peripheralID: peripheralID,
                interruptedGeneration: interruptedGeneration,
                claimedPeripheralObjectID: peripheralObjectID,
                claimedCallbackEpoch: callbackEpoch
            )
        lock.unlock()
        return accepted
    }

    @discardableResult
    func settleRealtimeRestoreClaim(
        peripheralID: UUID,
        peripheralObjectID: ObjectIdentifier,
        interruptedGeneration: UInt64,
        callbackEpoch: UInt64
    ) -> Bool {
        lock.lock()
        let expected = RealtimeRestoreHandoff(
            peripheralID: peripheralID,
            interruptedGeneration: interruptedGeneration,
            claimedPeripheralObjectID: peripheralObjectID,
            claimedCallbackEpoch: callbackEpoch
        )
        guard realtimeRestoreHandoff == expected else {
            lock.unlock()
            return false
        }
        realtimeRestoreHandoff = nil
        lock.unlock()
        return true
    }

    func realtimeRestoreHandoffSnapshot() -> RealtimeRestoreHandoff? {
        lock.lock()
        let handoff = realtimeRestoreHandoff
        lock.unlock()
        return handoff
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(generation: generation,
                                usesExplicitHistoryProfile: usesExplicitHistoryProfile,
                                serveToken: serveToken)
        lock.unlock()
        return snapshot
    }

    /// Mints a fresh token for exactly the currently active generation's next
    /// 0x16 request. Every page/retry receives a distinct token: a fragment
    /// captured under a predecessor command can therefore never combine with
    /// or authorize callbacks from the next command. A new generation starts
    /// unarmed.
    @discardableResult
    func armServe(ifMatching expectedGeneration: UInt64) -> Snapshot? {
        lock.lock()
        guard generation == expectedGeneration else {
            lock.unlock()
            return nil
        }
        nextServeToken &+= 1
        if nextServeToken == 0 { nextServeToken = 1 }
        serveToken = nextServeToken
        let snapshot = Snapshot(
            generation: generation,
            usesExplicitHistoryProfile: usesExplicitHistoryProfile,
            serveToken: serveToken
        )
        lock.unlock()
        return snapshot
    }

    /// Validates the immutable token captured at delegate entry. Reading only
    /// current MainActor state is insufficient: a predecessor callback may be
    /// queued before 0x16 and applied after it.
    func acceptsServe(
        _ snapshot: Snapshot,
        generation expectedGeneration: UInt64
    ) -> Bool {
        guard snapshot.generation == expectedGeneration,
              let expectedServeToken = snapshot.serveToken else {
            return false
        }
        lock.lock()
        let accepted = generation == expectedGeneration
            && serveToken == expectedServeToken
        lock.unlock()
        return accepted
    }

    func accepts(_ snapshot: Snapshot, generation expectedGeneration: UInt64) -> Bool {
        guard snapshot.generation == expectedGeneration else { return false }
        lock.lock()
        let accepted = generation == expectedGeneration
        lock.unlock()
        return accepted
    }
}
