import Foundation

/// Makes shadow aggregation advance even when an older sealed raw chunk is
/// malformed. A failed chunk remains authoritative raw truth; it cannot starve
/// later chunks and it is never marked committed or retired.
struct AtriaHistoricalShadowCompactionCoordinator {
    /// Production retention selection, split from execution so the 30-day /
    /// 512-MiB policy cannot silently become dead configuration again.
    /// (Raw horizon moved 14 -> 30 days on 2026-08-19; insights are never
    /// pruned. The live value is `AtriaHistoricalRetentionPolicy.production`.)
    ///
    /// This queue authorizes shadow aggregation only. A candidate that already
    /// has a strict-reader aggregate remains raw and is reported separately;
    /// neither this type nor its caller has a raw-deletion API.
    struct RetentionQueue: Equatable, Sendable {
        let plan: AtriaHistoricalRetentionPolicy.Plan
        let uncommittedCandidates: [AtriaHistoricalArchiveCatalog.RawChunk]
        let shadowCommittedCandidateIDs: [String]
        let missingSourceCandidateIDs: [String]
        /// Catalogs recovered from legacy files may not yet have decoded
        /// content bounds. Lifecycle dates can safely prioritize a shadow
        /// build, but must never be treated as raw-retirement evidence.
        let provisionalTimestampCandidateIDs: [String]
    }

    struct Failure: Equatable, Sendable {
        let chunkID: String
        let message: String
    }

    enum Outcome<Value> {
        case noCandidates
        case committed(value: Value, precedingFailures: [Failure])
        case allFailed([Failure])
    }

    static func orderedEligibleChunks(
        catalog: AtriaHistoricalArchiveCatalog,
        archiveDirectory: URL,
        committedChunkIDs: Set<String>,
        fileManager: FileManager = .default
    ) -> [AtriaHistoricalArchiveCatalog.RawChunk] {
        catalog.chunks
            .filter { chunk in
                guard chunk.state == .sealed,
                      !committedChunkIDs.contains(chunk.id) else { return false }
                let source = archiveDirectory.appendingPathComponent(chunk.relativePath)
                return fileManager.fileExists(atPath: source.path)
            }
            .sorted { lhs, rhs in
                let lhsStart = lhs.firstTimestamp ?? lhs.createdAt
                let rhsStart = rhs.firstTimestamp ?? rhs.createdAt
                if lhsStart != rhsStart { return lhsStart < rhsStart }
                let lhsEnd = lhs.lastTimestamp ?? lhs.sealedAt ?? lhs.createdAt
                let rhsEnd = rhs.lastTimestamp ?? rhs.sealedAt ?? rhs.createdAt
                if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
                return lhs.id < rhs.id
            }
    }

    static func retentionQueue(
        catalog: AtriaHistoricalArchiveCatalog,
        archiveDirectory: URL,
        committedChunkIDs: Set<String>,
        additionalCandidateIDs: Set<String> = [],
        policy: AtriaHistoricalRetentionPolicy = .production,
        now: Date,
        fileManager: FileManager = .default
    ) -> RetentionQueue {
        let liveChunks = catalog.chunks.filter { $0.state != .retired }
        let byID = Dictionary(uniqueKeysWithValues: liveChunks.map { ($0.id, $0) })
        let policyChunks = liveChunks.map { chunk in
            let earliest = chunk.firstTimestamp ?? chunk.createdAt
            let lifecycleEnd = chunk.sealedAt ?? now
            let latest = max(earliest, chunk.lastTimestamp ?? lifecycleEnd)
            return AtriaHistoricalRetentionPolicy.Chunk(
                identifier: chunk.id,
                url: archiveDirectory.appendingPathComponent(chunk.relativePath),
                byteCount: chunk.storedByteCount,
                earliestTimestamp: earliest,
                latestTimestamp: latest,
                isSealed: chunk.state == .sealed
            )
        }
        let plan = policy.plan(chunks: policyChunks, now: now)
        var uncommitted: [AtriaHistoricalArchiveCatalog.RawChunk] = []
        var committed: [String] = []
        var missing: [String] = []
        var provisional: [String] = []

        var orderedCandidateIDs = plan.candidates.map(\.chunk.identifier)
        let policyCandidateIDs = Set(orderedCandidateIDs)
        orderedCandidateIDs.append(contentsOf: liveChunks
            .filter {
                $0.state == .sealed
                    && additionalCandidateIDs.contains($0.id)
                    && !policyCandidateIDs.contains($0.id)
            }
            .sorted { lhs, rhs in
                let lhsEnd = lhs.lastTimestamp ?? lhs.sealedAt ?? lhs.createdAt
                let rhsEnd = rhs.lastTimestamp ?? rhs.sealedAt ?? rhs.createdAt
                if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
                return lhs.id < rhs.id
            }
            .map(\.id))

        for candidateID in orderedCandidateIDs {
            guard let chunk = byID[candidateID] else { continue }
            let sourceURL = archiveDirectory.appendingPathComponent(chunk.relativePath)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                missing.append(chunk.id)
                continue
            }
            if chunk.firstTimestamp == nil || chunk.lastTimestamp == nil {
                provisional.append(chunk.id)
            }
            if committedChunkIDs.contains(chunk.id) {
                committed.append(chunk.id)
            } else {
                uncommitted.append(chunk)
            }
        }

        return RetentionQueue(
            plan: plan,
            uncommittedCandidates: uncommitted,
            shadowCommittedCandidateIDs: committed,
            missingSourceCandidateIDs: missing,
            provisionalTimestampCandidateIDs: provisional
        )
    }

    static func commitFirst<Value>(
        candidates: [AtriaHistoricalArchiveCatalog.RawChunk],
        attempt: (AtriaHistoricalArchiveCatalog.RawChunk) throws -> Value
    ) -> Outcome<Value> {
        guard !candidates.isEmpty else { return .noCandidates }
        var failures: [Failure] = []
        failures.reserveCapacity(candidates.count)
        for chunk in candidates {
            do {
                return .committed(value: try attempt(chunk),
                                  precedingFailures: failures)
            } catch {
                failures.append(.init(chunkID: chunk.id,
                                      message: error.localizedDescription))
            }
        }
        return .allFailed(failures)
    }
}
