import Foundation

/// Exact, read-only accounting for the historical archive tree.
///
/// High-volume storage is intentionally narrower than total app storage:
/// immutable raw chunks and exact replay evidence are hard-cap inputs. Typed
/// daily/epoch projections are reported separately because they grow at a
/// small, time-bounded rate and are the long-term product history.
struct AtriaHistoricalHighVolumeStorageAccounting {
    enum Category: String, CaseIterable, Equatable, Sendable {
        case raw
        case replayEvidence = "replay_evidence"
        case compactLongTermTyped = "compact_long_term_typed"
        case otherManaged = "other_managed"
    }

    struct CategoryTotal: Equatable, Sendable {
        let fileCount: Int
        let byteCount: UInt64
    }

    struct Snapshot: Equatable, Sendable {
        let rootURL: URL
        let totals: [Category: CategoryTotal]
        let scannedFileCount: Int
        let scannedByteCount: UInt64

        var rawBytes: UInt64 { totals[.raw]?.byteCount ?? 0 }
        var replayEvidenceBytes: UInt64 {
            totals[.replayEvidence]?.byteCount ?? 0
        }
        var highVolumeBytes: UInt64 {
            // Construction has already checked the grand total for overflow,
            // so this narrower sum cannot overflow.
            rawBytes + replayEvidenceBytes
        }
        var compactLongTermTypedBytes: UInt64 {
            totals[.compactLongTermTyped]?.byteCount ?? 0
        }
        var otherManagedBytes: UInt64 {
            totals[.otherManaged]?.byteCount ?? 0
        }
    }

    struct FileFact: Equatable, Sendable {
        let relativePath: String
        let byteCount: UInt64
        let isSymbolicLink: Bool
    }

    enum AccountingError: Error, Equatable {
        case rootUnavailable
        case rootIsSymbolicLink
        case unsafeRawRelativePath(String)
        case symbolicLinkDetected(String)
        case enumerationFailed(String)
        case catalogRawMissing(String)
        case byteCountOverflow
        case fileCountOverflow
    }

    private static let replayDirectoryPrefix = "retired-replay-v1/"
    // This is the live, exact 14-day replay-deduplication index. Its entries
    // contain the complete frame identity, so on a continuously worn strap it
    // is a high-volume store in its own right (the on-device index is already
    // tens of MiB). Treating it as generic managed storage made the advertised
    // raw + replay ceiling undercount the very evidence required to safely
    // reject a replay. It cannot be deleted independently of its 14-day
    // horizon, but including it here correctly makes the raw-retirement
    // planner reclaim sealed raw earlier when necessary.
    private static let liveReplayIdentityIndexFilename = "historical-archive.identity.jsonl"
    // Rebuilding the live identity index uses an atomic same-directory
    // replacement.  While that replacement is in progress, the temporary is
    // a second full copy of exact replay evidence.  Count only this narrowly
    // identified file in the high-volume envelope; treating every `.tmp` as
    // retained evidence would let unrelated short-lived work distort the raw
    // retirement plan.
    private static let liveReplayIdentityIndexTemporaryPrefix =
        ".\(liveReplayIdentityIndexFilename)."
    private static let compactDirectoryPrefixes = [
        "aggregates-v2/",
        "retention-manifests-v2/",
        "drain-completions-v1/",
        "long-term-rollups-v1/",
    ]

    let archiveRoot: URL
    let catalogRawRelativePaths: Set<String>
    let fileManager: FileManager

    init(
        archiveRoot: URL,
        catalogRawRelativePaths: Set<String>,
        fileManager: FileManager = .default
    ) throws {
        for path in catalogRawRelativePaths where !Self.safeRelativePath(path) {
            throw AccountingError.unsafeRawRelativePath(path)
        }
        self.archiveRoot = archiveRoot.standardizedFileURL
        self.catalogRawRelativePaths = catalogRawRelativePaths
        self.fileManager = fileManager
    }

