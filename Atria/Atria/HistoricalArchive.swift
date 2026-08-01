import Foundation

enum HistoricalArchive {
    /// All heavyweight read-only projections over the historical archive share
    /// one lane. Running the JSONL scanners concurrently multiplies their
    /// resident buffers and can saturate every performance core, starving the
    /// main run loop even though each individual caller is off-main.
    static let consumerProjectionQueue = DispatchQueue(
        label: "com.atria.historical-archive-consumer-projection",
        qos: .utility
    )

    enum DurableAdmissionReconciliationError: Error {
        case rematerializationFailed(String)
    }

    static let didUpdateNotification = Notification.Name("AtriaHistoricalArchiveDidUpdate")
    static let schema = 3
    static let decodedLayoutPrefix = "whoop4_0x2f_openstrap_v1"
    static func layoutVersion(for version: UInt8) -> String {
        "\(decodedLayoutPrefix)_v\(version)"
    }
    static let layoutVersion = layoutVersion(for: 24)
    // v24 is present in the captured WHOOP 4 archive and its fixed HR/RR/time
    // layout matches the independently maintained OpenStrap protocol. Other
    // decoded versions remain raw/motion-only until captured on this hardware.
    static let validatedMetricLayoutVersions: Set<String> = [layoutVersion]
    static var hasValidatedMetricLayout: Bool {
        !validatedMetricLayoutVersions.isEmpty
    }
    static let relativePath = "Documents/atria-historical/historical-archive.jsonl"
    private static let diagnosticsIndexFilename = "historical-archive.diagnostics.json"
    private static let rotationManifestFilename = "historical-archive.manifest.json"
    private static let rotationThresholdBytes = 128 * 1024 * 1024
    private static let maxImmediateDiagnosticsScanBytes = 8 * 1024 * 1024
    private static let recoveredDataCacheMaximumWindowDrift: TimeInterval = 24 * 60 * 60
    private static let segmentsDirectoryName = "segments"
    private static let promotionLock = NSLock()
    private static let durableStoreLock = NSLock()
    private static let archiveCatalogInitializationLock = NSLock()
    private static var durableStore: AtriaHistoricalArchiveDurableStore?
    private static var archiveCatalogStore: AtriaHistoricalArchiveCatalogStore?
    private static var durableDrainBatches: [UInt64: AtriaHistoricalArchiveDurableStore.DrainBatch] = [:]
    private static let diagnosticsIndexLock = NSLock()
    private static let recentGravityCacheLock = NSLock()
    private static let recoveredDataCacheLock = NSLock()
#if DEBUG
    private static let fullGravityInstrumentationLock = NSLock()
    private static var fullGravityLoadCount = 0
#endif
    private static let archiveDateFormatter = ISO8601DateFormatter()
    private static var recentGravityCache: RecentGravityCache?
    private static var recoveredDataCache: RecoveredDataCache?
    private static var recentGravityLoadInFlight = false
    private static var recentGravityLoadGeneration: UInt64 = 0

    struct Diagnostics {
        let exists: Bool
        let parseOK: Bool
        let rows: Int
        let bytes: Int
        let schemas: [String]
        let layoutVersions: [String]
        let metricUsableRows: Int
        let currentSessionUsableRows: Int
        let undecodableRows: Int
        let rawPayloadRows: Int
        let unixFirst: UInt32?
        let unixLast: UInt32?
        let correctedUnixFirst: UInt32?
        let correctedUnixLast: UInt32?
        let gravityRows: Int
        let gravityValidatedRows: Int
        let reason: String
    }

    struct MetricReadinessProbe {
        let ready: Bool
        let rowsScanned: Int
        let metricUsableRows: Int
        let currentSessionUsableRows: Int
        let reason: String
    }

    private struct DiagnosticsIndex: Codable {
        var fileSize: Int
        var modificationTime: TimeInterval
        var rows: Int
        var schemas: [String]
        var layoutVersions: [String]
        var metricUsableRows: Int
        var currentSessionUsableRows: Int
        var undecodableRows: Int
        var rawPayloadRows: Int
        var unixFirst: UInt32?
        var unixLast: UInt32?
        var correctedUnixFirst: UInt32?
        var correctedUnixLast: UInt32?
        var gravityRows: Int
        var gravityValidatedRows: Int
    }

    /// One in-memory diagnostics delta per active history generation/file.
    /// The sidecar is a derived status accelerator, never raw-data or ACK
    /// authority. Keeping its tiny aggregate in memory lets the canonical
    /// archive append thousands of rows while writing the sidecar once at the
    /// durable boundary instead of atomically replacing it for every row.
    private struct DurableDiagnosticsAccumulator {
        let archiveURL: URL
        var index: DiagnosticsIndex?
    }

    private static var durableDiagnosticsAccumulators:
        [UInt64: [String: DurableDiagnosticsAccumulator]] = [:]

    private struct RotationManifest: Codable {
        var version: Int
        var baseRelativePath: String
        var activeSegmentRelativePath: String
        var createdAt: Date
        var rotationThresholdBytes: Int
    }

    struct MotionWindowDiagnostics {
        let status: String
        let reason: String
        let rows: Int
        let validatedRows: Int
        let coverageSeconds: Int
        let spanSeconds: Int
        let meanVectorDelta: Double?
        let p95VectorDelta: Double?
        let magnitudeMean: Double?
        let magnitudeStdDev: Double?
        let archiveFirstUnix: Int
        let archiveLastUnix: Int
        let nearestSeparationSeconds: Int
        let lowMotionReady: Bool
    }

    /// Exact strap-owned v24 counter endpoints for a workout window. The
    /// counter is decoded again from the retained payload; JSON metadata alone
    /// is never publication authority.
    struct MotionTickWindow: Equatable, Sendable {
        let startTick: Int
        let endTick: Int
        let delta: Int
        let steps: Int
        let startCapturedAt: Date
        let endCapturedAt: Date
        let coverageFraction: Double
        let decodedRows: Int
    }

    struct MotionTickDayEvidence: Equatable, Sendable {
        let windowStart: Date
        let windowEnd: Date
        let motionTicks: Int
        let steps: Int
        let knownCoverageSeconds: Int
        let missingCoverageSeconds: Int
        let decodedRows: Int
        let capturedThrough: Date
    }

    struct MotionArchiveSnapshot {
        fileprivate let samples: [GravitySample]
        /// Motion is independently fail-closed. A complete physiology scan may
        /// still carry an explicitly unavailable motion channel when its
        /// bounded replay-identity or sample budget was reached.
        let completeness: RecoveredDataCompleteness

        func recoveredEvidence(start: Date, end: Date) -> AtriaRecoveredMotionProjection.Evidence {
            guard completeness == .complete else {
                return AtriaRecoveredMotionProjection.project(
                    samples: [],
                    window: .init(id: "motion_budget_unavailable", start: start, end: end)
                )
            }
            return HistoricalArchive.recoveredMotionEvidence(start: start,
                                                              end: end,
                                                              records: samples)
        }

        func diagnostics(start: Date, end: Date) -> MotionWindowDiagnostics {
            guard completeness == .complete else {
                return HistoricalArchive.emptyMotionWindow(
                    status: "learning",
                    reason: completeness.failureReason ?? "motion_projection_incomplete"
                )
            }
            return HistoricalArchive.recoveredMotionWindowDiagnostics(start: start,
                                                                       end: end,
                                                                       records: samples)
        }

        func recoveredEpochs(
            windows: [AtriaRecoveredMotionProjection.Window]
        ) -> [String: [AtriaRecoveredMotionEpoch]] {
            guard completeness == .complete else { return [:] }
            return AtriaRecoveredMotionProjection.epochFeatures(samples: samples.map {
                .init(timestamp: Date(timeIntervalSince1970: $0.timestamp),
                      sequence: $0.sequence,
                      x: $0.x,
                      y: $0.y,
                      z: $0.z,
                      timestampValidated: $0.timestampValidated,
                      gravityValidated: $0.validated)
            }, windows: windows)
        }
    }

    struct RecoveredArchiveScanDiagnostics: Equatable, Sendable {
        let fileReadCount: Int
        let byteCount: Int
        let decodedRecordCount: Int
        let elapsedMilliseconds: Int
    }

    struct RecoveredProjectionBudget: Equatable, Sendable {
        static let production = RecoveredProjectionBudget(
            maximumHeartRatePoints: 1_500_000,
            maximumRRRecords: 250_000,
            maximumSkinTemperaturePoints: 1_500_000,
            maximumGravitySamples: 750_000,
            maximumMotionReplayIdentities: 750_000
        )

        let maximumHeartRatePoints: Int
        let maximumRRRecords: Int
        let maximumSkinTemperaturePoints: Int
        let maximumGravitySamples: Int
        let maximumMotionReplayIdentities: Int

        init(maximumHeartRatePoints: Int,
             maximumRRRecords: Int,
             maximumSkinTemperaturePoints: Int = 1_500_000,
             maximumGravitySamples: Int,
             maximumMotionReplayIdentities: Int) {
            precondition(maximumHeartRatePoints > 0)
            precondition(maximumRRRecords > 0)
            precondition(maximumSkinTemperaturePoints > 0)
            precondition(maximumGravitySamples > 0)
            precondition(maximumMotionReplayIdentities > 0)
            self.maximumHeartRatePoints = maximumHeartRatePoints
            self.maximumRRRecords = maximumRRRecords
            self.maximumSkinTemperaturePoints = maximumSkinTemperaturePoints
            self.maximumGravitySamples = maximumGravitySamples
            self.maximumMotionReplayIdentities = maximumMotionReplayIdentities
        }
    }

    enum RecoveredDataCompleteness: Equatable, Sendable {
        enum Channel: String, Equatable, Hashable, Sendable {
            case heartRate = "heart_rate"
            case rrRecords = "rr_records"
            case skinTemperature = "skin_temperature"
            case gravity = "gravity"
            case motionReplayIdentity = "motion_replay_identity"
        }

        case complete
        case budgetExceeded(channel: Channel, limit: Int)

        var failureReason: String? {
            guard case let .budgetExceeded(channel, limit) = self else { return nil }
            return "archive_projection_budget_exceeded_\(channel.rawValue)_\(limit)"
        }
    }

    struct RecoveredDataBudgetLimitation: Equatable, Sendable {
        let channel: RecoveredDataCompleteness.Channel
        let limit: Int

        var completeness: RecoveredDataCompleteness {
            .budgetExceeded(channel: channel, limit: limit)
        }
    }

    /// One immutable decode pass supplies HR, RR and motion projection. The
    /// recovered fence must not reread a large physical archive independently
    /// for each metric family.
    struct RecoveredDataSnapshot {
        let heartRatePoints: [HeartRatePoint]
        let rrRecords: [Record]
        let skinTemperatureRawPoints: [SkinTemperatureRawPoint]
        let motion: MotionArchiveSnapshot
        let scan: RecoveredArchiveScanDiagnostics
        /// Truthful completeness across every decoded channel. This must not
        /// become `.complete` merely because HR/RR remain publishable.
        let completeness: RecoveredDataCompleteness
        /// The independent gate used by the physiology projection. Motion
        /// exhaustion cannot discard fully scanned HR/RR, while either HR or RR
        /// exhaustion still withholds physiology as a unit.
        let physiologyCompleteness: RecoveredDataCompleteness
        let skinTemperatureCompleteness: RecoveredDataCompleteness
        /// Every exhausted channel in deterministic order, retaining the exact
        /// bound that caused partial publication.
        let budgetLimitations: [RecoveredDataBudgetLimitation]
    }

    struct VerifiedConsumerSourceReadReport: Equatable, Sendable {
        let committedSourceCount: Int
        let attemptedSourceCount: Int
        let deliveredSourceCount: Int
        let wasBounded: Bool
        let rejectedManifestCount: Int
    }

    struct MotionFeatureSummary: Equatable {
        let stillnessRatio: Double
        let movementIntensity: Double
        let rows: Int
        let validatedRows: Int
        let coverageSeconds: Int
        let maximumGapSeconds: Int
        let firstUnix: Int
        let lastUnix: Int
        let reason: String

        var lowMotionReady: Bool {
            let validatedRatio = rows > 0 ? Double(validatedRows) / Double(rows) : 0
            return validatedRows >= 300
                && validatedRatio >= 0.95
                && coverageSeconds >= 30 * 60
                && maximumGapSeconds <= 5 * 60
                && stillnessRatio >= 0.72
                && movementIntensity <= 0.18
        }
    }

    struct HeartRatePoint: Equatable, Sendable {
        let t: Date
        let bpm: Int
    }

    struct SkinTemperatureRawPoint: Equatable, Sendable {
        let t: Date
        let raw: Int
        let strapIdentifier: String?
    }

    struct HeartRateWindowRead: Equatable, Sendable {
        let points: [HeartRatePoint]
        let scannedFileCount: Int
        let scannedByteCount: Int
    }

    /// Cheap, read-only identity of every raw source a consumer scan can read.
    /// It deliberately uses filesystem identity/size/mtime plus the catalog
    /// generation; hashing sealed archives here would recreate the very
    /// lifetime read this token is intended to suppress.
    struct ConsumerSourceFingerprint: Codable, Equatable, Sendable {
        struct Source: Codable, Equatable, Sendable {
            let path: String
            let size: UInt64
            let modificationTimeMilliseconds: Int64
            let resourceIdentifier: String?
        }

        let catalogGeneration: UInt64?
        let sources: [Source]

