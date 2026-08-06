import Foundation

/// Correlates the two independent proofs for the single production GET_CLOCK
/// transport preflight. The response is evidence that the strap's command
/// response state is ready; GET_DATA_RANGE remains the sole clock authority.
struct AtriaWhoop4HistoryReadPreflightGate: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let generation: UInt64
        let commandSequence: UInt8
    }

    enum Decision: Equatable, Sendable {
        case ignored
        case awaitingGATTConfirmation(Identity)
        case awaitingLogicalResponse(Identity)
        case accepted(Identity)
        case failed(Identity)
    }

    private struct Pending: Equatable, Sendable {
        let identity: Identity
        var gattConfirmed = false
        var logicalResponseConfirmed = false
    }

    private var pending: Pending?

    var identity: Identity? { pending?.identity }

    /// One preflight is allowed per generation. A second caller must wait for
    /// or fail with the already armed identity; it may never enqueue another
    /// 0B/00 command on the same command epoch.
    mutating func arm(_ identity: Identity) -> Bool {
        guard pending == nil else { return false }
        pending = Pending(identity: identity)
        return true
    }

    mutating func reset() {
        pending = nil
    }

    mutating func completeGATT(
        generation: UInt64,
        commandSequence: UInt8,
        succeeded: Bool
    ) -> Decision {
        guard var active = pending,
              active.identity.generation == generation,
              active.identity.commandSequence == commandSequence else {
            return .ignored
        }
        guard succeeded else {
            pending = nil
            return .failed(active.identity)
        }
        if active.logicalResponseConfirmed {
            pending = nil
            return .accepted(active.identity)
        }
        active.gattConfirmed = true
        pending = active
        return .awaitingLogicalResponse(active.identity)
    }

    /// Proven WHOOP responses are `[24, responseSeq, 0B, requestSeq, 01, ...]`.
    /// A stale echo is ignored and therefore cannot authorize 16/00; a response
    /// for the armed sequence with a non-success status fails closed.
    mutating func receiveCommandResponse(
        _ payload: [UInt8],
        generation: UInt64
    ) -> Decision {
        guard payload.count >= 3,
              payload[0] == 0x24,
              payload[2] == 0x0B else { return .ignored }
        guard var active = pending,
              active.identity.generation == generation,
              payload.count >= 4,
              payload[3] == active.identity.commandSequence else {
            return .ignored
        }
        guard payload.count >= 9, payload[4] == 0x01 else {
            pending = nil
            return .failed(active.identity)
        }
        if active.gattConfirmed {
            pending = nil
            return .accepted(active.identity)
        }
        active.logicalResponseConfirmed = true
        pending = active
        return .awaitingGATTConfirmation(active.identity)
    }

    mutating func timeout(_ identity: Identity) -> Decision {
        guard pending?.identity == identity else { return .ignored }
        pending = nil
        return .failed(identity)
    }
}
