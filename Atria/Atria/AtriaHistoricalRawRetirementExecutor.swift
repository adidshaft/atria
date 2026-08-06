import Darwin
import Foundation

/// Retires at most one immutable raw chunk after re-reading every durable
/// replacement. A small intent survives the unlink -> catalog -> replay-index
/// sequence so a later launch can finish either post-unlink crash seam.
struct AtriaHistoricalRawRetirementExecutor {
    enum Checkpoint: Equatable {
        case sourceDeleted
        case catalogRetired
        case replayIndexMarked
    }

    struct Result: Equatable {
        let chunkID: String
        let sourceDeleted: Bool
        let catalogRetired: Bool
        let recoveredPendingIntent: Bool
    }

    enum ExecutorError: Error, Equatable {
        case chunkUnavailable
        case activeOrOpenSource
        case compressedSourceUnsupported
        case committedAggregateUnavailable
        case committedManifestInvalid
        case sourceIdentityMismatch
        case consumerAuthorityIncomplete
        case replayIndexVerificationFailed
        case invalidRecoveryIntent
    }

    private struct Intent: Codable, Equatable {
        static let currentVersion = 1
        let version: Int
        let chunkID: String
        let rawSHA256: String
        let identityCount: Int
        let orderedKeysSHA256: String
    }

    private struct Authority {
        let identity: AtriaHistoricalCanonicalConsumerApplicationStore.VerificationIdentity
        let artifacts: [AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact]
        let replayShard: AtriaHistoricalReplayIdentityShard
    }

    let archiveRoot: URL
    let catalogStore: AtriaHistoricalArchiveCatalogStore
    var fileManager: FileManager = .default
    var now: () -> Date = Date.init
    var checkpoint: (Checkpoint) throws -> Void = { _ in }

    private var aggregateDirectory: URL {
        archiveRoot.appendingPathComponent("aggregates-v2", isDirectory: true)
    }

    private var manifestDirectory: URL {
        archiveRoot.appendingPathComponent("retention-manifests-v2", isDirectory: true)
    }

    private var intentDirectory: URL {
        archiveRoot.appendingPathComponent("retirement-intents-v1", isDirectory: true)
    }

    private var replayIndexURL: URL {
        archiveRoot.appendingPathComponent("retired-replay-v1", isDirectory: true)
            .appendingPathComponent("exact-identities-v3.sqlite")
    }

    func retire(chunkID: String, recoveredPendingIntent: Bool = false) throws -> Result {
        let catalog = try catalogStore.snapshot()
        guard let chunk = catalog.chunks.first(where: { $0.id == chunkID }) else {
            throw ExecutorError.chunkUnavailable
        }
        guard chunk.id != catalog.activeChunkID, chunk.state != .active else {
            throw ExecutorError.activeOrOpenSource
        }
        guard chunk.compressedStorage == nil else {
            // A compressed catalog row can own two physical representations.
            // Retiring only one would leak or silently orphan the other.
            throw ExecutorError.compressedSourceUnsupported
        }
        guard let rawSHA256 = chunk.contentSHA256,
              let rowCount = chunk.rowCount,
              let firstTimestamp = chunk.firstTimestamp,
              let lastTimestamp = chunk.lastTimestamp else {
            throw ExecutorError.sourceIdentityMismatch
        }

        let reader = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregateDirectory,
            manifestDirectoryURL: manifestDirectory
        )
        // Retirement targets ONE chunk. Loading the whole committed archive
        // here (this runs once per chunk in the compaction loop) is the
        // primary foreground-reopen memory balloon — N chunks × whole-archive
        // decode. Window the decode to the target chunk's own committed range
        // (the catalog already provides its exact bounds), which contains the
        // matching aggregate (+ any boundary-adjacent neighbors, filtered out
        // below by chunkID). `rejectedManifests` now scopes to this window,
        // which is the only region relevant to retiring this chunk.
        let snapshot = reader.load(
            since: firstTimestamp,
            until: Date(timeIntervalSinceReferenceDate:
                lastTimestamp.timeIntervalSinceReferenceDate.nextUp)
        )
        let matches = snapshot.aggregates.filter { $0.source.chunkID == chunkID }
        guard !snapshot.diagnostics.limitExceeded,
              snapshot.diagnostics.rejectedManifests == 0,
              matches.count == 1,
              let aggregate = matches.first,
              aggregate.source.rawSHA256 == rawSHA256,
              aggregate.source.rawByteCount == chunk.byteCount,
              aggregate.source.rawRowCount == rowCount,
              aggregate.source.firstTimestamp == firstTimestamp,
              aggregate.source.lastTimestamp == lastTimestamp else {
            throw ExecutorError.committedAggregateUnavailable
        }

