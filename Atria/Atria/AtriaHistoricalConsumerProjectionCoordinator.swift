import Foundation

/// Process-wide foreground gate for the long historical projection lanes.
///
/// The archive lanes are admitted under a foreground-only entry gate, but a
/// lane admitted while active keeps allocating on the archive queues after the
/// scene backgrounds. The scene-phase handler flips this atomic Bool so
/// multi-source projection loops can abort cleanly BETWEEN sources; every
/// already-published receipt set is durable, so a partial pass resumes exactly
/// like a crash on the next foreground pass.
enum AtriaHistoricalProjectionForegroundGate {
    private static let lock = NSLock()
    private static var backgrounded = false

    static var isBackgrounded: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return backgrounded
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            backgrounded = newValue
        }
    }
}

/// Production-safe publication of historical consumer artifacts.
///
/// The coordinator accepts no caller-created inspection proof. Every typed
/// proof is derived from `AtriaHistoricalActivityInspectionProofFactory`, which
/// re-reads the real catalog from disk and binds it to a durable terminal-drain
/// record and the exact strict-reader aggregate snapshot. Publication is
/// shadow-only: this type never mutates the raw catalog, never marks a chunk
/// retired, and never deletes a source file.
struct AtriaHistoricalConsumerProjectionCoordinator {
    typealias Configuration = AtriaHistoricalConsumerProjectionConfiguration

    enum SettlementReadiness: Equatable, Sendable {
        case ready(requiredStart: Date, requiredEnd: Date)
        case pendingFutureEvidence(requiredStart: Date, requiredEnd: Date)
    }

    struct DeferredSource: Equatable, Sendable {
        let chunkID: String
        let reason: String
    }

    struct Report: Sendable {
        static let artifactsPerCompleteSource = 5

        let completionGeneration: UInt64?
        let inspectedSourceCount: Int
        let published: [AtriaHistoricalConsumerReceiptLedger.Published]
        let deferredSources: [DeferredSource]

        var rawRetirementWasAttempted: Bool { false }

        /// Authority may be consumed only after every inspected source has a
        /// complete activity/daily/steps/sleep/workout receipt set. A narrow
        /// completion interval normally defers sources because it cannot cover
        /// their civil-day and lookback/lookahead dependencies; zero receipts
        /// is therefore never success.
        var hasCompleteConsumerCoverage: Bool {
            inspectedSourceCount > 0
                && deferredSources.isEmpty
                && published.count
                    == inspectedSourceCount * Self.artifactsPerCompleteSource
        }
    }

    let completionStore: AtriaHistoricalDrainCompletionGenerationStore
    let receiptLedger: AtriaHistoricalConsumerReceiptLedger

    /// Publishes all five derived consumer receipts for every source whose
    /// complete history/look-ahead interval is covered by the latest durable
    /// terminal record. Sources that are too recent or lack committed neighbor
    /// aggregates are deferred, never interpreted as empty.
    func publishEligibleReceipts(
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot,
        configuration: Configuration,
        lane: String = "consumer_projection",
        shouldAbortBetweenSources: () -> Bool = {
            AtriaHistoricalProjectionForegroundGate.isBackgrounded
        }
    ) throws -> Report {
        try publishEligibleReceipts(
            evidence: .store(catalogStore),
            aggregateSnapshot: aggregateSnapshot,
            configuration: configuration,
            selectedChunkID: nil,
            lane: lane,
            shouldAbortBetweenSources: shouldAbortBetweenSources
        )
    }

    /// Memory-shape overload for flows that already hold the file-verified
    /// catalog and both canonical evidence encodings for this exact pass. The
    /// digests and every validation are identical to the store-based entry;
    /// only the per-source recomputation frequency changes.
    func publishEligibleReceipts(
        verifiedCatalog: AtriaHistoricalArchiveCatalog,
        catalogData: Data,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot,
        aggregateData: Data,
        configuration: Configuration,
        lane: String = "consumer_projection",
        shouldAbortBetweenSources: () -> Bool = {
            AtriaHistoricalProjectionForegroundGate.isBackgrounded
        }
    ) throws -> Report {
        try publishEligibleReceipts(
            evidence: .hoisted(verifiedCatalog, catalogData, aggregateData),
            aggregateSnapshot: aggregateSnapshot,
            configuration: configuration,
            selectedChunkID: nil,
            lane: lane,
            shouldAbortBetweenSources: shouldAbortBetweenSources
        )
    }

