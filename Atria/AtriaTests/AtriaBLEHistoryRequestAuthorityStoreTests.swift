import XCTest
@testable import Atria

final class AtriaBLEHistoryRequestAuthorityStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testArmedAuthorityAndBindingSurviveProcessRestart() throws {
        let root = try temporaryRoot()
        var store = makeStore(root, identifiers: ["request-1", "transport-1"])
        let request = exactRequest(start: 1_900_000_000)
        let authority = try store.arm(exactRequest: request,
                                      peripheralIdentifier: "peripheral-a",
                                      strapIdentity: "whoop-4",
                                      now: request.requestedEnd)
        let binding = try store.bind(authorityGeneration: authority.generation,
                                     requestIdentifier: authority.requestIdentifier,
                                     transportGeneration: 7,
                                     peripheralIdentifier: "peripheral-a",
                                     strapIdentity: "whoop-4",
                                     now: request.requestedEnd)

        store = makeStore(root, identifiers: ["unused"])
        XCTAssertEqual(try store.validateTerminal(binding: binding,
                                                  peripheralIdentifier: "peripheral-a",
                                                  strapIdentity: "whoop-4"),
                       try store.loadAuthority())
    }

    func testReconnectBindingRejectsStaleCallback() throws {
        let root = try temporaryRoot()
        let store = makeStore(root, identifiers: ["request-1", "transport-1", "transport-2"])
        let request = exactRequest(start: 1_900_000_000)
        let authority = try store.arm(exactRequest: request,
                                      peripheralIdentifier: "peripheral-a",
                                      strapIdentity: "whoop-4",
                                      now: request.requestedEnd)
        let old = try store.bind(authorityGeneration: authority.generation,
                                 requestIdentifier: authority.requestIdentifier,
                                 transportGeneration: 1,
                                 peripheralIdentifier: "peripheral-a",
                                 strapIdentity: "whoop-4",
                                 now: request.requestedEnd)
        let current = try store.bind(authorityGeneration: authority.generation,
                                     requestIdentifier: authority.requestIdentifier,
                                     transportGeneration: 2,
                                     peripheralIdentifier: "peripheral-a",
                                     strapIdentity: "whoop-4",
                                     now: request.requestedEnd.addingTimeInterval(1))

        XCTAssertThrowsError(try store.validateTerminal(binding: old,
                                                        peripheralIdentifier: "peripheral-a",
                                                        strapIdentity: "whoop-4")) {
            XCTAssertEqual($0 as? AtriaBLEHistoryRequestAuthorityStore.StoreError,
                           .staleTransportAttempt)
        }
        XCTAssertNoThrow(try store.validateTerminal(binding: current,
                                                    peripheralIdentifier: "peripheral-a",
                                                    strapIdentity: "whoop-4"))
    }

    func testChangedRequestMonotonicallyInvalidatesOldAuthority() throws {
        let root = try temporaryRoot()
        let store = makeStore(root, identifiers: ["request-1", "transport-1", "request-2", "transport-2"])
        let firstRequest = exactRequest(start: 1_900_000_000)
        let first = try store.arm(exactRequest: firstRequest,
                                  peripheralIdentifier: "peripheral-a",
                                  strapIdentity: "whoop-4",
                                  now: firstRequest.requestedEnd)
        let stale = try store.bind(authorityGeneration: first.generation,
                                   requestIdentifier: first.requestIdentifier,
                                   transportGeneration: 1,
                                   peripheralIdentifier: "peripheral-a",
                                   strapIdentity: "whoop-4",
                                   now: firstRequest.requestedEnd)
        let secondRequest = exactRequest(start: 1_900_010_000)
        let second = try store.arm(exactRequest: secondRequest,
                                   peripheralIdentifier: "peripheral-a",
                                   strapIdentity: "whoop-4",
                                   now: secondRequest.requestedEnd)
        XCTAssertEqual(second.generation, first.generation + 1)
        _ = try store.bind(authorityGeneration: second.generation,
                           requestIdentifier: second.requestIdentifier,
                           transportGeneration: 2,
                           peripheralIdentifier: "peripheral-a",
                           strapIdentity: "whoop-4",
                           now: secondRequest.requestedEnd)
        XCTAssertThrowsError(try store.validateTerminal(binding: stale,
                                                        peripheralIdentifier: "peripheral-a",
                                                        strapIdentity: "whoop-4")) {
            XCTAssertEqual($0 as? AtriaBLEHistoryRequestAuthorityStore.StoreError,
                           .staleAuthority)
        }
    }

    func testConsumptionIsOneShotAndWrongPeripheralFailsClosed() throws {
        let root = try temporaryRoot()
        let store = makeStore(root, identifiers: ["request-1", "transport-1", "request-2"])
        let request = exactRequest(start: 1_900_000_000)
        let authority = try store.arm(exactRequest: request,
                                      peripheralIdentifier: "peripheral-a",
                                      strapIdentity: "whoop-4",
                                      now: request.requestedEnd)
        let binding = try store.bind(authorityGeneration: authority.generation,
                                     requestIdentifier: authority.requestIdentifier,
                                     transportGeneration: 1,
                                     peripheralIdentifier: "peripheral-a",
                                     strapIdentity: "whoop-4",
                                     now: request.requestedEnd)
        XCTAssertThrowsError(try store.validateTerminal(binding: binding,
                                                        peripheralIdentifier: "peripheral-b",
                                                        strapIdentity: "whoop-4")) {
            XCTAssertEqual($0 as? AtriaBLEHistoryRequestAuthorityStore.StoreError,
                           .peripheralMismatch)
        }
        XCTAssertTrue(try store.markConsumed(binding: binding,
                                             peripheralIdentifier: "peripheral-a",
                                             strapIdentity: "whoop-4",
                                             completedAt: request.requestedEnd))
        XCTAssertFalse(try store.markConsumed(binding: binding,
                                              peripheralIdentifier: "peripheral-a",
                                              strapIdentity: "whoop-4",
                                              completedAt: request.requestedEnd))
        XCTAssertThrowsError(try store.validateTerminal(binding: binding,
                                                        peripheralIdentifier: "peripheral-a",
                                                        strapIdentity: "whoop-4")) {
            XCTAssertEqual($0 as? AtriaBLEHistoryRequestAuthorityStore.StoreError,
                           .authorityConsumed)
        }
        let rearmed = try store.arm(exactRequest: request,
                                    peripheralIdentifier: "peripheral-a",
                                    strapIdentity: "whoop-4",
                                    now: request.requestedEnd.addingTimeInterval(1))
        XCTAssertEqual(rearmed.generation, authority.generation + 1)
    }

    func testCorruptDurableStateNeverRearmsFromZero() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent("ble-history-request-authority-v1.json")
        )
        let store = makeStore(root, identifiers: ["request-1"])
        XCTAssertThrowsError(try store.arm(exactRequest: exactRequest(start: 1_900_000_000),
                                           peripheralIdentifier: "peripheral-a",
                                           strapIdentity: "whoop-4",
                                           now: Date(timeIntervalSince1970: 1_900_001_000))) {
            XCTAssertEqual($0 as? AtriaBLEHistoryRequestAuthorityStore.StoreError,
                           .stateCorrupt)
        }
    }

    func testPolicyAcceptsOnlyClosedGenuineIntervals() {
        let now = Date(timeIntervalSince1970: 1_900_100_000)
        let start = now.addingTimeInterval(-3_600)
        let end = now.addingTimeInterval(-1_800)
        let explicit = AtriaBLEHistoryExactRequestPolicy.resolve(
            pending: true,
            explicitStart: start.timeIntervalSince1970,
            explicitEnd: end.timeIntervalSince1970,
            gapWindows: [],
            now: now
        )
        XCTAssertEqual(explicit?.requestedStart, start)
        XCTAssertEqual(explicit?.requestedEnd, end)

        let open = AtriaHistoricalGapLedger.Window(start: start, reason: "disconnect")
        XCTAssertNil(AtriaBLEHistoryExactRequestPolicy.resolve(
            pending: true,
            explicitStart: nil,
            explicitEnd: nil,
            gapWindows: [open],
            now: now
        ))
        XCTAssertNil(AtriaBLEHistoryExactRequestPolicy.resolve(
            pending: false,
            explicitStart: start,
            explicitEnd: end,
            gapWindows: [],
            now: now
        ))

        let closed = AtriaHistoricalGapLedger.Window(start: start,
                                                     end: end,
                                                     reason: "disconnect")
        let fromLedger = AtriaBLEHistoryExactRequestPolicy.resolve(
            pending: true,
            explicitStart: nil,
            explicitEnd: nil,
            gapWindows: [closed],
            now: now
        )
        XCTAssertEqual(fromLedger?.requestedStart, start)
        XCTAssertEqual(fromLedger?.requestedEnd, end)
        XCTAssertTrue(fromLedger?.sourceIdentifier.hasPrefix("gap-window-") == true)
    }

    func testReducerExposesTerminalAuthorityOnlyAfterDurableNonemptyCompletion() {
        var drain = AtriaWhoop4HistoryDrainState()
        _ = drain.begin(generation: 9)
        XCTAssertNil(drain.terminalBatchNumberForCompletedDrain)
        XCTAssertNil(drain.durableFrameCountForCompletedDrain)
        let frame = drain.receiveFrame(generation: 9,
                                       frameKey: "frame",
                                       payload: [0x2f, 0, 0, 1, 0])
        XCTAssertEqual(frame.count, 1)
        _ = drain.historyComplete(generation: 9)
        let flush = drain.persistenceCompleted(generation: 9,
                                               frameKey: "frame",
                                               succeeded: true)
        guard case .durableFlush(_, let boundary) = flush.first else {
            return XCTFail("Expected terminal durable flush")
        }
        _ = drain.durableFlushCompleted(generation: 9,
                                        boundary: boundary,
                                        succeeded: true)
        XCTAssertEqual(drain.terminalBatchNumberForCompletedDrain, 0)
        XCTAssertEqual(drain.durableFrameCountForCompletedDrain, 1)
    }

    func testTerminalPublicationJobSurvivesRestartAndReconnectAttempt() throws {
        let root = try temporaryRoot()
        var authorityStore = makeStore(
            root.appendingPathComponent("authority"),
            identifiers: ["request-1", "transport-1"]
        )
        let request = exactRequest(start: 1_900_000_000)
        let authority = try authorityStore.arm(
            exactRequest: request,
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4",
            now: request.requestedEnd
        )
        let firstBinding = try authorityStore.bind(
            authorityGeneration: authority.generation,
            requestIdentifier: authority.requestIdentifier,
            transportGeneration: 7,
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4",
            now: request.requestedEnd
        )
        var publicationStore = AtriaBLEHistoryTerminalPublicationStore(
            directoryURL: root.appendingPathComponent("publication")
        )
        let job = try publicationStore.prepareStaged(
            binding: firstBinding,
            chunkID: "sealed-chunk-a",
            terminalBatchNumber: 3,
            durableSequence: 55,
            completedAt: request.requestedEnd,
            transportWrite: transportEvidence(
                generation: firstBinding.transportGeneration,
                completedAt: request.requestedEnd
            )
        )

        authorityStore = makeStore(
            root.appendingPathComponent("authority"),
            identifiers: ["transport-2"]
        )
        publicationStore = AtriaBLEHistoryTerminalPublicationStore(
            directoryURL: root.appendingPathComponent("publication")
        )
        let currentBinding = try authorityStore.bind(
            authorityGeneration: authority.generation,
            requestIdentifier: authority.requestIdentifier,
            transportGeneration: 1,
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4",
            now: request.requestedEnd.addingTimeInterval(10)
        )

        let resumed = try publicationStore.loadPending(matching: currentBinding)
        XCTAssertEqual(resumed, job)
        XCTAssertNotEqual(currentBinding.attempt, job.originalAttempt)
        XCTAssertNotEqual(currentBinding.transportNonce, job.originalTransportNonce)
        let sealed = try publicationStore.markRawSealed(
            job,
            evidence: rawSealEvidence(generation: firstBinding.transportGeneration)
        )
        let completed = try publicationStore.markCompletionPublished(
            sealed,
            evidence: completionEvidence()
        )
        let published = try publicationStore.markProjectionsPublished(
            completed,
            evidence: projectionEvidence()
        )
        try publicationStore.markAuthorityConsumed(published,
                                                   matching: currentBinding)
        XCTAssertEqual(try publicationStore.load()?.status, .authorityConsumed)
    }

    func testTerminalPublicationJobRejectsDifferentAuthority() throws {
        let root = try temporaryRoot()
        let store = AtriaBLEHistoryTerminalPublicationStore(directoryURL: root)
        let request = exactRequest(start: 1_900_000_000)
        let binding = AtriaBLEHistoryRequestAuthorityStore.Binding(
            authorityGeneration: 1,
            requestIdentifier: "request-1",
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4",
            exactRequest: request,
            attempt: 1,
            transportNonce: "transport-1",
            transportGeneration: 1
        )
        _ = try store.prepareStaged(binding: binding,
                                    chunkID: "sealed-chunk-a",
                                    terminalBatchNumber: 0,
                                    durableSequence: 1,
                                    completedAt: request.requestedEnd,
                                    transportWrite: transportEvidence(
                                        generation: binding.transportGeneration,
                                        completedAt: request.requestedEnd
                                    ))
        let unrelated = AtriaBLEHistoryRequestAuthorityStore.Binding(
            authorityGeneration: 2,
            requestIdentifier: "request-2",
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4",
            exactRequest: request,
            attempt: 1,
            transportNonce: "transport-2",
            transportGeneration: 2
        )
        XCTAssertNil(try store.loadPending(matching: unrelated))
    }

    func testTerminalTransactionResumesAfterEveryDurableStage() throws {
        let root = try temporaryRoot()
        let request = exactRequest(start: 1_900_000_000)
        let binding = AtriaBLEHistoryRequestAuthorityStore.Binding(
            authorityGeneration: 4,
            requestIdentifier: "request-4",
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4",
            exactRequest: request,
            attempt: 2,
            transportNonce: "transport-2",
            transportGeneration: 19
        )
        var store = AtriaBLEHistoryTerminalPublicationStore(directoryURL: root)
        let prepared = try store.prepareStaged(
            binding: binding,
            chunkID: "chunk-19",
            terminalBatchNumber: 8,
            durableSequence: 55,
            completedAt: request.requestedEnd,
            transportWrite: transportEvidence(
                generation: binding.transportGeneration,
                completedAt: request.requestedEnd
            )
        )
        XCTAssertEqual(prepared.status, .prepared)

        store = .init(directoryURL: root)
        XCTAssertEqual(try store.loadPending(matching: binding)?.status, .prepared)
        let raw = try store.markRawSealed(
            prepared,
            evidence: rawSealEvidence(generation: binding.transportGeneration)
        )

        store = .init(directoryURL: root)
        XCTAssertEqual(try store.loadPending(matching: binding)?.status, .rawSealed)
        let completion = try store.markCompletionPublished(
            raw,
            evidence: completionEvidence()
        )

        store = .init(directoryURL: root)
        XCTAssertEqual(try store.loadPending(matching: binding)?.status,
                       .completionPublished)
        let projections = try store.markProjectionsPublished(
            completion,
            evidence: projectionEvidence()
        )

        store = .init(directoryURL: root)
        XCTAssertEqual(try store.loadPending(matching: binding)?.status,
                       .projectionsPublished)
        try store.markAuthorityConsumed(projections, matching: binding)

        store = .init(directoryURL: root)
        XCTAssertEqual(try store.load()?.status, .authorityConsumed)
        XCTAssertThrowsError(try store.loadPending(matching: binding)) {
            XCTAssertEqual($0 as? AtriaBLEHistoryTerminalPublicationStore.StoreError,
                           .jobCompleted)
        }
    }

    func testTerminalTransactionRejectsWrongTransportAndDeferredProjection() throws {
        let root = try temporaryRoot()
        let request = exactRequest(start: 1_900_000_000)
        let binding = AtriaBLEHistoryRequestAuthorityStore.Binding(
            authorityGeneration: 9,
            requestIdentifier: "request-9",
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4",
            exactRequest: request,
            attempt: 3,
            transportNonce: "transport-3",
            transportGeneration: 27
        )
        let store = AtriaBLEHistoryTerminalPublicationStore(directoryURL: root)
        XCTAssertThrowsError(try store.prepareStaged(
            binding: binding,
            chunkID: "chunk-27",
            terminalBatchNumber: 1,
            durableSequence: 5,
            completedAt: request.requestedEnd,
            transportWrite: transportEvidence(
                generation: binding.transportGeneration + 1,
                completedAt: request.requestedEnd
            )
        )) {
            XCTAssertEqual($0 as? AtriaBLEHistoryTerminalPublicationStore.StoreError,
                           .invalidJob)
        }

        let prepared = try store.prepareStaged(
            binding: binding,
            chunkID: "chunk-27",
            terminalBatchNumber: 1,
            durableSequence: 5,
            completedAt: request.requestedEnd,
            transportWrite: transportEvidence(
                generation: binding.transportGeneration,
                completedAt: request.requestedEnd
            )
        )
        XCTAssertThrowsError(try store.markRawSealed(
            prepared,
            evidence: rawSealEvidence(generation: binding.transportGeneration + 1)
        )) {
            XCTAssertEqual($0 as? AtriaBLEHistoryTerminalPublicationStore.StoreError,
                           .invalidJob)
        }
        let raw = try store.markRawSealed(
            prepared,
            evidence: rawSealEvidence(generation: binding.transportGeneration)
        )
        XCTAssertThrowsError(try store.markProjectionsPublished(
            raw,
            evidence: projectionEvidence()
        )) {
            XCTAssertEqual($0 as? AtriaBLEHistoryTerminalPublicationStore.StoreError,
                           .conflictingJob)
        }
        XCTAssertThrowsError(try store.markAuthorityConsumed(raw,
                                                             matching: binding)) {
            XCTAssertEqual($0 as? AtriaBLEHistoryTerminalPublicationStore.StoreError,
                           .conflictingJob)
        }
        XCTAssertEqual(try store.load()?.status, .rawSealed,
                       "Deferred consumers must leave authority consumption impossible")
    }

    private func exactRequest(start: TimeInterval)
        -> AtriaBLEHistoryRequestAuthorityStore.ExactRequest {
        .init(sourceIdentifier: "gap-window-fixture",
              requestedStartUnix: start,
              requestedEndUnix: start + 900)
    }

    private func transportEvidence(
        generation: UInt64,
        completedAt: Date
    ) -> AtriaBLEHistoryTerminalPublicationStore.TransportWriteEvidence {
        .init(transportGeneration: generation,
              commandSequence: 17,
              command: 0x16,
              payload: [0x00],
              writeCompletedAtUnix: completedAt.timeIntervalSince1970 - 1)
    }

    private func rawSealEvidence(
        generation: UInt64
    ) -> AtriaBLEHistoryTerminalPublicationStore.RawSealEvidence {
        .init(drainGeneration: generation,
              contentSHA256: String(repeating: "a", count: 64),
              byteCount: 1024,
              rowCount: 55,
              firstTimestampUnix: 1_900_000_000,
              lastTimestampUnix: 1_900_000_900)
    }

    private func completionEvidence()
        -> AtriaBLEHistoryTerminalPublicationStore.CompletionEvidence {
        .init(generation: 1,
              catalogGeneration: 2,
              catalogSnapshotSHA256: String(repeating: "b", count: 64),
              aggregateSnapshotSHA256: String(repeating: "c", count: 64))
    }

    private func projectionEvidence()
        -> AtriaBLEHistoryTerminalPublicationStore.ProjectionEvidence {
        .init(completionGeneration: 1,
              inspectedSourceCount: 1,
              receiptCount: 5,
              artifactSHA256s: (0..<5).map {
                  String(repeating: String(format: "%x", $0 + 1), count: 64)
              })
    }

    private func makeStore(
        _ root: URL,
        identifiers: [String]
    ) -> AtriaBLEHistoryRequestAuthorityStore {
        var remaining = identifiers
        return AtriaBLEHistoryRequestAuthorityStore(
            directoryURL: root,
            makeIdentifier: { remaining.removeFirst() }
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaBLEHistoryRequestAuthorityStoreTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
}
