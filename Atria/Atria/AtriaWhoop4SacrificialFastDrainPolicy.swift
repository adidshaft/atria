import Foundation

/// A fail-closed command firewall for one attended WHOOP 4 history drain that
/// intentionally acknowledges (and therefore discards) every served page.
///
/// This policy owns no CoreBluetooth state and is never enabled in production.
/// It can only be armed by three explicit launch arguments. The transport
/// caller remains responsible for accepting metadata only after normal WHOOP
/// framing and CRC validation.
enum AtriaWhoop4SacrificialFastDrainPolicy {
    static let modeArgument = "--atria-one-shot-history-discard-drain"
    static let confirmationArgument =
        "--atria-confirm-sacrificial-strap-history-loss"
    static let runIDArgument = "--atria-history-discard-run-id"

    static let maximumAbortTimeout: TimeInterval = 120

    struct Authorization: Equatable, Sendable {
        let runID: UUID
    }

    enum AuthorizationError: Error, Equatable {
        case modeMissing
        case confirmationMissing
        case runIDMissing
        case runIDRepeated
        case malformedRunID
    }

    struct Command: Equatable, Sendable {
        let opcode: UInt8
        let payload: [UInt8]
    }

    enum Phase: Equatable, Sendable {
        case preflight
        case serve
        case streaming
        case postflight
        case abortReady
        case complete
    }

    enum PolicyError: Error, Equatable {
        case commandRejected(phase: Phase)
        case metadataRejected(phase: Phase)
        case acknowledgementAlreadyPending
        case tokenAlreadyConsumed
        case historyCompleteBeforeAcknowledgement
        case invalidAbortTimeout
        case abortTimeoutNotExpired
        case runAlreadyComplete
    }

    struct CursorObservation: Equatable, Sendable {
        let writeCursor: UInt32
        let readCursor: UInt32
        let pendingRecords: UInt32
    }

    static let getDataRange = Command(opcode: 0x22, payload: [0x00])
    static let sendHistorical = Command(opcode: 0x16, payload: [0x00])
    static let abort = Command(opcode: 0x14, payload: [0x00])

    static func authorizeLaunch(arguments: [String]) throws -> Authorization {
        guard arguments.contains(modeArgument) else {
            throw AuthorizationError.modeMissing
        }
        guard arguments.contains(confirmationArgument) else {
            throw AuthorizationError.confirmationMissing
        }

        let indexes = arguments.indices.filter {
            arguments[$0] == runIDArgument
        }
        guard !indexes.isEmpty else {
            throw AuthorizationError.runIDMissing
        }
        guard indexes.count == 1 else {
            throw AuthorizationError.runIDRepeated
        }

        let valueIndex = arguments.index(after: indexes[0])
        guard valueIndex < arguments.endIndex,
              arguments[valueIndex] != modeArgument,
              arguments[valueIndex] != confirmationArgument,
              arguments[valueIndex] != runIDArgument,
              let runID = UUID(uuidString: arguments[valueIndex]) else {
            throw AuthorizationError.malformedRunID
        }
        return Authorization(runID: runID)
    }

    struct Session: Sendable {
        let authorization: Authorization
        private(set) var phase: Phase = .preflight

        private var pendingAcknowledgement: Command?
        private var consumedTokens: Set<Data> = []

        init(authorization: Authorization) {
            self.authorization = authorization
        }