    /// Publishes one atomic five-receipt set for a single already-committed
    /// source. This bounded form is used by maintenance so one invocation can
    /// never accidentally claim cutover for unrelated shadow chunks.
    func publishReceiptSet(
        for chunkID: String,
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot,
        configuration: Configuration
    ) throws -> Report {
        try publishEligibleReceipts(
            evidence: .store(catalogStore),
            aggregateSnapshot: aggregateSnapshot,
            configuration: configuration,
            selectedChunkID: chunkID,
            lane: "consumer_projection",
            shouldAbortBetweenSources: { false }
        )
    }

    /// Memory-shape single-source overload; see the hoisted
    /// `publishEligibleReceipts` above for the evidence contract.
    func publishReceiptSet(
        for chunkID: String,
        verifiedCatalog: AtriaHistoricalArchiveCatalog,
        catalogData: Data,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot,
        aggregateData: Data,
        configuration: Configuration
    ) throws -> Report {
        try publishEligibleReceipts(
            evidence: .hoisted(verifiedCatalog, catalogData, aggregateData),
            aggregateSnapshot: aggregateSnapshot,
            configuration: configuration,
            selectedChunkID: chunkID,
            lane: "consumer_projection",
            shouldAbortBetweenSources: { false }
        )
    }

    /// The catalog snapshot, its canonical encoding, and the canonical
    /// aggregate-snapshot encoding are invariant across one publication pass.
    /// They are either hoisted by the caller from the same archive flow or
    /// computed exactly once below, never once per source.
    private enum CanonicalEvidenceInput {
        case store(AtriaHistoricalArchiveCatalogStore)
        case hoisted(AtriaHistoricalArchiveCatalog, Data, Data)
    }

