import Foundation

/// Makes shadow aggregation advance even when an older sealed raw chunk is
/// malformed. A failed chunk remains authoritative raw truth; it cannot starve
/// later chunks and it is never marked committed or retired.
struct AtriaHistoricalShadowCompactionCoordinator {
    /// Production retention selection, split from execution so the 7-day /
    /// 512-MiB policy cannot silently become dead configuration again.
    /// (Raw horizon moved 30 -> 7 days on 2026-09-14; insights are never
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

    /// Scene-background has ~25s. A 134 MB legacy JSONL cannot finish in that
    /// window; skip it and keep oldest-first among chunks that can.
    static func sceneBackgroundRetirementCandidates(
        _ candidates: [AtriaHistoricalArchiveCatalog.RawChunk],
        maximumByteCount: UInt64 = 8 * 1024 * 1024
    ) -> [AtriaHistoricalArchiveCatalog.RawChunk] {
        let finishable = candidates.filter {
            $0.storedByteCount > 0 && $0.storedByteCount <= maximumByteCount
        }
        return finishable
    }

    /// Raw JSONL that still cannot cut over (torn rows, missing identity)
    /// is remembered so sitting idle can drain later isolated shards.
    /// v2 retries files that only failed on duplicate history keys after
    /// first-wins collapse became legal.
    static let idleCutoverSkipChunkIDsKey = "atria.archiveCompaction.idleSkipChunkIDs.v2"

    static func idleCutoverSkipChunkIDs(
        defaults: UserDefaults = .standard
    ) -> Set<String> {
        Set(defaults.stringArray(forKey: idleCutoverSkipChunkIDsKey) ?? [])
    }

    static func recordIdleCutoverSkip(
        chunkID: String,
        defaults: UserDefaults = .standard
    ) {
        var ids = defaults.stringArray(forKey: idleCutoverSkipChunkIDsKey) ?? []
        guard !ids.contains(chunkID) else { return }
        ids.append(chunkID)
        defaults.set(ids, forKey: idleCutoverSkipChunkIDsKey)
    }

    static func skippingIdleCutoverSkips(
        _ candidates: [AtriaHistoricalArchiveCatalog.RawChunk],
        skippedIDs: Set<String>
    ) -> [AtriaHistoricalArchiveCatalog.RawChunk] {
        candidates.filter { !skippedIDs.contains($0.id) }
    }

    static func isPermanentIdleCutoverSkip(_ error: Error) -> Bool {
        if let shard = error as? AtriaHistoricalReplayIdentityShard.ShardError {
            switch shard {
            case .duplicateIdentity, .tornTrailingRow, .missingExactIdentity,
                 .rowCountMismatch, .invalidArtifact, .retainedArtifactTooLarge:
                return true
            case .sourceMissing, .sourceDigestMismatch:
                return false
            }
        }
        return String(describing: error).contains("duplicateIdentity")
    }

    static func orderedIdleRetirementCandidates(
        _ candidates: [AtriaHistoricalArchiveCatalog.RawChunk],
        preferLarge: Bool,
        limit: Int
    ) -> [AtriaHistoricalArchiveCatalog.RawChunk] {
        let ordered = candidates.sorted {
            preferLarge
                ? $0.storedByteCount > $1.storedByteCount
                : $0.storedByteCount < $1.storedByteCount
        }
        return Array(ordered.prefix(max(0, limit)))
    }

    /// Sitting Today tries cheap isolated ≤8 MB JSONL first so a 33 MB
    /// parse cannot starve the remaining small shards. Desk sitting may
    /// append one isolated 33 MB file only after those small candidates
    /// are gone.
    static func sittingIdleBuildCandidates(
        _ isolatedUnskipped: [AtriaHistoricalArchiveCatalog.RawChunk],
        smallChunkBytes: UInt64,
        includeOneLarge: Bool,
        smallLimit: Int = 8
    ) -> [AtriaHistoricalArchiveCatalog.RawChunk] {
        let small = orderedIdleRetirementCandidates(
            isolatedUnskipped.filter { $0.storedByteCount <= smallChunkBytes },
            preferLarge: false,
            limit: smallLimit
        )
        guard includeOneLarge else { return small }
        let large = orderedIdleRetirementCandidates(
            isolatedUnskipped.filter { $0.storedByteCount > smallChunkBytes },
            preferLarge: true,
            limit: 1
        )
        let smallIDs = Set(small.map(\.id))
        return small + large.filter { !smallIDs.contains($0.id) }
    }

    /// A 33 MB identity parse holds `already_running` for the whole sitting
    /// lease. Keep large JSONL off the queue while any isolated ≤8 MB file
    /// can still retire.
    static func shouldIncludeLargeIdleChunk(
        isolatedUnskipped: [AtriaHistoricalArchiveCatalog.RawChunk],
        smallChunkBytes: UInt64,
        preferLarge: Bool
    ) -> Bool {
        guard preferLarge else { return false }
        return !isolatedUnskipped.contains {
            $0.storedByteCount > 0 && $0.storedByteCount <= smallChunkBytes
        }
    }

    static func preferredIdleShadowCutoverChunkID(
        shadowed: [AtriaHistoricalArchiveCatalog.RawChunk],
        smallChunkBytes: UInt64,
        allowLarge: Bool
    ) -> String? {
        let smallShadowed = shadowed.filter {
            $0.storedByteCount > 0 && $0.storedByteCount <= smallChunkBytes
        }
        if let small = orderedIdleRetirementCandidates(
            smallShadowed,
            preferLarge: false,
            limit: 1
        ).first {
            return small.id
        }
        guard allowLarge else { return nil }
        return orderedIdleRetirementCandidates(
            shadowed,
            preferLarge: false,
            limit: 1
        ).first?.id
    }

    /// A 126 KB July shard that overlaps the 134 MB monolith fails shadow on
    /// this install and burns the sitting lease. Skip it; later isolated
    /// shards can still retire.
    static func skippingOversizedTimeOverlaps(
        _ candidates: [AtriaHistoricalArchiveCatalog.RawChunk],
        catalog: AtriaHistoricalArchiveCatalog,
        oversizedByteCount: UInt64
    ) -> [AtriaHistoricalArchiveCatalog.RawChunk] {
        let oversized = catalog.chunks.filter {
            $0.state == .sealed && $0.storedByteCount > oversizedByteCount
        }
        return candidates.filter { chunk in
            guard let first = chunk.firstTimestamp, let last = chunk.lastTimestamp else {
                return false
            }
            return !oversized.contains { sibling in
                guard sibling.id != chunk.id,
                      let siblingFirst = sibling.firstTimestamp,
                      let siblingLast = sibling.lastTimestamp else {
                    return false
                }
                return first <= siblingLast && last >= siblingFirst
            }
        }
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
