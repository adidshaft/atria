import CoreFoundation
import Foundation

/// Pure, fail-closed verifier for a completed sacrificial WHOOP 4 fast-drain
/// receipt. It reads caller-supplied bytes only: it owns no CoreBluetooth
/// objects, cannot mint an ACK, and cannot mutate application state.
enum AtriaWhoop4SacrificialFastDrainReceiptVerifier {
    static let reconciliationModeArgument =
        "--atria-reconcile-verified-sacrificial-fast-drain"

    struct Proof: Equatable, Sendable {
        let runID: UUID
        let completedAt: Date
        let preflightPendingRecords: UInt32
        let postflightPendingRecords: UInt32
        let acknowledgedChunks: Int
        let historicalRecordsDiscarded: Int
    }

    enum LaunchError: Error, Equatable {
        case modeMissing
        case modeRepeated
        case runIDMissing
        case runIDRepeated
        case malformedRunID
    }

    enum VerificationError: Error, Equatable {
        case malformedJSONL
        case incompleteReceipt
        case unexpectedEvent(index: Int)
        case invalidField(event: String, field: String)
        case wrongRunID
        case invalidOrdering
        case acknowledgementProofFailed
        case countMismatch
        case postconditionFailed
    }

    private typealias Row = [String: Any]

    /// Reconciliation is authorized by one explicit mode flag and one exact
    /// discard run ID. Repeated flags are rejected rather than selecting an
    /// arbitrary value from the process arguments.
    static func reconciliationRunID(arguments: [String]) throws -> UUID {
        let modeIndexes = arguments.indices.filter {
            arguments[$0] == reconciliationModeArgument
        }
        guard !modeIndexes.isEmpty else { throw LaunchError.modeMissing }
        guard modeIndexes.count == 1 else { throw LaunchError.modeRepeated }

        let runIDIndexes = arguments.indices.filter {
            arguments[$0]
                == AtriaWhoop4SacrificialFastDrainPolicy.runIDArgument
        }
        guard !runIDIndexes.isEmpty else { throw LaunchError.runIDMissing }
        guard runIDIndexes.count == 1 else { throw LaunchError.runIDRepeated }
        let valueIndex = arguments.index(after: runIDIndexes[0])
        guard valueIndex < arguments.endIndex,
              arguments[valueIndex] != reconciliationModeArgument,
              arguments[valueIndex]
                != AtriaWhoop4SacrificialFastDrainPolicy.runIDArgument,
              let runID = UUID(uuidString: arguments[valueIndex]) else {
            throw LaunchError.malformedRunID
        }
        return runID
    }

    static func receiptURL(
        documentDirectory: URL,
        runID: UUID
    ) -> URL {
        documentDirectory
            .appendingPathComponent(
                "atria-sacrificial-fast-drain",
                isDirectory: true
            )
            .appendingPathComponent(
                "read-only-history-\(runID.uuidString).jsonl"
            )
    }