    func measure() throws -> Snapshot {
        let rootValues: URLResourceValues
        do {
            rootValues = try archiveRoot.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
        } catch {
            throw AccountingError.rootUnavailable
        }
        guard rootValues.isSymbolicLink != true else {
            throw AccountingError.rootIsSymbolicLink
        }
        guard rootValues.isDirectory == true else {
            throw AccountingError.rootUnavailable
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        var enumerationFailure: String?
        guard let enumerator = fileManager.enumerator(
            at: archiveRoot,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, _ in
                enumerationFailure = self.relativePath(for: url)
                return false
            }
        ) else {
            throw AccountingError.enumerationFailed(".")
        }
        var facts: [FileFact] = []
        while let url = enumerator.nextObject() as? URL {
            let relative = relativePath(for: url)
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                throw AccountingError.enumerationFailed(relative)
            }
            if values.isSymbolicLink == true {
                throw AccountingError.symbolicLinkDetected(relative)
            }
            guard values.isRegularFile == true else { continue }
            guard let size = values.fileSize, size >= 0 else {
                throw AccountingError.enumerationFailed(relative)
            }
            facts.append(.init(relativePath: relative,
                               byteCount: UInt64(size),
                               isSymbolicLink: false))
        }
        if let enumerationFailure {
            throw AccountingError.enumerationFailed(enumerationFailure)
        }
        return try Self.summarize(rootURL: archiveRoot,
                                  facts: facts,
                                  catalogRawRelativePaths: catalogRawRelativePaths)
    }

    static func summarize(
        rootURL: URL,
        facts: [FileFact],
        catalogRawRelativePaths: Set<String>
    ) throws -> Snapshot {
        var seenRaw = Set<String>()
        var counts: [Category: Int] = [:]
        var bytes: [Category: UInt64] = [:]
        var totalFiles = 0
        var totalBytes: UInt64 = 0
        for fact in facts {
            guard safeRelativePath(fact.relativePath) else {
                throw AccountingError.enumerationFailed(fact.relativePath)
            }
            guard !fact.isSymbolicLink else {
                throw AccountingError.symbolicLinkDetected(fact.relativePath)
            }
            let category = category(for: fact.relativePath,
                                    catalogRawRelativePaths: catalogRawRelativePaths)
            if category == .raw { seenRaw.insert(fact.relativePath) }
            guard totalFiles < Int.max else { throw AccountingError.fileCountOverflow }
            totalFiles += 1
            let categoryCount = counts[category, default: 0]
            guard categoryCount < Int.max else {
                throw AccountingError.fileCountOverflow
            }
            counts[category] = categoryCount + 1
            bytes[category] = try adding(bytes[category, default: 0], fact.byteCount)
            totalBytes = try adding(totalBytes, fact.byteCount)
        }
        guard seenRaw == catalogRawRelativePaths else {
            let missing = catalogRawRelativePaths.subtracting(seenRaw).sorted().first ?? "unknown"
            throw AccountingError.catalogRawMissing(missing)
        }
        let totals = Dictionary(uniqueKeysWithValues: Category.allCases.map { category in
            (category, CategoryTotal(fileCount: counts[category, default: 0],
                                     byteCount: bytes[category, default: 0]))
        })
        return .init(rootURL: rootURL.standardizedFileURL,
                     totals: totals,
                     scannedFileCount: totalFiles,
                     scannedByteCount: totalBytes)
    }

    private static func category(
        for relativePath: String,
        catalogRawRelativePaths: Set<String>
    ) -> Category {
        if catalogRawRelativePaths.contains(relativePath) { return .raw }
        if relativePath == liveReplayIdentityIndexFilename {
            return .replayEvidence
        }
        if isLiveReplayIdentityIndexTemporary(relativePath) {
            return .replayEvidence
        }
        if relativePath.hasPrefix(replayDirectoryPrefix) {
            // Includes SQLite, -wal and -shm without filename assumptions.
            return .replayEvidence
        }
        let filename = URL(fileURLWithPath: relativePath).lastPathComponent
        if relativePath.hasPrefix("consumer-receipts-v1/")
            && filename.contains("replay_identity") {
            return .replayEvidence
        }
        if relativePath.hasPrefix("canonical-consumers-v1/destinations/")
            && filename.contains("replay_identity") {
            return .replayEvidence
        }
        if compactDirectoryPrefixes.contains(where: relativePath.hasPrefix)
            || relativePath.hasPrefix("consumer-receipts-v1/")
            || relativePath.hasPrefix("canonical-consumers-v1/") {
            return .compactLongTermTyped
        }
        return .otherManaged
    }

    private static func isLiveReplayIdentityIndexTemporary(_ relativePath: String) -> Bool {
        // `rebuildDerivedIndex` creates this exact sibling form before an
        // atomic replace.  It is deliberately root-only: no nested payload
        // gets to claim replay-evidence accounting merely by sharing a name.
        !relativePath.contains("/")
            && relativePath.hasPrefix(liveReplayIdentityIndexTemporaryPrefix)
            && relativePath.hasSuffix(".tmp")
            && relativePath.count > liveReplayIdentityIndexTemporaryPrefix.count + ".tmp".count
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw AccountingError.byteCountOverflow }
        return result.partialValue
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            return false
        }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = archiveRoot.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

