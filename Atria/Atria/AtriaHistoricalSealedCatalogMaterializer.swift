import Darwin
import Foundation

/// Bounded repair for immutable raw chunks recovered or rotated before their
/// decoded catalog metadata and shadow aggregate were published.
///
/// One invocation handles at most one chunk. Callers run this on the archive
/// queue and yield between reports so a large legacy archive cannot monopolize
/// a foreground execution lease. Raw retirement is deliberately impossible.
enum AtriaHistoricalSealedCatalogMaterializer {
    /// Divergent committed pairs are preserved here forever as a forensic
    /// audit trail — in the crash-lost-appends scenario they are the only
    /// surviving evidence of rows the interrupted seal attested. The directory
    /// lives outside both committed artifact directories because the aggregate
    /// reader accepts every top-level manifest JSON, and outside every GC and
    /// accounting surface that carries deletion authority.
    static let quarantineDirectoryName = "aggregate-repair-quarantine-v1"
    struct Report: Equatable, Sendable {
        let materializedChunkID: String?
        let remainingChunkCount: Int
        let catalogGeneration: UInt64
        let aggregateCount: Int

        var isComplete: Bool { remainingChunkCount == 0 }
    }

    enum MaterializationError: Error, Equatable {
        case rejectedAggregateCatalog
        case duplicateAggregate(String)
        case aggregateIdentityConflict(String)
        case rawSourceWasNotRetained(String)
        case repairedChunkUnavailable(String)
        /// The retained raw source no longer matches the catalog's sealed
        /// identity. A raw/catalog divergence is a different corruption class
        /// from a divergent committed pair and must never authorize any
        /// artifact mutation.
        case repairSourceMismatch(String)
    }

    enum Checkpoint: Equatable, Sendable {
        case metadataPublished(String)
        case aggregatePublished(String)
        case chunkVerified(String)
        case repairGenerationAdvanced(String)
        case divergentPairQuarantined(String)
    }

