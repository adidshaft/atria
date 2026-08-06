import XCTest
@testable import Atria

final class AtriaWhoop4SacrificialFastDrainReceiptVerifierTests:
    XCTestCase {
    private typealias Verifier =
        AtriaWhoop4SacrificialFastDrainReceiptVerifier
    private let runID = UUID(
        uuidString: "6DDAA19D-D31C-4221-9F29-B31A7417AFB5"
    )!

    func testReconciliationLaunchRequiresOneExactRunID() throws {
        let arguments = [
            "Atria",
            Verifier.reconciliationModeArgument,
            AtriaWhoop4SacrificialFastDrainPolicy.runIDArgument,
            runID.uuidString,
        ]
        XCTAssertEqual(
            try Verifier.reconciliationRunID(arguments: arguments),
            runID
        )
        XCTAssertThrowsError(
            try Verifier.reconciliationRunID(arguments: [
                "Atria",
                AtriaWhoop4SacrificialFastDrainPolicy.runIDArgument,
                runID.uuidString,
            ])
        ) {
            XCTAssertEqual($0 as? Verifier.LaunchError, .modeMissing)
        }
        XCTAssertThrowsError(
            try Verifier.reconciliationRunID(arguments: arguments + [
                AtriaWhoop4SacrificialFastDrainPolicy.runIDArgument,
                UUID().uuidString,
            ])
        ) {
            XCTAssertEqual($0 as? Verifier.LaunchError, .runIDRepeated)
        }
        XCTAssertThrowsError(
            try Verifier.reconciliationRunID(arguments: [
                "Atria",
                Verifier.reconciliationModeArgument,
                AtriaWhoop4SacrificialFastDrainPolicy.runIDArgument,
                "not-a-uuid",
            ])
        ) {
            XCTAssertEqual($0 as? Verifier.LaunchError, .malformedRunID)
        }
    }

    func testAcceptsCompleteTokenBoundHistoryCompleteAndCursorCollapse()
        throws {
        let proof = try Verifier.verify(
            jsonl: jsonl(validRows()),
            expectedRunID: runID
        )
        XCTAssertEqual(proof.runID, runID)
        XCTAssertEqual(
            proof.completedAt.timeIntervalSince1970,
            113
        )
        XCTAssertEqual(proof.preflightPendingRecords, 64)
        XCTAssertEqual(proof.postflightPendingRecords, 0)
        XCTAssertEqual(proof.acknowledgedChunks, 1)
        XCTAssertEqual(proof.historicalRecordsDiscarded, 5)
    }

    func testAcceptsCoherentTwoSliceDrainWithConfirmedAbort() throws {
        let proof = try Verifier.verify(
            jsonl: jsonl(validTwoSliceRows()),
            expectedRunID: runID
        )

        XCTAssertEqual(proof.runID, runID)
        XCTAssertEqual(proof.completedAt.timeIntervalSince1970, 194)
        XCTAssertEqual(proof.preflightPendingRecords, 64)
        XCTAssertEqual(proof.postflightPendingRecords, 0)
        XCTAssertEqual(proof.acknowledgedChunks, 2)
        XCTAssertEqual(proof.historicalRecordsDiscarded, 9)
    }

    func testRejectsTwoSliceAbortOrCursorTampering() {
        var wrongAbort = validTwoSliceRows()
        wrongAbort[8]["opcode"] = "16"
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(wrongAbort),
            expectedRunID: runID
        ))

        var prematureAbort = validTwoSliceRows()
        prematureAbort[8]["received_at_unix"] = 170
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(prematureAbort),
            expectedRunID: runID
        ))

        var regressedCursor = validTwoSliceRows()
        regressedCursor[12]["read_cursor"] = 40
        regressedCursor[12]["pending_records"] = 70
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(regressedCursor),
            expectedRunID: runID
        )) {
            XCTAssertEqual(
                $0 as? Verifier.VerificationError,
                .postconditionFailed
            )
        }
    }

    func testRejectsAcknowledgementTokenReplayAcrossSlices() {
        var replayed = validTwoSliceRows()
        replayed[15]["payload"] = "015179010012000000"
        replayed[17]["token"] = "5179010012000000"
        replayed[21]["last_confirmed_ack_token"] =
            "5179010012000000"

        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(replayed),
            expectedRunID: runID
        )) {
            XCTAssertEqual(
                $0 as? Verifier.VerificationError,
                .acknowledgementProofFailed
            )
        }
    }

    func testRejectsWrongRunIncompleteOrUnexpectedSliceReceipt() {
        var wrongRun = validRows()
        wrongRun[0]["run_id"] = UUID().uuidString
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(wrongRun),
            expectedRunID: runID
        )) {
            XCTAssertEqual(
                $0 as? Verifier.VerificationError,
                .wrongRunID
            )
        }

        let incomplete = validRows().filter {
            $0["event"] as? String != "history_complete"
        }
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(incomplete),
            expectedRunID: runID
        ))

        var checkpointed = validRows()
        checkpointed.insert([
            "event": "discard_drain_checkpoint",
            "received_at_unix": 108.5,
        ], at: 9)
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(checkpointed),
            expectedRunID: runID
        ))
    }

    func testRejectsFabricatedMismatchedOrReplayedAcknowledgement() {
        var fabricated = validRows()
        fabricated[8]["fabricated_ack"] = true
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(fabricated),
            expectedRunID: runID
        )) {
            XCTAssertEqual(
                $0 as? Verifier.VerificationError,
                .acknowledgementProofFailed
            )
        }

        var mismatched = validRows()
        mismatched[8]["token"] = "5279010012000000"
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(mismatched),
            expectedRunID: runID
        )) {
            XCTAssertEqual(
                $0 as? Verifier.VerificationError,
                .acknowledgementProofFailed
            )
        }

        var fakeCommand = validRows()
        fakeCommand[6]["payload"] = "005179010012000000"
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(fakeCommand),
            expectedRunID: runID
        )) {
            XCTAssertEqual(
                $0 as? Verifier.VerificationError,
                .acknowledgementProofFailed
            )
        }
    }

    func testRejectsUnsafeTerminalOrIncoherentCounts() {
        var inFlight = validRows()
        inFlight[12]["ack_in_flight"] = true
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(inFlight),
            expectedRunID: runID
        )) {
            XCTAssertEqual(
                $0 as? Verifier.VerificationError,
                .countMismatch
            )
        }

        var pending = validRows()
        pending[12]["pending_ack_token"] = "5179010012000000"
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(pending),
            expectedRunID: runID
        ))

        var wrongCount = validRows()
        wrongCount[12]["acknowledged_chunks"] = 2
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(wrongCount),
            expectedRunID: runID
        ))

        var mutated = validRows()
        mutated[12]["local_data_mutation"] = true
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(mutated),
            expectedRunID: runID
        ))
    }

    func testRejectsCursorMismatchOrUnacceptedCollapse() {
        var incoherentPreflight = validRows()
        incoherentPreflight[3]["pending_records"] = 63
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(incoherentPreflight),
            expectedRunID: runID
        )) {
            XCTAssertEqual(
                $0 as? Verifier.VerificationError,
                .postconditionFailed
            )
        }

        var notCollapsed = validRows()
        notCollapsed[11]["accepted"] = false
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(notCollapsed),
            expectedRunID: runID
        ))

        var residual = validRows()
        residual[11]["write_cursor"] = 55
        residual[11]["pending_records"] = 3
        XCTAssertThrowsError(try Verifier.verify(
            jsonl: jsonl(residual),
            expectedRunID: runID
        ))
    }

    func testDebugReconciliationIsBookkeepingOnlyAndSuspendsBluetooth()
        throws {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
            .appendingPathComponent("AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)
        let function = try XCTUnwrap(source.range(
            of: "private func reconcileVerifiedSacrificialFastDrainIfRequested("
        ))
        let nextFunction = try XCTUnwrap(source.range(
            of: "private func reconcileVerifiedSacrificialHistoryTrimIfRequested(",
            range: function.upperBound..<source.endIndex
        ))
        let body = String(source[
            function.lowerBound..<nextFunction.lowerBound
        ])
        XCTAssertTrue(body.contains(
            ".retireWindowsBeforeVerifiedStrapHistoryReset("
        ))
        XCTAssertTrue(body.contains(
            ".abandonDrainingAuthorityAfterVerifiedStrapHistoryReset("
        ))
        let authorityRetirement = try XCTUnwrap(body.range(
            of: ".abandonDrainingAuthorityAfterVerifiedStrapHistoryReset("
        ))
        let gapRetirement = try XCTUnwrap(body.range(
            of: ".retireWindowsBeforeVerifiedStrapHistoryReset("
        ))
        XCTAssertLessThan(
            authorityRetirement.lowerBound,
            gapRetirement.lowerBound,
            "a throwing authority mutation must not follow destructive gap retirement"
        )
        XCTAssertTrue(body.contains(
            "if retirement.remainingWindows == 0"
        ))
        XCTAssertFalse(body.contains("sendCommand("))
        XCTAssertFalse(body.contains("writeValue("))
        XCTAssertFalse(body.contains("discoverServices("))
        let initializer = try XCTUnwrap(source.range(
            of: "init(startsBluetooth: Bool) {"
        ))
        let earlyBranch = try XCTUnwrap(source.range(
            of: "if fastDrainReconciliationOnly {",
            range: initializer.lowerBound..<source.endIndex
        ))
        let ordinaryLaunch = try XCTUnwrap(source.range(
            of: "let launchDefaults = UserDefaults.standard",
            range: earlyBranch.upperBound..<source.endIndex
        ))
        let earlyBody = String(source[
            earlyBranch.lowerBound..<ordinaryLaunch.lowerBound
        ])
        XCTAssertTrue(earlyBody.contains(
            "reconcileVerifiedSacrificialFastDrainIfRequested("
        ))
        XCTAssertTrue(earlyBody.contains("return"))
        XCTAssertFalse(earlyBody.contains(
            "repairCrossConnectionCoverage("
        ))
        XCTAssertFalse(earlyBody.contains(
            "beginHistoricalArchiveWarmBackgroundLease("
        ))
        XCTAssertFalse(earlyBody.contains("CBCentralManager("))
        XCTAssertTrue(source.contains(
            "verified_fast_drain_reconciliation_no_ble"
        ))
    }

    private func validRows() -> [[String: Any]] {
        [
            [
                "event": "discard_drain_started",
                "fabricated_ack": false,
                "generation": 1,
                "local_data_mutation": false,
                "maximum_slice_attempts": 4,
                "reason": "characteristics_discovered",
                "received_at_unix": 101,
                "run_id": runID.uuidString,
                "slice_timeout_seconds": 75,
                "timeout_seconds": 120,
            ],
            [
                "event": "command",
                "opcode": "22",
                "payload": "00",
                "phase_after_accept": "serve",
                "received_at_unix": 102,
                "sequence": 0,
            ],
            [
                "event": "range_response_raw",
                "payload_hex": "24002200",
                "received_at_unix": 103,
                "request_sequence_echo": 0,
            ],
            [
                "capacity": 128,
                "continuation": false,
                "event": "preflight_range",
                "pending_records": 64,
                "read_cursor": 46,
                "received_at_unix": 104,
                "slice_attempt": 1,
                "write_cursor": 110,
            ],
            [
                "event": "command",
                "opcode": "16",
                "payload": "00",
                "phase_after_accept": "streaming",
                "received_at_unix": 105,
                "sequence": 1,
            ],
            [
                "event": "history_start",
                "received_at_unix": 106,
                "sequence": 60,
            ],
            [
                "event": "command",
                "opcode": "17",
                "payload": "015179010012000000",
                "phase_after_accept": "streaming",
                "received_at_unix": 107,
                "sequence": 2,
            ],
            [
                "acknowledged_chunks": 0,
                "event": "history_complete",
                "historical_records_discarded": 5,
                "received_at_unix": 108,
                "sequence": 63,
            ],
            [
                "acknowledged_chunks": 1,
                "event": "history_end_ack_confirmed",
                "fabricated_ack": false,
                "historical_records_discarded": 5,
                "received_at_unix": 109,
                "sequence": 61,
                "token": "5179010012000000",
            ],
            [
                "event": "command",
                "opcode": "22",
                "payload": "00",
                "phase_after_accept": "complete",
                "received_at_unix": 110,
                "sequence": 3,
            ],
            [
                "event": "range_response_raw",
                "payload_hex": "24002203",
                "received_at_unix": 111,
                "request_sequence_echo": 3,
            ],
            [
                "accepted": true,
                "capacity": 128,
                "event": "postflight_range",
                "pending_records": 0,
                "read_cursor": 52,
                "received_at_unix": 112,
                "slice_attempt": 1,
                "write_cursor": 52,
            ],
            [
                "accepted": true,
                "ack_in_flight": false,
                "acknowledged_chunks": 1,
                "event": "discard_drain_finished",
                "evidence_records": 0,
                "fabricated_ack": false,
                "historical_records_discarded": 5,
                "last_confirmed_ack_token": "5179010012000000",
                "local_data_mutation": false,
                "pending_ack_token": "none",
                "reason": "verified_backlog_collapse",
                "received_at_unix": 113,
                "slice_attempt": 1,
            ],
        ]
    }

    private func validTwoSliceRows() -> [[String: Any]] {
        [
            [
                "event": "discard_drain_started",
                "fabricated_ack": false,
                "generation": 1,
                "local_data_mutation": false,
                "maximum_slice_attempts": 4,
                "reason": "characteristics_discovered",
                "received_at_unix": 101,
                "run_id": runID.uuidString,
                "slice_timeout_seconds": 75,
                "timeout_seconds": 120,
            ],
            [
                "event": "command",
                "opcode": "22",
                "payload": "00",
                "phase_after_accept": "serve",
                "received_at_unix": 102,
                "sequence": 0,
            ],
            [
                "event": "range_response_raw",
                "payload_hex": "24002200",
                "received_at_unix": 103,
                "request_sequence_echo": 0,
            ],
            [
                "capacity": 128,
                "continuation": false,
                "event": "preflight_range",
                "pending_records": 64,
                "read_cursor": 46,
                "received_at_unix": 104,
                "slice_attempt": 1,
                "write_cursor": 110,
            ],
            [
                "event": "command",
                "opcode": "16",
                "payload": "00",
                "phase_after_accept": "streaming",
                "received_at_unix": 105,
                "sequence": 1,
            ],
            [
                "event": "history_start",
                "received_at_unix": 106,
                "sequence": 60,
            ],
            [
                "event": "command",
                "opcode": "17",
                "payload": "015179010012000000",
                "phase_after_accept": "streaming",
                "received_at_unix": 107,
                "sequence": 2,
            ],
            [
                "acknowledged_chunks": 1,
                "event": "history_end_ack_confirmed",
                "fabricated_ack": false,
                "historical_records_discarded": 5,
                "received_at_unix": 108,
                "sequence": 61,
                "token": "5179010012000000",
            ],
            [
                "event": "command",
                "opcode": "14",
                "payload": "00",
                "phase_after_accept": "complete",
                "received_at_unix": 181,
                "sequence": 3,
            ],
            [
                "abort_confirmed": true,
                "accepted": false,
                "acknowledged_chunks": 1,
                "event": "discard_drain_checkpoint",
                "fabricated_ack": false,
                "historical_records_discarded": 5,
                "last_confirmed_ack_token": "5179010012000000",
                "received_at_unix": 182,
                "slice_attempt": 1,
            ],
            [
                "event": "command",
                "opcode": "22",
                "payload": "00",
                "phase_after_accept": "serve",
                "received_at_unix": 183,
                "sequence": 4,
            ],
            [
                "event": "range_response_raw",
                "payload_hex": "24002204",
                "received_at_unix": 184,
                "request_sequence_echo": 4,
            ],
            [
                "capacity": 128,
                "continuation": true,
                "event": "preflight_range",
                "pending_records": 58,
                "read_cursor": 52,
                "received_at_unix": 185,
                "slice_attempt": 2,
                "write_cursor": 110,
            ],
            [
                "event": "command",
                "opcode": "16",
                "payload": "00",
                "phase_after_accept": "streaming",
                "received_at_unix": 186,
                "sequence": 5,
            ],
            [
                "event": "history_start",
                "received_at_unix": 187,
                "sequence": 62,
            ],
            [
                "event": "command",
                "opcode": "17",
                "payload": "015279010012000000",
                "phase_after_accept": "streaming",
                "received_at_unix": 188,
                "sequence": 6,
            ],
            [
                "acknowledged_chunks": 1,
                "event": "history_complete",
                "historical_records_discarded": 9,
                "received_at_unix": 189,
                "sequence": 63,
            ],
            [
                "acknowledged_chunks": 2,
                "event": "history_end_ack_confirmed",
                "fabricated_ack": false,
                "historical_records_discarded": 9,
                "received_at_unix": 190,
                "sequence": 64,
                "token": "5279010012000000",
            ],
            [
                "event": "command",
                "opcode": "22",
                "payload": "00",
                "phase_after_accept": "complete",
                "received_at_unix": 191,
                "sequence": 7,
            ],
            [
                "event": "range_response_raw",
                "payload_hex": "24002207",
                "received_at_unix": 192,
                "request_sequence_echo": 7,
            ],
            [
                "accepted": true,
                "capacity": 128,
                "event": "postflight_range",
                "pending_records": 0,
                "read_cursor": 110,
                "received_at_unix": 193,
                "slice_attempt": 2,
                "write_cursor": 110,
            ],
            [
                "accepted": true,
                "ack_in_flight": false,
                "acknowledged_chunks": 2,
                "event": "discard_drain_finished",
                "evidence_records": 0,
                "fabricated_ack": false,
                "historical_records_discarded": 9,
                "last_confirmed_ack_token": "5279010012000000",
                "local_data_mutation": false,
                "pending_ack_token": "none",
                "reason": "verified_backlog_collapse",
                "received_at_unix": 194,
                "slice_attempt": 2,
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