    private func publishEligibleReceipts(
        evidence evidenceInput: CanonicalEvidenceInput,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot,
        configuration: Configuration,
        selectedChunkID: String?,
        lane: String,
        shouldAbortBetweenSources: () -> Bool
    ) throws -> Report {
        guard !aggregateSnapshot.diagnostics.limitExceeded,
              aggregateSnapshot.diagnostics.rejectedManifests == 0 else {
            throw CoordinatorError.rejectedAggregateManifest
        }
        let completion = try completionStore.loadLatest()
        let factory = AtriaHistoricalActivityInspectionProofFactory(
            completionStore: completionStore
        )
        var published: [AtriaHistoricalConsumerReceiptLedger.Published] = []
        var deferred: [DeferredSource] = []
        let sources = aggregateSnapshot.aggregates
            .filter { selectedChunkID == nil || $0.source.chunkID == selectedChunkID }
            .sorted(by: sourceOrder)

        // Hoisted loop invariants: one file re-verified catalog snapshot, one
        // canonical catalog encoding, and one canonical aggregate-snapshot
        // encoding per pass instead of one per source. The bytes are the exact
        // `canonicalCatalogData`/`canonicalAggregateSnapshotData` output that
        // persisted completion SHA-256s compare against; only the frequency
        // changes.
        let catalog: AtriaHistoricalArchiveCatalog
        let catalogData: Data
        let aggregateData: Data
        switch evidenceInput {
        case .hoisted(let hoistedCatalog, let hoistedCatalogData, let hoistedAggregateData):
            catalog = hoistedCatalog
            catalogData = hoistedCatalogData
            aggregateData = hoistedAggregateData
        case .store(let catalogStore):
            do {
                let verified = try catalogStore.snapshotVerifiedAgainstFiles()
                try verified.validate()
                catalog = verified
                catalogData = try AtriaHistoricalActivityInspectionProofFactory
                    .canonicalCatalogData(verified)
                aggregateData = try AtriaHistoricalActivityInspectionProofFactory
                    .canonicalAggregateSnapshotData(aggregateSnapshot)
            } catch {
                // Identical deferral semantics to the previous per-iteration
                // evidence computation: every source defers with the evidence
                // error, except that a source whose required range itself is
                // invalid keeps its own range error because `requiredRange`
                // always ran before `factory.prepare`.
                for source in sources {
                    do {
                        _ = try requiredRange(for: source,
                                              dailyConfiguration: configuration.daily)
                        deferred.append(.init(chunkID: source.source.chunkID,
                                              reason: String(reflecting: error)))
                    } catch let rangeError {
                        deferred.append(.init(chunkID: source.source.chunkID,
                                              reason: String(reflecting: rangeError)))
                    }
                }
                return .init(completionGeneration: completion.generation,
                             inspectedSourceCount: sources.count,
                             published: published,
                             deferredSources: deferred)
            }
        }

        for (index, source) in sources.enumerated() {
            if index > 0, shouldAbortBetweenSources() {
                // The app left the foreground mid-lane. Receipt sets already
                // published are durable, so aborting BETWEEN sources (never
                // mid-source) resumes exactly like a crash next foreground.
                AtriaDebugLog("ATRIADBG historical_consumer_projection status=background_abort lane=%@ completed=%d total=%d action=resume_between_sources_from_durable_journals",
                              lane,
                              index,
                              sources.count)
                for remaining in sources[index...] {
                    deferred.append(.init(
                        chunkID: remaining.source.chunkID,
                        reason: "deferredBackgroundAbortBetweenSources"
                    ))
                }
                break
            }
            // Foundation/CryptoKit temporaries from one source's typed proof
            // and five receipts must not accumulate across a 40-60 source
            // pass (see AtriaHistoricalJSONLRecentScanner for the on-device
            // evidence behind this pattern).
            autoreleasepool {
                do {
                    let range = try requiredRange(for: source,
                                                  dailyConfiguration: configuration.daily)
                    let prepared = try factory.prepare(
                        verifiedCatalog: catalog,
                        catalogData: catalogData,
                        aggregateSnapshot: aggregateSnapshot,
                        aggregateData: aggregateData,
                        requestedStart: range.lowerBound,
                        requestedEnd: range.upperBound
                    )
                    guard prepared.completionGeneration == completion.generation else {
                        throw CoordinatorError.completionChangedDuringPublication
                    }
                    let sourcePublished = try publishReceiptSet(
                        source: source,
                        prepared: prepared,
                        configuration: configuration,
                        settledAt: completion.completedAt
                    )
                    published.append(contentsOf: sourcePublished)
                } catch {
                    deferred.append(.init(chunkID: source.source.chunkID,
                                          reason: String(reflecting: error)))
                }
            }
        }

        return .init(completionGeneration: completion.generation,
                     inspectedSourceCount: sources.count,
                     published: published,
                     deferredSources: deferred)
    }

    /// Settles one previously pending source from the latest independently
    /// journaled full scan. The persisted source identity and dependency bounds
    /// must still match the immutable aggregate; only the strap cursor
    /// watermark can close the future suffix.
    func publishReceiptSetUsingFullScan(
        for chunkID: String,
        expectedRawSHA256: String,
        requiredStart: Date,
        requiredEnd: Date,
        fullScanStore: AtriaHistoricalFullScanCompletionStore,
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        aggregateSnapshot: AtriaHistoricalAggregateReader.Snapshot,
        configuration: Configuration
    ) throws -> Report {
        guard !aggregateSnapshot.diagnostics.limitExceeded,
              aggregateSnapshot.diagnostics.rejectedManifests == 0 else {
            throw CoordinatorError.rejectedAggregateManifest
        }
        guard let source = aggregateSnapshot.aggregates.first(where: {
            $0.source.chunkID == chunkID
        }), source.source.rawSHA256 == expectedRawSHA256 else {
            throw CoordinatorError.sourceIdentityMismatch
        }
        let canonicalRange = try requiredRange(
            for: source,
            dailyConfiguration: configuration.daily
        )
        // `PendingConsumerDependency` can be checkpointed from the in-memory
        // terminal aggregate before its ISO-8601 catalog representation is
        // reloaded. Catalog dates persist at whole-second precision, while a
        // WHOOP row can retain sub-second precision. Treat only bounds within
        // the same persisted second as the same immutable dependency. A real
        // algorithm/time-zone/range change still fails closed.
        guard Self.persistedDependencyBoundMatches(
                canonical: canonicalRange.lowerBound,
                checkpointed: requiredStart
              ),
              Self.persistedDependencyBoundMatches(
                canonical: canonicalRange.upperBound,
                checkpointed: requiredEnd
              ) else {
            throw CoordinatorError.pendingDependencyMismatch
        }
        let scan = try fullScanStore.loadLatest()
        let prepared = try AtriaHistoricalActivityInspectionProofFactory(
            completionStore: completionStore
        ).prepareUsingFullScan(
            catalogStore: catalogStore,
            aggregateSnapshot: aggregateSnapshot,
            scan: scan,
            requestedStart: canonicalRange.lowerBound,
            requestedEnd: canonicalRange.upperBound
        )
        guard prepared.completionGeneration == scan.generation else {
            throw CoordinatorError.completionChangedDuringPublication
        }
        let published = try publishReceiptSet(
            source: source,
            prepared: prepared,
            configuration: configuration,
            settledAt: scan.terminalAt
        )
        return .init(
            completionGeneration: scan.generation,
            inspectedSourceCount: 1,
            published: published,
            deferredSources: []
        )
    }