    static func materializeNext(
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        archiveRoot: URL,
        aggregateDirectoryURL: URL,
        manifestDirectoryURL: URL,
        now: Date,
        checkpoint: (Checkpoint) throws -> Void = { _ in }
    ) throws -> Report {
        precondition(!Thread.isMainThread)
        // Candidate discovery reads only the durable catalog. The canonical
        // builder and transaction below hash/verify the selected source; a
        // global verified snapshot would reread the entire retained archive
        // once per bounded retry and defeat the execution budget.
        let catalog = try catalogStore.snapshot()
        try catalog.validate()
        // A chunk with a divergent-but-coherent committed pair (crash-at-seal)
        // is repairable only here, so the completion transition below must not
        // run while one remains.
        let selected = lightweightCandidates(
            catalog: catalog,
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        ).first ?? divergentCommittedArtifactCandidates(
            catalog: catalog,
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        ).first
        guard let chunk = selected else {
            // Pay the global verification cost exactly once, only at the
            // transition to complete. Until then each bounded turn touches
            // just one source and one committed artifact pair.
            let verifiedCount = try fullyVerifiedAggregateCount(
                catalog: catalog,
                aggregateDirectoryURL: aggregateDirectoryURL,
                manifestDirectoryURL: manifestDirectoryURL
            )
            return .init(
                materializedChunkID: nil,
                remainingChunkCount: 0,
                catalogGeneration: catalog.generation,
                aggregateCount: verifiedCount
            )
        }

        let sourceURL = archiveRoot.appendingPathComponent(chunk.relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw MaterializationError.rawSourceWasNotRetained(chunk.id)
        }
        // The divergence claim must run before `existingAggregateHint` and
        // before the transaction's committed-retry seam: a divergent committed
        // manifest wedges `commitRetainedRawShadow` forever, and a divergent
        // orphan aggregate wedges the hint's identity check forever. The
        // generation bump inside the quarantine and the rebuild below share
        // this one bounded invocation on the caller's serialized archive lane,
        // so no consumer evidence pass can mint a snapshot digest between the
        // advance and the recommitted pair.
        if selectedChunkNeedsDivergenceQuarantine(
            chunk: chunk,
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        ) {
            try quarantineDivergentCommittedArtifacts(
                chunk: chunk,
                sourceURL: sourceURL,
                archiveRoot: archiveRoot,
                aggregateDirectoryURL: aggregateDirectoryURL,
                manifestDirectoryURL: manifestDirectoryURL,
                catalogStore: catalogStore,
                checkpoint: checkpoint
            )
        }
        let existingAggregate = try existingAggregateHint(
            chunkID: chunk.id,
            aggregateDirectoryURL: aggregateDirectoryURL
        )
        let proof = try AtriaHistoricalAggregateBuilder
            .buildRetainedRawShadowProof(
            sourceURL: sourceURL,
            chunkID: chunk.id,
            // Aggregate identity must survive a crash/retry at a later wall
            // time. A maintenance invocation timestamp is not source identity.
            createdAt: existingAggregate?.createdAt
                ?? chunk.sealedAt
                ?? chunk.createdAt
        )
        if let existingAggregate {
            guard existingAggregate == proof.aggregate else {
                throw MaterializationError.aggregateIdentityConflict(chunk.id)
            }
        }

        if !hasCompleteMetadata(chunk) {
            try catalogStore.recordSealedMetadata(
                chunkID: chunk.id,
                rowCount: proof.aggregate.source.rawRowCount,
                firstTimestamp: proof.aggregate.source.firstTimestamp,
                lastTimestamp: proof.aggregate.source.lastTimestamp,
                contentSHA256: proof.aggregate.source.rawSHA256
            )
            try checkpoint(.metadataPublished(chunk.id))
        }

        let result = try AtriaHistoricalRetentionTransaction(
            now: { now },
            // Retained-shadow publication uses its typed proof seam below.
            // This generic verifier remains the irreversible-path default.
            semanticVerifier: AtriaHistoricalAggregateBuilder.verify
        ).commitRetainedRawShadow(.init(
                transactionID: chunk.id,
                sourceURL: sourceURL,
                aggregateDirectoryURL: aggregateDirectoryURL,
                manifestDirectoryURL: manifestDirectoryURL,
                proof: proof
            ))
        guard !result.sourceDeleted else {
            throw MaterializationError.rawSourceWasNotRetained(chunk.id)
        }
        if !result.reusedCommittedTransaction {
            try checkpoint(.aggregatePublished(chunk.id))
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw MaterializationError.rawSourceWasNotRetained(chunk.id)
        }

        let verifiedCatalog = try catalogStore.snapshot()
        guard let repairedChunk = verifiedCatalog.chunks.first(where: {
            $0.id == chunk.id
        }),
        isComplete(chunk: repairedChunk, aggregate: proof.aggregate) else {
            throw MaterializationError.repairedChunkUnavailable(chunk.id)
        }
        try checkpoint(.chunkVerified(chunk.id))

        // Divergent pairs count as remaining work: `isComplete` must never be
        // reported while one exists, so multiple broken chunks converge
        // through the caller's normal yield loop instead of dead-ending a
        // launch on a thrown completion error. The two candidate sets are
        // disjoint (lightweight requires a missing artifact or incomplete
        // metadata; divergent requires both artifacts and complete metadata).
        let remainingCount = lightweightCandidates(
            catalog: verifiedCatalog,
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        ).count + divergentCommittedArtifactCandidates(
            catalog: verifiedCatalog,
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        ).count
        let aggregateCount: Int
        if remainingCount == 0 {
            aggregateCount = try fullyVerifiedAggregateCount(
                catalog: verifiedCatalog,
                aggregateDirectoryURL: aggregateDirectoryURL,
                manifestDirectoryURL: manifestDirectoryURL
            )
        } else {
            aggregateCount = committedArtifactPairCount(
                catalog: verifiedCatalog,
                aggregateDirectoryURL: aggregateDirectoryURL,
                manifestDirectoryURL: manifestDirectoryURL
            )
        }
        return .init(
            materializedChunkID: chunk.id,
            remainingChunkCount: remainingCount,
            catalogGeneration: verifiedCatalog.generation,
            aggregateCount: aggregateCount
        )
    }