/// Pure advisory planner. It has no filesystem or catalog mutation authority.
struct AtriaHistoricalHighVolumeStoragePlanner: Equatable, Sendable {
    static let production = Self(maximumHighVolumeBytes: 512 * 1_024 * 1_024)

    struct Chunk: Equatable, Sendable {
        let identifier: String
        let rawByteCount: UInt64
        let latestTimestamp: Date
        let isSealed: Bool
        /// Exact additional high-volume bytes that would exist after the
        /// retirement evidence is published. Nil means evidence is incomplete.
        let additionalRetainedEvidenceBytes: UInt64?
    }

    struct Selection: Equatable, Sendable {
        let chunk: Chunk
        let reclaimableBytes: UInt64
        let projectedHighVolumeBytes: UInt64
    }

    enum State: String, Equatable, Sendable {
        case capSatisfied = "cap_satisfied"
        case progressOnly = "net_decreasing_progress_only"
        case protectedActiveException = "protected_active_exception"
        case blocked = "blocked"
    }

    struct Plan: Equatable, Sendable {
        let state: State
        let selections: [Selection]
        let highVolumeBytesBefore: UInt64
        let projectedHighVolumeBytes: UInt64
        let maximumHighVolumeBytes: UInt64
        let compactLongTermTypedBytes: UInt64
        let protectedActiveBytes: UInt64
        let remainingOverageBytes: UInt64
        let protectedActiveOverageBytes: UInt64
        let unresolvedNonActiveOverageBytes: UInt64

        var capSatisfied: Bool { projectedHighVolumeBytes <= maximumHighVolumeBytes }
        var makesNetDecreasingProgress: Bool { !selections.isEmpty }
    }

    enum PlannerError: Error, Equatable {
        case duplicateChunkIdentifier
        case rawAccountingMismatch(expected: UInt64, actual: UInt64)
        case byteCountOverflow
    }

    let maximumHighVolumeBytes: UInt64

    init(maximumHighVolumeBytes: UInt64) {
        precondition(maximumHighVolumeBytes > 0)
        self.maximumHighVolumeBytes = maximumHighVolumeBytes
    }

