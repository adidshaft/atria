import CoreFoundation
import Foundation

/// Pure verifier for the fsynced receipt emitted by the attended, one-shot
/// sacrificial WHOOP 4 history trim. It reads caller-supplied bytes only and
/// cannot issue BLE commands, retry a trim, or mutate local application data.
enum AtriaWhoop4SacrificialHistoryTrimReceiptVerifier {
    struct Proof: Equatable, Sendable {
        let runID: UUID
        let completedAt: Date
        let preflightPendingRecords: UInt32
        let postflightPendingRecords: UInt32
    }

    enum VerificationError: Error, Equatable {
        case malformedJSONL
        case incompleteReceipt
        case unexpectedEvent(index: Int)
        case invalidField(event: String, field: String)
        case wrongRunID
        case invalidOrdering
        case postconditionFailed
    }

    private typealias Row = [String: Any]

    private static let expectedEvents = [
        "trim_started",
        "command",
        "range_response_raw",
        "preflight_range",
        "command",
        "force_trim_response_matched",
        "force_trim_write_result",
        "command",
        "range_response_raw",
        "postflight_range",
        "trim_finished",
    ]

    static func verify(
        jsonl data: Data,
        expectedRunID: UUID
    ) throws -> Proof {
        let rows = try parseRows(data)
        guard rows.count == expectedEvents.count else {
            throw VerificationError.incompleteReceipt
        }
        for (index, expectedEvent) in expectedEvents.enumerated() {
            guard string("event", in: rows[index]) == expectedEvent else {
                throw VerificationError.unexpectedEvent(index: index)
            }
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
            pair in pair.0 <= pair.1
        }) else {
            throw VerificationError.invalidOrdering
        }

        let started = rows[0]
        guard string("trace", in: started)
                == "2200,19fefefefefefefefe00,2200",
              bool("automatic_retry", in: started) == false,
              bool("local_data_mutation", in: started) == false else {
            throw VerificationError.invalidField(
                event: "trim_started",
                field: "trace_or_safety_flags"
            )
        }
        guard let runIDString = string("run_id", in: started),
              let runID = UUID(uuidString: runIDString) else {
            throw VerificationError.invalidField(
                event: "trim_started",
                field: "run_id"
            )
        }
        guard runID == expectedRunID else {
            throw VerificationError.wrongRunID
        }

        let preflightSequence = try verifyCommand(
            rows[1],
            opcode: "22",
            payload: "00",
            phaseAfterAccept: "trim"
        )
        try verifyRangeResponse(rows[2], sequence: preflightSequence)

        let preflight = try cursor(
            rows[3],
            event: "preflight_range"
        )
        guard preflight.pendingRecords > 2 else {
            throw VerificationError.postconditionFailed
        }

        let trimSequence = try verifyCommand(
            rows[4],
            opcode: "19",
            payload: "fefefefefefefefe00",
            phaseAfterAccept: "postflight"
        )
        try verifyTrimResponse(rows[5], sequence: trimSequence)
        guard bool("logical_response_matched", in: rows[6]) == true,
              bool("automatic_retry", in: rows[6]) == false,
              string("result", in: rows[6]) == "confirmed" else {
            throw VerificationError.invalidField(
                event: "force_trim_write_result",
                field: "result_or_safety_flags"
            )
        }

        let postflightSequence = try verifyCommand(
            rows[7],
            opcode: "22",
            payload: "00",
            phaseAfterAccept: "complete"
        )
        guard preflightSequence != trimSequence,
              trimSequence != postflightSequence,
              preflightSequence != postflightSequence else {
            throw VerificationError.invalidOrdering
        }
        try verifyRangeResponse(rows[8], sequence: postflightSequence)

        let postflight = try cursor(
            rows[9],
            event: "postflight_range"
        )
        guard bool("accepted", in: rows[9]) == true,
              postflight.pendingRecords <= 2,
              AtriaWhoop4SacrificialHistoryTrimPolicy
                .hasAcceptablePostTrimCollapse(
                    preflight: preflight,
                    postflight: postflight
                ) else {
            throw VerificationError.postconditionFailed
        }

        let finished = rows[10]
        guard bool("accepted", in: finished) == true,
              bool("trim_issued", in: finished) == true,
              bool("logical_response_matched", in: finished) == true,
              bool("automatic_retry", in: finished) == false,
              bool("local_data_mutation", in: finished) == false else {
            throw VerificationError.invalidField(
                event: "trim_finished",
                field: "completion_or_safety_flags"
            )
        }

        return Proof(
            runID: runID,
            completedAt: Date(timeIntervalSince1970: times[10]),
            preflightPendingRecords: preflight.pendingRecords,
            postflightPendingRecords: postflight.pendingRecords
        )
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
        guard uint("request_sequence_echo", in: row) == UInt64(sequence),
              let payload = bytes(hex: string("payload_hex", in: row)),
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

    private static func verifyTrimResponse(
        _ row: Row,
        sequence: UInt8
    ) throws {
        guard uint("request_sequence_echo", in: row) == UInt64(sequence),
              let payload = bytes(hex: string("payload_hex", in: row)),
              payload.count >= 4,
              payload[0] == 0x24,
              payload[2] == 0x19,
              payload[3] == sequence else {
            throw VerificationError.invalidField(
                event: "force_trim_response_matched",
                field: "payload_or_sequence"
            )
        }
    }

    private static func cursor(
        _ row: Row,
        event: String
    ) throws -> AtriaWhoop4SacrificialHistoryTrimPolicy.CursorObservation {
        guard let write = uint("write_cursor", in: row),
              let read = uint("read_cursor", in: row),
              let pending = uint("pending_records", in: row),
              write <= UInt32.max,
              read <= UInt32.max,
              pending <= UInt32.max else {
            throw VerificationError.invalidField(
                event: event,
                field: "cursor"
            )
        }
        return .init(
            writeCursor: UInt32(write),
            readCursor: UInt32(read),
            pendingRecords: UInt32(pending)
        )
    }

    private static func parseRows(_ data: Data) throws -> [Row] {
        guard !data.isEmpty else {
            throw VerificationError.incompleteReceipt
        }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
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
                object = try JSONSerialization.jsonObject(with: Data(line))
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
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func number(_ key: String, in row: Row) -> Double? {
        guard let value = row[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    private static func uint(_ key: String, in row: Row) -> UInt64? {
        guard let value = number(key, in: row),
              value.isFinite,
              value >= 0,
              value.rounded(.towardZero) == value,
              value < 18_446_744_073_709_551_616 else { return nil }
        return UInt64(value)
    }

    private static func bytes(hex: String?) -> [UInt8]? {
        guard let hex,
              !hex.isEmpty,
              hex.count.isMultiple(of: 2),
              hex.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef")
                    .contains($0)
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
}
