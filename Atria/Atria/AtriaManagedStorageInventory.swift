import Foundation

/// Handoff-13 CP3-C: one read-only, whole-container accounting of every
/// Atria-managed store, in physically allocated bytes (SQLite -wal/-shm and
/// hidden temporaries included). This is TRUTH, not enforcement: production
/// archive-wide maintenance remains gated off and the compact cold-session
/// consumers are still shadow-only, so no nominal cap is a guarantee. The
/// receipt this writes says exactly that — a false storage promise is worse
/// than an honest blocker.
enum AtriaManagedStorageInventory {
    struct CategoryBytes: Codable, Equatable {
        let category: String
        let bytes: Int64
        let fileCount: Int
    }

    struct Receipt: Codable {
        var schema: Int = 1
        var recordedAtUnix: TimeInterval
        var categories: [CategoryBytes]
        var totalBytes: Int64
        /// The high-volume raw+replay sub-cap this pass inherits (bytes).
        var rawReplaySubCapBytes: Int64 = 512 * 1_024 * 1_024
        /// Whole managed-health target after maintenance (bytes).
        var managedHealthTargetBytes: Int64 = 768 * 1_024 * 1_024
        /// Generated/export budget, separately visible (bytes).
        var generatedExportBudgetBytes: Int64 = 256 * 1_024 * 1_024
        /// Whole Atria-managed warning threshold (bytes).
        var warningThresholdBytes: Int64 = 1_024 * 1_024 * 1_024
        /// The exact reason destructive retention is not running. Honest by
        /// construction: automatic archive-wide maintenance is disabled in
        /// production and every compact cold consumer is shadow-only, so age
        /// tiers are diagnostic targets, not enforced bounds.
        var retentionExecution: String
        var reclaimedBytes: Int64 = 0
        var nextEligibleAction: String
    }

    static let receiptKey = "atria.debug.managedStorageInventory.v1"

    /// The category → directory/file map. Paths are relative to Documents
    /// unless prefixed `AS:` (Application Support). Kept as data so the test
    /// and the accounting walk cannot drift apart.
    static let categoryPaths: [(category: String, paths: [String])] = [
        ("raw_history", ["atria-historical/segments"]),
        ("archive_identity_and_manifest",
         ["atria-historical/historical-archive.jsonl",
          "atria-historical/historical-archive.identity.jsonl",
          // The identity lookup database was missing from every category, so
          // its 839.7 MB was absent from the total the user is shown.
          // Measured on device 2026-08-19: summing the container's own file
          // listing gave 6.32 GB against a reported 4.98 GB, and this file plus
          // an orphaned compaction temporary accounted for the whole gap.
          // `allocatedBytes` folds in the -wal/-shm sidecars.
          "atria-historical/historical-archive.identity.lookup-v1.sqlite"]),
        ("retired_replay_evidence", ["atria-historical/retired-replay-v1"]),
        ("aggregates_and_sidecars",
         ["atria-historical/aggregates-v2",
          "atria-historical/retention-manifests-v2",
          "atria-historical/drain-completions-v1",
          "atria-historical/retirement-intents-v1",
          "atria-historical/hr-index-v1"]),
        ("long_term_rollups", ["atria-historical/long-term-rollups-v1"]),
        ("cold_sessions",
         ["atria-full-fidelity-cold-sessions-v1",
          "atria-cold-session-tier-v1",
          "sessions-cold.json"]),
        ("sessions_and_daily",
         ["sessions.json", "daily-rollups.json", "daily-metrics.json",
          "biological-age-cache.json"]),
        ("stress_history", ["AS:Atria/stress-history-v3"]),
        ("projections_and_receipts",
         ["AS:atria-projections", "AS:Atria/HistoricalRecovery",
          "AS:Atria/verified-step-evidence-v1",
          "atria-historical/ble-request-authority-v1",
          "atria-historical/full-drain-authority-v1",
          "atria-historical/history-drain-state-v1"]),
        ("generated_exports",
         ["atria-raw-exports", "atria-captures", "atria-backups",
          "whoop-backups", "atria-hr-reference-packages"]),
    ]

