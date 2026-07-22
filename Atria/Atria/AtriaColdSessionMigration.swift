import Darwin
import Foundation

/// Non-destructive migration from the monolithic sessions-cold.json source to
/// immutable daily compact-fact chunks. Publication never removes or rewrites
/// the source. Raw retirement has no production code path in this version.
struct AtriaColdSessionMigration {
    enum Checkpoint: String, CaseIterable, Sendable {
        case chunksDurable
        case catalogTemporaryDurable
        case sourceReverified
        case catalogPublished
        case catalogVerified
        case unreachableChunksPruned
    }

    enum MigrationError: Error, Equatable {
        case sourceMissing
        case sourceNotRegularFile
        case sourceDecodeFailed
        case sourceChangedDuringMigration
        case chunkConflict(String)
        case verificationFailed
        case verificationDetail(String)
        case rawRetirementDisabled
    }

    struct Result: Equatable, Sendable {
        enum Status: String, Equatable, Sendable {
            case published
            case unchanged
        }

        let status: Status
        let catalogURL: URL
        let decodedSessionCount: Int
        let eligibleSessionCount: Int
        let chunkCount: Int
        let compressedBytes: UInt64
        let sourceBytes: UInt64
        let sourceDeleted: Bool
    }

    private let fileManager: FileManager
    private let checkpoint: (Checkpoint) throws -> Void

    init(fileManager: FileManager = .default,
         checkpoint: @escaping (Checkpoint) throws -> Void = { _ in }) {
        self.fileManager = fileManager
        self.checkpoint = checkpoint
    }

    func migrate(sourceURL: URL,
                 destinationRootURL: URL,
                 now: Date = Date(),
                 context: AtriaColdSessionFactBuilder.Context = .init()) throws -> Result {
        guard fileManager.fileExists(atPath: sourceURL.path) else { throw MigrationError.sourceMissing }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw MigrationError.sourceNotRegularFile }
        let freshAttributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        guard let freshSourceSize = (freshAttributes[.size] as? NSNumber)?.uint64Value else {
            throw MigrationError.sourceChangedDuringMigration
        }
        let cutoff = AtriaColdSessionRetentionPolicy.compactCutoff(now: now)
        var decodedIDs: Set<UUID> = []
        var groupedFacts: [String: [AtriaColdSessionFact]] = [:]
        var expectedFacts: [UUID: String] = [:]
        let scan: AtriaColdSessionSourceScanner.Result
        do {
            scan = try AtriaColdSessionSourceScanner.scan(url: sourceURL) { session in
                guard decodedIDs.insert(session.id).inserted else {
                    throw MigrationError.verificationDetail("duplicate_session_id")
                }
                guard session.start < cutoff else { return }
                let fact = try AtriaColdSessionFactBuilder.build(session: session,
                                                                 context: context,
                                                                 createdAt: session.end)
                guard expectedFacts.updateValue(fact.source.canonicalSHA256,
                                                forKey: fact.source.sessionID) == nil else {
                    throw MigrationError.verificationDetail("duplicate_eligible_session_id")
                }
                groupedFacts[AtriaColdSessionChunk.utcDay(session.start), default: []].append(fact)
            }
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError.sourceDecodeFailed
        }
        let sourceDigest = scan.sha256
        let sourceBytes = scan.byteCount
        guard sourceBytes == freshSourceSize else {
            throw MigrationError.sourceChangedDuringMigration
        }

