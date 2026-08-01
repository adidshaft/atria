import Foundation

/// Bounded repair for immutable raw chunks recovered or rotated before their
/// decoded catalog metadata and shadow aggregate were published.
///
/// One invocation handles at most one chunk. Callers run this on the archive
/// queue and yield between reports so a large legacy archive cannot monopolize
/// a foreground execution lease. Raw retirement is deliberately impossible.
enum AtriaHistoricalSealedCatalogMaterializer {
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
    }

    enum Checkpoint: Equatable, Sendable {
        case metadataPublished(String)
        case aggregatePublished(String)
        case chunkVerified(String)
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
        let candidates = lightweightCandidates(
            catalog: catalog,
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        )
        guard let chunk = candidates.first else {
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

        let remaining = lightweightCandidates(
            catalog: verifiedCatalog,
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        )
        let aggregateCount: Int
        if remaining.isEmpty {
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
            remainingChunkCount: remaining.count,
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
    private static func isComplete(
        chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        source: AtriaHistoricalAggregateChunk.Source?
    ) -> Bool {
        guard hasCompleteMetadata(chunk),
              let source,
              chunk.contentSHA256 == source.rawSHA256,
              chunk.byteCount == source.rawByteCount,
              chunk.rowCount == source.rawRowCount,
              HistoricalArchive.catalogTimestampMatches(
                raw: source.firstTimestamp,
                catalog: chunk.firstTimestamp
              ),
              HistoricalArchive.catalogTimestampMatches(
                raw: source.lastTimestamp,
                catalog: chunk.lastTimestamp
              ) else { return false }
        return true
    }
}
