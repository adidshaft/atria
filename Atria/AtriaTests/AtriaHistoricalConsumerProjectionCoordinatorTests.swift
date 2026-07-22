import XCTest
@testable import Atria

final class AtriaHistoricalConsumerProjectionCoordinatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_002_000_000)
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testPublishesFiveTerminalAttestedConsumersAndRetainsRaw() throws {
        let fixture = try makeFixture()
        let coordinator = AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: fixture.completionStore,
            receiptLedger: fixture.ledger
        )

        let first = try coordinator.publishEligibleReceipts(
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.snapshot,
            configuration: configuration()
        )

        XCTAssertEqual(first.completionGeneration, 1)
        XCTAssertEqual(first.inspectedSourceCount, 1)
        XCTAssertTrue(first.deferredSources.isEmpty)
        XCTAssertEqual(Set(first.published.map(\.receipt.kind)), [
            .activity, .dailyMetrics, .steps, .sleep, .workout,
        ])
        XCTAssertEqual(first.published.count, 5)
        XCTAssertTrue(first.hasCompleteConsumerCoverage)
        XCTAssertFalse(first.rawRetirementWasAttempted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))

        let retry = try coordinator.publishEligibleReceipts(
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.snapshot,
            configuration: configuration()
        )
        XCTAssertEqual(retry.published.count, 5)
        XCTAssertTrue(retry.published.allSatisfy(\.reusedExistingReceipt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
    }

    func testPostTerminalCatalogMutationDefersInsteadOfPublishing() throws {
        let fixture = try makeFixture()
        let active = try fixture.catalogStore.activeChunkDescriptor()
        try Data("late-row\n".utf8).write(to: active.fileURL)
        let coordinator = AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: fixture.completionStore,
            receiptLedger: fixture.ledger
        )

        let report = try coordinator.publishEligibleReceipts(
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.snapshot,
            configuration: configuration()
        )

        XCTAssertTrue(report.published.isEmpty)
        XCTAssertFalse(report.hasCompleteConsumerCoverage)
        XCTAssertEqual(report.deferredSources.map(\.chunkID), [fixture.aggregate.source.chunkID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
    }

    func testRealisticNarrowGapDefersAndCannotConsumeAuthority() throws {
        let fixture = try makeFixture(narrowCompletion: true)
        let coordinator = AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: fixture.completionStore,
            receiptLedger: fixture.ledger
        )

        let report = try coordinator.publishEligibleReceipts(
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.snapshot,
            configuration: configuration()
        )

        XCTAssertEqual(report.inspectedSourceCount, 1)
        XCTAssertTrue(report.published.isEmpty)
        XCTAssertEqual(report.deferredSources.count, 1)
        XCTAssertFalse(report.hasCompleteConsumerCoverage,
                       "A narrow strap interval cannot mint civil-day/lookaround coverage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
    }

    func testCurrentCivilDayGapIsPendingFutureEvidenceInsteadOfConsumerFailure() throws {
        let calendar = utcCalendar()
        let day = calendar.startOfDay(for: start)
        let first = day.addingTimeInterval(10 * 60 * 60)
        let last = day.addingTimeInterval(12 * 60 * 60)
        let readiness = try AtriaHistoricalConsumerProjectionCoordinator
            .settlementReadiness(
                sourceFirstTimestamp: first,
                sourceLastTimestamp: last,
                completionStart: first.addingTimeInterval(-12 * 60 * 60),
                completionEnd: last,
                dailyConfiguration: configuration().daily
            )

        guard case .pendingFutureEvidence(let requiredStart, let requiredEnd) = readiness else {
            return XCTFail("a current-day exact gap must not claim future consumer evidence")
        }
        XCTAssertLessThanOrEqual(requiredStart, first.addingTimeInterval(-12 * 60 * 60))
        XCTAssertEqual(requiredEnd, calendar.date(byAdding: .day, value: 1, to: day))
    }

    func testOlderGapWithCivilDayAndLookaheadCoverageIsReady() throws {
        let calendar = utcCalendar()
        let day = calendar.startOfDay(for: start)
        let first = day.addingTimeInterval(10 * 60 * 60)
        let last = day.addingTimeInterval(12 * 60 * 60)
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let readiness = try AtriaHistoricalConsumerProjectionCoordinator
            .settlementReadiness(
                sourceFirstTimestamp: first,
                sourceLastTimestamp: last,
                completionStart: first.addingTimeInterval(-12 * 60 * 60),
                completionEnd: nextDay,
                dailyConfiguration: configuration().daily
            )

        guard case .ready(_, let requiredEnd) = readiness else {
            return XCTFail("a settled older gap should publish its five consumers")
        }
        XCTAssertEqual(requiredEnd, nextDay)
    }

    func testLaterFullScanPublishesExactlyFiveForPendingOriginalSource() throws {
        let settlement = try makeLaterFullScanFixture(coversRequiredEnd: true)
        let report = try AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: settlement.fixture.completionStore,
            receiptLedger: settlement.fixture.ledger
        ).publishReceiptSetUsingFullScan(
            for: settlement.fixture.aggregate.source.chunkID,
            expectedRawSHA256: settlement.fixture.aggregate.source.rawSHA256,
            requiredStart: settlement.requiredStart,
            requiredEnd: settlement.requiredEnd,
            fullScanStore: settlement.scanStore,
            catalogStore: settlement.fixture.catalogStore,
            aggregateSnapshot: settlement.snapshot,
            configuration: configuration()
        )

        XCTAssertEqual(report.inspectedSourceCount, 1)
        XCTAssertEqual(report.published.count, 5)
        XCTAssertTrue(report.hasCompleteConsumerCoverage)
        XCTAssertEqual(Set(report.published.map(\.receipt.kind)), [
            .activity, .dailyMetrics, .steps, .sleep, .workout,
        ])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: settlement.fixture.rawURL.path
        ))
    }

    func testLaterFullScanBeforeRequiredCursorEndFailsClosed() throws {
        let settlement = try makeLaterFullScanFixture(coversRequiredEnd: false)
        XCTAssertThrowsError(try AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: settlement.fixture.completionStore,
            receiptLedger: settlement.fixture.ledger
        ).publishReceiptSetUsingFullScan(
            for: settlement.fixture.aggregate.source.chunkID,
            expectedRawSHA256: settlement.fixture.aggregate.source.rawSHA256,
            requiredStart: settlement.requiredStart,
            requiredEnd: settlement.requiredEnd,
            fullScanStore: settlement.scanStore,
            catalogStore: settlement.fixture.catalogStore,
            aggregateSnapshot: settlement.snapshot,
            configuration: configuration()
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: settlement.fixture.rawURL.path
        ))
    }

    func testCrashAfterDurableReceiptPrefixResumesWithoutNewRawChunk() throws {
        let fixture = try makeFixture()
        var receiptCheckpoints = 0
        let crashLedger = AtriaHistoricalConsumerReceiptLedger(
            directoryURL: fixture.root.appendingPathComponent("consumer-receipts-v1")
        ) { checkpoint in
            if checkpoint == .receiptPublished {
                receiptCheckpoints += 1
                if receiptCheckpoints == 1 { throw SimulatedCrash.afterReceiptPrefix }
            }
        }
        let interrupted = try AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: fixture.completionStore,
            receiptLedger: crashLedger
        ).publishEligibleReceipts(
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.snapshot,
            configuration: configuration()
        )
        XCTAssertFalse(interrupted.hasCompleteConsumerCoverage)

        let completion = try fixture.completionStore.loadLatest()
        let exactRequest = AtriaBLEHistoryRequestAuthorityStore.ExactRequest(
            sourceIdentifier: "closed-gap-8",
            requestedStartUnix: completion.requestedStart.timeIntervalSince1970,
            requestedEndUnix: completion.requestedEnd.timeIntervalSince1970
        )
        var identifiers = ["exact-request-8", "transport-1"]
        var authorityStore = AtriaBLEHistoryRequestAuthorityStore(
            directoryURL: fixture.root.appendingPathComponent("ble-request-authority"),
            makeIdentifier: { identifiers.removeFirst() }
        )
        let authority = try authorityStore.arm(
            exactRequest: exactRequest,
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4",
            now: completion.completedAt
        )
        let binding = try authorityStore.bind(
            authorityGeneration: authority.generation,
            requestIdentifier: authority.requestIdentifier,
            transportGeneration: 41,
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4",
            now: completion.completedAt
        )
        let publicationStore = AtriaBLEHistoryTerminalPublicationStore(
            directoryURL: fixture.root.appendingPathComponent("ble-authority")
        )
        let stagedJob = try publicationStore.prepareStaged(
            binding: binding,
            chunkID: fixture.aggregate.source.chunkID,
            terminalBatchNumber: completion.terminalBatchNumber,
            durableSequence: completion.durableSequence,
            completedAt: completion.completedAt,
            transportWrite: .init(
                transportGeneration: binding.transportGeneration,
                commandSequence: 11,
                command: 0x16,
                payload: [0x00],
                writeCompletedAtUnix: completion.completedAt.timeIntervalSince1970 - 1
            )
        )
        let recoveredSeal = try HistoricalArchive.recoverAlreadySealedTerminalCatalogChunk(
            job: stagedJob,
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore
        )
        XCTAssertEqual(recoveredSeal.chunkID, fixture.aggregate.source.chunkID,
                       "Crash after seal but before journal advance must recover the sealed chunk")
        let source = fixture.aggregate.source
        let rawSealed = try publicationStore.markRawSealed(
            stagedJob,
            evidence: .init(
                drainGeneration: binding.transportGeneration,
                contentSHA256: source.rawSHA256,
                byteCount: source.rawByteCount,
                rowCount: source.rawRowCount,
                firstTimestampUnix: source.firstTimestamp.timeIntervalSince1970,
                lastTimestampUnix: source.lastTimestamp.timeIntervalSince1970
            )
        )
        let job = try publicationStore.markCompletionPublished(
            rawSealed,
            evidence: .init(
                generation: completion.generation,
                catalogGeneration: completion.catalogGeneration,
                catalogSnapshotSHA256: completion.catalogSnapshotSHA256,
                aggregateSnapshotSHA256: completion.aggregateSnapshotSHA256
            )
        )

        let restartedStore = AtriaBLEHistoryTerminalPublicationStore(
            directoryURL: fixture.root.appendingPathComponent("ble-authority")
        )
        XCTAssertEqual(try restartedStore.loadPending(matching: binding), job)
        let resumed = try HistoricalArchive.resumeTerminalConsumerProjectionsAfterCrash(
            job: job,
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore,
            configuration: configuration()
        )

        XCTAssertEqual(resumed.completion, completion)
        XCTAssertTrue(resumed.consumers.hasCompleteConsumerCoverage)
        XCTAssertEqual(resumed.consumers.published.count, 5)
        XCTAssertTrue(resumed.consumers.published.contains(where: \.reusedExistingReceipt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))

        let consumersPublished = try restartedStore.markProjectionsPublished(
            job,
            evidence: .init(
                completionGeneration: resumed.completion.generation,
                inspectedSourceCount: resumed.consumers.inspectedSourceCount,
                receiptCount: resumed.consumers.published.count,
                artifactSHA256s: resumed.consumers.published.map {
                    $0.receipt.artifactSHA256
                }.sorted()
            )
        )
        XCTAssertTrue(try authorityStore.markConsumed(
            binding: binding,
            peripheralIdentifier: binding.peripheralIdentifier,
            strapIdentity: binding.strapIdentity,
            completedAt: completion.completedAt
        ))
        // Simulate a crash after authority consumption but before the journal
        // flips to completed. Re-open both stores and reconcile without arming.
        authorityStore = AtriaBLEHistoryRequestAuthorityStore(
            directoryURL: fixture.root.appendingPathComponent("ble-request-authority")
        )
        _ = try authorityStore.validateConsumedAuthority(
            generation: consumersPublished.authorityGeneration,
            requestIdentifier: consumersPublished.requestIdentifier,
            peripheralIdentifier: consumersPublished.peripheralIdentifier,
            strapIdentity: consumersPublished.strapIdentity,
            exactRequest: consumersPublished.exactRequest
        )
        let reverified = try HistoricalArchive.resumeTerminalConsumerProjectionsAfterCrash(
            job: consumersPublished,
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore,
            configuration: configuration()
        )
        XCTAssertTrue(reverified.consumers.hasCompleteConsumerCoverage)
        try restartedStore.markAuthorityConsumedAfterReconciliation(consumersPublished)
        XCTAssertEqual(try restartedStore.load()?.status, .authorityConsumed)
    }

    private enum SimulatedCrash: Error {
        case afterReceiptPrefix
    }

    func testRejectedAggregateManifestStopsAllPublication() throws {
        let fixture = try makeFixture()
        let rejected = AtriaHistoricalAggregateReader.Snapshot(
            aggregates: fixture.snapshot.aggregates,
            diagnostics: .init(committedManifests: 2,
                               acceptedAggregates: 1,
                               rejectedManifests: 1)
        )
        let coordinator = AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: fixture.completionStore,
            receiptLedger: fixture.ledger
        )

        XCTAssertThrowsError(try coordinator.publishEligibleReceipts(
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: rejected,
            configuration: configuration()
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalConsumerProjectionCoordinator.CoordinatorError,
                           .rejectedAggregateManifest)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
    }

    private struct Fixture {
        let root: URL
        let catalogStore: AtriaHistoricalArchiveCatalogStore
        let aggregate: AtriaHistoricalAggregateChunk
        let snapshot: AtriaHistoricalAggregateReader.Snapshot
        let completionStore: AtriaHistoricalDrainCompletionGenerationStore
        let ledger: AtriaHistoricalConsumerReceiptLedger
        let rawURL: URL
    }

    private struct LaterFullScanFixture {
        let fixture: Fixture
        let scanStore: AtriaHistoricalFullScanCompletionStore
        let snapshot: AtriaHistoricalAggregateReader.Snapshot
        let requiredStart: Date
        let requiredEnd: Date
    }

    private func makeLaterFullScanFixture(
        coversRequiredEnd: Bool
    ) throws -> LaterFullScanFixture {
        let fixture = try makeFixture(narrowCompletion: true)
        let readiness = try AtriaHistoricalConsumerProjectionCoordinator
            .settlementReadiness(
                sourceFirstTimestamp: fixture.aggregate.source.firstTimestamp,
                sourceLastTimestamp: fixture.aggregate.source.lastTimestamp,
                completionStart: fixture.aggregate.source.firstTimestamp,
                completionEnd: fixture.aggregate.source.lastTimestamp,
                dailyConfiguration: configuration().daily
            )
        guard case .pendingFutureEvidence(let requiredStart, let requiredEnd) = readiness else {
            throw AtriaHistoricalConsumerProjectionCoordinator.CoordinatorError
                .invalidRequiredRange
        }

        let active = try fixture.catalogStore.activeChunkDescriptor()
        let scanStart = requiredStart.addingTimeInterval(-60)
        let scanEnd = coversRequiredEnd
            ? requiredEnd
            : requiredEnd.addingTimeInterval(-60)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let records = [historicalRecord(at: scanStart), historicalRecord(at: scanEnd)]
        var raw = Data()
        for record in records {
            raw.append(try encoder.encode(record))
            raw.append(0x0A)
        }
        try raw.write(to: active.fileURL)
        let digest = AtriaHistoricalRetentionTransaction.sha256(of: raw)
        try fixture.catalogStore.sealActiveChunkAtTerminal(
            chunkID: active.chunkID,
            rowCount: records.count,
            firstTimestamp: scanStart,
            lastTimestamp: scanEnd,
            contentSHA256: digest,
            now: scanEnd
        )
        let scanAggregate = try AtriaHistoricalAggregateBuilder.build(
            sourceURL: active.fileURL,
            chunkID: active.chunkID,
            createdAt: scanEnd.addingTimeInterval(1)
        ).aggregate
        let aggregates = fixture.root.appendingPathComponent("aggregates-v2")
        let manifests = fixture.root.appendingPathComponent("retention-manifests-v2")
        _ = try AtriaHistoricalRetentionTransaction(
            now: { scanEnd.addingTimeInterval(2) },
            semanticVerifier: { _, _, _ in true }
        ).commit(.init(
            transactionID: active.chunkID,
            sourceURL: active.fileURL,
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests,
            aggregate: scanAggregate,
            semanticParityReceipt: AtriaHistoricalAggregateBuilder
                .semanticParityReceipt(for: scanAggregate),
            deleteSourceAfterCommit: false
        ))
        let snapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        ).load()
        let catalog = try fixture.catalogStore.snapshotVerifiedAgainstFiles()
        let scanStore = AtriaHistoricalFullScanCompletionStore(
            directoryURL: fixture.root.appendingPathComponent("full-scan-completions-v1")
        )
        _ = try scanStore.recordCompletion(.init(
            version: AtriaHistoricalFullScanCompletionStore.Record.currentVersion,
            generation: 2,
            transportGeneration: 2,
            transportNonce: "scan-nonce-2",
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4",
            cursorWatermark: scanEnd,
            terminalAt: scanEnd.addingTimeInterval(60),
            sourceChunkID: scanAggregate.source.chunkID,
            sourceRawSHA256: scanAggregate.source.rawSHA256,
            sourceFirstTimestamp: scanAggregate.source.firstTimestamp,
            sourceLastTimestamp: scanAggregate.source.lastTimestamp,
            observedArchiveFirstTimestamp: min(
                scanAggregate.source.firstTimestamp,
                fixture.aggregate.source.firstTimestamp
            ),
            catalogGeneration: catalog.generation,
            catalogSnapshotSHA256: AtriaHistoricalDrainCompletionGenerationStore.sha256(
                try AtriaHistoricalActivityInspectionProofFactory
                    .canonicalCatalogData(catalog)
            ),
            aggregateSnapshotSHA256: AtriaHistoricalDrainCompletionGenerationStore.sha256(
                try AtriaHistoricalActivityInspectionProofFactory
                    .canonicalAggregateSnapshotData(snapshot)
            )
        ))
        return .init(
            fixture: fixture,
            scanStore: scanStore,
            snapshot: snapshot,
            requiredStart: requiredStart,
            requiredEnd: requiredEnd
        )
    }

    private func makeFixture(narrowCompletion: Bool = false) throws -> Fixture {
        let root = try temporaryRoot()
        var identifiers = ["sealed-source", "active-next", "active-after-scan"]
        let catalogStore = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            maximumActiveBytes: 1024,
            calendar: utcCalendar(),
            makeIdentifier: { identifiers.removeFirst() }
        )
        _ = try catalogStore.loadOrRecover(discoveredLegacyURLs: [], now: start)
        let active = try catalogStore.activeChunkDescriptor()
        try FileManager.default.createDirectory(
            at: active.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let end = start.addingTimeInterval(3_600)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let records = [historicalRecord(at: start), historicalRecord(at: end)]
        var raw = Data()
        for record in records {
            raw.append(try encoder.encode(record))
            raw.append(0x0A)
        }
        try raw.write(to: active.fileURL)
        let digest = AtriaHistoricalRetentionTransaction.sha256(of: raw)
        try catalogStore.sealActiveChunkAtTerminal(
            chunkID: active.chunkID,
            rowCount: records.count,
            firstTimestamp: start,
            lastTimestamp: end,
            contentSHA256: digest,
            now: end
        )
        let aggregate = try AtriaHistoricalAggregateBuilder.build(
            sourceURL: active.fileURL,
            chunkID: active.chunkID,
            createdAt: end.addingTimeInterval(1)
        ).aggregate
        let aggregates = root.appendingPathComponent("aggregates-v2")
        let manifests = root.appendingPathComponent("retention-manifests-v2")
        _ = try AtriaHistoricalRetentionTransaction(
            now: { end.addingTimeInterval(2) },
            semanticVerifier: { _, _, _ in true }
        ).commit(.init(
            transactionID: active.chunkID,
            sourceURL: active.fileURL,
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests,
            aggregate: aggregate,
            semanticParityReceipt: AtriaHistoricalAggregateBuilder.semanticParityReceipt(for: aggregate),
            deleteSourceAfterCommit: false
        ))
        let snapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        ).load()
        let completionStore = AtriaHistoricalDrainCompletionGenerationStore(
            directoryURL: root.appendingPathComponent("drain-completions-v1")
        )
        let requestedStart = narrowCompletion
            ? start.addingTimeInterval(10 * 60)
            : start.addingTimeInterval(-24 * 60 * 60)
        let requestedEnd = narrowCompletion
            ? end.addingTimeInterval(-10 * 60)
            : end.addingTimeInterval(24 * 60 * 60)
        _ = try completionStore.recordTerminal(
            generation: 1,
            terminalBatchNumber: 2,
            durableSequence: 1,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completedAt: requestedEnd,
            catalogStore: catalogStore,
            aggregateSnapshot: snapshot
        )
        return .init(root: root,
                     catalogStore: catalogStore,
                     aggregate: aggregate,
                     snapshot: snapshot,
                     completionStore: completionStore,
                     ledger: .init(directoryURL: root.appendingPathComponent("consumer-receipts-v1")),
                     rawURL: active.fileURL)
    }

    private func configuration() -> AtriaHistoricalConsumerProjectionCoordinator.Configuration {
        .init(
            activity: .init(restingHeartRate: 55,
                            maximumHeartRate: 190,
                            timeZoneIdentifier: "UTC"),
            daily: .init(timeZoneIdentifier: "UTC",
                         dayBoundaryPolicyVersion: "gregorian-civil-midnight-v1"),
            sleep: .init(timeZoneIdentifier: "UTC",
                         minimumDurationSeconds: 2 * 60 * 60,
                         minimumValidatedMotionCoverage: 0.80,
                         stillnessThreshold: 0.80,
                         maximumMovementIntensity: 0.08),
            workout: .init(restingHeartRate: 55,
                           maximumHeartRate: 190,
                           timeZoneIdentifier: "UTC",
                           minimumDurationMinutes: 10,
                           minimumHeartRateCoverage: 0.80)
        )
    }

    private func historicalRecord(at date: Date) -> HistoricalArchive.Record {
        let unix = UInt32(date.timeIntervalSince1970)
        return .init(schema: HistoricalArchive.schema,
                     capturedAt: date,
                     source: "0x2f",
                     layoutVersion: HistoricalArchive.layoutVersion,
                     sequence: Int(unix % 65_535),
                     command: 0x2f,
                     unix7: unix,
                     subsec11: 0,
                     flash13: unix,
                     payloadLength: 64,
                     whoofHR17: 70,
                     whoofRRNum18: 0,
                     whoofRR19: [],
                     kRR64: [],
                     gravityX36: 0,
                     gravityY40: 0,
                     gravityZ44: 1,
                     gravityMagnitude: 1,
                     gravityValidated: true,
                     candidateRR: [],
                     rawPayloadHex: "00",
                     clockDeviceRef: 1,
                     clockWallRef: 1,
                     clockDriftSeconds: 0,
                     clockCorrectedUnix7: unix,
                     clockCorrectionStatus: "clock_ref_present",
                     currentSessionUsable: true,
                     metricUsable: true,
                     usabilityReason: "test")
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalConsumerProjectionCoordinatorTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
}