        let store = AtriaColdSessionStore(rootURL: destinationRootURL, fileManager: fileManager)
        try fileManager.createDirectory(at: store.chunksURL, withIntermediateDirectories: true)
        var entries: [AtriaColdSessionCatalog.Entry] = []
        for day in groupedFacts.keys.sorted() {
            let facts = groupedFacts[day]!.sorted { lhs, rhs in
                lhs.source.start == rhs.source.start
                    ? lhs.source.sessionID.uuidString < rhs.source.sessionID.uuidString
                    : lhs.source.start < rhs.source.start
            }
            let chunk = AtriaColdSessionChunk(schema: AtriaColdSessionChunk.currentSchema,
                                              civilUTCDate: day,
                                              createdAt: facts.map(\.source.end).max() ?? now,
                                              facts: facts)
            try chunk.validate()
            let decodedChunk = try AtriaColdSessionStore.encoder().encode(chunk)
            let decodedDigest = AtriaColdSessionStore.sha256(decodedChunk)
            let compressed = try AtriaBackupCompression.compressedArchiveData(from: decodedChunk)
            let compressedDigest = AtriaColdSessionStore.sha256(compressed)
            let filename = "day-\(day)-\(decodedDigest.prefix(16)).json.gz"
            let finalURL = store.chunksURL.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: finalURL.path) {
                let existing = try Data(contentsOf: finalURL)
                guard existing.count == compressed.count,
                      AtriaColdSessionStore.sha256(existing) == compressedDigest else {
                    throw MigrationError.chunkConflict(filename)
                }
            } else {
                let temporaryURL = store.chunksURL
                    .appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
                do {
                    try AtriaColdSessionStore.writeDurable(compressed, temporaryURL: temporaryURL)
                    guard rename(temporaryURL.path, finalURL.path) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    try AtriaColdSessionStore.synchronizeDirectory(store.chunksURL)
                } catch {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw error
                }
            }
            entries.append(.init(civilUTCDate: day,
                                 filename: filename,
                                 compressedSHA256: compressedDigest,
                                 decodedSHA256: decodedDigest,
                                 compressedByteCount: UInt64(compressed.count),
                                 decodedByteCount: UInt64(decodedChunk.count),
                                 sessionCount: facts.count,
                                 firstSessionStart: facts.map(\.source.start).min()!,
                                 lastSessionEnd: facts.map(\.source.end).max()!))
        }
        try checkpoint(.chunksDurable)

        let catalog = AtriaColdSessionCatalog(
            schema: AtriaColdSessionCatalog.currentSchema,
            generatedAt: now,
            fullFidelityHotDays: AtriaColdSessionRetentionPolicy.hotFullFidelityDays,
            fullFidelityDecodedColdDays: AtriaColdSessionRetentionPolicy.decodedColdFullFidelityDays,
            source: .init(filename: sourceURL.lastPathComponent,
                          sha256: sourceDigest,
                          byteCount: sourceBytes,
                          decodedSessionCount: scan.sessionCount,
                          compactEligibleSessionCount: expectedFacts.count),
            entries: entries,
            consumerReadiness: .shadowOnly,
            productionRawRetirementEnabled: false
        )
        let catalogData = try AtriaColdSessionStore.encoder().encode(catalog)
        if let existing = try? store.loadCatalog(),
           existing.source == catalog.source,
           existing.entries == catalog.entries,
           existing.consumerReadiness == catalog.consumerReadiness,
           existing.productionRawRetirementEnabled == catalog.productionRawRetirementEnabled {
            try store.verifyCatalog(existing, expectedFactsByID: expectedFacts)
            try pruneUnreachableRecognizedChunks(store: store, catalog: existing)
            return result(status: .unchanged,
                          catalog: existing,
                          catalogURL: store.catalogURL,
                          sourceBytes: sourceBytes)
        }

        let temporaryCatalogURL = destinationRootURL
            .appendingPathComponent(".catalog.\(UUID().uuidString).tmp")
        do {
            try AtriaColdSessionStore.writeDurable(catalogData, temporaryURL: temporaryCatalogURL)
            try checkpoint(.catalogTemporaryDurable)
            guard try AtriaColdSessionStore.sha256(fileURL: sourceURL) == sourceDigest else {
                throw MigrationError.sourceChangedDuringMigration
            }
            try checkpoint(.sourceReverified)
            guard rename(temporaryCatalogURL.path, store.catalogURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try AtriaColdSessionStore.synchronizeDirectory(destinationRootURL)
            try checkpoint(.catalogPublished)
        } catch {
            try? fileManager.removeItem(at: temporaryCatalogURL)
            throw error
        }

        do {
            let reloaded = try store.loadCatalog()
            guard reloaded.source == catalog.source,
                  reloaded.entries == catalog.entries,
                  reloaded.consumerReadiness == catalog.consumerReadiness,
                  reloaded.fullFidelityHotDays == catalog.fullFidelityHotDays,
                  reloaded.fullFidelityDecodedColdDays == catalog.fullFidelityDecodedColdDays,
                  reloaded.productionRawRetirementEnabled == catalog.productionRawRetirementEnabled else {
                throw MigrationError.verificationDetail("catalog_round_trip_mismatch")
            }
            guard try AtriaColdSessionStore.sha256(fileURL: sourceURL) == sourceDigest else {
                throw MigrationError.sourceChangedDuringMigration
            }
            try store.verifyCatalog(reloaded, expectedFactsByID: expectedFacts)
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError.verificationDetail(String(reflecting: error))
        }
        try checkpoint(.catalogVerified)
        try pruneUnreachableRecognizedChunks(store: store, catalog: catalog)
        try checkpoint(.unreachableChunksPruned)
        return result(status: .published,
                      catalog: catalog,
                      catalogURL: store.catalogURL,
                      sourceBytes: sourceBytes)
    }

    /// There is deliberately no implementation that deletes raw source data.
    /// The explicit error makes accidental future call sites fail closed.
    func retireFullColdSource() throws -> Never {
        throw MigrationError.rawRetirementDisabled
    }

    private func result(status: Result.Status,
                        catalog: AtriaColdSessionCatalog,
                        catalogURL: URL,
                        sourceBytes: UInt64) -> Result {
        .init(status: status,
              catalogURL: catalogURL,
              decodedSessionCount: catalog.source.decodedSessionCount,
              eligibleSessionCount: catalog.source.compactEligibleSessionCount,
              chunkCount: catalog.entries.count,
              compressedBytes: catalog.entries.reduce(UInt64(0)) { $0 + $1.compressedByteCount },
              sourceBytes: sourceBytes,
              sourceDeleted: false)
    }

    /// Derived chunks are recoverable from the still-authoritative full cold
    /// source. After the replacement catalog has been reloaded and verified,
    /// remove only unreachable files matching our exact generated filename
    /// grammar. Symlinks, directories, and unknown files are never touched.
    private func pruneUnreachableRecognizedChunks(store: AtriaColdSessionStore,
                                                  catalog: AtriaColdSessionCatalog) throws {
        let referenced = Set(catalog.entries.map(\.filename))
        let candidates = try fileManager.contentsOfDirectory(
            at: store.chunksURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var removed = false
        for candidate in candidates where !referenced.contains(candidate.lastPathComponent) {
            let name = candidate.lastPathComponent
            guard Self.isRecognizedChunkFilename(name),
                  candidate.deletingLastPathComponent().standardizedFileURL
                    == store.chunksURL.standardizedFileURL else { continue }
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey,
                                                                 .isSymbolicLinkKey,
                                                                 .isDirectoryKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.isDirectory != true else { continue }
            try fileManager.removeItem(at: candidate)
            removed = true
        }
        if removed { try AtriaColdSessionStore.synchronizeDirectory(store.chunksURL) }
    }

    private static func isRecognizedChunkFilename(_ name: String) -> Bool {
        name.range(of: #"^day-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{16}\.json\.gz$"#,
                   options: .regularExpression) != nil
    }
}

