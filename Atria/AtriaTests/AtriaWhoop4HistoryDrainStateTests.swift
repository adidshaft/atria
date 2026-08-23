import XCTest
@testable import Atria

final class AtriaWhoop4HistoryDrainStateTests: XCTestCase {
    func testThreeReplayConfirmedCadencedFlashJumpsAdmitNextMatchingOccurrence() {
        let confirmed = [UInt16(100), 200, 300].map { previous in
            AtriaWhoop4HistoryDrainState.ContinuitySnapshot.Transition(
                streamKey: 0,
                previousFrameKey: "previous-\(previous)",
                currentFrameKey: "current-\(previous + 10)",
                previousSequence: previous,
                currentSequence: previous + 10
            )
        }
        var state = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(state.restoreContinuitySnapshot(.init(
            schemaVersion: AtriaWhoop4HistoryDrainState.ContinuitySnapshot.currentSchemaVersion,
            pending: nil,
            confirmed: confirmed
        )))
        _ = state.begin(generation: 1)
        let previous: [UInt8] = [0x2f, 0, 0, 0x90, 0x01] // 400
        let candidate: [UInt8] = [0x2f, 0, 0, 0x9a, 0x01] // 410
        _ = state.receiveFrame(
            generation: 1,
            frameKey: "previous-400",
            payload: previous
        )

        XCTAssertEqual(
            state.receiveFrame(
                generation: 1,
                frameKey: "current-410",
                payload: candidate
            ),
            [.persistFrame(
                generation: 1,
                frameKey: "current-410",
                payload: candidate
            )]
        )
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.continuitySnapshot.confirmed.count, 4)
    }

    func testCadencedFlashPatternStillRejectsChangedJump() {
        let confirmed = [UInt16(100), 200, 300].map { previous in
            AtriaWhoop4HistoryDrainState.ContinuitySnapshot.Transition(
                streamKey: 0,
                previousFrameKey: "previous-\(previous)",
                currentFrameKey: "current-\(previous + 10)",
                previousSequence: previous,
                currentSequence: previous + 10
            )
        }
        var state = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(state.restoreContinuitySnapshot(.init(
            schemaVersion: AtriaWhoop4HistoryDrainState.ContinuitySnapshot.currentSchemaVersion,
            pending: nil,
            confirmed: confirmed
        )))
        _ = state.begin(generation: 2)
        let previous: [UInt8] = [0x2f, 0, 0, 0x90, 0x01] // 400
        let changedJump: [UInt8] = [0x2f, 0, 0, 0x9b, 0x01] // 411
        _ = state.receiveFrame(
            generation: 2,
            frameKey: "previous-400",
            payload: previous
        )

        XCTAssertEqual(
            state.receiveFrame(
                generation: 2,
                frameKey: "changed-411",
                payload: changedJump
            ),
            [.failed(
                generation: 2,
                failure: .protocolViolation(
                    "history_sequence_gap_unconfirmed_previous_400_received_411"
                )
            )]
        )
    }

    func testCadencedFlashPatternRequiresThreeConfirmedOccurrences() {
        let confirmed = [UInt16(100), 200].map { previous in
            AtriaWhoop4HistoryDrainState.ContinuitySnapshot.Transition(
                streamKey: 0,
                previousFrameKey: "previous-\(previous)",
                currentFrameKey: "current-\(previous + 10)",
                previousSequence: previous,
                currentSequence: previous + 10
            )
        }
        var state = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(state.restoreContinuitySnapshot(.init(
            schemaVersion: AtriaWhoop4HistoryDrainState.ContinuitySnapshot.currentSchemaVersion,
            pending: nil,
            confirmed: confirmed
        )))
        _ = state.begin(generation: 3)
        _ = state.receiveFrame(
            generation: 3,
            frameKey: "previous-300",
            payload: [0x2f, 0, 0, 0x2c, 0x01]
        )

        XCTAssertEqual(
            state.receiveFrame(
                generation: 3,
                frameKey: "current-310",
                payload: [0x2f, 0, 0, 0x36, 0x01]
            ),
            [.failed(
                generation: 3,
                failure: .protocolViolation(
                    "history_sequence_gap_unconfirmed_previous_300_received_310"
                )
            )]
        )
    }

    func testCadencedFlashPatternStillRejectsChangedCadence() {
        let confirmed = [UInt16(100), 200, 300].map { previous in
            AtriaWhoop4HistoryDrainState.ContinuitySnapshot.Transition(
                streamKey: 0,
                previousFrameKey: "previous-\(previous)",
                currentFrameKey: "current-\(previous + 10)",
                previousSequence: previous,
                currentSequence: previous + 10
            )
        }
        var state = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(state.restoreContinuitySnapshot(.init(
            schemaVersion: AtriaWhoop4HistoryDrainState.ContinuitySnapshot.currentSchemaVersion,
            pending: nil,
            confirmed: confirmed
        )))
        _ = state.begin(generation: 4)
        _ = state.receiveFrame(
            generation: 4,
            frameKey: "previous-401",
            payload: [0x2f, 0, 0, 0x91, 0x01]
        )

        XCTAssertEqual(
            state.receiveFrame(
                generation: 4,
                frameKey: "current-411",
                payload: [0x2f, 0, 0, 0x9b, 0x01]
            ),
            [.failed(
                generation: 4,
                failure: .protocolViolation(
                    "history_sequence_gap_unconfirmed_previous_401_received_411"
                )
            )]
        )
    }

    func testPendingForwardDiscontinuitySurvivesProcessRestartAndExactReplayConfirms() {
        let first: [UInt8] = [0x2f, 0, 0, 0x10, 0x00]
        let gap: [UInt8] = [0x2f, 0, 0, 0x12, 0x00]
        var original = AtriaWhoop4HistoryDrainState()
        _ = original.begin(generation: 14)
        _ = original.receiveFrame(generation: 14, frameKey: "first", payload: first)
        XCTAssertNotNil(original.receiveFrame(generation: 14, frameKey: "gap", payload: gap).first)

        let durableSnapshot = original.continuitySnapshot
        XCTAssertNotNil(durableSnapshot.pending)
        var relaunched = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(relaunched.restoreContinuitySnapshot(durableSnapshot))
        _ = relaunched.begin(generation: 15)
        XCTAssertEqual(
            relaunched.receiveFrame(generation: 15, frameKey: "gap", payload: gap),
            [.persistFrame(generation: 15, frameKey: "gap", payload: gap)]
        )
        XCTAssertNil(relaunched.failure)
        XCTAssertNil(relaunched.continuitySnapshot.pending)
        XCTAssertEqual(relaunched.continuitySnapshot.confirmed.count, 1)
    }

    func testRestoredReplayConfirmsWhenProcessLocalGenerationNumberRestartsEqual() {
        let first: [UInt8] = [0x2f, 0, 0, 0x30, 0]
        let gap: [UInt8] = [0x2f, 0, 0, 0x34, 0]
        var original = AtriaWhoop4HistoryDrainState()
        _ = original.begin(generation: 1)
        _ = original.receiveFrame(generation: 1, frameKey: "first", payload: first)
        _ = original.receiveFrame(generation: 1, frameKey: "gap", payload: gap)

        var relaunched = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(relaunched.restoreContinuitySnapshot(original.continuitySnapshot))
        _ = relaunched.begin(generation: 1)
        XCTAssertEqual(
            relaunched.receiveFrame(generation: 1, frameKey: "gap", payload: gap),
            [.persistFrame(generation: 1, frameKey: "gap", payload: gap)]
        )
        XCTAssertNil(relaunched.failure)
        XCTAssertEqual(relaunched.continuitySnapshot.confirmed.count, 1)
    }

    func testSnapshotRejectsPendingTransitionAlreadyPresentInConfirmedSet() {
        let transition = AtriaWhoop4HistoryDrainState.ContinuitySnapshot.Transition(
            streamKey: 0x2f,
            previousFrameKey: "a",
            currentFrameKey: "b",
            previousSequence: 10,
            currentSequence: 12
        )
        let snapshot = AtriaWhoop4HistoryDrainState.ContinuitySnapshot(
            schemaVersion: AtriaWhoop4HistoryDrainState.ContinuitySnapshot.currentSchemaVersion,
            pending: .init(transition: transition, firstObservedGeneration: 1),
            confirmed: [transition]
        )
        var reducer = AtriaWhoop4HistoryDrainState()
        XCTAssertFalse(reducer.restoreContinuitySnapshot(snapshot))
        XCTAssertNil(reducer.continuitySnapshot.pending)
        XCTAssertTrue(reducer.continuitySnapshot.confirmed.isEmpty)
    }

    func testConfirmedFlashHolesSurviveBeyond64AndEvictOnlyAtCentralBound() {
        var reducer = AtriaWhoop4HistoryDrainState()
        var generation: UInt64 = 1
        _ = reducer.begin(generation: generation)
        var sequence: UInt16 = 0
        var priorKey = "seed"
        _ = reducer.receiveFrame(
            generation: generation,
            frameKey: priorKey,
            payload: [0x2f, 0, 0, 0, 0]
        )

        for index in 1...AtriaWhoop4HistoryDrainState.maximumConfirmedForwardDiscontinuities {
            sequence &+= 2
            let key = "gap-\(index)"
            let payload: [UInt8] = [
                0x2f, 0, 0,
                UInt8(truncatingIfNeeded: sequence),
                UInt8(truncatingIfNeeded: sequence >> 8),
            ]
            _ = reducer.receiveFrame(
                generation: generation,
                frameKey: key,
                payload: payload
            )
            generation += 1
            _ = reducer.begin(generation: generation)
            _ = reducer.receiveFrame(
                generation: generation,
                frameKey: key,
                payload: payload
            )
            priorKey = key
        }

        let atBound = reducer.continuitySnapshot
        XCTAssertEqual(atBound.confirmed.count, 512)
        XCTAssertEqual(atBound.confirmed.first?.currentFrameKey, "gap-1")
        var restored = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(restored.restoreContinuitySnapshot(atBound),
                      "a snapshot well beyond the old 64-hole limit must remain valid")

        sequence &+= 2
        let overflowKey = "gap-513"
        let overflowPayload: [UInt8] = [
            0x2f, 0, 0,
            UInt8(truncatingIfNeeded: sequence),
            UInt8(truncatingIfNeeded: sequence >> 8),
        ]
        _ = reducer.receiveFrame(
            generation: generation,
            frameKey: overflowKey,
            payload: overflowPayload
        )
        generation += 1
        _ = reducer.begin(generation: generation)
        _ = reducer.receiveFrame(
            generation: generation,
            frameKey: overflowKey,
            payload: overflowPayload
        )
        let overflowed = reducer.continuitySnapshot
        XCTAssertEqual(overflowed.confirmed.count, 512)
        XCTAssertEqual(overflowed.confirmed.first?.currentFrameKey, "gap-2")
        XCTAssertEqual(overflowed.confirmed.last?.currentFrameKey, overflowKey)
    }

    func testRestartedPendingDiscontinuityStillRejectsDroppedNotificationMismatch() {
        var original = AtriaWhoop4HistoryDrainState()
        _ = original.begin(generation: 20)
        _ = original.receiveFrame(generation: 20, frameKey: "first", payload: [0x2f, 0, 0, 0x20, 0])
        _ = original.receiveFrame(generation: 20, frameKey: "gap", payload: [0x2f, 0, 0, 0x24, 0])

        var relaunched = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(relaunched.restoreContinuitySnapshot(original.continuitySnapshot))
        _ = relaunched.begin(generation: 21)
        let effects = relaunched.receiveFrame(
            generation: 21,
            frameKey: "different",
            payload: [0x2f, 0, 0, 0x25, 0]
        )
        XCTAssertEqual(effects, [.failed(
            generation: 21,
            failure: .protocolViolation("history_sequence_gap_replay_mismatch_expected_36_received_37_stream_0")
        )])
    }

    func testConfirmedTransitionSnapshotSurvivesSecondRestart() {
        let first: [UInt8] = [0x2f, 0, 0, 0x10, 0]
        let gap: [UInt8] = [0x2f, 0, 0, 0x13, 0]
        var firstProcess = AtriaWhoop4HistoryDrainState()
        _ = firstProcess.begin(generation: 1)
        _ = firstProcess.receiveFrame(generation: 1, frameKey: "a", payload: first)
        _ = firstProcess.receiveFrame(generation: 1, frameKey: "b", payload: gap)
        var secondProcess = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(secondProcess.restoreContinuitySnapshot(firstProcess.continuitySnapshot))
        _ = secondProcess.begin(generation: 2)
        _ = secondProcess.receiveFrame(generation: 2, frameKey: "b", payload: gap)

        var thirdProcess = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(thirdProcess.restoreContinuitySnapshot(secondProcess.continuitySnapshot))
        _ = thirdProcess.begin(generation: 3)
        _ = thirdProcess.receiveFrame(generation: 3, frameKey: "a", payload: first)
        XCTAssertEqual(
            thirdProcess.receiveFrame(generation: 3, frameKey: "b", payload: gap),
            [.persistFrame(generation: 3, frameKey: "b", payload: gap)]
        )
        XCTAssertNil(thirdProcess.failure)
    }

    func testDurableAdmissionRemovesGenerationWideIdentityLimit() {
        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 30)

        XCTAssertEqual(
            state.receiveFrame(generation: 30, frameKey: "a", payload: [0xA0]),
            [.persistFrame(generation: 30, frameKey: "a", payload: [0xA0])]
        )
        XCTAssertEqual(
            state.receiveFrame(generation: 30, frameKey: "b", payload: [0xB0]),
            [.persistFrame(generation: 30, frameKey: "b", payload: [0xB0])]
        )
        XCTAssertTrue(
            state.receiveFrame(
                generation: 30,
                frameKey: "a",
                payload: [0xA0],
                admission: .duplicateInCurrentIncarnation
            ).isEmpty,
            "the disk authority, not a generation-wide Set, classifies the duplicate"
        )
        XCTAssertEqual(
            state.receiveFrame(generation: 30, frameKey: "c", payload: [0xC0]),
            [.persistFrame(generation: 30, frameKey: "c", payload: [0xC0])]
        )
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.peakAcceptedFrameIdentityCount, 3)
        XCTAssertEqual(state.pendingPersistenceCount, 3)
    }

    func testACKedBatchIdentityMustSurviveUntilTerminalToProtectSequenceCursor() {
        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 31)
        let first: [UInt8] = [0x2f, 0, 0, 0x10, 0x00]
        let second: [UInt8] = [0x2f, 0, 0, 0x11, 0x00]
        let third: [UInt8] = [0x2f, 0, 0, 0x12, 0x00]

        _ = state.receiveFrame(generation: 31, frameKey: "first", payload: first)
        _ = state.receiveFrame(generation: 31, frameKey: "second", payload: second)
        _ = state.historyEnd(
            generation: 31,
            boundaryID: "end-1",
            ackPayload: [0x01]
        )
        _ = state.persistenceCompleted(
            generation: 31,
            frameKey: "first",
            succeeded: true
        )
        XCTAssertEqual(
            state.persistenceCompleted(
                generation: 31,
                frameKey: "second",
                succeeded: true
            ),
            [.durableFlush(generation: 31, boundary: .batch("end-1"))]
        )
        _ = state.durableFlushCompleted(
            generation: 31,
            boundary: .batch("end-1"),
            succeeded: true
        )
        _ = state.ackCompleted(
            generation: 31,
            boundaryID: "end-1",
            succeeded: true
        )

        XCTAssertTrue(
            state.receiveFrame(
                generation: 31,
                frameKey: "first",
                payload: first,
                admission: .duplicateInCurrentIncarnation
            ).isEmpty,
            "durable archive dedupe occurs too late to stop an old replay from rewinding sequence state"
        )
        XCTAssertEqual(state.acceptedFrameIdentityCountForDiagnostics, 2)
        XCTAssertEqual(
            state.receiveFrame(generation: 31, frameKey: "third", payload: third),
            [.persistFrame(generation: 31, frameKey: "third", payload: third)]
        )
        XCTAssertNil(state.failure)
    }

    func testTerminalAndNewGenerationReleaseAcceptedIdentityCapacity() {
        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 32)
        _ = state.receiveFrame(generation: 32, frameKey: "old", payload: [0xA0])
        _ = state.persistenceCompleted(
            generation: 32,
            frameKey: "old",
            succeeded: true
        )
        XCTAssertEqual(
            state.historyComplete(generation: 32),
            [.durableFlush(generation: 32, boundary: .terminal(0))]
        )
        XCTAssertEqual(
            state.durableFlushCompleted(
                generation: 32,
                boundary: .terminal(0),
                succeeded: true
            ),
            [.finished(generation: 32)]
        )
        XCTAssertEqual(state.acceptedFrameIdentityCountForDiagnostics, 0)
        XCTAssertEqual(state.peakAcceptedFrameIdentityCount, 1)

        _ = state.begin(generation: 33)
        XCTAssertEqual(state.peakAcceptedFrameIdentityCount, 0)
        XCTAssertEqual(
            state.receiveFrame(generation: 33, frameKey: "new", payload: [0xB0]),
            [.persistFrame(generation: 33, frameKey: "new", payload: [0xB0])]
        )
    }

    func testFailureDiagnosticsRetainPhaseBeforeReducerEntersFailedState() {
        var state = AtriaWhoop4HistoryDrainState()
        state.begin(generation: 6)

        XCTAssertTrue(state.canReceiveFrame)

        XCTAssertEqual(
            state.receiveFrame(generation: 6, frameKey: "a", payload: [0xA0]),
            [.persistFrame(generation: 6, frameKey: "a", payload: [0xA0])]
        )
        XCTAssertTrue(state.historyEnd(
            generation: 6,
            boundaryID: "end-1",
            ackPayload: [0x01, 0x11]
        ).isEmpty)
        XCTAssertEqual(state.phaseForDiagnostics, "waiting_for_batch_persistence")
        XCTAssertFalse(state.canReceiveFrame)

        XCTAssertEqual(
            state.receiveFrame(generation: 6, frameKey: "b", payload: [0xB0]),
            [.failed(
                generation: 6,
                failure: .protocolViolation("frame_received_after_batch_boundary")
            )]
        )
        XCTAssertEqual(state.phaseForDiagnostics, "failed")
        XCTAssertEqual(
            state.failureOriginPhaseForDiagnostics,
            "waiting_for_batch_persistence"
        )
        XCTAssertFalse(state.canReceiveFrame)
    }

    func testFrameAdmissionReopensOnlyAfterDurableBoundaryACK() {
        var state = AtriaWhoop4HistoryDrainState()
        state.begin(generation: 61)
        XCTAssertTrue(state.canReceiveFrame)

        _ = state.receiveFrame(generation: 61, frameKey: "page-1", payload: [0xA0])
        _ = state.persistenceCompleted(
            generation: 61,
            frameKey: "page-1",
            succeeded: true
        )
        XCTAssertEqual(
            state.historyEnd(
                generation: 61,
                boundaryID: "end-1",
                ackPayload: [0x01, 0x11]
            ),
            [.durableFlush(generation: 61, boundary: .batch("end-1"))]
        )
        XCTAssertFalse(state.canReceiveFrame)

        _ = state.durableFlushCompleted(
            generation: 61,
            boundary: .batch("end-1"),
            succeeded: true
        )
        XCTAssertFalse(state.canReceiveFrame)

        _ = state.ackCompleted(
            generation: 61,
            boundaryID: "end-1",
            succeeded: true
        )
        XCTAssertTrue(state.canReceiveFrame)
        XCTAssertEqual(
            state.receiveFrame(generation: 61, frameKey: "page-2", payload: [0xB0]),
            [.persistFrame(generation: 61, frameKey: "page-2", payload: [0xB0])]
        )
    }

    func testDrainsMultipleBatchesAndACKsEachBoundaryOnce() {
        var state = AtriaWhoop4HistoryDrainState()
        state.begin(generation: 7)

        XCTAssertEqual(
            state.receiveFrame(generation: 7, frameKey: "a", payload: [0xA0]),
            [.persistFrame(generation: 7, frameKey: "a", payload: [0xA0])]
        )
        XCTAssertEqual(
            state.receiveFrame(generation: 7, frameKey: "b", payload: [0xB0]),
            [.persistFrame(generation: 7, frameKey: "b", payload: [0xB0])]
        )
        XCTAssertTrue(state.historyEnd(
            generation: 7,
            boundaryID: "end-1",
            ackPayload: [0x01, 0x11]
        ).isEmpty)
        XCTAssertTrue(state.persistenceCompleted(
            generation: 7,
            frameKey: "b",
            succeeded: true
        ).isEmpty)
        XCTAssertEqual(
            state.persistenceCompleted(generation: 7, frameKey: "a", succeeded: true),
            [.durableFlush(generation: 7, boundary: .batch("end-1"))]
        )
        XCTAssertEqual(
            state.durableFlushCompleted(
                generation: 7,
                boundary: .batch("end-1"),
                succeeded: true
            ),
            [.sendACK(
                generation: 7,
                boundaryID: "end-1",
                payload: [0x01, 0x11],
                attempt: 1
            )]
        )
        XCTAssertTrue(state.ackCompleted(
            generation: 7,
            boundaryID: "end-1",
            succeeded: true
        ).isEmpty)
        XCTAssertTrue(state.historyEnd(
            generation: 7,
            boundaryID: "end-1",
            ackPayload: [0x01, 0x11]
        ).isEmpty, "a replayed boundary must not emit a second ACK")

        XCTAssertEqual(
            state.receiveFrame(generation: 7, frameKey: "c", payload: [0xC0]),
            [.persistFrame(generation: 7, frameKey: "c", payload: [0xC0])]
        )
        XCTAssertTrue(state.historyEnd(
            generation: 7,
            boundaryID: "end-2",
            ackPayload: [0x01, 0x22]
        ).isEmpty)
        XCTAssertEqual(
            state.persistenceCompleted(generation: 7, frameKey: "c", succeeded: true),
            [.durableFlush(generation: 7, boundary: .batch("end-2"))]
        )
        XCTAssertEqual(
            state.durableFlushCompleted(
                generation: 7,
                boundary: .batch("end-2"),
                succeeded: true
            ),
            [.sendACK(
                generation: 7,
                boundaryID: "end-2",
                payload: [0x01, 0x22],
                attempt: 1
            )]
        )
        XCTAssertTrue(state.ackCompleted(
            generation: 7,
            boundaryID: "end-2",
            succeeded: true
        ).isEmpty)

        XCTAssertEqual(state.historyComplete(generation: 7), [.finished(generation: 7)])
        XCTAssertTrue(state.isFinished)
        XCTAssertEqual(state.acknowledgedBatchCount, 2)
        XCTAssertEqual(state.persistedFrameCount, 3)
    }

    func testTerminalTailFlushesAfterAllPersistenceAndDoesNotACK() {
        var state = AtriaWhoop4HistoryDrainState()
        state.begin(generation: 3)
        _ = state.receiveFrame(generation: 3, frameKey: "tail-a", payload: [1])
        _ = state.receiveFrame(generation: 3, frameKey: "tail-b", payload: [2])

        XCTAssertTrue(state.historyComplete(generation: 3).isEmpty)
        XCTAssertTrue(state.persistenceCompleted(
            generation: 3,
            frameKey: "tail-a",
            succeeded: true
        ).isEmpty)
        XCTAssertEqual(
            state.persistenceCompleted(generation: 3, frameKey: "tail-b", succeeded: true),
            [.durableFlush(generation: 3, boundary: .terminal(0))]
        )
        XCTAssertEqual(
            state.durableFlushCompleted(
                generation: 3,
                boundary: .terminal(0),
                succeeded: true
            ),
            [.finished(generation: 3)]
        )
        XCTAssertEqual(state.acknowledgedBatchCount, 0)
        XCTAssertTrue(state.isFinished)
    }

    func testEmptyTerminalFinishesWithoutFlushOrACK() {
        var state = AtriaWhoop4HistoryDrainState()
        state.begin(generation: 9)

        XCTAssertEqual(state.historyComplete(generation: 9), [.finished(generation: 9)])
        XCTAssertTrue(state.isFinished)
    }

    func testStaleGenerationCallbacksCannotAdvanceNewDrain() {
        var state = AtriaWhoop4HistoryDrainState()
        state.begin(generation: 10)
        _ = state.receiveFrame(generation: 10, frameKey: "new", payload: [0x10])

        XCTAssertTrue(state.persistenceCompleted(
            generation: 9,
            frameKey: "new",
            succeeded: true
        ).isEmpty)
        XCTAssertTrue(state.historyEnd(
            generation: 9,
            boundaryID: "stale-end",
            ackPayload: [0x09]
        ).isEmpty)
        XCTAssertTrue(state.historyComplete(generation: 9).isEmpty)
        XCTAssertEqual(state.pendingPersistenceCount, 1)
        XCTAssertFalse(state.isFinished)

        state.begin(generation: 9)
        XCTAssertEqual(state.generation, 10, "an older begin must not reset live progress")
    }

    func testPersistenceFailureFailsClosedBeforeFlushOrACK() {
        var state = AtriaWhoop4HistoryDrainState()
        state.begin(generation: 4)
        _ = state.receiveFrame(generation: 4, frameKey: "bad", payload: [0xFF])
        _ = state.historyEnd(
            generation: 4,
            boundaryID: "end",
            ackPayload: [1]
        )

        XCTAssertEqual(
            state.persistenceCompleted(generation: 4, frameKey: "bad", succeeded: false),
            [.failed(generation: 4, failure: .persistence(frameKey: "bad"))]
        )
        XCTAssertEqual(state.failure, .persistence(frameKey: "bad"))
        XCTAssertTrue(state.durableFlushCompleted(
            generation: 4,
            boundary: .batch("end"),
            succeeded: true
        ).isEmpty)
        XCTAssertTrue(state.ackCompleted(
            generation: 4,
            boundaryID: "end",
            succeeded: true
        ).isEmpty)
        XCTAssertFalse(state.isFinished)
    }

    func testFirstSeenForwardDiscontinuityFailsBeforeFlushOrACK() {
        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 14)
        _ = state.receiveFrame(
            generation: 14,
            frameKey: "first",
            payload: [0x2f, 0, 0, 0x10, 0x00]
        )

        let failure = AtriaWhoop4HistoryDrainState.Failure.protocolViolation(
            "history_sequence_gap_unconfirmed_previous_16_received_18"
        )
        XCTAssertEqual(
            state.receiveFrame(
                generation: 14,
                frameKey: "gap",
                payload: [0x2f, 0, 0, 0x12, 0x00]
            ),
            [.failed(generation: 14, failure: failure)]
        )
        XCTAssertEqual(state.failure, failure)
        XCTAssertTrue(state.durableFlushCompleted(
            generation: 14,
            boundary: .batch("end"),
            succeeded: true
        ).isEmpty)
        XCTAssertTrue(state.ackCompleted(
            generation: 14,
            boundaryID: "end",
            succeeded: true
        ).isEmpty)
    }

    func testAuthorityBoundFullDrainPersistsUnconfirmedForwardDiscontinuityBeforeACK() {
        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 14)
        let first: [UInt8] = [0x2f, 0x18, 0x05, 0x18, 0xa5] // 42264
        let jump: [UInt8] = [0x2f, 0x18, 0x05, 0xc9, 0xa9] // 43465
        _ = state.receiveFrame(generation: 14, frameKey: "42264", payload: first)

        XCTAssertEqual(
            state.receiveFrame(
                generation: 14,
                frameKey: "43465",
                payload: jump,
                permitsUnconfirmedForwardDiscontinuity: true
            ),
            [.persistFrame(generation: 14, frameKey: "43465", payload: jump)]
        )
        XCTAssertNil(state.failure)
        XCTAssertNotNil(state.continuitySnapshot.pending,
                        "the raw page is retained, but the discontinuity remains replay evidence")
        XCTAssertEqual(state.sequenceRestartCount, 1)

        XCTAssertTrue(state.historyEnd(
            generation: 14,
            boundaryID: "end",
            ackPayload: [1]
        ).isEmpty)
        XCTAssertTrue(state.persistenceCompleted(
            generation: 14,
            frameKey: "42264",
            succeeded: true
        ).isEmpty)
        XCTAssertEqual(state.persistenceCompleted(
            generation: 14,
            frameKey: "43465",
            succeeded: true
        ), [.durableFlush(generation: 14, boundary: .batch("end"))])
    }

    func testBackwardOverlapDoesNotRewindForwardSequenceCursor() {
        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 14)

        XCTAssertEqual(state.receiveFrame(
            generation: 14,
            frameKey: "forward-405",
            payload: [0x2f, 0, 0, 0x95, 0x01]
        ), [.persistFrame(
            generation: 14,
            frameKey: "forward-405",
            payload: [0x2f, 0, 0, 0x95, 0x01]
        )])
        XCTAssertEqual(state.receiveFrame(
            generation: 14,
            frameKey: "overlap-366",
            payload: [0x2f, 0, 0, 0x6e, 0x01]
        ), [.persistFrame(
            generation: 14,
            frameKey: "overlap-366",
            payload: [0x2f, 0, 0, 0x6e, 0x01]
        )])

        // 406 is contiguous with the retained forward cursor (405). If the
        // overlap had rewound it to 366 this would fail closed as a gap of 40.
        XCTAssertEqual(state.receiveFrame(
            generation: 14,
            frameKey: "forward-406",
            payload: [0x2f, 0, 0, 0x96, 0x01]
        ), [.persistFrame(
            generation: 14,
            frameKey: "forward-406",
            payload: [0x2f, 0, 0, 0x96, 0x01]
        )])
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.sequenceRestartCount, 1)
    }

    func testInterleavedPhysicalRecordLayoutsUseIndependentSequenceCursors() {
        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 14)

        // Physical WHOOP 4 pages interleave these two record layouts. Their
        // counters are locally contiguous but offset from one another.
        let secondary365: [UInt8] = [0x2f, 0x19, 0x00, 0x6d, 0x01]
        let primary405: [UInt8] = [0x2f, 0x18, 0x05, 0x95, 0x01]
        let secondary366: [UInt8] = [0x2f, 0x19, 0x00, 0x6e, 0x01]
        let primary406: [UInt8] = [0x2f, 0x18, 0x05, 0x96, 0x01]

        for (key, payload) in [
            ("secondary-365", secondary365),
            ("primary-405", primary405),
            ("secondary-366", secondary366),
            ("primary-406", primary406),
        ] {
            XCTAssertEqual(state.receiveFrame(
                generation: 14,
                frameKey: key,
                payload: payload
            ), [.persistFrame(
                generation: 14,
                frameKey: key,
                payload: payload
            )])
        }
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.sequenceRestartCount, 0)
    }

    func testExactForwardDiscontinuityReplayInLaterGenerationCanFlushAndACK() {
        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 14)
        _ = state.receiveFrame(
            generation: 14,
            frameKey: "first",
            payload: [0x2f, 0, 0, 0x10, 0x00]
        )
        _ = state.receiveFrame(
            generation: 14,
            frameKey: "gap",
            payload: [0x2f, 0, 0, 0x12, 0x00]
        )

        _ = state.begin(generation: 15)
        XCTAssertEqual(state.receiveFrame(
            generation: 15,
            frameKey: "gap",
            payload: [0x2f, 0, 0, 0x12, 0x00]
        ), [.persistFrame(
            generation: 15,
            frameKey: "gap",
            payload: [0x2f, 0, 0, 0x12, 0x00]
        )])
        XCTAssertEqual(state.sequenceRestartCount, 1)
        XCTAssertNil(state.failure)
        XCTAssertTrue(state.historyEnd(
            generation: 15,
            boundaryID: "end",
            ackPayload: [1, 2]
        ).isEmpty)
        XCTAssertEqual(state.persistenceCompleted(
            generation: 15,
            frameKey: "gap",
            succeeded: true
        ), [.durableFlush(generation: 15, boundary: .batch("end"))])
        XCTAssertEqual(state.durableFlushCompleted(
            generation: 15,
            boundary: .batch("end"),
            succeeded: true
        ), [.sendACK(
            generation: 15,
            boundaryID: "end",
            payload: [1, 2],
            attempt: 1
        )])
    }

    func testDifferentForwardDiscontinuityOnRetryStillFailsClosed() {
        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 14)
        _ = state.receiveFrame(
            generation: 14,
            frameKey: "first-a",
            payload: [0x2f, 0, 0, 0x10, 0x00]
        )
        _ = state.receiveFrame(
            generation: 14,
            frameKey: "gap-a",
            payload: [0x2f, 0, 0, 0x12, 0x00]
        )

        _ = state.begin(generation: 15)
        let failure = AtriaWhoop4HistoryDrainState.Failure.protocolViolation(
            "history_sequence_gap_replay_mismatch_expected_18_received_19_stream_0"
        )
        XCTAssertEqual(state.receiveFrame(
            generation: 15,
            frameKey: "different-resumed-frame",
            payload: [0x2f, 0, 0, 0x13, 0x00]
        ), [.failed(generation: 15, failure: failure)])
        XCTAssertEqual(state.failure, failure)
        XCTAssertTrue(state.historyEnd(
            generation: 15,
            boundaryID: "must-not-ack",
            ackPayload: [1]
        ).isEmpty)
    }

    func testContiguousMissingFrameOnRetryRetractsFalseDiscontinuityCandidate() {
        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 14)
        _ = state.receiveFrame(
            generation: 14,
            frameKey: "32908",
            payload: [0x2f, 0x19, 0x00, 0x8c, 0x80]
        )
        XCTAssertEqual(state.receiveFrame(
            generation: 14,
            frameKey: "32910",
            payload: [0x2f, 0x19, 0x00, 0x8e, 0x80]
        ), [.failed(
            generation: 14,
            failure: .protocolViolation(
                "history_sequence_gap_unconfirmed_previous_32908_received_32910"
            )
        )])

        _ = state.begin(generation: 15)
        XCTAssertEqual(state.receiveFrame(
            generation: 15,
            frameKey: "32909",
            payload: [0x2f, 0x19, 0x00, 0x8d, 0x80]
        ), [.persistFrame(
            generation: 15,
            frameKey: "32909",
            payload: [0x2f, 0x19, 0x00, 0x8d, 0x80]
        )])
        XCTAssertNil(state.continuitySnapshot.pending)
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.receiveFrame(
            generation: 15,
            frameKey: "32910",
            payload: [0x2f, 0x19, 0x00, 0x8e, 0x80],
            admission: .needsPersistence
        ), [.persistFrame(
            generation: 15,
            frameKey: "32910",
            payload: [0x2f, 0x19, 0x00, 0x8e, 0x80]
        )])
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.sequenceRestartCount, 0)
    }

    func testRestoredFalseDiscontinuityIsRetractedByContiguousMissingFrame() {
        var original = AtriaWhoop4HistoryDrainState()
        _ = original.begin(generation: 14)
        _ = original.receiveFrame(
            generation: 14,
            frameKey: "32908",
            payload: [0x2f, 0x19, 0x00, 0x8c, 0x80]
        )
        _ = original.receiveFrame(
            generation: 14,
            frameKey: "32910",
            payload: [0x2f, 0x19, 0x00, 0x8e, 0x80]
        )

        var restored = AtriaWhoop4HistoryDrainState()
        XCTAssertTrue(restored.restoreContinuitySnapshot(original.continuitySnapshot))
        _ = restored.begin(generation: 1)
        XCTAssertEqual(restored.receiveFrame(
            generation: 1,
            frameKey: "32909",
            payload: [0x2f, 0x19, 0x00, 0x8d, 0x80]
        ), [.persistFrame(
            generation: 1,
            frameKey: "32909",
            payload: [0x2f, 0x19, 0x00, 0x8d, 0x80]
        )])
        XCTAssertNil(restored.continuitySnapshot.pending)
        XCTAssertNil(restored.failure)
    }

    func testParsedHistoryEndStatusWordDoesNotPretendToBePacketCount() throws {
        let metadata: [UInt8] = [
            0x31, 0x07, 0x02, 0, 0, 0, 0, 0, 0,
            0x02, 0, 0, 0,
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        ]
        guard case let .historyEnd(_, opaqueStatusWord, token) =
                try AtriaWhoop4HistoryMetadata.parse(metadata) else {
            return XCTFail("expected HISTORY_END metadata")
        }

        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 15)
        _ = state.receiveFrame(generation: 15, frameKey: "one", payload: [0x2F])

        XCTAssertEqual(opaqueStatusWord, 2)
        XCTAssertEqual(
            state.historyEnd(
                generation: 15,
                boundaryID: "enddata:\(token.bytes)",
                ackPayload: token.acknowledgementPayload
            ),
            [],
            "the opaque status word must not reject a complete received batch"
        )
    }

    func testACKFailureRetriesSamePayloadThenFailsClosed() {
        var state = AtriaWhoop4HistoryDrainState(maximumACKAttempts: 3)
        state.begin(generation: 5)
        _ = state.historyEnd(
            generation: 5,
            boundaryID: "end",
            ackPayload: [0x01, 0xAA]
        )
        XCTAssertEqual(
            state.durableFlushCompleted(
                generation: 5,
                boundary: .batch("end"),
                succeeded: true
            ),
            [.sendACK(
                generation: 5,
                boundaryID: "end",
                payload: [0x01, 0xAA],
                attempt: 1
            )]
        )
        XCTAssertEqual(
            state.ackCompleted(generation: 5, boundaryID: "end", succeeded: false),
            [.sendACK(
                generation: 5,
                boundaryID: "end",
                payload: [0x01, 0xAA],
                attempt: 2
            )]
        )
        XCTAssertEqual(
            state.ackCompleted(generation: 5, boundaryID: "end", succeeded: false),
            [.sendACK(
                generation: 5,
                boundaryID: "end",
                payload: [0x01, 0xAA],
                attempt: 3
            )]
        )
        XCTAssertEqual(
            state.ackCompleted(generation: 5, boundaryID: "end", succeeded: false),
            [.failed(generation: 5, failure: .ack(boundaryID: "end", attempts: 3))]
        )
        XCTAssertEqual(state.failure, .ack(boundaryID: "end", attempts: 3))
    }

    func testACKRetryCanRecoverAndOpenNextBatch() {
        var state = AtriaWhoop4HistoryDrainState(maximumACKAttempts: 2)
        state.begin(generation: 12)
        _ = state.historyEnd(
            generation: 12,
            boundaryID: "first",
            ackPayload: [1]
        )
        _ = state.durableFlushCompleted(
            generation: 12,
            boundary: .batch("first"),
            succeeded: true
        )
        _ = state.ackCompleted(generation: 12, boundaryID: "first", succeeded: false)

        XCTAssertTrue(state.ackCompleted(
            generation: 12,
            boundaryID: "first",
            succeeded: true
        ).isEmpty)
        XCTAssertEqual(
            state.receiveFrame(generation: 12, frameKey: "next", payload: [2]),
            [.persistFrame(generation: 12, frameKey: "next", payload: [2])]
        )
    }

    func testDurableFlushFailureFailsClosed() {
        var state = AtriaWhoop4HistoryDrainState()
        state.begin(generation: 20)
        _ = state.historyEnd(
            generation: 20,
            boundaryID: "end",
            ackPayload: [1]
        )

        XCTAssertEqual(
            state.durableFlushCompleted(
                generation: 20,
                boundary: .batch("end"),
                succeeded: false
            ),
            [.failed(
                generation: 20,
                failure: .durableFlush(boundary: .batch("end"))
            )]
        )
        XCTAssertFalse(state.isFinished)
    }

    func testBackwardFlashOverlapIsReplaySafeAndRecordsDiscontinuity() {
        var state = AtriaWhoop4HistoryDrainState()
        _ = state.begin(generation: 15)
        XCTAssertEqual(
            state.receiveFrame(
                generation: 15,
                frameKey: "newer",
                payload: [0x2f, 0, 0, 0x20, 0x00]
            ),
            [.persistFrame(
                generation: 15,
                frameKey: "newer",
                payload: [0x2f, 0, 0, 0x20, 0x00]
            )]
        )
        XCTAssertEqual(
            state.receiveFrame(
                generation: 15,
                frameKey: "overlap",
                payload: [0x2f, 0, 0, 0x10, 0x00]
            ),
            [.persistFrame(
                generation: 15,
                frameKey: "overlap",
                payload: [0x2f, 0, 0, 0x10, 0x00]
            )]
        )
        XCTAssertEqual(state.sequenceRestartCount, 1)
        XCTAssertEqual(
            state.receiveFrame(
                generation: 15,
                frameKey: "overlap-next",
                payload: [0x2f, 0, 0, 0x11, 0x00]
            ),
            [.persistFrame(
                generation: 15,
                frameKey: "overlap-next",
                payload: [0x2f, 0, 0, 0x11, 0x00]
            )]
        )
        XCTAssertNil(state.failure)
    }

    func testSkippedACKLetsNextGenerationResumeTheSameHistoryEnd() {
        var interrupted = AtriaWhoop4HistoryDrainState()
        interrupted.begin(generation: 30)
        XCTAssertEqual(
            interrupted.historyEnd(
                generation: 30,
                boundaryID: "enddata:aa",
                ackPayload: [0x17, 0xaa]
            ),
            [.durableFlush(generation: 30, boundary: .batch("enddata:aa"))]
        )
        XCTAssertEqual(
            interrupted.durableFlushCompleted(
                generation: 30,
                boundary: .batch("enddata:aa"),
                succeeded: true
            ),
            [.sendACK(
                generation: 30,
                boundaryID: "enddata:aa",
                payload: [0x17, 0xaa],
                attempt: 1
            )]
        )
        // Drop happens before ackCompleted: the strap re-serves this token.

        var resumed = AtriaWhoop4HistoryDrainState()
        resumed.begin(generation: 31)
        XCTAssertEqual(
            resumed.historyEnd(
                generation: 31,
                boundaryID: "enddata:aa",
                ackPayload: [0x17, 0xaa]
            ),
            [.durableFlush(generation: 31, boundary: .batch("enddata:aa"))],
            "an un-ACKed HISTORY_END must be eligible again on the next generation"
        )
        XCTAssertEqual(
            resumed.durableFlushCompleted(
                generation: 31,
                boundary: .batch("enddata:aa"),
                succeeded: true
            ),
            [.sendACK(
                generation: 31,
                boundaryID: "enddata:aa",
                payload: [0x17, 0xaa],
                attempt: 1
            )]
        )
        XCTAssertTrue(
            resumed.ackCompleted(
                generation: 31,
                boundaryID: "enddata:aa",
                succeeded: true
            ).isEmpty
        )
        XCTAssertEqual(resumed.acknowledgedBatchCount, 1)
        XCTAssertTrue(
            resumed.historyEnd(
                generation: 31,
                boundaryID: "enddata:aa",
                ackPayload: [0x17, 0xaa]
            ).isEmpty,
            "after persist-before-ACK succeeds, the same cursor must not double-count"
        )
    }
}
