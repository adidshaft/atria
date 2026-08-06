import Darwin
import Foundation

/// Authoritative full-fidelity storage for sessions outside the hot window.
///
/// Each SavedSession is encoded and compressed independently, then addressed by
/// its decoded SHA-256. Publication is a single durable manifest rename. A hot
/// checkpoint therefore never allocates, encodes, or fingerprints the complete
/// cold history. A verified manifest is the durable authority for the current
/// full-fidelity generation; content-addressed chunks from superseded versions
/// of the same sessions are reclaimed only after every referenced replacement
/// has been decoded and verified.
struct AtriaFullFidelityColdSessionStore {
    static let directoryName = "atria-full-fidelity-cold-sessions-v1"
    static let manifestFilename = "manifest.json"
    static let invalidationFilename = "force-full-rewrite"

    /// Every store value is a lightweight facade over the same directory. Keep
    /// manifest mutation serialized across those values; otherwise a normal
    /// checkpoint can publish a stale manifest after the >90-day compactor has
    /// retired entries and pruned their chunks. The digest compare immediately
    /// before rename is still required for another process (or a future writer
    /// that does not participate in this registry).
    private static let mutationRegistryLock = NSLock()
    private static var mutationLocks: [String: NSRecursiveLock] = [:]

    struct Delta: Equatable, Sendable {
        let requiresFullRewrite: Bool
        let changedSessionIDs: Set<UUID>

        static let none = Delta(requiresFullRewrite: false, changedSessionIDs: [])
        static let full = Delta(requiresFullRewrite: true, changedSessionIDs: [])
    }

    struct Manifest: Codable, Equatable, Sendable {
        static let currentSchema = 1

        struct Entry: Codable, Equatable, Sendable {
            let sessionID: UUID
            let filename: String
            let compressedSHA256: String
            let decodedSHA256: String
            let compressedByteCount: UInt64
            let decodedByteCount: UInt64
            let start: Date
            let end: Date
        }

        let schema: Int
        let generatedAt: Date
        let coldSessionAgeDays: Int
        /// Ordered exactly like the former `[SavedSession]` cold array. Entries
        /// intentionally allow duplicate IDs to preserve legacy union semantics.
        let entries: [Entry]
    }

    enum Checkpoint: String, CaseIterable, Sendable {
        case chunksDurable
        case manifestTemporaryDurable
        case manifestPublished
        case manifestVerified
    }

    enum StoreError: Error, Equatable {
        case manifestMissing
        case unsupportedManifestSchema
        case invalidManifest
        case chunkMissing(String)
        case chunkDigestMismatch(String)
        case chunkDecodeFailed(String)
        case chunkSemanticMismatch(String)
        case chunkConflict(String)
        case sourceChanged(String)
    }

    struct PersistResult: Equatable, Sendable {
        enum Status: String, Equatable, Sendable {
            case unchanged
            case published
        }

        let status: Status
        let coldSessionCount: Int
        let encodedSessionCount: Int
        let largestEncodedSessionBytes: Int
        let manifestURL: URL
    }

    struct AppendResult: Equatable, Sendable {
        let storedSessionCount: Int
        let appendedSessionCount: Int
        let decodedByteCount: UInt64
        let largestDecodedSessionBytes: UInt64
    }

    struct BoundedAppendResult: Equatable, Sendable {
        let storedSessionCount: Int
        let eligibleSessionCount: Int
        let appendedSessionCount: Int
        let decodedByteCount: UInt64
        let largestDecodedSessionBytes: UInt64
        let wasTruncated: Bool
    }

    struct BoundedLoadPolicy: Equatable, Sendable {
        let earliestStart: Date
        let maximumSessionCount: Int
        let maximumDecodedBytes: UInt64

        var isValid: Bool {
            maximumSessionCount > 0 && maximumDecodedBytes > 0
        }
    }

    struct StreamingAdoptionPolicy: Equatable, Sendable {
        let earliestResidentStart: Date
        let maximumResidentSessionCount: Int
        let maximumResidentDecodedBytes: UInt64

        var isValid: Bool {
            maximumResidentSessionCount > 0 && maximumResidentDecodedBytes > 0
        }
    }

    struct StreamingAdoptionResult {
        let publicationStatus: PersistResult.Status
        let residentSessions: [SavedSession]
        let hotSource: AtriaColdSessionSourceScanner.Result?
        let legacyColdSource: AtriaColdSessionSourceScanner.Result?
        let archivedSessionCount: Int
        let encodedSessionCount: Int
        let residentDecodedByteCount: UInt64
        let largestTransientPayloadBytes: UInt64
        let residentWasTruncated: Bool
    }

