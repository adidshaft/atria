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
        var snapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        ).load()
        try validate(snapshot)

        let aggregateByID = try aggregatesByID(snapshot.aggregates)
        let candidates = catalog.chunks
            .filter { chunk in
                chunk.state == .sealed
                    && chunk.byteCount > 0
                    && !isComplete(chunk: chunk, aggregate: aggregateByID[chunk.id])
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id < $1.id
            }
        guard let chunk = candidates.first else {
            return .init(
                materializedChunkID: nil,
                remainingChunkCount: 0,
                catalogGeneration: catalog.generation,
                aggregateCount: snapshot.aggregates.count
            )
        }

        let sourceURL = archiveRoot.appendingPathComponent(chunk.relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw MaterializationError.rawSourceWasNotRetained(chunk.id)
        }
        let existingAggregate = aggregateByID[chunk.id]
        let build = try AtriaHistoricalAggregateBuilder.build(
            sourceURL: sourceURL,
            chunkID: chunk.id,
            // Aggregate identity must survive a crash/retry at a later wall
            // time. A maintenance invocation timestamp is not source identity.
            createdAt: existingAggregate?.createdAt
                ?? chunk.sealedAt
                ?? chunk.createdAt
        )
        if let existingAggregate {
            guard existingAggregate == build.aggregate,
                  try AtriaHistoricalAggregateBuilder.verify(
                    sourceURL: sourceURL,
                    aggregate: existingAggregate,
                    semanticParityReceipt: AtriaHistoricalAggregateBuilder
                        .semanticParityReceipt(for: existingAggregate)
                  ) else {
                throw MaterializationError.aggregateIdentityConflict(chunk.id)
            }
        }

        if !hasCompleteMetadata(chunk) {
            try catalogStore.recordSealedMetadata(
                chunkID: chunk.id,
                rowCount: build.aggregate.source.rawRowCount,
                firstTimestamp: build.aggregate.source.firstTimestamp,
                lastTimestamp: build.aggregate.source.lastTimestamp,
                contentSHA256: build.aggregate.source.rawSHA256
            )
            try checkpoint(.metadataPublished(chunk.id))
        }

        if existingAggregate == nil {
            let result = try AtriaHistoricalRetentionTransaction(
                now: { now },
                semanticVerifier: AtriaHistoricalAggregateBuilder.verify
            ).commit(.init(
                transactionID: chunk.id,
                sourceURL: sourceURL,
                aggregateDirectoryURL: aggregateDirectoryURL,
                manifestDirectoryURL: manifestDirectoryURL,
                aggregate: build.aggregate,
                semanticParityReceipt: build.semanticParityReceipt,
                deleteSourceAfterCommit: false
            ))
            guard !result.sourceDeleted else {
                throw MaterializationError.rawSourceWasNotRetained(chunk.id)
            }
            try checkpoint(.aggregatePublished(chunk.id))
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw MaterializationError.rawSourceWasNotRetained(chunk.id)
        }

        let verifiedCatalog = try catalogStore.snapshot()
        snapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregateDirectoryURL,
            manifestDirectoryURL: manifestDirectoryURL
        ).load()
        try validate(snapshot)
        let verifiedByID = try aggregatesByID(snapshot.aggregates)
        guard let repairedChunk = verifiedCatalog.chunks.first(where: {
            $0.id == chunk.id
        }),
        let repairedAggregate = verifiedByID[chunk.id],
        isComplete(chunk: repairedChunk, aggregate: repairedAggregate),
        try AtriaHistoricalAggregateBuilder.verify(
            sourceURL: sourceURL,
            aggregate: repairedAggregate,
            semanticParityReceipt: AtriaHistoricalAggregateBuilder
                .semanticParityReceipt(for: repairedAggregate)
        ) else {
            throw MaterializationError.repairedChunkUnavailable(chunk.id)
        }
        try checkpoint(.chunkVerified(chunk.id))

        let remaining = verifiedCatalog.chunks.filter {
            $0.state == .sealed
                && $0.byteCount > 0
                && !isComplete(chunk: $0, aggregate: verifiedByID[$0.id])
        }.count
        return .init(
            materializedChunkID: chunk.id,
            remainingChunkCount: remaining,
            catalogGeneration: verifiedCatalog.generation,
            aggregateCount: snapshot.aggregates.count
        )
    }

    private static func validate(
        _ snapshot: AtriaHistoricalAggregateReader.Snapshot
    ) throws {
        guard !snapshot.diagnostics.limitExceeded,
              snapshot.diagnostics.rejectedManifests == 0 else {
            throw MaterializationError.rejectedAggregateCatalog
        }
    }

    private static func aggregatesByID(
        _ aggregates: [AtriaHistoricalAggregateChunk]
    ) throws -> [String: AtriaHistoricalAggregateChunk] {
        var result: [String: AtriaHistoricalAggregateChunk] = [:]
        for aggregate in aggregates {
            guard result.updateValue(
                aggregate,
                forKey: aggregate.source.chunkID
            ) == nil else {
                throw MaterializationError.duplicateAggregate(
                    aggregate.source.chunkID
                )
            }
        }
        return result
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
        guard hasCompleteMetadata(chunk),
              let aggregate,
              chunk.contentSHA256 == aggregate.source.rawSHA256,
              chunk.byteCount == aggregate.source.rawByteCount,
              chunk.rowCount == aggregate.source.rawRowCount,
              HistoricalArchive.catalogTimestampMatches(
                raw: aggregate.source.firstTimestamp,
                catalog: chunk.firstTimestamp
              ),
              HistoricalArchive.catalogTimestampMatches(
                raw: aggregate.source.lastTimestamp,
                catalog: chunk.lastTimestamp
              ) else { return false }
        return true
    }
}
