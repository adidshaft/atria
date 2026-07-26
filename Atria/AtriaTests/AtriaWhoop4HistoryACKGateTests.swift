import XCTest
@testable import Atria

final class AtriaWhoop4HistoryACKGateTests: XCTestCase {
    private let identity = AtriaWhoop4HistoryACKGate.Identity(
        generation: 8,
        boundaryID: "enddata:0102030405060708",
        commandSequence: 41,
        attempt: 1
    )

    func testMatchingGATTSuccessAcceptsACKWithoutInventingLogicalResponse() {
        var gate = AtriaWhoop4HistoryACKGate()
        gate.arm(identity)

        XCTAssertEqual(
            gate.completeGATT(
                generation: 8,
                boundaryID: identity.boundaryID,
                commandSequence: 41,
                succeeded: true
            ),
            .acceptedByGATT(identity)
        )
        XCTAssertNil(gate.identity)
    }

    func testStaleGenerationAndMismatchedSequenceCannotSettleCurrentACK() {
        var gate = AtriaWhoop4HistoryACKGate()
        gate.arm(identity)

        XCTAssertEqual(
            gate.completeGATT(
                generation: 7,
                boundaryID: identity.boundaryID,
                commandSequence: 41,
                succeeded: true
            ),
            .ignored
        )
        XCTAssertEqual(
            gate.completeGATT(
                generation: 8,
                boundaryID: identity.boundaryID,
                commandSequence: 40,
                succeeded: true
            ),
            .ignored
        )
        XCTAssertEqual(gate.identity, identity)
    }

    func testLateLogicalResponseIsIgnoredAfterGATTAlreadySettledACK() {
        var gate = AtriaWhoop4HistoryACKGate()
        gate.arm(identity)
        _ = gate.completeGATT(
            generation: 8,
            boundaryID: identity.boundaryID,
            commandSequence: 41,
            succeeded: true
        )

        XCTAssertEqual(
            gate.receiveCommandResponse(
                [0x24, 0x6c, 0x17, 0x00, 0x01, 0x00, 0x00, 0x00],
                generation: 8
            ),
            .ignored
        )
        XCTAssertNil(gate.identity)
    }

    func testRejectedOrMalformedLogicalResponseCannotAcceptACK() {
        for response in [
            [UInt8](arrayLiteral: 0x24, 0x6c, 0x17, 0x01, 0x01, 0x00, 0x00, 0x00),
            [UInt8](arrayLiteral: 0x24, 0x6c, 0x17, 0x00, 0x01)
        ] {
            var gate = AtriaWhoop4HistoryACKGate()
            gate.arm(identity)

            XCTAssertEqual(
                gate.receiveCommandResponse(response, generation: 8),
                .failed(identity)
            )
            XCTAssertNil(gate.identity)
        }
    }

    func testLogicalResponseBeforeGATTConfirmationIsBufferedUntilWriteSucceeds() {
        var gate = AtriaWhoop4HistoryACKGate()
        gate.arm(identity)
        XCTAssertTrue(gate.requiresHistoryCallbackDeferral)

        XCTAssertEqual(
            gate.receiveCommandResponse(
                [0x24, 0x69, 0x17, 0x00, 0x01, 0x00, 0x00, 0x00],
                generation: 8
            ),
            .awaitingGATTConfirmation(identity)
        )
        XCTAssertEqual(gate.identity, identity)
        XCTAssertEqual(
            gate.completeGATT(
                generation: 8,
                boundaryID: identity.boundaryID,
                commandSequence: 41,
                succeeded: true
            ),
            .accepted(
                identity: identity,
                responseSequence: 0x69,
                responsePayload: [0x24, 0x69, 0x17, 0x00, 0x01, 0x00, 0x00, 0x00]
            )
        )
        XCTAssertNil(gate.identity)
        XCTAssertFalse(gate.requiresHistoryCallbackDeferral)
    }

    func testBufferedLogicalResponseStillFailsWhenGATTWriteFails() {
        var gate = AtriaWhoop4HistoryACKGate()
        gate.arm(identity)
        XCTAssertEqual(
            gate.receiveCommandResponse(
                [0x24, 0x69, 0x17, 0x00, 0x01, 0x00, 0x00, 0x00],
                generation: 8
            ),
            .awaitingGATTConfirmation(identity)
        )

        XCTAssertEqual(
            gate.completeGATT(
                generation: 8,
                boundaryID: identity.boundaryID,
                commandSequence: 41,
                succeeded: false
            ),
            .failed(identity)
        )
        XCTAssertNil(gate.identity)
    }

    func testStaleGenerationResponseCannotBeBufferedBeforeGATTConfirmation() {
        var gate = AtriaWhoop4HistoryACKGate()
        gate.arm(identity)

        XCTAssertEqual(
            gate.receiveCommandResponse(
                [0x24, 0x68, 0x17, 0x00, 0x01, 0x00, 0x00, 0x00],
                generation: 7
            ),
            .ignored
        )
        XCTAssertEqual(
            gate.completeGATT(
                generation: 8,
                boundaryID: identity.boundaryID,
                commandSequence: 41,
                succeeded: true
            ),
            .acceptedByGATT(identity)
        )
        XCTAssertNil(gate.identity)
    }

