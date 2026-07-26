import XCTest
@testable import Atria

final class AtriaHistoricalFullDrainCoverageAuthorityTests: XCTestCase {
    typealias Policy = AtriaHistoricalFullDrainCoveragePolicy
    typealias Store = AtriaHistoricalFullDrainCoverageStore
    typealias Coordinator = AtriaHistoricalFullDrainCoverageCoordinator

    private let start = 1_900_000_000.0
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testDenseDecodedTimestampsProduceRevalidatablePerCadenceProof() throws {
        let stores = durableStores(sequence: 10, fsyncedAt: start + 110)
        let proof = try Policy.evaluate(
            gapIdentifier: "gap-a",
            gapStartUnix: start,
            gapEndUnix: start + 100,
            attemptIdentifier: "attempt-a",
            transportNonce: "nonce-a",
            transportGeneration: 7,
            stores: stores,
            decoderIdentifier: "whoop4-history-decoder",
            decoderVersion: 2,
            metricTimestampsUnix: (0..<100).map { start + Double($0) }
        )

        XCTAssertEqual(proof.observedBuckets, 100)
        XCTAssertEqual(proof.expectedBuckets, 100)
        XCTAssertEqual(proof.densityPercent, 100)
        XCTAssertEqual(proof.maximumGapSeconds, 1)
        XCTAssertEqual(proof.p95GapSeconds, 1)
        XCTAssertEqual(proof.coveredBucketBits.count, 13)
        XCTAssertTrue(Policy.validate(
            proof,
            gapIdentifier: "gap-a",
            gapStartUnix: start,
            gapEndUnix: start + 100,
            attemptIdentifier: "attempt-a",
            transportNonce: "nonce-a",
            transportGeneration: 7,
            stores: stores
        ))
    }

    func testLargeRowCountCannotSubstituteForTimestampCoverage() {
        XCTAssertThrowsError(try Policy.evaluate(
            gapIdentifier: "gap-a",
            gapStartUnix: start,
            gapEndUnix: start + 100,
            attemptIdentifier: "attempt-a",
            transportNonce: "nonce-a",
            transportGeneration: 7,
            stores: durableStores(sequence: 10, fsyncedAt: start + 110),
            decoderIdentifier: "decoder",
            decoderVersion: 1,
            metricTimestampsUnix: Array(repeating: start + 50, count: 100_000)
        )) {
            XCTAssertEqual($0 as? Policy.Rejection, .insufficientDensity)
        }
    }

    func testDenseInteriorWithoutGapEdgesFailsClosed() {
        XCTAssertThrowsError(try Policy.evaluate(
            gapIdentifier: "gap-a",
            gapStartUnix: start,
            gapEndUnix: start + 100,
            attemptIdentifier: "attempt-a",
            transportNonce: "nonce-a",
            transportGeneration: 7,
            stores: durableStores(sequence: 10, fsyncedAt: start + 110),
            decoderIdentifier: "decoder",
            decoderVersion: 1,
            metricTimestampsUnix: (4..<100).map { start + Double($0) }
        )) {
            XCTAssertEqual($0 as? Policy.Rejection, .edgeNotCovered)
        }
    }

    func testInternalCadenceHoleAndP95CadenceBothFailClosed() {
        let stores = durableStores(sequence: 10, fsyncedAt: start + 110)
        var hole = (0..<100).map { start + Double($0) }
        hole.removeAll { $0 >= start + 45 && $0 <= start + 48 }
        XCTAssertThrowsError(try Policy.evaluate(
            gapIdentifier: "gap-a",
            gapStartUnix: start,
            gapEndUnix: start + 100,
            attemptIdentifier: "attempt-a",
            transportNonce: "nonce-a",
            transportGeneration: 7,
            stores: stores,
            decoderIdentifier: "decoder",
            decoderVersion: 1,
            metricTimestampsUnix: hole
        )) {
            XCTAssertEqual($0 as? Policy.Rejection, .cadenceGapExceeded)
        }

        let p95Configuration = Policy.Configuration(
            cadenceSeconds: 1,
            minimumDensityPercent: 50,
            maximumGapSeconds: 3,
            maximumP95GapSeconds: 1,
            maximumGapDurationSeconds: 1_000,
            requiredConsumerKinds: ["one"]
        )
        XCTAssertThrowsError(try Policy.evaluate(
            gapIdentifier: "gap-a",
            gapStartUnix: start,
            gapEndUnix: start + 100,
            attemptIdentifier: "attempt-a",
            transportNonce: "nonce-a",
            transportGeneration: 7,
            stores: stores,
            decoderIdentifier: "decoder",
            decoderVersion: 1,
            metricTimestampsUnix: stride(from: 0, to: 100, by: 2).map {
                start + Double($0)
            },
            configuration: p95Configuration
        )) {
            XCTAssertEqual($0 as? Policy.Rejection, .p95GapExceeded)
        }
    }

    func testTransportAuthorityRejectsClockSequenceMismatch() {
        XCTAssertThrowsError(try transportAuthority(clockResponseSequence: 10)) {
            XCTAssertEqual($0 as? Policy.TransportRejection, .clockSequenceMismatch)
        }
    }

    func testTransportAuthorityRejectsMissingWriteAndHistoryStart() {
        XCTAssertThrowsError(try transportAuthority(fullDrainCommandSequence: nil)) {
            XCTAssertEqual($0 as? Policy.TransportRejection, .fullDrainWriteMissing)
        }
        XCTAssertThrowsError(try transportAuthority(historyStartSequence: nil)) {
            XCTAssertEqual($0 as? Policy.TransportRejection, .historyStartMissing)
        }
    }

    func testTransportAuthorityRejectsInsaneClockAndReorderedEvents() {
        XCTAssertThrowsError(try transportAuthority(deviceClockUnix: 1)) {
            XCTAssertEqual($0 as? Policy.TransportRejection, .clockResponseInsane)
        }
        XCTAssertThrowsError(try transportAuthority(fullDrainWriteCompletedAtUnix: start + 99)) {
            XCTAssertEqual($0 as? Policy.TransportRejection, .eventOrderInvalid)
        }
    }

    func testTransportAuthorityAcceptsSingleClockThenFullDrainThenStart() throws {
        let authority = try transportAuthority()
        XCTAssertTrue(authority.isValid)
        XCTAssertEqual(authority.clockCommandSequence, authority.clockResponseSequence)
        XCTAssertNotEqual(authority.clockCommandSequence,
                          authority.fullDrainCommandSequence)
    }

