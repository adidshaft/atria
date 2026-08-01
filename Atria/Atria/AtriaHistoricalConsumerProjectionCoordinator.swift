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
    ///
    /// Takes the reader (never a pre-loaded whole-archive snapshot) so the
    /// whole-archive aggregate-snapshot digest can be streamed once at bounded
    /// memory and each source's dependency window can be loaded one at a time
    /// inside the existing per-source `autoreleasepool`. This is the fix for
    /// the foreground reopen memory balloon: previously every decoded
    /// aggregate (per-minute HR dictionaries, RR/motion epochs, for the whole
    /// committed archive) stayed resident for the entire multi-source pass.
    func publishEligibleReceipts(
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        aggregateReader: AtriaHistoricalAggregateReader,
        limits: AtriaHistoricalAggregateReader.LoadLimits = .unboundedConsumerProjection,
        configuration: Configuration,
        lane: String = "consumer_projection",
        shouldAbortBetweenSources: () -> Bool = {
            AtriaHistoricalProjectionForegroundGate.isBackgrounded
        }
    ) throws -> Report {
        try publishEligibleReceipts(
            evidence: .store(catalogStore),
            aggregateReader: aggregateReader,
            limits: limits,
            configuration: configuration,
            selectedChunkID: nil,
            lane: lane,
            shouldAbortBetweenSources: shouldAbortBetweenSources
        )
    }

    /// Memory-shape overload for flows that already hold the file-verified
    /// catalog and its canonical encoding for this exact pass. Every
    /// validation is identical to the store-based entry; only the catalog
    /// recomputation frequency changes. The whole-archive aggregate-snapshot
    /// digest is still streamed fresh from `aggregateReader` below — it is
    /// cheap at bounded memory and keeps this overload's digest guarantee
    /// identical to the store-based entry's.
    func publishEligibleReceipts(
        verifiedCatalog: AtriaHistoricalArchiveCatalog,
        catalogData: Data,
        aggregateReader: AtriaHistoricalAggregateReader,
        limits: AtriaHistoricalAggregateReader.LoadLimits = .unboundedConsumerProjection,
        configuration: Configuration,
        lane: String = "consumer_projection",
        shouldAbortBetweenSources: () -> Bool = {
            AtriaHistoricalProjectionForegroundGate.isBackgrounded
        }
    ) throws -> Report {
        try publishEligibleReceipts(
            evidence: .hoisted(verifiedCatalog, catalogData),
            aggregateReader: aggregateReader,
            limits: limits,
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
        try publishEligibleReceiptsFromSnapshot(
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
        aggregateSnapshotDigest: String,
        configuration: Configuration
    ) throws -> Report {
        try publishEligibleReceiptsFromSnapshot(
            evidence: .hoisted(verifiedCatalog, catalogData, aggregateSnapshotDigest),
            aggregateSnapshot: aggregateSnapshot,
            configuration: configuration,
            selectedChunkID: chunkID,
            lane: "consumer_projection",
            shouldAbortBetweenSources: { false }
        )
    }

    /// Reader-based single-source overload. Streams the whole-archive digest
    /// once and window-loads only the selected source's dependency range
    /// (`requiredRange`, which the core computes internally — wider than the
    /// chunk's own bounds) instead of accepting a whole-archive snapshot. This
    /// is the bounded-memory form for the crash-resume and pending-consumer
    /// maintenance paths; every validation is identical to the snapshot-based
    /// overload above, only the decode is windowed.
    func publishReceiptSet(
        for chunkID: String,
        verifiedCatalog: AtriaHistoricalArchiveCatalog,
        catalogData: Data,
        aggregateReader: AtriaHistoricalAggregateReader,
        limits: AtriaHistoricalAggregateReader.LoadLimits = .unboundedConsumerProjection,
        configuration: Configuration
    ) throws -> Report {
        try publishEligibleReceipts(
            evidence: .hoisted(verifiedCatalog, catalogData),
            aggregateReader: aggregateReader,
            limits: limits,
            configuration: configuration,
            selectedChunkID: chunkID,
            lane: "consumer_projection",
            shouldAbortBetweenSources: { false }
        )
    }

    /// The catalog snapshot and its canonical encoding are invariant across
    /// one publication pass. They are either hoisted by the caller from the
    /// same archive flow or computed exactly once below, never once per
    /// source. The whole-archive aggregate-snapshot digest is always streamed
    /// fresh from `aggregateReader` in the core function below, exactly once
    /// per pass either way.
    private enum CanonicalEvidenceInput {
        case store(AtriaHistoricalArchiveCatalogStore)
        case hoisted(AtriaHistoricalArchiveCatalog, Data)
    }

    private func publishEligibleReceipts(
        evidence evidenceInput: CanonicalEvidenceInput,
        aggregateReader: AtriaHistoricalAggregateReader,
        limits: AtriaHistoricalAggregateReader.LoadLimits,
        configuration: Configuration,
        selectedChunkID: String?,
        lane: String,
        shouldAbortBetweenSources: () -> Bool
    ) throws -> Report {
        let completion = try completionStore.loadLatest()
        let factory = AtriaHistoricalActivityInspectionProofFactory(
            completionStore: completionStore
        )

        // Stream the whole-archive digest exactly once per pass, at bounded
        // memory: peak residency is one decoded aggregate at a time (see
        // `AtriaHistoricalAggregateReader.streamedWholeArchiveDigest`).
        // `streamed.sources` below is the lightweight per-source identity
        // list (canonical order, no per-minute HR dictionaries or RR/motion
        // epoch arrays), so nothing heavy stays resident across the
        // multi-source loop — only the current source's windowed aggregates
        // do, inside the existing `autoreleasepool`.
        guard let streamed = aggregateReader.streamedWholeArchiveDigest(limits: limits) else {
            // A committed aggregate file changed between the streaming
            // digest's two verification passes. Fail closed exactly like the
            // whole-archive rejected-manifest guard immediately below: this
            // pass cannot trust the digest it would publish against.
            throw CoordinatorError.rejectedAggregateManifest
        }
        guard !streamed.diagnostics.limitExceeded,
              streamed.diagnostics.rejectedManifests == 0 else {
            throw CoordinatorError.rejectedAggregateManifest
        }

        var published: [AtriaHistoricalConsumerReceiptLedger.Published] = []
        var deferred: [DeferredSource] = []
        let sources = streamed.sources
            .filter { selectedChunkID == nil || $0.chunkID == selectedChunkID }
            .sorted(by: sourceOrder)

        // Hoisted loop invariant: one file re-verified catalog snapshot and
        // one canonical catalog encoding per pass instead of one per source.
        // The catalog bytes are the exact `canonicalCatalogData` output that
        // persisted completion SHA-256s compare against; only the
        // recomputation frequency changes.
        let catalog: AtriaHistoricalArchiveCatalog
        let catalogData: Data
        switch evidenceInput {
        case .hoisted(let hoistedCatalog, let hoistedCatalogData):
            catalog = hoistedCatalog
            catalogData = hoistedCatalogData
        case .store(let catalogStore):
            do {
                let verified = try catalogStore.snapshotVerifiedAgainstFiles()
                try verified.validate()
                catalog = verified
                catalogData = try AtriaHistoricalActivityInspectionProofFactory
                    .canonicalCatalogData(verified)
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
                        deferred.append(.init(chunkID: source.chunkID,
                                              reason: String(reflecting: error)))
                    } catch let rangeError {
                        deferred.append(.init(chunkID: source.chunkID,
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
                        chunkID: remaining.chunkID,
                        reason: "deferredBackgroundAbortBetweenSources"
                    ))
                }
                break
            }
            // Foundation/CryptoKit temporaries from one source's typed proof
            // and five receipts must not accumulate across a 40-60 source
            // pass (see AtriaHistoricalJSONLRecentScanner for the on-device
            // evidence behind this pattern). The windowed aggregate load
            // below is now ALSO inside this pool: only the chunks that
            // intersect this one source's dependency range are decoded, and
            // they are released before the next source's iteration begins.
            autoreleasepool {
                do {
                    let range = try requiredRange(for: source,
                                                  dailyConfiguration: configuration.daily)
                    // `load(since:until:)` treats `until` as EXCLUSIVE
                    // (`sourceFirstTimestamp >= until` is skipped), but
                    // `prepareVerified` selects dependency chunks with an
                    // INCLUSIVE `firstTimestamp <= requestedEnd`. The old
                    // whole-archive path loaded every chunk, so a dependency
                    // whose firstTimestamp lands exactly on `range.upperBound`
                    // was always present; a naive windowed `until:
                    // range.upperBound` would drop it and defer the source.
                    // Nudging `until` up by one ULP makes the windowed set an
                    // exact superset of `prepareVerified`'s inclusive filter
                    // (which then re-selects authoritatively), with no extra
                    // chunks beyond a bit-identical boundary match.
                    let windowUntil = Date(timeIntervalSinceReferenceDate:
                        range.upperBound.timeIntervalSinceReferenceDate.nextUp)
                    let windowed = aggregateReader.load(since: range.lowerBound,
                                                        until: windowUntil,
                                                        limits: limits)
                    guard !windowed.diagnostics.limitExceeded else {
                        throw CoordinatorError.windowedAggregateLoadLimitExceeded
                    }
                    guard let fullSource = windowed.aggregates.first(where: {
                        $0.source.chunkID == source.chunkID
                    }) else {
                        // The source itself always intersects its own
                        // required range, so its windowed load must contain
                        // it. Not finding it means the committed aggregate
                        // changed underneath this pass; defer rather than
                        // publish from a mismatched dependency set.
                        throw CoordinatorError.sourceIdentityMismatch
                    }
                    // WINDOWED aggregates (only the chunks this source's
                    // dependency range needs) paired with the WHOLE-archive
                    // diagnostics streamed above: `prepare`'s
                    // limitExceeded/rejectedManifests guards must see
                    // whole-archive state, and `prepareVerified`'s
                    // `relevantAggregates` filter still yields exactly the
                    // right subset from the smaller windowed array.
                    let windowedSnapshot = AtriaHistoricalAggregateReader.Snapshot(
                        aggregates: windowed.aggregates,
                        diagnostics: streamed.diagnostics
                    )
                    let prepared = try factory.prepare(
                        verifiedCatalog: catalog,
                        catalogData: catalogData,
                        aggregateSnapshot: windowedSnapshot,
                        aggregateSnapshotDigest: streamed.digest,
                        requestedStart: range.lowerBound,
                        requestedEnd: range.upperBound
                    )
                    guard prepared.completionGeneration == completion.generation else {
                        throw CoordinatorError.completionChangedDuringPublication
                    }
                    let sourcePublished = try publishReceiptSet(
                        source: fullSource,
                        prepared: prepared,
                        configuration: configuration,
                        settledAt: completion.completedAt
                    )
                    published.append(contentsOf: sourcePublished)
                } catch {
                    deferred.append(.init(chunkID: source.chunkID,
                                          reason: String(reflecting: error)))
                }
            }
        }

        return .init(completionGeneration: completion.generation,
                     inspectedSourceCount: sources.count,
                     published: published,
                     deferredSources: deferred)
    }

    /// Legacy whole-snapshot evidence shape, retained only for the bounded
    /// single-source `publishReceiptSet` overloads below (maintenance/cutover
    /// callers that already hold one already-decoded `Snapshot` for the one
    /// chunk they care about, not the multi-source foreground pass this file
    /// was ballooning on). Unlike `CanonicalEvidenceInput` above, the digest
    /// is either caller-supplied (hoisted) or computed once from the supplied
    /// snapshot (store) — there is no reader here to stream it from.
    private enum SnapshotEvidenceInput {
        case store(AtriaHistoricalArchiveCatalogStore)
        case hoisted(AtriaHistoricalArchiveCatalog, Data, String)
    }

    /// Unchanged pre-streaming implementation: iterates a caller-supplied,
    /// already-decoded `aggregateSnapshot` directly. Kept verbatim for the
    /// single-source `publishReceiptSet` overloads, which are out of scope
    /// for the whole-archive streaming fix above (a bounded, already
    /// one-chunk-at-a-time caller, not the multi-source foreground pass).
    private func publishEligibleReceiptsFromSnapshot(
        evidence evidenceInput: SnapshotEvidenceInput,
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

        let catalog: AtriaHistoricalArchiveCatalog
        let catalogData: Data
        let aggregateSnapshotDigest: String
        switch evidenceInput {
        case .hoisted(let hoistedCatalog, let hoistedCatalogData, let hoistedAggregateDigest):
            catalog = hoistedCatalog
            catalogData = hoistedCatalogData
            aggregateSnapshotDigest = hoistedAggregateDigest
        case .store(let catalogStore):
            do {
                let verified = try catalogStore.snapshotVerifiedAgainstFiles()
                try verified.validate()
                catalog = verified
                catalogData = try AtriaHistoricalActivityInspectionProofFactory
                    .canonicalCatalogData(verified)
                aggregateSnapshotDigest = try AtriaHistoricalActivityInspectionProofFactory
                    .streamedAggregateSnapshotDigest(aggregateSnapshot)
            } catch {
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
            autoreleasepool {
                do {
                    let range = try requiredRange(for: source,
                                                  dailyConfiguration: configuration.daily)
                    let prepared = try factory.prepare(
                        verifiedCatalog: catalog,
                        catalogData: catalogData,
                        aggregateSnapshot: aggregateSnapshot,
                        aggregateSnapshotDigest: aggregateSnapshotDigest,
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

    /// Reader-based bounded overload of `publishReceiptSetUsingFullScan`.
    /// Streams the whole-archive digest once (one decoded aggregate resident at
    /// a time), derives the dependency range from the streamed source identity,
    /// and window-loads only that range — instead of accepting a whole-archive
    /// snapshot. Every validation is identical to the snapshot-based entry.
    func publishReceiptSetUsingFullScan(
        for chunkID: String,
        expectedRawSHA256: String,
        requiredStart: Date,
        requiredEnd: Date,
        fullScanStore: AtriaHistoricalFullScanCompletionStore,
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        aggregateReader: AtriaHistoricalAggregateReader,
        limits: AtriaHistoricalAggregateReader.LoadLimits = .unboundedConsumerProjection,
        configuration: Configuration
    ) throws -> Report {
        guard let streamed = aggregateReader.streamedWholeArchiveDigest(limits: limits),
              !streamed.diagnostics.limitExceeded,
              streamed.diagnostics.rejectedManifests == 0 else {
            throw CoordinatorError.rejectedAggregateManifest
        }
        guard let sourceIdentity = streamed.sources.first(where: {
            $0.chunkID == chunkID
        }), sourceIdentity.rawSHA256 == expectedRawSHA256 else {
            throw CoordinatorError.sourceIdentityMismatch
        }
        let canonicalRange = try requiredRange(
            for: sourceIdentity,
            dailyConfiguration: configuration.daily
        )
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
        let windowed = aggregateReader.load(
            since: canonicalRange.lowerBound,
            until: Date(timeIntervalSinceReferenceDate:
                canonicalRange.upperBound.timeIntervalSinceReferenceDate.nextUp)
        )
        guard let source = windowed.aggregates.first(where: {
            $0.source.chunkID == chunkID
        }), source.source.rawSHA256 == expectedRawSHA256 else {
            throw CoordinatorError.sourceIdentityMismatch
        }
        let windowedSnapshot = AtriaHistoricalAggregateReader.Snapshot(
            aggregates: windowed.aggregates,
            diagnostics: streamed.diagnostics
        )
        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        try catalog.validate()
        let catalogData = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalCatalogData(catalog)
        let scan = try fullScanStore.loadLatest()
        let prepared = try AtriaHistoricalActivityInspectionProofFactory(
            completionStore: completionStore
        ).prepareUsingFullScan(
            verifiedCatalog: catalog,
            catalogData: catalogData,
            aggregateSnapshot: windowedSnapshot,
            aggregateSnapshotDigest: streamed.digest,
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
        /// The per-source windowed `aggregateReader.load(since:until:)` hit
        /// its byte/count limits. Unlike the whole-archive streamed digest
        /// guard above, this defers only the one source, not the whole pass.
        case windowedAggregateLoadLimitExceeded
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

    /// Lightweight-source overload: the multi-source `publishEligibleReceipts`
    /// loop iterates the streamed digest's `Source` list (no heavy per-minute
    /// arrays resident), so it needs a source's required range before it has
    /// decoded any full `AtriaHistoricalAggregateChunk` for that source.
    private func requiredRange(
        for source: AtriaHistoricalAggregateChunk.Source,
        dailyConfiguration: AtriaHistoricalDailyConsumerProjection.Configuration
    ) throws -> ClosedRange<Date> {
        try Self.requiredRange(sourceFirstTimestamp: source.firstTimestamp,
                               sourceLastTimestamp: source.lastTimestamp,
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

    /// Lightweight-source overload; same canonical order as above, applied to
    /// the streamed digest's `Source` list.
    private func sourceOrder(
        _ lhs: AtriaHistoricalAggregateChunk.Source,
        _ rhs: AtriaHistoricalAggregateChunk.Source
    ) -> Bool {
        if lhs.firstTimestamp != rhs.firstTimestamp {
            return lhs.firstTimestamp < rhs.firstTimestamp
        }
        return lhs.chunkID < rhs.chunkID
    }
}

extension AtriaHistoricalAggregateReader.LoadLimits {
    /// Practically unbounded whole-archive limits for the foreground consumer
    /// projection lanes above, matching the completely unbounded
    /// `aggregateReader.load()` calls their production call sites made before
    /// this streaming digest existed. `streamedWholeArchiveDigest`'s memory
    /// bound comes from decoding one aggregate at a time, not from these
    /// totals, so the headroom here is deliberately generous — a real archive
    /// should never legitimately hit it. A caller with a narrower memory
    /// budget can still pass its own tighter `LoadLimits`.
    static let unboundedConsumerProjection = AtriaHistoricalAggregateReader.LoadLimits(
        maximumManifestCount: 10_000_000,
        maximumManifestBytes: 64 * 1_024 * 1_024,
        maximumAggregateBytes: 8 * 1_024 * 1_024 * 1_024,
        maximumTotalAggregateBytes: 4 * 1_024 * 1_024 * 1_024 * 1_024
    )
}
