import Foundation

/// Bounded, archive-queue-owned checkpoint cadence for a long WHOOP history
/// transfer.  A HISTORY_END ACK is deliberately not part of this type: these
/// checkpoints only seal durable prefixes so a full-flash replay cannot retain
/// every exact identity until the final terminal marker arrives.
///
/// The caller must invoke `recordPersistence` from the same serial queue that
/// performs the raw archive append.  Therefore a returned checkpoint ordinal
/// has a complete, successfully persisted prefix; it is never inferred from
/// callbacks that may arrive out of order on the main actor.
final class AtriaWhoop4HistoryCheckpointCoordinator: @unchecked Sendable {
    /// Below the archive receipt's 65,536 exact-identity ceiling, leaving room
    /// for replay identities and a terminal tail without turning a long drain
    /// into an unbounded resident batch.
    static let productionMaximumUnsealedFrames = 48_000

    struct Checkpoint: Equatable, Sendable {
        let generation: UInt64
        let throughOrdinal: UInt64
    }

    private let lock = NSLock()
    private let threshold: Int
    private var generation: UInt64?
    private var successfulFramesSinceCheckpoint = 0
    private var persistenceFailed = false
    private var checkpointInFlight = false

    init(threshold: Int = productionMaximumUnsealedFrames) {
        precondition(threshold > 0)
        precondition(threshold < AtriaHistoricalArchiveDurableStore
            .productionMaximumReceiptBatchIdentities)
        self.threshold = threshold
    }

    func begin(generation newGeneration: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        generation = newGeneration
        successfulFramesSinceCheckpoint = 0
        persistenceFailed = false
        checkpointInFlight = false
    }

    /// Returns at most one checkpoint request at a time. A failed archive
    /// append permanently suppresses checkpointing for that generation: the
    /// terminal path will withhold ACK and preserve the gap for replay.
    func recordPersistence(
        generation eventGeneration: UInt64,
        ordinal: UInt64,
        succeeded: Bool
    ) -> Checkpoint? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == eventGeneration else { return nil }
        guard succeeded else {
            persistenceFailed = true
            return nil
        }
        guard !persistenceFailed, !checkpointInFlight else { return nil }
        successfulFramesSinceCheckpoint += 1
        guard successfulFramesSinceCheckpoint >= threshold else { return nil }
        checkpointInFlight = true
        return .init(generation: eventGeneration, throughOrdinal: ordinal)
    }

    func checkpointCompleted(generation eventGeneration: UInt64, succeeded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == eventGeneration else { return }
        checkpointInFlight = false
        if succeeded {
            successfulFramesSinceCheckpoint = 0
        } else {
            persistenceFailed = true
        }
    }
}