    func testTransportAuthorityAcceptsLegalNotificationBeforeWriteCallbacks() throws {
        let authority = try transportAuthority(
            clockWriteCompletedAtUnix: start + 99.5,
            clockResponseReceivedAtUnix: start + 99,
            fullDrainCommandRequestedAtUnix: start + 100,
            fullDrainWriteCompletedAtUnix: start + 101,
            historyStartReceivedAtUnix: start + 100.5
        )
        XCTAssertTrue(authority.isValid,
                      "CoreBluetooth may deliver notifications before matching didWrite callbacks")
    }

    func testArmRequiresClosedPendingGapAndBoundAttemptIdentity() throws {
        let store = try makeStore()
        var notPending = gap()
        notPending = Store.PendingGap(
            gapIdentifier: notPending.gapIdentifier,
            gapLedgerGeneration: notPending.gapLedgerGeneration,
            gapLedgerSnapshotSHA256: notPending.gapLedgerSnapshotSHA256,
            startUnix: notPending.startUnix,
            endUnix: notPending.endUnix,
            reason: notPending.reason,
            pending: false
        )
        XCTAssertThrowsError(try store.arm(gap: notPending,
                                           attempt: attempt(),
                                           now: date(102))) {
            XCTAssertEqual($0 as? Store.StoreError, .invalidGap)
        }
        let authority = try store.arm(gap: gap(), attempt: attempt(), now: date(102))
        XCTAssertEqual(authority.status, .draining)
        XCTAssertEqual(authority.gap.gapIdentifier, "gap-a")
        XCTAssertEqual(authority.attempt.strapIdentity, "whoop-4-a")
    }

    func testStaleStrapAttemptOrTransportCannotRecordHistoryEnd() throws {
        let store = try armedStore()
        for stale in [
            identity(strapIdentity: "whoop-4-b"),
            identity(attemptIdentifier: "attempt-b"),
            identity(transportNonce: "nonce-b"),
            identity(transportGeneration: 8),
        ] {
            XCTAssertThrowsError(try store.recordHistoryEndFsynced(
                identity: stale,
                boundaryIdentifier: "end-1",
                historyEndPayload: Data([0x31, 1]),
                expectedACKPayload: Data([1, 2]),
                stores: durableStores(sequence: 1, fsyncedAt: start + 103),
                fsyncedAt: date(104)
            )) {
                XCTAssertEqual($0 as? Store.StoreError, .staleEventIdentity)
            }
        }
        XCTAssertTrue(try XCTUnwrap(store.load()).boundaries.isEmpty)
    }

    func testHistoryEndPermitSurvivesRestartAndOnlyMatchingACKAdvances() throws {
        let root = try temporaryRoot()
        var store = makeStore(root: root)
        _ = try store.arm(gap: gap(), attempt: attempt(), now: date(102))
        let stores = durableStores(sequence: 4, fsyncedAt: start + 103)
        let permit = try store.recordHistoryEndFsynced(
            identity: identity(),
            boundaryIdentifier: "end-1",
            historyEndPayload: Data([0x31, 1]),
            expectedACKPayload: Data([0x01, 0x7f]),
            stores: stores,
            fsyncedAt: date(104)
        )
        XCTAssertNil(try XCTUnwrap(store.load()).boundaries[0].ackCompletedAtUnix)

        store = makeStore(root: root)
        let recoveredPermit = try store.recordHistoryEndFsynced(
            identity: identity(),
            boundaryIdentifier: "end-1",
            historyEndPayload: Data([0x31, 1]),
            expectedACKPayload: Data([0x01, 0x7f]),
            stores: stores,
            fsyncedAt: date(104)
        )
        XCTAssertEqual(recoveredPermit, permit,
                       "crash after fsync but before send must recover one exact permit")
        XCTAssertThrowsError(try store.recordMatchingACK(
            identity: identity(),
            permit: recoveredPermit,
            actualACKPayload: Data([0x01, 0x7e]),
            ackAttempt: 1,
            completedAt: date(105)
        )) {
            XCTAssertEqual($0 as? Store.StoreError, .ackPayloadMismatch)
        }
        let advanced = try store.recordMatchingACK(
            identity: identity(),
            permit: recoveredPermit,
            actualACKPayload: Data([0x01, 0x7f]),
            ackAttempt: 1,
            completedAt: date(105)
        )
        XCTAssertEqual(advanced.boundaries[0].ackAttempt, 1)
        XCTAssertEqual(advanced.boundaries[0].stores, stores)
    }

    func testInterruptedAttemptCanBeRearmedForSameGapButStaleCallbacksFail() throws {
        let store = try armedStore()
        let retried = try store.arm(
            gap: gap(),
            attempt: attempt(generation: 8,
                             commandSequence: 12,
                             transportNonce: "nonce-b",
                             writeCompletedAt: start + 103),
            now: date(104)
        )
        XCTAssertEqual(retried.attempt.transportGeneration, 8)
        XCTAssertTrue(retried.boundaries.isEmpty)
        XCTAssertThrowsError(try store.recordHistoryEndFsynced(
            identity: identity(),
            boundaryIdentifier: "stale-end",
            historyEndPayload: Data([0x31]),
            expectedACKPayload: Data([0x01]),
            stores: durableStores(sequence: 2, fsyncedAt: start + 105),
            fsyncedAt: date(106)
        )) {
            XCTAssertEqual($0 as? Store.StoreError, .staleEventIdentity)
        }
    }

    func testDrainingAuthorityCanOnlyBeAbandonedForChangedGapFingerprint() throws {
        let store = try armedStore()
        XCTAssertFalse(try store.abandonDrainingAuthorityIfGapFingerprintChanged(
            gapIdentifier: "gap-a",
            observedStartUnix: start,
            observedEndUnix: start + 100,
            observedReason: "disconnect"
        ))
        XCTAssertNotNil(try store.load())
        XCTAssertTrue(try store.abandonDrainingAuthorityIfGapFingerprintChanged(
            gapIdentifier: "gap-a",
            observedStartUnix: start - 10,
            observedEndUnix: start + 100,
            observedReason: "disconnect"
        ))
        XCTAssertNil(try store.load())
    }