    private func publishReceiptSet(
        source: AtriaHistoricalAggregateChunk,
        prepared: AtriaHistoricalActivityInspectionProofFactory.Prepared,
        configuration: Configuration,
        settledAt: Date
    ) throws -> [AtriaHistoricalConsumerReceiptLedger.Published] {
        let dailyProof = try makeDailyProof(prepared)
        let sessionProof = try makeSessionProof(prepared)
        var published: [AtriaHistoricalConsumerReceiptLedger.Published] = []
        published.append(try AtriaHistoricalActivityProjection.publishReceipt(
            source: source,
            dependencyChunks: prepared.dependencyChunks,
            configuration: configuration.activity,
            inspectionProof: prepared.inspectionProof,
            completionWatermark: prepared.completionWatermark,
            ledger: receiptLedger,
            settledAt: settledAt
        ))
        published.append(try AtriaHistoricalDailyConsumerProjection.publishDailyMetricsReceipt(
            source: source,
            dependencyChunks: prepared.dependencyChunks,
            configuration: configuration.daily,
            inspectionProof: dailyProof,
            completionWatermark: prepared.completionWatermark,
            ledger: receiptLedger,
            settledAt: settledAt
        ))
        published.append(try AtriaHistoricalDailyConsumerProjection.publishStepsReceipt(
            source: source,
            dependencyChunks: prepared.dependencyChunks,
            configuration: configuration.daily,
            inspectionProof: dailyProof,
            completionWatermark: prepared.completionWatermark,
            ledger: receiptLedger,
            settledAt: settledAt
        ))
        published.append(try AtriaHistoricalSleepProjection.publishReceipt(
            source: source,
            dependencyChunks: prepared.dependencyChunks,
            configuration: configuration.sleep,
            inspectionProof: sessionProof,
            completionWatermark: prepared.completionWatermark,
            ledger: receiptLedger,
            settledAt: settledAt
        ))
        published.append(try AtriaHistoricalWorkoutProjection.publishReceipt(
            source: source,
            dependencyChunks: prepared.dependencyChunks,
            configuration: configuration.workout,
            inspectionProof: sessionProof,
            completionWatermark: prepared.completionWatermark,
            ledger: receiptLedger,
            settledAt: settledAt
        ))
        let ledgerSource = AtriaHistoricalConsumerReceiptLedger.Source(
            chunkID: source.source.chunkID,
            rawSHA256: source.source.rawSHA256,
            firstTimestamp: source.source.firstTimestamp,
            lastTimestamp: source.source.lastTimestamp
        )
        try receiptLedger.activateCurrentSet(for: ledgerSource, publications: published)
        return published
    }

    enum CoordinatorError: Error, Equatable {
        case rejectedAggregateManifest
        case invalidDailyTimeZone
        case invalidRequiredRange
        case completionChangedDuringPublication
        case sourceIdentityMismatch
        case pendingDependencyMismatch
    }