        var stableIdentifier: String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(self).base64EncodedString()
        }
    }

    enum MotionTickWindowRead: Equatable, Sendable {
        case qualified(MotionTickWindow)
        case completeNoQualifiedEvidence
        case incomplete

        var evidence: MotionTickWindow? {
            guard case .qualified(let value) = self else { return nil }
            return value
        }
    }

    enum MotionTickDayEvidenceRead: Equatable, Sendable {
        case qualified(MotionTickDayEvidence)
        case completeNoQualifiedEvidence
        case incomplete

        var evidence: MotionTickDayEvidence? {
            guard case .qualified(let value) = self else { return nil }
            return value
        }
    }

    struct DurableAppendResult {
        let url: URL
        let inserted: Bool
    }

    struct TerminalCatalogSealResult {
        let chunkID: String
        let sourceURL: URL
        let aggregateBuild: AtriaHistoricalAggregateBuilder.FileBuildResult
    }

    struct TerminalConsumerProjectionResult {
        let aggregateCommit: AtriaHistoricalRetentionTransaction.Result
        let completion: AtriaHistoricalDrainCompletionGenerationStore.Published
        let consumers: AtriaHistoricalConsumerProjectionCoordinator.Report
    }

    struct TerminalCompletionPublicationResult {
        let aggregateCommit: AtriaHistoricalRetentionTransaction.Result
        let completion: AtriaHistoricalDrainCompletionGenerationStore.Published
    }

    struct FullScanAggregatePublicationResult {
        let aggregateCommit: AtriaHistoricalRetentionTransaction.Result?
        let source: AtriaHistoricalAggregateChunk.Source
        let observedArchiveFirstTimestamp: Date
        let catalogGeneration: UInt64
        let catalogSnapshotSHA256: String
        let aggregateSnapshotSHA256: String
    }

    struct TerminalConsumerProjectionResumeResult {
        let completion: AtriaHistoricalDrainCompletionGenerationStore.Record
        let consumers: AtriaHistoricalConsumerProjectionCoordinator.Report
    }

    /// Audit result for the bounded retention cutover step. It proves that one
    /// committed shadow chunk has all six typed, re-readable retirement
    /// receipts while the original raw file still exists. The five app-facing
    /// receipts remain the ledger's atomic current set; replay identity is an
    /// independently durable raw-bound audit artifact.
    struct HistoricalConsumerCutoverResult: Equatable {
        let chunkID: String
        let completionGeneration: UInt64
        let receiptCount: Int
        let reusedReceiptCount: Int
        let receiptKinds: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind]
        let canonicalApplicationCount: Int
        let canonicalApplicationIdentitySHA256: String
        let rawSourceURL: URL
    }

    /// Exact values exposed to SessionStore after the atomic canonical
    /// application proof and all five destination snapshots are re-read.
    struct VerifiedCanonicalConsumerSource: Equatable, Sendable {
        let identity: AtriaHistoricalCanonicalConsumerApplicationStore.VerificationIdentity
        let activity: AtriaHistoricalActivityProjection
        let dailyMetrics: AtriaHistoricalDailyConsumerProjection.DailyMetricsArtifact
        let steps: AtriaHistoricalDailyConsumerProjection.StepsArtifact
        let sleep: AtriaHistoricalSleepProjection
        let workout: AtriaHistoricalWorkoutProjection
        let replayIdentity: AtriaHistoricalReplayIdentityShard
        let replayPayloadRetired: Bool
    }

    struct VerifiedCanonicalConsumerPage: Sendable {
        let sources: [VerifiedCanonicalConsumerSource]
        let nextCursor: AtriaHistoricalAggregateReader.PageCursor?
        let hasMore: Bool
        let examinedSourceCount: Int
    }

    enum HistoricalConsumerCutoverError: Error, Equatable {
        case committedShadowUnavailable
        case rawSourceUnavailable
        case terminalCompletionAttestationUnavailable
        case terminalCompletionAttestationRejected
        case receiptPublicationIncomplete
        case typedVerificationIncomplete
        case rawSourceWasNotRetained
    }

    struct Record: Codable {
        let schema: Int
        let capturedAt: Date
        var strapIdentifier: String? = nil
        let source: String
        let layoutVersion: String
        let sequence: Int
        let command: Int
        let unix7: UInt32
        let subsec11: UInt16
        let flash13: UInt32
        let payloadLength: Int
        let whoofHR17: Int
        let whoofRRNum18: Int
        let whoofRR19: [Int]
        let kRR64: [Int]
        let gravityX36: Double?
        let gravityY40: Double?
        let gravityZ44: Double?
        var unknownMotionScalar32: Double? = nil
        let gravityMagnitude: Double?
        let gravityValidated: Bool
        var motionTickCounter88: Int? = nil
        let candidateRR: [String]
        let rawPayloadHex: String
        let clockDeviceRef: UInt32?
        let clockWallRef: UInt32?
        let clockDriftSeconds: Int?
        let clockCorrectedUnix7: UInt32?
        let clockCorrectionStatus: String
        let currentSessionUsable: Bool
        let metricUsable: Bool
        let usabilityReason: String
    }

    struct UndecodableFrame: Codable {
        let schema: Int
        let capturedAt: Date
        let source: String
        let payloadLength: Int
        let rawPayloadHex: String
        let currentSessionUsable: Bool
        let metricUsable: Bool
        let usabilityReason: String
    }

    static var fileURL: URL {
        archiveDirectory
            .appendingPathComponent("historical-archive.jsonl")
    }

    private static var legacyFileURL: URL {
        documentsDirectory
            .appendingPathComponent("whoop-historical", isDirectory: true)
            .appendingPathComponent("historical-archive.jsonl")
    }

    private static var readableFileURL: URL {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return legacyFileURL
    }

    private static var diagnosticsIndexURL: URL {
        archiveDirectory.appendingPathComponent(diagnosticsIndexFilename)
    }

    private static var rotationManifestURL: URL {
        archiveDirectory.appendingPathComponent(rotationManifestFilename)
    }

    static func append(_ record: Record) throws -> URL {
        try appendJSONLine(record)
    }

    static func appendUndecodable(payload: [UInt8], reason: String) throws -> URL {
        let frame = UndecodableFrame(schema: schema,
                                     capturedAt: Date(),
                                     source: "0x2f",
                                     payloadLength: payload.count,
                                     rawPayloadHex: hex(payload),
                                     currentSessionUsable: false,
                                     metricUsable: false,
                                     usabilityReason: reason)
        return try appendJSONLine(frame)
    }

    /// Idempotently appends one decoded frame to a generation-scoped drain.
    /// The identity index is derived from archive rows and rebuilt on launch;
    /// it is not a second source of truth.
    static func appendDurably(
        _ record: Record,
        identity: AtriaHistoricalArchiveDurableStore.FrameIdentity,
        generation: UInt64
    ) throws -> DurableAppendResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let diagnosticsObject =
            (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any]
        return try appendDurably(
            encodedJSONObject: data,
            diagnosticsObject: diagnosticsObject,
            identity: identity,
            generation: generation
        )
    }

    static func appendUndecodableDurably(
        payload: [UInt8],
        reason: String,
        identity: AtriaHistoricalArchiveDurableStore.FrameIdentity,
        generation: UInt64
    ) throws -> DurableAppendResult {
        let frame = UndecodableFrame(schema: schema,
                                     capturedAt: Date(),
                                     source: "0x2f",
                                     payloadLength: payload.count,
                                     rawPayloadHex: hex(payload),
                                     currentSessionUsable: false,
                                     metricUsable: false,
                                     usabilityReason: reason)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(frame)
        let diagnosticsObject =
            (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any]
        return try appendDurably(
            encodedJSONObject: data,
            diagnosticsObject: diagnosticsObject,
            identity: identity,
            generation: generation
        )
    }

    private static func appendDurably(
        encodedJSONObject: Data,
        diagnosticsObject: [String: Any]?,
        identity: AtriaHistoricalArchiveDurableStore.FrameIdentity,
        generation: UInt64
    ) throws -> DurableAppendResult {
        promotionLock.lock()
        defer { promotionLock.unlock() }
        let url = try writableFileURL()
        beginDurableDiagnosticsAccumulationIfNeeded(
            generation: generation,
            archiveURL: url
        )

        durableStoreLock.lock()
        defer { durableStoreLock.unlock() }
        let store = try durableStoreLocked()
        let batch = durableDrainBatches[generation] ?? store.beginDrainBatch()
        durableDrainBatches[generation] = batch
        let result = try store.append(identity: identity,
                                      encodedJSONObject: encodedJSONObject,
                                      to: url,
                                      batch: batch)
        let inserted: Bool
        switch result {
        case .inserted:
            inserted = true
            appendDurableDiagnostics(
                object: diagnosticsObject,
                generation: generation,
                archiveURL: url
            )
        case .duplicate:
            inserted = false
        }
        return DurableAppendResult(url: url, inserted: inserted)
    }

    /// Rebinds every admission row still awaiting promotion to the exact
    /// archive receipt that will authorize this HISTORY_END. Existing rows are
    /// never duplicated; a missing identity fails closed before flush/ACK.
    static func includeExistingAdmissionFramesInDurableBatch(
        payloads: [Data],
        strapIdentifier: String,
        generation: UInt64,
        clock: AtriaWhoop4HistoryArchivePipeline.ClockReference? = nil,
        historyClockSyncEnabled: Bool = false
    ) throws {
        guard !payloads.isEmpty else { return }
        for payload in payloads {
            do {
                promotionLock.lock()
                durableStoreLock.lock()
                let store = try durableStoreLocked()
                let batch = durableDrainBatches[generation] ?? store.beginDrainBatch()
                durableDrainBatches[generation] = batch
                try store.includeExisting(
                    .whoop4(strapIdentifier: strapIdentifier, payload: payload),
                    in: batch
                )
                durableStoreLock.unlock()
                promotionLock.unlock()
            } catch AtriaHistoricalArchiveDurableStore.StoreError.missingExistingIdentity {
                durableStoreLock.unlock()
                promotionLock.unlock()

                // The exact-admission SQLite ledger is write-ahead authority:
                // a crash may leave an admitted payload without its raw JSONL
                // row. Re-materialize that exact payload into the same drain
                // batch before fsync instead of permanently wedging every
                // later HISTORY_END. This remains fail-closed: any decode or
                // append failure propagates and the strap receives no ACK.
                let computation = AtriaWhoop4HistoryArchivePipeline.prepare(
                    payload: Array(payload),
                    clock: clock,
                    historyClockSyncEnabled: historyClockSyncEnabled
                )
                let persistence = AtriaWhoop4HistoryArchivePipeline.persist(
                    computation,
                    strapIdentifier: strapIdentifier,
                    generation: generation
                )
                guard persistence.succeeded else {
                    throw DurableAdmissionReconciliationError.rematerializationFailed(
                        persistence.errorDescription ?? "unknown"
                    )
                }
            } catch {
                durableStoreLock.unlock()
                promotionLock.unlock()
                throw error
            }
        }
    }

    /// Establishes the durability boundary used by the strap-history ACK.
    /// Individual frames are appended serially; synchronizing once at the end
    /// of a transmitted batch keeps the hot path cheap while ensuring the
    /// strap is never told to trim data that exists only in the OS write cache.
    static func synchronizeDurableStorage() throws {
        promotionLock.lock()
        defer { promotionLock.unlock() }
        let url = try writableFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// Flushes every base/rotated archive file dirtied by this exact drain plus
    /// its replay index. This is the only durability result eligible to precede
    /// a HISTORY_END ACK.
    @discardableResult
    static func synchronizeDurableStorage(
        generation: UInt64
    ) throws -> AtriaHistoricalArchiveDurableStore.FlushReceipt? {
        durableStoreLock.lock()
        let receipt: AtriaHistoricalArchiveDurableStore.FlushReceipt?
        do {
            let store = try durableStoreLocked()
            // Empty terminal tails still receive a distinct durable sequence
            // and zero-row receipt. This proves ordering without fabricating
            // positive historical coverage.
            let batch =
                durableDrainBatches[generation] ?? store.beginDrainBatch()
            receipt = try store.flush(batch)
            // Each HISTORY_END is a separate durability boundary. A
            // successful flush seals this store batch; the next strap burst
            // gets a fresh one while retaining the same BLE drain generation.
            durableDrainBatches.removeValue(forKey: generation)
            durableStoreLock.unlock()
        } catch {
            durableStoreLock.unlock()
            throw error
        }
        if let receipt {
            try reconcileActiveCatalogAfterDurableFlush(
                synchronizedFiles: receipt.synchronizedFiles,
                catalogStore: try catalogStoreLocked()
            )
        }
        flushDurableDiagnostics(generation: generation)
        NotificationCenter.default.post(name: didUpdateNotification, object: nil)
        return receipt
    }

    /// Mirrors the normal JSONL append path's catalog hint once the durable
    /// writer has fsynced its exact batch. Durable history appends intentionally
    /// bypass `appendJSONLine`; without this boundary update the in-process
    /// catalog retains its pre-drain size and terminal proof rejects valid raw
    /// rows until the app is relaunched.
    static func reconcileActiveCatalogAfterDurableFlush(
        synchronizedFiles: [URL],
        catalogStore: AtriaHistoricalArchiveCatalogStore
    ) throws {
        let active = try catalogStore.activeChunkDescriptor()
        let activePath = active.fileURL.standardizedFileURL.path
        guard synchronizedFiles.contains(where: {
            $0.standardizedFileURL.path == activePath
        }) else { return }
        try catalogStore.recordAppendCompleted(at: active.fileURL)
    }

    /// Opens the exact-history identity store before a recovery drain needs its
    /// first append. The initial open may rebuild its derived index by scanning
    /// retained raw chunks, which can be substantial after a long wear period.
    /// Call this only from a background queue: it performs no append, terminal
    /// publication, ACK, cursor, or gap-coverage mutation.
    static func warmDurableIdentityStoreForBackgroundRecovery() throws {
        durableStoreLock.lock()
        defer { durableStoreLock.unlock() }
        _ = try durableStoreLocked()
    }

    /// Production-facing bridge for the terminal history-drain callback.
    /// It flushes the exact drain batch, derives authoritative bounds through
    /// the canonical aggregate builder, and atomically rotates the active raw
    /// chunk. The returned aggregate is still shadow-only until its retention
    /// transaction is separately committed; this method never deletes raw.
    static func sealCatalogChunkAfterTerminalDrain(
        generation: UInt64,
        completedAt: Date = Date(),
        expectedChunkID: String? = nil
    ) throws -> TerminalCatalogSealResult? {
        promotionLock.lock()
        defer { promotionLock.unlock() }

        durableStoreLock.lock()
        do {
            if let batch = durableDrainBatches[generation] {
                _ = try durableStoreLocked().flush(batch)
                durableDrainBatches.removeValue(forKey: generation)
            }
            durableStoreLock.unlock()
        } catch {
            durableStoreLock.unlock()
            throw error
        }
        flushDurableDiagnostics(generation: generation)

        let catalogStore = try catalogStoreLocked()
        let active = try catalogStore.activeChunkDescriptor()
        guard expectedChunkID == nil || active.chunkID == expectedChunkID else {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: active.fileURL.path)[.size])
            as? NSNumber)?.uint64Value ?? 0
        guard bytes > 0 else { return nil }
        let handle = try FileHandle(forWritingTo: active.fileURL)
        defer { try? handle.close() }
        try handle.synchronize()

        let build = try AtriaHistoricalAggregateBuilder.build(
            sourceURL: active.fileURL,
            chunkID: active.chunkID,
            createdAt: completedAt
        )
        try catalogStore.sealActiveChunkAtTerminal(
            chunkID: active.chunkID,
            rowCount: build.aggregate.source.rawRowCount,
            firstTimestamp: build.aggregate.source.firstTimestamp,
            lastTimestamp: build.aggregate.source.lastTimestamp,
            contentSHA256: build.aggregate.source.rawSHA256,
            now: completedAt
        )
        NotificationCenter.default.post(name: didUpdateNotification, object: nil)
        return .init(chunkID: active.chunkID,
                     sourceURL: active.fileURL,
                     aggregateBuild: build)
    }

    /// Converges one immutable sealed payload toward the complete catalog +
    /// shadow-aggregate authority required by terminal consumer projection.
    /// The caller must yield between reports; this method never retires raw.
    static func materializeNextSealedCatalogDependency(
        now: Date = Date()
    ) throws -> AtriaHistoricalSealedCatalogMaterializer.Report {
        try AtriaHistoricalSealedCatalogMaterializer.materializeNext(
            catalogStore: try catalogStoreLocked(),
            archiveRoot: archiveDirectory,
            aggregateDirectoryURL: archiveDirectory.appendingPathComponent(
                "aggregates-v2", isDirectory: true
            ),
            manifestDirectoryURL: archiveDirectory.appendingPathComponent(
                "retention-manifests-v2", isDirectory: true
            ),
            now: now
        )
    }

    /// Read-only identifier used to stage the crash journal before the catalog
    /// seal changes the active chunk. The seal rechecks this exact ID.
    static func terminalCatalogCandidateChunkID() throws -> String {
        try catalogStoreLocked().activeChunkDescriptor().chunkID
    }

    /// A read-only cap-pressure probe for the foreground maintenance scheduler.
    /// It deliberately has no compaction or deletion authority: its sole job is
    /// to avoid a once-daily lease leaving an already-over-cap archive idle for
    /// almost a full day while live capture continues to append.
    static func highVolumeMaintenancePressure() -> AtriaHistoricalHighVolumeDiagnosticsCoordinator.Report? {
        do {
            let catalog = try catalogStoreLocked().snapshotVerifiedAgainstFiles()
            return try AtriaHistoricalHighVolumeDiagnosticsCoordinator.evaluate(
                archiveRoot: archiveDirectory,
                catalog: catalog
            )
        } catch {
            AtriaDebugLog("ATRIADBG archive_storage_pressure status=unavailable error=%@ mutation_authority=0",
                          String(describing: error))
            return nil
        }
    }

    /// Reconciles a staged journal across the catalog-seal boundary. If the
    /// expected chunk is still active it performs the seal; if it was already
    /// sealed before a crash it rebuilds and verifies the same immutable seal.
    static func recoverTerminalCatalogSeal(
        job: AtriaBLEHistoryTerminalPublicationStore.Job,
        generation: UInt64
    ) throws -> TerminalCatalogSealResult {
        let store = try catalogStoreLocked()
        let catalog = try store.snapshot()
        guard let chunk = catalog.chunks.first(where: { $0.id == job.chunkID }) else {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        if chunk.state == .active {
            guard let seal = try sealCatalogChunkAfterTerminalDrain(
                generation: generation,
                completedAt: job.completedAt,
                expectedChunkID: job.chunkID
            ) else {
                throw TerminalConsumerProjectionError.resumeChunkUnavailable
            }
            return seal
        }
        return try recoverAlreadySealedTerminalCatalogChunk(
            job: job,
            archiveRoot: archiveDirectory,
            catalogStore: store
        )
    }

    /// Injected sealed-side recovery used to prove the checkpoint immediately
    /// after catalog seal and before the journal advances from `staged`.
    static func recoverAlreadySealedTerminalCatalogChunk(
        job: AtriaBLEHistoryTerminalPublicationStore.Job,
        archiveRoot: URL,
        catalogStore: AtriaHistoricalArchiveCatalogStore
    ) throws -> TerminalCatalogSealResult {
        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        guard let chunk = catalog.chunks.first(where: { $0.id == job.chunkID }),
              chunk.state == .sealed else {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        let sourceURL = archiveRoot.appendingPathComponent(chunk.relativePath)
        let build = try AtriaHistoricalAggregateBuilder.build(
            sourceURL: sourceURL,
            chunkID: job.chunkID,
            createdAt: job.completedAt
        )
        guard build.aggregate.source.rawSHA256 == chunk.contentSHA256,
              build.aggregate.source.rawByteCount == chunk.byteCount,
              build.aggregate.source.rawRowCount == chunk.rowCount,
              catalogTimestampMatches(
                raw: build.aggregate.source.firstTimestamp,
                catalog: chunk.firstTimestamp
              ),
              catalogTimestampMatches(
                raw: build.aggregate.source.lastTimestamp,
                catalog: chunk.lastTimestamp
              ) else {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        return .init(chunkID: job.chunkID,
                     sourceURL: sourceURL,
                     aggregateBuild: build)
    }

    static func recoverFullDrainTerminalCatalogSeal(
        checkpoint: AtriaHistoricalFullDrainCoverageStore.PublicationCheckpoint,
        generation: UInt64
    ) throws -> TerminalCatalogSealResult {
        let store = try catalogStoreLocked()
        let catalog = try store.snapshot()
        guard let chunk = catalog.chunks.first(where: {
            $0.id == checkpoint.chunkID
        }) else { throw TerminalConsumerProjectionError.resumeChunkUnavailable }
        if chunk.state == .active {
            guard let seal = try sealCatalogChunkAfterTerminalDrain(
                generation: generation,
                completedAt: Date(timeIntervalSince1970: checkpoint.completedAtUnix),
                expectedChunkID: checkpoint.chunkID
            ) else { throw TerminalConsumerProjectionError.resumeChunkUnavailable }
            return seal
        }
        let verified = try store.snapshotVerifiedAgainstFiles()
        guard let sealed = verified.chunks.first(where: {
            $0.id == checkpoint.chunkID && $0.state == .sealed
        }) else { throw TerminalConsumerProjectionError.resumeChunkUnavailable }
        let sourceURL = archiveDirectory.appendingPathComponent(sealed.relativePath)
        let build = try AtriaHistoricalAggregateBuilder.build(
            sourceURL: sourceURL,
            chunkID: checkpoint.chunkID,
            createdAt: Date(timeIntervalSince1970: checkpoint.completedAtUnix)
        )
        guard build.aggregate.source.rawSHA256 == sealed.contentSHA256,
              build.aggregate.source.rawByteCount == sealed.byteCount,
              build.aggregate.source.rawRowCount == sealed.rowCount,
              catalogTimestampMatches(
                raw: build.aggregate.source.firstTimestamp,
                catalog: sealed.firstTimestamp
              ),
              catalogTimestampMatches(
                raw: build.aggregate.source.lastTimestamp,
                catalog: sealed.lastTimestamp
              ) else {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        return .init(chunkID: checkpoint.chunkID,
                     sourceURL: sourceURL,
                     aggregateBuild: build)
    }

    /// Catalog dates are persisted with Foundation's `.iso8601` strategy,
    /// which serializes whole seconds. Raw WHOOP rows retain 1/32,768-second
    /// precision. Digest, byte and row identities remain exact; timestamp
    /// comparison at this persistence boundary must use the catalog's actual
    /// representational precision.
    static func catalogTimestampMatches(raw: Date, catalog: Date?) -> Bool {
        guard let catalog else { return false }
        return floor(raw.timeIntervalSince1970)
            == floor(catalog.timeIntervalSince1970)
    }

    static func persistedISO8601Value<T: Codable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    static func persistedTimestamp(_ persisted: Date, coversStart raw: Date) -> Bool {
        persisted <= raw || catalogTimestampMatches(raw: raw, catalog: persisted)
    }

    static func persistedTimestamp(_ persisted: Date, coversEnd raw: Date) -> Bool {
        persisted >= raw || catalogTimestampMatches(raw: raw, catalog: persisted)
    }

    static func verifiedMetricTimestamps(
        in seal: TerminalCatalogSealResult,
        start: Date,
        end: Date,
        observedAfter: Date? = nil,
        observedBefore: Date? = nil
    ) throws -> [TimeInterval] {
        guard end > start,
              (observedAfter == nil) == (observedBefore == nil) else {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        if let observedAfter,
           let observedBefore,
           observedBefore < observedAfter {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        guard try AtriaHistoricalJSONLInput.identity(at: seal.sourceURL).sha256
                == seal.aggregateBuild.aggregate.source.rawSHA256,
              let descriptor = AtriaHistoricalJSONLRecentScanner
                .descriptors(for: [seal.sourceURL]).first else {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        var timestamps: [TimeInterval] = []
        timestamps.reserveCapacity(min(
            Int(end.timeIntervalSince(start).rounded(.up)),
            1_500_000
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = AtriaHistoricalJSONLRecentScanner.scan(
            sources: [.init(descriptor: descriptor, startOffset: 0)],
            cutoff: start.timeIntervalSince1970
        ) { line in
            guard timestamps.count < 1_500_000,
                  let record = try? decoder.decode(Record.self, from: line),
                  record.metricUsable,
                  let timestamp = AtriaHistoricalJSONLRecentScanner.timestamp(in: line),
                  timestamp >= start.timeIntervalSince1970,
                  timestamp < end.timeIntervalSince1970 else { return }
            if let observedAfter, let observedBefore {
                guard let envelope = try? decoder.decode(
                    HistoricalObservationEnvelope.self,
                    from: line
                ),
                      let observedAtUnix = envelope.observedAtUnix,
                      observedAtUnix >= observedAfter.timeIntervalSince1970,
                      observedAtUnix <= observedBefore.timeIntervalSince1970 else {
                    return
                }
            }
            timestamps.append(timestamp)
        }
        guard result.complete else {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        return timestamps
    }

    /// The raw archive injects this exact observation timestamp alongside the
    /// decoded record. It is deliberately separate from `capturedAt`: a frame
    /// replayed from strap flash may retain its original capture timestamp but
    /// must prove that this terminal attempt actually observed it.
    private struct HistoricalObservationEnvelope: Decodable {
        let observedAtUnix: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case observedAtUnix = "_atriaHistoryObservedAtUnix"
        }
    }

    /// Commits the already-sealed terminal aggregate, records a durable exact
    /// request-range completion, and publishes consumer artifacts derived from
    /// that attestation. This is the bounded runtime seam for the terminal BLE
    /// callback. The caller must supply the actual requested range; this method
    /// never widens it from file timestamps or local completion time.
    ///
    /// Raw retirement is deliberately impossible here: the aggregate commit
    /// uses `deleteSourceAfterCommit: false`, and consumer publication has no
    /// catalog-retirement API.
    static func materializeTerminalConsumerProjectionsAfterDrain(
        seal: TerminalCatalogSealResult,
        terminalBatchNumber: UInt64,
        durableSequence: UInt64,
        requestedStart: Date,
        requestedEnd: Date,
        completedAt: Date,
        configuration: AtriaHistoricalConsumerProjectionCoordinator.Configuration
    ) throws -> TerminalConsumerProjectionResult {
        let published = try publishTerminalCompletionAfterDrain(
            seal: seal,
            terminalBatchNumber: terminalBatchNumber,
            durableSequence: durableSequence,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completedAt: completedAt
        )
        let aggregates = archiveDirectory.appendingPathComponent("aggregates-v2", isDirectory: true)
        let manifests = archiveDirectory.appendingPathComponent(
            "retention-manifests-v2",
            isDirectory: true
        )
        let aggregateSnapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        ).load()
        let coordinator = AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: AtriaHistoricalDrainCompletionGenerationStore(
                directoryURL: archiveDirectory.appendingPathComponent(
                    "drain-completions-v1",
                    isDirectory: true
                )
            ),
            receiptLedger: .init(directoryURL: archiveDirectory.appendingPathComponent(
                "consumer-receipts-v1",
                isDirectory: true
            ))
        )
        let consumers = try coordinator.publishEligibleReceipts(
            catalogStore: try catalogStoreLocked(),
            aggregateSnapshot: aggregateSnapshot,
            configuration: configuration,
            lane: "terminal_materialize_after_drain"
        )
        return .init(aggregateCommit: published.aggregateCommit,
                     completion: published.completion,
                     consumers: consumers)
    }

    /// Publishes only the immutable aggregate and exact terminal completion.
    /// The caller must durably checkpoint this result before invoking any
    /// consumer projection publication.
    static func publishTerminalCompletionAfterDrain(
        seal: TerminalCatalogSealResult,
        terminalBatchNumber: UInt64,
        durableSequence: UInt64,
        requestedStart: Date,
        requestedEnd: Date,
        completedAt: Date
    ) throws -> TerminalCompletionPublicationResult {
        guard durableSequence > 0,
              requestedEnd > requestedStart,
              completedAt >= requestedEnd else {
            throw TerminalConsumerProjectionError.invalidTerminalAuthority
        }
        let aggregates = archiveDirectory.appendingPathComponent("aggregates-v2", isDirectory: true)
        let manifests = archiveDirectory.appendingPathComponent(
            "retention-manifests-v2",
            isDirectory: true
        )
        let transaction = AtriaHistoricalRetentionTransaction(
            now: { completedAt },
            semanticVerifier: AtriaHistoricalAggregateBuilder.verify
        )
        let aggregateCommit = try transaction.commit(.init(
            transactionID: seal.chunkID,
            sourceURL: seal.sourceURL,
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests,
            aggregate: seal.aggregateBuild.aggregate,
            semanticParityReceipt: seal.aggregateBuild.semanticParityReceipt,
            deleteSourceAfterCommit: false
        ))
        guard !aggregateCommit.sourceDeleted,
              FileManager.default.fileExists(atPath: seal.sourceURL.path) else {
            throw TerminalConsumerProjectionError.rawSourceWasNotRetained
        }

        let aggregateSnapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        ).load()
        let catalogStore = try catalogStoreLocked()
        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        try catalog.validate()
        let catalogData = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalCatalogData(catalog)
        let aggregateData = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalAggregateSnapshotData(aggregateSnapshot)
        let catalogSnapshotSHA256 =
            AtriaHistoricalDrainCompletionGenerationStore.sha256(catalogData)
        let aggregateSnapshotSHA256 =
            AtriaHistoricalDrainCompletionGenerationStore.sha256(aggregateData)
        let persistedAggregate = try persistedISO8601Value(
            seal.aggregateBuild.aggregate
        )
        guard aggregateSnapshot.diagnostics.rejectedManifests == 0,
              aggregateSnapshot.aggregates.contains(where: {
                  $0.source.chunkID == seal.chunkID
                      && $0 == persistedAggregate
              }) else {
            throw TerminalConsumerProjectionError.committedAggregateUnavailable
        }

        let completionStore = AtriaHistoricalDrainCompletionGenerationStore(
            directoryURL: archiveDirectory.appendingPathComponent(
                "drain-completions-v1",
                isDirectory: true
            )
        )
        let prior = try? completionStore.loadLatest()
        let generation = try terminalCompletionGeneration(
            prior: prior,
            terminalBatchNumber: terminalBatchNumber,
            durableSequence: durableSequence,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completedAt: completedAt,
            catalogGeneration: catalog.generation,
            catalogSnapshotSHA256: catalogSnapshotSHA256,
            aggregateSnapshotSHA256: aggregateSnapshotSHA256
        )
        // The archive queue is the single writer here, so the catalog and
        // aggregate snapshot verified above are invariant through this call.
        // Reusing their canonical encodings avoids a second file re-stat and
        // whole-snapshot encode; the persisted digest bytes are identical.
        let completion = try completionStore.recordTerminal(
            generation: generation,
            terminalBatchNumber: terminalBatchNumber,
            durableSequence: durableSequence,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completedAt: completedAt,
            verifiedCatalog: catalog,
            catalogData: catalogData,
            aggregateData: aggregateData
        )
        return .init(aggregateCommit: aggregateCommit,
                     completion: completion)
    }

    /// A terminal transport can be retried after the catalog gains verified
    /// metadata for older immutable chunks. Reuse its completion generation
    /// only when the entire attested catalog+aggregate snapshot is unchanged;
    /// otherwise publish a later generation instead of conflicting with the
    /// already-durable content-addressed record.
    static func terminalCompletionGeneration(
        prior: AtriaHistoricalDrainCompletionGenerationStore.Record?,
        terminalBatchNumber: UInt64,
        durableSequence: UInt64,
        requestedStart: Date,
        requestedEnd: Date,
        completedAt: Date,
        catalogGeneration: UInt64,
        catalogSnapshotSHA256: String,
        aggregateSnapshotSHA256: String
    ) throws -> UInt64 {
        if let prior,
           prior.terminalBatchNumber == terminalBatchNumber,
           prior.durableSequence == durableSequence,
           catalogTimestampMatches(raw: requestedStart, catalog: prior.requestedStart),
           catalogTimestampMatches(raw: requestedEnd, catalog: prior.requestedEnd),
           catalogTimestampMatches(raw: completedAt, catalog: prior.completedAt),
           prior.catalogGeneration == catalogGeneration,
           prior.catalogSnapshotSHA256 == catalogSnapshotSHA256,
           prior.aggregateSnapshotSHA256 == aggregateSnapshotSHA256 {
            return prior.generation
        }
        let priorGeneration = prior?.generation ?? 0
        guard priorGeneration < UInt64.max else {
            throw TerminalConsumerProjectionError.completionGenerationExhausted
        }
        let next = priorGeneration + 1
        guard next > 0 else {
            throw TerminalConsumerProjectionError.completionGenerationExhausted
        }
        return next
    }

    /// Commits a terminal full-scan aggregate without claiming that WHOOP
    /// honored an exact time range. This is the evidence source for settling a
    /// previously recovered chunk's wider consumer dependencies.
    static func publishFullScanAggregateAfterDrain(
        seal: TerminalCatalogSealResult,
        completedAt: Date
    ) throws -> FullScanAggregatePublicationResult {
        let aggregates = archiveDirectory.appendingPathComponent(
            "aggregates-v2", isDirectory: true
        )
        let manifests = archiveDirectory.appendingPathComponent(
            "retention-manifests-v2", isDirectory: true
        )
        let aggregateCommit = try AtriaHistoricalRetentionTransaction(
            now: { completedAt },
            semanticVerifier: AtriaHistoricalAggregateBuilder.verify
        ).commit(.init(
            transactionID: seal.chunkID,
            sourceURL: seal.sourceURL,
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests,
            aggregate: seal.aggregateBuild.aggregate,
            semanticParityReceipt: seal.aggregateBuild.semanticParityReceipt,
            deleteSourceAfterCommit: false
        ))
        guard !aggregateCommit.sourceDeleted,
              FileManager.default.fileExists(atPath: seal.sourceURL.path) else {
            throw TerminalConsumerProjectionError.rawSourceWasNotRetained
        }
        return try currentFullScanSnapshotEvidence(
            sourceChunkID: seal.aggregateBuild.aggregate.source.chunkID,
            sourceRawSHA256: seal.aggregateBuild.aggregate.source.rawSHA256,
            aggregateCommit: aggregateCommit
        )
    }

    /// Produces a new terminal-scan checkpoint when the strap replayed only
    /// rows already present in the archive. The snapshot and source are fully
    /// revalidated; only the later strap cursor is new evidence.
    static func currentFullScanSnapshotEvidence(
        sourceChunkID: String,
        sourceRawSHA256: String
    ) throws -> FullScanAggregatePublicationResult {
        try currentFullScanSnapshotEvidence(
            sourceChunkID: sourceChunkID,
            sourceRawSHA256: sourceRawSHA256,
            aggregateCommit: nil
        )
    }

    /// Cheap retry identity for terminal consumer publication admission.
    ///
    /// This intentionally hashes only immutable sealed catalog identity from
    /// the already-loaded image; it does not verify raw files or load aggregate
    /// manifests. Ordinary live appends mutate the active chunk byte count and
    /// must not re-arm a watchdog-producing scan. Sealing/rotation, retention,
    /// or repaired immutable metadata advances the generation/sealed identity,
    /// so genuinely new consumer input invalidates the cached failure.
    static func terminalConsumerRetryCatalogFingerprint() -> String? {
        guard let catalog = try? catalogStoreLocked().snapshot() else {
            return nil
        }
        let sealedIdentity = catalog.chunks
            .filter { $0.state == .sealed }
            .sorted { $0.id < $1.id }
            .map { chunk in
                [
                    chunk.id,
                    chunk.contentSHA256 ?? "missing",
                    String(chunk.byteCount),
                    chunk.rowCount.map(String.init) ?? "unknown",
                    chunk.firstTimestamp.map {
                        String(Int64((
                            $0.timeIntervalSince1970 * 1_000
                        ).rounded()))
                    } ?? "unknown",
                    chunk.lastTimestamp.map {
                        String(Int64((
                            $0.timeIntervalSince1970 * 1_000
                        ).rounded()))
                    } ?? "unknown",
                    chunk.compressedStorage?.storedSHA256 ?? "plain",
                ].joined(separator: ":")
            }
            .joined(separator: "|")
        let digest = AtriaHistoricalDrainCompletionGenerationStore.sha256(
            Data(sealedIdentity.utf8)
        )
        return [
            "terminal_retry_catalog_v1",
            String(catalog.generation),
            catalog.activeChunkID,
            digest,
        ].joined(separator: "|")
    }

    private static func currentFullScanSnapshotEvidence(
        sourceChunkID: String,
        sourceRawSHA256: String,
        aggregateCommit: AtriaHistoricalRetentionTransaction.Result?
    ) throws -> FullScanAggregatePublicationResult {
        let aggregates = archiveDirectory.appendingPathComponent(
            "aggregates-v2", isDirectory: true
        )
        let manifests = archiveDirectory.appendingPathComponent(
            "retention-manifests-v2", isDirectory: true
        )
        let snapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        ).load()
        let catalog = try catalogStoreLocked().snapshotVerifiedAgainstFiles()
        guard !snapshot.diagnostics.limitExceeded,
              snapshot.diagnostics.rejectedManifests == 0,
              let source = snapshot.aggregates.first(where: {
                  $0.source.chunkID == sourceChunkID
                    && $0.source.rawSHA256 == sourceRawSHA256
              }),
              catalog.chunks.contains(where: {
                  $0.id == sourceChunkID && $0.contentSHA256 == sourceRawSHA256
              }) else {
            throw TerminalConsumerProjectionError.committedAggregateUnavailable
        }
        return .init(
            aggregateCommit: aggregateCommit,
            source: source.source,
            observedArchiveFirstTimestamp: snapshot.aggregates
                .map(\.source.firstTimestamp).min()
                ?? source.source.firstTimestamp,
            catalogGeneration: catalog.generation,
            catalogSnapshotSHA256: AtriaHistoricalDrainCompletionGenerationStore.sha256(
                try AtriaHistoricalActivityInspectionProofFactory.canonicalCatalogData(catalog)
            ),
            aggregateSnapshotSHA256: AtriaHistoricalDrainCompletionGenerationStore.sha256(
                try AtriaHistoricalActivityInspectionProofFactory
                    .canonicalAggregateSnapshotData(snapshot)
            )
        )
    }

    static func earliestCommittedAggregateTimestamp() -> Date? {
        AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: archiveDirectory.appendingPathComponent(
                "aggregates-v2", isDirectory: true
            ),
            manifestDirectoryURL: archiveDirectory.appendingPathComponent(
                "retention-manifests-v2", isDirectory: true
            )
        ).load().aggregates.map(\.source.firstTimestamp).min()
    }

    /// Resumes publication from an already-durable terminal completion without
    /// requiring another raw chunk. This is the crash path for a completion
    /// followed by only a prefix of the five consumer receipts. Every immutable
    /// input is re-read and re-verified; raw remains present and is never
    /// retired by this path.
    static func resumeTerminalConsumerProjectionsAfterCrash(
        job: AtriaBLEHistoryTerminalPublicationStore.Job,
        configuration: AtriaHistoricalConsumerProjectionCoordinator.Configuration
    ) throws -> TerminalConsumerProjectionResumeResult {
        try resumeTerminalConsumerProjectionsAfterCrash(
            job: job,
            archiveRoot: archiveDirectory,
            catalogStore: try catalogStoreLocked(),
            configuration: configuration
        )
    }

    /// Dependency-injected overload used by crash/restart tests.
    static func resumeTerminalConsumerProjectionsAfterCrash(
        job: AtriaBLEHistoryTerminalPublicationStore.Job,
        archiveRoot: URL,
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        configuration: AtriaHistoricalConsumerProjectionCoordinator.Configuration
    ) throws -> TerminalConsumerProjectionResumeResult {
        guard job.status == .completionPublished
                || job.status == .projectionsPublished
                || job.status == .authorityConsumed,
              job.durableSequence > 0,
              job.exactRequest.requestedEnd > job.exactRequest.requestedStart,
              job.completedAt >= job.exactRequest.requestedEnd else {
            throw TerminalConsumerProjectionError.invalidResumeJob
        }

        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        try catalog.validate()
        guard let chunk = catalog.chunks.first(where: { $0.id == job.chunkID }),
              chunk.state == .sealed,
              chunk.rowCount != nil,
              chunk.firstTimestamp != nil,
              chunk.lastTimestamp != nil,
              chunk.contentSHA256 != nil else {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        let sourceURL = archiveRoot.appendingPathComponent(chunk.relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw TerminalConsumerProjectionError.rawSourceWasNotRetained
        }

        let aggregates = archiveRoot.appendingPathComponent("aggregates-v2", isDirectory: true)
        let manifests = archiveRoot.appendingPathComponent(
            "retention-manifests-v2",
            isDirectory: true
        )
        let aggregateSnapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        ).load()
        guard aggregateSnapshot.diagnostics.rejectedManifests == 0,
              let aggregate = aggregateSnapshot.aggregates.first(where: {
                  $0.source.chunkID == job.chunkID
              }),
              aggregate.source.rawSHA256 == chunk.contentSHA256,
              aggregate.source.rawByteCount == chunk.byteCount,
              aggregate.source.rawRowCount == chunk.rowCount,
              catalogTimestampMatches(
                raw: aggregate.source.firstTimestamp,
                catalog: chunk.firstTimestamp
              ),
              catalogTimestampMatches(
                raw: aggregate.source.lastTimestamp,
                catalog: chunk.lastTimestamp
              ),
              try AtriaHistoricalAggregateBuilder.verify(
                  sourceURL: sourceURL,
                  aggregate: aggregate,
                  semanticParityReceipt: AtriaHistoricalAggregateBuilder
                      .semanticParityReceipt(for: aggregate)
              ) else {
            throw TerminalConsumerProjectionError.resumeAggregateUnavailable
        }

        let completionStore = AtriaHistoricalDrainCompletionGenerationStore(
            directoryURL: archiveRoot.appendingPathComponent(
                "drain-completions-v1",
                isDirectory: true
            )
        )
        let completion = try completionStore.loadLatest()
        let catalogData = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalCatalogData(catalog)
        let aggregateData = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalAggregateSnapshotData(aggregateSnapshot)
        guard completion.terminalBatchNumber == job.terminalBatchNumber,
              completion.durableSequence == job.durableSequence,
              completion.requestedStart == job.exactRequest.requestedStart,
              completion.requestedEnd == job.exactRequest.requestedEnd,
              completion.completedAt == job.completedAt,
              completion.catalogGeneration == catalog.generation,
              completion.catalogSnapshotSHA256
                == AtriaHistoricalDrainCompletionGenerationStore.sha256(catalogData),
              completion.aggregateSnapshotSHA256
                == AtriaHistoricalDrainCompletionGenerationStore.sha256(aggregateData) else {
            throw TerminalConsumerProjectionError.resumeCompletionMismatch
        }

        let coordinator = AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: completionStore,
            receiptLedger: .init(directoryURL: archiveRoot.appendingPathComponent(
                "consumer-receipts-v1",
                isDirectory: true
            ))
        )
        // The catalog was file-verified and canonically encoded above on the
        // same serialized archive flow; reuse that evidence instead of
        // re-stat/re-encode once per source inside the coordinator loop.
        let consumers = try coordinator.publishEligibleReceipts(
            verifiedCatalog: catalog,
            catalogData: catalogData,
            aggregateSnapshot: aggregateSnapshot,
            aggregateData: aggregateData,
            configuration: configuration,
            lane: "terminal_crash_resume"
        )
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw TerminalConsumerProjectionError.rawSourceWasNotRetained
        }
        return .init(completion: completion, consumers: consumers)
    }

    static func resumeFullDrainConsumerProjectionsAfterCrash(
        checkpoint: AtriaHistoricalFullDrainCoverageStore.PublicationCheckpoint,
        requestedStart: Date,
        requestedEnd: Date,
        configuration: AtriaHistoricalConsumerProjectionCoordinator.Configuration
    ) throws -> TerminalConsumerProjectionResumeResult {
        guard checkpoint.status == .completionPublished
                || checkpoint.status == .projectionsPublished,
              checkpoint.durableSequence > 0,
              requestedEnd > requestedStart,
              Date(timeIntervalSince1970: checkpoint.completedAtUnix) >= requestedEnd else {
            throw TerminalConsumerProjectionError.invalidResumeJob
        }
        let catalogStore = try catalogStoreLocked()
        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        try catalog.validate()
        guard let chunk = catalog.chunks.first(where: {
            $0.id == checkpoint.chunkID && $0.state == .sealed
        }), chunk.rowCount != nil,
           chunk.firstTimestamp != nil,
           chunk.lastTimestamp != nil,
           chunk.contentSHA256 != nil else {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        let sourceURL = archiveDirectory.appendingPathComponent(chunk.relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw TerminalConsumerProjectionError.rawSourceWasNotRetained
        }
        let aggregateSnapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: archiveDirectory.appendingPathComponent(
                "aggregates-v2", isDirectory: true
            ),
            manifestDirectoryURL: archiveDirectory.appendingPathComponent(
                "retention-manifests-v2", isDirectory: true
            )
        ).load()
        guard aggregateSnapshot.diagnostics.rejectedManifests == 0,
              let aggregate = aggregateSnapshot.aggregates.first(where: {
                  $0.source.chunkID == checkpoint.chunkID
              }),
              aggregate.source.rawSHA256 == chunk.contentSHA256,
              aggregate.source.rawByteCount == chunk.byteCount,
              aggregate.source.rawRowCount == chunk.rowCount,
              catalogTimestampMatches(
                raw: aggregate.source.firstTimestamp,
                catalog: chunk.firstTimestamp
              ),
              catalogTimestampMatches(
                raw: aggregate.source.lastTimestamp,
                catalog: chunk.lastTimestamp
              ),
              try AtriaHistoricalAggregateBuilder.verify(
                  sourceURL: sourceURL,
                  aggregate: aggregate,
                  semanticParityReceipt: AtriaHistoricalAggregateBuilder
                    .semanticParityReceipt(for: aggregate)
              ) else { throw TerminalConsumerProjectionError.resumeAggregateUnavailable }
        let completionStore = AtriaHistoricalDrainCompletionGenerationStore(
            directoryURL: archiveDirectory.appendingPathComponent(
                "drain-completions-v1", isDirectory: true
            )
        )
        let completion = try completionStore.loadLatest()
        let catalogData = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalCatalogData(catalog)
        let aggregateData = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalAggregateSnapshotData(aggregateSnapshot)
        guard completion.terminalBatchNumber == checkpoint.terminalBatchNumber,
              completion.durableSequence == checkpoint.durableSequence,
              catalogTimestampMatches(
                raw: requestedStart,
                catalog: completion.requestedStart
              ),
              catalogTimestampMatches(
                raw: requestedEnd,
                catalog: completion.requestedEnd
              ),
              catalogTimestampMatches(
                raw: Date(timeIntervalSince1970: checkpoint.completedAtUnix),
                catalog: completion.completedAt
              ),
              completion.catalogGeneration == catalog.generation,
              completion.catalogSnapshotSHA256
                == AtriaHistoricalDrainCompletionGenerationStore.sha256(catalogData),
              completion.aggregateSnapshotSHA256
                == AtriaHistoricalDrainCompletionGenerationStore.sha256(aggregateData) else {
            throw TerminalConsumerProjectionError.resumeCompletionMismatch
        }
        let consumers = try AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: completionStore,
            receiptLedger: .init(directoryURL: archiveDirectory.appendingPathComponent(
                "consumer-receipts-v1", isDirectory: true
            ))
        ).publishReceiptSet(
            for: checkpoint.chunkID,
            verifiedCatalog: catalog,
            catalogData: catalogData,
            aggregateSnapshot: aggregateSnapshot,
            aggregateData: aggregateData,
            configuration: configuration
        )
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw TerminalConsumerProjectionError.rawSourceWasNotRetained
        }
        return .init(completion: completion, consumers: consumers)
    }

    /// Publishes the five typed artifacts for one source whose original exact
    /// gap was already resolved but whose wider dependency range is now closed
    /// by a later strap-cursor-bound full scan. No BLE work or raw retirement
    /// occurs here.
    static func publishPendingConsumersUsingLatestFullScan(
        dependency: AtriaHistoricalFullDrainCoverageStore.PendingConsumerDependency,
        fullScanStore: AtriaHistoricalFullScanCompletionStore,
        configuration: AtriaHistoricalConsumerProjectionConfiguration
    ) throws -> AtriaHistoricalConsumerProjectionCoordinator.Report {
        let catalogStore = try catalogStoreLocked()
        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        guard let sourceChunk = catalog.chunks.first(where: {
            $0.id == dependency.sourceChunkID
        }), sourceChunk.contentSHA256 == dependency.sourceRawSHA256 else {
            throw TerminalConsumerProjectionError.resumeChunkUnavailable
        }
        let sourceURL = archiveDirectory.appendingPathComponent(sourceChunk.relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw TerminalConsumerProjectionError.rawSourceWasNotRetained
        }
        let aggregateSnapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: archiveDirectory.appendingPathComponent(
                "aggregates-v2", isDirectory: true
            ),
            manifestDirectoryURL: archiveDirectory.appendingPathComponent(
                "retention-manifests-v2", isDirectory: true
            )
        ).load()
        return try AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: AtriaHistoricalDrainCompletionGenerationStore(
                directoryURL: archiveDirectory.appendingPathComponent(
                    "drain-completions-v1", isDirectory: true
                )
            ),
            receiptLedger: .init(directoryURL: archiveDirectory.appendingPathComponent(
                "consumer-receipts-v1", isDirectory: true
            ))
        ).publishReceiptSetUsingFullScan(
            for: dependency.sourceChunkID,
            expectedRawSHA256: dependency.sourceRawSHA256,
            requiredStart: Date(timeIntervalSince1970: dependency.requiredStartUnix),
            requiredEnd: Date(timeIntervalSince1970: dependency.requiredEndUnix),
            fullScanStore: fullScanStore,
            catalogStore: catalogStore,
            aggregateSnapshot: aggregateSnapshot,
            configuration: configuration
        )
    }

    /// Publishes and immediately re-reads one five-artifact app-facing consumer
    /// set plus the independently durable exact replay-identity shard for an
    /// already committed shadow aggregate. This is deliberately not retirement
    /// authority: it cannot edit the aggregate, catalog, manifest, mark a chunk
    /// retired, or delete raw. Missing, stale, or too-narrow terminal completion
    /// evidence fails closed; this path never manufactures a completion record.
    static func publishAndVerifyHistoricalConsumerCutover(
        chunkID: String,
        archiveRoot: URL,
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        configuration: AtriaHistoricalConsumerProjectionConfiguration,
        receiptLedger injectedLedger: AtriaHistoricalConsumerReceiptLedger? = nil
    ) throws -> HistoricalConsumerCutoverResult {
        let aggregates = archiveRoot.appendingPathComponent("aggregates-v2", isDirectory: true)
        let manifests = archiveRoot.appendingPathComponent(
            "retention-manifests-v2",
            isDirectory: true
        )
        let aggregateReader = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        )
        let snapshot = aggregateReader.load()
        let matchingAggregates = snapshot.aggregates.filter { $0.source.chunkID == chunkID }
        guard !snapshot.diagnostics.limitExceeded,
              snapshot.diagnostics.rejectedManifests == 0,
              matchingAggregates.count == 1,
              let aggregate = matchingAggregates.first else {
            throw HistoricalConsumerCutoverError.committedShadowUnavailable
        }

        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        guard let rawChunk = catalog.chunks.first(where: { $0.id == chunkID }),
              rawChunk.state == .sealed,
              rawChunk.contentSHA256 == aggregate.source.rawSHA256,
              rawChunk.byteCount == aggregate.source.rawByteCount,
              rawChunk.rowCount == aggregate.source.rawRowCount,
              catalogTimestampMatches(
                raw: aggregate.source.firstTimestamp,
                catalog: rawChunk.firstTimestamp
              ),
              catalogTimestampMatches(
                raw: aggregate.source.lastTimestamp,
                catalog: rawChunk.lastTimestamp
              ) else {
            throw HistoricalConsumerCutoverError.rawSourceUnavailable
        }
        let rawURL = archiveRoot.appendingPathComponent(rawChunk.relativePath)
        // Compare the retained source's decoded identity — transparently
        // inflating a compressed artifact — against the committed aggregate, so
        // compressed shards verify by content, not physical bytes. Plaintext
        // sources are read verbatim, so their behavior is unchanged.
        guard FileManager.default.fileExists(atPath: rawURL.path),
              let rawIdentity = try? AtriaHistoricalJSONLInput.identity(at: rawURL),
              rawIdentity.byteCount == aggregate.source.rawByteCount,
              rawIdentity.sha256 == aggregate.source.rawSHA256 else {
            throw HistoricalConsumerCutoverError.rawSourceUnavailable
        }
        let ledgerSource = AtriaHistoricalConsumerReceiptLedger.Source(
            chunkID: aggregate.source.chunkID,
            rawSHA256: aggregate.source.rawSHA256,
            firstTimestamp: aggregate.source.firstTimestamp,
            lastTimestamp: aggregate.source.lastTimestamp
        )

        let completionStore = AtriaHistoricalDrainCompletionGenerationStore(
            directoryURL: archiveRoot.appendingPathComponent(
                "drain-completions-v1",
                isDirectory: true
            )
        )
        let completion: AtriaHistoricalDrainCompletionGenerationStore.Record
        do {
            completion = try completionStore.loadLatest()
        } catch {
            throw HistoricalConsumerCutoverError.terminalCompletionAttestationUnavailable
        }
        let ledger = injectedLedger ?? .init(
            directoryURL: archiveRoot.appendingPathComponent(
                "consumer-receipts-v1",
                isDirectory: true
            )
        )
        let report = try AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: completionStore,
            receiptLedger: ledger
        ).publishReceiptSet(
            for: chunkID,
            catalogStore: catalogStore,
            aggregateSnapshot: snapshot,
            configuration: configuration
        )
        let expectedKinds: Set<AtriaHistoricalConsumerReceiptLedger.ProjectionKind> = [
            .activity, .dailyMetrics, .steps, .sleep, .workout,
        ]
        guard report.completionGeneration == completion.generation,
              report.inspectedSourceCount == 1,
              report.deferredSources.isEmpty else {
            throw HistoricalConsumerCutoverError.terminalCompletionAttestationRejected
        }
        guard report.published.count == AtriaHistoricalConsumerProjectionCoordinator
                .Report.artifactsPerCompleteSource,
              Set(report.published.map(\.receipt.kind)) == expectedKinds,
              report.published.allSatisfy({ $0.receipt.source == ledgerSource }) else {
            throw HistoricalConsumerCutoverError.receiptPublicationIncomplete
        }

        let verified = AtriaHistoricalVerifiedConsumerReader(
            aggregateReader: aggregateReader,
            completionStore: completionStore,
            receiptLedger: ledger
        ).readSource(
            chunkID: chunkID,
            catalogStore: catalogStore,
            configuration: configuration
        )
        guard verified.hasCompleteConsumerCoverage,
              let identity = verified.verificationIdentity,
              identity.completionGeneration == completion.generation,
              identity.source == ledgerSource,
              identity.receipts.count == expectedKinds.count,
              Set(identity.receipts.map(\.kind)) == expectedKinds else {
            throw HistoricalConsumerCutoverError.typedVerificationIncomplete
        }

        // Replay identity is deliberately outside `activateCurrentSet`: app
        // readers retain their bounded atomic five-artifact contract, while the
        // retention audit also proves every exact schema-v2 replay key directly
        // from the still-sealed raw source.
        let replay = try AtriaHistoricalReplayIdentityShard.publishReceipt(
            sourceURL: rawURL,
            source: aggregate.source,
            ledger: ledger,
            settledAt: completion.completedAt
        )
        let typedReceipts = Dictionary(uniqueKeysWithValues: identity.receipts.map {
            ($0.kind, $0)
        })
        var canonicalArtifacts: [AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact] = []
        let projections = try ledger.validatedMaterializedProjections(
            for: ledgerSource
        ) { receipt, artifact in
            if receipt.kind == .replayIdentity {
                guard receipt == replay.receipt else { return false }
                let valid = try AtriaHistoricalReplayIdentityShard.verifyReceipt(
                    receipt,
                    artifact: artifact,
                    sourceURL: rawURL,
                    source: aggregate.source
                )
                if valid { canonicalArtifacts.append(.init(receipt: receipt, artifact: artifact)) }
                return valid
            }
            // These exact immutable receipt+artifact digests were semantically
            // decoded by the typed reader above. Matching the whole receipt
            // binds this audit scan to that verification rather than accepting
            // an older receipt produced by another configuration generation.
            let valid = typedReceipts[receipt.kind] == receipt
            if valid { canonicalArtifacts.append(.init(receipt: receipt, artifact: artifact)) }
            return valid
        }
        let requiredKinds = AtriaHistoricalAggregateChunk
            .rawRetirementRequiredProjectionKinds
        guard projections.count == requiredKinds.count,
              Set(projections.map(\.kind)) == requiredKinds else {
            throw HistoricalConsumerCutoverError.typedVerificationIncomplete
        }

        // Projection receipts are immutable staging evidence. Apply the exact
        // six verified artifacts to the five downstream destinations and only
        // then publish the atomic application proof. Its verifier re-opens each
        // destination snapshot and binds every payload digest to this identity.
        let canonicalIdentity = AtriaHistoricalCanonicalConsumerApplicationStore
            .VerificationIdentity(typed: identity, replayReceipt: replay.receipt)
        let canonicalRoot = archiveRoot.appendingPathComponent(
            "canonical-consumers-v1", isDirectory: true
        )
        let canonicalAdapter = AtriaHistoricalCanonicalConsumerApplicationAdapter(
            destinationStore: .init(directoryURL: canonicalRoot.appendingPathComponent(
                "destinations", isDirectory: true
            )),
            proofDirectoryURL: canonicalRoot.appendingPathComponent(
                "application-proofs", isDirectory: true
            )
        )
        let canonicalApplied = try canonicalAdapter.apply(
            identity: canonicalIdentity,
            artifacts: canonicalArtifacts,
            appliedAt: Date()
        )
        let canonicalReadback = try canonicalAdapter.validatedCurrent(
            identity: canonicalIdentity
        )
        guard canonicalReadback == canonicalApplied,
              canonicalReadback.applications.count
                == AtriaHistoricalCanonicalConsumerApplicationStore.Consumer.allCases.count else {
            throw HistoricalConsumerCutoverError.typedVerificationIncomplete
        }

        // The replay shard can be large. Refuse to return a mixed-generation
        // audit if terminal authority or the atomic five-receipt app pointer
        // advanced while it was scanned.
        let finalCompletion: AtriaHistoricalDrainCompletionGenerationStore.Record
        let finalCurrentSet: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind:
            AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact]
        do {
            finalCompletion = try completionStore.loadLatest()
            finalCurrentSet = try ledger.validatedCurrentSet(for: ledgerSource)
        } catch {
            throw HistoricalConsumerCutoverError.typedVerificationIncomplete
        }
        guard finalCompletion == completion else {
            throw HistoricalConsumerCutoverError.terminalCompletionAttestationRejected
        }
        let finalCurrentReceipts = Dictionary(uniqueKeysWithValues: finalCurrentSet.map {
            ($0.key, $0.value.receipt)
        })
        guard finalCurrentReceipts.count == expectedKinds.count,
              finalCurrentReceipts == typedReceipts else {
            throw HistoricalConsumerCutoverError.typedVerificationIncomplete
        }

        // Close the audit with fresh file-backed evidence. No result escapes if
        // the aggregate/manifest, sealed catalog row, raw length, or raw digest
        // changed while the six artifacts were being published and re-read.
        let finalSnapshot = aggregateReader.load()
        let finalMatches = finalSnapshot.aggregates.filter { $0.source.chunkID == chunkID }
        let finalCatalog = try catalogStore.snapshotVerifiedAgainstFiles()
        guard !finalSnapshot.diagnostics.limitExceeded,
              finalSnapshot.diagnostics.rejectedManifests == 0,
              finalMatches.count == 1,
              finalMatches.first == aggregate,
              finalCatalog.chunks.first(where: { $0.id == chunkID }) == rawChunk,
              rawChunk.state == .sealed,
              FileManager.default.fileExists(atPath: rawURL.path),
              let finalRawIdentity = try? AtriaHistoricalJSONLInput.identity(at: rawURL),
              finalRawIdentity.byteCount == aggregate.source.rawByteCount,
              finalRawIdentity.sha256 == aggregate.source.rawSHA256 else {
            throw HistoricalConsumerCutoverError.rawSourceWasNotRetained
        }
        return .init(
            chunkID: chunkID,
            completionGeneration: completion.generation,
            receiptCount: projections.count,
            reusedReceiptCount: report.published.filter(\.reusedExistingReceipt).count
                + (replay.reusedExistingReceipt ? 1 : 0),
            receiptKinds: projections.map(\.kind).sorted { $0.rawValue < $1.rawValue },
            canonicalApplicationCount: canonicalReadback.applications.count,
            canonicalApplicationIdentitySHA256: canonicalReadback.verificationIdentitySHA256,
            rawSourceURL: rawURL
        )
    }

    enum TerminalConsumerProjectionError: Error, Equatable {
        case invalidTerminalAuthority
        case rawSourceWasNotRetained
        case committedAggregateUnavailable
        case completionGenerationExhausted
        case invalidResumeJob
        case resumeChunkUnavailable
        case resumeAggregateUnavailable
        case resumeCompletionMismatch
    }

    static func endDurableDrain(generation: UInt64) {
        durableStoreLock.lock()
        let batch = durableDrainBatches.removeValue(forKey: generation)
        if let batch {
            durableStore?.abandon(batch)
        }
        durableStoreLock.unlock()
        discardDurableDiagnostics(generation: generation)
    }

    private static func durableStoreLocked() throws -> AtriaHistoricalArchiveDurableStore {
        if let durableStore { return durableStore }
        var archives = [fileURL, legacyFileURL]
        archives.append(contentsOf: rotatedSegmentFileURLs())
        let store = try AtriaHistoricalArchiveDurableStore(
            indexURL: archiveDirectory.appendingPathComponent("historical-archive.identity.jsonl"),
            existingArchiveURLs: archives
        )
        durableStore = store
        return store
    }

    static func diagnostics() -> Diagnostics {
        // A catalog-v2 install may have no legacy base file at all. Diagnose
        // the newest real raw chunk rather than treating that healthy layout as
        // a missing archive.
        guard let url = recentReadableFileURLs().first else {
            return Diagnostics(exists: false,
                               parseOK: true,
                               rows: 0,
                               bytes: 0,
                               schemas: [],
                               layoutVersions: [],
                               metricUsableRows: 0,
                               currentSessionUsableRows: 0,
                               undecodableRows: 0,
                               rawPayloadRows: 0,
                               unixFirst: nil,
                               unixLast: nil,
                               correctedUnixFirst: nil,
                               correctedUnixLast: nil,
                               gravityRows: 0,
                               gravityValidatedRows: 0,
                               reason: "missing_archive")
        }

        let attributes = archiveAttributes(for: url)
        let byteCount = attributes.byteCount
        if let index = readDiagnosticsIndex(for: url, attributes: attributes) {
            let segmentIndexes = rotatedSegmentFileURLs()
                .filter { $0.standardizedFileURL != url.standardizedFileURL }
                .compactMap { segmentURL -> DiagnosticsIndex? in
                let segmentAttributes = archiveAttributes(for: segmentURL)
                if let segmentIndex = readDiagnosticsIndex(for: segmentURL, attributes: segmentAttributes) {
                    return segmentIndex
                }
                guard segmentAttributes.byteCount <= 8 * 1024 * 1024,
                      let segmentIndex = scanDiagnosticsIndex(for: segmentURL, attributes: segmentAttributes) else {
                    return nil
                }
                writeDiagnosticsIndex(segmentIndex, for: segmentURL)
                return segmentIndex
            }
            if !segmentIndexes.isEmpty {
                let aggregate = aggregateDiagnosticsIndex(base: index, segments: segmentIndexes)
                return diagnostics(from: aggregate, reason: "aggregate_index_ok")
            }
            return diagnostics(from: index, reason: index.rows > 0 ? "index_ok" : "empty_archive_index")
        }

        guard attributes.byteCount <= maxImmediateDiagnosticsScanBytes else {
            let probe = quickMetricReadinessProbe()
            return Diagnostics(exists: true,
                               parseOK: true,
                               rows: probe.rowsScanned,
                               bytes: byteCount,
                               schemas: [],
                               layoutVersions: [],
                               metricUsableRows: probe.metricUsableRows,
                               currentSessionUsableRows: probe.currentSessionUsableRows,
                               undecodableRows: 0,
                               rawPayloadRows: 0,
                               unixFirst: nil,
                               unixLast: nil,
                               correctedUnixFirst: nil,
                               correctedUnixLast: nil,
                               gravityRows: 0,
                               gravityValidatedRows: 0,
                               reason: "large_archive_index_missing_probe_\(probe.reason)")
        }

        if let index = scanDiagnosticsIndex(for: url, attributes: attributes) {
            writeDiagnosticsIndex(index, for: url)
            return diagnostics(from: index, reason: index.rows > 0 ? "scanned_index_written" : "empty_archive")
        } else {
            return Diagnostics(exists: true,
                               parseOK: false,
                               rows: 0,
                               bytes: byteCount,
                               schemas: [],
                               layoutVersions: [],
                               metricUsableRows: 0,
                               currentSessionUsableRows: 0,
                               undecodableRows: 0,
                               rawPayloadRows: 0,
                               unixFirst: nil,
                               unixLast: nil,
                               correctedUnixFirst: nil,
                               correctedUnixLast: nil,
                               gravityRows: 0,
                               gravityValidatedRows: 0,
                               reason: "read_failed")
        }
    }

    static func quickMetricReadinessProbe(maxRows: Int = 20_000) -> MetricReadinessProbe {
        let url = readableFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return MetricReadinessProbe(ready: false,
                                        rowsScanned: 0,
                                        metricUsableRows: 0,
                                        currentSessionUsableRows: 0,
                                        reason: "missing_archive")
        }
        guard let stream = InputStream(url: url) else {
            return MetricReadinessProbe(ready: false,
                                        rowsScanned: 0,
                                        metricUsableRows: 0,
                                        currentSessionUsableRows: 0,
                                        reason: "read_failed")
        }
        stream.open()
        defer { stream.close() }

        var rowsScanned = 0
        var metricRows = 0
        var currentRows = 0
        var lineBuffer = ""
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while stream.hasBytesAvailable && rowsScanned < maxRows {
            let readCount = stream.read(&buffer, maxLength: chunkSize)
            if readCount < 0 {
                return MetricReadinessProbe(ready: false,
                                            rowsScanned: rowsScanned,
                                            metricUsableRows: metricRows,
                                            currentSessionUsableRows: currentRows,
                                            reason: "read_failed")
            }
            if readCount == 0 { break }
            lineBuffer += String(decoding: buffer.prefix(readCount), as: UTF8.self)
            while let newlineRange = lineBuffer.range(of: "\n"), rowsScanned < maxRows {
                let line = String(lineBuffer[..<newlineRange.lowerBound])
                lineBuffer.removeSubrange(..<newlineRange.upperBound)
                guard !line.isEmpty else { continue }
                rowsScanned += 1
                if let data = line.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if metricUsable(object: object) { metricRows += 1 }
                    if object["currentSessionUsable"] as? Bool == true { currentRows += 1 }
                }
                if metricRows > 0 {
                    return MetricReadinessProbe(ready: true,
                                                rowsScanned: rowsScanned,
                                                metricUsableRows: metricRows,
                                                currentSessionUsableRows: currentRows,
                                                reason: currentRows > 0 ? "metric_ready" : "metric_ready_without_explicit_current_flag")
                }
            }
        }

        if rowsScanned < maxRows, !lineBuffer.isEmpty {
            rowsScanned += 1
            if let data = lineBuffer.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if metricUsable(object: object) { metricRows += 1 }
                if object["currentSessionUsable"] as? Bool == true { currentRows += 1 }
            }
        }

        return MetricReadinessProbe(ready: metricRows > 0,
                                    rowsScanned: rowsScanned,
                                    metricUsableRows: metricRows,
                                    currentSessionUsableRows: currentRows,
                                    reason: metricRows > 0 ? (currentRows > 0 ? "metric_ready" : "metric_ready_without_explicit_current_flag") : (rowsScanned > 0 ? "not_ready_in_probe_window" : "empty_archive"))
    }

    @discardableResult
    static func promoteMetricUsableRows(reason: String) -> Int {
        promotionLock.lock()
        defer { promotionLock.unlock() }

        let url = readableFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var updated = 0
            var output: [String] = []
            output.reserveCapacity(content.split(whereSeparator: \.isNewline).count)
            for rawLine in content.split(whereSeparator: \.isNewline) {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                guard let data = line.data(using: .utf8),
                      var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    output.append(line)
                    continue
                }
                if object["metricUsable"] as? Bool != true,
                   metricEvidenceValidated(object: object) {
                    object["metricUsable"] = true
                    object["usabilityReason"] = "metric_ready_clock_gravity_rr"
                    updated += 1
                    let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    output.append(String(decoding: encoded, as: UTF8.self))
                } else {
                    output.append(line)
                }
            }
            guard updated > 0 else { return 0 }
            let promoted = output.joined(separator: "\n") + "\n"
            try promoted.write(to: fileURL, atomically: true, encoding: .utf8)
            NotificationCenter.default.post(name: didUpdateNotification, object: nil)
            AtriaDebugLog("ATRIADBG historical_archive_promotion status=updated reason=%@ rows=%d criteria=clock_corrected_gravity_validated_rr_bearing",
                          reason,
                          updated)
            return updated
        } catch {
            AtriaDebugLog("ATRIADBG historical_archive_promotion status=failed reason=%@ error=%@",
                          reason,
                          String(describing: error).replacingOccurrences(of: " ", with: "_"))
            return 0
        }
    }

    private static func currentSessionUsable(object: [String: Any]) -> Bool {
        let correctedUnix = (object["clockCorrectedUnix7"] as? NSNumber)?.uint32Value ?? 0
        let rawUnix = (object["unix7"] as? NSNumber)?.uint32Value ?? 0
        guard max(correctedUnix, rawUnix) > 0 else { return false }
        guard let payloadHex = object["rawPayloadHex"] as? String,
              let payload = bytes(fromHex: payloadHex),
              historicalGravity(payload)?.validated == true else { return false }
        guard let heartRate = (object["whoofHR17"] as? NSNumber)?.intValue else { return false }
        return (25...230).contains(heartRate)
    }

    static func metricLayoutValidated(_ layoutVersion: String) -> Bool {
        validatedMetricLayoutVersions.contains(layoutVersion)
    }

    private static func metricUsable(object: [String: Any]) -> Bool {
        guard object["metricUsable"] as? Bool == true else { return false }
        return metricEvidenceValidated(object: object)
    }

    private static func metricEvidenceValidated(object: [String: Any]) -> Bool {
        guard let layoutVersion = object["layoutVersion"] as? String,
              metricLayoutValidated(layoutVersion) else { return false }
        guard object["clockCorrectionStatus"] as? String == "clock_ref_present" else { return false }
        guard object["gravityValidated"] as? Bool == true else { return false }
        guard let heartRate = (object["whoofHR17"] as? NSNumber)?.intValue else { return false }
        return (25...230).contains(heartRate)
    }

    static func motionWindowDiagnostics(start: Date, end: Date) -> MotionWindowDiagnostics {
        guard !Thread.isMainThread else {
            return emptyMotionWindow(status: "learning", reason: "full_archive_requires_background")
        }
        return makeMotionArchiveSnapshot().diagnostics(start: start, end: end)
    }

    struct MotionTickPayloadClockProvenance: Equatable {
        let observedAtUnix: TimeInterval
        let endpointTimestamp: TimeInterval
        let clockDeviceRef: UInt32
        let clockWallRef: UInt32
        let clockOffsetSeconds: Int
    }

    enum MotionTickPayloadClockResolution: Equatable {
        case accepted(MotionTickPayloadClockProvenance)
        case conflicted(earliestObservedAtUnix: TimeInterval)
    }

    /// Selects clock provenance for one physical payload independently of
    /// archive scan order. Replays observed later cannot rewrite the original
    /// endpoint or drift. Two different clock tuples claiming the same earliest
    /// observation are ambiguous, so that payload contributes no endpoint.
    nonisolated static func resolveMotionTickPayloadClockProvenance(
        existing: MotionTickPayloadClockResolution?,
        candidate: MotionTickPayloadClockProvenance
    ) -> MotionTickPayloadClockResolution {
        guard let existing else { return .accepted(candidate) }
        let existingObservedAt: TimeInterval
        switch existing {
        case .accepted(let accepted):
            existingObservedAt = accepted.observedAtUnix
        case .conflicted(let earliestObservedAtUnix):
            existingObservedAt = earliestObservedAtUnix
        }
        if candidate.observedAtUnix < existingObservedAt {
            return .accepted(candidate)
        }
        if candidate.observedAtUnix > existingObservedAt {
            return existing
        }
        switch existing {
        case .accepted(let accepted):
            if accepted.endpointTimestamp == candidate.endpointTimestamp,
               accepted.clockDeviceRef == candidate.clockDeviceRef,
               accepted.clockWallRef == candidate.clockWallRef,
               accepted.clockOffsetSeconds == candidate.clockOffsetSeconds {
                return existing
            }
            return .conflicted(earliestObservedAtUnix: existingObservedAt)
        case .conflicted:
            return existing
        }
    }

    /// Reads a bounded WHOOP 4 v24 counter window off-main.
    ///
    /// History pages can be drained under different GET_DATA_RANGE clock
    /// references. Applying each page's correction independently can make one
    /// physical sequence jump backwards in wall time. Instead, this evaluates
    /// only the finite offsets actually observed in the retained rows (plus
    /// zero for an already-synchronised strap), applies one offset to the whole
    /// workout, and chooses it only from clock-reference provenance. Motion is
    /// never inspected to select the time alignment.
    static func motionTickWindow(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> MotionTickWindow? {
        motionTickWindowRead(
            start: start,
            end: end,
            strapIdentifier: strapIdentifier
        ).evidence
    }

    /// Same publication semantics as `motionTickWindow`, while preserving the
    /// distinction required by durable negative caching: only a stable,
    /// complete read may prove that this exact source generation has no
    /// qualified gait window.
    static func motionTickWindowRead(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> MotionTickWindowRead {
        precondition(!Thread.isMainThread,
                     "Historical motion-tick decoding must run off the main thread")
        guard end > start, !strapIdentifier.isEmpty else { return .incomplete }
        let boundaryTolerance: TimeInterval = 3
        let maximumClockOffset =
            AtriaWhoop4ProductionHistoryBootstrapPolicy.maximumClockDrift
        let scanStart = start.addingTimeInterval(
            -(boundaryTolerance + maximumClockOffset)
        )
        let scanEnd = end.addingTimeInterval(
            boundaryTolerance + maximumClockOffset
        )
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: motionWindowReadableFileURLs(
                start: start,
                end: end
            )
        )
        typealias CadencePoint = AtriaWhoop4GravityCadenceStepModel.Point
        var endpoints: [String: CadencePoint] = [:]
        var clockOffsetByPayload: [String: Int] = [:]
        var clockResolutionByPayload:
            [String: MotionTickPayloadClockResolution] = [:]
        let scan = AtriaHistoricalJSONLRecentScanner.scan(
            sources: descriptors.map { .init(descriptor: $0, startOffset: 0) },
            cutoff: scanStart.timeIntervalSince1970
        ) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line)
                    as? [String: Any],
                  (object["sequence"] as? NSNumber)?.intValue
                    == Int(AtriaWhoop4HistoricalLayout.v24.rawValue),
                  historicalStrapIdentifier(object: object) == strapIdentifier,
                  object["clockCorrectionStatus"] as? String == "clock_ref_present",
                  let clockDeviceRef =
                    (object["clockDeviceRef"] as? NSNumber)?.uint32Value,
                  let clockWallRef =
                    (object["clockWallRef"] as? NSNumber)?.uint32Value,
                  let drift =
                    (object["clockDriftSeconds"] as? NSNumber)?.intValue,
                  abs(TimeInterval(drift)) <= maximumClockOffset,
                  let deviceUnix = (object["unix7"] as? NSNumber)?.doubleValue,
                  let subsecond = (object["subsec11"] as? NSNumber)?.doubleValue,
                  subsecond >= 0,
                  subsecond < 32_768,
                  deviceUnix >= scanStart.timeIntervalSince1970,
                  deviceUnix <= scanEnd.timeIntervalSince1970,
                  let payloadHex = object["rawPayloadHex"] as? String,
                  let payload = bytes(fromHex: payloadHex),
                  case .record(let decoded) =
                    AtriaWhoop4HistoricalRecordDecoder.decode(payload),
                  decoded.layout == .v24,
                  let decodedTick = decoded.motionTickCounter.map(Int.init),
                  let observedAtUnix = (object[
                    AtriaHistoricalArchiveDurableStore.identityObservedAtProperty
                  ] as? NSNumber)?.doubleValue,
                  observedAtUnix.isFinite else {
                return
            }
            let storedTick = ((object["nativeStepCounter88"] as? NSNumber)
                ?? (object["motionTickCounter88"] as? NSNumber))?.intValue
            guard storedTick == nil || storedTick == decodedTick else { return }
            let endpointTimestamp = deviceUnix + subsecond / 32_768
            let resolution = resolveMotionTickPayloadClockProvenance(
                existing: clockResolutionByPayload[payloadHex],
                candidate: .init(
                    observedAtUnix: observedAtUnix,
                    endpointTimestamp: endpointTimestamp,
                    clockDeviceRef: clockDeviceRef,
                    clockWallRef: clockWallRef,
                    clockOffsetSeconds: drift
                )
            )
            clockResolutionByPayload[payloadHex] = resolution
            guard case .accepted(let accepted) = resolution else {
                endpoints.removeValue(forKey: payloadHex)
                clockOffsetByPayload.removeValue(forKey: payloadHex)
                return
            }
            endpoints[payloadHex] = CadencePoint(
                timestamp: accepted.endpointTimestamp,
                flash: decoded.counter,
                tick: decodedTick,
                gravityX: decoded.gravity.x,
                gravityY: decoded.gravity.y,
                gravityZ: decoded.gravity.z,
                unknownMotionScalar32: decoded.unknownMotionScalar32,
                identity: payloadHex
            )
            clockOffsetByPayload[payloadHex] = accepted.clockOffsetSeconds
        }
        // The active JSONL is append-only and can grow while this bounded read
        // is in flight. A concurrently appended trailing row makes the generic
        // scanner report an incomplete snapshot even though every complete row
        // it returned is durable. Do not discard those rows: the alignment
        // gate below still requires both workout boundaries and >=90% exact
        // temporal coverage before any step result can be published.
        let rejected: MotionTickWindowRead =
            scan.complete ? .completeNoQualifiedEvidence : .incomplete
        AtriaDebugLog(
            "ATRIADBG motion_tick_window status=scanned sources=%d files=%d bytes=%d lines=%d candidates=%d complete=%d endpoints=%d",
            descriptors.count,
            scan.statistics.fileReadCount,
            scan.statistics.byteCount,
            scan.statistics.lineCount,
            scan.statistics.candidateLineCount,
            scan.complete ? 1 : 0,
            endpoints.count
        )
        guard endpoints.count >= 2 else {
            AtriaDebugLog("ATRIADBG motion_tick_window status=rejected reason=insufficient_endpoints")
            return rejected
        }
        let points = endpoints.values.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return $0.identity < $1.identity
        }
        let modulus = 65_536
        guard let selected =
            AtriaWhoop4GravityCadenceStepModel.estimateAlignedWindow(
                points: points,
                requestedStart: start.timeIntervalSince1970,
                requestedEnd: end.timeIntervalSince1970,
                clockOffsetByIdentity: clockOffsetByPayload,
                boundaryTolerance: boundaryTolerance
            ) else {
            AtriaDebugLog(
                "ATRIADBG motion_tick_window status=rejected reason=alignment_or_gait points=%d offsets=%d",
                points.count,
                Set(clockOffsetByPayload.values).count
            )
            return rejected
        }
        let delta = selected.last.tick >= selected.first.tick
            ? selected.last.tick - selected.first.tick
            : selected.last.tick + modulus - selected.first.tick
        guard Double(delta) <= max(
            12,
            (selected.last.timestamp - selected.first.timestamp) * 12
        ) else { return rejected }
        return .qualified(
            .init(startTick: selected.first.tick,
                  endTick: selected.last.tick,
                  delta: delta,
                  steps: selected.estimate.steps,
                  startCapturedAt: Date(
                    timeIntervalSince1970: selected.first.timestamp
                        + Double(selected.clockOffsetSeconds)
                  ),
                  endCapturedAt: Date(
                    timeIntervalSince1970: selected.last.timestamp
                        + Double(selected.clockOffsetSeconds)
                  ),
                  coverageFraction: selected.coverageFraction,
                  decodedRows: selected.decodedRows)
        )
    }

    /// Produces a deduplicated, strap-only subtotal for the active
    /// physiological day. Coverage authority comes from the durable 0x69 bank
    /// ledger; counter authority is re-decoded from retained v24 payloads.
    /// Missing bank time remains missing and the result is never promoted to a
    /// complete day while the day is still open.
    static func motionTickDayEvidence(
        start: Date,
        end: Date,
        bankCoverage: [DateInterval],
        strapIdentifier: String
    ) -> MotionTickDayEvidence? {
        motionTickDayEvidenceRead(
            start: start,
            end: end,
            bankCoverage: bankCoverage,
            strapIdentifier: strapIdentifier
        ).evidence
    }

    /// Preserves the difference between a complete scan with no qualified
    /// daily motion and an interrupted/overflowed scan. Only the former may
    /// suppress an identical future launch attempt.
    static func motionTickDayEvidenceRead(
        start: Date,
        end: Date,
        bankCoverage: [DateInterval],
        strapIdentifier: String,
        compactMigrationStore: AtriaWhoop4MotionTickCompactStore? = nil
    ) -> MotionTickDayEvidenceRead {
        precondition(!Thread.isMainThread,
                     "Historical motion-tick daily decoding must run off the main thread")
        guard end > start,
              !bankCoverage.isEmpty,
              !strapIdentifier.isEmpty else { return .incomplete }
        let dayWindow = DateInterval(start: start, end: end)
        let intervals = mergedMotionCoverage(bankCoverage.compactMap {
            let clippedStart = max($0.start, dayWindow.start)
            let clippedEnd = min($0.end, dayWindow.end)
            return clippedEnd > clippedStart
                ? DateInterval(start: clippedStart, end: clippedEnd)
                : nil
        })
        guard let scanStart = intervals.first?.start,
              let scanEnd = intervals.last?.end else { return .incomplete }
        let tolerance: TimeInterval = 3
        let maximumClockOffset =
            AtriaWhoop4ProductionHistoryBootstrapPolicy.maximumClockDrift
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: recentRecoveredReadableFileURLs(
                since: scanStart.addingTimeInterval(
                    -(tolerance + maximumClockOffset)
                )
                    .timeIntervalSince1970
            )
        )
        typealias Point = AtriaWhoop4MotionTickSequenceReducer.Point
        typealias CadencePoint = AtriaWhoop4GravityCadenceStepModel.Point
        var rows: [String: (
            counter: Point,
            cadence: CadencePoint
        )] = [:]
        var clockOffsetByPayload: [String: Int] = [:]
        var clockResolutionByPayload:
            [String: MotionTickPayloadClockResolution] = [:]
        let scan = AtriaHistoricalJSONLRecentScanner.scan(
            sources: descriptors.map { .init(descriptor: $0, startOffset: 0) },
            cutoff: scanStart.addingTimeInterval(
                -(tolerance + maximumClockOffset)
            ).timeIntervalSince1970
        ) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line)
                    as? [String: Any],
                  (object["sequence"] as? NSNumber)?.intValue
                    == Int(AtriaWhoop4HistoricalLayout.v24.rawValue),
                  historicalStrapIdentifier(object: object) == strapIdentifier,
                  object["clockCorrectionStatus"] as? String == "clock_ref_present",
                  let clockDeviceRef =
                    (object["clockDeviceRef"] as? NSNumber)?.uint32Value,
                  let clockWallRef =
                    (object["clockWallRef"] as? NSNumber)?.uint32Value,
                  let drift =
                    (object["clockDriftSeconds"] as? NSNumber)?.intValue,
                  abs(TimeInterval(drift)) <= maximumClockOffset,
                  let deviceUnix = (object["unix7"] as? NSNumber)?.doubleValue,
                  let subsecond = (object["subsec11"] as? NSNumber)?.doubleValue,
                  subsecond >= 0,
                  subsecond < 32_768,
                  deviceUnix >= scanStart.addingTimeInterval(
                    -(tolerance + maximumClockOffset)
                  )
                    .timeIntervalSince1970,
                  deviceUnix <= scanEnd.addingTimeInterval(
                    tolerance + maximumClockOffset
                  )
                    .timeIntervalSince1970,
                  let payloadHex = object["rawPayloadHex"] as? String,
                  let payload = bytes(fromHex: payloadHex),
                  case .record(let decoded) =
                    AtriaWhoop4HistoricalRecordDecoder.decode(payload),
                  decoded.layout == .v24,
                  let tick = decoded.motionTickCounter.map(Int.init),
                  let observedAtUnix = (object[
                    AtriaHistoricalArchiveDurableStore.identityObservedAtProperty
                  ] as? NSNumber)?.doubleValue,
                  observedAtUnix.isFinite else {
                return
            }
            let stored = ((object["nativeStepCounter88"] as? NSNumber)
                ?? (object["motionTickCounter88"] as? NSNumber))?.intValue
            guard stored == nil || stored == tick else { return }
            let rawTimestamp = deviceUnix + subsecond / 32_768
            let resolution = resolveMotionTickPayloadClockProvenance(
                existing: clockResolutionByPayload[payloadHex],
                candidate: .init(
                    observedAtUnix: observedAtUnix,
                    endpointTimestamp: rawTimestamp,
                    clockDeviceRef: clockDeviceRef,
                    clockWallRef: clockWallRef,
                    clockOffsetSeconds: drift
                )
            )
            clockResolutionByPayload[payloadHex] = resolution
            guard case .accepted(let accepted) = resolution else {
                rows.removeValue(forKey: payloadHex)
                clockOffsetByPayload.removeValue(forKey: payloadHex)
                return
            }
            rows[payloadHex] = (
                counter: .init(timestamp: accepted.endpointTimestamp,
                               tick: tick,
                               flash: decoded.counter,
                               identity: payloadHex),
                cadence: .init(
                timestamp: accepted.endpointTimestamp,
                flash: decoded.counter,
                tick: tick,
                gravityX: decoded.gravity.x,
                gravityY: decoded.gravity.y,
                gravityZ: decoded.gravity.z,
                unknownMotionScalar32: decoded.unknownMotionScalar32,
                identity: payloadHex
                )
            )
            clockOffsetByPayload[payloadHex] = accepted.clockOffsetSeconds
        }
        guard scan.complete else { return .incomplete }
        if let compactMigrationStore {
            let migrationPoints = rows.compactMap {
                payloadHex,
                pair -> AtriaWhoop4MotionTickCompactStore.MigrationPoint? in
                guard let clockOffset = clockOffsetByPayload[payloadHex],
                      let rawPayload = bytes(fromHex: payloadHex) else {
                    return nil
                }
                return .init(
                    timestamp: pair.counter.timestamp
                        + TimeInterval(clockOffset),
                    flash: pair.counter.flash,
                    tick: pair.counter.tick,
                    gravityX: pair.cadence.gravityX,
                    gravityY: pair.cadence.gravityY,
                    gravityZ: pair.cadence.gravityZ,
                    unknownMotionScalar32:
                        pair.cadence.unknownMotionScalar32,
                    rawPayload: rawPayload
                )
            }
            do {
                let migrated = try compactMigrationStore.appendMigrated(
                    migrationPoints,
                    strapIdentifier: strapIdentifier
                )
                try compactMigrationStore.synchronize()
                AtriaDebugLog(
                    "ATRIADBG whoop4_motion_compact status=canonical_migration_complete inspected=%d appended=%d strap=%@",
                    migrationPoints.count,
                    migrated,
                    strapIdentifier
                )
            } catch {
                // The canonical scan remains the authority for this read.
                // Migration failure only keeps the next background projection
                // partial; it must never discard a valid canonical result.
                AtriaDebugLog(
                    "ATRIADBG whoop4_motion_compact status=canonical_migration_failed inspected=%d error=%@ action=retain_canonical_read",
                    migrationPoints.count,
                    String(describing: error)
                )
            }
        }
        guard rows.count >= 2 else {
            return .completeNoQualifiedEvidence
        }
        var clockOffsetSupport: [Int: Int] = [:]
        for payloadHex in rows.keys {
            guard let offset = clockOffsetByPayload[payloadHex] else {
                continue
            }
            clockOffsetSupport[offset, default: 0] += 1
        }
        var totalTicks = 0
        var totalKnownDuration: TimeInterval = 0
        var totalDecodedRows = 0
        var totalSteps = 0
        var totalUnresolvedMotion: TimeInterval = 0
        var cadenceFragments: [[CadencePoint]] = []
        var capturedThrough: Date?
        for interval in intervals {
            typealias IntervalAlignment = (
                offset: Int,
                members: [(counter: Point, cadence: CadencePoint)],
                boundaryError: TimeInterval,
                support: Int
            )
            var candidates: [IntervalAlignment] = []
            for offset in clockOffsetSupport.keys.sorted() {
                let rawStart = interval.start.timeIntervalSince1970
                    - Double(offset)
                let rawEnd = interval.end.timeIntervalSince1970
                    - Double(offset)
                let nearby = rows.values.filter {
                    $0.counter.timestamp >= rawStart - tolerance
                        && $0.counter.timestamp <= rawEnd + tolerance
                }.sorted {
                    if $0.counter.timestamp != $1.counter.timestamp {
                        return $0.counter.timestamp < $1.counter.timestamp
                    }
                    return $0.counter.identity < $1.counter.identity
                }
                guard let first = nearby.min(by: {
                    abs($0.counter.timestamp - rawStart)
                        < abs($1.counter.timestamp - rawStart)
                }),
                let last = nearby.min(by: {
                    abs($0.counter.timestamp - rawEnd)
                        < abs($1.counter.timestamp - rawEnd)
                }),
                abs(first.counter.timestamp - rawStart) <= tolerance,
                abs(last.counter.timestamp - rawEnd) <= tolerance,
                last.counter.timestamp > first.counter.timestamp,
                let firstIndex = nearby.firstIndex(where: {
                    $0.counter.identity == first.counter.identity
                }),
                let lastIndex = nearby.firstIndex(where: {
                    $0.counter.identity == last.counter.identity
                }),
                lastIndex > firstIndex else { continue }
                let members = Array(nearby[firstIndex...lastIndex])
                candidates.append((
                    offset,
                    members,
                    abs(first.counter.timestamp - rawStart)
                        + abs(last.counter.timestamp - rawEnd),
                    members.reduce(into: 0) { count, member in
                        if clockOffsetByPayload[member.counter.identity]
                            == offset {
                            count += 1
                        }
                    }
                ))
            }
            guard let strongestSupport = candidates.map(\.support).max() else {
                continue
            }
            let supported = candidates.filter {
                $0.support == strongestSupport
            }
            guard let bestBoundaryError = supported.map(\.boundaryError).min()
            else { continue }
            let boundaryMatched = supported.filter {
                abs($0.boundaryError - bestBoundaryError) < 0.001
            }
            guard boundaryMatched.count == 1,
                  let selected = boundaryMatched.first,
                  let first = selected.members.first,
                  let last = selected.members.last else { continue }
            let rawInterval = DateInterval(
                start: Date(timeIntervalSince1970: first.counter.timestamp),
                end: Date(timeIntervalSince1970: last.counter.timestamp)
            )
            guard let reduced = AtriaWhoop4MotionTickSequenceReducer.reduce(
                points: selected.members.map(\.counter),
                intervals: [rawInterval],
                boundaryTolerance: 0.001
            ) else { continue }
            cadenceFragments.append(selected.members.map { member in
                let point = member.cadence
                return .init(
                    timestamp: point.timestamp + Double(selected.offset),
                    flash: point.flash,
                    tick: point.tick,
                    gravityX: point.gravityX,
                    gravityY: point.gravityY,
                    gravityZ: point.gravityZ,
                    unknownMotionScalar32: point.unknownMotionScalar32,
                    identity: point.identity
                )
            })
            totalTicks += reduced.ticks
            totalKnownDuration += reduced.knownDuration
            totalDecodedRows += reduced.admittedRows
            let wallCaptured = Date(
                timeIntervalSince1970: last.counter.timestamp
                    + Double(selected.offset)
            )
            capturedThrough = max(capturedThrough ?? wallCaptured, wallCaptured)
        }
        if let cadence = AtriaWhoop4GravityCadenceStepModel
            .estimateCoveredActivityFragments(cadenceFragments) {
            totalSteps = cadence.steps
            totalUnresolvedMotion = cadence.unresolvedMotionSeconds
        } else {
            totalUnresolvedMotion = totalKnownDuration
        }
        let knownSeconds = max(0, Int(totalKnownDuration.rounded()))
        guard knownSeconds > 0, totalDecodedRows >= 2,
              let capturedThrough else {
            return .completeNoQualifiedEvidence
        }
        let totalSeconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        let unresolvedMotionSeconds = max(
            0,
            Int(totalUnresolvedMotion.rounded(.up))
        )
        let qualifiedStepSeconds = max(
            0,
            min(totalSeconds, knownSeconds) - unresolvedMotionSeconds
        )
        return .qualified(
            .init(
                windowStart: start,
                windowEnd: end,
                motionTicks: totalTicks,
                steps: totalSteps,
                knownCoverageSeconds: qualifiedStepSeconds,
                missingCoverageSeconds: max(
                    0,
                    totalSeconds - qualifiedStepSeconds
                ),
                decodedRows: totalDecodedRows,
                capturedThrough: min(capturedThrough, end)
            )
        )
    }

    struct MotionBankTransportCoverage: Equatable, Sendable {
        let observedSeconds: Int
        let expectedSeconds: Int
        let densityPercent: Int
        let maximumMissingRunSeconds: Int
        let firstCapturedAt: Date?
        let capturedThrough: Date?

        var satisfiesNinetyPercentExactWindow: Bool {
            guard expectedSeconds > 0,
                  densityPercent >= 90,
                  let firstCapturedAt,
                  let capturedThrough else { return false }
            return maximumMissingRunSeconds <= max(3, expectedSeconds / 10)
                && capturedThrough >= firstCapturedAt
        }
    }

    /// Transport-only proof for a closed 0x69 bank interval. This deliberately
    /// does not classify gait or estimate steps: an arm-only control must still
    /// be considered durably offloaded even though the step model rejects it.
    static func motionBankTransportCoverage(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> MotionBankTransportCoverage {
        precondition(!Thread.isMainThread,
                     "Historical motion-bank coverage must run off the main thread")
        guard end > start, !strapIdentifier.isEmpty else {
            return .init(observedSeconds: 0,
                         expectedSeconds: 0,
                         densityPercent: 0,
                         maximumMissingRunSeconds: 0,
                         firstCapturedAt: nil,
                         capturedThrough: nil)
        }
        let firstBucket = Int(floor(start.timeIntervalSince1970))
        let lastBucket = Int(floor(end.timeIntervalSince1970))
        let expected = max(1, lastBucket - firstBucket + 1)
        let tolerance: TimeInterval = 120
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: recentRecoveredReadableFileURLs(
                since: start.addingTimeInterval(-tolerance)
                    .timeIntervalSince1970
            )
        )
        var earliestByPayload: [String: (observed: Double, wall: Double)] = [:]
        _ = AtriaHistoricalJSONLRecentScanner.scan(
            sources: descriptors.map { .init(descriptor: $0, startOffset: 0) },
            cutoff: start.addingTimeInterval(-tolerance)
                .timeIntervalSince1970
        ) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line)
                    as? [String: Any],
                  (object["sequence"] as? NSNumber)?.intValue
                    == Int(AtriaWhoop4HistoricalLayout.v24.rawValue),
                  historicalStrapIdentifier(object: object) == strapIdentifier,
                  object["clockCorrectionStatus"] as? String
                    == "clock_ref_present",
                  (object["gravityValidated"] as? Bool) == true,
                  let rawUnix = (object["unix7"] as? NSNumber)?.doubleValue,
                  let subsecond = (object["subsec11"] as? NSNumber)?.doubleValue,
                  let drift = (object["clockDriftSeconds"] as? NSNumber)?.doubleValue,
                  let payload = object["rawPayloadHex"] as? String,
                  let observed = (object[
                    AtriaHistoricalArchiveDurableStore.identityObservedAtProperty
                  ] as? NSNumber)?.doubleValue else { return }
            let wall = rawUnix + subsecond / 32_768 + drift
            guard wall >= start.timeIntervalSince1970 - 1,
                  wall <= end.timeIntervalSince1970 + 1 else { return }
            if let existing = earliestByPayload[payload],
               existing.observed <= observed {
                return
            }
            earliestByPayload[payload] = (observed, wall)
        }
        let seconds = Set(earliestByPayload.values.compactMap { value -> Int? in
            let bucket = Int(floor(value.wall))
            return (firstBucket...lastBucket).contains(bucket) ? bucket : nil
        })
        var maximumMissingRun = 0
        var currentMissingRun = 0
        for bucket in firstBucket...lastBucket {
            if seconds.contains(bucket) {
                currentMissingRun = 0
            } else {
                currentMissingRun += 1
                maximumMissingRun = max(maximumMissingRun, currentMissingRun)
            }
        }
        let orderedWall = earliestByPayload.values.map(\.wall).sorted()
        return .init(
            observedSeconds: seconds.count,
            expectedSeconds: expected,
            densityPercent: min(
                100,
                Int((Double(seconds.count) / Double(expected) * 100).rounded())
            ),
            maximumMissingRunSeconds: maximumMissingRun,
            firstCapturedAt: orderedWall.first.map(Date.init(timeIntervalSince1970:)),
            capturedThrough: orderedWall.last.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func mergedMotionCoverage(
        _ intervals: [DateInterval]
    ) -> [DateInterval] {
        let sorted = intervals.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var result: [DateInterval] = []
        for interval in sorted where interval.end > interval.start {
            guard let last = result.last else {
                result.append(interval)
                continue
            }
            if interval.start <= last.end {
                result[result.count - 1] = .init(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private static func historicalStrapIdentifier(
        object: [String: Any]
    ) -> String? {
        if let explicit = object["strapIdentifier"] as? String,
           !explicit.isEmpty {
            return explicit
        }
        guard let key = object[
            AtriaHistoricalArchiveDurableStore.identityProperty
        ] as? String,
        let bytes = bytes(fromHex: key),
        bytes.count >= 5,
        bytes[0] == 2 else {
            return nil
        }
        let length = Int(bytes[1])
            | (Int(bytes[2]) << 8)
            | (Int(bytes[3]) << 16)
            | (Int(bytes[4]) << 24)
        guard length > 0, bytes.count >= 5 + length else { return nil }
        return String(bytes: bytes[5..<(5 + length)], encoding: .utf8)
    }

    static func makeMotionArchiveSnapshot() -> MotionArchiveSnapshot {
        precondition(!Thread.isMainThread, "Full historical motion decoding must run off the main thread")
        return MotionArchiveSnapshot(samples: loadGravitySamples(), completeness: .complete)
    }

    static func makeRecoveredDataSnapshot(
        since: Date,
        budget: RecoveredProjectionBudget = .production,
        onScanProgress: ((AtriaHistoricalJSONLRecentScanner.Statistics) -> Void)? = nil
    ) -> RecoveredDataSnapshot {
        precondition(!Thread.isMainThread, "Recovered archive decoding must run off the main thread")
        let started = DispatchTime.now().uptimeNanoseconds
        let cutoff = since.timeIntervalSince1970
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: recentRecoveredReadableFileURLs(since: cutoff)
        )
        return makeRecoveredDataSnapshot(
            since: since,
            budget: budget,
            descriptors: descriptors,
            started: started,
            onScanProgress: onScanProgress
        )
    }

    /// Bounded, read-only facade for app stores consuming verified historical
    /// artifacts. The callback receives one source at a time so five potentially
    /// large typed artifacts are released before the next source is opened.
    /// Missing/deferred/known-empty states are delivered unchanged; this API
    /// never edits catalog state and has no raw-retirement authority.
    @discardableResult
    static func readVerifiedConsumerSources(
        configuration: AtriaHistoricalVerifiedConsumerReader.Configuration,
        maximumSourceCount: Int = 8,
        consume: (AtriaHistoricalVerifiedConsumerReader.SourceArtifacts) -> Void
    ) -> VerifiedConsumerSourceReadReport {
        do {
            return try readVerifiedConsumerSources(
                archiveRoot: archiveDirectory,
                catalogStore: catalogStoreLocked(),
                configuration: configuration,
                maximumSourceCount: maximumSourceCount,
                consume: consume
            )
        } catch {
            return .init(committedSourceCount: 0,
                         attemptedSourceCount: 0,
                         deliveredSourceCount: 0,
                         wasBounded: false,
                         rejectedManifestCount: 1)
        }
    }

    /// Dependency-injected seam used by crash/tamper tests. It exercises the
    /// same aggregate, completion and receipt paths as the production facade.
    @discardableResult
    static func readVerifiedConsumerSources(
        archiveRoot: URL,
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        configuration: AtriaHistoricalVerifiedConsumerReader.Configuration,
        maximumSourceCount: Int,
        consume: (AtriaHistoricalVerifiedConsumerReader.SourceArtifacts) -> Void
    ) throws -> VerifiedConsumerSourceReadReport {
        guard maximumSourceCount > 0 else {
            return .init(committedSourceCount: 0,
                         attemptedSourceCount: 0,
                         deliveredSourceCount: 0,
                         wasBounded: true,
                         rejectedManifestCount: 0)
        }
        let aggregateReader = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: archiveRoot.appendingPathComponent(
                "aggregates-v2", isDirectory: true
            ),
            manifestDirectoryURL: archiveRoot.appendingPathComponent(
                "retention-manifests-v2", isDirectory: true
            )
        )
        let snapshot = aggregateReader.load()
        guard !snapshot.diagnostics.limitExceeded,
              snapshot.diagnostics.rejectedManifests == 0 else {
            return .init(committedSourceCount: snapshot.aggregates.count,
                         attemptedSourceCount: 0,
                         deliveredSourceCount: 0,
                         wasBounded: snapshot.diagnostics.limitExceeded,
                         rejectedManifestCount: snapshot.diagnostics.rejectedManifests)
        }
        let sources = snapshot.aggregates.sorted {
            if $0.source.lastTimestamp != $1.source.lastTimestamp {
                return $0.source.lastTimestamp > $1.source.lastTimestamp
            }
            return $0.source.chunkID < $1.source.chunkID
        }
        let selected = Array(sources.prefix(maximumSourceCount))
        let reader = AtriaHistoricalVerifiedConsumerReader(
            aggregateReader: aggregateReader,
            completionStore: .init(directoryURL: archiveRoot.appendingPathComponent(
                "drain-completions-v1", isDirectory: true
            )),
            receiptLedger: .init(directoryURL: archiveRoot.appendingPathComponent(
                "consumer-receipts-v1", isDirectory: true
            ))
        )
        var delivered = 0
        for source in selected {
            autoreleasepool {
                consume(reader.readSource(chunkID: source.source.chunkID,
                                          catalogStore: catalogStore,
                                          configuration: configuration))
                delivered += 1
            }
        }
        return .init(committedSourceCount: sources.count,
                     attemptedSourceCount: selected.count,
                     deliveredSourceCount: delivered,
                     wasBounded: selected.count < sources.count,
                     rejectedManifestCount: 0)
    }

    /// Bounded production read path for app-visible canonical history. Any
    /// missing proof, corrupt pointer, mismatched generation, or undecodable
    /// destination drops that source rather than falling back to shadow bytes.
    static func readVerifiedCanonicalConsumerSources(
        maximumSourceCount: Int = 8
    ) -> [VerifiedCanonicalConsumerSource] {
        readVerifiedCanonicalConsumerSourcePage(
            archiveRoot: archiveDirectory,
            after: nil,
            maximumSourceCount: maximumSourceCount
        ).sources
    }

    static func readVerifiedCanonicalConsumerSources(
        archiveRoot: URL,
        maximumSourceCount: Int
    ) -> [VerifiedCanonicalConsumerSource] {
        readVerifiedCanonicalConsumerSourcePage(
            archiveRoot: archiveRoot,
            after: nil,
            maximumSourceCount: maximumSourceCount
        ).sources
    }

    static func readVerifiedCanonicalConsumerSourcePage(
        after cursor: AtriaHistoricalAggregateReader.PageCursor?,
        maximumSourceCount: Int = 8
    ) -> VerifiedCanonicalConsumerPage {
        readVerifiedCanonicalConsumerSourcePage(
            archiveRoot: archiveDirectory,
            after: cursor,
            maximumSourceCount: maximumSourceCount
        )
    }

    static func readVerifiedCanonicalConsumerSourcePage(
        archiveRoot: URL,
        after cursor: AtriaHistoricalAggregateReader.PageCursor?,
        maximumSourceCount: Int
    ) -> VerifiedCanonicalConsumerPage {
        guard maximumSourceCount > 0 else {
            return .init(sources: [], nextCursor: cursor, hasMore: false,
                         examinedSourceCount: 0)
        }
        let aggregatePage = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: archiveRoot.appendingPathComponent(
                "aggregates-v2", isDirectory: true
            ),
            manifestDirectoryURL: archiveRoot.appendingPathComponent(
                "retention-manifests-v2", isDirectory: true
            )
        ).loadPage(
            after: cursor,
            maximumAggregateCount: maximumSourceCount,
            limits: .init(maximumManifestCount: 200_000,
                          maximumManifestBytes: 512 * 1_024,
                          maximumAggregateBytes: 64 * 1_024 * 1_024,
                          maximumTotalAggregateBytes: 128 * 1_024 * 1_024)
        )
        let snapshot = aggregatePage.snapshot
        guard !snapshot.diagnostics.limitExceeded,
              snapshot.diagnostics.rejectedManifests == 0 else {
            return .init(sources: [],
                         nextCursor: aggregatePage.nextCursor,
                         hasMore: aggregatePage.hasMore,
                         examinedSourceCount: 0)
        }
        let canonicalRoot = archiveRoot.appendingPathComponent(
            "canonical-consumers-v1", isDirectory: true
        )
        let destination = AtriaHistoricalCanonicalConsumerDestinationStore(
            directoryURL: canonicalRoot.appendingPathComponent(
                "destinations", isDirectory: true
            )
        )
        let proofDirectory = canonicalRoot.appendingPathComponent(
            "application-proofs", isDirectory: true
        )
        let structuralProofStore = AtriaHistoricalCanonicalConsumerApplicationStore(
            directoryURL: proofDirectory
        )
        let adapter = AtriaHistoricalCanonicalConsumerApplicationAdapter(
            destinationStore: destination,
            proofDirectoryURL: proofDirectory
        )
        let sources: [VerifiedCanonicalConsumerSource] = snapshot.aggregates.compactMap { aggregate in
            do {
                guard let structural = try structuralProofStore.loadCurrent(
                    sourceChunkID: aggregate.source.chunkID
                ), structural.verificationIdentity.source.rawSHA256
                    == aggregate.source.rawSHA256 else { return nil }
                let identity = structural.verificationIdentity
                var byKind: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind: Data] = [:]
                var replay: AtriaHistoricalReplayIdentityShard?
                var replayPayloadRetired = false
                do {
                    _ = try adapter.validatedCurrent(identity: identity)
                    let artifacts = try adapter.validatedArtifacts(identity: identity)
                    byKind = Dictionary(uniqueKeysWithValues: artifacts.map {
                        ($0.receipt.kind, $0.artifact)
                    })
                    guard let replayData = byKind[.replayIdentity] else { return nil }
                    replay = try AtriaHistoricalReplayIdentityShard
                        .decodeRetainedArtifact(replayData, source: aggregate.source)
                    guard try replay?.encodedArtifact() == replayData else { return nil }
                } catch {
                    let replayIndex = try AtriaHistoricalRetiredReplayIndex(
                        databaseURL: archiveRoot.appendingPathComponent(
                            "retired-replay-v1/exact-identities-v3.sqlite"
                        )
                    )
                    _ = try AtriaHistoricalReplayPayloadCompactionStore(
                        directoryURL: archiveRoot.appendingPathComponent(
                            "replay-compaction-v1", isDirectory: true
                        )
                    ).verifiedProof(identity: identity, replayIndex: replayIndex)
                    var typed: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind: Data] = [:]
                    for application in structural.applications
                        where application.consumer != .replayIdentity {
                        for artifact in try destination.validatedArtifacts(
                            application: application, identity: identity
                        ) {
                            typed[artifact.receipt.kind] = artifact.artifact
                        }
                    }
                    byKind = typed
                    replay = .init(
                        schema: AtriaHistoricalReplayIdentityShard.currentSchema,
                        source: .init(chunkID: aggregate.source.chunkID,
                                      rawSHA256: aggregate.source.rawSHA256,
                                      rawRowCount: aggregate.source.rawRowCount),
                        entries: []
                    )
                    replayPayloadRetired = true
                }
                guard let replay,
                      let activityData = byKind[.activity],
                      let dailyData = byKind[.dailyMetrics],
                      let stepsData = byKind[.steps],
                      let sleepData = byKind[.sleep],
                      let workoutData = byKind[.workout] else { return nil }
                let decoder = JSONDecoder()
                let activity = try decoder.decode(AtriaHistoricalActivityProjection.self,
                                                  from: activityData)
                let daily = try decoder.decode(
                    AtriaHistoricalDailyConsumerProjection.DailyMetricsArtifact.self,
                    from: dailyData
                )
                let steps = try decoder.decode(
                    AtriaHistoricalDailyConsumerProjection.StepsArtifact.self,
                    from: stepsData
                )
                let sleep = try decoder.decode(AtriaHistoricalSleepProjection.self,
                                               from: sleepData)
                let workout = try decoder.decode(AtriaHistoricalWorkoutProjection.self,
                                                 from: workoutData)
                guard try activity.encodedArtifact() == activityData,
                      try daily.encodedArtifact() == dailyData,
                      try steps.encodedArtifact() == stepsData,
                      try sleep.encodedArtifact() == sleepData,
                      try workout.encodedArtifact() == workoutData else { return nil }
                return .init(identity: identity,
                             activity: activity,
                             dailyMetrics: daily,
                             steps: steps,
                             sleep: sleep,
                             workout: workout,
                             replayIdentity: replay,
                             replayPayloadRetired: replayPayloadRetired)
            } catch {
                return nil
            }
        }
        return .init(sources: sources,
                     nextCursor: aggregatePage.nextCursor,
                     hasMore: aggregatePage.hasMore,
                     examinedSourceCount: snapshot.aggregates.count)
    }

    /// Dependency-injected production-path seam for retention tests. It uses
    /// the exact catalog selector and one-pass decoder used above, while
    /// keeping fixtures out of the app container.
    static func makeRecoveredDataSnapshot(
        since: Date,
        budget: RecoveredProjectionBudget = .production,
        candidates: [URL],
        catalog: AtriaHistoricalArchiveCatalog,
        archiveRoot: URL,
        onScanProgress: ((AtriaHistoricalJSONLRecentScanner.Statistics) -> Void)? = nil
    ) -> RecoveredDataSnapshot {
        precondition(!Thread.isMainThread, "Recovered archive decoding must run off the main thread")
        let started = DispatchTime.now().uptimeNanoseconds
        let selected = recoveredProjectionFileURLs(
            candidates: candidates,
            catalog: catalog,
            archiveRoot: archiveRoot,
            since: since.timeIntervalSince1970
        )
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(for: selected)
        return makeRecoveredDataSnapshot(
            since: since,
            budget: budget,
            descriptors: descriptors,
            started: started,
            onScanProgress: onScanProgress
        )
    }

    private static func makeRecoveredDataSnapshot(
        since: Date,
        budget: RecoveredProjectionBudget,
        descriptors: [AtriaHistoricalJSONLRecentScanner.FileDescriptor],
        started: UInt64,
        onScanProgress: ((AtriaHistoricalJSONLRecentScanner.Statistics) -> Void)?
    ) -> RecoveredDataSnapshot {
        let cutoff = since.timeIntervalSince1970

        recoveredDataCacheLock.lock()
        defer { recoveredDataCacheLock.unlock() }

        let reusableCache = recoveredDataCache.flatMap { cache in
            cache.budget == budget
                && cache.coveredSince <= cutoff
                && cutoff - cache.coveredSince <= recoveredDataCacheMaximumWindowDrift
                ? prunedRecoveredCache(cache, since: cutoff)
                : nil
        }
        let plan = AtriaHistoricalJSONLRecentScanner.plan(
            previousStates: reusableCache?.fileStates,
            current: descriptors
        )
        if case .reuse = plan, let reusableCache {
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            let limitations = recoveredBudgetLimitations(cache: reusableCache, budget: budget)
            recoveredDataCache = limitations.isEmpty ? reusableCache : nil
            return recoveredSnapshot(from: reusableCache,
                                     scan: .init(fileReadCount: 0,
                                                 byteCount: 0,
                                                 decodedRecordCount: 0,
                                                 elapsedMilliseconds: elapsed),
                                     limitations: limitations)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var decodedRecordCount = 0
        let coveredSince = cutoff
        var heartRate = reusableCache?.heartRatePoints ?? []
        var rrRecords = reusableCache?.rrRecords ?? []
        var skinTemperatureRawPoints = reusableCache?.skinTemperatureRawPoints ?? []
        var gravity = reusableCache?.gravitySamples ?? []
        var motionRecordIdentities = reusableCache?.motionRecordIdentities ?? []
        var limitations = recoveredBudgetLimitations(
            heartRateCount: heartRate.count,
            rrRecordCount: rrRecords.count,
            skinTemperatureCount: skinTemperatureRawPoints.count,
            gravityCount: gravity.count,
            motionIdentityCount: motionRecordIdentities.count,
            budget: budget
        )
        let sources: [AtriaHistoricalJSONLRecentScanner.Source]
        switch plan {
        case .reuse:
            sources = []
        case .incremental(let additions), .rebuild(let additions):
            sources = additions
        }
        if case .rebuild = plan {
            heartRate.removeAll(keepingCapacity: true)
            rrRecords.removeAll(keepingCapacity: true)
            skinTemperatureRawPoints.removeAll(keepingCapacity: true)
            gravity.removeAll(keepingCapacity: true)
            motionRecordIdentities.removeAll(keepingCapacity: true)
        }

        let scanResult = AtriaHistoricalJSONLRecentScanner.scan(
            sources: sources,
            cutoff: coveredSince,
            onProgress: onScanProgress
        ) { lineData in
            guard let record = try? decoder.decode(Record.self, from: lineData) else { return }
            decodedRecordCount += 1
            appendRecoveredRecord(record,
                                  cutoff: coveredSince,
                                  budget: budget,
                                  limitations: &limitations,
                                  heartRate: &heartRate,
                                  rrRecords: &rrRecords,
                                  skinTemperatureRawPoints: &skinTemperatureRawPoints,
                                  gravity: &gravity,
                                  motionRecordIdentities: &motionRecordIdentities)
        }
        sortRecoveredData(heartRate: &heartRate,
                          rrRecords: &rrRecords,
                          skinTemperatureRawPoints: &skinTemperatureRawPoints,
                          gravity: &gravity)

        var fileStates: [String: AtriaHistoricalJSONLRecentScanner.FileState]
        if case .incremental = plan {
            fileStates = reusableCache?.fileStates ?? [:]
            scanResult.states.forEach { fileStates[$0.key] = $0.value }
        } else {
            fileStates = scanResult.states
        }
        let cache = RecoveredDataCache(coveredSince: coveredSince,
                                       budget: budget,
                                       fileStates: fileStates,
                                       heartRatePoints: heartRate,
                                       rrRecords: rrRecords,
                                       skinTemperatureRawPoints: skinTemperatureRawPoints,
                                       gravitySamples: gravity,
                                       motionRecordIdentities: motionRecordIdentities)
        if scanResult.complete, limitations.isEmpty {
            recoveredDataCache = cache
        } else if !limitations.isEmpty {
            // A bounded channel must be rebuilt on the next request; retaining
            // it would make a later, narrower window look complete. The current
            // snapshot may still publish independently complete HR/RR, while
            // the limited motion facade remains explicitly unavailable.
            recoveredDataCache = nil
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        return recoveredSnapshot(from: cache,
                                 scan: .init(fileReadCount: scanResult.statistics.fileReadCount,
                                             byteCount: scanResult.statistics.byteCount,
                                             decodedRecordCount: decodedRecordCount,
                                             elapsedMilliseconds: elapsed),
                                 limitations: limitations)
    }

    private static func appendRecoveredRecord(
        _ record: Record,
        cutoff: TimeInterval,
        budget: RecoveredProjectionBudget,
        limitations: inout [RecoveredDataCompleteness.Channel: Int],
        heartRate: inout [HeartRatePoint],
        rrRecords: inout [Record],
        skinTemperatureRawPoints: inout [SkinTemperatureRawPoint],
        gravity: inout [GravitySample],
        motionRecordIdentities: inout Set<AtriaRecoveredMotionReplayIdentity>
    ) {
        let unix = record.clockCorrectedUnix7 ?? record.unix7
        guard unix > 0, record.subsec11 < 32_768 else { return }
        let timestamp = TimeInterval(unix) + TimeInterval(record.subsec11) / 32_768
        guard timestamp >= cutoff else { return }
        let motionAlreadyLimited = limitations[.motionReplayIdentity] != nil
            || limitations[.gravity] != nil
        if !motionAlreadyLimited {
            let motionIdentity = AtriaRecoveredMotionReplayIdentity(record: record)
            if !motionRecordIdentities.contains(motionIdentity) {
                if motionRecordIdentities.count >= budget.maximumMotionReplayIdentities {
                    limitations[.motionReplayIdentity] = budget.maximumMotionReplayIdentities
                } else if let sample = gravitySample(from: record) {
                    if gravity.count >= budget.maximumGravitySamples {
                        limitations[.gravity] = budget.maximumGravitySamples
                    } else {
                        motionRecordIdentities.insert(motionIdentity)
                        gravity.append(sample)
                    }
                } else {
                    motionRecordIdentities.insert(motionIdentity)
                }
            }
        }
        guard record.metricUsable,
              metricLayoutValidated(record.layoutVersion),
              record.clockCorrectionStatus == "clock_ref_present",
              record.clockCorrectedUnix7 != nil else { return }
        if let raw = whoop4SkinTemperatureRaw(from: record),
           limitations[.skinTemperature] == nil {
            if skinTemperatureRawPoints.count >= budget.maximumSkinTemperaturePoints {
                limitations[.skinTemperature] = budget.maximumSkinTemperaturePoints
            } else {
                skinTemperatureRawPoints.append(.init(
                    t: Date(timeIntervalSince1970: timestamp),
                    raw: raw,
                    strapIdentifier: record.strapIdentifier
                ))
            }
        }
        if (35...240).contains(record.whoofHR17) {
            if limitations[.heartRate] == nil {
                if heartRate.count >= budget.maximumHeartRatePoints {
                    limitations[.heartRate] = budget.maximumHeartRatePoints
                } else {
                    heartRate.append(.init(t: Date(timeIntervalSince1970: timestamp),
                                           bpm: record.whoofHR17))
                }
            }
        }
        if record.whoofRRNum18 > 0 {
            if limitations[.rrRecords] == nil {
                if rrRecords.count >= budget.maximumRRRecords {
                    limitations[.rrRecords] = budget.maximumRRRecords
                } else {
                    rrRecords.append(record)
                }
            }
        }
    }

    private static func sortRecoveredData(
        heartRate: inout [HeartRatePoint],
        rrRecords: inout [Record],
        skinTemperatureRawPoints: inout [SkinTemperatureRawPoint],
        gravity: inout [GravitySample]
    ) {
        heartRate.sort {
            if $0.t != $1.t { return $0.t < $1.t }
            return $0.bpm < $1.bpm
        }
        rrRecords.sort {
            let lhsUnix = $0.clockCorrectedUnix7 ?? $0.unix7
            let rhsUnix = $1.clockCorrectedUnix7 ?? $1.unix7
            if lhsUnix != rhsUnix { return lhsUnix < rhsUnix }
            if $0.subsec11 != $1.subsec11 { return $0.subsec11 < $1.subsec11 }
            return $0.flash13 < $1.flash13
        }
        skinTemperatureRawPoints.sort { $0.t < $1.t }
        gravity.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.sequence < $1.sequence
        }
    }

    private static func whoop4SkinTemperatureRaw(from record: Record) -> Int? {
        guard record.layoutVersion == layoutVersion(for: 24),
              record.gravityValidated,
              let payload = bytes(fromHex: record.rawPayloadHex),
              payload.count > AtriaResearchProbe.whoop4SkinTemperatureRawOffset + 1,
              payload[0] == 0x2f,
              payload[1] == 24 else { return nil }
        // Frame-absolute skin-contact offset 55 maps to payload-relative 51.
        // A non-zero contact byte is necessary but not sufficient; the ADC
        // range below also excludes the observed doff floor and saturation.
        guard payload.count > 51, payload[51] != 0 else { return nil }
        let offset = AtriaResearchProbe.whoop4SkinTemperatureRawOffset
        let raw = Int(UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8))
        guard AtriaResearchProbe.whoop4SkinTemperatureWornRawRange.contains(raw) else {
            return nil
        }
        return raw
    }

    private static func prunedRecoveredCache(
        _ cache: RecoveredDataCache,
        since cutoff: TimeInterval
    ) -> RecoveredDataCache {
        RecoveredDataCache(
            coveredSince: cutoff,
            budget: cache.budget,
            fileStates: cache.fileStates,
            heartRatePoints: cache.heartRatePoints.filter {
                $0.t.timeIntervalSince1970 >= cutoff
            },
            rrRecords: cache.rrRecords.filter {
                let unix = $0.clockCorrectedUnix7 ?? $0.unix7
                return TimeInterval(unix) + TimeInterval($0.subsec11) / 32_768 >= cutoff
            },
            skinTemperatureRawPoints: cache.skinTemperatureRawPoints.filter {
                $0.t.timeIntervalSince1970 >= cutoff
            },
            gravitySamples: cache.gravitySamples.filter { $0.timestamp >= cutoff },
            motionRecordIdentities: Set(cache.motionRecordIdentities.filter {
                $0.projectedTimestamp >= cutoff
            })
        )
    }

    private static let recoveredBudgetChannelOrder: [RecoveredDataCompleteness.Channel] = [
        .heartRate, .rrRecords, .skinTemperature, .gravity, .motionReplayIdentity
    ]

    private static func recoveredBudgetLimitations(
        cache: RecoveredDataCache,
        budget: RecoveredProjectionBudget
    ) -> [RecoveredDataCompleteness.Channel: Int] {
        recoveredBudgetLimitations(heartRateCount: cache.heartRatePoints.count,
                                   rrRecordCount: cache.rrRecords.count,
                                   skinTemperatureCount: cache.skinTemperatureRawPoints.count,
                                   gravityCount: cache.gravitySamples.count,
                                   motionIdentityCount: cache.motionRecordIdentities.count,
                                   budget: budget)
    }

    private static func recoveredBudgetLimitations(
        heartRateCount: Int,
        rrRecordCount: Int,
        skinTemperatureCount: Int,
        gravityCount: Int,
        motionIdentityCount: Int,
        budget: RecoveredProjectionBudget
    ) -> [RecoveredDataCompleteness.Channel: Int] {
        var limitations: [RecoveredDataCompleteness.Channel: Int] = [:]
        if heartRateCount > budget.maximumHeartRatePoints {
            limitations[.heartRate] = budget.maximumHeartRatePoints
        }
        if rrRecordCount > budget.maximumRRRecords {
            limitations[.rrRecords] = budget.maximumRRRecords
        }
        if skinTemperatureCount > budget.maximumSkinTemperaturePoints {
            limitations[.skinTemperature] = budget.maximumSkinTemperaturePoints
        }
        if gravityCount > budget.maximumGravitySamples {
            limitations[.gravity] = budget.maximumGravitySamples
        }
        if motionIdentityCount > budget.maximumMotionReplayIdentities {
            limitations[.motionReplayIdentity] = budget.maximumMotionReplayIdentities
        }
        return limitations
    }

    private static func recoveredCompleteness(
        limitations: [RecoveredDataCompleteness.Channel: Int],
        channels: Set<RecoveredDataCompleteness.Channel>? = nil
    ) -> RecoveredDataCompleteness {
        for channel in recoveredBudgetChannelOrder
        where channels?.contains(channel) ?? true {
            if let limit = limitations[channel] {
                return .budgetExceeded(channel: channel, limit: limit)
            }
        }
        return .complete
    }

    private static func recoveredSnapshot(
        from cache: RecoveredDataCache,
        scan: RecoveredArchiveScanDiagnostics,
        limitations: [RecoveredDataCompleteness.Channel: Int]
    ) -> RecoveredDataSnapshot {
        let orderedLimitations = recoveredBudgetChannelOrder.compactMap { channel in
            limitations[channel].map {
                RecoveredDataBudgetLimitation(channel: channel, limit: $0)
            }
        }
        let motionCompleteness = recoveredCompleteness(
            limitations: limitations,
            channels: [.gravity, .motionReplayIdentity]
        )
        return .init(heartRatePoints: cache.heartRatePoints,
                     rrRecords: cache.rrRecords,
                     skinTemperatureRawPoints: cache.skinTemperatureRawPoints,
                     motion: .init(samples: cache.gravitySamples,
                                   completeness: motionCompleteness),
                     scan: scan,
                     completeness: recoveredCompleteness(limitations: limitations),
                     physiologyCompleteness: recoveredCompleteness(
                        limitations: limitations,
                        channels: [.heartRate, .rrRecords]
                     ),
                     skinTemperatureCompleteness: recoveredCompleteness(
                        limitations: limitations,
                        channels: [.skinTemperature]
                     ),
                     budgetLimitations: orderedLimitations)
    }

    /// Test/replay adapter for the same independent metric gates used by the
    /// one-pass file scanner. In particular, a row may remain usable for
    /// verified HR/RR even when its gravity vector fails the stricter motion
    /// range; motion failure must not discard another independently proven
    /// channel from the archive snapshot.
    static func makeRecoveredDataSnapshot(
        records: [Record],
        since: Date,
        budget: RecoveredProjectionBudget = .production
    ) -> RecoveredDataSnapshot {
        let cutoff = since.timeIntervalSince1970
        var heartRate: [HeartRatePoint] = []
        var rrRecords: [Record] = []
        var skinTemperatureRawPoints: [SkinTemperatureRawPoint] = []
        var gravity: [GravitySample] = []
        var motionRecordIdentities = Set<AtriaRecoveredMotionReplayIdentity>()
        var limitations: [RecoveredDataCompleteness.Channel: Int] = [:]
        for record in records {
            appendRecoveredRecord(record,
                                  cutoff: cutoff,
                                  budget: budget,
                                  limitations: &limitations,
                                  heartRate: &heartRate,
                                  rrRecords: &rrRecords,
                                  skinTemperatureRawPoints: &skinTemperatureRawPoints,
                                  gravity: &gravity,
                                  motionRecordIdentities: &motionRecordIdentities)
        }
        sortRecoveredData(heartRate: &heartRate,
                          rrRecords: &rrRecords,
                          skinTemperatureRawPoints: &skinTemperatureRawPoints,
                          gravity: &gravity)
        let cache = RecoveredDataCache(coveredSince: cutoff,
                                       budget: budget,
                                       fileStates: [:],
                                       heartRatePoints: heartRate,
                                       rrRecords: rrRecords,
                                       skinTemperatureRawPoints: skinTemperatureRawPoints,
                                       gravitySamples: gravity,
                                       motionRecordIdentities: motionRecordIdentities)
        return recoveredSnapshot(
            from: cache,
            scan: .init(fileReadCount: 0,
                        byteCount: 0,
                        decodedRecordCount: records.count,
                        elapsedMilliseconds: 0),
            limitations: limitations
        )
    }