    func testNoLongerPendingDrainingAuthorityClearsOnlyForExactIdentifier() throws {
        let store = try armedStore()
        try store.clearUnresolvedAuthorityIfGapNoLongerPending(
            gapIdentifier: "another-gap"
        )
        XCTAssertNotNil(try store.load())

        try store.clearUnresolvedAuthorityIfGapNoLongerPending(
            gapIdentifier: "gap-a"
        )
        XCTAssertNil(try store.load())
    }

    func testACKBeforeBothStoreFsyncsFailsClosed() throws {
        let store = try armedStore()
        XCTAssertThrowsError(try store.recordHistoryEndFsynced(
            identity: identity(),
            boundaryIdentifier: "end-1",
            historyEndPayload: Data([0x31]),
            expectedACKPayload: Data([0x01]),
            stores: durableStores(sequence: 1, fsyncedAt: start + 106),
            fsyncedAt: date(104)
        )) {
            XCTAssertEqual($0 as? Store.StoreError, .ackBeforeDurableFlush)
        }
        XCTAssertTrue(try XCTUnwrap(store.load()).boundaries.isEmpty,
                      "no ACK permit or boundary may exist before both fsyncs")
    }

    func testACKPermitWaitsForLaterAdmissionSeal() throws {
        let store = try armedStore()
        let stores = durableStores(sequence: 1,
                                   fsyncedAt: start + 103,
                                   admissionFsyncedAt: start + 106)
        XCTAssertThrowsError(try store.recordHistoryEndFsynced(
            identity: identity(),
            boundaryIdentifier: "end-admission-late",
            historyEndPayload: Data([0x31]),
            expectedACKPayload: Data([0x01]),
            stores: stores,
            fsyncedAt: date(104)
        )) {
            XCTAssertEqual($0 as? Store.StoreError, .ackBeforeDurableFlush)
        }
        let permit = try store.recordHistoryEndFsynced(
            identity: identity(),
            boundaryIdentifier: "end-admission-late",
            historyEndPayload: Data([0x31]),
            expectedACKPayload: Data([0x01]),
            stores: stores,
            fsyncedAt: date(106)
        )
        XCTAssertFalse(permit.evidenceSHA256.isEmpty)
    }

    func testAnotherBoundaryAndHistoryCompleteWaitForPendingACK() throws {
        let store = try armedStore()
        let stores = durableStores(sequence: 1, fsyncedAt: start + 103)
        _ = try store.recordHistoryEndFsynced(
            identity: identity(),
            boundaryIdentifier: "end-1",
            historyEndPayload: Data([0x31]),
            expectedACKPayload: Data([0x01]),
            stores: stores,
            fsyncedAt: date(104)
        )
        XCTAssertThrowsError(try store.recordHistoryEndFsynced(
            identity: identity(),
            boundaryIdentifier: "end-2",
            historyEndPayload: Data([0x31, 2]),
            expectedACKPayload: Data([0x02]),
            stores: durableStores(sequence: 2, fsyncedAt: start + 105),
            fsyncedAt: date(106)
        )) {
            XCTAssertEqual($0 as? Store.StoreError, .boundaryAlreadyPending)
        }
        XCTAssertThrowsError(try store.recordHistoryComplete(
            identity: identity(),
            completionIdentifier: "complete-a",
            notificationPayload: Data([0x32]),
            stores: stores,
            receivedAt: date(106)
        )) {
            XCTAssertEqual($0 as? Store.StoreError, .unacknowledgedBoundary)
        }
    }

    func testTerminalStoreSealCannotMoveBackwards() throws {
        let store = try armedStore()
        let permit = try endAndPermit(store: store, sequence: 5)
        _ = try store.recordMatchingACK(identity: identity(),
                                        permit: permit,
                                        actualACKPayload: Data([0x01]),
                                        ackAttempt: 1,
                                        completedAt: date(105))
        XCTAssertThrowsError(try store.recordHistoryComplete(
            identity: identity(),
            completionIdentifier: "complete-a",
            notificationPayload: Data([0x32]),
            stores: durableStores(sequence: 4, fsyncedAt: start + 106),
            receivedAt: date(107)
        )) {
            XCTAssertEqual($0 as? Store.StoreError, .storeSealMismatch)
        }
    }

    func testMultipleHistoryEndsEachRequireOwnFsyncAndMatchingACKBeforeComplete() throws {
        let store = try armedStore()
        let first = try endAndPermit(store: store, sequence: 5)
        _ = try store.recordMatchingACK(identity: identity(),
                                        permit: first,
                                        actualACKPayload: Data([0x01]),
                                        ackAttempt: 1,
                                        completedAt: date(105))
        let secondStores = durableStores(sequence: 8, fsyncedAt: start + 106)
        let second = try store.recordHistoryEndFsynced(
            identity: identity(),
            boundaryIdentifier: "end-2",
            historyEndPayload: Data([0x31, 2]),
            expectedACKPayload: Data([0x02]),
            stores: secondStores,
            fsyncedAt: date(107)
        )
        XCTAssertThrowsError(try store.recordHistoryComplete(
            identity: identity(),
            completionIdentifier: "complete-a",
            notificationPayload: Data([0x32]),
            stores: secondStores,
            receivedAt: date(108)
        )) {
            XCTAssertEqual($0 as? Store.StoreError, .unacknowledgedBoundary)
        }
        _ = try store.recordMatchingACK(identity: identity(),
                                        permit: second,
                                        actualACKPayload: Data([0x02]),
                                        ackAttempt: 1,
                                        completedAt: date(108))
        let completed = try store.recordHistoryComplete(
            identity: identity(),
            completionIdentifier: "complete-a",
            notificationPayload: Data([0x32]),
            stores: durableStores(sequence: 9, fsyncedAt: start + 109),
            receivedAt: date(110)
        )
        XCTAssertEqual(completed.historyComplete?.acknowledgedBoundaryCount, 2)
        XCTAssertEqual(completed.boundaries.map(\.boundaryIdentifier), ["end-1", "end-2"])
        XCTAssertTrue(completed.boundaries.allSatisfy { $0.ackCompletedAtUnix != nil })
    }

