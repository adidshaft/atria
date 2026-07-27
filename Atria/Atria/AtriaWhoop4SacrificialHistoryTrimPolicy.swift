import Foundation

/// Fail-closed command firewall for one attended, sacrificial WHOOP 4 history
/// trim. This type owns no CoreBluetooth objects and is not a production
/// recovery path. A caller must explicitly authorize one run at launch and
/// advance through the exact three-command trace without retries.
enum AtriaWhoop4SacrificialHistoryTrimPolicy {
    static let modeArgument = "--atria-one-shot-history-trim"
    static let confirmationArgument = "--atria-confirm-sacrificial-strap-history-loss"
    static let runIDArgument = "--atria-history-trim-run-id"

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
        case trim
        case postflight
        case complete
    }

    enum CommandError: Error, Equatable {
        case commandRejected(phase: Phase)
        case runAlreadyComplete
    }

    struct CursorObservation: Equatable, Sendable {
        let writeCursor: UInt32
        let readCursor: UInt32
        let pendingRecords: UInt32
    }

    static let getDataRange = Command(opcode: 0x22, payload: [0x00])
    static let forceTrim = Command(
        opcode: 0x19,
        payload: Array(repeating: 0xFE, count: 8) + [0x00]
    )

    /// All three explicit launch arguments are mandatory. Repeated run-ID
    /// arguments are rejected so command-line parsing cannot select an
    /// unintended authorization token.
    static func authorizeLaunch(arguments: [String]) throws -> Authorization {
        guard arguments.contains(modeArgument) else {
            throw AuthorizationError.modeMissing
        }
        guard arguments.contains(confirmationArgument) else {
            throw AuthorizationError.confirmationMissing
        }

        let runIDIndexes = arguments.indices.filter {
            arguments[$0] == runIDArgument
        }
        guard !runIDIndexes.isEmpty else {
            throw AuthorizationError.runIDMissing
        }
        guard runIDIndexes.count == 1 else {
            throw AuthorizationError.runIDRepeated
        }

        let valueIndex = arguments.index(after: runIDIndexes[0])
        guard valueIndex < arguments.endIndex,
              arguments[valueIndex] != modeArgument,
              arguments[valueIndex] != confirmationArgument,
              arguments[valueIndex] != runIDArgument,
              let runID = UUID(uuidString: arguments[valueIndex]) else {
            throw AuthorizationError.malformedRunID
        }
        return Authorization(runID: runID)
    }

    /// Advances only for 22/00 -> 19/(FE*8 + 00) -> 22/00. The nine-byte
    /// payload is copied from an official WHOOP 4 erase-device wire capture;
    /// the trailing 00 is CRC-covered command payload, not framing. There is
    /// no transition for SEND_HISTORICAL, ACK, clock writes, reboot, mode
    /// changes, a second trim, or any retry after an ambiguous outcome.
    static func authorize(
        command: Command,
        in phase: Phase
    ) throws -> Phase {
        switch phase {
        case .preflight:
            guard command == getDataRange else {
                throw CommandError.commandRejected(phase: phase)
            }
            return .trim
        case .trim:
            guard command == forceTrim else {
                throw CommandError.commandRejected(phase: phase)
            }
            return .postflight
        case .postflight:
            guard command == getDataRange else {
                throw CommandError.commandRejected(phase: phase)
            }
            return .complete
        case .complete:
            throw CommandError.runAlreadyComplete
        }
    }

    /// Exact empty-ring proof. This is the strongest postcondition, but a
    /// continuously recording strap may append a page between the destructive
    /// write and the postflight range response.
    static func isExactlyEmpty(_ observation: CursorObservation) -> Bool {
        observation.pendingRecords == 0
            && observation.readCursor == observation.writeCursor
    }

    /// Attended physical acceptance permits at most two newly appended records
    /// while requiring the preflight backlog to have collapsed materially.
    /// This does not authorize another trim when the result is ambiguous.
    static func hasAcceptablePostTrimCollapse(
        preflight: CursorObservation,
        postflight: CursorObservation,
        maximumResidualRecords: UInt32 = 2,
        minimumRemovedRecords: UInt32 = 3
    ) -> Bool {
        guard maximumResidualRecords <= 2,
              minimumRemovedRecords >= 3,
              postflight.pendingRecords <= maximumResidualRecords,
              preflight.pendingRecords > postflight.pendingRecords,
              preflight.pendingRecords - postflight.pendingRecords >= minimumRemovedRecords else {
            return false
        }
        if postflight.pendingRecords == 0 {
            return postflight.readCursor == postflight.writeCursor
        }
        return postflight.readCursor != postflight.writeCursor
    }
}