    /// Physically allocated bytes for one file, including its SQLite
    /// sidecars when present. Never follows symlinks.
    private static func allocatedBytes(
        at url: URL,
        fileManager: FileManager
    ) -> (bytes: Int64, files: Int) {
        var total: Int64 = 0
        var count = 0
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path,
                                     isDirectory: &isDirectory) else {
            return (0, 0)
        }
        if isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [
                    .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey,
                    .isSymbolicLinkKey,
                    .isRegularFileKey,
                ],
                options: []
            ) else { return (0, 0) }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: [
                    .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey,
                    .isSymbolicLinkKey,
                    .isRegularFileKey,
                ]) else { continue }
                if values.isSymbolicLink == true { continue }
                guard values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize
                               ?? values.fileAllocatedSize ?? 0)
                count += 1
            }
        } else {
            if let values = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .isSymbolicLinkKey,
            ]), values.isSymbolicLink != true {
                total = Int64(values.totalFileAllocatedSize
                              ?? values.fileAllocatedSize ?? 0)
                count = 1
            }
            // SQLite sidecars sit beside the base file.
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: url.path + suffix)
                if let values = try? sidecar.resourceValues(forKeys: [
                    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                ]) {
                    total += Int64(values.totalFileAllocatedSize
                                   ?? values.fileAllocatedSize ?? 0)
                    count += 1
                }
            }
        }
        return (total, count)
    }

    static func measure(
        documentsURL: URL? = nil,
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> [CategoryBytes] {
        let documents = documentsURL
            ?? fileManager.urls(for: .documentDirectory,
                                in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let support = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory,
                                in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        var results: [CategoryBytes] = []
        for (category, paths) in categoryPaths {
            var bytes: Int64 = 0
            var files = 0
            for path in paths {
                let url: URL
                if path.hasPrefix("AS:") {
                    url = support.appendingPathComponent(
                        String(path.dropFirst(3))
                    )
                } else {
                    url = documents.appendingPathComponent(path)
                }
                let measured = allocatedBytes(at: url,
                                              fileManager: fileManager)
                bytes += measured.bytes
                files += measured.files
            }
            results.append(CategoryBytes(category: category,
                                         bytes: bytes,
                                         fileCount: files))
        }
        return results
    }

    /// Records the bounded maintenance receipt. `retentionExecution` must
    /// state the exact blocker while destructive maintenance stays disabled.
    static func recordReceipt(
        categories: [CategoryBytes],
        retentionExecution: String,
        nextEligibleAction: String,
        reclaimedBytes: Int64 = 0,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var receipt = Receipt(
            recordedAtUnix: now.timeIntervalSince1970,
            categories: categories,
            totalBytes: categories.reduce(0) { $0 + $1.bytes },
            retentionExecution: retentionExecution,
            nextEligibleAction: nextEligibleAction
        )
        receipt.reclaimedBytes = reclaimedBytes
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        defaults.set(data, forKey: receiptKey)
    }

    /// The truthful current blocker, derived from the same authorities the
    /// planner consults. Automatic execution is a debug-only override and
    /// every compact cold consumer is shadow-only — so retention execution
    /// is blocked, and the receipt says by exactly what.
    /// Deletes orphaned debug logs and aged generated artifacts, returning the
    /// bytes reclaimed.
    ///
    /// Scope is deliberately tiny. It touches exactly two things: the memprobe
    /// pair in Documents, whose writer no longer exists anywhere in the codebase,
    /// and generated `.png`/`.html`/`.gpx` files in `tmp/` older than 24 h. It
    /// never walks the archive, never touches a store, and never removes anything
    /// a reader could still resolve — `shouldSweepGeneratedArtifact` gates on both
    /// extension and age so an in-flight share sheet cannot lose its file.
    ///
    /// Every failure is swallowed: reclaiming disk must never be able to fail a
    /// launch, and a file that will not delete is simply counted as not reclaimed.
    @discardableResult
    static func sweepOrphanedArtifacts(
        documentsURL: URL? = nil,
        temporaryURL: URL? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int64 {
        var reclaimed: Int64 = 0

        let documents = documentsURL
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        if let documents {
            for name in orphanedDebugLogNames {
                let url = documents.appendingPathComponent(name)
                guard let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size])
                        as? NSNumber else { continue }
                guard (try? fileManager.removeItem(at: url)) != nil else { continue }
                reclaimed += size.int64Value
            }
        }

        // Compaction temporaries orphaned by a process death live in the
        // archive directory, not in `temporaryDirectory`, and they are
        // dot-prefixed — so the `.skipsHiddenFiles` walk below cannot see them.
        // The store also sweeps them at init; routing them through here as well
        // is what makes their bytes show up in `reclaimedBytes` instead of the
        // 565.6 MB reclaimed on 2026-08-19 being reported to the user as 0.
        // The sweep is idempotent, so running from both places is harmless.
        if let documents {
            reclaimed += AtriaHistoricalArchiveDurableStore
                .sweepStaleIdentityCompactionTemporaries(
                    in: documents.appendingPathComponent("atria-historical"),
                    now: now,
                    fileManager: fileManager
                )
        }

        let temporary = temporaryURL ?? fileManager.temporaryDirectory
        let contents = (try? fileManager.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in contents {
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            guard let modified = values?.contentModificationDate,
                  shouldSweepGeneratedArtifact(name: url.lastPathComponent,
                                               modifiedAt: modified,
                                               now: now) else { continue }
            let size = Int64(values?.fileSize ?? 0)
            guard (try? fileManager.removeItem(at: url)) != nil else { continue }
            reclaimed += size
        }

        if reclaimed > 0 {
            AtriaDebugLog("ATRIADBG managed_storage status=orphans_swept reclaimed_bytes=%lld",
                          reclaimed)
        }
        return reclaimed
    }

    /// Was `RETENTION_EXECUTION_BLOCKED(automatic_execution_disabled+cold_session_consumers_shadow_only)`.
    ///
    /// The first half stopped being true when the archive-wide release fence was
    /// lifted (df11d6c5): automatic maintenance now runs from the BGProcessing
    /// lane under `shouldAdmitAutomaticArchiveCompaction`. Leaving the old string
    /// in place would make this receipt assert a blocker that no longer exists —
    /// and this file's own header says "a false storage promise is worse than an
    /// honest blocker", which cuts both ways: a false blocker misreports state
    /// just as badly.
    ///
    /// The second half is still true, so it is still named.
    static let currentRetentionExecutionState =
        "RETENTION_EXECUTION_ADMITTED(bg_processing_environmental_admission)+COLD_SESSION_CONSUMERS_SHADOW_ONLY"

    /// Orphaned debug artifacts with no remaining writer, plus generated share/
    /// export files old enough that no sheet can still be holding them.
    ///
    /// Measured on device 2026-08-19: **50.8 MB** of pure dead weight —
    /// 17.0 MB of `atria-memprobe*.log` whose writer no longer exists anywhere in
    /// the codebase (only a stale comment at HistoricalArchive.swift:6483
    /// survives), and 33.8 MB of `tmp/` share PNGs, exported HTML and GPX, the
    /// oldest dating to 7/15 — thirty-five days earlier. `tmp/` is nominally
    /// purgeable by iOS; it demonstrably was not being purged here.
    static let orphanedDebugLogNames = ["atria-memprobe.log", "atria-memprobe.1.log"]

    /// Generated `tmp/` artifacts are only swept once they are old enough that an
    /// in-flight share sheet cannot still own them.
    static let generatedArtifactMinimumAge: TimeInterval = 24 * 60 * 60

    nonisolated static func shouldSweepGeneratedArtifact(
        name: String,
        modifiedAt: Date,
        now: Date,
        minimumAge: TimeInterval = generatedArtifactMinimumAge
    ) -> Bool {
        let generated = name.hasSuffix(".png")
            || name.hasSuffix(".html")
            || name.hasSuffix(".gpx")
        guard generated else { return false }
        let age = now.timeIntervalSince(modifiedAt)
        // A forward-dated file (clock correction) is not evidence of age.
        guard age >= 0 else { return false }
        return age >= minimumAge
    }
}