    /// Tells the full-drain authority whether its exact closed interval can
    /// honestly settle the five typed consumers. A current-day drain normally
    /// cannot: daily consumers need the civil-day close and sleep needs four
    /// hours of lookahead. That is a pending projection, not failed gap
    /// coverage and never permission to manufacture an empty artifact.
    static func settlementReadiness(
        sourceFirstTimestamp: Date,
        sourceLastTimestamp: Date,
        completionStart: Date,
        completionEnd: Date,
        dailyConfiguration: AtriaHistoricalDailyConsumerProjection.Configuration
    ) throws -> SettlementReadiness {
        let range = try requiredRange(sourceFirstTimestamp: sourceFirstTimestamp,
                                      sourceLastTimestamp: sourceLastTimestamp,
                                      dailyConfiguration: dailyConfiguration)
        if completionStart <= range.lowerBound, completionEnd >= range.upperBound {
            return .ready(requiredStart: range.lowerBound, requiredEnd: range.upperBound)
        }
        return .pendingFutureEvidence(requiredStart: range.lowerBound,
                                      requiredEnd: range.upperBound)
    }

    private static func requiredRange(
        sourceFirstTimestamp: Date,
        sourceLastTimestamp: Date,
        dailyConfiguration: AtriaHistoricalDailyConsumerProjection.Configuration
    ) throws -> ClosedRange<Date> {
        guard sourceLastTimestamp >= sourceFirstTimestamp else {
            throw CoordinatorError.invalidRequiredRange
        }
        guard let zone = TimeZone(identifier: dailyConfiguration.timeZoneIdentifier) else {
            throw CoordinatorError.invalidDailyTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let dailyStart = calendar.startOfDay(for: sourceFirstTimestamp)
        let lastDay = calendar.startOfDay(for: sourceLastTimestamp)
        guard let dailyEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) else {
            throw CoordinatorError.invalidRequiredRange
        }
        let start = min(
            dailyStart,
            sourceFirstTimestamp.addingTimeInterval(
                -max(AtriaHistoricalActivityProjection.requiredHistory,
                     AtriaHistoricalSleepProjection.requiredHistory,
                     AtriaHistoricalWorkoutProjection.requiredHistory)
            )
        )
        let end = max(
            dailyEnd,
            sourceLastTimestamp.addingTimeInterval(
                max(AtriaHistoricalActivityProjection.requiredLookahead,
                    AtriaHistoricalSleepProjection.requiredLookahead,
                    AtriaHistoricalWorkoutProjection.requiredLookahead)
            )
        )
        guard end > start else { throw CoordinatorError.invalidRequiredRange }
        return start...end
    }

    private static func persistedDependencyBoundMatches(
        canonical: Date,
        checkpointed: Date
    ) -> Bool {
        HistoricalArchive.catalogTimestampMatches(
            raw: checkpointed,
            catalog: canonical
        )
    }

    private func requiredRange(
        for source: AtriaHistoricalAggregateChunk,
        dailyConfiguration: AtriaHistoricalDailyConsumerProjection.Configuration
    ) throws -> ClosedRange<Date> {
        try Self.requiredRange(sourceFirstTimestamp: source.source.firstTimestamp,
                               sourceLastTimestamp: source.source.lastTimestamp,
                               dailyConfiguration: dailyConfiguration)
    }

    private func makeDailyProof(
        _ prepared: AtriaHistoricalActivityInspectionProofFactory.Prepared
    ) throws -> AtriaHistoricalDailyConsumerProjection.InspectionProof {
        try .make(
            generationIdentifier: prepared.generationIdentifier,
            catalogSnapshot: prepared.catalogSnapshot,
            dependencyChunks: prepared.dependencyChunks,
            closedCoverageIntervals: prepared.closedCoverageIntervals.map {
                .init(start: $0.start, end: $0.end, recordCount: $0.recordCount)
            }
        )
    }

    private func makeSessionProof(
        _ prepared: AtriaHistoricalActivityInspectionProofFactory.Prepared
    ) throws -> AtriaHistoricalSessionInspectionProof {
        try .make(
            generationIdentifier: prepared.generationIdentifier,
            catalogSnapshot: prepared.catalogSnapshot,
            closedCoverageIntervals: prepared.closedCoverageIntervals.map {
                .init(start: $0.start, end: $0.end, recordCount: $0.recordCount)
            }
        )
    }

    private func sourceOrder(
        _ lhs: AtriaHistoricalAggregateChunk,
        _ rhs: AtriaHistoricalAggregateChunk
    ) -> Bool {
        if lhs.source.firstTimestamp != rhs.source.firstTimestamp {
            return lhs.source.firstTimestamp < rhs.source.firstTimestamp
        }
        return lhs.source.chunkID < rhs.source.chunkID
    }
}