    func testTimeoutFailsOnlyTheExactAttempt() {
        var gate = AtriaWhoop4HistoryACKGate()
        gate.arm(identity)
        XCTAssertEqual(gate.timeout(.init(
            generation: 8,
            boundaryID: identity.boundaryID,
            commandSequence: 40,
            attempt: 1
        )), .ignored)
        XCTAssertEqual(gate.timeout(identity), .failed(identity))
        XCTAssertNil(gate.identity)
    }

    func testCoalescedACKAndNextHistoryStartDefersStartUntilGATTProof() throws {
        let ackFrame = encodeFrame(
            [0x24, 0xd0, 0x17, 0x00, 0x01, 0x00, 0x00, 0x00]
        )
        let nextStartFrame = encodeFrame([0x31, 0xd1])
        var coalesced = Data(ackFrame)
        coalesced.append(nextStartFrame)
        let frames = AtriaWhoop4FrameReassembler().feed(
            coalesced,
            source: "stream5"
        )
        XCTAssertEqual(frames.count, 2)

        var gate = AtriaWhoop4HistoryACKGate()
        gate.arm(identity)
        let ackPayload = try XCTUnwrap(
            AtriaFrame.parse(frames[0], source: "stream5")
        ).payload
        XCTAssertEqual(
            gate.receiveCommandResponse([UInt8](ackPayload), generation: 8),
            .awaitingGATTConfirmation(identity)
        )

        var deferredFrames: [Data] = []
        if gate.requiresHistoryCallbackDeferral {
            deferredFrames.append(frames[1])
        }
        XCTAssertEqual(deferredFrames, [nextStartFrame])

        guard case .accepted = gate.completeGATT(
            generation: 8,
            boundaryID: identity.boundaryID,
            commandSequence: 41,
            succeeded: true
        ) else {
            return XCTFail("matching GATT proof must release the buffered page")
        }
        XCTAssertFalse(gate.requiresHistoryCallbackDeferral)
        XCTAssertEqual(deferredFrames, [nextStartFrame])
    }

    func testManagerPausesDropsAndReleasesOrderedPostACKCallbacks() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let managerURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let manager = try String(contentsOf: managerURL, encoding: .utf8)

        XCTAssertTrue(manager.contains(
            "guard !historyACKGate.requiresHistoryCallbackDeferral else"
        ))
        XCTAssertTrue(manager.contains("AtriaWhoop4HistoricalIngressSpool"))
        XCTAssertTrue(manager.contains("let retainedPostACKIngress"))
        XCTAssertTrue(manager.contains("Do not delete disk ingress after an ACK failure"))
        XCTAssertTrue(manager.contains(
            "historicalAdmissionFailed = true"
        ))
        XCTAssertTrue(manager.contains("scheduleHistoricalTransportEventDrain()"))
        XCTAssertTrue(manager.contains(
            "self.pendingHistoryEndACK == nil"
        ))
        XCTAssertTrue(manager.contains(
            "!self.historyACKGate.requiresHistoryCallbackDeferral"
        ))
    }

    func testAcceptedHistoryACKDoesNotResendSendHistoricalMidStream() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let managerURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let manager = try String(contentsOf: managerURL, encoding: .utf8)

        let acceptanceStart = try XCTUnwrap(manager.range(
            of: "private func completeHistoricalACKAcceptance("
        ))
        let acceptanceTail = manager[acceptanceStart.lowerBound...]
        let replayStart = try XCTUnwrap(acceptanceTail.range(
            of: "private func reackDurableHistoricalReplay("
        ))
        let acceptanceBody = acceptanceTail[..<replayStart.lowerBound]
        XCTAssertFalse(acceptanceBody.contains(
            "armHistoricalPageContinuationAfterACK("
        ))

        let replayTail = acceptanceTail[replayStart.lowerBound...]
        let continuationDefinition = try XCTUnwrap(replayTail.range(
            of: "private func armHistoricalPageContinuationAfterACK("
        ))
        let replayBody = replayTail[..<continuationDefinition.lowerBound]
        XCTAssertFalse(replayBody.contains(
            "armHistoricalPageContinuationAfterACK("
        ))
        XCTAssertTrue(replayBody.contains("await_strap_owned_next_page"))
    }

    func testForegroundLifecycleCannotPreemptAnInFlightHistoryPage() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let managerURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let manager = try String(contentsOf: managerURL, encoding: .utf8)
        let start = try XCTUnwrap(manager.range(
            of: "func handleInteractiveForeground(rest: Int, maxHR: Int)"
        ))
        let tail = manager[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(
            of: "private func reassertHeartRateNotificationsIfConnected"
        ))
        let foregroundHandler = tail[..<end.lowerBound]

        XCTAssertFalse(foregroundHandler.contains(
            "yieldHistoricalTransportToExplicitWorkoutIfNeeded"
        ))
        XCTAssertTrue(manager.contains(
            "yieldHistoricalTransportToExplicitWorkoutIfNeeded(reason: reason)"
        ), "a genuine persisted workout must retain history-preemption priority")
    }
}