    func testCoverageMustMatchTerminalRawAndIdentitySnapshots() throws {
        let (store, terminalStores) = try terminalStore()
        let wrongStores = durableStores(sequence: 9,
                                        fsyncedAt: start + 108,
                                        rawHash: hash("other-raw"))
        let proof = try Policy.evaluate(
            gapIdentifier: "gap-a",
            gapStartUnix: start,
            gapEndUnix: start + 100,
            attemptIdentifier: "attempt-a",
            transportNonce: "nonce-a",
            transportGeneration: 7,
            stores: wrongStores,
            decoderIdentifier: "decoder",
            decoderVersion: 1,
            metricTimestampsUnix: denseTimestamps()
        )
        XCTAssertThrowsError(try store.recordCoverageProof(identity: identity(), proof: proof)) {
            XCTAssertEqual($0 as? Store.StoreError, .coverageRejected)
        }
        XCTAssertNotEqual(terminalStores.raw.snapshotSHA256, wrongStores.raw.snapshotSHA256)
    }

    func testConsumerCommitRequiresEveryConfiguredReceiptAndExactSources() throws {
        let (store, stores) = try coveredStore()
        let receipts = consumerReceipts(stores: stores)
        XCTAssertThrowsError(try store.recordCommittedConsumers(
            identity: identity(),
            receipts: Array(receipts.dropLast()),
            committedAt: date(112)
        )) {
            XCTAssertEqual($0 as? Store.StoreError, .consumerReceiptsIncomplete)
        }
        var wrongSource = receipts
        wrongSource[0] = receipt(kind: wrongSource[0].kind,
                                 stores: durableStores(sequence: 9,
                                                       fsyncedAt: start + 108,
                                                       rawHash: hash("wrong")))
        XCTAssertThrowsError(try store.recordCommittedConsumers(
            identity: identity(),
            receipts: wrongSource,
            committedAt: date(112)
        )) {
            XCTAssertEqual($0 as? Store.StoreError, .consumerReceiptsIncomplete)
        }
        let committed = try store.recordCommittedConsumers(identity: identity(),
                                                            receipts: receipts,
                                                            committedAt: date(112))
        XCTAssertEqual(committed.status, .consumersCommitted)
        XCTAssertEqual(committed.consumerCommit?.receipts.map(\.kind),
                       Policy.Configuration.production.requiredConsumerKinds)
    }

    func testExactGapResolutionCanRemainDurablyPendingForFutureConsumers() throws {
        let root = try temporaryRoot()
        var store = makeStore(root: root)
        _ = try store.arm(gap: gap(), attempt: attempt(), now: date(102))
        let permit = try endAndPermit(store: store, sequence: 5)
        _ = try store.recordMatchingACK(identity: identity(),
                                        permit: permit,
                                        actualACKPayload: Data([0x01]),
                                        ackAttempt: 1,
                                        completedAt: date(105))
        let stores = durableStores(sequence: 6, fsyncedAt: start + 106)
        _ = try store.recordHistoryComplete(identity: identity(),
                                            completionIdentifier: "complete-a",
                                            notificationPayload: Data([0x32]),
                                            stores: stores,
                                            receivedAt: date(107))
        let proof = try Policy.evaluate(
            gapIdentifier: "gap-a",
            gapStartUnix: start,
            gapEndUnix: start + 100,
            attemptIdentifier: "attempt-a",
            transportNonce: "nonce-a",
            transportGeneration: 7,
            stores: stores,
            decoderIdentifier: "decoder",
            decoderVersion: 1,
            metricTimestampsUnix: denseTimestamps()
        )
        _ = try store.recordCoverageProof(identity: identity(), proof: proof)
        try markProjectionCheckpoint(store: store)

        let dependency = Store.PendingConsumerDependency(
            requiredStartUnix: start - 600,
            requiredEndUnix: start + 14_400,
            sourceChunkID: "raw-chunk-a",
            sourceRawSHA256: String(repeating: "a", count: 64)
        )
        _ = try store.recordPendingConsumerDependency(
            identity: identity(),
            dependency: dependency
        )

        let prepared = try store.prepareGapResolution(
            identity: identity(),
            at: date(109)
        )
        XCTAssertEqual(prepared.gapResolutionPreparedAtUnix, start + 109)
        let pending = try store.resolve(identity: identity(), at: date(110))
        XCTAssertEqual(pending.status, .gapResolvedConsumersPending)
        XCTAssertNil(pending.consumerCommit)
        XCTAssertNotNil(pending.resolvedAtUnix)
        XCTAssertEqual(pending.pendingConsumerDependency, dependency)

        store = makeStore(root: root)
        let restarted = store
        XCTAssertEqual(try restarted.load()?.status, .gapResolvedConsumersPending,
                       "the future-dependent consumer retry must survive restart")
        XCTAssertEqual(try restarted.load()?.pendingConsumerDependency, dependency)

        let completed = try restarted.recordCommittedConsumers(
            identity: identity(),
            receipts: consumerReceipts(stores: stores),
            committedAt: date(112)
        )
        XCTAssertEqual(completed.status, .resolved)
        XCTAssertNotNil(completed.consumerCommit)
    }