    func plan(
        accounting: AtriaHistoricalHighVolumeStorageAccounting.Snapshot,
        chunks: [Chunk]
    ) throws -> Plan {
        guard Set(chunks.map(\.identifier)).count == chunks.count else {
            throw PlannerError.duplicateChunkIdentifier
        }
        let catalogRaw = try chunks.reduce(UInt64(0)) { total, chunk in
            let sum = total.addingReportingOverflow(chunk.rawByteCount)
            guard !sum.overflow else { throw PlannerError.byteCountOverflow }
            return sum.partialValue
        }
        guard catalogRaw == accounting.rawBytes else {
            throw PlannerError.rawAccountingMismatch(expected: catalogRaw,
                                                      actual: accounting.rawBytes)
        }
        let protectedActive = try chunks.filter { !$0.isSealed }
            .reduce(UInt64(0)) { total, chunk in
                let sum = total.addingReportingOverflow(chunk.rawByteCount)
                guard !sum.overflow else { throw PlannerError.byteCountOverflow }
                return sum.partialValue
            }
        var projected = accounting.highVolumeBytes
        var selections: [Selection] = []
        if projected > maximumHighVolumeBytes {
            let eligible = chunks.filter { chunk in
                guard chunk.isSealed,
                      let retained = chunk.additionalRetainedEvidenceBytes else {
                    return false
                }
                return retained < chunk.rawByteCount
            }.sorted {
                if $0.latestTimestamp != $1.latestTimestamp {
                    return $0.latestTimestamp < $1.latestTimestamp
                }
                return $0.identifier < $1.identifier
            }
            for chunk in eligible where projected > maximumHighVolumeBytes {
                let retained = chunk.additionalRetainedEvidenceBytes!
                let reclaimed = chunk.rawByteCount - retained
                projected -= min(projected, reclaimed)
                selections.append(.init(chunk: chunk,
                                        reclaimableBytes: reclaimed,
                                        projectedHighVolumeBytes: projected))
            }
        }
        let overage = projected > maximumHighVolumeBytes
            ? projected - maximumHighVolumeBytes : 0
        let protectedOverage = min(overage, protectedActive)
        let unresolved = overage - protectedOverage
        let state: State
        if overage == 0 {
            state = .capSatisfied
        } else if unresolved == 0 {
            state = .protectedActiveException
        } else if !selections.isEmpty {
            state = .progressOnly
        } else {
            state = .blocked
        }
        return .init(state: state,
                     selections: selections,
                     highVolumeBytesBefore: accounting.highVolumeBytes,
                     projectedHighVolumeBytes: projected,
                     maximumHighVolumeBytes: maximumHighVolumeBytes,
                     compactLongTermTypedBytes: accounting.compactLongTermTypedBytes,
                     protectedActiveBytes: protectedActive,
                     remainingOverageBytes: overage,
                     protectedActiveOverageBytes: protectedOverage,
                     unresolvedNonActiveOverageBytes: unresolved)
    }
}

/// Read-only production bridge used by historical maintenance diagnostics.
/// It can inspect catalog/application proof state and return an advisory plan,
/// but owns no transaction, unlink, replay cleanup, or catalog mutation API.
struct AtriaHistoricalHighVolumeDiagnosticsCoordinator {
    struct Report: Equatable, Sendable {
        let accounting: AtriaHistoricalHighVolumeStorageAccounting.Snapshot
        let plan: AtriaHistoricalHighVolumeStoragePlanner.Plan
        let verifiedReplayEvidenceChunkCount: Int
        let incompleteReplayEvidenceChunkCount: Int
    }

