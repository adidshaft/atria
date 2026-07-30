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
    /// The physical v6 run lost its BLE link 104.93 seconds after SERVE. Stop
    /// each destructive slice well before that observed boundary, then begin
    /// any continuation from a fresh cursor preflight.
    static let sliceTimeout: TimeInterval = 75
    static let maximumSliceAttempts = 4

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
        let capacity: UInt32
        let pendingRecords: UInt32
    }

    /// A continuation may only move the strap read cursor forward (allowing a
    /// bounded ring wrap) or observe the same cursor when the preceding ACK was
    /// accepted by CoreBluetooth but not yet committed by the strap. A backward
    /// cursor observation is fail-closed.
    static func hasNonRegressingContinuationPreflight(
        previous: CursorObservation,
        current: CursorObservation
    ) -> Bool {
        guard previous.capacity > 0,
              current.capacity == previous.capacity,
              previous.pendingRecords <= previous.capacity,
              current.pendingRecords <= current.capacity else {
            return false
        }
        if current.readCursor == previous.readCursor {
            return true
        }
        let capacity = UInt64(previous.capacity)
        let previousCursor = UInt64(previous.readCursor) % capacity
        let currentCursor = UInt64(current.readCursor) % capacity
        let forward = (currentCursor + capacity - previousCursor) % capacity
        return forward > 0 && forward <= capacity / 2
    }

    /// A launch UUID is a root authorization, not an escape hatch. Once a root
    /// has started serving history, a different UUID cannot replace it. Slices
    /// continue internally under the original authorization.
    static func admitsRootLaunch(
        authorization: Authorization,
        consumedRunID: String?,
        activeRootRunID: String?
    ) -> Bool {
        guard consumedRunID != authorization.runID.uuidString else {
            return false
        }
        guard let activeRootRunID else { return true }
        return activeRootRunID == authorization.runID.uuidString
            && consumedRunID == nil
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