        /// Authorizes only this trace:
        ///
        /// `22/00 -> 16/00 -> (17/[01 + parsed token])* -> 22/00`
        ///
        /// A command is rejected without changing session state. `14/00` is
        /// available only after `recordBoundedTimeout` has entered abortReady.
        mutating func authorize(_ command: Command) throws {
            switch phase {
            case .preflight:
                guard command
                        == AtriaWhoop4SacrificialFastDrainPolicy.getDataRange else {
                    throw PolicyError.commandRejected(phase: phase)
                }
                phase = .serve

            case .serve:
                guard command
                        == AtriaWhoop4SacrificialFastDrainPolicy.sendHistorical else {
                    throw PolicyError.commandRejected(phase: phase)
                }
                phase = .streaming

            case .streaming:
                guard let expected = pendingAcknowledgement,
                      command == expected else {
                    throw PolicyError.commandRejected(phase: phase)
                }
                let token = Data(command.payload.dropFirst())
                guard !consumedTokens.contains(token) else {
                    throw PolicyError.tokenAlreadyConsumed
                }
                consumedTokens.insert(token)
                pendingAcknowledgement = nil

            case .postflight:
                guard command
                        == AtriaWhoop4SacrificialFastDrainPolicy.getDataRange else {
                    throw PolicyError.commandRejected(phase: phase)
                }
                phase = .complete

            case .abortReady:
                guard command
                        == AtriaWhoop4SacrificialFastDrainPolicy.abort else {
                    throw PolicyError.commandRejected(phase: phase)
                }
                phase = .complete

            case .complete:
                throw PolicyError.runAlreadyComplete
            }
        }

        /// Records a validated WHOOP metadata payload. Only a parsed
        /// HISTORY_END can mint an ACK permit, and the permit is exactly
        /// `[success = 01] + the fixed eight-byte opaque token`.
        mutating func recordMetadata(_ bytes: [UInt8]) throws {
            guard phase == .streaming else {
                throw PolicyError.metadataRejected(phase: phase)
            }

            let marker: AtriaWhoop4HistoryMetadata.Marker
            do {
                marker = try AtriaWhoop4HistoryMetadata.parse(bytes)
            } catch {
                throw PolicyError.metadataRejected(phase: phase)
            }

            switch marker {
            case .historyStart:
                return

            case .historyEnd(_, _, let token):
                guard pendingAcknowledgement == nil else {
                    throw PolicyError.acknowledgementAlreadyPending
                }
                let tokenIdentity = Data(token.bytes)
                guard !consumedTokens.contains(tokenIdentity) else {
                    throw PolicyError.tokenAlreadyConsumed
                }
                pendingAcknowledgement = Command(
                    opcode: 0x17,
                    payload: token.acknowledgementPayload
                )

            case .historyComplete:
                guard pendingAcknowledgement == nil else {
                    throw PolicyError.historyCompleteBeforeAcknowledgement
                }
                phase = .postflight
            }
        }

        /// Opens the sole ABORT path only when an external bounded timer has
        /// actually expired. Invalid, zero, or overly broad timeout limits are
        /// rejected so ABORT cannot become a generic escape command.
        mutating func recordBoundedTimeout(
            elapsed: TimeInterval,
            limit: TimeInterval
        ) throws {
            guard phase != .complete else {
                throw PolicyError.runAlreadyComplete
            }
            guard limit > 0,
                  limit <= AtriaWhoop4SacrificialFastDrainPolicy.maximumAbortTimeout,
                  elapsed >= 0,
                  elapsed.isFinite,
                  limit.isFinite else {
                throw PolicyError.invalidAbortTimeout
            }
            guard elapsed >= limit else {
                throw PolicyError.abortTimeoutNotExpired
            }
            phase = .abortReady
            pendingAcknowledgement = nil
        }
    }

    /// Pure physical acceptance predicate for a completed discard drain. The
    /// postflight range may contain at most two records appended while the
    /// continuously recording strap completed the postflight exchange.
    static func hasAcceptableCursorCollapse(
        preflight: CursorObservation,
        postflight: CursorObservation
    ) -> Bool {
        guard preflight.pendingRecords > 2,
              postflight.pendingRecords <= 2,
              postflight.pendingRecords < preflight.pendingRecords else {
            return false
        }
        if postflight.pendingRecords == 0 {
            return postflight.readCursor == postflight.writeCursor
        }
        return postflight.readCursor != postflight.writeCursor
    }
}