    private static func lightweightCandidates(
        catalog: AtriaHistoricalArchiveCatalog,
        aggregateDirectoryURL: URL,
        manifestDirectoryURL: URL
    ) -> [AtriaHistoricalArchiveCatalog.RawChunk] {
        catalog.chunks
            .filter { chunk in
                guard chunk.state == .sealed, chunk.byteCount > 0 else {
                    return false
                }
                let artifacts = artifactURLs(
                    chunkID: chunk.id,
                    aggregateDirectoryURL: aggregateDirectoryURL,
                    manifestDirectoryURL: manifestDirectoryURL
                )
                return !hasCompleteMetadata(chunk)
                    || !FileManager.default.fileExists(
                        atPath: artifacts.aggregate.path
                    )
                    || !FileManager.default.fileExists(
                        atPath: artifacts.manifest.path
                    )
            }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id < $1.id
            }
    }

    /// Sealed chunks whose committed artifact pair is present and internally
    /// coherent yet disagrees with the sealed catalog identity — the
    /// crash-at-seal class. Candidacy is decided from the small durable
    /// manifest alone (one bounded JSON per sealed chunk), never a
    /// whole-archive verify. An undecodable or incoherent manifest is
    /// deliberately NOT a candidate: that corruption class stays fail-closed
    /// through `fullyVerifiedAggregateCount`'s rejected-manifest accounting.
    private static func divergentCommittedArtifactCandidates(
        catalog: AtriaHistoricalArchiveCatalog,
        aggregateDirectoryURL: URL,
        manifestDirectoryURL: URL
    ) -> [AtriaHistoricalArchiveCatalog.RawChunk] {
        catalog.chunks
            .filter { chunk in
                guard chunk.state == .sealed,
                      chunk.byteCount > 0,
                      hasCompleteMetadata(chunk) else { return false }
                let artifacts = artifactURLs(
                    chunkID: chunk.id,
                    aggregateDirectoryURL: aggregateDirectoryURL,
                    manifestDirectoryURL: manifestDirectoryURL
                )
                guard FileManager.default.fileExists(
                        atPath: artifacts.aggregate.path
                      ),
                      FileManager.default.fileExists(
                        atPath: artifacts.manifest.path
                      ),
                      let manifest = decodedCommittedManifest(
                        at: artifacts.manifest
                      ),
                      manifest.sourceChunkID == chunk.id else { return false }
                return !manifestSourceMatchesCatalogChunk(manifest, chunk: chunk)
            }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id < $1.id
            }
    }

    /// Pre-flight for a chunk selected by `lightweightCandidates`, claiming
    /// the two crash-resume states of an interrupted repair before the
    /// existing fail-closed seams can wedge on them every pass:
    /// (a) divergent committed manifest — otherwise the transaction's
    ///     committed-retry path can never reconcile the rebuilt proof with the
    ///     stale manifest;
    /// (b) divergent orphan aggregate without a manifest — otherwise
    ///     `existingAggregateHint` pins the rebuild to the stale identity and
    ///     `aggregateIdentityConflict` recurs forever.
    /// Incomplete catalog metadata disqualifies the claim: without a sealed
    /// digest there is no catalog truth for the repair's Proof 1 to verify
    /// the retained raw against.
    private static func selectedChunkNeedsDivergenceQuarantine(
        chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        aggregateDirectoryURL: URL,
        manifestDirectoryURL: URL
    ) -> Bool {
        guard chunk.state == .sealed,
              chunk.byteCount > 0,
              hasCompleteMetadata(chunk) else { return false }
        let artifacts = artifactURLs(
            chunkID: chunk.id,
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        )
        if FileManager.default.fileExists(atPath: artifacts.manifest.path) {
            guard let manifest = decodedCommittedManifest(
                at: artifacts.manifest
            ), manifest.sourceChunkID == chunk.id else { return false }
            return !manifestSourceMatchesCatalogChunk(manifest, chunk: chunk)
        }
        if FileManager.default.fileExists(atPath: artifacts.aggregate.path) {
            guard let source = decodedCommittedAggregateSource(
                at: artifacts.aggregate
            ), source.chunkID == chunk.id else { return false }
            return !HistoricalArchive.aggregateSourceMatchesCatalogChunk(
                rawSHA256: source.rawSHA256,
                byteCount: source.rawByteCount,
                rowCount: source.rawRowCount,
                firstTimestamp: source.firstTimestamp,
                lastTimestamp: source.lastTimestamp,
                chunk: chunk
            )
        }
        return false
    }

    /// The only mutation primitive of the crash-at-seal repair. It never
    /// touches the raw source or any catalog chunk field, never writes into
    /// the committed artifact directories, and never deletes a quarantined
    /// artifact.
    private static func quarantineDivergentCommittedArtifacts(
        chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        sourceURL: URL,
        archiveRoot: URL,
        aggregateDirectoryURL: URL,
        manifestDirectoryURL: URL,
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        checkpoint: (Checkpoint) throws -> Void
    ) throws {
        // Proof 1 — the retained raw is the catalog's truth. Identity is the
        // compressed-transparent logical stream, never a physical hash of the
        // stored artifact, and must equal the sealed catalog identity exactly.
        // A failure here is a raw/catalog divergence: a different corruption
        // class that no quarantine may touch.
        let identity = try AtriaHistoricalJSONLInput.identity(at: sourceURL)
        guard identity.sha256 == chunk.contentSHA256,
              identity.byteCount == chunk.byteCount else {
            throw MaterializationError.repairSourceMismatch(chunk.id)
        }

        // Proof 2 — re-assert divergence on whichever artifacts exist. A pair
        // consistent with the catalog can never be quarantined.
        let artifacts = artifactURLs(
            chunkID: chunk.id,
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        )
        let aggregateExists = FileManager.default.fileExists(
            atPath: artifacts.aggregate.path
        )
        var moveAggregate = false
        var moveManifest = false
        if FileManager.default.fileExists(atPath: artifacts.manifest.path) {
            guard let manifest = decodedCommittedManifest(
                at: artifacts.manifest
            ), manifest.sourceChunkID == chunk.id else {
                // A divergent aggregate beside an undecodable manifest stays
                // fail-closed: the aggregate reader counts that manifest in
                // `rejectedManifests`, which rejects every completion pass
                // until it is inspected. No mutation is provable here.
                return
            }
            guard !manifestSourceMatchesCatalogChunk(manifest, chunk: chunk) else {
                return
            }
            // Proof 1 plus manifest divergence suffices to quarantine both
            // files even when the aggregate itself no longer decodes: the
            // quarantine name is content-addressed by the file's own bytes,
            // so preserving the evidence requires no decode.
            moveManifest = true
            moveAggregate = aggregateExists
        } else if aggregateExists {
            guard let source = decodedCommittedAggregateSource(
                at: artifacts.aggregate
            ),
            source.chunkID == chunk.id,
            !HistoricalArchive.aggregateSourceMatchesCatalogChunk(
                rawSHA256: source.rawSHA256,
                byteCount: source.rawByteCount,
                rowCount: source.rawRowCount,
                firstTimestamp: source.firstTimestamp,
                lastTimestamp: source.lastTimestamp,
                chunk: chunk
            ) else { return }
            moveAggregate = true
        } else {
            return
        }

        // The durable generation advance must precede any file move: the
        // committed aggregate-snapshot digest is about to change, and a digest
        // change without a strictly newer catalog generation permanently fails
        // the terminal publication checkpoint and the coverage-store rebind.
        // A crash immediately after this bump costs one harmless extra
        // generation on retry.
        try catalogStore.recordAggregateRepairGenerationAdvance(
            chunkID: chunk.id
        )
        try checkpoint(.repairGenerationAdvanced(chunk.id))

        let quarantineDirectory = archiveRoot.appendingPathComponent(
            quarantineDirectoryName, isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: quarantineDirectory,
            withIntermediateDirectories: true
        )
        // Aggregate first, then manifest: the interrupted state this order
        // can leave (orphan divergent manifest) is claimed on resume by the
        // cheap manifest-decode pre-flight.
        if moveAggregate {
            try quarantineMove(
                chunkID: chunk.id,
                from: artifacts.aggregate,
                to: quarantineDirectory,
                filenamePrefix: "quarantined-aggregate-\(chunk.id)",
                sourceDirectory: aggregateDirectoryURL
            )
        }
        if moveManifest {
            try quarantineMove(
                chunkID: chunk.id,
                from: artifacts.manifest,
                to: quarantineDirectory,
                filenamePrefix: "quarantined-manifest-\(chunk.id)",
                sourceDirectory: manifestDirectoryURL
            )
        }
        try checkpoint(.divergentPairQuarantined(chunk.id))
    }

    /// Content-addressed move into the quarantine. The destination name
    /// embeds the moved file's own byte digest so a retry after a crash can
    /// prove the move already completed; a same-name collision with different
    /// bytes is not provably the same evidence and fails closed.
    private static func quarantineMove(
        chunkID: String,
        from artifactURL: URL,
        to quarantineDirectory: URL,
        filenamePrefix: String,
        sourceDirectory: URL
    ) throws {
        let digest = try AtriaHistoricalRetentionTransaction.sha256(
            of: artifactURL
        )
        let destination = quarantineDirectory.appendingPathComponent(
            "\(filenamePrefix)-\(digest.prefix(16)).json"
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try AtriaHistoricalRetentionTransaction.sha256(of: destination)
                == digest else {
                throw MaterializationError.aggregateIdentityConflict(chunkID)
            }
            // A prior crashed attempt already preserved these exact bytes;
            // removing the duplicate source completes that interrupted move.
            try FileManager.default.removeItem(at: artifactURL)
        } else {
            try FileManager.default.moveItem(at: artifactURL, to: destination)
        }
        try synchronizeDirectory(sourceDirectory)
        try synchronizeDirectory(quarantineDirectory)
    }

    private static func manifestSourceMatchesCatalogChunk(
        _ manifest: AtriaHistoricalRetentionTransaction.Manifest,
        chunk: AtriaHistoricalArchiveCatalog.RawChunk
    ) -> Bool {
        HistoricalArchive.aggregateSourceMatchesCatalogChunk(
            rawSHA256: manifest.sourceSHA256,
            byteCount: manifest.sourceByteCount,
            rowCount: manifest.sourceRowCount,
            firstTimestamp: manifest.sourceFirstTimestamp,
            lastTimestamp: manifest.sourceLastTimestamp,
            chunk: chunk
        )
    }

    private static func decodedCommittedManifest(
        at url: URL
    ) -> AtriaHistoricalRetentionTransaction.Manifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(
                AtriaHistoricalRetentionTransaction.Manifest.self,
                from: data
              ),
              manifest.version
                == AtriaHistoricalRetentionTransaction.Manifest.currentVersion
        else { return nil }
        return manifest
    }

    private static func decodedCommittedAggregateSource(
        at url: URL
    ) -> AtriaHistoricalAggregateChunk.Source? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let aggregate = try? decoder.decode(
                AtriaHistoricalAggregateChunk.self,
                from: data
              ),
              (try? aggregate.validateForCommit()) != nil else { return nil }
        return aggregate.source
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func existingAggregateHint(
        chunkID: String,
        aggregateDirectoryURL: URL
    ) throws -> AtriaHistoricalAggregateChunk? {
        let url = aggregateDirectoryURL.appendingPathComponent(
            "aggregate-\(chunkID).json"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let aggregate = try decoder.decode(
            AtriaHistoricalAggregateChunk.self,
            from: Data(contentsOf: url)
        )
        try aggregate.validateForCommit()
        guard aggregate.source.chunkID == chunkID else {
            throw MaterializationError.aggregateIdentityConflict(chunkID)
        }
        return aggregate
    }

    /// Bounded whole-archive completeness verification. The old form decoded
    /// every aggregate into one resident `[String: AtriaHistoricalAggregateChunk]`
    /// just to (a) count accepted aggregates and (b) confirm every sealed chunk
    /// has a complete committed aggregate — the heavy per-minute/epoch arrays
    /// were never read. `streamedWholeArchiveDigest` reproduces the exact
    /// accepted-set and rejection state while holding one decoded aggregate at a
    /// time, and completeness needs only each source's lightweight identity.
    /// Returns the accepted aggregate count (the only value callers consume).
    private static func fullyVerifiedAggregateCount(
        catalog: AtriaHistoricalArchiveCatalog,
        aggregateDirectoryURL: URL,
        manifestDirectoryURL: URL
    ) throws -> Int {
        guard let streamed = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        ).streamedWholeArchiveDigest(
            limits: AtriaHistoricalAggregateReader.LoadLimits.unboundedConsumerProjection
        ) else {
            throw MaterializationError.rejectedAggregateCatalog
        }
        guard !streamed.diagnostics.limitExceeded,
              streamed.diagnostics.rejectedManifests == 0 else {
            throw MaterializationError.rejectedAggregateCatalog
        }
        var sourceByID: [String: AtriaHistoricalAggregateChunk.Source] = [:]
        for source in streamed.sources {
            guard sourceByID.updateValue(source, forKey: source.chunkID) == nil else {
                throw MaterializationError.duplicateAggregate(source.chunkID)
            }
        }
        if let incomplete = catalog.chunks
            .filter({ $0.state == .sealed && $0.byteCount > 0 })
            .first(where: {
                !isComplete(chunk: $0, source: sourceByID[$0.id])
            }) {
            throw MaterializationError.repairedChunkUnavailable(incomplete.id)
        }
        return streamed.sources.count
    }

    private static func committedArtifactPairCount(
        catalog: AtriaHistoricalArchiveCatalog,
        aggregateDirectoryURL: URL,
        manifestDirectoryURL: URL
    ) -> Int {
        catalog.chunks.filter { chunk in
            guard chunk.state == .sealed, chunk.byteCount > 0 else {
                return false
            }
            let artifacts = artifactURLs(
                chunkID: chunk.id,
                aggregateDirectoryURL: aggregateDirectoryURL,
                manifestDirectoryURL: manifestDirectoryURL
            )
            return FileManager.default.fileExists(atPath: artifacts.aggregate.path)
                && FileManager.default.fileExists(atPath: artifacts.manifest.path)
        }.count
    }

    private static func artifactURLs(
        chunkID: String,
        aggregateDirectoryURL: URL,
        manifestDirectoryURL: URL
    ) -> (aggregate: URL, manifest: URL) {
        (
            aggregateDirectoryURL.appendingPathComponent(
                "aggregate-\(chunkID).json"
            ),
            manifestDirectoryURL.appendingPathComponent(
                "manifest-\(chunkID).json"
            )
        )
    }

    private static func hasCompleteMetadata(
        _ chunk: AtriaHistoricalArchiveCatalog.RawChunk
    ) -> Bool {
        guard let rows = chunk.rowCount,
              rows > 0,
              let first = chunk.firstTimestamp,
              let last = chunk.lastTimestamp,
              last >= first,
              let digest = chunk.contentSHA256 else { return false }
        return digest.count == 64
    }

    private static func isComplete(
        chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        aggregate: AtriaHistoricalAggregateChunk?
    ) -> Bool {
        isComplete(chunk: chunk, source: aggregate?.source)
    }

    /// Completeness needs only the source identity, never the heavy aggregate
    /// arrays — so the streaming path can verify from `Source` alone.
    /// `hasCompleteMetadata` stays a separate materializer-only gate: the
    /// shared 5-tuple predicate must remain exactly what the proof factory
    /// enforces (a sealed zero-row chunk with an agreeing aggregate passes
    /// the factory but is never materializer-complete).
    private static func isComplete(
        chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        source: AtriaHistoricalAggregateChunk.Source?
    ) -> Bool {
        guard hasCompleteMetadata(chunk),
              let source,
              HistoricalArchive.aggregateSourceMatchesCatalogChunk(
                rawSHA256: source.rawSHA256,
                byteCount: source.rawByteCount,
                rowCount: source.rawRowCount,
                firstTimestamp: source.firstTimestamp,
                lastTimestamp: source.lastTimestamp,
                chunk: chunk
              ) else { return false }
        return true
    }
}