    /// Verifies one complete root drain, including bounded continuation slices.
    /// Every non-final slice must prove its own timed ABORT, durable checkpoint,
    /// and non-regressing cursor before a fresh GET_RANGE/SERVE pair is
    /// accepted. Only the final HISTORY_COMPLETE plus cursor collapse can
    /// authorize reconciliation.
    static func verify(
        jsonl data: Data,
        expectedRunID: UUID
    ) throws -> Proof {
        let rows = try parseRows(data)
        guard rows.count >= 10 else {
            throw VerificationError.incompleteReceipt
        }
        let events = rows.map { string("event", in: $0) }
        guard events.allSatisfy({ $0 != nil }) else {
            throw VerificationError.malformedJSONL
        }
        let allowedEvents: Set<String> = [
            "discard_drain_started",
            "command",
            "range_response_raw",
            "preflight_range",
            "history_start",
            "discard_progress",
            "history_end_ack_confirmed",
            "history_complete",
            "discard_drain_checkpoint",
            "postflight_range",
            "discard_drain_finished",
        ]
        if let unexpected = events.enumerated().first(where: {
            !allowedEvents.contains($0.element!)
        }) {
            throw VerificationError.unexpectedEvent(index: unexpected.offset)
        }

        guard events.first! == "discard_drain_started",
              events.last! == "discard_drain_finished",
              events.filter({ $0 == "discard_drain_started" }).count == 1,
              events.filter({ $0 == "history_complete" }).count == 1,
              events.filter({ $0 == "postflight_range" }).count == 1,
              events.filter({ $0 == "discard_drain_finished" }).count == 1 else {
            throw VerificationError.incompleteReceipt
        }
        let sliceCount = events.filter({ $0 == "preflight_range" }).count
        guard sliceCount >= 1,
              sliceCount
                <= AtriaWhoop4SacrificialFastDrainPolicy
                    .maximumSliceAttempts,
              events.filter({ $0 == "discard_drain_checkpoint" }).count
                == sliceCount - 1 else {
            throw VerificationError.incompleteReceipt
        }

        let times = try rows.map { row -> TimeInterval in
            guard let event = string("event", in: row),
                  let value = number("received_at_unix", in: row),
                  value.isFinite,
                  value > 0 else {
                throw VerificationError.invalidField(
                    event: string("event", in: row) ?? "unknown",
                    field: "received_at_unix"
                )
            }
            _ = event
            return value
        }
        guard zip(times, times.dropFirst()).allSatisfy({
            $0.0 <= $0.1
        }) else {
            throw VerificationError.invalidOrdering
        }

        let started = rows[0]
        guard let runIDString = string("run_id", in: started),
              let runID = UUID(uuidString: runIDString) else {
            throw VerificationError.invalidField(
                event: "discard_drain_started",
                field: "run_id"
            )
        }
        guard runID == expectedRunID else {
            throw VerificationError.wrongRunID
        }
        guard bool("fabricated_ack", in: started) == false,
              bool("local_data_mutation", in: started) == false,
              uint("generation", in: started).map({ $0 > 0 }) == true,
              number("timeout_seconds", in: started)
                == AtriaWhoop4SacrificialFastDrainPolicy
                    .maximumAbortTimeout,
              number("slice_timeout_seconds", in: started)
                == AtriaWhoop4SacrificialFastDrainPolicy.sliceTimeout,
              uint("maximum_slice_attempts", in: started)
                == UInt64(
                    AtriaWhoop4SacrificialFastDrainPolicy
                        .maximumSliceAttempts
                ) else {
            throw VerificationError.invalidField(
                event: "discard_drain_started",
                field: "safety_configuration"
            )
        }

        var rowIndex = 1
        var sliceAttempt = 1
        var rootPreflight:
            AtriaWhoop4SacrificialFastDrainPolicy.CursorObservation?
        var previousPreflight:
            AtriaWhoop4SacrificialFastDrainPolicy.CursorObservation?
        var acknowledgementCommands:
            [(index: Int, token: String)] = []
        var acknowledgementConfirmations:
            [(index: Int, token: String, records: Int)] = []
        var consumedAcknowledgementTokens = Set<String>()
        var historyCompleteRecords: Int?
        var previousDiscardedRecords = 0

        sliceLoop: while sliceAttempt <= sliceCount {
            guard rowIndex + 3 < rows.count else {
                throw VerificationError.incompleteReceipt
            }
            let preflightSequence = try verifyCommand(
                rows[rowIndex],
                opcode: "22",
                payload: "00",
                phaseAfterAccept: "serve"
            )
            try verifyRangeResponse(
                rows[rowIndex + 1],
                sequence: preflightSequence
            )
            let preflightRow = rows[rowIndex + 2]
            guard string("event", in: preflightRow)
                    == "preflight_range" else {
                throw VerificationError.invalidOrdering
            }
            let preflight = try cursor(
                preflightRow,
                event: "preflight_range"
            )
            guard bool("continuation", in: preflightRow)
                    == (sliceAttempt > 1),
                  uint("slice_attempt", in: preflightRow)
                    == UInt64(sliceAttempt),
                  cursorPendingCountIsCoherent(preflight) else {
                throw VerificationError.postconditionFailed
            }
            if let previousPreflight {
                guard AtriaWhoop4SacrificialFastDrainPolicy
                    .hasNonRegressingContinuationPreflight(
                        previous: previousPreflight,
                        current: preflight
                    ) else {
                    throw VerificationError.postconditionFailed
                }
            } else {
                guard preflight.pendingRecords > 2 else {
                    throw VerificationError.postconditionFailed
                }
                rootPreflight = preflight
            }

            _ = try verifyCommand(
                rows[rowIndex + 3],
                opcode: "16",
                payload: "00",
                phaseAfterAccept: "streaming"
            )
            let serveAt = times[rowIndex + 3]
            rowIndex += 4

            var localHistoryStarts = 0
            var localAcknowledgementCommands = 0
            var localAcknowledgementConfirmations = 0
            var pendingAcknowledgement:
                (index: Int, token: String)?
            var sliceReachedHistoryComplete = false

            streamLoop: while rowIndex < rows.count {
                guard let event = string("event", in: rows[rowIndex]) else {
                    throw VerificationError.malformedJSONL
                }
                let row = rows[rowIndex]
                switch event {
                case "history_start":
                    guard !sliceReachedHistoryComplete,
                          uint("sequence", in: row).map({
                              $0 <= UInt8.max
                          }) == true else {
                        throw VerificationError.invalidOrdering
                    }
                    localHistoryStarts += 1
                    rowIndex += 1

                case "discard_progress":
                    guard !sliceReachedHistoryComplete,
                          uint("acknowledged_chunks", in: row)
                            == UInt64(
                                acknowledgementConfirmations.count
                            ),
                          let records = exactInt(
                            "historical_records_discarded",
                            in: row
                          ),
                          records >= previousDiscardedRecords else {
                        throw VerificationError.countMismatch
                    }
                    previousDiscardedRecords = records
                    rowIndex += 1

                case "history_complete":
                    guard !sliceReachedHistoryComplete,
                          historyCompleteRecords == nil,
                          uint("sequence", in: row).map({
                              $0 <= UInt8.max
                          }) == true,
                          uint("acknowledged_chunks", in: row)
                            == UInt64(
                                acknowledgementConfirmations.count
                            ),
                          let records = exactInt(
                            "historical_records_discarded",
                            in: row
                          ),
                          records >= previousDiscardedRecords else {
                        throw VerificationError.countMismatch
                    }
                    sliceReachedHistoryComplete = true
                    historyCompleteRecords = records
                    previousDiscardedRecords = records
                    rowIndex += 1

                case "history_end_ack_confirmed":
                    guard let pending = pendingAcknowledgement,
                          bool("fabricated_ack", in: row) == false,
                          let tokenString = string("token", in: row),
                          bytes(hex: tokenString)?.count == 8,
                          tokenString == pending.token,
                          uint("acknowledged_chunks", in: row)
                            == UInt64(
                                acknowledgementConfirmations.count + 1
                            ),
                          let records = exactInt(
                            "historical_records_discarded",
                            in: row
                          ),
                          records >= previousDiscardedRecords else {
                        throw VerificationError
                            .acknowledgementProofFailed
                    }
                    previousDiscardedRecords = records
                    acknowledgementConfirmations.append((
                        index: rowIndex,
                        token: tokenString,
                        records: records
                    ))
                    localAcknowledgementConfirmations += 1
                    pendingAcknowledgement = nil
                    rowIndex += 1

                case "command":
                    switch string("opcode", in: row) {
                    case "17":
                        guard !sliceReachedHistoryComplete,
                              pendingAcknowledgement == nil,
                              string("phase_after_accept", in: row)
                                == "streaming",
                              let payload = bytes(
                                hex: string("payload", in: row)
                              ),
                              payload.count == 9,
                              payload[0] == 0x01 else {
                            throw VerificationError
                                .acknowledgementProofFailed
                        }
                        let token = hex(Array(payload.dropFirst()))
                        guard consumedAcknowledgementTokens.insert(token)
                            .inserted else {
                            throw VerificationError
                                .acknowledgementProofFailed
                        }
                        pendingAcknowledgement = (
                            index: rowIndex,
                            token: token
                        )
                        acknowledgementCommands.append((
                            index: rowIndex,
                            token: token
                        ))
                        localAcknowledgementCommands += 1
                        rowIndex += 1

                    case "14":
                        guard !sliceReachedHistoryComplete,
                              pendingAcknowledgement == nil,
                              sliceAttempt < sliceCount,
                              times[rowIndex] - serveAt
                                >= AtriaWhoop4SacrificialFastDrainPolicy
                                    .sliceTimeout else {
                            throw VerificationError.invalidOrdering
                        }
                        _ = try verifyCommand(
                            row,
                            opcode: "14",
                            payload: "00",
                            phaseAfterAccept: "complete"
                        )
                        guard rowIndex + 1 < rows.count,
                              string(
                                "event",
                                in: rows[rowIndex + 1]
                              ) == "discard_drain_checkpoint" else {
                            throw VerificationError.invalidOrdering
                        }
                        let checkpoint = rows[rowIndex + 1]
                        let lastToken =
                            acknowledgementConfirmations.last?.token
                                ?? "none"
                        guard uint("slice_attempt", in: checkpoint)
                                == UInt64(sliceAttempt),
                              bool("abort_confirmed", in: checkpoint)
                                == true,
                              bool("accepted", in: checkpoint) == false,
                              bool("fabricated_ack", in: checkpoint)
                                == false,
                              uint(
                                "acknowledged_chunks",
                                in: checkpoint
                              ) == UInt64(
                                acknowledgementConfirmations.count
                              ),
                              exactInt(
                                "historical_records_discarded",
                                in: checkpoint
                              ) == previousDiscardedRecords,
                              string(
                                "last_confirmed_ack_token",
                                in: checkpoint
                              ) == lastToken,
                              localHistoryStarts > 0,
                              localAcknowledgementCommands
                                == localAcknowledgementConfirmations,
                              localHistoryStarts
                                == localAcknowledgementCommands
                                || localHistoryStarts
                                    == localAcknowledgementCommands + 1
                        else {
                            throw VerificationError.countMismatch
                        }
                        previousPreflight = preflight
                        sliceAttempt += 1
                        rowIndex += 2
                        continue sliceLoop

                    case "22":
                        guard sliceAttempt == sliceCount,
                              sliceReachedHistoryComplete,
                              pendingAcknowledgement == nil,
                              localHistoryStarts > 0,
                              localHistoryStarts
                                == localAcknowledgementCommands,
                              localAcknowledgementCommands
                                == localAcknowledgementConfirmations
                        else {
                            throw VerificationError.invalidOrdering
                        }
                        break streamLoop

                    default:
                        throw VerificationError.unexpectedEvent(
                            index: rowIndex
                        )
                    }

                default:
                    throw VerificationError.unexpectedEvent(
                        index: rowIndex
                    )
                }
            }

            guard sliceReachedHistoryComplete,
                  sliceAttempt == sliceCount,
                  rowIndex + 3 < rows.count,
                  let rootPreflight,
                  let historyCompleteRecords,
                  !acknowledgementCommands.isEmpty,
                  acknowledgementCommands.count
                    == acknowledgementConfirmations.count,
                  acknowledgementCommands.map(\.token)
                    == acknowledgementConfirmations.map(\.token),
                  zip(
                    acknowledgementCommands,
                    acknowledgementConfirmations
                  ).allSatisfy({ $0.0.index < $0.1.index }) else {
                throw VerificationError.acknowledgementProofFailed
            }

            let postflightSequence = try verifyCommand(
                rows[rowIndex],
                opcode: "22",
                payload: "00",
                phaseAfterAccept: "complete"
            )
            try verifyRangeResponse(
                rows[rowIndex + 1],
                sequence: postflightSequence
            )
            guard string("event", in: rows[rowIndex + 2])
                    == "postflight_range" else {
                throw VerificationError.invalidOrdering
            }
            let postflight = try cursor(
                rows[rowIndex + 2],
                event: "postflight_range"
            )
            guard bool("accepted", in: rows[rowIndex + 2]) == true,
                  uint("slice_attempt", in: rows[rowIndex + 2])
                    == UInt64(sliceAttempt),
                  postflight.capacity == rootPreflight.capacity,
                  cursorPendingCountIsCoherent(postflight),
                  AtriaWhoop4SacrificialFastDrainPolicy
                    .hasAcceptableCursorCollapse(
                        preflight: rootPreflight,
                        postflight: postflight
                    ) else {
                throw VerificationError.postconditionFailed
            }

            let finished = rows[rowIndex + 3]
            guard string("event", in: finished)
                    == "discard_drain_finished",
                  rowIndex + 4 == rows.count,
                  bool("accepted", in: finished) == true,
                  bool("fabricated_ack", in: finished) == false,
                  bool("local_data_mutation", in: finished) == false,
                  bool("ack_in_flight", in: finished) == false,
                  string("pending_ack_token", in: finished) == "none",
                  string("reason", in: finished)
                    == "verified_backlog_collapse",
                  uint("slice_attempt", in: finished)
                    == UInt64(sliceAttempt),
                  uint("acknowledged_chunks", in: finished)
                    == UInt64(acknowledgementConfirmations.count),
                  let finalRecords = exactInt(
                    "historical_records_discarded",
                    in: finished
                  ),
                  finalRecords == historyCompleteRecords,
                  finalRecords
                    == acknowledgementConfirmations.last?.records,
                  string("last_confirmed_ack_token", in: finished)
                    == acknowledgementConfirmations.last?.token,
                  uint("evidence_records", in: finished).map({
                      $0 <= UInt64(finalRecords)
                  }) == true else {
                throw VerificationError.countMismatch
            }

            return Proof(
                runID: runID,
                completedAt: Date(
                    timeIntervalSince1970: times[times.count - 1]
                ),
                preflightPendingRecords:
                    rootPreflight.pendingRecords,
                postflightPendingRecords:
                    postflight.pendingRecords,
                acknowledgedChunks:
                    acknowledgementConfirmations.count,
                historicalRecordsDiscarded:
                    historyCompleteRecords
            )
        }

        throw VerificationError.incompleteReceipt
    }