/// Production cutover from the manifested full-fidelity store to the compact
/// >90-day tier. Unlike the legacy shadow migration, its source receipt is the
/// exact durable full-store manifest generation and it may remove old chunks
/// only through `retireCompactedEntries`, after every fact has been re-read.
struct AtriaManifestedColdSessionCompaction {
    enum Checkpoint: String, CaseIterable, Sendable {
        case compactCatalogVerified
        case fullRetirementCommitted
    }

    struct Result: Equatable, Sendable {
        let compactedSessionIDs: Set<UUID>
        let compactBytes: UInt64
        let fullBytesRetired: UInt64
        let compactCatalogURL: URL
        let fullManifestURL: URL
    }

    enum CompactionError: Error, Equatable {
        case noEligibleSessions
        case duplicateSessionID
        case verificationFailed
    }

    private let fileManager: FileManager
    private let checkpoint: (Checkpoint) throws -> Void

    init(fileManager: FileManager = .default,
         checkpoint: @escaping (Checkpoint) throws -> Void = { _ in }) {
        self.fileManager = fileManager
        self.checkpoint = checkpoint
    }

    func compactAndRetire(
        fullStore: AtriaFullFidelityColdSessionStore,
        destinationRootURL: URL,
        now: Date = Date(),
        confirmedSleeps: [UserConfirmedSleep],
        confirmedWorkouts: [UserConfirmedWorkout],
        restingHeartRate: Int,
        maximumHeartRate: Int
    ) throws -> Result {
        let cutoff = AtriaColdSessionRetentionPolicy.compactCutoff(now: now)
        let manifest = try fullStore.loadManifest()
        let identity = try fullStore.manifestIdentity()
        let eligible = manifest.entries.filter { $0.start < cutoff }
        guard !eligible.isEmpty else { throw CompactionError.noEligibleSessions }
        guard Set(eligible.map(\.sessionID)).count == eligible.count else {
            throw CompactionError.duplicateSessionID
        }

        let compactStore = AtriaColdSessionStore(rootURL: destinationRootURL,
                                                fileManager: fileManager)
        var priorCatalog: AtriaColdSessionCatalog?
        if let existing = try? compactStore.loadCatalog(),
           existing.productionRawRetirementEnabled,
           existing.consumerReadiness == .productionReadable {
            try compactStore.verifyCatalog(existing)
            priorCatalog = existing
        }
        let eligibleByDay = Dictionary(grouping: eligible) {
            AtriaColdSessionChunk.utcDay($0.start)
        }
        let affectedDays = Set(eligibleByDay.keys)
        // Preserve immutable days verbatim. Only a newly crossing UTC day is
        // decoded and regenerated, so every later maintenance run has bounded
        // transient memory instead of loading the lifetime compact tier.
        var catalogEntries = priorCatalog?.entries.filter {
            !affectedDays.contains($0.civilUTCDate)
        } ?? []
        var retiredBytes: UInt64 = 0

        try fileManager.createDirectory(at: compactStore.chunksURL,
                                        withIntermediateDirectories: true)
        for day in affectedDays.sorted() {
            var factsByID: [UUID: AtriaColdSessionFact] = [:]
            if let existingEntry = priorCatalog?.entries.first(where: { $0.civilUTCDate == day }) {
                for fact in try compactStore.loadChunk(entry: existingEntry).facts {
                    guard factsByID.updateValue(fact, forKey: fact.source.sessionID) == nil else {
                        throw CompactionError.duplicateSessionID
                    }
                }
            }
            for entry in eligibleByDay[day] ?? [] {
                let session = try fullStore.loadSession(entry: entry)
                let activityAvailability: AtriaColdSessionAvailability<[AtriaColdSessionFact.Reference]>
                if let detection = session.detectedActivity(rest: restingHeartRate,
                                                            maxHR: maximumHeartRate),
                   detection.kind == .activityCandidate {
                    activityAvailability = .available([.init(
                        kind: .activity,
                        identifier: detection.id.uuidString.lowercased(),
                        start: detection.start,
                        end: detection.end,
                        label: detection.suggestedActivityType?.rawValue,
                        source: "atria_local_detector"
                    )])
                } else {
                    activityAvailability = .knownEmpty(
                        "local detector found no qualified activity for this session"
                    )
                }
                let fact = try AtriaColdSessionFactBuilder.build(
                    session: session,
                    context: .init(confirmedSleeps: confirmedSleeps,
                                   confirmedWorkouts: confirmedWorkouts,
                                   activityReferences: activityAvailability),
                    createdAt: entry.end
                )
                guard fact.source.sessionID == entry.sessionID,
                      fact.source.start == entry.start,
                      fact.source.end == entry.end else {
                    throw CompactionError.verificationFailed
                }
                factsByID[fact.source.sessionID] = fact
                retiredBytes &+= entry.compressedByteCount
            }
            let facts = factsByID.values.sorted {
                if $0.source.start != $1.source.start { return $0.source.start < $1.source.start }
                return $0.source.sessionID.uuidString < $1.source.sessionID.uuidString
            }
            let chunk = AtriaColdSessionChunk(schema: AtriaColdSessionChunk.currentSchema,
                                              civilUTCDate: day,
                                              createdAt: facts.map(\.source.end).max() ?? now,
                                              facts: facts)
            try chunk.validate()
            let decoded = try AtriaColdSessionStore.encoder().encode(chunk)
            let decodedDigest = AtriaColdSessionStore.sha256(decoded)
            let compressed = try AtriaBackupCompression.compressedArchiveData(from: decoded)
            let compressedDigest = AtriaColdSessionStore.sha256(compressed)
            let filename = "day-\(day)-\(decodedDigest.prefix(16)).json.gz"
            let finalURL = compactStore.chunksURL.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: finalURL.path) {
                guard UInt64((try finalURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1)
                        == UInt64(compressed.count),
                      try AtriaColdSessionStore.sha256(fileURL: finalURL) == compressedDigest else {
                    throw CompactionError.verificationFailed
                }
            } else {
                let temporary = compactStore.chunksURL
                    .appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
                try AtriaColdSessionStore.writeDurable(compressed, temporaryURL: temporary)
                guard rename(temporary.path, finalURL.path) == 0 else {
                    try? fileManager.removeItem(at: temporary)
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try AtriaColdSessionStore.synchronizeDirectory(compactStore.chunksURL)
            }
            catalogEntries.append(.init(
                civilUTCDate: day,
                filename: filename,
                compressedSHA256: compressedDigest,
                decodedSHA256: decodedDigest,
                compressedByteCount: UInt64(compressed.count),
                decodedByteCount: UInt64(decoded.count),
                sessionCount: facts.count,
                firstSessionStart: facts.map(\.source.start).min()!,
                lastSessionEnd: facts.map(\.source.end).max()!
            ))
        }
        catalogEntries.sort { lhs, rhs in
            if lhs.civilUTCDate != rhs.civilUTCDate { return lhs.civilUTCDate < rhs.civilUTCDate }
            return lhs.filename < rhs.filename
        }
        let compactSessionCount = catalogEntries.reduce(0) { $0 + $1.sessionCount }

        let catalog = AtriaColdSessionCatalog(
            schema: AtriaColdSessionCatalog.currentSchema,
            generatedAt: now,
            fullFidelityHotDays: AtriaColdSessionRetentionPolicy.hotFullFidelityDays,
            fullFidelityDecodedColdDays: AtriaColdSessionRetentionPolicy.decodedColdFullFidelityDays,
            source: .init(filename: AtriaFullFidelityColdSessionStore.manifestFilename,
                          sha256: identity.sha256,
                          byteCount: identity.byteCount,
                          decodedSessionCount: identity.sessionCount,
                          compactEligibleSessionCount: compactSessionCount),
            entries: catalogEntries,
            consumerReadiness: .productionReadable,
            productionRawRetirementEnabled: true
        )
        let catalogData = try AtriaColdSessionStore.encoder().encode(catalog)
        let temporaryCatalog = destinationRootURL
            .appendingPathComponent(".catalog.\(UUID().uuidString).tmp")
        try AtriaColdSessionStore.writeDurable(catalogData, temporaryURL: temporaryCatalog)
        guard rename(temporaryCatalog.path, compactStore.catalogURL.path) == 0 else {
            try? fileManager.removeItem(at: temporaryCatalog)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try AtriaColdSessionStore.synchronizeDirectory(destinationRootURL)
        let reloaded = try compactStore.loadCatalog()
        guard reloaded == catalog else { throw CompactionError.verificationFailed }
        try compactStore.verifyCatalog(reloaded)
        try checkpoint(.compactCatalogVerified)

        _ = try fullStore.retireCompactedEntries(
            sessionIDs: Set(eligible.map(\.sessionID)),
            compactStore: compactStore,
            cutoff: cutoff,
            generatedAt: now
        )
        try checkpoint(.fullRetirementCommitted)
        pruneUnreachableCompactChunks(store: compactStore, catalog: reloaded)
        return .init(compactedSessionIDs: Set(eligible.map(\.sessionID)),
                     compactBytes: catalogEntries.reduce(0) { $0 + $1.compressedByteCount },
                     fullBytesRetired: retiredBytes,
                     compactCatalogURL: compactStore.catalogURL,
                     fullManifestURL: fullStore.manifestURL)
    }

    private func pruneUnreachableCompactChunks(store: AtriaColdSessionStore,
                                               catalog: AtriaColdSessionCatalog) {
        let referenced = Set(catalog.entries.map(\.filename))
        guard let urls = try? fileManager.contentsOfDirectory(
            at: store.chunksURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var removed = false
        for url in urls where !referenced.contains(url.lastPathComponent) {
            guard url.lastPathComponent.range(
                of: #"^day-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{16}\.json\.gz$"#,
                options: .regularExpression
            ) != nil,
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed = true }
        }
        if removed { try? AtriaColdSessionStore.synchronizeDirectory(store.chunksURL) }
    }
}

enum AtriaManifestedColdSessionCompactionCoordinator {
    private static let lock = NSLock()
    private static var running = false

    static func schedule(
        fullStore: AtriaFullFidelityColdSessionStore,
        destinationRootURL: URL,
        now: Date,
        confirmedSleeps: [UserConfirmedSleep],
        confirmedWorkouts: [UserConfirmedWorkout],
        restingHeartRate: Int,
        maximumHeartRate: Int,
        reason: String
    ) {
        lock.lock()
        guard !running else {
            lock.unlock()
            AtriaDebugLog("ATRIADBG cold_session_tier status=skipped reason=%@ why=already_running", reason)
            return
        }
        running = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            defer {
                lock.lock()
                running = false
                lock.unlock()
            }
            do {
                let result = try AtriaManifestedColdSessionCompaction().compactAndRetire(
                    fullStore: fullStore,
                    destinationRootURL: destinationRootURL,
                    now: now,
                    confirmedSleeps: confirmedSleeps,
                    confirmedWorkouts: confirmedWorkouts,
                    restingHeartRate: restingHeartRate,
                    maximumHeartRate: maximumHeartRate
                )
                AtriaDebugLog("ATRIADBG cold_session_tier status=production_compacted reason=%@ sessions=%d compact_bytes=%llu retired_full_bytes=%llu source_deleted=1",
                              reason,
                              result.compactedSessionIDs.count,
                              result.compactBytes,
                              result.fullBytesRetired)
            } catch AtriaManifestedColdSessionCompaction.CompactionError.noEligibleSessions {
                AtriaDebugLog("ATRIADBG cold_session_tier status=skipped reason=%@ why=no_older_than_90d", reason)
            } catch {
                AtriaDebugLog("ATRIADBG cold_session_tier status=failed reason=%@ error=%@ source_deleted=0",
                              reason,
                              String(describing: error))
            }
        }
    }
}

/// Serializes opportunistic shadow builds. The SessionStore integration only
/// schedules work after its deferred load has finished; the migration itself
/// re-hashes sessions-cold.json immediately before publishing.
enum AtriaColdSessionShadowCoordinator {
    private static let lock = NSLock()
    private static var running = false