    static func evaluate(
        archiveRoot: URL,
        catalog: AtriaHistoricalArchiveCatalog,
        planner: AtriaHistoricalHighVolumeStoragePlanner = .production,
        fileManager: FileManager = .default
    ) throws -> Report {
        let retainedRaw = catalog.chunks.filter { $0.state != .retired }
        // A freshly rotated active chunk is registered in the catalog before its
        // first append materializes a file on disk. Accounting mirrors
        // snapshotVerifiedAgainstFiles by not demanding a raw file for an active
        // chunk that still records zero bytes and has no file yet; any chunk with
        // recorded bytes whose file is missing continues to fail closed.
        var rawPaths = Set<String>()
        for chunk in retainedRaw {
            if chunk.state == .active, chunk.storedByteCount == 0 {
                let url = archiveRoot.appendingPathComponent(chunk.relativePath)
                if !fileManager.fileExists(atPath: url.path) { continue }
            }
            rawPaths.insert(chunk.relativePath)
        }
        // During the crash-safe storage substitution window both the original
        // JSONL and compressed artifact are retained raw evidence. Count both
        // until a later catalog-authorized cleanup actually removes the source.
        for chunk in retainedRaw {
            guard let sourcePath = chunk.compressedStorage?.sourceRelativePath else { continue }
            let sourceURL = archiveRoot.appendingPathComponent(sourcePath)
            if fileManager.fileExists(atPath: sourceURL.path) { rawPaths.insert(sourcePath) }
        }
        let accounting = try AtriaHistoricalHighVolumeStorageAccounting(
            archiveRoot: archiveRoot,
            catalogRawRelativePaths: rawPaths,
            fileManager: fileManager
        ).measure()
        let adapter = canonicalAdapter(archiveRoot: archiveRoot,
                                       fileManager: fileManager)
        var verifiedCount = 0
        var incompleteCount = 0
        let chunks = try retainedRaw.map { chunk -> AtriaHistoricalHighVolumeStoragePlanner.Chunk in
            let verified: Bool
            if chunk.state == .sealed {
                verified = verifiedReplayEvidence(
                    for: chunk,
                    adapter: adapter
                )
                if verified { verifiedCount += 1 } else { incompleteCount += 1 }
            } else {
                verified = false
            }
            return .init(
                identifier: chunk.id,
                rawByteCount: try managedRawByteCount(
                    for: chunk,
                    archiveRoot: archiveRoot,
                    fileManager: fileManager
                ),
                latestTimestamp: chunk.lastTimestamp ?? chunk.sealedAt ?? chunk.createdAt,
                isSealed: chunk.state == .sealed,
                // A verified canonical replay artifact is already present in
                // the recursively measured tree; retirement would add zero
                // further replay bytes at this read-only planning boundary.
                additionalRetainedEvidenceBytes: verified ? 0 : nil
            )
        }
        return .init(accounting: accounting,
                     plan: try planner.plan(accounting: accounting, chunks: chunks),
                     verifiedReplayEvidenceChunkCount: verifiedCount,
                     incompleteReplayEvidenceChunkCount: incompleteCount)
    }

    private static func managedRawByteCount(
        for chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        archiveRoot: URL,
        fileManager: FileManager
    ) throws -> UInt64 {
        var total = chunk.storedByteCount
        guard let sourcePath = chunk.compressedStorage?.sourceRelativePath else { return total }
        let sourceURL = archiveRoot.appendingPathComponent(sourcePath)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return total }
        let sourceBytes = ((try fileManager.attributesOfItem(atPath: sourceURL.path)[.size])
            as? NSNumber)?.uint64Value ?? 0
        let sum = total.addingReportingOverflow(sourceBytes)
        guard !sum.overflow else {
            throw AtriaHistoricalHighVolumeStoragePlanner.PlannerError.byteCountOverflow
        }
        total = sum.partialValue
        return total
    }

    private static func verifiedReplayEvidence(
        for chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        adapter: AtriaHistoricalCanonicalConsumerApplicationAdapter
    ) -> Bool {
        guard let digest = chunk.contentSHA256,
              let first = chunk.firstTimestamp,
              let last = chunk.lastTimestamp,
              let current = try? adapter.loadCurrent(sourceChunkID: chunk.id),
              current.verificationIdentity.source.rawSHA256 == digest,
              current.verificationIdentity.source.firstTimestamp == first,
              current.verificationIdentity.source.lastTimestamp == last,
              (try? adapter.validatedCurrent(
                identity: current.verificationIdentity
              )) != nil else {
            return false
        }
        return true
    }

    private static func canonicalAdapter(
        archiveRoot: URL,
        fileManager: FileManager
    ) -> AtriaHistoricalCanonicalConsumerApplicationAdapter {
        let root = archiveRoot.appendingPathComponent(
            "canonical-consumers-v1", isDirectory: true
        )
        return .init(
            destinationStore: .init(
                directoryURL: root.appendingPathComponent(
                    "destinations", isDirectory: true
                ),
                fileManager: fileManager
            ),
            proofDirectoryURL: root.appendingPathComponent(
                "application-proofs", isDirectory: true
            )
        )
    }
}