    func testFullFlowSurvivesRestartsAndResolvesOnlyAtLastDurableStage() throws {
        let root = try temporaryRoot()
        var store = makeStore(root: root)
        let coordinator = Coordinator(store: store)
        _ = try coordinator.arm(gap: gap(), attempt: attempt(), now: date(102))
        guard case .sendMatchingACK(let payload, let permit) = try coordinator
            .historyEndDurablyFsynced(
                identity: identity(),
                boundaryIdentifier: "end-1",
                historyEndPayload: Data([0x31]),
                expectedACKPayload: Data([0x01]),
                stores: durableStores(sequence: 5, fsyncedAt: start + 103),
                fsyncedAt: date(104)
            ) else { return XCTFail("expected ACK permit") }
        XCTAssertEqual(payload, Data([0x01]))

        store = makeStore(root: root)
        var restarted = Coordinator(store: store)
        _ = try restarted.ackCompleted(identity: identity(),
                                       permit: permit,
                                       actualACKPayload: payload,
                                       ackAttempt: 1,
                                       completedAt: date(105))
        let terminalStores = durableStores(sequence: 6, fsyncedAt: start + 106)
        XCTAssertEqual(try restarted.historyComplete(
            identity: identity(),
            completionIdentifier: "complete-a",
            notificationPayload: Data([0x32]),
            stores: terminalStores,
            receivedAt: date(107)
        ), .historyCompletePersisted)
        XCTAssertThrowsError(try restarted.resolve(identity: identity(), at: date(108))) {
            XCTAssertEqual($0 as? Store.StoreError, .notReadyToResolve)
        }

        store = makeStore(root: root)
        restarted = Coordinator(store: store)
        guard case .coveragePersisted(let proof) = try restarted.proveCoverage(
            identity: identity(),
            decoderIdentifier: "whoop4-history-decoder",
            decoderVersion: 2,
            metricTimestampsUnix: denseTimestamps()
        ) else { return XCTFail("expected coverage proof") }
        XCTAssertEqual(proof.observedBuckets, 100)
        try markProjectionCheckpoint(store: store)
        XCTAssertEqual(try restarted.consumersCommitted(
            identity: identity(),
            receipts: consumerReceipts(stores: terminalStores),
            committedAt: date(112)
        ), .consumerReceiptsPersisted)
        XCTAssertThrowsError(try restarted.resolve(identity: identity(), at: date(113))) {
            XCTAssertEqual($0 as? Store.StoreError, .notReadyToResolve)
        }
        XCTAssertEqual(try restarted.prepareGapResolution(
            identity: identity(),
            at: date(113)
        ), .gapResolutionPrepared)
        XCTAssertEqual(try restarted.resolve(identity: identity(), at: date(113)),
                       .gapResolutionCommitted)
        XCTAssertEqual(try store.load()?.status, .resolved)
    }

    func testGapResolutionIntentSurvivesRestartAndIsIdempotent() throws {
        let root = try temporaryRoot()
        var store = makeStore(root: root)
        _ = try store.arm(gap: gap(), attempt: attempt(), now: date(102))
        let permit = try endAndPermit(store: store, sequence: 5)
        _ = try store.recordMatchingACK(identity: identity(),
                                        permit: permit,
                                        actualACKPayload: Data([0x01]),
                                        ackAttempt: 1,
                                        completedAt: date(105))
        let stores = durableStores(sequence: 6, fsyncedAt: start + 106)
        _ = try store.recordHistoryComplete(identity: identity(),
                                            completionIdentifier: "complete-a",
                                            notificationPayload: Data([0x32]),
                                            stores: stores,
                                            receivedAt: date(107))
        let proof = try Policy.evaluate(
            gapIdentifier: "gap-a",
            gapStartUnix: start,
            gapEndUnix: start + 100,
            attemptIdentifier: "attempt-a",
            transportNonce: "nonce-a",
            transportGeneration: 7,
            stores: stores,
            decoderIdentifier: "decoder",
            decoderVersion: 1,
            metricTimestampsUnix: denseTimestamps()
        )
        _ = try store.recordCoverageProof(identity: identity(), proof: proof)

        let first = try store.prepareGapResolution(identity: identity(), at: date(109))
        XCTAssertEqual(first.gapResolutionPreparedAtUnix, start + 109)

        store = makeStore(root: root)
        XCTAssertEqual(try store.load()?.gapResolutionPreparedAtUnix, start + 109)
        let replayed = try store.prepareGapResolution(identity: identity(), at: date(120))
        XCTAssertEqual(replayed.gapResolutionPreparedAtUnix, start + 109,
                       "crash replay must preserve the first durable intent")
    }

    func testManagerPersistsExactIntentBeforeEitherGapLedgerCAS() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        func body(start: String, end: String) throws -> Substring {
            let suffix = try XCTUnwrap(source.range(of: start)).upperBound
            let tail = source[suffix...]
            let finish = try XCTUnwrap(tail.range(of: end)).lowerBound
            return tail[..<finish]
        }

        for functionBody in [
            try body(start: "private func commitFullDrainGapPendingConsumers(",
                     end: "private func commitFullDrainGapAfterConsumers("),
            try body(start: "private func commitFullDrainGapAfterConsumers(",
                     end: "private func finalizeAlreadyResolvedFullDrainConsumers(")
        ] {
            let prepare = try XCTUnwrap(functionBody.range(of: ".prepareGapResolution("))
            let ledgerCAS = try XCTUnwrap(functionBody.range(of: "commitFullDrainGapLedgerCAS("))
            let resolve = try XCTUnwrap(functionBody.range(of: ".resolve("))
            XCTAssertLessThan(prepare.lowerBound, ledgerCAS.lowerBound)
            XCTAssertLessThan(ledgerCAS.lowerBound, resolve.lowerBound)
        }