        let manifestURL = manifestDirectory.appendingPathComponent("manifest-\(chunkID).json")
        let manifest = try decodeManifest(at: manifestURL)
        guard manifest.sourceChunkID == chunkID,
              manifest.sourceSHA256 == rawSHA256,
              manifest.sourceByteCount == chunk.byteCount,
              manifest.sourceRowCount == rowCount,
              manifest.sourceFirstTimestamp == firstTimestamp,
              manifest.sourceLastTimestamp == lastTimestamp,
              manifest.sourceFilename == chunk.relativePath.split(separator: "/").last.map(String.init),
              manifest.aggregateFilename == "aggregate-\(chunkID).json",
              manifest.semanticParityReceipt
                == AtriaHistoricalAggregateBuilder.semanticParityReceipt(for: aggregate) else {
            throw ExecutorError.committedManifestInvalid
        }

        let sourceURL = archiveRoot.appendingPathComponent(chunk.relativePath)
        if fileManager.fileExists(atPath: sourceURL.path) {
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  UInt64(values.fileSize ?? -1) == chunk.byteCount,
                  try AtriaHistoricalRetentionTransaction.sha256(of: sourceURL) == rawSHA256 else {
                throw ExecutorError.sourceIdentityMismatch
            }
        } else {
            guard recoveredPendingIntent || chunk.state == .retired else {
                throw ExecutorError.sourceIdentityMismatch
            }
        }

        let authority = try loadAuthority(aggregate: aggregate, sourceURL: sourceURL)
        let replayIndex = try AtriaHistoricalRetiredReplayIndex(databaseURL: replayIndexURL)
        let importReceipt = try replayIndex.importAndVerify(
            shard: authority.replayShard,
            source: aggregate.source,
            importedAt: now()
        )
        guard try replayIndex.verify(shard: authority.replayShard, receipt: importReceipt) else {
            throw ExecutorError.replayIndexVerificationFailed
        }

        let intent = Intent(version: Intent.currentVersion,
                            chunkID: chunkID,
                            rawSHA256: importReceipt.sourceRawSHA256,
                            identityCount: importReceipt.identityCount,
                            orderedKeysSHA256: importReceipt.orderedKeysSHA256)
        let intentURL = try publishIntent(intent)

        let authorityMatches: (AtriaHistoricalAggregateChunk) throws -> Bool = { candidate in
            guard candidate == aggregate else { return false }
            let fresh = try loadAuthority(aggregate: candidate, sourceURL: sourceURL)
            return fresh.identity == authority.identity
                && fresh.artifacts == authority.artifacts
                && fresh.replayShard == authority.replayShard
        }
        let applicationMatches: (AtriaHistoricalAggregateChunk) throws -> Bool = { candidate in
            guard candidate == aggregate else { return false }
            let adapter = canonicalAdapter()
            return try adapter.validatedCurrent(identity: authority.identity)
                == adapter.loadCurrent(sourceChunkID: chunkID)
        }
        let transaction = AtriaHistoricalRetentionTransaction(
            now: now,
            consumerProjectionVerifier: authorityMatches,
            consumerApplicationVerifier: applicationMatches,
            externalRawRetirementAuthorizer: authorityMatches,
            semanticVerifier: AtriaHistoricalAggregateBuilder.verify
        )
        let committed = try transaction.commit(.init(
            transactionID: chunkID,
            sourceURL: sourceURL,
            aggregateDirectoryURL: aggregateDirectory,
            manifestDirectoryURL: manifestDirectory,
            aggregate: aggregate,
            semanticParityReceipt: manifest.semanticParityReceipt,
            deleteSourceAfterCommit: true
        ))
        guard committed.sourceDeleted || !fileManager.fileExists(atPath: sourceURL.path) else {
            throw ExecutorError.sourceIdentityMismatch
        }
        try checkpoint(.sourceDeleted)

