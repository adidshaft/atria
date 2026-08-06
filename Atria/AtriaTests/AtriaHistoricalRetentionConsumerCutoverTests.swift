import XCTest
@testable import Atria

final class AtriaHistoricalRetentionConsumerCutoverTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_002_500_000)
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testMatchingProductionConfigurationPublishesSixWhileAppCurrentSetRemainsFiveAndRawIsRetained()
        throws {
        let fixture = try makeFixture(completion: .complete)
        let catalogBefore = try fixture.catalogStore.snapshot()
        let aggregateReader = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: fixture.root.appendingPathComponent("aggregates-v2"),
            manifestDirectoryURL: fixture.root.appendingPathComponent("retention-manifests-v2")
        )
        let aggregatesBefore = aggregateReader.load().aggregates
        let manifestURL = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            at: fixture.root.appendingPathComponent("retention-manifests-v2"),
            includingPropertiesForKeys: nil
        ).first)
        let manifestBefore = try Data(contentsOf: manifestURL)

        let result = try cutover(fixture)

        XCTAssertEqual(result.chunkID, fixture.chunkID)
        XCTAssertEqual(result.completionGeneration, 1)
        XCTAssertEqual(result.receiptCount, 6)
        XCTAssertEqual(Set(result.receiptKinds), expectedKinds)
        XCTAssertEqual(result.reusedReceiptCount, 0)
        XCTAssertEqual(result.canonicalApplicationCount, 5)
        XCTAssertEqual(result.canonicalApplicationIdentitySHA256.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root
            .appendingPathComponent("canonical-consumers-v1")
            .appendingPathComponent("application-proofs").path))
        let canonicalSources = HistoricalArchive.readVerifiedCanonicalConsumerSources(
            archiveRoot: fixture.root,
            maximumSourceCount: 8
        )
        let canonical = try XCTUnwrap(canonicalSources.first)
        XCTAssertEqual(canonicalSources.count, 1)
        XCTAssertEqual(canonical.identity.source.chunkID, fixture.chunkID)
        XCTAssertEqual(canonical.replayIdentity.entries.count, 2)
        XCTAssertEqual(canonical.activity.source.chunkID, fixture.chunkID)
        XCTAssertEqual(canonical.dailyMetrics.source.chunkID, fixture.chunkID)
        XCTAssertEqual(canonical.steps.source.chunkID, fixture.chunkID)
        XCTAssertEqual(canonical.sleep.source.chunkID, fixture.chunkID)
        XCTAssertEqual(canonical.workout.source.chunkID, fixture.chunkID)
        let currentSet = try receiptLedger(fixture).validatedCurrentSet(
            for: ledgerSource(fixture)
        )
        XCTAssertEqual(currentSet.count, 5)
        XCTAssertNil(currentSet[.replayIdentity])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        XCTAssertEqual(result.rawSourceURL.standardizedFileURL,
                       fixture.rawURL.standardizedFileURL)
        XCTAssertEqual(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        }?.state, .sealed, "consumer cutover must not mint retirement authority")
        XCTAssertEqual(try fixture.catalogStore.snapshot(), catalogBefore)
        XCTAssertEqual(aggregateReader.load().aggregates, aggregatesBefore)
        XCTAssertTrue(try XCTUnwrap(aggregateReader.load().aggregates.first)
            .materializedProjections.isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
    }

    /// Drives a *compressed* sealed chunk end-to-end through consumer cutover.
    /// The retained-source verification now compares decoded identity, so a
    /// chunk whose physical bytes are DEFLATE must still publish all six
    /// receipts and keep both the original source and the compressed artifact.
    func testCompressedSealedChunkPublishesSixReceiptsAndRetainsBothSourceAndArtifact()
        throws {
        // Build the chunk + committed aggregate WITHOUT a terminal completion
        // yet: the completion attests the catalog snapshot, so it must be
        // recorded after compression mutates the catalog (relativePath →
        // artifact, generation bump), otherwise the attestation fails closed.
        let fixture = try makeFixture(completion: .missing)
        let originalSource = fixture.rawURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalSource.path))

        // Substitute the sealed chunk's physical storage with a compressed
        // artifact. A modest chunkSize (97) exercises the multi-block streaming
        // inflate path while staying in the codec's covered range.
        let activeNext = try fixture.catalogStore.activeChunkDescriptor()
        let compressed = try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: fixture.chunkID,
            sourceURL: originalSource,
            archiveRootURL: fixture.root,
            activeSourceURL: activeNext.fileURL,
            chunkSize: 97
        )
        try fixture.catalogStore.recordCompressedStorage(
            chunkID: fixture.chunkID,
            manifestURL: compressed.manifestURL,
            artifactURL: compressed.artifactURL
        )
        // The catalog now resolves the chunk to the DEFLATE artifact.
        let resolved = try fixture.catalogStore.resolvedFileURL(forChunkID: fixture.chunkID)
        XCTAssertEqual(resolved.pathExtension,
                       AtriaHistoricalSealedJSONLCompression.artifactExtension)

        // Attest the terminal completion against the post-compression catalog.
        try advanceCompletion(fixture, generation: 1, completedAtOffset: 0)

        let result = try cutover(fixture)

        XCTAssertEqual(result.chunkID, fixture.chunkID)
        XCTAssertEqual(result.receiptCount, 6)
        XCTAssertEqual(Set(result.receiptKinds), expectedKinds)
        XCTAssertEqual(result.canonicalApplicationCount, 5)
        // Crash-safe coexistence: neither the original source nor the artifact
        // may be removed by a cutover (which never mints retirement authority).
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalSource.path),
                      "consumer cutover must retain the original source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressed.artifactURL.path),
                      "consumer cutover must retain the compressed artifact")
        XCTAssertEqual(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        }?.state, .sealed)
        let currentSet = try receiptLedger(fixture).validatedCurrentSet(
            for: ledgerSource(fixture)
        )
        XCTAssertEqual(currentSet.count, 5)
        XCTAssertNil(currentSet[.replayIdentity])
    }

    func testCutoverIsIdempotentAndReusesAllSixReceiptsWithoutDeletingRaw() throws {
        let fixture = try makeFixture(completion: .complete)
        let first = try cutover(fixture)
        let second = try cutover(fixture)

        XCTAssertEqual(first.receiptKinds, second.receiptKinds)
        XCTAssertEqual(second.receiptCount, 6)
        XCTAssertEqual(second.reusedReceiptCount, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
    }

    func testLaterCompletionGenerationSelectsItsExactReplayReceiptAndRetainsRaw() throws {
        let fixture = try makeFixture(completion: .complete)
        _ = try cutover(fixture)
        try advanceCompletion(fixture, generation: 2, completedAtOffset: 60)

        let result = try cutover(fixture)

        XCTAssertEqual(result.completionGeneration, 2)
        XCTAssertEqual(result.receiptCount, 6)
        XCTAssertEqual(Set(result.receiptKinds), expectedKinds)
        XCTAssertEqual(result.reusedReceiptCount, 0)
        let replayReceipts = try FileManager.default.contentsOfDirectory(
            at: fixture.root.appendingPathComponent("consumer-receipts-v1"),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("consumer-receipt-replayIdentity-") }
        XCTAssertEqual(replayReceipts.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
    }

    func testCrashAfterReceiptPrefixNeverExposesPartialSetAndRetryCompletes() throws {
        enum Injected: Error { case crash }
        let fixture = try makeFixture(completion: .complete)
        var durableReceipts = 0
        let receiptDirectory = fixture.root.appendingPathComponent("consumer-receipts-v1")
        let crashingLedger = AtriaHistoricalConsumerReceiptLedger(
            directoryURL: receiptDirectory,
            checkpoint: { checkpoint in
                guard checkpoint == .receiptPublished else { return }
                durableReceipts += 1
                if durableReceipts == 2 { throw Injected.crash }
            }
        )

        XCTAssertThrowsError(try HistoricalArchive.publishAndVerifyHistoricalConsumerCutover(
            chunkID: fixture.chunkID,
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore,
            configuration: configuration,
            receiptLedger: crashingLedger
        ))

        let beforeRetry = makeReader(fixture).readSource(
            chunkID: fixture.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: configuration
        )
        XCTAssertNil(beforeRetry.verificationIdentity)
        XCTAssertFalse(beforeRetry.hasCompleteConsumerCoverage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))

        let retry = try cutover(fixture)
        XCTAssertEqual(retry.receiptCount, 6)
        XCTAssertGreaterThanOrEqual(retry.reusedReceiptCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
    }

    func testCrashAfterReplayReceiptPublicationRetriesByReusingAllSixAndRetainsRaw() throws {
        enum Injected: Error { case crash }
        let fixture = try makeFixture(completion: .complete)
        var durableReceipts = 0
        let crashingLedger = AtriaHistoricalConsumerReceiptLedger(
            directoryURL: fixture.root.appendingPathComponent("consumer-receipts-v1"),
            checkpoint: { checkpoint in
                guard checkpoint == .receiptPublished else { return }
                durableReceipts += 1
                if durableReceipts == 6 { throw Injected.crash }
            }
        )

        XCTAssertThrowsError(try HistoricalArchive.publishAndVerifyHistoricalConsumerCutover(
            chunkID: fixture.chunkID,
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore,
            configuration: configuration,
            receiptLedger: crashingLedger
        ))
        XCTAssertEqual(durableReceipts, 6)
        let currentSet = try receiptLedger(fixture).validatedCurrentSet(
            for: ledgerSource(fixture)
        )
        XCTAssertEqual(currentSet.count, 5)
        XCTAssertNil(currentSet[.replayIdentity])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))

        let retry = try cutover(fixture)
        XCTAssertEqual(retry.receiptCount, 6)
        XCTAssertEqual(retry.reusedReceiptCount, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
    }

    func testCompletionAdvanceDuringReplayPublicationFailsFinalAuditAndRetainsRaw() throws {
        let fixture = try makeFixture(completion: .complete)
        var durableReceipts = 0
        let racingLedger = AtriaHistoricalConsumerReceiptLedger(
            directoryURL: fixture.root.appendingPathComponent("consumer-receipts-v1"),
            checkpoint: { checkpoint in
                guard checkpoint == .receiptPublished else { return }
                durableReceipts += 1
                if durableReceipts == 6 {
                    try self.advanceCompletion(fixture,
                                               generation: 2,
                                               completedAtOffset: 60)
                }
            }
        )

        XCTAssertThrowsError(try HistoricalArchive.publishAndVerifyHistoricalConsumerCutover(
            chunkID: fixture.chunkID,
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore,
            configuration: configuration,
            receiptLedger: racingLedger
        )) { error in
            XCTAssertEqual(error as? HistoricalArchive.HistoricalConsumerCutoverError,
                           .terminalCompletionAttestationRejected)
        }
        XCTAssertEqual(durableReceipts, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        XCTAssertEqual(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        }?.state, .sealed)
    }

    func testCurrentSetAdvanceDuringReplayPublicationFailsFinalAuditAndRetainsRaw() throws {
        let fixture = try makeFixture(completion: .complete)
        var durableReceipts = 0
        let racingLedger = AtriaHistoricalConsumerReceiptLedger(
            directoryURL: fixture.root.appendingPathComponent("consumer-receipts-v1"),
            checkpoint: { checkpoint in
                guard checkpoint == .receiptPublished else { return }
                durableReceipts += 1
                if durableReceipts == 6 {
                    try self.publishAppSet(
                        fixture,
                        configuration: .production(restingHeartRate: 56,
                                                   maximumHeartRate: 190,
                                                   timeZoneIdentifier: "UTC")
                    )
                }
            }
        )

        XCTAssertThrowsError(try HistoricalArchive.publishAndVerifyHistoricalConsumerCutover(
            chunkID: fixture.chunkID,
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore,
            configuration: configuration,
            receiptLedger: racingLedger
        )) { error in
            XCTAssertEqual(error as? HistoricalArchive.HistoricalConsumerCutoverError,
                           .typedVerificationIncomplete)
        }
        XCTAssertEqual(durableReceipts, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        XCTAssertEqual(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        }?.state, .sealed)
    }

    func testTamperedReplayArtifactFailsClosedAndRetainsRaw() throws {
        let fixture = try makeFixture(completion: .complete)
        _ = try cutover(fixture)
        let receiptDirectory = fixture.root.appendingPathComponent("consumer-receipts-v1")
        let replayArtifact = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: receiptDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("consumer-artifact-replayIdentity-") }
        )
        var bytes = try Data(contentsOf: replayArtifact)
        bytes[bytes.startIndex] ^= 0xff
        try bytes.write(to: replayArtifact)

        XCTAssertThrowsError(try cutover(fixture))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        XCTAssertEqual(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        }?.state, .sealed)
    }

    func testTamperedCanonicalDestinationIsWithheldFromSessionStoreReadPath() throws {
        let fixture = try makeFixture(completion: .complete)
        _ = try cutover(fixture)
        let destinationDirectory = fixture.root
            .appendingPathComponent("canonical-consumers-v1")
            .appendingPathComponent("destinations")
        let sleepSnapshot = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: destinationDirectory,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasPrefix("canonical-sleep-")
                    && !$0.lastPathComponent.contains("-current-")
            }
        )
        var bytes = try Data(contentsOf: sleepSnapshot)
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: sleepSnapshot)

        XCTAssertTrue(HistoricalArchive.readVerifiedCanonicalConsumerSources(
            archiveRoot: fixture.root,
            maximumSourceCount: 8
        ).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
    }

    func testRawRowMissingDurableReplayIdentityFailsClosedAndRetainsRaw() throws {
        let fixture = try makeFixture(completion: .complete,
                                      decorateReplayIdentities: false)

        XCTAssertThrowsError(try cutover(fixture)) { error in
            XCTAssertEqual(error as? AtriaHistoricalReplayIdentityShard.ShardError,
                           .missingExactIdentity(row: 0))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        XCTAssertEqual(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        }?.state, .sealed)
    }

    func testCatalogAggregateSourceMetadataMismatchFailsBeforePublicationAndRetainsRaw() throws {
        let fixture = try makeFixture(completion: .missing,
                                      committedAggregateRawRowCount: 3)

        XCTAssertThrowsError(try cutover(fixture)) { error in
            XCTAssertEqual(error as? HistoricalArchive.HistoricalConsumerCutoverError,
                           .rawSourceUnavailable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root
            .appendingPathComponent("consumer-receipts-v1").path))
        XCTAssertEqual(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        }?.state, .sealed)
    }

    func testMissingTerminalCompletionFailsClosedAndRetainsRaw() throws {
        let fixture = try makeFixture(completion: .missing)

        XCTAssertThrowsError(try cutover(fixture)) { error in
            XCTAssertEqual(error as? HistoricalArchive.HistoricalConsumerCutoverError,
                           .terminalCompletionAttestationUnavailable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root
            .appendingPathComponent("drain-completions-v1")
            .appendingPathComponent("history-drain-completion.latest.json").path),
            "maintenance must never synthesize terminal completion authority")
    }

    func testNarrowTerminalCompletionFailsClosedAndRetainsRaw() throws {
        let fixture = try makeFixture(completion: .narrow)

        XCTAssertThrowsError(try cutover(fixture))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        XCTAssertFalse(makeReader(fixture).readSource(
            chunkID: fixture.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: configuration
        ).hasCompleteConsumerCoverage)
    }

    func testStaleTerminalCompletionFailsClosedAndRetainsRaw() throws {
        let fixture = try makeFixture(completion: .complete)
        let active = try fixture.catalogStore.activeChunkDescriptor()
        try Data("post-attestation-row\n".utf8).write(to: active.fileURL)

        XCTAssertThrowsError(try cutover(fixture))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        XCTAssertFalse(makeReader(fixture).readSource(
            chunkID: fixture.chunkID,
            catalogStore: fixture.catalogStore,
            configuration: configuration
        ).hasCompleteConsumerCoverage)
    }

    func testVerifiedCutoverRetiresOneExactRawChunkAndCatalog() throws {
        let fixture = try makeFixture(completion: .complete)
        _ = try cutover(fixture)

        let result = try AtriaHistoricalRawRetirementExecutor(
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore
        ).retire(chunkID: fixture.chunkID)

        XCTAssertEqual(result.chunkID, fixture.chunkID)
        XCTAssertTrue(result.sourceDeleted)
        XCTAssertTrue(result.catalogRetired)
        XCTAssertFalse(result.recoveredPendingIntent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        let retired = try XCTUnwrap(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        })
        XCTAssertEqual(retired.state, .retired)
        XCTAssertNotNil(retired.retirementManifestRelativePath)
        XCTAssertNoThrow(try fixture.catalogStore.snapshotVerifiedAgainstFiles())
    }

    func testReplayPayloadCompactionPreservesEveryTypedHistoricalViewAndIsIdempotent() throws {
        let fixture = try makeFixture(completion: .complete)
        _ = try cutover(fixture)
        _ = try AtriaHistoricalRawRetirementExecutor(
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore
        ).retire(chunkID: fixture.chunkID)
        let before = try XCTUnwrap(HistoricalArchive.readVerifiedCanonicalConsumerSources(
            archiveRoot: fixture.root, maximumSourceCount: 8
        ).first)

        let first = try AtriaHistoricalReplayPayloadCompactor(
            archiveRoot: fixture.root
        ).compactRetiredSource(chunkID: fixture.chunkID, now: start.addingTimeInterval(4_000))

        XCTAssertGreaterThan(first.retiredBytes, 0)
        let after = try XCTUnwrap(HistoricalArchive.readVerifiedCanonicalConsumerSources(
            archiveRoot: fixture.root, maximumSourceCount: 8
        ).first)
        XCTAssertEqual(after.activity, before.activity)
        XCTAssertEqual(after.dailyMetrics, before.dailyMetrics)
        XCTAssertEqual(after.steps, before.steps)
        XCTAssertEqual(after.sleep, before.sleep)
        XCTAssertEqual(after.workout, before.workout)
        XCTAssertTrue(after.replayPayloadRetired)
        XCTAssertEqual(after.identity.replayReceipt.recordCount,
                       before.replayIdentity.entries.count)

        let second = try AtriaHistoricalReplayPayloadCompactor(
            archiveRoot: fixture.root
        ).compactRetiredSource(chunkID: fixture.chunkID, now: start.addingTimeInterval(5_000))
        XCTAssertEqual(second.retiredBytes, 0)
        XCTAssertEqual(second.proof, first.proof)
        let replayStaging = try FileManager.default.contentsOfDirectory(
            at: fixture.root.appendingPathComponent("consumer-receipts-v1"),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("consumer-artifact-replayIdentity-") }
        XCTAssertTrue(replayStaging.isEmpty)
        let replayDestinations = try FileManager.default.contentsOfDirectory(
            at: fixture.root.appendingPathComponent("canonical-consumers-v1/destinations"),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("canonical-replayIdentity-") }
        XCTAssertTrue(replayDestinations.isEmpty)
    }

    func testCorruptCompactReplayProofFailsClosedAfterPayloadRetirement() throws {
        let fixture = try makeFixture(completion: .complete)
        _ = try cutover(fixture)
        _ = try AtriaHistoricalRawRetirementExecutor(
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore
        ).retire(chunkID: fixture.chunkID)
        _ = try AtriaHistoricalReplayPayloadCompactor(
            archiveRoot: fixture.root
        ).compactRetiredSource(chunkID: fixture.chunkID, now: start.addingTimeInterval(4_000))
        let proof = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: fixture.root.appendingPathComponent("replay-compaction-v1"),
            includingPropertiesForKeys: nil
        ).first)
        try Data("corrupt".utf8).write(to: proof, options: .atomic)

        XCTAssertTrue(HistoricalArchive.readVerifiedCanonicalConsumerSources(
            archiveRoot: fixture.root, maximumSourceCount: 8
        ).isEmpty)
    }

    func testReplayCompactionRestartsAcrossEveryPublicationAndDeletionSeam() throws {
        enum Injected: Error { case crash }
        enum Seam: CaseIterable {
            case proofTemporary
            case proofPublished
            case proofVerified
            case canonicalRetired
            case stagingRetired
        }
        for seam in Seam.allCases {
            let fixture = try makeFixture(completion: .complete)
            _ = try cutover(fixture)
            _ = try AtriaHistoricalRawRetirementExecutor(
                archiveRoot: fixture.root,
                catalogStore: fixture.catalogStore
            ).retire(chunkID: fixture.chunkID)
            var faulting = AtriaHistoricalReplayPayloadCompactor(archiveRoot: fixture.root)
            faulting.proofCheckpoint = { point in
                if seam == .proofTemporary && point == .proofTemporaryDurable { throw Injected.crash }
                if seam == .proofPublished && point == .proofPublished { throw Injected.crash }
            }
            faulting.checkpoint = { point in
                if seam == .proofVerified && point == .proofVerified { throw Injected.crash }
                if seam == .canonicalRetired && point == .canonicalReplayRetired { throw Injected.crash }
                if seam == .stagingRetired && point == .stagingReplayRetired { throw Injected.crash }
            }
            XCTAssertThrowsError(try faulting.compactRetiredSource(
                chunkID: fixture.chunkID, now: start.addingTimeInterval(4_000)
            ), "seam \(seam) must interrupt this attempt")

            let recovered = try AtriaHistoricalReplayPayloadCompactor(
                archiveRoot: fixture.root
            ).compactRetiredSource(chunkID: fixture.chunkID,
                                   now: start.addingTimeInterval(5_000))
            XCTAssertEqual(recovered.chunkID, fixture.chunkID)
            let source = try XCTUnwrap(HistoricalArchive.readVerifiedCanonicalConsumerSources(
                archiveRoot: fixture.root, maximumSourceCount: 8
            ).first)
            XCTAssertTrue(source.replayPayloadRetired)
            XCTAssertEqual(source.activity.source.chunkID, fixture.chunkID)
            XCTAssertEqual(source.sleep.source.chunkID, fixture.chunkID)
            XCTAssertEqual(source.workout.source.chunkID, fixture.chunkID)
        }
    }

    func testExpiredIndexTombstoneStillServesTypedHistoryFromDurableCompactProof() throws {
        let fixture = try makeFixture(completion: .complete)
        _ = try cutover(fixture)
        _ = try AtriaHistoricalRawRetirementExecutor(
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore
        ).retire(chunkID: fixture.chunkID)
        _ = try AtriaHistoricalReplayPayloadCompactor(
            archiveRoot: fixture.root
        ).compactRetiredSource(chunkID: fixture.chunkID,
                               now: Date().addingTimeInterval(-100 * 86_400))
        let index = try AtriaHistoricalRetiredReplayIndex(
            databaseURL: fixture.root.appendingPathComponent(
                "retired-replay-v1/exact-identities-v3.sqlite"
            ),
            unsafeDisableDurabilityForTests: true
        )
        let maintenance = try index.maintainStorage(
            identityCutoff: start.addingTimeInterval(200 * 86_400),
            sourceTombstoneCutoff: Date().addingTimeInterval(86_400),
            sourceTombstoneRetirementAuthorizedChunkIDs: [fixture.chunkID]
        )
        XCTAssertEqual(maintenance.remainingExactIdentities, 0)
        XCTAssertEqual(maintenance.remainingSourceTombstones, 0)

        let source = try XCTUnwrap(HistoricalArchive.readVerifiedCanonicalConsumerSources(
            archiveRoot: fixture.root, maximumSourceCount: 8
        ).first)
        XCTAssertTrue(source.replayPayloadRetired)
        XCTAssertEqual(source.activity.source.chunkID, fixture.chunkID)
        XCTAssertEqual(source.dailyMetrics.source.chunkID, fixture.chunkID)
        XCTAssertEqual(source.steps.source.chunkID, fixture.chunkID)
        XCTAssertEqual(source.sleep.source.chunkID, fixture.chunkID)
        XCTAssertEqual(source.workout.source.chunkID, fixture.chunkID)
    }

    func testRetirementWithoutCanonicalCutoverFailsClosed() throws {
        let fixture = try makeFixture(completion: .complete)

        XCTAssertThrowsError(try AtriaHistoricalRawRetirementExecutor(
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore
        ).retire(chunkID: fixture.chunkID))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        XCTAssertEqual(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        }?.state, .sealed)
    }

    func testCrashAfterUnlinkRecoversCatalogAndReplayIndexFromDurableIntent() throws {
        enum Injected: Error { case stop }
        let fixture = try makeFixture(completion: .complete)
        _ = try cutover(fixture)
        var interrupted = AtriaHistoricalRawRetirementExecutor(
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore
        )
        interrupted.checkpoint = { point in
            if point == .sourceDeleted { throw Injected.stop }
        }

        XCTAssertThrowsError(try interrupted.retire(chunkID: fixture.chunkID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rawURL.path))
        XCTAssertEqual(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        }?.state, .sealed)

        let recovered = try XCTUnwrap(try AtriaHistoricalRawRetirementExecutor(
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore
        ).recoverFirstPendingIntent())
        XCTAssertTrue(recovered.recoveredPendingIntent)
        XCTAssertTrue(recovered.catalogRetired)
        XCTAssertEqual(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        }?.state, .retired)
        XCTAssertNoThrow(try fixture.catalogStore.snapshotVerifiedAgainstFiles())
        let intentDirectory = fixture.root.appendingPathComponent("retirement-intents-v1")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(
            at: intentDirectory,
            includingPropertiesForKeys: nil
        )).isEmpty)
    }

    private enum CompletionMode: Equatable {
        case complete
        case narrow
        case missing
    }

    private struct Fixture {
        let root: URL
        let catalogStore: AtriaHistoricalArchiveCatalogStore
        let chunkID: String
        let rawURL: URL
    }

    private var configuration: AtriaHistoricalConsumerProjectionConfiguration {
        .production(restingHeartRate: 55,
                    maximumHeartRate: 190,
                    timeZoneIdentifier: "UTC")
    }

    private var expectedKinds: Set<AtriaHistoricalConsumerReceiptLedger.ProjectionKind> {
        [.activity, .dailyMetrics, .steps, .sleep, .workout, .replayIdentity]
    }

    private func cutover(
        _ fixture: Fixture
    ) throws -> HistoricalArchive.HistoricalConsumerCutoverResult {
        try HistoricalArchive.publishAndVerifyHistoricalConsumerCutover(
            chunkID: fixture.chunkID,
            archiveRoot: fixture.root,
            catalogStore: fixture.catalogStore,
            configuration: configuration
        )
    }

    private func makeReader(_ fixture: Fixture) -> AtriaHistoricalVerifiedConsumerReader {
        .init(
            aggregateReader: .init(
                aggregateDirectoryURL: fixture.root.appendingPathComponent("aggregates-v2"),
                manifestDirectoryURL: fixture.root.appendingPathComponent(
                    "retention-manifests-v2"
                )
            ),
            completionStore: .init(directoryURL: fixture.root.appendingPathComponent(
                "drain-completions-v1"
            )),
            receiptLedger: .init(directoryURL: fixture.root.appendingPathComponent(
                "consumer-receipts-v1"
            ))
        )
    }

    private func receiptLedger(
        _ fixture: Fixture
    ) -> AtriaHistoricalConsumerReceiptLedger {
        .init(directoryURL: fixture.root.appendingPathComponent("consumer-receipts-v1"))
    }

    private func ledgerSource(
        _ fixture: Fixture
    ) throws -> AtriaHistoricalConsumerReceiptLedger.Source {
        let chunk = try XCTUnwrap(try fixture.catalogStore.snapshot().chunks.first {
            $0.id == fixture.chunkID
        })
        return .init(chunkID: chunk.id,
                     rawSHA256: try XCTUnwrap(chunk.contentSHA256),
                     firstTimestamp: try XCTUnwrap(chunk.firstTimestamp),
                     lastTimestamp: try XCTUnwrap(chunk.lastTimestamp))
    }

    private func advanceCompletion(
        _ fixture: Fixture,
        generation: UInt64,
        completedAtOffset: TimeInterval
    ) throws {
        let snapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: fixture.root.appendingPathComponent("aggregates-v2"),
            manifestDirectoryURL: fixture.root.appendingPathComponent("retention-manifests-v2")
        ).load()
        let requestedEnd = start.addingTimeInterval(49 * 60 * 60)
        _ = try AtriaHistoricalDrainCompletionGenerationStore(
            directoryURL: fixture.root.appendingPathComponent("drain-completions-v1")
        ).recordTerminal(
            generation: generation,
            terminalBatchNumber: generation + 1,
            durableSequence: generation,
            requestedStart: start.addingTimeInterval(-48 * 60 * 60),
            requestedEnd: requestedEnd,
            completedAt: requestedEnd.addingTimeInterval(completedAtOffset),
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: snapshot
        )
    }

    private func publishAppSet(
        _ fixture: Fixture,
        configuration: AtriaHistoricalConsumerProjectionConfiguration
    ) throws {
        let snapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: fixture.root.appendingPathComponent("aggregates-v2"),
            manifestDirectoryURL: fixture.root.appendingPathComponent("retention-manifests-v2")
        ).load()
        let report = try AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: .init(directoryURL: fixture.root.appendingPathComponent(
                "drain-completions-v1"
            )),
            receiptLedger: receiptLedger(fixture)
        ).publishReceiptSet(
            for: fixture.chunkID,
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: snapshot,
            configuration: configuration
        )
        XCTAssertTrue(report.deferredSources.isEmpty)
        XCTAssertEqual(report.published.count, 5)
    }

    private func makeFixture(
        completion mode: CompletionMode,
        decorateReplayIdentities: Bool = true,
        committedAggregateRawRowCount: Int? = nil
    ) throws -> Fixture {
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
        let end = start.addingTimeInterval(3_600)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if decorateReplayIdentities {
            let durableStore = try AtriaHistoricalArchiveDurableStore(
                indexURL: root.appendingPathComponent("historical-identity-v2.jsonl"),
                existingArchiveURLs: [],
                identityRetention: .infinity,
                now: { end }
            )
            let batch = durableStore.beginDrainBatch()
            for (offset, date) in [start, end].enumerated() {
                let unix = UInt32(date.timeIntervalSince1970)
                _ = try durableStore.append(
                    identity: .init(
                        strapIdentifier: "cutover-fixture-strap",
                        protocolVersion: 24,
                        counter: UInt32(offset + 1),
                        unixSeconds: unix,
                        subsecond: UInt16(offset),
                        payload: Data([0x00])
                    ),
                    encodedJSONObject: try encoder.encode(historicalRecord(at: date)),
                    to: active.fileURL,
                    batch: batch
                )
            }
            _ = try durableStore.flush(batch)
        } else {
            var raw = Data()
            for date in [start, end] {
                raw.append(try encoder.encode(historicalRecord(at: date)))
                raw.append(0x0A)
            }
            try raw.write(to: active.fileURL)
        }
        let digest = try AtriaHistoricalRetentionTransaction.sha256(of: active.fileURL)
        try catalogStore.sealActiveChunkAtTerminal(
            chunkID: active.chunkID,
            rowCount: 2,
            firstTimestamp: start,
            lastTimestamp: end,
            contentSHA256: digest,
            now: end
        )

        let build = try AtriaHistoricalAggregateBuilder.build(
            sourceURL: active.fileURL,
            chunkID: active.chunkID,
            createdAt: end.addingTimeInterval(1)
        )
        let aggregate = committedAggregateRawRowCount.map {
            replacingRawRowCount(build.aggregate, with: $0)
        } ?? build.aggregate
        let parityReceipt = AtriaHistoricalAggregateBuilder.semanticParityReceipt(
            for: aggregate
        )
        let aggregateDirectory = root.appendingPathComponent("aggregates-v2")
        let manifestDirectory = root.appendingPathComponent("retention-manifests-v2")
        _ = try AtriaHistoricalRetentionTransaction(
            now: { end.addingTimeInterval(2) },
            semanticVerifier: committedAggregateRawRowCount == nil
                ? AtriaHistoricalAggregateBuilder.verify
                : { _, candidate, receipt in
                    receipt == AtriaHistoricalAggregateBuilder.semanticParityReceipt(
                        for: candidate
                    )
                }
        ).commit(.init(
            transactionID: active.chunkID,
            sourceURL: active.fileURL,
            aggregateDirectoryURL: aggregateDirectory,
            manifestDirectoryURL: manifestDirectory,
            aggregate: aggregate,
            semanticParityReceipt: parityReceipt,
            deleteSourceAfterCommit: false
        ))

        if mode != .missing {
            let snapshot = AtriaHistoricalAggregateReader(
                aggregateDirectoryURL: aggregateDirectory,
                manifestDirectoryURL: manifestDirectory
            ).load()
            let requestedStart = mode == .narrow
                ? start.addingTimeInterval(10 * 60)
                : start.addingTimeInterval(-48 * 60 * 60)
            let requestedEnd = mode == .narrow
                ? end.addingTimeInterval(-10 * 60)
                : end.addingTimeInterval(48 * 60 * 60)
            _ = try AtriaHistoricalDrainCompletionGenerationStore(
                directoryURL: root.appendingPathComponent("drain-completions-v1")
            ).recordTerminal(
                generation: 1,
                terminalBatchNumber: 2,
                durableSequence: 1,
                requestedStart: requestedStart,
                requestedEnd: requestedEnd,
                completedAt: requestedEnd,
                catalogStore: catalogStore,
                aggregateSnapshot: snapshot
            )
        }
        return .init(root: root,
                     catalogStore: catalogStore,
                     chunkID: active.chunkID,
                     rawURL: active.fileURL)
    }

    private func replacingRawRowCount(
        _ aggregate: AtriaHistoricalAggregateChunk,
        with rowCount: Int
    ) -> AtriaHistoricalAggregateChunk {
        let source = AtriaHistoricalAggregateChunk.Source(
            chunkID: aggregate.source.chunkID,
            rawSHA256: aggregate.source.rawSHA256,
            rawByteCount: aggregate.source.rawByteCount,
            rawRowCount: rowCount,
            firstTimestamp: aggregate.source.firstTimestamp,
            lastTimestamp: aggregate.source.lastTimestamp,
            decoderSchema: aggregate.source.decoderSchema,
            validatedLayouts: aggregate.source.validatedLayouts
        )
        let parity = AtriaHistoricalAggregateChunk.Parity(
            rawRows: rowCount,
            decodedRows: rowCount,
            undecodableRowsRetainedRaw: 0,
            metricUsableRows: aggregate.parity.metricUsableRows,
            heartRateSamples: aggregate.parity.heartRateSamples,
            heartRateSumBPM: aggregate.parity.heartRateSumBPM,
            acceptedRRBeats: aggregate.parity.acceptedRRBeats,
            acceptedRRSumMilliseconds: aggregate.parity.acceptedRRSumMilliseconds,
            validatedGravityRows: aggregate.parity.validatedGravityRows,
            motionEpochs: aggregate.parity.motionEpochs,
            projectionReceipts: aggregate.parity.projectionReceipts
        )
        return .init(schema: aggregate.schema,
                     createdAt: aggregate.createdAt,
                     source: source,
                     heartRateMinutes: aggregate.heartRateMinutes,
                     rrEpochs: aggregate.rrEpochs,
                     motionEpochs: aggregate.motionEpochs,
                     materializedProjections: aggregate.materializedProjections,
                     parity: parity)
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
            .appendingPathComponent("AtriaHistoricalRetentionConsumerCutoverTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
}