    private static func verifyCommand(
        _ row: Row,
        opcode: String,
        payload: String,
        phaseAfterAccept: String
    ) throws -> UInt8 {
        guard string("opcode", in: row) == opcode,
              string("payload", in: row) == payload,
              string("phase_after_accept", in: row) == phaseAfterAccept,
              let rawSequence = uint("sequence", in: row),
              rawSequence <= UInt8.max else {
            throw VerificationError.invalidField(
                event: "command",
                field: "opcode_payload_phase_or_sequence"
            )
        }
        return UInt8(rawSequence)
    }

    private static func verifyRangeResponse(
        _ row: Row,
        sequence: UInt8
    ) throws {
        guard uint("request_sequence_echo", in: row)
                == UInt64(sequence),
              let payload = bytes(
                hex: string("payload_hex", in: row)
              ),
              payload.count >= 4,
              payload[0] == 0x24,
              payload[2] == 0x22,
              payload[3] == sequence else {
            throw VerificationError.invalidField(
                event: "range_response_raw",
                field: "payload_or_sequence"
            )
        }
    }

    private static func cursor(
        _ row: Row,
        event: String
    ) throws -> AtriaWhoop4SacrificialFastDrainPolicy.CursorObservation {
        guard let write = uint("write_cursor", in: row),
              let read = uint("read_cursor", in: row),
              let capacity = uint("capacity", in: row),
              let pending = uint("pending_records", in: row),
              write <= UInt32.max,
              read <= UInt32.max,
              capacity > 0,
              capacity <= UInt32.max,
              pending <= UInt32.max else {
            throw VerificationError.invalidField(
                event: event,
                field: "cursor"
            )
        }
        return .init(
            writeCursor: UInt32(write),
            readCursor: UInt32(read),
            capacity: UInt32(capacity),
            pendingRecords: UInt32(pending)
        )
    }