#if DEBUG
    static func resetFullGravityLoadCountForTesting() {
        fullGravityInstrumentationLock.lock()
        fullGravityLoadCount = 0
        fullGravityInstrumentationLock.unlock()
    }

    static var fullGravityLoadCountForTesting: Int {
        fullGravityInstrumentationLock.lock()
        let count = fullGravityLoadCount
        fullGravityInstrumentationLock.unlock()
        return count
    }
#endif

    private static func recoveredMotionWindowDiagnostics(
        start: Date,
        end: Date,
        records: [GravitySample]
    ) -> MotionWindowDiagnostics {
        let evidence = recoveredMotionEvidence(start: start, end: end, records: records)
        let trusted = records
            .filter { $0.timestampValidated && $0.validated }
            .map(\.timestamp)
            .sorted()
        let archiveFirst = Int((trusted.first ?? 0).rounded())
        let archiveLast = Int((trusted.last ?? 0).rounded())
        return MotionWindowDiagnostics(
            status: evidence.lowMotionQualified ? "ready" : "learning",
            reason: evidence.reason,
            rows: evidence.rows,
            validatedRows: evidence.validatedRows,
            coverageSeconds: evidence.coverageSeconds,
            spanSeconds: max(0, Int(end.timeIntervalSince(start).rounded())),
            meanVectorDelta: evidence.movementIntensity,
            p95VectorDelta: evidence.p95VectorDelta,
            magnitudeMean: nil,
            magnitudeStdDev: nil,
            archiveFirstUnix: archiveFirst,
            archiveLastUnix: archiveLast,
            nearestSeparationSeconds: nearestSeparationSeconds(
                archiveFirst: TimeInterval(archiveFirst),
                archiveLast: TimeInterval(archiveLast),
                windowStart: start.timeIntervalSince1970,
                windowEnd: end.timeIntervalSince1970
            ),
            lowMotionReady: evidence.lowMotionQualified
        )
    }

    private static func recoveredMotionEvidence(
        start: Date,
        end: Date,
        records: [GravitySample]
    ) -> AtriaRecoveredMotionProjection.Evidence {
        AtriaRecoveredMotionProjection.project(
            samples: records.map { sample in
                .init(timestamp: Date(timeIntervalSince1970: sample.timestamp),
                      sequence: sample.sequence,
                      x: sample.x,
                      y: sample.y,
                      z: sample.z,
                      timestampValidated: sample.timestampValidated,
                      gravityValidated: sample.validated)
            },
            window: .init(id: "full_archive", start: start, end: end)
        )
    }

    static func motionFeatureSummary(start: Date, end: Date) -> MotionFeatureSummary? {
        guard end > start else { return nil }
        let samples = loadRecentGravitySamples(start: start, end: end)
        let evidence = AtriaRecoveredMotionProjection.project(
            samples: samples.map { sample in
                .init(timestamp: Date(timeIntervalSince1970: sample.timestamp),
                      sequence: sample.sequence,
                      x: sample.x,
                      y: sample.y,
                      z: sample.z,
                      timestampValidated: sample.timestampValidated,
                      gravityValidated: sample.validated)
            },
            window: .init(id: "bounded_recent", start: start, end: end)
        )
        guard evidence.rows > 0,
              let stillness = evidence.stillnessRatio,
              let intensity = evidence.movementIntensity else { return nil }
        let trustedTimes = samples
            .filter { $0.timestampValidated && $0.validated }
            .map(\.timestamp)
            .filter { $0 >= start.timeIntervalSince1970 && $0 <= end.timeIntervalSince1970 }
            .sorted()
        return MotionFeatureSummary(stillnessRatio: stillness,
                                    movementIntensity: intensity,
                                    rows: evidence.rows,
                                    validatedRows: evidence.validatedRows,
                                    coverageSeconds: evidence.coverageSeconds,
                                    maximumGapSeconds: evidence.maximumGapSeconds,
                                    firstUnix: Int((trustedTimes.first ?? 0).rounded()),
                                    lastUnix: Int((trustedTimes.last ?? 0).rounded()),
                                    reason: evidence.reason)
    }

    static func boundedMotionWindowDiagnostics(start: Date, end: Date) -> MotionWindowDiagnostics {
        guard let summary = motionFeatureSummary(start: start, end: end) else {
            return emptyMotionWindow(status: "missing", reason: "bounded_recent_no_overlap")
        }
        return MotionWindowDiagnostics(status: summary.lowMotionReady ? "ready" : "insufficient_motion",
                                       reason: summary.reason,
                                       rows: summary.rows,
                                       validatedRows: summary.validatedRows,
                                       coverageSeconds: summary.coverageSeconds,
                                       spanSeconds: max(0, Int(end.timeIntervalSince(start).rounded())),
                                       meanVectorDelta: summary.movementIntensity,
                                       p95VectorDelta: nil,
                                       magnitudeMean: nil,
                                       magnitudeStdDev: nil,
                                       archiveFirstUnix: summary.firstUnix,
                                       archiveLastUnix: summary.lastUnix,
                                       nearestSeparationSeconds: 0,
                                       lowMotionReady: summary.lowMotionReady)
    }

    static func metricHeartRatePoints(since: Date? = nil, limit: Int? = nil) -> [HeartRatePoint] {
        if since == nil, let limit {
            return loadRecentHeartRateSamples(limit: limit)
        }
        if let since {
            return loadRecentHeartRateSamples(since: since, limit: limit ?? 6_000)
        }
        return loadHeartRateSamples(since: since, limit: limit)
    }

    /// Exact, memory-bounded raw-history lookup for a closed-open workout
    /// window. Unlike the recent-tail facade, newer rows cannot consume this
    /// window's row budget. Sealed catalog bounds select only overlapping raw
    /// chunks; active/legacy/untrusted files are conservatively streamed in
    /// 64-KiB pieces. A truncated or unreadable scan fails closed to nil.
    static func metricHeartRatePoints(
        start: Date,
        end: Date,
        maximumPoints: Int
    ) -> HeartRateWindowRead? {
        guard end > start, maximumPoints > 0 else { return nil }
        let candidates = recentReadableFileURLs()
        let catalog = (try? catalogStoreLocked()).flatMap { try? $0.snapshot() }
        return exactMetricHeartRatePoints(
            in: candidates,
            catalog: catalog,
            archiveRoot: archiveDirectory,
            start: start,
            end: end,
            maximumPoints: maximumPoints
        )
    }

    /// Testable production seam. The scanner never materializes a source file;
    /// its resident payload is one chunk plus at most `maximumPoints` results.
    static func exactMetricHeartRatePoints(
        in candidates: [URL],
        catalog: AtriaHistoricalArchiveCatalog?,
        archiveRoot: URL,
        start: Date,
        end: Date,
        maximumPoints: Int,
        fileManager: FileManager = .default
    ) -> HeartRateWindowRead? {
        guard end > start, maximumPoints > 0 else { return nil }
        let selected: [URL]
        if let catalog {
            selected = exactWindowProjectionFileURLs(
                candidates: candidates,
                catalog: catalog,
                archiveRoot: archiveRoot,
                start: start,
                end: end,
                fileManager: fileManager
            )
        } else {
            selected = candidates
        }
        guard selected.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            return nil
        }
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(for: selected)
        guard selected.isEmpty || !descriptors.isEmpty else {
            return nil
        }

        var points: [HeartRatePoint] = []
        let durationCapacity = Int(min(Double(maximumPoints),
                                       max(2, end.timeIntervalSince(start) + 1)))
        points.reserveCapacity(durationCapacity)
        var overflowed = false
        let result = AtriaHistoricalJSONLRecentScanner.scan(
            sources: descriptors.map { .init(descriptor: $0, startOffset: 0) },
            // Current-session rows may need capturedAt correction, so raw unix
            // is not a safe lower-bound prefilter here.
            cutoff: 0
        ) { line in
            guard !overflowed,
                  let text = String(data: line, encoding: .utf8),
                  let point = fastHeartRatePoint(from: text),
                  point.t >= start,
                  point.t < end else { return }
            guard points.count < maximumPoints else {
                overflowed = true
                return
            }
            points.append(point)
        }
        guard result.complete, !overflowed else { return nil }
        points.sort {
            if $0.t != $1.t { return $0.t < $1.t }
            return $0.bpm < $1.bpm
        }
        return .init(points: points,
                     scannedFileCount: result.statistics.fileReadCount,
                     scannedByteCount: result.statistics.byteCount)
    }

    private static func appendJSONLine<T: Encodable>(_ value: T) throws -> URL {
        // Serialize with compactArchive/promoteMetricUsableRows: both rewrite the
        // base file wholesale; an unlocked append during that window would land
        // on the doomed inode and be silently destroyed by the swap.
        promotionLock.lock()
        defer { promotionLock.unlock() }
        let url = try writableFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let previousAttributes = archiveAttributes(for: url)
        var line = data
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
        try catalogStoreLocked().recordAppendCompleted(at: url)
        updateDiagnosticsIndexAfterAppend(object: object,
                                          archiveURL: url,
                                          previousAttributes: previousAttributes)
        NotificationCenter.default.post(name: didUpdateNotification, object: nil)
        return url
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var archiveDirectory: URL {
        documentsDirectory.appendingPathComponent("atria-historical", isDirectory: true)
    }

    /// Exact recovery publication owns the archive projection lane until its
    /// recovered rows have crossed SessionStore's durable publication fence.
    /// Starting a multi-hundred-megabyte shadow build first can otherwise hold
    /// the shared serial queue past the finite projection lease and leave a
    /// physically proven gap permanently parked at `coverageProven`.
    static func exactRecoveryProjectionOwnsArchivePriority(
        archiveRoot: URL? = nil
    ) -> Bool {
        let root = archiveRoot ?? archiveDirectory
        let store = AtriaHistoricalFullDrainCoverageStore(
            directoryURL: root.appendingPathComponent(
                "full-drain-authority-v1",
                isDirectory: true
            )
        )
        do {
            guard let status = try store.load()?.status else { return false }
            switch status {
            case .draining,
                 .historyComplete,
                 .coverageProven,
                 .consumersCommitted:
                return true
            case .gapResolvedConsumersPending,
                 .resolved:
                return false
            }
        } catch {
            // Corrupt terminal authority is not permission to start a large
            // competing mutation. Its recovery path remains fail-closed.
            return true
        }
    }

    static var verifiedActivityConsumerShadowDirectory: URL {
        archiveDirectory.appendingPathComponent(
            "verified-consumer-application-v1/activity-shadow-v1",
            isDirectory: true
        )
    }

    private static var segmentsDirectory: URL {
        archiveDirectory.appendingPathComponent(segmentsDirectoryName, isDirectory: true)
    }

    private static func writableFileURL(now: Date = Date()) throws -> URL {
        // New writes always use a bounded UUID chunk. Existing base/daily files
        // are discovered once as immutable legacy chunks and remain readable;
        // a sealed path is never reopened for append.
        try catalogStoreLocked().writableChunkURL(now: now)
    }

    private static func activeSegmentURL(for date: Date = Date()) -> URL {
        segmentsDirectory.appendingPathComponent(activeSegmentFilename(for: date))
    }

    private static func activeSegmentFilename(for date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        // Daily segments bound reconnect projection memory while preserving the
        // append-only archive. Existing monthly segment files remain readable.
        return String(format: "historical-archive-%04d-%02d-%02d.jsonl", year, month, day)
    }

    private static func writeRotationManifest(activeSegmentURL: URL, createdAt: Date) throws {
        let manifest = RotationManifest(version: 1,
                                        baseRelativePath: relativePath,
                                        activeSegmentRelativePath: documentsRelativePath(for: activeSegmentURL),
                                        createdAt: createdAt,
                                        rotationThresholdBytes: rotationThresholdBytes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: rotationManifestURL, options: .atomic)
    }

    private static func activeSegmentReadableURL() -> URL? {
        if let data = try? Data(contentsOf: rotationManifestURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let manifest = try? decoder.decode(RotationManifest.self, from: data) {
                let url = documentsDirectory.appendingPathComponent(manifest.activeSegmentRelativePath
                    .replacingOccurrences(of: "Documents/", with: ""))
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        let currentDay = activeSegmentURL()
        if FileManager.default.fileExists(atPath: currentDay.path) {
            return currentDay
        }
        return nil
    }

    private static func legacyRotatedSegmentFileURLs() -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: segmentsDirectory,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) else {
            return []
        }
        return items
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func rotatedSegmentFileURLs() -> [URL] {
        var urls = legacyRotatedSegmentFileURLs()
        urls.append(contentsOf: catalogRawFileURLs())
        var seen = Set<String>()
        return urls
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Holding `archiveCatalogInitializationLock` across `loadOrRecover` is
    /// deliberate and safe for the 1 Hz path: initialization must be exclusive
    /// (exactly one store may publish the recovered catalog), it runs at most
    /// once per process lifetime, and the recovery walk only reads file
    /// attributes and performs one durable catalog write — it never streams
    /// SHA256 over chunk contents or decompresses artifacts. In steady state
    /// this function is lock / cached-store check / unlock, so it cannot
    /// stall main-thread callers the way in-lock verification did
    /// (priority-inversion freeze fixed 2026-08-01 in
    /// `snapshotVerifiedAgainstFiles`).
    private static func catalogStoreLocked() throws -> AtriaHistoricalArchiveCatalogStore {
        archiveCatalogInitializationLock.lock()
        defer { archiveCatalogInitializationLock.unlock() }
        if let archiveCatalogStore { return archiveCatalogStore }
        let store = AtriaHistoricalArchiveCatalogStore(rootURL: archiveDirectory)
        var legacy = legacyRotatedSegmentFileURLs()
        if FileManager.default.fileExists(atPath: fileURL.path) { legacy.append(fileURL) }
        _ = try store.loadOrRecover(discoveredLegacyURLs: legacy, now: Date())
        archiveCatalogStore = store
        return store
    }

    private static func catalogRawFileURLs() -> [URL] {
        let catalogURL = archiveDirectory.appendingPathComponent("historical-archive.catalog-v2.json")
        guard FileManager.default.fileExists(atPath: catalogURL.path),
              let store = try? catalogStoreLocked(),
              let snapshot = try? store.snapshot() else { return [] }
        return snapshot.chunks
            .filter { $0.state != .retired }
            .map { archiveDirectory.appendingPathComponent($0.relativePath) }
    }

    private static func recentReadableFileURLs() -> [URL] {
        // Newest first so bounded readers spend their budget on the most
        // relevant rows, but retain every rotated month for reconnect gaps
        // that cross a month boundary.
        var urls = rotatedSegmentFileURLs().reversed().map { $0 }
        if let activeSegment = activeSegmentReadableURL() {
            urls.insert(activeSegment, at: 0)
        }
        urls.append(readableFileURL)
        urls.append(legacyFileURL)
        var seen = Set<String>()
        return urls.filter { url in
            guard FileManager.default.fileExists(atPath: url.path),
                  !seen.contains(url.path) else { return false }
            seen.insert(url.path)
            return true
        }
    }

    /// Returns a filesystem-metadata token for the exact source set used by
    /// heavyweight archive consumers. This performs directory enumeration and
    /// stat calls only; it never opens, hashes, decodes, compacts, or mutates a
    /// history source.
    static func consumerSourceFingerprint() -> ConsumerSourceFingerprint {
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: recentReadableFileURLs()
        )
        let catalogGeneration = (try? catalogStoreLocked())
            .flatMap { try? $0.snapshot().generation }
        return makeConsumerSourceFingerprint(
            catalogGeneration: catalogGeneration,
            descriptors: descriptors
        )
    }

    static func makeConsumerSourceFingerprint(
        catalogGeneration: UInt64?,
        descriptors: [AtriaHistoricalJSONLRecentScanner.FileDescriptor]
    ) -> ConsumerSourceFingerprint {
        .init(
            catalogGeneration: catalogGeneration,
            sources: descriptors
                .map {
                    ConsumerSourceFingerprint.Source(
                        path: $0.url.standardizedFileURL.path,
                        size: $0.size,
                        modificationTimeMilliseconds: Int64(
                            ($0.modificationTime * 1_000).rounded()
                        ),
                        resourceIdentifier: $0.resourceIdentifier
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.path != rhs.path { return lhs.path < rhs.path }
                    if lhs.size != rhs.size { return lhs.size < rhs.size }
                    if lhs.modificationTimeMilliseconds
                        != rhs.modificationTimeMilliseconds {
                        return lhs.modificationTimeMilliseconds
                            < rhs.modificationTimeMilliseconds
                    }
                    return (lhs.resourceIdentifier ?? "")
                        < (rhs.resourceIdentifier ?? "")
                }
        )
    }

    /// Narrows the recovered projection to raw chunks that can still overlap
    /// its cutoff. A sealed catalog bound is eligible to exclude a file only
    /// when the catalog's seal transaction durably bound that exact path,
    /// byte count, row count, digest, and first/last timestamp, and the file
    /// has not changed in size or modification time since the seal. The digest
    /// was verified when the bound was committed; rehashing every known-old
    /// chunk here would itself reread lifetime raw history on every refresh.
    ///
    /// Any missing, malformed, conflicting, active, or externally changed
    /// metadata fails closed for retention: that file remains in the scan.
    private static func recentRecoveredReadableFileURLs(
        since cutoff: TimeInterval
    ) -> [URL] {
        let candidates = recentReadableFileURLs()
        guard cutoff.isFinite,
              let store = try? catalogStoreLocked(),
              let catalog = try? store.snapshot() else {
            return candidates
        }
        return recoveredProjectionFileURLs(
            candidates: candidates,
            catalog: catalog,
            archiveRoot: archiveDirectory,
            since: cutoff
        )
    }

    /// A raw chunk that was durably sealed before a later workout scan window
    /// cannot contain rows ingested by that workout. This independent
    /// filesystem/catalog bound keeps exact motion replay from rereading
    /// lifetime archives whose older catalog rows predate timestamp indexing.
    /// Unknown, active, changed, or incompletely sealed chunks remain included.
    private static func motionWindowReadableFileURLs(
        start: Date,
        end: Date,
        fileManager: FileManager = .default
    ) -> [URL] {
        let candidates = recentReadableFileURLs()
        guard end > start,
              let store = try? catalogStoreLocked(),
              let catalog = try? store.snapshot(),
              (try? catalog.validate()) != nil else {
            return candidates
        }
        let canonicalRoot = archiveDirectory.standardizedFileURL
        let chunksByCanonicalPath = Dictionary(grouping: catalog.chunks) { chunk in
            canonicalRoot.appendingPathComponent(chunk.relativePath)
                .standardizedFileURL.path
        }
        return candidates.filter { candidate in
            let canonicalCandidate = candidate.standardizedFileURL
            let matching = chunksByCanonicalPath[canonicalCandidate.path] ?? []
            guard matching.count == 1,
                  let chunk = matching.first,
                  chunk.state == .sealed,
                  let sealedAt = chunk.sealedAt,
                  sealedAt < start,
                  chunk.byteCount > 0,
                  let digest = chunk.contentSHA256,
                  digest.count == 64,
                  digest.unicodeScalars.allSatisfy(
                    CharacterSet(charactersIn: "0123456789abcdef").contains
                  ),
                  let attributes = try? fileManager.attributesOfItem(
                    atPath: canonicalCandidate.path
                  ),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  (attributes[.size] as? NSNumber)?.uint64Value
                    == chunk.byteCount,
                  let modificationDate =
                    attributes[.modificationDate] as? Date,
                  modificationDate.timeIntervalSince(sealedAt) <= 1 else {
                return true
            }
            return false
        }
    }

    /// Internal seam shared by production selection and focused retention
    /// tests. Returning a candidate is always safe; exclusion requires one
    /// unique, durably verified sealed catalog bound proving it wholly old.
    static func recoveredProjectionFileURLs(
        candidates: [URL],
        catalog: AtriaHistoricalArchiveCatalog,
        archiveRoot: URL,
        since cutoff: TimeInterval,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard cutoff.isFinite,
              (try? catalog.validate()) != nil else {
            return candidates
        }

        let canonicalRoot = archiveRoot.standardizedFileURL
        let chunksByCanonicalPath = Dictionary(grouping: catalog.chunks) { chunk in
            canonicalRoot.appendingPathComponent(chunk.relativePath)
                .standardizedFileURL.path
        }
        return candidates.filter { candidate in
            let canonicalCandidate = candidate.standardizedFileURL
            let matchingChunks = chunksByCanonicalPath[canonicalCandidate.path] ?? []
            guard matchingChunks.count == 1,
                  let chunk = matchingChunks.first,
                  sealedCatalogBoundIsDurablyTrusted(
                    chunk,
                    fileURL: canonicalCandidate,
                    cutoff: cutoff,
                    fileManager: fileManager
                  ) else {
                // Unknown/untrusted bounds are conservatively scanned.
                return true
            }
            return false
        }
    }

    /// Selects raw chunks that may overlap one exact closed-open interval.
    /// A file is excluded only when one immutable catalog row, still matching
    /// its on-disk byte identity, proves the complete chunk is before or after
    /// the requested window. Unknown and active files remain scan candidates.
    static func exactWindowProjectionFileURLs(
        candidates: [URL],
        catalog: AtriaHistoricalArchiveCatalog,
        archiveRoot: URL,
        start: Date,
        end: Date,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard end > start,
              start.timeIntervalSince1970.isFinite,
              end.timeIntervalSince1970.isFinite,
              (try? catalog.validate()) != nil else {
            return candidates
        }

        let canonicalRoot = archiveRoot.standardizedFileURL
        let chunksByCanonicalPath = Dictionary(grouping: catalog.chunks) { chunk in
            canonicalRoot.appendingPathComponent(chunk.relativePath)
                .standardizedFileURL.path
        }
        return candidates.filter { candidate in
            let canonicalCandidate = candidate.standardizedFileURL
            let matchingChunks = chunksByCanonicalPath[canonicalCandidate.path] ?? []
            guard matchingChunks.count == 1,
                  let chunk = matchingChunks.first,
                  sealedCatalogBoundIsDurablyTrustedOutsideWindow(
                    chunk,
                    fileURL: canonicalCandidate,
                    start: start,
                    end: end,
                    fileManager: fileManager
                  ) else {
                return true
            }
            return false
        }
    }

    private static func sealedCatalogBoundIsDurablyTrustedOutsideWindow(
        _ chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        fileURL: URL,
        start: Date,
        end: Date,
        fileManager: FileManager
    ) -> Bool {
        guard chunk.state == .sealed,
              let sealedAt = chunk.sealedAt,
              let rowCount = chunk.rowCount,
              rowCount > 0,
              let firstTimestamp = chunk.firstTimestamp,
              let lastTimestamp = chunk.lastTimestamp,
              lastTimestamp > firstTimestamp,
              lastTimestamp < start || firstTimestamp >= end,
              chunk.byteCount > 0,
              let digest = chunk.contentSHA256,
              digest.count == 64,
              digest.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdef").contains
              ),
              let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.size] as? NSNumber)?.uint64Value == chunk.byteCount,
              let modificationDate = attributes[.modificationDate] as? Date,
              modificationDate.timeIntervalSince(sealedAt) <= 1 else {
            return false
        }
        return true
    }

    /// Returns true only when an immutable sealed file is proven to end before
    /// the requested window and may therefore be omitted without data loss.
    private static func sealedCatalogBoundIsDurablyTrusted(
        _ chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        fileURL: URL,
        cutoff: TimeInterval,
        fileManager: FileManager
    ) -> Bool {
        guard chunk.state == .sealed,
              let sealedAt = chunk.sealedAt,
              let rowCount = chunk.rowCount,
              rowCount > 0,
              let firstTimestamp = chunk.firstTimestamp?.timeIntervalSince1970,
              let lastTimestamp = chunk.lastTimestamp?.timeIntervalSince1970,
              firstTimestamp.isFinite,
              lastTimestamp.isFinite,
              lastTimestamp > firstTimestamp,
              lastTimestamp < cutoff,
              chunk.byteCount > 0,
              let digest = chunk.contentSHA256,
              digest.count == 64,
              digest.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdef").contains
              ),
              let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.size] as? NSNumber)?.uint64Value == chunk.byteCount,
              let modificationDate = attributes[.modificationDate] as? Date,
              // Filesystem timestamp precision can be coarser than Date.
              modificationDate.timeIntervalSince(sealedAt) <= 1 else {
            return false
        }
        return true
    }

    private static func documentsRelativePath(for url: URL) -> String {
        let documentsPath = documentsDirectory.path
        guard url.path.hasPrefix(documentsPath) else { return url.path }
        let suffix = url.path.dropFirst(documentsPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "Documents/\(suffix)"
    }

    private static func archiveAttributes(for url: URL) -> (byteCount: Int, modificationTime: TimeInterval) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let modificationTime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (byteCount, modificationTime)
    }

    private static func diagnosticsIndexURL(for url: URL) -> URL? {
        if url == fileURL {
            return diagnosticsIndexURL
        }
        // UUID raw chunks live in segments/raw-v2 rather than directly under
        // segments. Keep each immutable chunk's sidecar adjacent to it.
        guard url.standardizedFileURL.path.hasPrefix(archiveDirectory.path + "/"),
              url.pathExtension == "jsonl" else { return nil }
        return url.deletingPathExtension().appendingPathExtension("diagnostics.json")
    }

    private static func readDiagnosticsIndex(for url: URL,
                                             attributes: (byteCount: Int, modificationTime: TimeInterval)) -> DiagnosticsIndex? {
        guard let indexURL = diagnosticsIndexURL(for: url),
              let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(DiagnosticsIndex.self, from: data),
              index.fileSize == attributes.byteCount,
              abs(index.modificationTime - attributes.modificationTime) < 0.001 else {
            return nil
        }
        return index
    }

    private static func writeDiagnosticsIndex(_ index: DiagnosticsIndex, for url: URL) {
        guard let indexURL = diagnosticsIndexURL(for: url) else { return }
        diagnosticsIndexLock.lock()
        defer { diagnosticsIndexLock.unlock() }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(index)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: indexURL)
        }
    }

    private static func scanDiagnosticsIndex(for url: URL,
                                             attributes: (byteCount: Int, modificationTime: TimeInterval)) -> DiagnosticsIndex? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var index = DiagnosticsIndex(fileSize: attributes.byteCount,
                                     modificationTime: attributes.modificationTime,
                                     rows: 0,
                                     schemas: [],
                                     layoutVersions: [],
                                     metricUsableRows: 0,
                                     currentSessionUsableRows: 0,
                                     undecodableRows: 0,
                                     rawPayloadRows: 0,
                                     unixFirst: nil,
                                     unixLast: nil,
                                     correctedUnixFirst: nil,
                                     correctedUnixLast: nil,
                                     gravityRows: 0,
                                     gravityValidatedRows: 0)
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            append(object: object, to: &index)
        }
        return index
    }

    private static func aggregateDiagnosticsIndex(base: DiagnosticsIndex,
                                                  segments: [DiagnosticsIndex]) -> DiagnosticsIndex {
        segments.reduce(base) { partial, segment in
            DiagnosticsIndex(fileSize: partial.fileSize + segment.fileSize,
                             modificationTime: max(partial.modificationTime, segment.modificationTime),
                             rows: partial.rows + segment.rows,
                             schemas: sortedUnion(partial.schemas, segment.schemas),
                             layoutVersions: sortedUnion(partial.layoutVersions, segment.layoutVersions),
                             metricUsableRows: partial.metricUsableRows + segment.metricUsableRows,
                             currentSessionUsableRows: partial.currentSessionUsableRows + segment.currentSessionUsableRows,
                             undecodableRows: partial.undecodableRows + segment.undecodableRows,
                             rawPayloadRows: partial.rawPayloadRows + segment.rawPayloadRows,
                             unixFirst: minOptional(partial.unixFirst, segment.unixFirst),
                             unixLast: maxOptional(partial.unixLast, segment.unixLast),
                             correctedUnixFirst: minOptional(partial.correctedUnixFirst, segment.correctedUnixFirst),
                             correctedUnixLast: maxOptional(partial.correctedUnixLast, segment.correctedUnixLast),
                             gravityRows: partial.gravityRows + segment.gravityRows,
                             gravityValidatedRows: partial.gravityValidatedRows + segment.gravityValidatedRows)
        }
    }

    private static func diagnostics(from index: DiagnosticsIndex, reason: String) -> Diagnostics {
        Diagnostics(exists: true,
                    parseOK: true,
                    rows: index.rows,
                    bytes: index.fileSize,
                    schemas: index.schemas,
                    layoutVersions: index.layoutVersions,
                    metricUsableRows: index.metricUsableRows,
                    currentSessionUsableRows: index.currentSessionUsableRows,
                    undecodableRows: index.undecodableRows,
                    rawPayloadRows: index.rawPayloadRows,
                    unixFirst: index.unixFirst,
                    unixLast: index.unixLast,
                    correctedUnixFirst: index.correctedUnixFirst,
                    correctedUnixLast: index.correctedUnixLast,
                    gravityRows: index.gravityRows,
                    gravityValidatedRows: index.gravityValidatedRows,
                    reason: reason)
    }

    private static func updateDiagnosticsIndexAfterAppend(object: [String: Any]?,
                                                          archiveURL: URL,
                                                          previousAttributes: (byteCount: Int, modificationTime: TimeInterval)) {
        guard let indexURL = diagnosticsIndexURL(for: archiveURL) else { return }
        let attributes = archiveAttributes(for: archiveURL)
        diagnosticsIndexLock.lock()
        defer { diagnosticsIndexLock.unlock() }
        guard let object else {
            try? FileManager.default.removeItem(at: indexURL)
            return
        }
        let existingIndex: DiagnosticsIndex?
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode(DiagnosticsIndex.self, from: data),
           decoded.fileSize == previousAttributes.byteCount,
           abs(decoded.modificationTime - previousAttributes.modificationTime) < 0.001 {
            existingIndex = decoded
        } else if previousAttributes.byteCount == 0 {
            existingIndex = DiagnosticsIndex(fileSize: 0,
                                             modificationTime: previousAttributes.modificationTime,
                                             rows: 0,
                                             schemas: [],
                                             layoutVersions: [],
                                             metricUsableRows: 0,
                                             currentSessionUsableRows: 0,
                                             undecodableRows: 0,
                                             rawPayloadRows: 0,
                                             unixFirst: nil,
                                             unixLast: nil,
                                             correctedUnixFirst: nil,
                                             correctedUnixLast: nil,
                                             gravityRows: 0,
                                             gravityValidatedRows: 0)
        } else {
            try? FileManager.default.removeItem(at: indexURL)
            return
        }
        guard var index = existingIndex else { return }
        append(object: object, to: &index)
        index.fileSize = attributes.byteCount
        index.modificationTime = attributes.modificationTime
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: indexURL)
        }
    }

    private static func beginDurableDiagnosticsAccumulationIfNeeded(
        generation: UInt64,
        archiveURL: URL
    ) {
        let canonical = archiveURL.standardizedFileURL
        diagnosticsIndexLock.lock()
        defer { diagnosticsIndexLock.unlock() }
        if durableDiagnosticsAccumulators[generation]?[canonical.path] != nil {
            return
        }
        let attributes = archiveAttributes(for: canonical)
        let initial: DiagnosticsIndex?
        if let indexURL = diagnosticsIndexURL(for: canonical),
           let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode(
               DiagnosticsIndex.self,
               from: data
           ),
           decoded.fileSize == attributes.byteCount,
           abs(decoded.modificationTime - attributes.modificationTime)
               < 0.001 {
            initial = decoded
        } else if attributes.byteCount == 0 {
            initial = DiagnosticsIndex(
                fileSize: 0,
                modificationTime: attributes.modificationTime,
                rows: 0,
                schemas: [],
                layoutVersions: [],
                metricUsableRows: 0,
                currentSessionUsableRows: 0,
                undecodableRows: 0,
                rawPayloadRows: 0,
                unixFirst: nil,
                unixLast: nil,
                correctedUnixFirst: nil,
                correctedUnixLast: nil,
                gravityRows: 0,
                gravityValidatedRows: 0
            )
        } else {
            // A missing/stale preexisting index stays invalid and is rebuilt
            // by the existing bounded diagnostics path. Never scan a large
            // canonical archive in the BLE drain.
            initial = nil
        }
        var generationAccumulators =
            durableDiagnosticsAccumulators[generation] ?? [:]
        generationAccumulators[canonical.path] =
            DurableDiagnosticsAccumulator(
                archiveURL: canonical,
                index: initial
            )
        durableDiagnosticsAccumulators[generation] =
            generationAccumulators
    }

    private static func appendDurableDiagnostics(
        object: [String: Any]?,
        generation: UInt64,
        archiveURL: URL
    ) {
        let canonical = archiveURL.standardizedFileURL
        diagnosticsIndexLock.lock()
        defer { diagnosticsIndexLock.unlock() }
        guard let object,
              var accumulator =
                durableDiagnosticsAccumulators[generation]?[canonical.path],
              var index = accumulator.index else {
            return
        }
        append(object: object, to: &index)
        accumulator.index = index
        var generationAccumulators =
            durableDiagnosticsAccumulators[generation] ?? [:]
        generationAccumulators[canonical.path] = accumulator
        durableDiagnosticsAccumulators[generation] =
            generationAccumulators
    }

    private static func flushDurableDiagnostics(generation: UInt64) {
        diagnosticsIndexLock.lock()
        let accumulators = durableDiagnosticsAccumulators.removeValue(
            forKey: generation
        ).map { Array($0.values) } ?? []
        diagnosticsIndexLock.unlock()

        for accumulator in accumulators {
            guard var index = accumulator.index else { continue }
            let attributes = archiveAttributes(for: accumulator.archiveURL)
            index.fileSize = attributes.byteCount
            index.modificationTime = attributes.modificationTime
            writeDiagnosticsIndex(index, for: accumulator.archiveURL)
        }
    }

    private static func discardDurableDiagnostics(generation: UInt64) {
        diagnosticsIndexLock.lock()
        durableDiagnosticsAccumulators.removeValue(forKey: generation)
        diagnosticsIndexLock.unlock()
    }

    private static func append(object: [String: Any], to index: inout DiagnosticsIndex) {
        index.rows += 1
        if let schema = object["schema"] {
            index.schemas = sortedUnion(index.schemas, String(describing: schema))
        } else {
            index.schemas = sortedUnion(index.schemas, "missing")
        }
        if let layout = object["layoutVersion"] as? String, !layout.isEmpty {
            index.layoutVersions = sortedUnion(index.layoutVersions, layout)
        } else {
            index.layoutVersions = sortedUnion(index.layoutVersions, "undecodable")
            if object["source"] as? String == "0x2f" {
                index.undecodableRows += 1
            }
        }
        if metricUsable(object: object) {
            index.metricUsableRows += 1
        }
        if object["currentSessionUsable"] as? Bool == true || currentSessionUsable(object: object) {
            index.currentSessionUsableRows += 1
        }
        if let rawPayload = object["rawPayloadHex"] as? String, !rawPayload.isEmpty {
            index.rawPayloadRows += 1
            if let payload = bytes(fromHex: rawPayload),
               let gravity = historicalGravity(payload) {
                index.gravityRows += 1
                if gravity.validated {
                    index.gravityValidatedRows += 1
                }
            }
        }
        if let unixNumber = object["unix7"] as? NSNumber {
            let value = unixNumber.uint32Value
            if value > 0 {
                index.unixFirst = min(index.unixFirst ?? value, value)
                index.unixLast = max(index.unixLast ?? value, value)
            }
        }
        if let correctedNumber = object["clockCorrectedUnix7"] as? NSNumber {
            let value = correctedNumber.uint32Value
            if value > 0 {
                index.correctedUnixFirst = min(index.correctedUnixFirst ?? value, value)
                index.correctedUnixLast = max(index.correctedUnixLast ?? value, value)
            }
        }
    }

    private static func sortedUnion(_ values: [String], _ newValue: String) -> [String] {
        var set = Set(values)
        set.insert(newValue)
        return Array(set).sorted()
    }

    private static func sortedUnion(_ lhs: [String], _ rhs: [String]) -> [String] {
        Array(Set(lhs).union(rhs)).sorted()
    }

    private static func minOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return min(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private static func maxOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    fileprivate struct GravitySample {
        let timestamp: TimeInterval
        let sequence: Int
        let x: Double
        let y: Double
        let z: Double
        let magnitude: Double
        let validated: Bool
        let timestampValidated: Bool
    }

    /// Immutable projection input keyed by complete JSONL line boundaries.
    /// File identity fencing prevents an atomic compaction/rewrite from being
    /// mistaken for tail growth, while genuine history appends only decode the
    /// bytes added since the preceding snapshot.
    private struct RecoveredDataCache {
        let coveredSince: TimeInterval
        let budget: RecoveredProjectionBudget
        let fileStates: [String: AtriaHistoricalJSONLRecentScanner.FileState]
        let heartRatePoints: [HeartRatePoint]
        let rrRecords: [Record]
        let skinTemperatureRawPoints: [SkinTemperatureRawPoint]
        let gravitySamples: [GravitySample]
        let motionRecordIdentities: Set<AtriaRecoveredMotionReplayIdentity>
    }

    private struct RecentGravityCache {
        let loadedAt: Date
        let targetBytes: UInt64
        let samples: [GravitySample]
        let latestTimestamp: TimeInterval?
    }

    private static func loadGravitySamples() -> [GravitySample] {
#if DEBUG
        fullGravityInstrumentationLock.lock()
        fullGravityLoadCount += 1
        fullGravityInstrumentationLock.unlock()
#endif
        return recentReadableFileURLs()
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap(gravitySamples(from:))
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.sequence < $1.sequence
            }
    }

    private static func loadRecentGravitySamples(start: Date, end: Date) -> [GravitySample] {
        guard end > start else { return [] }
        let spanSeconds = max(1, end.timeIntervalSince(start))
        let estimatedRows = Int((spanSeconds / 2.0).rounded(.up)) + 720
        // A raw JSONL tail expands several-fold while Foundation decodes it.
        // The former 32 MiB ceiling drove an observed 696 MiB footprint jump
        // and an iOS CPU-resource kill during a single sleep review. Eight MiB
        // still covers the normal overnight Whoop cadence while keeping review
        // work bounded; older windows fail closed unless their decoded motion
        // epochs were already projected into the canonical session.
        let targetBytes = UInt64(max(2_097_152, min(8_388_608, estimatedRows * 640)))

        recentGravityCacheLock.lock()
        if let cache = recentGravityCache,
           cache.targetBytes >= targetBytes,
           recentGravityCacheCovers(cache, end: end) {
            let samples = cache.samples
            recentGravityCacheLock.unlock()
            return samples
        }
        if recentGravityLoadInFlight {
            recentGravityCacheLock.unlock()
            return []
        }
        recentGravityLoadInFlight = true
        let loadGeneration = recentGravityLoadGeneration
        recentGravityCacheLock.unlock()

        // Never decode archive JSON from a UI update. Main-thread callers fail
        // closed for this pass while a single utility task prepares the cache.
        if Thread.isMainThread {
            DispatchQueue.global(qos: .utility).async {
                let samples = loadRecentGravitySamplesUncached(targetBytes: targetBytes)
                publishRecentGravityCache(samples: samples,
                                          targetBytes: targetBytes,
                                          generation: loadGeneration)
            }
            return []
        }

        let samples = loadRecentGravitySamplesUncached(targetBytes: targetBytes)
        publishRecentGravityCache(samples: samples,
                                  targetBytes: targetBytes,
                                  generation: loadGeneration)
        return samples
    }

    private static func recentGravityCacheCovers(_ cache: RecentGravityCache, end: Date) -> Bool {
        if cache.samples.isEmpty {
            return Date().timeIntervalSince(cache.loadedAt) < 60
        }
        guard let latestTimestamp = cache.latestTimestamp else { return false }
        // A small tolerance covers the normal archive write/clock cadence. A
        // newer live window triggers a refresh and remains unvalidated until it
        // lands, rather than trusting stale motion evidence.
        return latestTimestamp >= end.timeIntervalSince1970 - 120
    }

    private static func publishRecentGravityCache(samples: [GravitySample],
                                                  targetBytes: UInt64,
                                                  generation: UInt64) {
        recentGravityCacheLock.lock()
        guard generation == recentGravityLoadGeneration else {
            recentGravityCacheLock.unlock()
            return
        }
        recentGravityCache = RecentGravityCache(loadedAt: Date(),
                                                targetBytes: targetBytes,
                                                samples: samples,
                                                latestTimestamp: samples.last?.timestamp)
        recentGravityLoadInFlight = false
        recentGravityCacheLock.unlock()
    }

