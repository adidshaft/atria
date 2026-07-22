import Foundation

/// Correlates a WHOOP 4 HISTORY_END acknowledgement with its exact confirmed
/// GATT write. WHOOP 4 does not consistently emit a command-response frame for
/// command 0x17. Requiring one makes a successfully delivered ACK time out and
/// causes the same durable page to be resent forever. A matching
/// `didWriteValueFor` callback is therefore the ACK completion boundary. If the
/// strap ignored the command it can only re-serve the already-fsynced page;
/// later page/terminal callbacks remain the proof needed to finish the drain.
struct AtriaWhoop4HistoryACKGate: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let generation: UInt64
        let boundaryID: String
        let commandSequence: UInt8
        let attempt: Int
    }

    enum Decision: Equatable, Sendable {
        case ignored
        case awaitingGATTConfirmation(Identity)
        case awaitingLogicalResponse(Identity)
        case acceptedByGATT(Identity)
        case accepted(
            identity: Identity,
            responseSequence: UInt8,
            responsePayload: [UInt8]
        )
        case failed(Identity)
    }

    private struct Pending: Equatable, Sendable {
        let identity: Identity
        var gattConfirmed = false
        var logicalResponse: [UInt8]?
    }

    private var pending: Pending?

    var identity: Identity? { pending?.identity }
    /// While either ACK proof is outstanding, later history callbacks belong
    /// to the next page and must not reach a reducer still waiting for ACK.
    var requiresHistoryCallbackDeferral: Bool { pending != nil }

    mutating func arm(_ identity: Identity) {
        pending = Pending(identity: identity)
    }

    mutating func reset() {
        pending = nil
    }

    mutating func completeGATT(
        generation: UInt64,
        boundaryID: String,
        commandSequence: UInt8,
        succeeded: Bool
    ) -> Decision {
        guard let active = pending,
              active.identity.generation == generation,
              active.identity.boundaryID == boundaryID,
              active.identity.commandSequence == commandSequence else {
            return .ignored
        }
        guard succeeded else {
            pending = nil
            return .failed(active.identity)
        }
        if let response = active.logicalResponse {
            pending = nil
            return .accepted(
                identity: active.identity,
                responseSequence: response[1],
                responsePayload: response
            )
        }
        pending = nil
        return .acceptedByGATT(active.identity)
    }

    /// The accepted status is deliberately exact. Physical WHOOP 4 captures
    /// consistently encode acceptance as:
    /// `[0x24, responseSequence, 0x17, 0x00, 0x01, 0x00, 0x00, 0x00]`.
    /// Any other 0x17 response is a rejection/malformed response and therefore
    /// consumes this attempt without advancing the history reducer.
    mutating func receiveCommandResponse(
        _ payload: [UInt8],
        generation: UInt64
    ) -> Decision {
        guard payload.count >= 3,
              payload[0] == 0x24,
              payload[2] == 0x17 else {
            return .ignored
        }
        guard var active = pending,
              active.identity.generation == generation else {
            return .ignored
        }
        let accepted = payload.count == 8
            && Array(payload.dropFirst(3)) == [0x00, 0x01, 0x00, 0x00, 0x00]
        guard accepted else {
            pending = nil
            return .failed(active.identity)
        }
        if active.gattConfirmed {
            pending = nil
            return .accepted(
                identity: active.identity,
                responseSequence: payload[1],
                responsePayload: payload
            )
        }
        // CoreBluetooth may deliver the strap notification before its
        // `didWriteValueFor` callback, even for a write-with-response. Retain
        // the exact, generation-fenced logical proof but do not accept it until
        // the matching GATT completion also succeeds.
        if active.logicalResponse == nil {
            active.logicalResponse = payload
            pending = active
        }
        return .awaitingGATTConfirmation(active.identity)
    }

    mutating func timeout(_ identity: Identity) -> Decision {
        guard pending?.identity == identity else { return .ignored }
        pending = nil
        return .failed(identity)
    }
}