        let cas = try body(start: "private func commitFullDrainGapLedgerCAS(",
                           end: "private nonisolated static func fullDrainEventIdentity(")
        let intentGuard = try XCTUnwrap(cas.range(of: "gapResolutionPreparedAtUnix != nil"))
        let absentReplay = try XCTUnwrap(cas.range(of: "removed || !sameIDStillExists"))
        XCTAssertLessThan(intentGuard.lowerBound, absentReplay.lowerBound)
    }

    func testManagerRejectsQuarantinedGapLedgerButAllowsValidAbsentCrashResume() {
        let ordinary = AtriaHistoricalGapLedger.Window(
            start: date(1),
            end: date(2),
            reason: "bluetooth_unavailable"
        )
        let quarantined = AtriaHistoricalGapLedger.Window(
            start: date(1),
            reason: "durable_gap_ledger_corrupt_" + String(repeating: "a", count: 64)
        )

        XCTAssertTrue(AtriaBLEManager.gapLedgerSnapshotIsValidForResolution([]),
                      "a valid absent row is the exact-CAS crash-resume case")
        XCTAssertTrue(AtriaBLEManager.gapLedgerSnapshotIsValidForResolution([ordinary]))
        XCTAssertFalse(AtriaBLEManager.gapLedgerSnapshotIsValidForResolution([quarantined]))
        XCTAssertFalse(AtriaBLEManager.gapLedgerSnapshotIsValidForResolution([
            ordinary,
            quarantined,
        ]))
    }

    func testManagerGatesPrimaryAndSecondaryAbsentRowResolutionOnValidLedger() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        func body(start: String, end: String) throws -> Substring {
            let suffix = try XCTUnwrap(source.range(of: start)).upperBound
            let tail = source[suffix...]
            let finish = try XCTUnwrap(tail.range(of: end)).lowerBound
            return tail[..<finish]
        }

        let secondary = try body(
            start: "private func reconcileAdditionalTerminalFullDrainGaps(",
            end: "private func commitFullDrainGapPendingConsumers("
        )
        let secondaryValidity = try XCTUnwrap(secondary.range(of:
            "validGapLedgerResolutionSnapshot()"))
        let secondaryAbsent = try XCTUnwrap(secondary.range(of:
            "let resolved = removed || !sameIDStillExists"))
        XCTAssertLessThan(secondaryValidity.lowerBound, secondaryAbsent.lowerBound)
        XCTAssertTrue(secondary.contains(".gapLedgerQuarantined"))

        let primary = try body(
            start: "private func commitFullDrainGapLedgerCAS(",
            end: "private nonisolated static func fullDrainEventIdentity("
        )
        let primaryValidity = try XCTUnwrap(primary.range(of:
            "guard let ledgerBeforeCAS = Self.validGapLedgerResolutionSnapshot()"))
        let primaryAbsent = try XCTUnwrap(primary.range(of:
            "guard removed || !sameIDStillExists"))
        XCTAssertLessThan(primaryValidity.lowerBound, primaryAbsent.lowerBound)
        XCTAssertGreaterThanOrEqual(primary.components(separatedBy:
            "validGapLedgerResolutionSnapshot()").count - 1, 2,
            "the CAS must revalidate quarantine after its mutation attempt")

        let validator = try body(
            start: "private nonisolated static func validGapLedgerResolutionSnapshot()",
            end: "private nonisolated static func fullDrainEventIdentity("
        )
        XCTAssertGreaterThanOrEqual(validator.components(separatedBy:
            "AtriaHistoricalGapLedger.durableStateIsValid()").count - 1, 2,
            "snapshot reads must be bracketed by canonical durable-state validation")
    }

    func testManagerFinalizesResolvedFutureConsumersWithoutSecondLedgerDelete() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let receiptStart = try XCTUnwrap(source.range(of:
            "_ = try coverageStore.recordCommittedConsumers("))
        let tail = source[receiptStart.lowerBound...]
        let receiptEnd = try XCTUnwrap(tail.range(of:
            "private func commitFullDrainGapPendingConsumers("))
        let receiptPath = tail[..<receiptEnd.lowerBound]
        XCTAssertTrue(receiptPath.contains("reread.status == .resolved"))
        XCTAssertTrue(receiptPath.contains("finalizeAlreadyResolvedFullDrainConsumers("))

        let finalizerStart = try XCTUnwrap(source.range(of:
            "private func finalizeAlreadyResolvedFullDrainConsumers("))
        let finalizerTail = source[finalizerStart.lowerBound...]
        let finalizerEnd = try XCTUnwrap(finalizerTail.range(of:
            "private func commitFullDrainGapLedgerCAS("))
        let finalizer = finalizerTail[..<finalizerEnd.lowerBound]
        XCTAssertFalse(finalizer.contains("commitFullDrainGapLedgerCAS("))
        XCTAssertTrue(finalizer.contains("ledgerCoverageResolved: true"))
    }

    func testOneTerminalJournalsEveryOtherGapAndResumesEachIndependently() throws {
        let root = try temporaryRoot()
        var store = makeStore(root: root)
        _ = try store.arm(gap: gap(), attempt: attempt(), now: date(102))
        let permit = try endAndPermit(store: store, sequence: 5)
        _ = try store.recordMatchingACK(identity: identity(),
                                        permit: permit,
                                        actualACKPayload: Data([0x01]),
                                        ackAttempt: 1,
                                        completedAt: date(105))
        let stores = durableStores(sequence: 6, fsyncedAt: start + 106)
        _ = try store.recordHistoryComplete(identity: identity(),
                                            completionIdentifier: "complete-a",
                                            notificationPayload: Data([0x32]),
                                            stores: stores,
                                            receivedAt: date(107))
        let authority = try XCTUnwrap(store.load())
        let denseID = UUID()
        let sparseID = UUID()
        let candidates = [
            AtriaHistoricalGapLedger.RecoveryCandidate(
                window: .init(id: denseID,
                              start: date(10),
                              end: date(30),
                              reason: "dense"),
                ledgerGeneration: 4,
                ledgerSnapshotSHA256: hash("ledger")),
            AtriaHistoricalGapLedger.RecoveryCandidate(
                window: .init(id: sparseID,
                              start: date(40),
                              end: date(60),
                              reason: "sparse"),
                ledgerGeneration: 4,
                ledgerSnapshotSHA256: hash("ledger")),
        ]
        let timestamps = (10..<30).map { start + Double($0) }
            + [start + 40, start + 59]
        let entries = try AtriaHistoricalTerminalGapReconciliationCoordinator.evaluate(
            candidates: candidates,
            excludingGapIdentifier: authority.gap.gapIdentifier,
            authority: authority,
            decoderIdentifier: "decoder",
            decoderVersion: 1,
            metricTimestampsUnix: timestamps
        )
        XCTAssertEqual(entries.map(\.status), [.coverageProven, .rejected])
        XCTAssertEqual(entries[0].coverageProof?.densityPercent, 100)
        XCTAssertNil(entries[1].coverageProof)

        _ = try store.recordTerminalGapReconciliations(identity: identity(),
                                                        entries: entries)
        store = makeStore(root: root)
        XCTAssertEqual(try store.load()?.terminalGapReconciliations, entries)
        XCTAssertThrowsError(try store.prepareTerminalGapResolution(
            identity: identity(),
            gapIdentifier: denseID.uuidString.lowercased(),
            at: date(109)
        )) {
            XCTAssertEqual($0 as? Store.StoreError, .notReadyToResolve,
                           "secondary gaps cannot outrun terminal consumers")
        }

        try markProjectionCheckpoint(store: store)
        let prepared = try store.prepareTerminalGapResolution(
            identity: identity(),
            gapIdentifier: denseID.uuidString.lowercased(),
            at: date(110)
        )
        XCTAssertEqual(prepared.terminalGapReconciliations?.first?.status,
                       .resolutionPrepared)

        store = makeStore(root: root)
        let resolved = try store.finishTerminalGapResolution(
            identity: identity(),
            gapIdentifier: denseID.uuidString.lowercased(),
            resolved: true,
            at: date(111)
        )
        XCTAssertEqual(resolved.terminalGapReconciliations?.map(\.status),
                       [.resolved, .rejected])
        XCTAssertEqual(try makeStore(root: root).load()?
            .terminalGapReconciliations?.map(\.status), [.resolved, .rejected])
    }

    func testManagerJournalsAllGapProofsBeforePrimaryProofAndReconcilesBeforeCommit() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let enumerate = try XCTUnwrap(source.range(of:
            "let terminalGapEntries = try"))
        let suffix = source[enumerate.lowerBound...]
        let journal = try XCTUnwrap(suffix.range(of:
            "recordTerminalGapReconciliations("))
        let primaryProof = try XCTUnwrap(suffix.range(of:
            ".proveCoverage("))
        XCTAssertLessThan(journal.lowerBound, primaryProof.lowerBound,
                          "a crash after primary proof must not lose the all-gap journal")

        let committed = try XCTUnwrap(source.range(of:
            "_ = try coverageStore.recordCommittedConsumers("))
        let prefix = source[..<committed.lowerBound]
        let reconciliation = try XCTUnwrap(prefix.range(of:
            "reconcileAdditionalTerminalFullDrainGaps(",
            options: .backwards))
        XCTAssertLessThan(reconciliation.lowerBound, committed.lowerBound,
                          "secondary crash replay requires the primary authority to commit last")
    }

    func testTamperedCanonicalStateFailsClosedAfterRestart() throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        _ = try store.arm(gap: gap(), attempt: attempt(), now: date(102))
        let stateURL = root.appendingPathComponent(
            "historical-full-drain-coverage-authority-v1.json"
        )
        var data = try Data(contentsOf: stateURL)
        data.append(0x20)
        try data.write(to: stateURL)
        XCTAssertThrowsError(try makeStore(root: root).load()) {
            XCTAssertEqual($0 as? Store.StoreError, .stateCorrupt)
        }
    }

    func testProductionAutomaticIntegrationIsDisabledUntilGapRecoveryIsProven() {
        XCTAssertFalse(AtriaHistoricalFullDrainCoverageIntegration
            .automaticFullDrainRecoveryEnabled)
        XCTAssertFalse(AtriaHistoricalFullDrainCoverageIntegration
            .exactRangeTransportAuthorityAvailable)
    }

    private func terminalStore() throws -> (Store, Policy.DurableStorePair) {
        let store = try armedStore()
        let permit = try endAndPermit(store: store, sequence: 5)
        _ = try store.recordMatchingACK(identity: identity(),
                                        permit: permit,
                                        actualACKPayload: Data([0x01]),
                                        ackAttempt: 1,
                                        completedAt: date(105))
        let terminalStores = durableStores(sequence: 6, fsyncedAt: start + 106)
        _ = try store.recordHistoryComplete(identity: identity(),
                                            completionIdentifier: "complete-a",
                                            notificationPayload: Data([0x32]),
                                            stores: terminalStores,
                                            receivedAt: date(107))
        return (store, terminalStores)
    }

    private func coveredStore() throws -> (Store, Policy.DurableStorePair) {
        let (store, stores) = try terminalStore()
        let proof = try Policy.evaluate(
            gapIdentifier: "gap-a",
            gapStartUnix: start,
            gapEndUnix: start + 100,
            attemptIdentifier: "attempt-a",
            transportNonce: "nonce-a",
            transportGeneration: 7,
            stores: stores,
            decoderIdentifier: "decoder",
            decoderVersion: 1,
            metricTimestampsUnix: denseTimestamps()
        )
        _ = try store.recordCoverageProof(identity: identity(), proof: proof)
        try markProjectionCheckpoint(store: store)
        return (store, stores)
    }

    private func markProjectionCheckpoint(store: Store) throws {
        _ = try store.preparePublication(
            identity: identity(),
            chunkID: "chunk-a",
            terminalBatchNumber: 1,
            durableSequence: 1,
            completedAt: date(108)
        )
        _ = try store.recordRawSeal(
            identity: identity(),
            evidence: .init(drainGeneration: 7,
                            contentSHA256: hash("chunk-a"),
                            byteCount: 100,
                            rowCount: 10,
                            firstTimestampUnix: start,
                            lastTimestampUnix: start + 99)
        )
        _ = try store.recordCompletionPublished(
            identity: identity(),
            evidence: .init(generation: 1,
                            catalogGeneration: 1,
                            catalogSnapshotSHA256: hash("catalog"),
                            aggregateSnapshotSHA256: hash("aggregate"))
        )
        _ = try store.recordProjectionsPublished(
            identity: identity(),
            evidence: .init(completionGeneration: 1,
                            inspectedSourceCount: 1,
                            receiptCount: 5,
                            artifactSHA256s: (0..<5).map { hash("artifact-\($0)") })
        )
    }

    private func endAndPermit(store: Store, sequence: UInt64) throws -> Store.ACKPermit {
        try store.recordHistoryEndFsynced(
            identity: identity(),
            boundaryIdentifier: "end-1",
            historyEndPayload: Data([0x31]),
            expectedACKPayload: Data([0x01]),
            stores: durableStores(sequence: sequence, fsyncedAt: start + 103),
            fsyncedAt: date(104)
        )
    }

    private func armedStore() throws -> Store {
        let store = try makeStore()
        _ = try store.arm(gap: gap(), attempt: attempt(), now: date(102))
        return store
    }

    private func makeStore() throws -> Store {
        makeStore(root: try temporaryRoot())
    }

    private func makeStore(root: URL) -> Store {
        Store(directoryURL: root, makeIdentifier: { "authority-a" })
    }

    private func gap() -> Store.PendingGap {
        .init(gapIdentifier: "gap-a",
              gapLedgerGeneration: 9,
              gapLedgerSnapshotSHA256: hash("gap-ledger"),
              startUnix: start,
              endUnix: start + 100,
              reason: "disconnect",
              pending: true)
    }

    private func attempt(
        generation: UInt64 = 7,
        commandSequence: UInt8 = 10,
        transportNonce: String = "nonce-a",
        writeCompletedAt: TimeInterval? = nil
    ) -> Store.Attempt {
        let writeAt = writeCompletedAt ?? start + 101
        return .init(attemptIdentifier: "attempt-a",
              attemptNumber: 3,
              peripheralIdentifier: "peripheral-a",
              strapIdentity: "whoop-4-a",
              transportNonce: transportNonce,
              transportGeneration: generation,
              fullDrainCommandSHA256: hash("full-drain-command"),
              commandWriteCompletedAtUnix: writeAt,
              transportAuthority: try! transportAuthority(
                transportGeneration: generation,
                transportNonce: transportNonce,
                fullDrainCommandSequence: commandSequence,
                fullDrainWriteCompletedAtUnix: writeAt,
                historyStartReceivedAtUnix: writeAt + 1
              ))
    }

    private func transportAuthority(
        transportGeneration: UInt64 = 7,
        transportNonce: String = "nonce-a",
        clockResponseSequence: UInt8? = 9,
        deviceClockUnix: UInt32? = 1_900_000_100,
        clockWriteCompletedAtUnix: TimeInterval? = nil,
        clockResponseReceivedAtUnix: TimeInterval? = nil,
        fullDrainCommandSequence: UInt8? = 10,
        fullDrainCommandRequestedAtUnix: TimeInterval? = nil,
        fullDrainWriteCompletedAtUnix: TimeInterval? = 1_900_000_101,
        historyStartSequence: UInt8? = 11,
        historyStartReceivedAtUnix: TimeInterval = 1_900_000_102
    ) throws -> Policy.TransportAuthority {
        try Policy.validateTransportAuthority(
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4-a",
            transportNonce: transportNonce,
            transportGeneration: transportGeneration,
            clockCommandSequence: 9,
            clockCommandRequestedAtUnix: start + 98,
            clockWriteCompletedAtUnix: clockWriteCompletedAtUnix ?? start + 99,
            clockResponseSequence: clockResponseSequence,
            deviceClockUnix: deviceClockUnix,
            clockWallUnix: UInt32(start + 100),
            clockResponseReceivedAtUnix: clockResponseReceivedAtUnix ?? start + 100,
            fullDrainCommandSequence: fullDrainCommandSequence,
            fullDrainCommandRequestedAtUnix: fullDrainCommandRequestedAtUnix
                ?? start + 100.5,
            fullDrainWriteCompletedAtUnix: fullDrainWriteCompletedAtUnix,
            historyStartSequence: historyStartSequence,
            historyStartReceivedAtUnix: historyStartReceivedAtUnix
        )
    }

    private func identity(
        attemptIdentifier: String = "attempt-a",
        strapIdentity: String = "whoop-4-a",
        transportNonce: String = "nonce-a",
        transportGeneration: UInt64 = 7
    ) -> Store.EventIdentity {
        .init(gapIdentifier: "gap-a",
              attemptIdentifier: attemptIdentifier,
              peripheralIdentifier: "peripheral-a",
              strapIdentity: strapIdentity,
              transportNonce: transportNonce,
              transportGeneration: transportGeneration)
    }

    private func durableStores(
        sequence: UInt64,
        fsyncedAt: TimeInterval,
        admissionFsyncedAt: TimeInterval? = nil,
        rawHash: String? = nil
    ) -> Policy.DurableStorePair {
        let rawSnapshot = rawHash ?? hash("raw-\(sequence)")
        let identitySnapshot = hash("identity-\(sequence)")
        let admissionSnapshot = hash("admission-\(sequence)")
        let batchKeys = hash("batch-keys-\(sequence)")
        let admissionFsync = admissionFsyncedAt ?? fsyncedAt
        return .init(raw: .init(storeIdentifier: "raw-store-a",
                         snapshotSHA256: rawSnapshot,
                         durableSequence: sequence,
                         batchKeysSHA256: batchKeys,
                         byteCount: 10_000 + sequence,
                         recordCount: 100 + sequence,
                         observedIdentityCount: 100 + sequence,
                         fsyncedAtUnix: fsyncedAt),
              identity: .init(storeIdentifier: "identity-store-a",
                              snapshotSHA256: identitySnapshot,
                              durableSequence: sequence,
                              batchKeysSHA256: batchKeys,
                              byteCount: 5_000 + sequence,
                              recordCount: 100 + sequence,
                              observedIdentityCount: 100 + sequence,
                              fsyncedAtUnix: fsyncedAt),
              admission: .init(storeIdentifier: "admission-store-a",
                              snapshotSHA256: admissionSnapshot,
                              durableSequence: sequence,
                              batchKeysSHA256: admissionSnapshot,
                              byteCount: 3_000 + sequence,
                              recordCount: 100 + sequence,
                              observedIdentityCount: 100 + sequence,
                              fsyncedAtUnix: admissionFsync),
              admissionReceipt: .init(
                  storeIdentifier: "admission-store-a",
                  snapshotSHA256: admissionSnapshot,
                  durableSequence: sequence,
                  durableOrdinal: sequence - 1,
                  recordCount: 100 + sequence,
                  byteCount: 3_000 + sequence,
                  fsyncedAtUnix: admissionFsync,
                  rawArchiveSnapshotSHA256: rawSnapshot,
                  identityIndexSnapshotSHA256: identitySnapshot,
                  archiveReceiptChainSHA256: hash("chain-\(sequence)")
              ))
    }

    private func consumerReceipts(
        stores: Policy.DurableStorePair
    ) -> [Store.ConsumerReceipt] {
        Policy.Configuration.production.requiredConsumerKinds.map {
            receipt(kind: $0, stores: stores)
        }
    }

    private func receipt(
        kind: String,
        stores: Policy.DurableStorePair
    ) -> Store.ConsumerReceipt {
        .init(kind: kind,
              receiptSHA256: hash("receipt-\(kind)"),
              artifactSHA256: hash("artifact-\(kind)"),
              sourceRawSnapshotSHA256: stores.raw.snapshotSHA256,
              sourceIdentitySnapshotSHA256: stores.identity.snapshotSHA256,
              sourceAdmissionSnapshotSHA256: stores.admission.snapshotSHA256,
              gapIdentifier: "gap-a",
              attemptIdentifier: "attempt-a",
              completionIdentifier: "complete-a",
              commitIdentifier: "commit-\(kind)",
              committedAtUnix: start + 111)
    }

    private func denseTimestamps() -> [TimeInterval] {
        (0..<100).map { start + Double($0) }
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: start + offset)
    }

    private func hash(_ value: String) -> String {
        Policy.sha256(Data(value.utf8))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaFullDrainCoverageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
}