#if DEBUG
    static func resetRecentGravityCacheForTesting() {
        recentGravityCacheLock.lock()
        recentGravityLoadGeneration &+= 1
        recentGravityCache = nil
        recentGravityLoadInFlight = false
        recentGravityCacheLock.unlock()

        recoveredDataCacheLock.lock()
        recoveredDataCache = nil
        recoveredDataCacheLock.unlock()

        // Fixture tests temporarily move the entire archive directory. Any
        // process-lifetime catalog or exact-index object would otherwise keep
        // referring to the inode/path set from the directory that was moved.
        archiveCatalogInitializationLock.lock()
        archiveCatalogStore = nil
        archiveCatalogInitializationLock.unlock()
        durableStoreLock.lock()
        durableStore = nil
        durableDrainBatches.removeAll()
        durableStoreLock.unlock()
        diagnosticsIndexLock.lock()
        durableDiagnosticsAccumulators.removeAll()
        diagnosticsIndexLock.unlock()
    }
#endif

    private static func loadRecentGravitySamplesUncached(targetBytes: UInt64) -> [GravitySample] {
        var samples: [GravitySample] = []
        var remainingBytes = targetBytes
        for url in recentReadableFileURLs().reversed() {
            guard remainingBytes > 0 else { break }
            guard let content = tailContent(from: url, targetBytes: remainingBytes) else { continue }
            samples.append(contentsOf: gravitySamples(from: content))
            let consumed = UInt64(content.utf8.count)
            remainingBytes = consumed >= remainingBytes ? 0 : remainingBytes - consumed
        }
        return samples.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.sequence < rhs.sequence
        }
    }

    private static func gravitySamples(from content: String) -> [GravitySample] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return content.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let record = try? decoder.decode(Record.self, from: data) else { return nil }
            return gravitySample(from: record)
        }
    }

    /// RR-equivalent verification for historical gravity. Stored metadata is
    /// not trusted until the versioned decoder reproduces its clock identity;
    /// subsecond ticks and flash counter are preserved for deterministic order.
    private static func gravitySample(from record: Record) -> GravitySample? {
        guard record.unix7 > 0,
              record.subsec11 < 32_768,
              let payload = bytes(fromHex: record.rawPayloadHex),
              payload.count == record.payloadLength,
              let gravity = historicalGravity(payload) else { return nil }

        let rawIdentityValidated: Bool
        if case .record(let decoded) = AtriaWhoop4HistoricalRecordDecoder.decode(
            payload,
            origin: "atria-recovered-motion"
        ) {
            rawIdentityValidated = decoded.counter == record.flash13
                && decoded.timestampSeconds == record.unix7
                && decoded.subsecond == record.subsec11
                && record.sequence == Int(decoded.layout.rawValue)
                && record.layoutVersion == layoutVersion(for: decoded.layout.rawValue)
                && decoded.gravity.magnitude.isFinite
                && abs(decoded.gravity.magnitude - gravity.magnitude) <= 0.000_1
        } else {
            rawIdentityValidated = false
        }

        let clockValidated: Bool
        if record.clockCorrectionStatus == "clock_ref_present",
           let device = record.clockDeviceRef,
           let wall = record.clockWallRef,
           let storedDrift = record.clockDriftSeconds,
           let corrected = record.clockCorrectedUnix7 {
            let drift = Int(wall) - Int(device)
            let snapped: Int
            if abs(drift) < 86_400 {
                snapped = drift
            } else if drift >= 0 {
                snapped = ((drift + 150) / 300) * 300
            } else {
                snapped = ((drift - 150) / 300) * 300
            }
            let expected = Int64(record.unix7) + Int64(snapped)
            clockValidated = storedDrift == drift
                && expected > 0
                && expected <= Int64(UInt32.max)
                && corrected == UInt32(expected)
        } else {
            clockValidated = false
        }
        let unix = record.clockCorrectedUnix7 ?? record.unix7
        let timestamp = TimeInterval(unix) + TimeInterval(record.subsec11) / 32_768
        let trusted = rawIdentityValidated
            && clockValidated
            && record.gravityValidated
            && gravity.validated
        return GravitySample(timestamp: timestamp,
                             sequence: Int(record.flash13),
                             x: gravity.x,
                             y: gravity.y,
                             z: gravity.z,
                             magnitude: gravity.magnitude,
                             validated: trusted,
                             timestampValidated: rawIdentityValidated && clockValidated)
    }

    private struct HeartRateArchiveRow {
        let capturedAt: TimeInterval
        let unix: UInt32
        let sequence: Int
        let bpm: Int
        let currentSessionUsable: Bool
    }

    private static func loadHeartRateSamples(since: Date?, limit: Int?) -> [HeartRatePoint] {
        let url = readableFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var records: [HeartRateArchiveRow] = []
        records.reserveCapacity(min(content.split(whereSeparator: \.isNewline).count, limit ?? Int.max))
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  metricUsable(object: object),
                  let bpmNumber = object["whoofHR17"] as? NSNumber else { continue }
            let bpm = bpmNumber.intValue
            guard (35...240).contains(bpm) else { continue }
            let correctedUnix = (object["clockCorrectedUnix7"] as? NSNumber)?.uint32Value
            let rawUnix = (object["unix7"] as? NSNumber)?.uint32Value
            guard let unix = correctedUnix ?? rawUnix, unix > 0 else { continue }
            let capturedAt = (object["capturedAt"] as? String).flatMap(Self.iso8601TimeInterval(from:))
                ?? TimeInterval(unix)
            records.append(HeartRateArchiveRow(capturedAt: capturedAt,
                                               unix: unix,
                                               sequence: (object["sequence"] as? NSNumber)?.intValue ?? 0,
                                               bpm: bpm,
                                               currentSessionUsable: currentSessionUsable(object: object)))
        }

        let currentUsable = records.filter(\.currentSessionUsable)
        let currentAnchor = currentUsable.max { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt < rhs.capturedAt
            }
            return lhs.unix < rhs.unix
        }
        let lowerBound = since?.timeIntervalSince1970 ?? 0
        var points: [HeartRatePoint] = []
        points.reserveCapacity(min(records.count, limit ?? records.count))
        for item in records {
            let timestamp: TimeInterval
            if item.currentSessionUsable,
               let anchor = currentAnchor,
               abs(item.capturedAt - TimeInterval(item.unix)) > 12 * 60 * 60 {
                timestamp = anchor.capturedAt
                    - TimeInterval(Int64(anchor.unix) - Int64(item.unix))
            } else {
                timestamp = TimeInterval(item.unix)
            }
            guard timestamp >= lowerBound else { continue }
            points.append(HeartRatePoint(t: Date(timeIntervalSince1970: timestamp),
                                         bpm: item.bpm))
        }
        let sorted = points.sorted { lhs, rhs in
            if lhs.t != rhs.t { return lhs.t < rhs.t }
            return lhs.bpm < rhs.bpm
        }
        guard let limit, sorted.count > limit else { return sorted }
        return Array(sorted.suffix(limit))
    }

    private static func loadRecentHeartRateSamples(limit: Int) -> [HeartRatePoint] {
        guard limit > 0 else { return [] }
        let targetBytes = UInt64(max(1_048_576, min(16_777_216, limit * 768)))
        var points: [HeartRatePoint] = []
        points.reserveCapacity(limit)
        for url in recentReadableFileURLs() {
            if points.count >= limit { break }
            guard let content = tailContent(from: url, targetBytes: targetBytes) else { continue }
            for rawLine in content.split(whereSeparator: \.isNewline).reversed() {
                if points.count >= limit { break }
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let point = fastHeartRatePoint(from: line) else { continue }
                points.append(point)
            }
        }
        return Array(points.sorted { lhs, rhs in
            if lhs.t != rhs.t { return lhs.t < rhs.t }
            return lhs.bpm < rhs.bpm
        }.suffix(limit))
    }

    private static func loadRecentHeartRateSamples(since: Date, limit: Int) -> [HeartRatePoint] {
        guard limit > 0 else { return [] }
        let lowerBound = since.timeIntervalSince1970
        let targetBytes = UInt64(max(4_194_304, min(100_663_296, limit * 1_024)))
        var points: [HeartRatePoint] = []
        points.reserveCapacity(limit)
        for url in recentReadableFileURLs() {
            if points.count >= limit { break }
            guard let content = tailContent(from: url, targetBytes: targetBytes) else { continue }
            for rawLine in content.split(whereSeparator: \.isNewline).reversed() {
                if points.count >= limit { break }
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let point = fastHeartRatePoint(from: line),
                      point.t.timeIntervalSince1970 >= lowerBound else { continue }
                points.append(point)
            }
        }
        return Array(points.sorted { lhs, rhs in
            if lhs.t != rhs.t { return lhs.t < rhs.t }
            return lhs.bpm < rhs.bpm
        }.suffix(limit))
    }

    private static func tailContent(from url: URL, targetBytes: UInt64) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset = fileSize > targetBytes ? fileSize - targetBytes : 0
        try? handle.seek(toOffset: startOffset)
        let data = handle.readDataToEndOfFile()
        guard var content = String(data: data, encoding: .utf8), !content.isEmpty else { return nil }
        if startOffset > 0, let firstNewline = content.firstIndex(where: \.isNewline) {
            content.removeSubrange(content.startIndex...firstNewline)
        }
        return content
    }

    private static func fastHeartRatePoint(from line: String) -> HeartRatePoint? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              metricUsable(object: object),
              let bpmNumber = object["whoofHR17"] as? NSNumber else { return nil }
        let bpm = bpmNumber.intValue
        guard (35...240).contains(bpm) else { return nil }
        let correctedUnix = (object["clockCorrectedUnix7"] as? NSNumber)?.uint32Value
        let rawUnix = (object["unix7"] as? NSNumber)?.uint32Value
        let unix = correctedUnix ?? rawUnix
        let capturedAt = (object["capturedAt"] as? String).flatMap(Self.iso8601TimeInterval(from:))
        let timestamp: TimeInterval
        if currentSessionUsable(object: object),
           let capturedAt,
           let unix,
           abs(capturedAt - TimeInterval(unix)) > 12 * 60 * 60 {
            timestamp = capturedAt
        } else if let unix, unix > 0 {
            timestamp = TimeInterval(unix)
        } else if let capturedAt {
            timestamp = capturedAt
        } else {
            return nil
        }
        return HeartRatePoint(t: Date(timeIntervalSince1970: timestamp), bpm: bpm)
    }

    private static func iso8601TimeInterval(from raw: String) -> TimeInterval? {
        archiveDateFormatter.date(from: raw)?.timeIntervalSince1970
    }

    private static func emptyMotionWindow(status: String, reason: String) -> MotionWindowDiagnostics {
        MotionWindowDiagnostics(status: status,
                                reason: reason,
                                rows: 0,
                                validatedRows: 0,
                                coverageSeconds: 0,
                                spanSeconds: 0,
                                meanVectorDelta: nil,
                                p95VectorDelta: nil,
                                magnitudeMean: nil,
                                magnitudeStdDev: nil,
                                archiveFirstUnix: 0,
                                archiveLastUnix: 0,
                                nearestSeparationSeconds: 0,
                                lowMotionReady: false)
    }

    private static func nearestSeparationSeconds(archiveFirst: TimeInterval,
                                                 archiveLast: TimeInterval,
                                                 windowStart: TimeInterval,
                                                 windowEnd: TimeInterval) -> Int {
        guard archiveFirst > 0, archiveLast > 0 else { return 0 }
        if archiveLast < windowStart {
            return Int((windowStart - archiveLast).rounded())
        }
        if archiveFirst > windowEnd {
            return Int((archiveFirst - windowEnd).rounded())
        }
        return 0
    }

    private static func coverageSeconds(for timestamps: [TimeInterval]) -> Int {
        guard let first = timestamps.min(), let last = timestamps.max(), last >= first else { return 0 }
        return Int((last - first).rounded())
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func stddev(_ values: [Double], mean: Double?) -> Double? {
        guard values.count >= 2, let mean else { return nil }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return sqrt(variance)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(fraction, 0), 1)
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * clamped).rounded(.down))))
        return sorted[index]
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func historicalGravity(_ payload: [UInt8]) -> (x: Double, y: Double, z: Double, magnitude: Double, validated: Bool)? {
        let version = payload.count > 1 ? Int(payload[1]) : -1
        let x: Double
        let y: Double
        let z: Double
        if version == 25 {
            guard let gx = i16le(payload, 69),
                  let gy = i16le(payload, 71),
                  let gz = i16le(payload, 73) else { return nil }
            x = Double(gx) / 16384.0
            y = Double(gy) / 16384.0
            z = Double(gz) / 16384.0
        } else {
            guard let gx = f32le(payload, 36),
                  let gy = f32le(payload, 40),
                  let gz = f32le(payload, 44) else { return nil }
            x = gx
            y = gy
            z = gz
        }
        let magnitude = sqrt(x * x + y * y + z * z)
        return (x, y, z, magnitude, (0.8...1.2).contains(magnitude))
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func f32le(_ bytes: [UInt8], _ offset: Int) -> Double? {
        guard offset + 3 < bytes.count else { return nil }
        let raw = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Double(Float32(bitPattern: raw))
    }

    private static func i16le(_ bytes: [UInt8], _ offset: Int) -> Int16? {
        guard offset + 1 < bytes.count else { return nil }
        let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        return Int16(bitPattern: raw)
    }

    // MARK: - Archive compaction (docs/24 §14.1 step 2)
    //
    // Streams the BASE aggregate file once: rows whose timestamps (BOTH the
    // strap-clock anchored time AND the wall-clock capture time) are older than
    // the cutoff — and that fall outside every pinned confirmed-sleep/workout
    // window — are folded into per-minute summary rows; everything else is kept
    // raw. Order: write summaries, write the kept-raw temp file, VERIFY it,
    // atomically swap, then drop the stale diagnostics sidecar. Appends never
    // race this rewrite (at >=128 MiB they already go to the rotated segment);
    // promoteMetricUsableRows is serialized via promotionLock. Hard invariant:
    // the kept set must retain metricUsable AND currentSessionUsable rows, or
    // the compaction ABORTS — the metric-ready greens may never regress.

    static let minuteSummarySchema = 1

    struct MinuteSummary: Codable {
        let schema: Int
        /// Anchored (strap-clock corrected) minute start, unix seconds.
        let minuteStart: Int
        let samples: Int
        let minHR: Int
        let maxHR: Int
        let hrSum: Int
        let rrCount: Int
        let gravitySamples: Int
        let metricUsableSamples: Int
    }

    struct CompactionResult {
        let status: String
        let scannedRows: Int
        let keptRows: Int
        let compactedRows: Int
        let summaryRows: Int
        let bytesBefore: Int
        let bytesAfter: Int
    }

    private static func minuteSummariesURL(forAnchoredMonth date: Date) -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: date)
        let name = String(format: "minutes-%04d-%02d.jsonl", components.year ?? 0, components.month ?? 0)
        return fileURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Builds and commits one parity-verified aggregate in shadow mode. Raw is
    /// intentionally retained until aggregate readers and retired-identity
    /// shards pass end-to-end parity. This replaces the former best-effort
    /// compactor, which could delete raw after unverified `try?` summary writes.
    static func compactArchive(olderThanDays: Int = 30,
                               pinnedWindows: [(start: Date, end: Date)],
                               reason: String,
                               configuration: AtriaHistoricalConsumerProjectionConfiguration,
                               now: Date = Date()) -> CompactionResult {
        do {
            let store = try catalogStoreLocked()
            let retirementExecutor = AtriaHistoricalRawRetirementExecutor(
                archiveRoot: archiveDirectory,
                catalogStore: store
            )
            if let recovered = try retirementExecutor.recoverFirstPendingIntent() {
                AtriaDebugLog("ATRIADBG archive_retention status=recovered_retirement_intent reason=%@ chunk=%@ source_deleted=%d catalog_retired=%d",
                              reason,
                              recovered.chunkID,
                              recovered.sourceDeleted ? 1 : 0,
                              recovered.catalogRetired ? 1 : 0)
                // One invocation may cross at most one irreversible raw
                // boundary. Recovery is therefore terminal; a fresh call can
                // independently select the next verified candidate.
                return CompactionResult(status: "ok_recovered_retirement_intent",
                                        scannedRows: 0,
                                        keptRows: 0,
                                        compactedRows: 0,
                                        summaryRows: 0,
                                        bytesBefore: 0,
                                        bytesAfter: 0)
            }
            let catalog = try store.snapshot()
            // Recover crash-left immutable generations before high-volume
            // accounting. The collector follows every durable current pointer
            // and never removes necessary typed history.
            do {
                let collected = try AtriaHistoricalGeneratedArtifactGC(
                    archiveRoot: archiveDirectory,
                    now: now
                ).prune()
                AtriaDebugLog("ATRIADBG historical_generated_gc status=maintenance removed=%d removed_bytes=%llu avoidable_after=%llu limit_satisfied=%d",
                              collected.removedFiles,
                              collected.removedBytes,
                              collected.avoidableBytesAfter,
                              collected.limitSatisfied ? 1 : 0)
            } catch {
                AtriaDebugLog("ATRIADBG historical_generated_gc status=deferred error=%@ removed=0",
                              String(describing: error))
            }
            // Substitute the large replay shard copies only after the retired
            // SQLite source receipt and all six canonical destinations have
            // independently revalidated. Typed historical destinations remain
            // untouched and a compact proof makes retries idempotent.
            var replayCompactedChunkIDs = Set<String>()
            for chunk in catalog.chunks.filter({ $0.state == .retired }).sorted(by: {
                let lhs = $0.lastTimestamp ?? $0.sealedAt ?? $0.createdAt
                let rhs = $1.lastTimestamp ?? $1.sealedAt ?? $1.createdAt
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }) {
                do {
                    let compacted = try AtriaHistoricalReplayPayloadCompactor(
                        archiveRoot: archiveDirectory
                    ).compactRetiredSource(chunkID: chunk.id, now: now)
                    if compacted.proof.publishedAt <= now.addingTimeInterval(-90 * 86_400) {
                        replayCompactedChunkIDs.insert(chunk.id)
                    }
                    if compacted.retiredBytes > 0 {
                        AtriaDebugLog("ATRIADBG retired_replay_payload status=compacted chunk=%@ retired_bytes=%llu typed_destinations_retained=1",
                                      chunk.id, compacted.retiredBytes)
                    }
                } catch {
                    AtriaDebugLog("ATRIADBG retired_replay_payload status=deferred chunk=%@ error=%@ payload_retained=1",
                                  chunk.id, String(describing: error))
                }
            }
            // Retired replay membership has a deliberate 14-day exact-dedupe
            // horizon; source receipts remain as 90-day reimport tombstones.
            // Run the SQLite page-reclaim transaction before accounting so the
            // combined cap observes physical post-VACUUM bytes, not a lifetime
            // freelist high-water mark. Any corruption/failure is fail-closed:
            // no raw selection or replay payload deletion follows this pass.
            let replayDatabaseURL = archiveDirectory
                .appendingPathComponent("retired-replay-v1", isDirectory: true)
                .appendingPathComponent("exact-identities-v3.sqlite")
            if FileManager.default.fileExists(atPath: replayDatabaseURL.path) {
                let replayIndex = try AtriaHistoricalRetiredReplayIndex(
                    databaseURL: replayDatabaseURL
                )
                let maintained = try replayIndex.maintainStorage(
                    identityCutoff: now.addingTimeInterval(-14 * 86_400),
                    sourceTombstoneCutoff: now.addingTimeInterval(-90 * 86_400),
                    sourceTombstoneRetirementAuthorizedChunkIDs: replayCompactedChunkIDs
                )
                AtriaDebugLog("ATRIADBG retired_replay_maintenance status=verified identities_removed=%d memberships_removed=%d tombstones_removed=%d identities_remaining=%d tombstones_remaining=%d bytes_before=%llu bytes_after=%llu",
                              maintained.removedExactIdentities,
                              maintained.removedSourceMemberships,
                              maintained.removedSourceTombstones,
                              maintained.remainingExactIdentities,
                              maintained.remainingSourceTombstones,
                              maintained.bytesBefore,
                              maintained.bytesAfter)
            }
            // Read-only high-volume accounting is advisory. A scan failure is
            // logged truthfully and cannot delay capture or authorize any
            // retention mutation.
            var highVolumeReport: AtriaHistoricalHighVolumeDiagnosticsCoordinator.Report?
            do {
                let diagnostics = try AtriaHistoricalHighVolumeDiagnosticsCoordinator
                    .evaluate(archiveRoot: archiveDirectory, catalog: catalog)
                highVolumeReport = diagnostics
                AtriaDebugLog("ATRIADBG archive_storage_diagnostics state=%@ high_volume_bytes=%llu cap_bytes=%llu projected_bytes=%llu cap_satisfied=%d net_decreasing_candidates=%d remaining_overage_bytes=%llu protected_active_bytes=%llu protected_active_overage_bytes=%llu unresolved_nonactive_overage_bytes=%llu compact_typed_bytes=%llu replay_evidence_bytes=%llu verified_replay_chunks=%d incomplete_replay_chunks=%d mutation_authority=0 raw_retained=1",
                              diagnostics.plan.state.rawValue,
                              diagnostics.accounting.highVolumeBytes,
                              diagnostics.plan.maximumHighVolumeBytes,
                              diagnostics.plan.projectedHighVolumeBytes,
                              diagnostics.plan.capSatisfied ? 1 : 0,
                              diagnostics.plan.selections.count,
                              diagnostics.plan.remainingOverageBytes,
                              diagnostics.plan.protectedActiveBytes,
                              diagnostics.plan.protectedActiveOverageBytes,
                              diagnostics.plan.unresolvedNonActiveOverageBytes,
                              diagnostics.accounting.compactLongTermTypedBytes,
                              diagnostics.accounting.replayEvidenceBytes,
                              diagnostics.verifiedReplayEvidenceChunkCount,
                              diagnostics.incompleteReplayEvidenceChunkCount)
            } catch {
                AtriaDebugLog("ATRIADBG archive_storage_diagnostics state=unavailable error=%@ mutation_authority=0 raw_retained=1",
                              String(describing: error))
            }
            let aggregates = archiveDirectory.appendingPathComponent("aggregates-v2", isDirectory: true)
            let manifests = archiveDirectory.appendingPathComponent("retention-manifests-v2", isDirectory: true)
            // A filename alone is not a commit. Only the strict reader's
            // digest/schema/parity-validated aggregate set can suppress retry.
            let aggregateReader = AtriaHistoricalAggregateReader(
                aggregateDirectoryURL: aggregates,
                manifestDirectoryURL: manifests
            )
            let committedIndex = aggregateReader.loadCommittedChunkIDs()
            guard !committedIndex.limitExceeded,
                  committedIndex.rejectedManifests == 0 else {
                AtriaDebugLog("ATRIADBG archive_retention status=deferred_reader_limit reason=%@ raw_retained=1",
                              reason)
                return CompactionResult(status: "deferred_retention_reader_limit",
                                        scannedRows: 0,
                                        keptRows: 0,
                                        compactedRows: 0,
                                        summaryRows: 0,
                                        bytesBefore: 0,
                                        bytesAfter: 0)
            }
            let committedChunkIDs = committedIndex.chunkIDs
            // The combined raw + exact-replay ceiling is an execution input, not
            // merely a dashboard diagnostic. Verified planner selections are
            // eligible for immediate cutover. While the tree is over cap, the
            // oldest sealed chunks whose replay proof is not ready are also fed
            // through the one-chunk shadow transaction so a later invocation can
            // actually reclaim them. The executor still performs every semantic,
            // consumer and replay-identity verification before unlinking raw.
            var highVolumeCandidateIDs = Set(
                highVolumeReport?.plan.selections.map(\.chunk.identifier) ?? []
            )
            if let report = highVolumeReport,
               report.accounting.highVolumeBytes > report.plan.maximumHighVolumeBytes {
                let incomplete = catalog.chunks
                    .filter { $0.state == .sealed && !committedChunkIDs.contains($0.id) }
                    .sorted { lhs, rhs in
                        let lhsEnd = lhs.lastTimestamp ?? lhs.sealedAt ?? lhs.createdAt
                        let rhsEnd = rhs.lastTimestamp ?? rhs.sealedAt ?? rhs.createdAt
                        if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
                        return lhs.id < rhs.id
                    }
                if let oldest = incomplete.first { highVolumeCandidateIDs.insert(oldest.id) }
            }
            let retention = AtriaHistoricalShadowCompactionCoordinator.retentionQueue(
                catalog: catalog,
                archiveDirectory: archiveDirectory,
                committedChunkIDs: committedChunkIDs,
                additionalCandidateIDs: highVolumeCandidateIDs,
                policy: .production,
                now: now
            )
            AtriaDebugLog("ATRIADBG archive_retention status=policy_evaluated reason=%@ raw_bytes=%llu projected_after_verified_retirement=%llu selected=%d shadow_pending=%d shadow_committed=%d missing_sources=%d provisional_timestamps=%d hard_cap_satisfied=%d raw_retained=1",
                          reason,
                          retention.plan.rawBytesBefore,
                          retention.plan.projectedRawBytes,
                          retention.plan.candidates.count,
                          retention.uncommittedCandidates.count,
                          retention.shadowCommittedCandidateIDs.count,
                          retention.missingSourceCandidateIDs.count,
                          retention.provisionalTimestampCandidateIDs.count,
                          retention.plan.hardCapSatisfied ? 1 : 0)
            let outcome = AtriaHistoricalShadowCompactionCoordinator.commitFirst(
                candidates: retention.uncommittedCandidates
            ) { chunk in
                let sourceURL = archiveDirectory.appendingPathComponent(chunk.relativePath)
                let build = try AtriaHistoricalAggregateBuilder.build(sourceURL: sourceURL,
                                                                      chunkID: chunk.id,
                                                                      createdAt: chunk.sealedAt
                                                                        ?? chunk.createdAt)
                // Catalog recovery intentionally registers legacy JSONL with nil
                // decoded bounds. Persist the builder's exact digest/count/time
                // identity before publishing its aggregate; otherwise legacy
                // archives can shadow-commit forever but can never satisfy the
                // raw-retirement executor's authority checks.
                if chunk.rowCount == nil || chunk.firstTimestamp == nil
                    || chunk.lastTimestamp == nil || chunk.contentSHA256 == nil {
                    try store.recordSealedMetadata(
                        chunkID: chunk.id,
                        rowCount: build.aggregate.source.rawRowCount,
                        firstTimestamp: build.aggregate.source.firstTimestamp,
                        lastTimestamp: build.aggregate.source.lastTimestamp,
                        contentSHA256: build.aggregate.source.rawSHA256
                    )
                }
                let transaction = AtriaHistoricalRetentionTransaction(
                    now: { now },
                    semanticVerifier: AtriaHistoricalAggregateBuilder.verify
                )
                let result = try transaction.commit(.init(
                    transactionID: chunk.id,
                    sourceURL: sourceURL,
                    aggregateDirectoryURL: aggregates,
                    manifestDirectoryURL: manifests,
                    aggregate: build.aggregate,
                    semanticParityReceipt: build.semanticParityReceipt,
                    deleteSourceAfterCommit: false
                ))
                return (chunk: chunk, build: build, result: result)
            }

            switch outcome {
            case .noCandidates:
                let status: String
                if !retention.missingSourceCandidateIDs.isEmpty {
                    status = "deferred_retention_source_unavailable"
                } else if let chunkID = retention.shadowCommittedCandidateIDs.first {
                    do {
                        let cutover = try publishAndVerifyHistoricalConsumerCutover(
                            chunkID: chunkID,
                            archiveRoot: archiveDirectory,
                            catalogStore: store,
                            configuration: configuration
                        )
                        let retired = try retirementExecutor.retire(chunkID: cutover.chunkID)
                        AtriaDebugLog("ATRIADBG archive_retention status=retired_verified_raw reason=%@ chunk=%@ completion_generation=%llu receipts=%d reused=%d source_deleted=%d catalog_retired=%d",
                                      reason,
                                      cutover.chunkID,
                                      cutover.completionGeneration,
                                      cutover.receiptCount,
                                      cutover.reusedReceiptCount,
                                      retired.sourceDeleted ? 1 : 0,
                                      retired.catalogRetired ? 1 : 0)
                        status = "ok_verified_consumer_cutover_raw_retired"
                    } catch {
                        AtriaDebugLog("ATRIADBG archive_retention status=deferred_verified_consumer_cutover reason=%@ chunk=%@ error=%@ raw_retained=1 retirement_authority=0",
                                      reason,
                                      chunkID,
                                      String(describing: error))
                        status = "deferred_verified_consumer_cutover_required"
                    }
                } else {
                    switch highVolumeReport?.plan.state {
                    case .protectedActiveException:
                        status = "noop_retention_protected_active_exception"
                    case .blocked, .progressOnly:
                        status = "deferred_retention_cap_unresolved"
                    case .capSatisfied, .none:
                        status = "noop_retention_within_bounds"
                    }
                }
                return CompactionResult(status: status,
                                        scannedRows: 0,
                                        keptRows: 0,
                                        compactedRows: 0,
                                        summaryRows: 0,
                                        bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                                        bytesAfter: Int(clamping: retention.plan.rawBytesBefore))
            case let .allFailed(failures):
                for failure in failures {
                    AtriaDebugLog("ATRIADBG archive_retention status=shadow_chunk_deferred reason=%@ chunk=%@ error=%@ raw_retained=1",
                                  reason,
                                  failure.chunkID,
                                  failure.message)
                }
                return CompactionResult(status: "deferred_shadow_verification_failed",
                                        scannedRows: 0,
                                        keptRows: 0,
                                        compactedRows: 0,
                                        summaryRows: 0,
                                        bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                                        bytesAfter: Int(clamping: retention.plan.rawBytesBefore))
            case let .committed(value, precedingFailures):
                for failure in precedingFailures {
                    AtriaDebugLog("ATRIADBG archive_retention status=shadow_chunk_skipped reason=%@ chunk=%@ error=%@ raw_retained=1",
                                  reason,
                                  failure.chunkID,
                                  failure.message)
                }
                let build = value.build
                let result = value.result
                AtriaDebugLog("ATRIADBG archive_retention status=shadow_committed reason=%@ chunk=%@ rows=%d raw_bytes=%llu aggregate=%@ manifest=%@ reused=%d raw_retained=1",
                              reason,
                              value.chunk.id,
                              build.aggregate.source.rawRowCount,
                              build.aggregate.source.rawByteCount,
                              result.aggregateURL.lastPathComponent,
                              result.manifestURL.lastPathComponent,
                              result.reusedCommittedTransaction ? 1 : 0)
                // Do not make a verified shadow wait for tomorrow's once-daily
                // pass. The same invocation can publish/re-read every consumer
                // and cross the one permitted irreversible boundary. Any failed
                // gate still leaves raw intact and returns an explicitly
                // retryable status.
                do {
                    let cutover = try publishAndVerifyHistoricalConsumerCutover(
                        chunkID: value.chunk.id,
                        archiveRoot: archiveDirectory,
                        catalogStore: store,
                        configuration: configuration
                    )
                    let retired = try retirementExecutor.retire(chunkID: cutover.chunkID)
                    AtriaDebugLog("ATRIADBG archive_retention status=retired_verified_raw_after_shadow reason=%@ chunk=%@ completion_generation=%llu receipts=%d source_deleted=%d catalog_retired=%d",
                                  reason,
                                  cutover.chunkID,
                                  cutover.completionGeneration,
                                  cutover.receiptCount,
                                  retired.sourceDeleted ? 1 : 0,
                                  retired.catalogRetired ? 1 : 0)
                    return CompactionResult(
                        status: "ok_verified_consumer_cutover_raw_retired",
                        scannedRows: build.aggregate.source.rawRowCount,
                        keptRows: build.aggregate.source.rawRowCount,
                        compactedRows: 0,
                        summaryRows: build.aggregate.heartRateMinutes.count
                            + build.aggregate.rrEpochs.count
                            + build.aggregate.motionEpochs.count,
                        bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                        bytesAfter: Int(clamping: retention.plan.projectedRawBytes)
                    )
                } catch {
                    AtriaDebugLog("ATRIADBG archive_retention status=deferred_verified_consumer_cutover_after_shadow reason=%@ chunk=%@ error=%@ raw_retained=1 retirement_authority=0",
                                  reason,
                                  value.chunk.id,
                                  String(describing: error))
                    return CompactionResult(
                        status: "deferred_verified_consumer_cutover_required",
                        scannedRows: build.aggregate.source.rawRowCount,
                        keptRows: build.aggregate.source.rawRowCount,
                        compactedRows: 0,
                        summaryRows: build.aggregate.heartRateMinutes.count
                            + build.aggregate.rrEpochs.count
                            + build.aggregate.motionEpochs.count,
                        bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                        bytesAfter: Int(clamping: retention.plan.rawBytesBefore)
                    )
                }
            }
        } catch {
            AtriaDebugLog("ATRIADBG archive_retention status=shadow_deferred reason=%@ error=%@ raw_retained=1",
                          reason,
                          error.localizedDescription)
            return CompactionResult(status: "deferred_shadow_verification_failed",
                                    scannedRows: 0,
                                    keptRows: 0,
                                    compactedRows: 0,
                                    summaryRows: 0,
                                    bytesBefore: 0,
                                    bytesAfter: 0)
        }
    }

    /// Makes bounded same-pass progress instead of consuming one daily launch
    /// per chunk. `compactArchive` still crosses at most one irreversible raw
    /// boundary; this coordinator starts a fresh fully verified transaction for
    /// each subsequent iteration and yields to the driver on time/iteration
    /// budget so capture cannot be starved.
    static func compactArchiveConverging(
        pinnedWindows: [(start: Date, end: Date)],
        reason: String,
        configuration: AtriaHistoricalConsumerProjectionConfiguration,
        now: Date = Date(),
        maximumIterations: Int = 8,
        maximumElapsed: TimeInterval = 8
    ) -> CompactionResult {
        precondition(maximumIterations > 0)
        precondition(maximumElapsed > 0)
        let started = Date()
        var firstBytesBefore: Int?
        var scanned = 0
        var kept = 0
        var compacted = 0
        var summaries = 0
        var last: CompactionResult?
        for _ in 0..<maximumIterations {
            let result = compactArchive(pinnedWindows: pinnedWindows,
                                        reason: reason,
                                        configuration: configuration,
                                        now: now)
            if firstBytesBefore == nil { firstBytesBefore = result.bytesBefore }
            scanned &+= result.scannedRows
            kept &+= result.keptRows
            compacted &+= result.compactedRows
            summaries &+= result.summaryRows
            last = result
            let madeProgress = result.status == "ok_recovered_retirement_intent"
                || result.status == "ok_verified_consumer_cutover_raw_retired"
                || result.status.hasPrefix("ok_shadow_")
            guard madeProgress else {
                return .init(status: result.status,
                             scannedRows: scanned,
                             keptRows: kept,
                             compactedRows: compacted,
                             summaryRows: summaries,
                             bytesBefore: firstBytesBefore ?? result.bytesBefore,
                             bytesAfter: result.bytesAfter)
            }
            if Date().timeIntervalSince(started) >= maximumElapsed { break }
        }
        let final = last ?? .init(status: "deferred_retention_cap_unresolved",
                                  scannedRows: 0, keptRows: 0, compactedRows: 0,
                                  summaryRows: 0, bytesBefore: 0, bytesAfter: 0)
        return .init(status: "yielded_retention_progress",
                     scannedRows: scanned,
                     keptRows: kept,
                     compactedRows: compacted,
                     summaryRows: summaries,
                     bytesBefore: firstBytesBefore ?? final.bytesBefore,
                     bytesAfter: final.bytesAfter)
    }

    /// Preserved temporarily as unreachable migration reference. It must not
    /// be re-enabled: its summary schema has no reader and cannot preserve RR,
    /// motion, strain, sleep, activity, or exact replay identity.
    private static func legacyCompactArchiveDisabled(olderThanDays: Int = 30,
                                                     pinnedWindows: [(start: Date, end: Date)],
                                                     reason: String,
                                                     now: Date = Date()) -> CompactionResult {
        promotionLock.lock()
        defer { promotionLock.unlock() }

        let sourceURL = fileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return CompactionResult(status: "skipped_no_base_file", scannedRows: 0, keptRows: 0,
                                    compactedRows: 0, summaryRows: 0, bytesBefore: 0, bytesAfter: 0)
        }
        let bytesBefore = archiveAttributes(for: sourceURL).byteCount
        let cutoff = now.addingTimeInterval(-TimeInterval(olderThanDays) * 24 * 60 * 60)
        let pinPadding: TimeInterval = 24 * 60 * 60
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func isPinned(_ instant: Date) -> Bool {
            pinnedWindows.contains { window in
                instant >= window.start.addingTimeInterval(-pinPadding)
                    && instant <= window.end.addingTimeInterval(pinPadding)
            }
        }

        let tempURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("historical-archive.compacting.jsonl")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let keepHandle = try? FileHandle(forWritingTo: tempURL),
              let stream = InputStream(url: sourceURL) else {
            return CompactionResult(status: "failed_io_setup", scannedRows: 0, keptRows: 0,
                                    compactedRows: 0, summaryRows: 0, bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }
        stream.open()
        defer { stream.close() }

        var scanned = 0
        var kept = 0
        var compacted = 0
        var keptMetricUsable = 0
        var keptCurrentUsable = 0
        var minuteBuckets: [Int: (samples: Int, minHR: Int, maxHR: Int, hrSum: Int, rrCount: Int, gravity: Int, metric: Int)] = [:]
        var carry = Data()
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var failed = false

        func processLine(_ lineData: Data) {
            guard !lineData.isEmpty else { return }
            scanned += 1
            func keepRaw() {
                keepHandle.write(lineData)
                keepHandle.write(Data([0x0a]))
                kept += 1
            }
            guard let record = try? decoder.decode(Record.self, from: lineData) else {
                // Undecodable frames and unknown shapes stay raw — they are rare
                // and this compactor must never destroy what it cannot summarize.
                keepRaw()
                return
            }
            let anchoredUnix = TimeInterval(record.clockCorrectedUnix7 ?? record.unix7)
            let anchoredDate = Date(timeIntervalSince1970: anchoredUnix)
            let isOldByBothClocks = anchoredDate < cutoff && record.capturedAt < cutoff
            if !isOldByBothClocks || isPinned(anchoredDate) || isPinned(record.capturedAt) {
                if record.metricUsable { keptMetricUsable += 1 }
                if record.currentSessionUsable { keptCurrentUsable += 1 }
                keepRaw()
                return
            }
            compacted += 1
            let minute = Int(anchoredUnix) / 60 * 60
            var bucket = minuteBuckets[minute] ?? (0, Int.max, 0, 0, 0, 0, 0)
            bucket.samples += 1
            if record.whoofHR17 > 0 {
                bucket.minHR = Swift.min(bucket.minHR, record.whoofHR17)
                bucket.maxHR = Swift.max(bucket.maxHR, record.whoofHR17)
                bucket.hrSum += record.whoofHR17
            }
            bucket.rrCount += record.whoofRR19.count
            if record.gravityValidated { bucket.gravity += 1 }
            if record.metricUsable { bucket.metric += 1 }
            minuteBuckets[minute] = bucket
        }

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: chunkSize)
            guard read >= 0 else { failed = true; break }
            if read == 0 { break }
            carry.append(contentsOf: buffer[0..<read])
            while let newline = carry.firstIndex(of: 0x0a) {
                processLine(carry.subdata(in: carry.startIndex..<newline))
                carry.removeSubrange(carry.startIndex...newline)
            }
        }
        if !failed, !carry.isEmpty {
            processLine(carry)
        }
        try? keepHandle.close()

        guard !failed else {
            try? FileManager.default.removeItem(at: tempURL)
            return CompactionResult(status: "failed_stream_read", scannedRows: scanned, keptRows: kept,
                                    compactedRows: compacted, summaryRows: 0, bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }
        guard compacted > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            return CompactionResult(status: "noop_nothing_to_compact", scannedRows: scanned, keptRows: kept,
                                    compactedRows: 0, summaryRows: 0, bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }
        // Green invariant: never leave the base file without usable raw rows.
        guard keptMetricUsable > 0, keptCurrentUsable > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            AtriaDebugLog("ATRIADBG archive_compaction status=aborted reason=green_invariant kept_metric_usable=%d kept_current_usable=%d",
                          keptMetricUsable,
                          keptCurrentUsable)
            return CompactionResult(status: "aborted_green_invariant", scannedRows: scanned, keptRows: kept,
                                    compactedRows: compacted, summaryRows: 0, bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }
        // Verify the kept file parses to the expected row count before swap.
        let verified = quickRowCount(at: tempURL)
        guard verified == kept else {
            try? FileManager.default.removeItem(at: tempURL)
            AtriaDebugLog("ATRIADBG archive_compaction status=aborted reason=verify_mismatch expected=%d actual=%d",
                          kept,
                          verified)
            return CompactionResult(status: "aborted_verify_mismatch", scannedRows: scanned, keptRows: kept,
                                    compactedRows: compacted, summaryRows: 0, bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }

        // Summaries FIRST (so a crash after summary-write but before swap only
        // duplicates summaries, never loses raw), then the atomic swap.
        var summaryRows = 0
        let encoder = JSONEncoder()
        var summariesByURL: [URL: Data] = [:]
        for (minute, bucket) in minuteBuckets.sorted(by: { $0.key < $1.key }) {
            let summary = MinuteSummary(schema: minuteSummarySchema,
                                        minuteStart: minute,
                                        samples: bucket.samples,
                                        minHR: bucket.minHR == Int.max ? 0 : bucket.minHR,
                                        maxHR: bucket.maxHR,
                                        hrSum: bucket.hrSum,
                                        rrCount: bucket.rrCount,
                                        gravitySamples: bucket.gravity,
                                        metricUsableSamples: bucket.metric)
            guard let data = try? encoder.encode(summary) else { continue }
            let url = minuteSummariesURL(forAnchoredMonth: Date(timeIntervalSince1970: TimeInterval(minute)))
            summariesByURL[url, default: Data()].append(data)
            summariesByURL[url]?.append(0x0a)
            summaryRows += 1
        }
        for (url, data) in summariesByURL {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }

        do {
            _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            AtriaDebugLog("ATRIADBG archive_compaction status=failed reason=swap error=%@",
                          error.localizedDescription)
            return CompactionResult(status: "failed_swap", scannedRows: scanned, keptRows: kept,
                                    compactedRows: compacted, summaryRows: summaryRows,
                                    bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }
        // Stale sidecar would zero the diagnostics via its fileSize+mtime key;
        // remove it so readers rebuild an index for the new file.
        if let sidecarURL = diagnosticsIndexURL(for: sourceURL) {
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        NotificationCenter.default.post(name: didUpdateNotification, object: nil)
        let bytesAfter = archiveAttributes(for: sourceURL).byteCount
        AtriaDebugLog("ATRIADBG archive_compaction status=ok reason=%@ scanned=%d kept=%d compacted=%d summary_rows=%d bytes_before=%d bytes_after=%d kept_metric_usable=%d kept_current_usable=%d",
                      reason,
                      scanned,
                      kept,
                      compacted,
                      summaryRows,
                      bytesBefore,
                      bytesAfter,
                      keptMetricUsable,
                      keptCurrentUsable)
        return CompactionResult(status: "ok", scannedRows: scanned, keptRows: kept,
                                compactedRows: compacted, summaryRows: summaryRows,
                                bytesBefore: bytesBefore, bytesAfter: bytesAfter)
    }

    private static func quickRowCount(at url: URL) -> Int {
        guard let stream = InputStream(url: url) else { return -1 }
        stream.open()
        defer { stream.close() }
        var count = 0
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var lastByte: UInt8 = 0x0a
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: chunkSize)
            guard read > 0 else { break }
            for index in 0..<read where buffer[index] == 0x0a {
                count += 1
            }
            lastByte = buffer[read - 1]
        }
        if lastByte != 0x0a { count += 1 }
        return count
    }

}

enum AtriaHistoricalGravity {
    static func decode(payload: [UInt8], version: Int? = nil) -> (x: Double, y: Double, z: Double, magnitude: Double, validated: Bool)? {
        HistoricalArchive.historicalGravity(payload)
    }
}
