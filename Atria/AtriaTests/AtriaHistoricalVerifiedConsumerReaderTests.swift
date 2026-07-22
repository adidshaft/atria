import XCTest
@testable import Atria

final class AtriaHistoricalVerifiedConsumerReaderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_002_000_000)
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testReadsFiveTerminalAttestedArtifactsWithExplicitEvidenceStates() throws {
        let fixture = try makeFixture()
        _ = try publishAll(fixture)

        let result = makeReader(fixture).readSource(
            chunkID: fixture.aggregate.source.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: configuration()
        )

        XCTAssertEqual(result.activity, .knownEmpty)
        if case .available(let artifact) = result.dailyMetrics {
            XCTAssertFalse(artifact.days.isEmpty)
            XCTAssertTrue(artifact.days.allSatisfy { $0.heartRateState == .missing })
        } else {
            XCTFail("daily metrics must be verified and available")
        }
        if case .available(let artifact) = result.steps {
            XCTAssertFalse(artifact.days.isEmpty)
            XCTAssertTrue(artifact.days.allSatisfy { $0.state == .missing })
        } else {
            XCTFail("steps must preserve explicit missing evidence")
        }
        XCTAssertEqual(result.sleep, .knownEmpty)
        XCTAssertEqual(result.workout, .knownEmpty)
        XCTAssertTrue(result.hasConsumableValue)
        let identity = try XCTUnwrap(result.verificationIdentity)
        XCTAssertEqual(identity.completionGeneration, 1)
        XCTAssertEqual(identity.source.chunkID, fixture.aggregate.source.chunkID)
        XCTAssertEqual(identity.source.rawSHA256, fixture.aggregate.source.rawSHA256)
        XCTAssertEqual(identity.receipts.map(\.kind),
                       [AtriaHistoricalAggregateChunk.MaterializedProjection.Kind.activity,
                        .dailyMetrics, .sleep, .steps, .workout])
        XCTAssertEqual(Set(identity.receipts.map(\.artifactSHA256)).count, 5)
        XCTAssertTrue(identity.receipts.allSatisfy {
            $0.source == identity.source && $0.completionWatermark == fixture.requestedEnd
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path),
                      "consumer reads must never retire raw history")
    }

    func testUnpublishedReceiptsAreMissingRatherThanKnownEmpty() throws {
        let fixture = try makeFixture()

        let result = makeReader(fixture).readSource(
            chunkID: fixture.aggregate.source.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: configuration()
        )

        XCTAssertEqual(result.activity, .missing(.receiptNotPublished))
        XCTAssertEqual(result.dailyMetrics, .missing(.receiptNotPublished))
        XCTAssertEqual(result.steps, .missing(.receiptNotPublished))
        XCTAssertEqual(result.sleep, .missing(.receiptNotPublished))
        XCTAssertEqual(result.workout, .missing(.receiptNotPublished))
        XCTAssertNil(result.verificationIdentity)
        XCTAssertFalse(result.hasConsumableValue)
    }

    func testHashOrConfigurationMismatchCannotReachConsumer() throws {
        let fixture = try makeFixture()
        let published = try publishAll(fixture)

        var changed = configuration()
        changed = .init(activity: .init(restingHeartRate: 60,
                                        maximumHeartRate: 190,
                                        timeZoneIdentifier: "UTC"),
                        daily: changed.daily,
                        sleep: changed.sleep,
                        workout: changed.workout)
        let configurationMismatch = makeReader(fixture).readSource(
            chunkID: fixture.aggregate.source.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: changed
        )
        XCTAssertEqual(configurationMismatch.activity, .deferred(.verificationFailed))

        let activity = try XCTUnwrap(published.first { $0.receipt.kind == .activity })
        try Data("tampered".utf8).write(to: activity.artifactURL)
        let hashMismatch = makeReader(fixture).readSource(
            chunkID: fixture.aggregate.source.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: configuration()
        )

        XCTAssertEqual(hashMismatch.activity, .deferred(.verificationFailed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
    }

    func testPostTerminalAppendDuringReadDefersEveryArtifact() throws {
        let fixture = try makeFixture()
        _ = try publishAll(fixture)
        let active = try fixture.catalogStore.activeChunkDescriptor()
        var reader = makeReader(fixture)
        reader.checkpoint = { point in
            guard point == .artifactsRead else { return }
            try Data("late-row\n".utf8).write(to: active.fileURL)
        }

        let result = reader.readSource(
            chunkID: fixture.aggregate.source.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: configuration()
        )

        assertAllDeferred(result, reason: .evidenceChangedDuringRead)
        XCTAssertNil(result.verificationIdentity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
    }

    func testCommittedAggregateMutationDuringReadDefersEveryArtifact() throws {
        let fixture = try makeFixture()
        _ = try publishAll(fixture)
        var reader = makeReader(fixture)
        reader.checkpoint = { point in
            guard point == .artifactsRead else { return }
            try Data("corrupt aggregate".utf8).write(to: fixture.aggregateURL)
        }

        let result = reader.readSource(
            chunkID: fixture.aggregate.source.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: configuration()
        )

        assertAllDeferred(result, reason: .evidenceChangedDuringRead)
        XCTAssertNil(result.verificationIdentity)
    }

    func testArtifactByteLimitFailsClosedBeforeDecode() throws {
        let fixture = try makeFixture()
        _ = try publishAll(fixture)
        var reader = makeReader(fixture)
        reader.limits = .init(maximumAggregateCount: 4,
                              maximumDependencyCount: 4,
                              maximumReceiptBytes: 64 * 1_024,
                              maximumArtifactBytes: 1)

        let result = reader.readSource(
            chunkID: fixture.aggregate.source.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: configuration()
        )

        assertAllDeferred(result, reason: .readerLimitExceeded)
    }

    func testAggregateByteLimitFailsClosedBeforeAggregateDecode() throws {
        let fixture = try makeFixture()
        _ = try publishAll(fixture)
        var reader = makeReader(fixture)
        reader.limits = .init(maximumAggregateCount: 4,
                              maximumDependencyCount: 4,
                              maximumReceiptBytes: 64 * 1_024,
                              maximumArtifactBytes: 16 * 1_024 * 1_024,
                              maximumAggregateBytes: 1,
                              maximumTotalAggregateBytes: 16 * 1_024 * 1_024)

        let result = reader.readSource(chunkID: fixture.aggregate.source.chunkID,
                                       catalogStore: fixture.catalogStore,
                                       configuration: configuration())

        assertAllDeferred(result, reason: .readerLimitExceeded)
    }

    func testTotalAggregateByteLimitFailsClosedBeforeAggregateDecode() throws {
        let fixture = try makeFixture()
        _ = try publishAll(fixture)
        var reader = makeReader(fixture)
        reader.limits = .init(maximumAggregateCount: 4,
                              maximumDependencyCount: 4,
                              maximumReceiptBytes: 64 * 1_024,
                              maximumArtifactBytes: 16 * 1_024 * 1_024,
                              maximumAggregateBytes: 16 * 1_024 * 1_024,
                              maximumTotalAggregateBytes: 1)

        let result = reader.readSource(chunkID: fixture.aggregate.source.chunkID,
                                       catalogStore: fixture.catalogStore,
                                       configuration: configuration())

        assertAllDeferred(result, reason: .readerLimitExceeded)
    }

    func testCrashPrefixCannotBecomeVisibleWithoutAtomicSetPointer() throws {
        enum Injected: Error { case crash }
        let fixture = try makeFixture()
        let crashingLedger = AtriaHistoricalConsumerReceiptLedger(
            directoryURL: fixture.receiptDirectory,
            checkpoint: {
                if $0 == .currentSetPointerTemporaryDurable { throw Injected.crash }
            }
        )

        XCTAssertThrowsError(try publishAll(fixture, ledger: crashingLedger))
        let result = makeReader(fixture).readSource(
            chunkID: fixture.aggregate.source.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: configuration()
        )

        XCTAssertEqual(result.activity, .missing(.receiptNotPublished))
        XCTAssertEqual(result.dailyMetrics, .missing(.receiptNotPublished))
        XCTAssertEqual(result.steps, .missing(.receiptNotPublished))
        XCTAssertEqual(result.sleep, .missing(.receiptNotPublished))
        XCTAssertEqual(result.workout, .missing(.receiptNotPublished))
        XCTAssertNil(result.verificationIdentity)
    }

    func testNewCompletionAndConfigurationRepublishAdvancesSetWithoutReceiptConflict() throws {
        let fixture = try makeFixture()
        let first = try publishAll(fixture)
        var updated = configuration()
        updated = .init(activity: .init(restingHeartRate: 60,
                                        maximumHeartRate: 190,
                                        timeZoneIdentifier: "UTC"),
                        daily: updated.daily,
                        sleep: updated.sleep,
                        workout: updated.workout)
        _ = try fixture.completionStore.recordTerminal(
            generation: 2,
            terminalBatchNumber: 3,
            durableSequence: 2,
            requestedStart: fixture.requestedStart,
            requestedEnd: fixture.requestedEnd,
            completedAt: fixture.requestedEnd,
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.aggregateReader.load()
        )

        let second = try publishAll(fixture, config: updated)
        let result = makeReader(fixture).readSource(
            chunkID: fixture.aggregate.source.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: updated
        )

        XCTAssertEqual(result.activity, .knownEmpty)
        let identity = try XCTUnwrap(result.verificationIdentity)
        XCTAssertEqual(identity.completionGeneration, 2)
        XCTAssertEqual(identity.receipts.map(\.configurationSHA256).sorted(),
                       second.map(\.receipt.configurationSHA256).sorted())
        XCTAssertEqual(first.count, 5)
        XCTAssertEqual(second.count, 5)
        XCTAssertTrue(zip(first, second).allSatisfy {
            $0.0.receiptURL != $0.1.receiptURL
        })
        let receiptFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.receiptDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("consumer-receipt-") }
        XCTAssertEqual(receiptFiles.count, 10, "old immutable generation must remain auditable")
    }

    private struct Fixture {
        let catalogStore: AtriaHistoricalArchiveCatalogStore
        let aggregateReader: AtriaHistoricalAggregateReader
        let aggregate: AtriaHistoricalAggregateChunk
        let aggregateURL: URL
        let completionStore: AtriaHistoricalDrainCompletionGenerationStore
        let ledger: AtriaHistoricalConsumerReceiptLedger
        let receiptDirectory: URL
        let rawURL: URL
        let requestedStart: Date
        let requestedEnd: Date
    }

    private func makeFixture() throws -> Fixture {
        let root = try temporaryRoot()
        var identifiers = ["sealed-source", "active-next"]
        let catalogStore = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            maximumActiveBytes: 1_024,
            calendar: utcCalendar(),
            makeIdentifier: { identifiers.removeFirst() }
        )
        _ = try catalogStore.loadOrRecover(discoveredLegacyURLs: [], now: start)
        let active = try catalogStore.activeChunkDescriptor()
        try FileManager.default.createDirectory(
            at: active.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let raw = Data("{\"row\":1}\n".utf8)
        try raw.write(to: active.fileURL)
        let digest = AtriaHistoricalRetentionTransaction.sha256(of: raw)
        let end = start.addingTimeInterval(3_600)
        try catalogStore.sealActiveChunkAtTerminal(
            chunkID: active.chunkID,
            rowCount: 1,
            firstTimestamp: start,
            lastTimestamp: end,
            contentSHA256: digest,
            now: end
        )
        let aggregate = AtriaHistoricalAggregateChunk(
            schema: AtriaHistoricalAggregateChunk.currentSchema,
            createdAt: end.addingTimeInterval(1),
            source: .init(chunkID: active.chunkID,
                          rawSHA256: digest,
                          rawByteCount: UInt64(raw.count),
                          rawRowCount: 1,
                          firstTimestamp: start,
                          lastTimestamp: end,
                          decoderSchema: HistoricalArchive.schema,
                          validatedLayouts: []),
            heartRateMinutes: [],
            rrEpochs: [],
            motionEpochs: [],
            materializedProjections: [],
            parity: .init(rawRows: 1,
                          decodedRows: 1,
                          undecodableRowsRetainedRaw: 0,
                          metricUsableRows: 0,
                          heartRateSamples: 0,
                          heartRateSumBPM: 0,
                          acceptedRRBeats: 0,
                          acceptedRRSumMilliseconds: 0,
                          validatedGravityRows: 0,
                          motionEpochs: 0,
                          projectionReceipts: 0)
        )
        let aggregates = root.appendingPathComponent("aggregates")
        let manifests = root.appendingPathComponent("manifests")
        let committed = try AtriaHistoricalRetentionTransaction(
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
        let aggregateReader = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        )
        let snapshot = aggregateReader.load()
        let completionStore = AtriaHistoricalDrainCompletionGenerationStore(
            directoryURL: root.appendingPathComponent("completions")
        )
        let requestedStart = start.addingTimeInterval(-48 * 60 * 60)
        let requestedEnd = end.addingTimeInterval(48 * 60 * 60)
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
        let receiptDirectory = root.appendingPathComponent("receipts")
        return .init(catalogStore: catalogStore,
                     aggregateReader: aggregateReader,
                     aggregate: aggregate,
                     aggregateURL: committed.aggregateURL,
                     completionStore: completionStore,
                     ledger: .init(directoryURL: receiptDirectory),
                     receiptDirectory: receiptDirectory,
                     rawURL: active.fileURL,
                     requestedStart: requestedStart,
                     requestedEnd: requestedEnd)
    }

    private func publishAll(
        _ fixture: Fixture,
        ledger: AtriaHistoricalConsumerReceiptLedger? = nil,
        config: AtriaHistoricalVerifiedConsumerReader.Configuration? = nil
    ) throws -> [AtriaHistoricalConsumerReceiptLedger.Published] {
        let config = config ?? configuration()
        let ledger = ledger ?? fixture.ledger
        let snapshot = fixture.aggregateReader.load()
        let range = try requiredRange(for: fixture.aggregate,
                                      dailyConfiguration: config.daily)
        let prepared = try AtriaHistoricalActivityInspectionProofFactory(
            completionStore: fixture.completionStore
        ).prepare(catalogStore: fixture.catalogStore,
                  aggregateSnapshot: snapshot,
                  requestedStart: range.lowerBound,
                  requestedEnd: range.upperBound)
        let dailyProof = try AtriaHistoricalDailyConsumerProjection.InspectionProof.make(
            generationIdentifier: prepared.generationIdentifier,
            catalogSnapshot: prepared.catalogSnapshot,
            dependencyChunks: prepared.dependencyChunks,
            closedCoverageIntervals: prepared.closedCoverageIntervals.map {
                .init(start: $0.start, end: $0.end, recordCount: $0.recordCount)
            }
        )
        let sessionProof = try AtriaHistoricalSessionInspectionProof.make(
            generationIdentifier: prepared.generationIdentifier,
            catalogSnapshot: prepared.catalogSnapshot,
            closedCoverageIntervals: prepared.closedCoverageIntervals.map {
                .init(start: $0.start, end: $0.end, recordCount: $0.recordCount)
            }
        )
        let settledAt = try fixture.completionStore.loadLatest().completedAt
        let published = [
            try AtriaHistoricalActivityProjection.publishReceipt(
                source: fixture.aggregate,
                dependencyChunks: prepared.dependencyChunks,
                configuration: config.activity,
                inspectionProof: prepared.inspectionProof,
                completionWatermark: prepared.completionWatermark,
                ledger: ledger,
                settledAt: settledAt
            ),
            try AtriaHistoricalDailyConsumerProjection.publishDailyMetricsReceipt(
                source: fixture.aggregate,
                dependencyChunks: prepared.dependencyChunks,
                configuration: config.daily,
                inspectionProof: dailyProof,
                completionWatermark: prepared.completionWatermark,
                ledger: ledger,
                settledAt: settledAt
            ),
            try AtriaHistoricalDailyConsumerProjection.publishStepsReceipt(
                source: fixture.aggregate,
                dependencyChunks: prepared.dependencyChunks,
                configuration: config.daily,
                inspectionProof: dailyProof,
                completionWatermark: prepared.completionWatermark,
                ledger: ledger,
                settledAt: settledAt
            ),
            try AtriaHistoricalSleepProjection.publishReceipt(
                source: fixture.aggregate,
                dependencyChunks: prepared.dependencyChunks,
                configuration: config.sleep,
                inspectionProof: sessionProof,
                completionWatermark: prepared.completionWatermark,
                ledger: ledger,
                settledAt: settledAt
            ),
            try AtriaHistoricalWorkoutProjection.publishReceipt(
                source: fixture.aggregate,
                dependencyChunks: prepared.dependencyChunks,
                configuration: config.workout,
                inspectionProof: sessionProof,
                completionWatermark: prepared.completionWatermark,
                ledger: ledger,
                settledAt: settledAt
            ),
        ]
        let ledgerSource = AtriaHistoricalConsumerReceiptLedger.Source(
            chunkID: fixture.aggregate.source.chunkID,
            rawSHA256: fixture.aggregate.source.rawSHA256,
            firstTimestamp: fixture.aggregate.source.firstTimestamp,
            lastTimestamp: fixture.aggregate.source.lastTimestamp
        )
        try ledger.activateCurrentSet(for: ledgerSource, publications: published)
        return published
    }

    private func makeReader(_ fixture: Fixture) -> AtriaHistoricalVerifiedConsumerReader {
        .init(aggregateReader: fixture.aggregateReader,
              completionStore: fixture.completionStore,
              receiptLedger: fixture.ledger)
    }

    private func configuration() -> AtriaHistoricalVerifiedConsumerReader.Configuration {
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

    private func requiredRange(
        for source: AtriaHistoricalAggregateChunk,
        dailyConfiguration: AtriaHistoricalDailyConsumerProjection.Configuration
    ) throws -> ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: dailyConfiguration.timeZoneIdentifier))
        let dailyStart = calendar.startOfDay(for: source.source.firstTimestamp)
        let lastDay = calendar.startOfDay(for: source.source.lastTimestamp)
        let dailyEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: lastDay))
        let history = max(AtriaHistoricalActivityProjection.requiredHistory,
                          AtriaHistoricalSleepProjection.requiredHistory,
                          AtriaHistoricalWorkoutProjection.requiredHistory)
        let lookahead = max(AtriaHistoricalActivityProjection.requiredLookahead,
                            AtriaHistoricalSleepProjection.requiredLookahead,
                            AtriaHistoricalWorkoutProjection.requiredLookahead)
        let start = min(dailyStart, source.source.firstTimestamp.addingTimeInterval(-history))
        let end = max(dailyEnd, source.source.lastTimestamp.addingTimeInterval(lookahead))
        return start...end
    }

    private func assertAllDeferred(
        _ result: AtriaHistoricalVerifiedConsumerReader.SourceArtifacts,
        reason: AtriaHistoricalVerifiedConsumerReader.DeferredReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.activity, .deferred(reason), file: file, line: line)
        XCTAssertEqual(result.dailyMetrics, .deferred(reason), file: file, line: line)
        XCTAssertEqual(result.steps, .deferred(reason), file: file, line: line)
        XCTAssertEqual(result.sleep, .deferred(reason), file: file, line: line)
        XCTAssertEqual(result.workout, .deferred(reason), file: file, line: line)
        XCTAssertFalse(result.hasConsumableValue, file: file, line: line)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalVerifiedConsumerReaderTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
}