    struct ManifestIdentity: Equatable, Sendable {
        let sha256: String
        let byteCount: UInt64
        let sessionCount: Int
    }

    let rootURL: URL
    private let fileManager: FileManager
    private let checkpoint: (Checkpoint) throws -> Void

    init(rootURL: URL,
         fileManager: FileManager = .default,
         checkpoint: @escaping (Checkpoint) throws -> Void = { _ in }) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.checkpoint = checkpoint
    }

    var chunksURL: URL { rootURL.appendingPathComponent("chunks", isDirectory: true) }
    var manifestURL: URL { rootURL.appendingPathComponent(Self.manifestFilename) }
    var invalidationURL: URL { rootURL.appendingPathComponent(Self.invalidationFilename) }

    static func rootURL(nextTo legacyColdURL: URL) -> URL {
        legacyColdURL.deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    func loadManifest() throws -> Manifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw StoreError.manifestMissing
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest: Manifest
        do { manifest = try Self.manifestDecoder().decode(Manifest.self, from: data) }
        catch { throw StoreError.invalidManifest }
        guard manifest.schema == Manifest.currentSchema else {
            throw StoreError.unsupportedManifestSchema
        }
        guard manifest.coldSessionAgeDays == SessionStore.coldSessionAgeDays,
              manifest.entries.allSatisfy(Self.validEntry) else {
            throw StoreError.invalidManifest
        }
        return manifest
    }

    func manifestIdentity() throws -> ManifestIdentity {
        let manifest = try loadManifest()
        let data = try Self.manifestEncoder().encode(manifest)
        return .init(sha256: AtriaColdSessionStore.sha256(data),
                     byteCount: UInt64(data.count),
                     sessionCount: manifest.entries.count)
    }

    /// Retires only entries older than the compact cutoff after independently
    /// re-reading a production-readable fact catalog tied to this exact manifest
    /// generation. Publication reuses the normal durable manifest transaction;
    /// content chunks become unlinkable only after the replacement manifest has
    /// round-tripped and every retained entry has verified.
    func retireCompactedEntries(
        sessionIDs requestedIDs: Set<UUID>,
        compactStore: AtriaColdSessionStore,
        cutoff: Date,
        generatedAt: Date = Date()
    ) throws -> PersistResult {
        try withManifestMutationLock {
            try retireCompactedEntriesLocked(
                sessionIDs: requestedIDs,
                compactStore: compactStore,
                cutoff: cutoff,
                generatedAt: generatedAt
            )
        }
    }

    private func retireCompactedEntriesLocked(
        sessionIDs requestedIDs: Set<UUID>,
        compactStore: AtriaColdSessionStore,
        cutoff: Date,
        generatedAt: Date
    ) throws -> PersistResult {
        let fullManifest = try loadManifest()
        let identity = try manifestIdentity()
        let compactCatalog = try compactStore.loadCatalog()
        guard compactCatalog.productionRawRetirementEnabled,
              compactCatalog.consumerReadiness == .productionReadable,
              compactCatalog.source.sha256 == identity.sha256,
              compactCatalog.source.byteCount == identity.byteCount,
              compactCatalog.source.decodedSessionCount == identity.sessionCount else {
            throw StoreError.invalidManifest
        }
        try compactStore.verifyCatalog(compactCatalog)

        let eligible = fullManifest.entries.filter {
            $0.start < cutoff && requestedIDs.contains($0.sessionID)
        }
        guard !eligible.isEmpty, eligible.count == requestedIDs.count else {
            throw StoreError.invalidManifest
        }
        let factsByID = try compactStore.facts(sessionIDs: requestedIDs)
        for entry in eligible {
            let session = try loadSession(entry: entry)
            let canonicalEncoder = JSONEncoder()
            canonicalEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let canonical = try canonicalEncoder.encode(session)
            guard let fact = factsByID[entry.sessionID],
                  fact.source.canonicalSHA256 == AtriaColdSessionStore.sha256(canonical),
                  fact.source.canonicalByteCount == canonical.count,
                  fact.source.start == entry.start,
                  fact.source.end == entry.end else {
                throw StoreError.chunkSemanticMismatch(entry.filename)
            }
        }
        return try persist(
            sessions: [],
            cutoff: cutoff,
            delta: .init(requiresFullRewrite: false, changedSessionIDs: requestedIDs),
            preservingUnspecifiedExistingSessions: true,
            generatedAt: generatedAt
        )
    }

    /// Streams the launch sources directly into immutable, content-addressed
    /// chunks while retaining only a bounded newest resident window. Every
    /// source session is archived, including recent hot sessions, so a bounded
    /// resident selection can never make an omitted full-fidelity object depend
    /// on a later rewrite of the monolithic source.
    ///
    /// Publication is transactional: source framing and a second source digest
    /// verification finish before the manifest rename. Malformed/truncated or
    /// concurrently replaced input therefore leaves the prior manifest (if any)
    /// authoritative. Newly written unreachable chunks are retained as raw
    /// evidence and are never pruned here.
    func adoptStreamingSources(hotURL: URL?,
                               legacyColdURL: URL?,
                               policy: StreamingAdoptionPolicy,
                               generatedAt: Date = Date()) throws -> StreamingAdoptionResult {
        try withManifestMutationLock {
            try adoptStreamingSourcesLocked(hotURL: hotURL,
                                            legacyColdURL: legacyColdURL,
                                            policy: policy,
                                            generatedAt: generatedAt)
        }
    }

    private func adoptStreamingSourcesLocked(
        hotURL: URL?,
        legacyColdURL: URL?,
        policy: StreamingAdoptionPolicy,
        generatedAt: Date
    ) throws -> StreamingAdoptionResult {
        guard policy.isValid else { throw StoreError.invalidManifest }
        try fileManager.createDirectory(at: chunksURL, withIntermediateDirectories: true)
        pruneAbandonedTemporaryFiles()

        let startingManifestDigest = try currentManifestDigest()
        let existing = fileManager.fileExists(atPath: manifestURL.path)
            ? try loadManifest()
            : nil
        struct Candidate {
            let session: SavedSession
            let decodedByteCount: UInt64
            let sourceOrder: Int
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(min(policy.maximumResidentSessionCount, 2_048))
        var candidateBytes: UInt64 = 0
        var residentWasTruncated = false
        var sourceOrder = 0
        var streamedEntries: [Manifest.Entry] = []
        var streamedIDs: Set<UUID> = []
        var hotIDs: Set<UUID> = []
        var encodedSessionCount = 0
        var largestTransientPayloadBytes: UInt64 = 0

        func retainCandidate(_ session: SavedSession, decodedByteCount: UInt64) {
            defer { sourceOrder += 1 }
            guard session.start >= policy.earliestResidentStart,
                  decodedByteCount <= policy.maximumResidentDecodedBytes else {
                if session.start >= policy.earliestResidentStart { residentWasTruncated = true }
                return
            }
            candidates.append(.init(session: session,
                                    decodedByteCount: decodedByteCount,
                                    sourceOrder: sourceOrder))
            candidateBytes += decodedByteCount
            candidates.sort { lhs, rhs in
                if lhs.session.start != rhs.session.start {
                    return lhs.session.start > rhs.session.start
                }
                return lhs.sourceOrder < rhs.sourceOrder
            }
            while candidates.count > policy.maximumResidentSessionCount
                    || candidateBytes > policy.maximumResidentDecodedBytes {
                let removed = candidates.removeLast()
                candidateBytes -= removed.decodedByteCount
                residentWasTruncated = true
            }
        }

        func archive(_ session: SavedSession, encoded: Data) throws {
            let decodedDigest = AtriaColdSessionStore.sha256(encoded)
            let compressed = try AtriaBackupCompression.compressedArchiveData(from: encoded)
            let transient = UInt64(encoded.count) + UInt64(compressed.count)
            largestTransientPayloadBytes = max(largestTransientPayloadBytes, transient)
            let compressedDigest = AtriaColdSessionStore.sha256(compressed)
            let filename = "session-\(decodedDigest).json.gz"
            let finalURL = chunksURL.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: finalURL.path) {
                let attributes = try fileManager.attributesOfItem(atPath: finalURL.path)
                let existingBytes = (attributes[.size] as? NSNumber)?.uint64Value
                guard existingBytes == UInt64(compressed.count),
                      try AtriaColdSessionStore.sha256(fileURL: finalURL) == compressedDigest else {
                    throw StoreError.chunkConflict(filename)
                }
            } else {
                let temporaryURL = chunksURL
                    .appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
                do {
                    try AtriaColdSessionStore.writeDurable(compressed, temporaryURL: temporaryURL)
                    guard rename(temporaryURL.path, finalURL.path) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    try AtriaColdSessionStore.synchronizeDirectory(chunksURL)
                } catch {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw error
                }
            }
            streamedEntries.append(.init(sessionID: session.id,
                                         filename: filename,
                                         compressedSHA256: compressedDigest,
                                         decodedSHA256: decodedDigest,
                                         compressedByteCount: UInt64(compressed.count),
                                         decodedByteCount: UInt64(encoded.count),
                                         start: session.start,
                                         end: session.end))
            streamedIDs.insert(session.id)
            encodedSessionCount += 1
        }

        func scan(_ url: URL, isHot: Bool) throws -> AtriaColdSessionSourceScanner.Result {
            try AtriaColdSessionSourceScanner.scanFrames(url: url) { session, encoded in
                if isHot {
                    hotIDs.insert(session.id)
                } else if hotIDs.contains(session.id) {
                    return
                }
                try archive(session, encoded: encoded)
                retainCandidate(session, decodedByteCount: UInt64(encoded.count))
            }
        }

        let hotSource = try hotURL.flatMap { url -> AtriaColdSessionSourceScanner.Result? in
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try scan(url, isHot: true)
        }
        let legacyColdSource = try legacyColdURL.flatMap { url -> AtriaColdSessionSourceScanner.Result? in
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try scan(url, isHot: false)
        }

        for (url, scanned) in [(hotURL, hotSource), (legacyColdURL, legacyColdSource)] {
            guard let url, let scanned else { continue }
            guard try AtriaColdSessionStore.sha256(fileURL: url) == scanned.sha256 else {
                throw StoreError.sourceChanged(url.lastPathComponent)
            }
        }
        try checkpoint(.chunksDurable)

        let preserved = existing?.entries.filter { !streamedIDs.contains($0.sessionID) } ?? []
        let entries = streamedEntries + preserved
        let status: PersistResult.Status
        if let existing, existing.entries == entries {
            status = .unchanged
        } else {
            let manifest = Manifest(schema: Manifest.currentSchema,
                                    generatedAt: generatedAt,
                                    coldSessionAgeDays: SessionStore.coldSessionAgeDays,
                                    entries: entries)
            let manifestData = try Self.manifestEncoder().encode(manifest)
            let temporaryURL = rootURL
                .appendingPathComponent(".manifest.\(UUID().uuidString).tmp")
            do {
                try AtriaColdSessionStore.writeDurable(manifestData, temporaryURL: temporaryURL)
                try checkpoint(.manifestTemporaryDurable)
                guard try currentManifestDigest() == startingManifestDigest else {
                    throw StoreError.sourceChanged(Self.manifestFilename)
                }
                guard rename(temporaryURL.path, manifestURL.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try AtriaColdSessionStore.synchronizeDirectory(rootURL)
                try checkpoint(.manifestPublished)
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
            let reloaded = try loadManifest()
            guard reloaded == manifest else { throw StoreError.invalidManifest }
            try verifyManifest(reloaded)
            try checkpoint(.manifestVerified)
            pruneUnreachableChunks(referencedBy: reloaded)
            status = .published
        }

        return .init(publicationStatus: status,
                     residentSessions: candidates.map(\.session),
                     hotSource: hotSource,
                     legacyColdSource: legacyColdSource,
                     archivedSessionCount: entries.count,
                     encodedSessionCount: encodedSessionCount,
                     residentDecodedByteCount: candidateBytes,
                     largestTransientPayloadBytes: largestTransientPayloadBytes,
                     residentWasTruncated: residentWasTruncated)
    }

    /// Publishes the exact cold subsequence of `sessions`. Existing entries are
    /// reused without loading or encoding their chunks unless their ID is in
    /// the caller's mutation delta. New boundary-crossing sessions are detected
    /// from manifest membership, so aging remains correct even with `.none`.
    func persist(sessions: [SavedSession],
                 cutoff: Date,
                 delta requestedDelta: Delta,
                 preservingUnspecifiedExistingSessions: Bool = false,
                 generatedAt: Date = Date()) throws -> PersistResult {
        try withManifestMutationLock {
            try persistLocked(sessions: sessions,
                              cutoff: cutoff,
                              delta: requestedDelta,
                              preservingUnspecifiedExistingSessions:
                                preservingUnspecifiedExistingSessions,
                              generatedAt: generatedAt)
        }
    }

    private func persistLocked(
        sessions: [SavedSession],
        cutoff: Date,
        delta requestedDelta: Delta,
        preservingUnspecifiedExistingSessions: Bool,
        generatedAt: Date
    ) throws -> PersistResult {
        try fileManager.createDirectory(at: chunksURL, withIntermediateDirectories: true)
        pruneAbandonedTemporaryFiles()

        let startingManifestDigest = try currentManifestDigest()
        let manifestExists = fileManager.fileExists(atPath: manifestURL.path)
        // A present-but-invalid manifest is authoritative metadata damage, not
        // a first-run condition. Never replace it from a potentially partial
        // in-memory load; retain every raw chunk and fail closed for recovery.
        let existing = manifestExists ? try loadManifest() : nil
        let forceMarkerExists = fileManager.fileExists(atPath: invalidationURL.path)
        let delta = Delta(
            requiresFullRewrite: requestedDelta.requiresFullRewrite || existing == nil || forceMarkerExists,
            changedSessionIDs: requestedDelta.changedSessionIDs
        )
        var reusableByID: [UUID: [Manifest.Entry]] = [:]
        if !delta.requiresFullRewrite, let existing {
            for entry in existing.entries {
                reusableByID[entry.sessionID, default: []].append(entry)
            }
        }
        var reusedOffsets: [UUID: Int] = [:]
        var entries: [Manifest.Entry] = []
        entries.reserveCapacity(existing?.entries.count ?? 0)
        var encodedSessionCount = 0
        var largestEncodedSessionBytes = 0

        for session in sessions where session.start < cutoff {
            let offset = reusedOffsets[session.id, default: 0]
            reusedOffsets[session.id] = offset + 1
            let reusable = reusableByID[session.id].flatMap { offset < $0.count ? $0[offset] : nil }
            if !delta.requiresFullRewrite,
               !delta.changedSessionIDs.contains(session.id),
               let reusable,
               reusable.start == session.start,
               reusable.end == session.end {
                entries.append(reusable)
                continue
            }

            let decoded = try JSONEncoder().encode(session)
            encodedSessionCount += 1
            largestEncodedSessionBytes = max(largestEncodedSessionBytes, decoded.count)
            let decodedDigest = AtriaColdSessionStore.sha256(decoded)
            let compressed = try AtriaBackupCompression.compressedArchiveData(from: decoded)
            let compressedDigest = AtriaColdSessionStore.sha256(compressed)
            let filename = "session-\(decodedDigest).json.gz"
            let finalURL = chunksURL.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: finalURL.path) {
                let attributes = try fileManager.attributesOfItem(atPath: finalURL.path)
                let existingBytes = (attributes[.size] as? NSNumber)?.uint64Value
                guard existingBytes == UInt64(compressed.count),
                      try AtriaColdSessionStore.sha256(fileURL: finalURL) == compressedDigest else {
                    throw StoreError.chunkConflict(filename)
                }
            } else {
                let temporaryURL = chunksURL
                    .appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
                do {
                    try AtriaColdSessionStore.writeDurable(compressed, temporaryURL: temporaryURL)
                    guard rename(temporaryURL.path, finalURL.path) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    try AtriaColdSessionStore.synchronizeDirectory(chunksURL)
                } catch {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw error
                }
            }
            entries.append(.init(sessionID: session.id,
                                 filename: filename,
                                 compressedSHA256: compressedDigest,
                                 decodedSHA256: decodedDigest,
                                 compressedByteCount: UInt64(compressed.count),
                                 decodedByteCount: UInt64(decoded.count),
                                 start: session.start,
                                 end: session.end))
        }

        // A bounded resident snapshot intentionally omits old cold sessions.
        // Preserve their already-published manifest entries without decoding
        // their chunks. IDs explicitly supplied by the caller replace every old
        // occurrence; changed IDs that are absent represent a deliberate delete
        // or a move back into the hot tier.
        if preservingUnspecifiedExistingSessions, let existing {
            let suppliedColdIDs = Set(sessions.lazy.filter { $0.start < cutoff }.map(\.id))
            let replacedIDs = suppliedColdIDs.union(delta.changedSessionIDs)
            if replacedIDs.isEmpty {
                entries = existing.entries
            } else {
                entries.append(contentsOf: existing.entries.filter {
                    !replacedIDs.contains($0.sessionID)
                })
                entries.sort { lhs, rhs in
                    if lhs.start != rhs.start { return lhs.start > rhs.start }
                    if lhs.end != rhs.end { return lhs.end > rhs.end }
                    if lhs.sessionID != rhs.sessionID {
                        return lhs.sessionID.uuidString < rhs.sessionID.uuidString
                    }
                    return lhs.filename < rhs.filename
                }
            }
        }
        try checkpoint(.chunksDurable)

        if let existing,
           existing.entries == entries,
           !forceMarkerExists {
            return .init(status: .unchanged,
                         coldSessionCount: entries.count,
                         encodedSessionCount: encodedSessionCount,
                         largestEncodedSessionBytes: largestEncodedSessionBytes,
                         manifestURL: manifestURL)
        }

        let manifest = Manifest(schema: Manifest.currentSchema,
                                generatedAt: generatedAt,
                                coldSessionAgeDays: SessionStore.coldSessionAgeDays,
                                entries: entries)
        let manifestData = try Self.manifestEncoder().encode(manifest)
        let temporaryURL = rootURL
            .appendingPathComponent(".manifest.\(UUID().uuidString).tmp")
        do {
            try AtriaColdSessionStore.writeDurable(manifestData, temporaryURL: temporaryURL)
            try checkpoint(.manifestTemporaryDurable)
            guard try currentManifestDigest() == startingManifestDigest else {
                throw StoreError.sourceChanged(Self.manifestFilename)
            }
            guard rename(temporaryURL.path, manifestURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try AtriaColdSessionStore.synchronizeDirectory(rootURL)
            try checkpoint(.manifestPublished)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        let reloaded = try loadManifest()
        guard reloaded == manifest else { throw StoreError.invalidManifest }
        try verifyManifest(reloaded)
        try checkpoint(.manifestVerified)
        pruneUnreachableChunks(referencedBy: reloaded)
        // The marker is metadata, never raw evidence, and is cleared only after
        // the replacement generation has been fully reloaded and verified.
        if forceMarkerExists && !preservingUnspecifiedExistingSessions {
            try? fileManager.removeItem(at: invalidationURL)
            try AtriaColdSessionStore.synchronizeDirectory(rootURL)
        }
        return .init(status: .published,
                     coldSessionCount: entries.count,
                     encodedSessionCount: encodedSessionCount,
                     largestEncodedSessionBytes: largestEncodedSessionBytes,
                     manifestURL: manifestURL)
    }

    private func withManifestMutationLock<T>(_ operation: () throws -> T) rethrows -> T {
        let key = rootURL.standardizedFileURL.path
        Self.mutationRegistryLock.lock()
        let lock: NSRecursiveLock
        if let existing = Self.mutationLocks[key] {
            lock = existing
        } else {
            let created = NSRecursiveLock()
            Self.mutationLocks[key] = created
            lock = created
        }
        Self.mutationRegistryLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func currentManifestDigest() throws -> String? {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        return try AtriaColdSessionStore.sha256(fileURL: manifestURL)
    }

    func verifyManifest(_ manifest: Manifest) throws {
        for entry in manifest.entries { _ = try loadSession(entry: entry) }
    }

    /// Reclaims only immutable chunks that are provably superseded by a fully
    /// reloaded and verified manifest. Unknown names, hidden temporary files,
    /// directories and symlinks are retained. Failure to enumerate or remove a
    /// candidate is non-fatal: the authoritative manifest and all referenced
    /// chunks are already durable, and a later publication can retry cleanup.
    private func pruneUnreachableChunks(referencedBy manifest: Manifest) {
        let referenced = Set(manifest.entries.map(\.filename))
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: chunksURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isDirectoryKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return }

        var removed = 0
        var reclaimedBytes: UInt64 = 0
        for candidate in candidates where !referenced.contains(candidate.lastPathComponent) {
            guard Self.isRecognizedChunkFilename(candidate.lastPathComponent),
                  candidate.deletingLastPathComponent().standardizedFileURL
                    == chunksURL.standardizedFileURL,
                  let values = try? candidate.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .isDirectoryKey,
                    .fileSizeKey
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.isDirectory != true else { continue }
            do {
                try fileManager.removeItem(at: candidate)
                removed += 1
                reclaimedBytes += UInt64(max(0, values.fileSize ?? 0))
            } catch {
                continue
            }
        }
        guard removed > 0 else { return }
        try? AtriaColdSessionStore.synchronizeDirectory(chunksURL)
        AtriaDebugLog(
            "ATRIADBG cold_session_store status=superseded_chunks_pruned removed=%d reclaimed_bytes=%llu referenced=%d authority=verified_manifest",
            removed,
            reclaimedBytes,
            referenced.count
        )
    }

    private static func isRecognizedChunkFilename(_ name: String) -> Bool {
        name.range(
            of: #"^session-[0-9a-f]{64}\.json\.gz$"#,
            options: .regularExpression
        ) != nil
    }

    /// A process death between durable temporary-file fsync and rename leaves a
    /// hidden file that no manifest can reference. The grammar is deliberately
    /// exact; cleanup runs before this store creates any new temporary, so it
    /// cannot race its own publication and unknown files remain untouched.
    private func pruneAbandonedTemporaryFiles() {
        let roots: [(URL, String)] = [
            (chunksURL, #"^\.session-[0-9a-f]{64}\.json\.gz\.[0-9A-Fa-f-]{36}\.tmp$"#),
            (rootURL, #"^\.manifest\.[0-9A-Fa-f-]{36}\.tmp$"#),
        ]
        var changedDirectories = Set<URL>()
        for (directory, pattern) in roots {
            guard let candidates = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ) else { continue }
            for candidate in candidates {
                guard candidate.lastPathComponent.range(of: pattern, options: .regularExpression) != nil,
                      candidate.deletingLastPathComponent().standardizedFileURL
                        == directory.standardizedFileURL,
                      let values = try? candidate.resourceValues(forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey,
                      ]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }
                if (try? fileManager.removeItem(at: candidate)) != nil {
                    changedDirectories.insert(directory)
                }
            }
        }
        for directory in changedDirectories {
            try? AtriaColdSessionStore.synchronizeDirectory(directory)
        }
    }

    func loadSession(entry: Manifest.Entry) throws -> SavedSession {
        let url = chunksURL.appendingPathComponent(entry.filename)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StoreError.chunkMissing(entry.filename)
        }
        let compressed = try Data(contentsOf: url)
        guard UInt64(compressed.count) == entry.compressedByteCount,
              AtriaColdSessionStore.sha256(compressed) == entry.compressedSHA256 else {
            throw StoreError.chunkDigestMismatch(entry.filename)
        }
        let decoded: Data
        do {
            decoded = try AtriaBackupCompression.archivePayloadData(from: compressed,
                                                                    fileExtension: "gz")
        } catch {
            throw StoreError.chunkDecodeFailed(entry.filename)
        }
        guard UInt64(decoded.count) == entry.decodedByteCount,
              AtriaColdSessionStore.sha256(decoded) == entry.decodedSHA256 else {
            throw StoreError.chunkDigestMismatch(entry.filename)
        }
        let session: SavedSession
        do { session = try JSONDecoder().decode(SavedSession.self, from: decoded) }
        catch { throw StoreError.chunkDecodeFailed(entry.filename) }
        guard session.id == entry.sessionID,
              session.start == entry.start,
              session.end == entry.end else {
            throw StoreError.chunkSemanticMismatch(entry.filename)
        }
        return session
    }

    /// Transactional bounded reader. At most one decoded session payload is in
    /// the store's temporary buffers, and a late corrupt chunk rolls back every
    /// append from this attempt.
    func appendFullFidelitySessions(to destination: inout [SavedSession],
                                    excludingIDs: Set<UUID>) throws -> AppendResult {
        let manifest = try loadManifest()
        let originalCount = destination.count
        var decodedBytes: UInt64 = 0
        var largestDecodedBytes: UInt64 = 0
        do {
            for entry in manifest.entries {
                let session = try loadSession(entry: entry)
                decodedBytes += entry.decodedByteCount
                largestDecodedBytes = max(largestDecodedBytes, entry.decodedByteCount)
                guard !excludingIDs.contains(session.id) else { continue }
                destination.append(session)
            }
        } catch {
            if destination.count > originalCount { destination.removeSubrange(originalCount...) }
            throw error
        }
        return .init(storedSessionCount: manifest.entries.count,
                     appendedSessionCount: destination.count - originalCount,
                     decodedByteCount: decodedBytes,
                     largestDecodedSessionBytes: largestDecodedBytes)
    }

    /// Loads only the newest full-fidelity sessions allowed by `policy`.
    /// Selection uses manifest metadata before opening a chunk, so both retained
    /// object count and decoded JSON bytes have hard ceilings. Every selected
    /// chunk still passes the same digest/decompression/semantic verification as
    /// an unbounded restore. A corrupt selected chunk rolls back the entire append.
    func appendBoundedFullFidelitySessions(
        to destination: inout [SavedSession],
        excludingIDs: Set<UUID>,
        policy: BoundedLoadPolicy
    ) throws -> BoundedAppendResult {
        guard policy.isValid else { throw StoreError.invalidManifest }
        let manifest = try loadManifest()
        let eligible = manifest.entries.enumerated()
            .filter { _, entry in
                entry.start >= policy.earliestStart && !excludingIDs.contains(entry.sessionID)
            }
            .sorted { lhs, rhs in
                if lhs.element.start != rhs.element.start {
                    return lhs.element.start > rhs.element.start
                }
                return lhs.offset < rhs.offset
            }

        var selected: [Manifest.Entry] = []
        selected.reserveCapacity(min(eligible.count, policy.maximumSessionCount))
        var selectedBytes: UInt64 = 0
        var wasTruncated = false
        for candidate in eligible.map(\.element) {
            guard selected.count < policy.maximumSessionCount else {
                wasTruncated = true
                break
            }
            let (nextBytes, overflow) = selectedBytes.addingReportingOverflow(candidate.decodedByteCount)
            guard !overflow, nextBytes <= policy.maximumDecodedBytes else {
                wasTruncated = true
                continue
            }
            selected.append(candidate)
            selectedBytes = nextBytes
        }
        if selected.count < eligible.count { wasTruncated = true }

        let originalCount = destination.count
        var decodedBytes: UInt64 = 0
        var largestDecodedBytes: UInt64 = 0
        do {
            for entry in selected {
                let session = try loadSession(entry: entry)
                destination.append(session)
                decodedBytes += entry.decodedByteCount
                largestDecodedBytes = max(largestDecodedBytes, entry.decodedByteCount)
            }
        } catch {
            if destination.count > originalCount { destination.removeSubrange(originalCount...) }
            throw error
        }
        return .init(storedSessionCount: manifest.entries.count,
                     eligibleSessionCount: eligible.count,
                     appendedSessionCount: destination.count - originalCount,
                     decodedByteCount: decodedBytes,
                     largestDecodedSessionBytes: largestDecodedBytes,
                     wasTruncated: wasTruncated)
    }

    /// On-demand full-fidelity range access for consumers that need an older
    /// detail view without promoting lifetime history into `SessionStore.sessions`.
    func sessions(overlapping interval: DateInterval,
                  maximumSessionCount: Int,
                  maximumDecodedBytes: UInt64) throws -> [SavedSession] {
        guard interval.duration > 0,
              maximumSessionCount > 0,
              maximumDecodedBytes > 0 else { throw StoreError.invalidManifest }
        let manifest = try loadManifest()
        let matches = manifest.entries.enumerated()
            .filter { _, entry in entry.end > interval.start && entry.start < interval.end }
            .sorted { lhs, rhs in
                if lhs.element.start != rhs.element.start {
                    return lhs.element.start > rhs.element.start
                }
                return lhs.offset < rhs.offset
            }
        var result: [SavedSession] = []
        result.reserveCapacity(min(matches.count, maximumSessionCount))
        var decodedBytes: UInt64 = 0
        for entry in matches.map(\.element) {
            guard result.count < maximumSessionCount else { break }
            let (nextBytes, overflow) = decodedBytes.addingReportingOverflow(entry.decodedByteCount)
            guard !overflow, nextBytes <= maximumDecodedBytes else { continue }
            result.append(try loadSession(entry: entry))
            decodedBytes = nextBytes
        }
        return result
    }

    func requestFullRewrite() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: invalidationURL.path) {
            try AtriaColdSessionStore.writeDurable(Data("pending\n".utf8),
                                                   temporaryURL: invalidationURL)
            try AtriaColdSessionStore.synchronizeDirectory(rootURL)
        }
    }

    private static func validEntry(_ entry: Manifest.Entry) -> Bool {
        let expectedFilename = "session-\(entry.decodedSHA256).json.gz"
        return entry.filename == expectedFilename
            && entry.start <= entry.end
            && entry.compressedByteCount > 0
            && entry.decodedByteCount > 0
            && isSHA256(entry.compressedSHA256)
            && isSHA256(entry.decodedSHA256)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "0123456789abcdef").contains
        )
    }

    private static func manifestEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func manifestDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