        if chunk.state != .retired {
            try catalogStore.markRetired(chunkID: chunkID,
                                         manifestURL: committed.manifestURL,
                                         now: now())
        }
        try checkpoint(.catalogRetired)
        // This follows catalog publication. If it fails, the durable intent is
        // deliberately retained and recovery replays this idempotent update.
        try replayIndex.markCatalogRetired(receipt: importReceipt, retiredAt: now())
        try checkpoint(.replayIndexMarked)
        try fileManager.removeItem(at: intentURL)
        try Self.synchronizeDirectory(intentDirectory)
        return .init(chunkID: chunkID,
                     sourceDeleted: committed.sourceDeleted,
                     catalogRetired: true,
                     recoveredPendingIntent: recoveredPendingIntent)
    }

    /// Completes at most one interrupted retirement before verified catalog
    /// scans encounter a sealed row whose source was already unlinked.
    func recoverFirstPendingIntent() throws -> Result? {
        guard fileManager.fileExists(atPath: intentDirectory.path) else { return nil }
        let urls = try fileManager.contentsOfDirectory(at: intentDirectory,
                                                       includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("retirement-intent-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let url = urls.first else { return nil }
        let decoder = JSONDecoder()
        let intent = try decoder.decode(Intent.self, from: Data(contentsOf: url))
        guard intent.version == Intent.currentVersion,
              url.lastPathComponent == "retirement-intent-\(intent.chunkID).json" else {
            throw ExecutorError.invalidRecoveryIntent
        }
        return try retire(chunkID: intent.chunkID, recoveredPendingIntent: true)
    }

    private func loadAuthority(
        aggregate: AtriaHistoricalAggregateChunk,
        sourceURL: URL
    ) throws -> Authority {
        let adapter = canonicalAdapter()
        guard let current = try adapter.loadCurrent(sourceChunkID: aggregate.source.chunkID),
              current.verificationIdentity.source.chunkID == aggregate.source.chunkID,
              current.verificationIdentity.source.rawSHA256 == aggregate.source.rawSHA256,
              current.verificationIdentity.source.firstTimestamp == aggregate.source.firstTimestamp,
              current.verificationIdentity.source.lastTimestamp == aggregate.source.lastTimestamp else {
            throw ExecutorError.consumerAuthorityIncomplete
        }
        let verified = try adapter.validatedCurrent(identity: current.verificationIdentity)
        guard verified == current else { throw ExecutorError.consumerAuthorityIncomplete }
        let artifacts = try adapter.validatedArtifacts(identity: current.verificationIdentity)
        let required = AtriaHistoricalAggregateChunk.rawRetirementRequiredProjectionKinds
        guard artifacts.count == required.count,
              Set(artifacts.map(\.receipt.kind)) == required,
              artifacts.allSatisfy({ artifact in
                  artifact.receipt.source == current.verificationIdentity.source
                      && artifact.receipt.dependencyStart <= aggregate.source.firstTimestamp
                      && artifact.receipt.dependencyEnd >= aggregate.source.lastTimestamp
                      && artifact.receipt.completionWatermark >= aggregate.source.lastTimestamp
                      && artifact.receipt.settledAt >= artifact.receipt.dependencyEnd
              }),
              let replay = artifacts.first(where: { $0.receipt.kind == .replayIdentity }) else {
            throw ExecutorError.consumerAuthorityIncomplete
        }
        let shard = try AtriaHistoricalReplayIdentityShard.decodeRetainedArtifact(
            replay.artifact,
            source: aggregate.source
        )
        let validReplay: Bool
        if fileManager.fileExists(atPath: sourceURL.path) {
            validReplay = try AtriaHistoricalReplayIdentityShard.verifyReceipt(
                replay.receipt,
                artifact: replay.artifact,
                sourceURL: sourceURL,
                source: aggregate.source
            )
        } else {
            validReplay = try AtriaHistoricalReplayIdentityShard.verifyRetainedReceipt(
                replay.receipt,
                artifact: replay.artifact,
                source: aggregate.source
            )
        }
        guard validReplay else { throw ExecutorError.consumerAuthorityIncomplete }
        return .init(identity: current.verificationIdentity,
                     artifacts: artifacts,
                     replayShard: shard)
    }

    private func canonicalAdapter() -> AtriaHistoricalCanonicalConsumerApplicationAdapter {
        let root = archiveRoot.appendingPathComponent("canonical-consumers-v1", isDirectory: true)
        return .init(destinationStore: .init(directoryURL: root.appendingPathComponent(
            "destinations", isDirectory: true
        )), proofDirectoryURL: root.appendingPathComponent(
            "application-proofs", isDirectory: true
        ))
    }

    private func decodeManifest(at url: URL) throws -> AtriaHistoricalRetentionTransaction.Manifest {
        guard fileManager.fileExists(atPath: url.path),
              let bytes = (try fileManager.attributesOfItem(atPath: url.path)[.size]
                as? NSNumber)?.uint64Value,
              bytes <= 256 * 1_024 else {
            throw ExecutorError.committedManifestInvalid
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(AtriaHistoricalRetentionTransaction.Manifest.self,
                                       from: Data(contentsOf: url)) }
        catch { throw ExecutorError.committedManifestInvalid }
    }

    private func publishIntent(_ intent: Intent) throws -> URL {
        try fileManager.createDirectory(at: intentDirectory, withIntermediateDirectories: true)
        let url = intentDirectory.appendingPathComponent("retirement-intent-\(intent.chunkID).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(intent)
        if fileManager.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else {
                throw ExecutorError.invalidRecoveryIntent
            }
            return url
        }
        let temporary = intentDirectory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        let descriptor = open(temporary.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
        try fileManager.moveItem(at: temporary, to: url)
        try Self.synchronizeDirectory(intentDirectory)
        return url
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}