    private static func cursorPendingCountIsCoherent(
        _ cursor: AtriaWhoop4SacrificialFastDrainPolicy.CursorObservation
    ) -> Bool {
        guard cursor.capacity > 0,
              cursor.pendingRecords <= cursor.capacity else { return false }
        let capacity = UInt64(cursor.capacity)
        let write = UInt64(cursor.writeCursor) % capacity
        let read = UInt64(cursor.readCursor) % capacity
        let distance = (write + capacity - read) % capacity
        return distance == UInt64(cursor.pendingRecords)
            || (cursor.pendingRecords == cursor.capacity && distance == 0)
    }

    private static func parseRows(_ data: Data) throws -> [Row] {
        guard !data.isEmpty else {
            throw VerificationError.incompleteReceipt
        }
        let lines = data.split(
            separator: 0x0A,
            omittingEmptySubsequences: false
        )
        var nonemptyLines = Array(lines)
        if nonemptyLines.last?.isEmpty == true {
            nonemptyLines.removeLast()
        }
        guard !nonemptyLines.isEmpty,
              nonemptyLines.allSatisfy({ !$0.isEmpty }) else {
            throw VerificationError.malformedJSONL
        }
        return try nonemptyLines.map { line in
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(
                    with: Data(line)
                )
            } catch {
                throw VerificationError.malformedJSONL
            }
            guard let row = object as? Row else {
                throw VerificationError.malformedJSONL
            }
            return row
        }
    }

    private static func string(_ key: String, in row: Row) -> String? {
        row[key] as? String
    }

    private static func bool(_ key: String, in row: Row) -> Bool? {
        guard let value = row[key] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        return value.boolValue
    }

    private static func number(_ key: String, in row: Row) -> Double? {
        guard let value = row[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else {
            return nil
        }
        return value.doubleValue
    }

    private static func uint(_ key: String, in row: Row) -> UInt64? {
        guard let value = number(key, in: row),
              value.isFinite,
              value >= 0,
              value.rounded(.towardZero) == value,
              value < 18_446_744_073_709_551_616 else {
            return nil
        }
        return UInt64(value)
    }

    private static func exactInt(_ key: String, in row: Row) -> Int? {
        guard let value = uint(key, in: row),
              value <= UInt64(Int.max) else { return nil }
        return Int(value)
    }

    private static func bytes(hex: String?) -> [UInt8]? {
        guard let hex,
              !hex.isEmpty,
              hex.count.isMultiple(of: 2),
              hex.unicodeScalars.allSatisfy({
                  CharacterSet(
                    charactersIn: "0123456789abcdef"
                  ).contains($0)
              }) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