    static func schedule(sourceURL: URL,
                         destinationRootURL: URL,
                         now: Date,
                         context: AtriaColdSessionFactBuilder.Context,
                         reason: String) {
        lock.lock()
        guard !running else {
            lock.unlock()
            AtriaDebugLog("ATRIADBG cold_session_tier status=skipped reason=%@ why=already_running", reason)
            return
        }
        running = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            defer {
                lock.lock()
                running = false
                lock.unlock()
            }
            do {
                let result = try AtriaColdSessionMigration().migrate(sourceURL: sourceURL,
                                                                      destinationRootURL: destinationRootURL,
                                                                      now: now,
                                                                      context: context)
                AtriaDebugLog("ATRIADBG cold_session_tier status=%@ reason=%@ decoded=%d eligible=%d chunks=%d compressed_bytes=%llu source_bytes=%llu source_deleted=0",
                              result.status.rawValue,
                              reason,
                              result.decodedSessionCount,
                              result.eligibleSessionCount,
                              result.chunkCount,
                              result.compressedBytes,
                              result.sourceBytes)
            } catch AtriaColdSessionMigration.MigrationError.sourceMissing {
                AtriaDebugLog("ATRIADBG cold_session_tier status=skipped reason=%@ why=source_missing", reason)
            } catch {
                AtriaDebugLog("ATRIADBG cold_session_tier status=failed reason=%@ error=%@ source_deleted=0",
                              reason,
                              String(describing: error))
            }
        }
    }
}
