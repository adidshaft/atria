import XCTest
@testable import Atria

final class AtriaWhoop4SacrificialHistoryTrimReceiptVerifierTests:
    XCTestCase {
    private typealias Verifier =
        AtriaWhoop4SacrificialHistoryTrimReceiptVerifier
    private let runID = UUID(
        uuidString: "8EAA3941-A158-448C-BF08-8DA62BB94927"
    )!

    func testAcceptsOnlyCompleteSuccessfulNineByteTrimReceipt() throws {
        let proof = try Verifier.verify(
            jsonl: jsonl(validRows()),
            expectedRunID: runID
        )
        XCTAssertEqual(proof.runID, runID)
        XCTAssertEqual(proof.completedAt.timeIntervalSince1970, 111)
        XCTAssertEqual(proof.preflightPendingRecords, 130_780)
        XCTAssertEqual(proof.postflightPendingRecords, 1)
    }

    func testRejectsMalformedWrongRunAndIncompleteReceipt() {
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: Data("{bad json}\n".utf8),
            expectedRunID: runID
        ))

        var wrongRun = validRows()
        wrongRun[0]["run_id"] = UUID().uuidString
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(wrongRun),
            expectedRunID: runID
        )) {
            XCTAssertEqual($0 as? Verifier.VerificationError, .wrongRunID)
        }

        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(Array(validRows().dropLast())),
            expectedRunID: runID
        )) {
            XCTAssertEqual(
                $0 as? Verifier.VerificationError,
                .incompleteReceipt
            )
        }
    }

    func testRejectsReorderedOrDuplicateTrimCommands() {
        var reordered = validRows()
        reordered.swapAt(3, 4)
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(reordered),
            expectedRunID: runID
        ))

        var duplicate = validRows()
        duplicate.insert(duplicate[4], at: 5)
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(duplicate),
            expectedRunID: runID
        )) {
            XCTAssertEqual(
                $0 as? Verifier.VerificationError,
                .incompleteReceipt
            )
        }
    }

    func testRejectsOldEightByteSentinelAndIncompleteLogicalProof() {
        var oldPayload = validRows()
        oldPayload[0]["trace"] = "2200,19fefefefefefefefe,2200"
        oldPayload[4]["payload"] = "fefefefefefefefe"
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(oldPayload),
            expectedRunID: runID
        ))

        var noLogicalMatch = validRows()
        noLogicalMatch[6]["logical_response_matched"] = false
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(noLogicalMatch),
            expectedRunID: runID
        ))
    }

    func testRejectsUnacceptedOrInsufficientBacklogCollapse() {
        var notAccepted = validRows()
        notAccepted[9]["accepted"] = false
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(notAccepted),
            expectedRunID: runID
        ))

        var largeResidual = validRows()
        largeResidual[9]["pending_records"] = 3
        largeResidual[9]["write_cursor"] = 62_525
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(largeResidual),
            expectedRunID: runID
        ))

        var tinyPreflight = validRows()
        tinyPreflight[3]["pending_records"] = 2
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(tinyPreflight),
            expectedRunID: runID
        ))
    }

    private func validRows() -> [[String: Any]] {
        [
            [
                "automatic_retry": false,
                "event": "trim_started",
                "generation": 1,
                "local_data_mutation": false,
                "received_at_unix": 101,
                "run_id": runID.uuidString,
                "trace": "2200,19fefefefefefefefe00,2200",
            ],
            [
                "event": "command",
                "opcode": "22",
                "payload": "00",
                "phase_after_accept": "trim",
                "received_at_unix": 102,
                "sequence": 0,
            ],
            [
                "event": "range_response_raw",
                "payload_hex": "249022000101",
                "received_at_unix": 103,
                "request_sequence_echo": 0,
            ],
            [
                "event": "preflight_range",
                "pending_records": 130_780,
                "read_cursor": 62_814,
                "received_at_unix": 104,
                "write_cursor": 62_522,
            ],
            [
                "event": "command",
                "opcode": "19",
                "payload": "fefefefefefefefe00",
                "phase_after_accept": "postflight",
                "received_at_unix": 105,
                "sequence": 1,
            ],
            [
                "event": "force_trim_response_matched",
                "payload_hex": "2491190101000000",
                "received_at_unix": 106,
                "request_sequence_echo": 1,
            ],
            [
                "automatic_retry": false,
                "event": "force_trim_write_result",
                "logical_response_matched": true,
                "received_at_unix": 107,
                "result": "confirmed",
            ],
            [
                "event": "command",
                "opcode": "22",
                "payload": "00",
                "phase_after_accept": "complete",
                "received_at_unix": 108,
                "sequence": 2,
            ],
            [
                "event": "range_response_raw",
                "payload_hex": "249222020101",
                "received_at_unix": 109,
                "request_sequence_echo": 2,
            ],
            [
                "accepted": true,
                "event": "postflight_range",
                "pending_records": 1,
                "read_cursor": 62_522,
                "received_at_unix": 110,
                "write_cursor": 62_523,
            ],
            [
                "accepted": true,
                "automatic_retry": false,
                "event": "trim_finished",
                "local_data_mutation": false,
                "logical_response_matched": true,
                "received_at_unix": 111,
                "trim_issued": true,
            ],
        ]
    }

    private func jsonl(_ rows: [[String: Any]]) -> Data {
        var data = Data()
        for row in rows {
            data.append(try! JSONSerialization.data(
                withJSONObject: row,
                options: [.sortedKeys]
            ))
            data.append(0x0A)
        }
        return data
    }
}
