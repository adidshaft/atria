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
    /// Every recovered-cache mutation advances this generation. A publishing
    /// authority receives the exact generation plus an unforgeable per-install
    /// tag, so a late revocation can roll back only its own cache image without
    /// deleting a newer publisher's replacement.
    private struct RecoveredDataCacheInstallOwnership: Equatable {
        let generation: UInt64
        let authorityTag: UUID
    }
    private static var recoveredDataCacheMutationGeneration: UInt64 = 0
    private static var recoveredDataCacheInstallOwnership:
        RecoveredDataCacheInstallOwnership?
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
            recoveredEpochsCancellable(
                windows: windows,
                shouldContinue: { true }
            ) ?? [:]
        }

        func recoveredEpochsCancellable(
            windows: [AtriaRecoveredMotionProjection.Window],
            shouldContinue: () -> Bool
        ) -> [String: [AtriaRecoveredMotionEpoch]]? {
            guard completeness == .complete else { return [:] }
            var projectedSamples: [AtriaRecoveredMotionProjection.Sample] = []
            projectedSamples.reserveCapacity(samples.count)
            for (index, sample) in samples.enumerated() {
                if index.isMultiple(of: 256), !shouldContinue() {
                    return nil
                }
                projectedSamples.append(.init(
                    timestamp: Date(timeIntervalSince1970: sample.timestamp),
                    sequence: sample.sequence,
                    x: sample.x,
                    y: sample.y,
                    z: sample.z,
                    timestampValidated: sample.timestampValidated,
                    gravityValidated: sample.validated
                ))
            }
            return AtriaRecoveredMotionProjection.epochFeaturesCancellable(
                samples: projectedSamples,
                windows: windows,
                shouldContinue: shouldContinue
            )
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
            maximumRRRecords: 1_000_000,
            maximumSkinTemperaturePoints: 1_500_000,
            maximumGravitySamples: 750_000,
            maximumMotionReplayIdentities: 750_000
        )

        /// Ordinary current-cycle freshness is intentionally much smaller than
        /// exact/manual or leased BGProcessing projection. The paired bootstrap
        /// checkpoint uses the same bounds, so crossing one never installs a
        /// partial automatic cache or silently widens a later foreground pass.
        static let automaticForeground = RecoveredProjectionBudget(
            maximumHeartRatePoints: 200_000,
            maximumRRRecords: 200_000,
            maximumSkinTemperaturePoints: 200_000,
            maximumGravitySamples: 200_000,
            maximumMotionReplayIdentities: 200_000
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

    /// Cache compatibility is deliberately directional. A completed automatic
    /// bootstrap is a full source image proven under stricter channel and
    /// aggregate caps, so a production BG continuation may consume it without
    /// rescanning. The reverse would let an ordinary automatic request inherit
    /// a production-sized image and bypass its decoded-work admission contract.
    nonisolated static func recoveredProjectionCacheBudgetIsReusable(
        cached: RecoveredProjectionBudget,
        requested: RecoveredProjectionBudget,
        hasTruncatedChannels: Bool
    ) -> Bool {
        if cached == requested { return true }
        return cached == .automaticForeground
            && requested == .production
            && !hasTruncatedChannels
    }

    struct RecoveredDecodedWorkBudget: Equatable, Sendable {
        static let automaticForeground = RecoveredDecodedWorkBudget(
            maximumDecodedRecords: 250_000,
            maximumCandidateLines: 250_000,
            maximumRetainedChannelElements: 200_000,
            maximumRetainedAggregateElements: 250_000
        )

        let maximumDecodedRecords: Int
        let maximumCandidateLines: Int
        let maximumRetainedChannelElements: Int
        let maximumRetainedAggregateElements: Int

        func admitsRetainedCounts(
            heartRate: Int,
            rr: Int,
            skin: Int,
            gravity: Int,
            motionIdentities: Int
        ) -> Bool {
            let counts = [heartRate, rr, skin, gravity, motionIdentities]
            guard counts.allSatisfy({
                $0 >= 0 && $0 <= maximumRetainedChannelElements
            }) else { return false }
            var aggregate = 0
            for count in counts {
                let addition = aggregate.addingReportingOverflow(count)
                guard !addition.overflow,
                      addition.partialValue
                        <= maximumRetainedAggregateElements else {
                    return false
                }
                aggregate = addition.partialValue
            }
            return true
        }
    }

    private struct AutomaticRecoveredDataBootstrapRetainedCounts {
        let heartRate: Int
        let rr: Int
        let skin: Int
        let gravity: Int
    }

    /// The bootstrap retains four compact evidence channels and deliberately no
    /// motion identities. Per-channel limits remain owned by the bootstrap
    /// projection budget; the independent 250,000-element automatic aggregate
    /// contract is shared with ordinary current-cycle work. This check walks no
    /// evidence and is therefore O(1) at every durable/publication boundary.
    private static func automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
        _ counts: AutomaticRecoveredDataBootstrapRetainedCounts
    ) -> Bool {
        guard counts.heartRate >= 0,
              counts.heartRate
                <= automaticRecoveredDataBootstrapBudget.maximumHeartRatePoints,
              counts.rr >= 0,
              counts.rr
                <= automaticRecoveredDataBootstrapBudget.maximumRRRecords,
              counts.skin >= 0,
              counts.skin
                <= automaticRecoveredDataBootstrapBudget
                    .maximumSkinTemperaturePoints,
              counts.gravity >= 0,
              counts.gravity
                <= automaticRecoveredDataBootstrapBudget.maximumGravitySamples
        else { return false }
        return RecoveredDecodedWorkBudget.automaticForeground
            .admitsRetainedCounts(
                heartRate: counts.heartRate,
                rr: counts.rr,
                skin: counts.skin,
                gravity: counts.gravity,
                motionIdentities: 0
            )
    }

    private static func automaticRecoveredDataBootstrapRetainedCounts(
        heartRate: [HeartRatePoint],
        rrAccumulator: AtriaRecoveredRRProjection.Accumulator,
        skin: [SkinTemperatureRawPoint],
        gravity: [GravitySample]
    ) -> AutomaticRecoveredDataBootstrapRetainedCounts {
        .init(
            heartRate: heartRate.count,
            rr: rrAccumulator.acceptedRecordCount,
            skin: skin.count,
            gravity: gravity.count
        )
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
        /// Verified RR beats, projected AT SCAN TIME (2026-08-04 footprint
        /// fix). The scan used to retain whole `Record`s here (~1KB each) for
        /// a later `project(records:)` pass; verification now happens per
        /// record during the scan and only the compact accepted form is kept.
        let rrProjection: AtriaRecoveredRRProjection.Result
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
        /// Complete-line scanner authority captured from the exact cache image
        /// that produced this snapshot. SessionStore persists this alongside
        /// its bounded current-cycle projection so a later process can decode
        /// an append-only tail without advancing past rows the UI never saw.
        let automaticCacheAuthority: AutomaticRecoveredDataCacheAuthority?
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

    struct HeartRatePoint: Codable, Equatable, Sendable {
        let t: Date
        let bpm: Int
    }

    struct SkinTemperatureRawPoint: Codable, Equatable, Sendable {
        let t: Date
        let raw: Int
        let strapIdentifier: String?
    }

    struct HeartRateWindowRead: Equatable, Sendable {
        let points: [HeartRatePoint]
        let scannedFileCount: Int
        let scannedByteCount: Int
    }

    /// Bounded attribution receipt for one exact-window HR lookup (handoff-8
    /// CP1): which candidates existed, how many the sealed-catalog identity
    /// proof excluded, and what the scan actually touched. Persisted as a
    /// short diagnostic ring — request metadata only, never health samples.
    struct HeartRateWindowReadDiagnostics: Codable, Equatable, Sendable {
        var startUnix: Double
        var endUnix: Double
        var elapsedMilliseconds: Int
        var candidateFileCount: Int
        var trustedOutsideWindowSkipped: Int
        var selectedFileCount: Int
        var scannedFileCount: Int
        var scannedByteCount: Int
        var scannedLineCount: Int
        var heartRateCandidateLineCount: Int
        var inWindowPointCount: Int
        var catalogGeneration: UInt64
        var catalogChunkCount: Int
        var terminal: String

        static let ringKey = "atria.debug.hrWindowReadReceipts.v1"
        private static let ringLimit = 12

        func persistToRing(defaults: UserDefaults = .standard) {
            guard let encoded = try? JSONEncoder().encode(self),
                  let line = String(data: encoded, encoding: .utf8) else { return }
            var lines = (defaults.string(forKey: Self.ringKey) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            lines.append(line)
            if lines.count > Self.ringLimit {
                lines.removeFirst(lines.count - Self.ringLimit)
            }
            defaults.set(lines.joined(separator: "\n"), forKey: Self.ringKey)
        }
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

    /// Compact cross-process authority for the automatic recovered-data lane.
    /// It persists only verified complete-line offsets and source identity; the
    /// bounded UI checkpoint remains the base projection. On relaunch, this lets
    /// an unchanged source reuse that checkpoint or an append-only <=8 MiB tail
    /// decode only the new bytes without serializing the large in-memory cache.
    struct AutomaticRecoveredDataCacheAuthority: Codable, Equatable, Sendable {
        static let schema = 1

        struct Source: Codable, Equatable, Sendable {
            let path: String
            let processedOffset: UInt64
            let modificationTime: TimeInterval
            let resourceIdentifier: String
        }

        let version: Int
        let coveredSince: TimeInterval
        let sources: [Source]
    }

    enum AutomaticRecoveredDataBootstrapStepResult: Equatable, Sendable {
        case progressed(readBytes: Int, remainingBytes: UInt64)
        case ready(readBytes: Int)
        case deferred(reason: String)
        case invalidated(reason: String)
    }

    private struct AutomaticRecoveredDataBootstrapSourceImage {
        let catalogGeneration: UInt64?
        let descriptors: [AtriaHistoricalJSONLRecentScanner.FileDescriptor]
    }

    /// Durable, bounded partial projection for a first-install/upgrade whose
    /// current-window raw image is larger than one automatic 8 MiB pass.
    /// Complete-line cursors and compact metric accumulators are one atomic
    /// property-list generation; no cursor can advance without the evidence it
    /// decoded being present in the same file.
    private struct AutomaticRecoveredDataBootstrapCheckpoint: Codable {
        static let schema = 1

        struct Source: Codable, Equatable {
            let path: String
            var targetSize: UInt64
            var processedOffset: UInt64
            var modificationTime: TimeInterval
            let resourceIdentifier: String
        }

        let version: Int
        var cutoff: TimeInterval
        var updatedAt: TimeInterval
        var sourceFingerprint: ConsumerSourceFingerprint
        var sources: [Source]
        var heartRatePoints: [HeartRatePoint]
        var rrAccumulator: AtriaRecoveredRRProjection.Accumulator
        var skinTemperatureRawPoints: [SkinTemperatureRawPoint]
        var gravitySamples: [GravitySample]

        private enum CodingKeys: String, CodingKey {
            case version
            case cutoff
            case updatedAt
            case sourceFingerprint
            case sources
            case heartRatePoints
            case rrAccumulator
            case skinTemperatureRawPoints
            case gravitySamples
        }

        init(
            version: Int,
            cutoff: TimeInterval,
            updatedAt: TimeInterval,
            sourceFingerprint: ConsumerSourceFingerprint,
            sources: [Source],
            heartRatePoints: [HeartRatePoint],
            rrAccumulator: AtriaRecoveredRRProjection.Accumulator,
            skinTemperatureRawPoints: [SkinTemperatureRawPoint],
            gravitySamples: [GravitySample]
        ) {
            self.version = version
            self.cutoff = cutoff
            self.updatedAt = updatedAt
            self.sourceFingerprint = sourceFingerprint
            self.sources = sources
            self.heartRatePoints = heartRatePoints
            self.rrAccumulator = rrAccumulator
            self.skinTemperatureRawPoints = skinTemperatureRawPoints
            self.gravitySamples = gravitySamples
        }

        init(from decoder: Decoder) throws {
            let authority = decoder.userInfo[
                .atriaRecoveredCheckpointCodingAuthority
            ] as? AtriaRecoveredCheckpointCodingAuthority
            try authority?.checkpoint(
                stage: "checkpoint_decode_header",
                index: 0
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            cutoff = try container.decode(
                TimeInterval.self,
                forKey: .cutoff
            )
            updatedAt = try container.decode(
                TimeInterval.self,
                forKey: .updatedAt
            )
            sourceFingerprint = try container.decode(
                ConsumerSourceFingerprint.self,
                forKey: .sourceFingerprint
            )

            var sourceContainer = try container.nestedUnkeyedContainer(
                forKey: .sources
            )
            var decodedSources: [Source] = []
            if let count = sourceContainer.count {
                guard count <= HistoricalArchive
                    .maximumAutomaticRecoveredDataCacheAuthoritySourceCount
                else {
                    throw AtriaRecoveredCheckpointCodingError
                        .containerLimitExceeded
                }
                decodedSources.reserveCapacity(count)
            }
            while !sourceContainer.isAtEnd {
                let index = decodedSources.count
                guard index < HistoricalArchive
                    .maximumAutomaticRecoveredDataCacheAuthoritySourceCount
                else {
                    throw AtriaRecoveredCheckpointCodingError
                        .containerLimitExceeded
                }
                if index.isMultiple(of: 16) {
                    try authority?.checkpoint(
                        stage: "checkpoint_decode_sources",
                        index: index
                    )
                }
                decodedSources.append(try sourceContainer.decode(Source.self))
            }
            sources = decodedSources

            var heartRateContainer = try container.nestedUnkeyedContainer(
                forKey: .heartRatePoints
            )
            var decodedHeartRate: [HeartRatePoint] = []
            if let count = heartRateContainer.count {
                guard count <= HistoricalArchive
                    .automaticRecoveredDataBootstrapBudget
                    .maximumHeartRatePoints else {
                    throw AtriaRecoveredCheckpointCodingError
                        .containerLimitExceeded
                }
                decodedHeartRate.reserveCapacity(count)
            }
            while !heartRateContainer.isAtEnd {
                let index = decodedHeartRate.count
                guard index < HistoricalArchive
                    .automaticRecoveredDataBootstrapBudget
                    .maximumHeartRatePoints else {
                    throw AtriaRecoveredCheckpointCodingError
                        .containerLimitExceeded
                }
                if index.isMultiple(of: 256) {
                    try authority?.checkpoint(
                        stage: "checkpoint_decode_heart_rate",
                        index: index
                    )
                }
                decodedHeartRate.append(try heartRateContainer.decode(
                    HeartRatePoint.self
                ))
            }
            heartRatePoints = decodedHeartRate
            rrAccumulator = try container.decode(
                AtriaRecoveredRRProjection.Accumulator.self,
                forKey: .rrAccumulator
            )
            guard HistoricalArchive
                .automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
                    .init(
                        heartRate: decodedHeartRate.count,
                        rr: rrAccumulator.acceptedRecordCount,
                        skin: 0,
                        gravity: 0
                    )
                ) else {
                throw AtriaRecoveredCheckpointCodingError
                    .containerLimitExceeded
            }

            var skinContainer = try container.nestedUnkeyedContainer(
                forKey: .skinTemperatureRawPoints
            )
            var decodedSkin: [SkinTemperatureRawPoint] = []
            if let count = skinContainer.count {
                guard count <= HistoricalArchive
                    .automaticRecoveredDataBootstrapBudget
                    .maximumSkinTemperaturePoints else {
                    throw AtriaRecoveredCheckpointCodingError
                        .containerLimitExceeded
                }
                decodedSkin.reserveCapacity(count)
            }
            while !skinContainer.isAtEnd {
                let index = decodedSkin.count
                guard index < HistoricalArchive
                    .automaticRecoveredDataBootstrapBudget
                    .maximumSkinTemperaturePoints else {
                    throw AtriaRecoveredCheckpointCodingError
                        .containerLimitExceeded
                }
                if index.isMultiple(of: 256) {
                    try authority?.checkpoint(
                        stage: "checkpoint_decode_skin",
                        index: index
                    )
                }
                decodedSkin.append(try skinContainer.decode(
                    SkinTemperatureRawPoint.self
                ))
            }
            skinTemperatureRawPoints = decodedSkin
            guard HistoricalArchive
                .automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
                    .init(
                        heartRate: decodedHeartRate.count,
                        rr: rrAccumulator.acceptedRecordCount,
                        skin: decodedSkin.count,
                        gravity: 0
                    )
                ) else {
                throw AtriaRecoveredCheckpointCodingError
                    .containerLimitExceeded
            }

            var gravityContainer = try container.nestedUnkeyedContainer(
                forKey: .gravitySamples
            )
            var decodedGravity: [GravitySample] = []
            if let count = gravityContainer.count {
                guard count <= HistoricalArchive
                    .automaticRecoveredDataBootstrapBudget
                    .maximumGravitySamples else {
                    throw AtriaRecoveredCheckpointCodingError
                        .containerLimitExceeded
                }
                decodedGravity.reserveCapacity(count)
            }
            while !gravityContainer.isAtEnd {
                let index = decodedGravity.count
                guard index < HistoricalArchive
                    .automaticRecoveredDataBootstrapBudget
                    .maximumGravitySamples else {
                    throw AtriaRecoveredCheckpointCodingError
                        .containerLimitExceeded
                }
                if index.isMultiple(of: 256) {
                    try authority?.checkpoint(
                        stage: "checkpoint_decode_gravity",
                        index: index
                    )
                }
                decodedGravity.append(try gravityContainer.decode(
                    GravitySample.self
                ))
            }
            gravitySamples = decodedGravity
            guard HistoricalArchive
                .automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
                    .init(
                        heartRate: decodedHeartRate.count,
                        rr: rrAccumulator.acceptedRecordCount,
                        skin: decodedSkin.count,
                        gravity: decodedGravity.count
                    )
                ) else {
                throw AtriaRecoveredCheckpointCodingError
                    .containerLimitExceeded
            }
            try authority?.checkpoint(
                stage: "checkpoint_decode_complete",
                index: decodedHeartRate.count + decodedSkin.count
                    + decodedGravity.count
            )
        }

        func encode(to encoder: Encoder) throws {
            let authority = encoder.userInfo[
                .atriaRecoveredCheckpointCodingAuthority
            ] as? AtriaRecoveredCheckpointCodingAuthority
            guard HistoricalArchive
                .automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
                    HistoricalArchive
                        .automaticRecoveredDataBootstrapRetainedCounts(
                            heartRate: heartRatePoints,
                            rrAccumulator: rrAccumulator,
                            skin: skinTemperatureRawPoints,
                            gravity: gravitySamples
                        )
                ) else {
                throw AtriaRecoveredCheckpointCodingError
                    .containerLimitExceeded
            }
            try authority?.checkpoint(
                stage: "checkpoint_encode_header",
                index: 0
            )
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(cutoff, forKey: .cutoff)
            try container.encode(updatedAt, forKey: .updatedAt)
            try container.encode(
                sourceFingerprint,
                forKey: .sourceFingerprint
            )

            var sourceContainer = container.nestedUnkeyedContainer(
                forKey: .sources
            )
            for (index, source) in sources.enumerated() {
                if index.isMultiple(of: 16) {
                    try authority?.checkpoint(
                        stage: "checkpoint_encode_sources",
                        index: index
                    )
                }
                try sourceContainer.encode(source)
            }

            var heartRateContainer = container.nestedUnkeyedContainer(
                forKey: .heartRatePoints
            )
            for (index, point) in heartRatePoints.enumerated() {
                if index.isMultiple(of: 256) {
                    try authority?.checkpoint(
                        stage: "checkpoint_encode_heart_rate",
                        index: index
                    )
                }
                try heartRateContainer.encode(point)
            }
            try container.encode(rrAccumulator, forKey: .rrAccumulator)

            var skinContainer = container.nestedUnkeyedContainer(
                forKey: .skinTemperatureRawPoints
            )
            for (index, point) in skinTemperatureRawPoints.enumerated() {
                if index.isMultiple(of: 256) {
                    try authority?.checkpoint(
                        stage: "checkpoint_encode_skin",
                        index: index
                    )
                }
                try skinContainer.encode(point)
            }

            var gravityContainer = container.nestedUnkeyedContainer(
                forKey: .gravitySamples
            )
            for (index, sample) in gravitySamples.enumerated() {
                if index.isMultiple(of: 256) {
                    try authority?.checkpoint(
                        stage: "checkpoint_encode_gravity",
                        index: index
                    )
                }
                try gravityContainer.encode(sample)
            }
            try authority?.checkpoint(
                stage: "checkpoint_encode_complete",
                index: heartRatePoints.count
                    + rrAccumulator.acceptedRecordCount
                    + skinTemperatureRawPoints.count
                    + gravitySamples.count
            )
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

    /// Hard admission envelope for the one-time pre-compact v24 migration.
    /// Compressed inputs are rejected because their expanded read cost is not
    /// bounded by the descriptor's physical byte count.
    struct MotionTickDayEvidenceMigrationBudget: Equatable, Sendable {
        let maximumFileCount: Int
        let maximumTotalBytes: UInt64
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
        case maintenanceAuthorityRevoked
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
        // Handoff-9 CP1: durable history appends intentionally bypass
        // `appendJSONLine`, so chunks sealed by drain-driven rotation would
        // otherwise wait for the next launch backfill. Every lock is released
        // here; hand any freshly sealed chunks to the coalesced utility
        // sidecar builder (best-effort, per durable batch — never per frame).
        scheduleHeartRateSidecarBuildsForFreshlySealedChunks()
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
        // Handoff-9 CP1: the catalog lock is released; hand the freshly sealed
        // chunk to the coalesced utility sidecar builder (best-effort).
        scheduleHeartRateSidecarBuildsForFreshlySealedChunks()
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

    /// A read-only cap-pressure probe for guarded background maintenance.
    /// It deliberately has no compaction or deletion authority: its sole job is
    /// to avoid a once-daily lease leaving an already-over-cap archive idle for
    /// almost a full day while live capture continues to append.
    static func highVolumeMaintenancePressure(
        shouldContinue: () -> Bool = { true }
    ) -> AtriaHistoricalHighVolumeDiagnosticsCoordinator.Report? {
        do {
            guard shouldContinue() else { return nil }
            // The diagnostics coordinator already enumerates exact file sizes,
            // rejects missing catalog sources, symlinks and partial trees, and
            // owns no mutation API. Re-hashing every sealed raw chunk here made
            // this advisory lease check a 2-GB / ~50-second scan before it could
            // even decide that no compaction was needed.
            let catalog = try catalogStoreLocked().snapshot()
            return try AtriaHistoricalHighVolumeDiagnosticsCoordinator.evaluate(
                archiveRoot: archiveDirectory,
                catalog: catalog,
                shouldContinue: shouldContinue
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

    /// The single aggregate-vs-catalog consistency truth. A committed
    /// aggregate source and a catalog chunk describe the same immutable raw
    /// payload only when this exact 5-tuple holds: content digest, logical
    /// byte count, row count, and both time bounds at the catalog's persisted
    /// whole-second precision. `byteCount` must always be the logical decoded
    /// JSONL byte count — never `compressedStorage.storedByteCount` — because
    /// aggregate identity is the canonical decoded stream, not the physical
    /// artifact. Both enforcement sites (the proof factory's per-aggregate
    /// guard and the sealed-catalog materializer's completeness check) must
    /// call this predicate so detection and repair can never disagree about
    /// what "consistent" means.
    static func aggregateSourceMatchesCatalogChunk(
        rawSHA256: String,
        byteCount: UInt64,
        rowCount: Int,
        firstTimestamp: Date,
        lastTimestamp: Date,
        chunk: AtriaHistoricalArchiveCatalog.RawChunk
    ) -> Bool {
        chunk.contentSHA256 == rawSHA256
            && chunk.byteCount == byteCount
            && chunk.rowCount == rowCount
            && catalogTimestampMatches(raw: firstTimestamp,
                                       catalog: chunk.firstTimestamp)
            && catalogTimestampMatches(raw: lastTimestamp,
                                       catalog: chunk.lastTimestamp)
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
        // No whole-archive `.load()` here: the coordinator streams the
        // whole-archive digest and window-loads each source's dependency
        // range itself, so this foreground-reopen path (the one that used to
        // balloon resident memory to the whole committed archive) never holds
        // more than one decoded aggregate at a time.
        let aggregateReader = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        )
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
            aggregateReader: aggregateReader,
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

        // Bounded (was a whole-archive .load()): the whole-archive digest and
        // rejection state come from the streaming primitive (one decoded
        // aggregate resident at a time), and the just-committed seal aggregate
        // is verified byte-identical via a windowed load of its own range.
        let aggregateReader = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        )
        guard let streamedAggregate = aggregateReader.streamedWholeArchiveDigest(
            limits: AtriaHistoricalAggregateReader.LoadLimits.unboundedConsumerProjection
        ) else {
            throw TerminalConsumerProjectionError.committedAggregateUnavailable
        }
        let catalogStore = try catalogStoreLocked()
        let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
        try catalog.validate()
        let catalogData = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalCatalogData(catalog)
        let catalogSnapshotSHA256 =
            AtriaHistoricalDrainCompletionGenerationStore.sha256(catalogData)
        let aggregateSnapshotSHA256 = streamedAggregate.digest
        let persistedAggregate = try persistedISO8601Value(
            seal.aggregateBuild.aggregate
        )
        let sealSource = seal.aggregateBuild.aggregate.source
        let sealWindow = aggregateReader.load(
            since: sealSource.firstTimestamp,
            until: Date(timeIntervalSinceReferenceDate:
                sealSource.lastTimestamp.timeIntervalSinceReferenceDate.nextUp)
        )
        guard streamedAggregate.diagnostics.rejectedManifests == 0,
              sealWindow.aggregates.contains(where: {
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
        // Reusing the canonical catalog encoding and the streamed aggregate
        // digest avoids a second file re-stat and whole-snapshot encode; the
        // persisted digest bytes are identical.
        let completion = try completionStore.recordTerminal(
            generation: generation,
            terminalBatchNumber: terminalBatchNumber,
            durableSequence: durableSequence,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completedAt: completedAt,
            verifiedCatalog: catalog,
            catalogData: catalogData,
            aggregateSnapshotDigest: aggregateSnapshotSHA256
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
        let sealedIdentity = terminalConsumerRetrySealedIdentity(
            from: catalog.chunks
        )
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

    /// Canonical, lightweight identity for the immutable portion of a catalog.
    /// Keep this deliberately imperative: the equivalent chained collection
    /// expression grows enough generic/closure inference that the release
    /// compiler can time out while type-checking it.
    private static func terminalConsumerRetrySealedIdentity(
        from chunks: [AtriaHistoricalArchiveCatalog.RawChunk]
    ) -> String {
        var sealedChunks = chunks.filter { $0.state == .sealed }
        sealedChunks.sort { lhs, rhs in
            lhs.id < rhs.id
        }

        var identities: [String] = []
        identities.reserveCapacity(sealedChunks.count)
        for chunk in sealedChunks {
            identities.append(terminalConsumerRetryChunkIdentity(chunk))
        }
        return identities.joined(separator: "|")
    }

    private static func terminalConsumerRetryChunkIdentity(
        _ chunk: AtriaHistoricalArchiveCatalog.RawChunk
    ) -> String {
        let firstTimestamp = terminalConsumerRetryTimestampIdentity(
            chunk.firstTimestamp
        )
        let lastTimestamp = terminalConsumerRetryTimestampIdentity(
            chunk.lastTimestamp
        )
        let rowCount = chunk.rowCount.map(String.init) ?? "unknown"

        return [
            chunk.id,
            chunk.contentSHA256 ?? "missing",
            String(chunk.byteCount),
            rowCount,
            firstTimestamp,
            lastTimestamp,
            chunk.compressedStorage?.storedSHA256 ?? "plain",
        ].joined(separator: ":")
    }

    private static func terminalConsumerRetryTimestampIdentity(
        _ timestamp: Date?
    ) -> String {
        guard let timestamp else { return "unknown" }
        return String(Int64((
            timestamp.timeIntervalSince1970 * 1_000
        ).rounded()))
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
        // Bounded (was a whole-archive .load()): this evidence needs only the
        // whole-archive digest, whole-archive rejection state, the matched
        // source IDENTITY (not its heavy sample arrays), and the minimum
        // committed firstTimestamp — all provided by the streaming primitive
        // (canonical order, one decoded aggregate resident at a time).
        guard let streamed = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        ).streamedWholeArchiveDigest(
            limits: AtriaHistoricalAggregateReader.LoadLimits.unboundedConsumerProjection
        ) else {
            throw TerminalConsumerProjectionError.committedAggregateUnavailable
        }
        let catalog = try catalogStoreLocked().snapshotVerifiedAgainstFiles()
        // The caller's `sourceRawSHA256` is deliberately not consulted for the
        // match below — see `resolveCommittedFullScanSource` for the honesty
        // trade this encodes. Every other gate (limit, rejected manifests,
        // chunk present in the file-verified catalog) is unchanged.
        guard !streamed.diagnostics.limitExceeded,
              streamed.diagnostics.rejectedManifests == 0,
              let source = resolveCommittedFullScanSource(
                  sourceChunkID: sourceChunkID,
                  catalog: catalog,
                  streamedSources: streamed.sources
              ) else {
            throw TerminalConsumerProjectionError.committedAggregateUnavailable
        }
        return .init(
            aggregateCommit: aggregateCommit,
            source: source,
            observedArchiveFirstTimestamp: streamed.sources.first?.firstTimestamp
                ?? source.firstTimestamp,
            catalogGeneration: catalog.generation,
            catalogSnapshotSHA256: AtriaHistoricalDrainCompletionGenerationStore.sha256(
                try AtriaHistoricalActivityInspectionProofFactory.canonicalCatalogData(catalog)
            ),
            aggregateSnapshotSHA256: streamed.digest
        )
    }

    /// Honesty trade (2026-08-05 crash-at-seal repair): the committed source
    /// is resolved by the FILE-VERIFIED catalog chunk's content digest, not by
    /// a caller-persisted `sourceRawSHA256`. After this, a full-scan record's
    /// source identity is catalog-derived rather than independent evidence —
    /// the catalog+file axis is already proven physically by
    /// `snapshotVerifiedAgainstFiles`, so a record carrying a pre-crash digest
    /// converts from a fail-closed disagreement into an auto-heal against that
    /// proven axis. Coverage facts (`cursorWatermark`, transport identity)
    /// remain independent evidence and are never derived here. A chunk absent
    /// from the catalog, or whose digest matches no accepted committed source,
    /// still resolves to nil and fails closed at the caller.
    static func resolveCommittedFullScanSource(
        sourceChunkID: String,
        catalog: AtriaHistoricalArchiveCatalog,
        streamedSources: [AtriaHistoricalAggregateChunk.Source]
    ) -> AtriaHistoricalAggregateChunk.Source? {
        guard let chunk = catalog.chunks.first(where: {
            $0.id == sourceChunkID
        }) else { return nil }
        return streamedSources.first(where: {
            $0.chunkID == sourceChunkID
                && $0.rawSHA256 == chunk.contentSHA256
        })
    }

    static func earliestCommittedAggregateTimestamp() -> Date? {
        // Bounded: `streamedWholeArchiveDigest` returns the accepted committed
        // sources in canonical (firstTimestamp asc, then chunkID) order while
        // holding only one decoded aggregate at a time — so `.sources.first`
        // is the exact minimum accepted firstTimestamp without decoding the
        // whole archive into one resident array (was the old
        // `.load().aggregates.map(...).min()` balloon). Accepted-only semantics
        // are preserved (a rejected/corrupt chunk must not lower the observed
        // archive coverage floor). nil (empty archive or a between-pass file
        // change) falls back at the call site.
        AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: archiveDirectory.appendingPathComponent(
                "aggregates-v2", isDirectory: true
            ),
            manifestDirectoryURL: archiveDirectory.appendingPathComponent(
                "retention-manifests-v2", isDirectory: true
            )
        ).streamedWholeArchiveDigest(
            limits: AtriaHistoricalAggregateReader.LoadLimits.unboundedConsumerProjection
        )?.sources.first?.firstTimestamp
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
        let aggregateReader = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        )
        // This crash-resume path runs on foreground reopen (invoked from the
        // BLE lifecycle), so it must never decode the whole committed archive
        // — that whole `.load()` was a primary reopen memory balloon. Stream
        // the whole-archive digest + diagnostics at bounded memory (peak: one
        // decoded aggregate), then window-load only the target chunk's own
        // range to re-verify its aggregate against the retained raw source.
        guard let streamed = aggregateReader.streamedWholeArchiveDigest(
                limits: .unboundedConsumerProjection),
              !streamed.diagnostics.limitExceeded,
              streamed.diagnostics.rejectedManifests == 0 else {
            throw TerminalConsumerProjectionError.resumeAggregateUnavailable
        }
        let targetWindow = aggregateReader.load(
            since: chunk.firstTimestamp!,
            until: Date(timeIntervalSinceReferenceDate:
                chunk.lastTimestamp!.timeIntervalSinceReferenceDate.nextUp),
            limits: AtriaHistoricalAggregateReader.LoadLimits.unboundedConsumerProjection
        )
        guard !targetWindow.diagnostics.limitExceeded,
              let aggregate = targetWindow.aggregates.first(where: {
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
        // Byte-identical to hashing the whole decoded snapshot, computed at
        // bounded memory above (see `streamedWholeArchiveDigest`).
        let aggregateSnapshotDigest = streamed.digest
        guard completion.terminalBatchNumber == job.terminalBatchNumber,
              completion.durableSequence == job.durableSequence,
              completion.requestedStart == job.exactRequest.requestedStart,
              completion.requestedEnd == job.exactRequest.requestedEnd,
              completion.completedAt == job.completedAt,
              completion.catalogGeneration == catalog.generation,
              completion.catalogSnapshotSHA256
                == AtriaHistoricalDrainCompletionGenerationStore.sha256(catalogData),
              completion.aggregateSnapshotSHA256 == aggregateSnapshotDigest else {
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
        // re-stat/re-encode once per source inside the coordinator loop. The
        // whole-archive aggregate-snapshot digest is streamed fresh from
        // `aggregateReader` inside the coordinator at bounded memory; it is
        // byte-identical to `aggregateSnapshotDigest` computed above.
        let consumers = try coordinator.publishEligibleReceipts(
            verifiedCatalog: catalog,
            catalogData: catalogData,
            aggregateReader: aggregateReader,
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
        // Bounded (was a whole-archive .load(); this path runs on foreground
        // reopen): whole-archive digest + rejection state come from the
        // streaming primitive, and the target chunk's aggregate is verified
        // via a windowed load of its own range.
        let aggregateReader = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: archiveDirectory.appendingPathComponent(
                "aggregates-v2", isDirectory: true
            ),
            manifestDirectoryURL: archiveDirectory.appendingPathComponent(
                "retention-manifests-v2", isDirectory: true
            )
        )
        guard let streamedAggregate = aggregateReader.streamedWholeArchiveDigest(
                limits: AtriaHistoricalAggregateReader.LoadLimits.unboundedConsumerProjection
              ),
              !streamedAggregate.diagnostics.limitExceeded,
              streamedAggregate.diagnostics.rejectedManifests == 0 else {
            throw TerminalConsumerProjectionError.resumeAggregateUnavailable
        }
        let targetWindow = aggregateReader.load(
            since: chunk.firstTimestamp!,
            until: Date(timeIntervalSinceReferenceDate:
                chunk.lastTimestamp!.timeIntervalSinceReferenceDate.nextUp)
        )
        guard let aggregate = targetWindow.aggregates.first(where: {
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
        let aggregateSnapshotDigest = streamedAggregate.digest
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
              completion.aggregateSnapshotSHA256 == aggregateSnapshotDigest else {
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
            aggregateReader: aggregateReader,
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
        // Bounded (was a whole-archive .load()): the coordinator streams the
        // digest once and window-loads only this dependency's range.
        let aggregateReader = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: archiveDirectory.appendingPathComponent(
                "aggregates-v2", isDirectory: true
            ),
            manifestDirectoryURL: archiveDirectory.appendingPathComponent(
                "retention-manifests-v2", isDirectory: true
            )
        )
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
            aggregateReader: aggregateReader,
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
        receiptLedger injectedLedger: AtriaHistoricalConsumerReceiptLedger? = nil,
        shouldContinue: () -> Bool = { true }
    ) throws -> HistoricalConsumerCutoverResult {
        func requireMaintenanceAuthority() throws {
            guard shouldContinue() else {
                throw HistoricalConsumerCutoverError
                    .maintenanceAuthorityRevoked
            }
        }
        try requireMaintenanceAuthority()
        let aggregates = archiveRoot.appendingPathComponent("aggregates-v2", isDirectory: true)
        let manifests = archiveRoot.appendingPathComponent(
            "retention-manifests-v2",
            isDirectory: true
        )
        let aggregateReader = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        )
        // Bounded (was a whole-archive .load()): the catalog gives the target
        // chunk's exact range up front, so the aggregate is found via a windowed
        // load of that range instead of decoding the whole archive. This cutover
        // path runs during foreground compaction.
        let catalog = try catalogStore.snapshotVerifiedAgainstFiles(
            shouldContinue: shouldContinue
        )
        guard let rawChunk = catalog.chunks.first(where: { $0.id == chunkID }),
              let chunkFirst = rawChunk.firstTimestamp,
              let chunkLast = rawChunk.lastTimestamp else {
            throw HistoricalConsumerCutoverError.committedShadowUnavailable
        }
        let chunkWindowEnd = Date(timeIntervalSinceReferenceDate:
            chunkLast.timeIntervalSinceReferenceDate.nextUp)
        try requireMaintenanceAuthority()
        let snapshot = aggregateReader.load(since: chunkFirst, until: chunkWindowEnd)
        let matchingAggregates = snapshot.aggregates.filter { $0.source.chunkID == chunkID }
        guard !snapshot.diagnostics.limitExceeded,
              snapshot.diagnostics.rejectedManifests == 0,
              matchingAggregates.count == 1,
              let aggregate = matchingAggregates.first else {
            throw HistoricalConsumerCutoverError.committedShadowUnavailable
        }

        guard rawChunk.state == .sealed,
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
        try requireMaintenanceAuthority()
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
        try requireMaintenanceAuthority()
        let report = try AtriaHistoricalConsumerProjectionCoordinator(
            completionStore: completionStore,
            receiptLedger: ledger
        ).publishReceiptSet(
            for: chunkID,
            verifiedCatalog: catalog,
            catalogData: try AtriaHistoricalActivityInspectionProofFactory
                .canonicalCatalogData(catalog),
            aggregateReader: aggregateReader,
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

        try requireMaintenanceAuthority()
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
        try requireMaintenanceAuthority()
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
        try requireMaintenanceAuthority()
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
        try requireMaintenanceAuthority()
        let canonicalApplied = try canonicalAdapter.apply(
            identity: canonicalIdentity,
            artifacts: canonicalArtifacts,
            appliedAt: Date()
        )
        try requireMaintenanceAuthority()
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
        // Bounded re-verify: window to the same target-chunk range as the
        // opening load; the mutation check (`finalMatches.first == aggregate`)
        // and windowed rejection state detect any change to this chunk during
        // publication.
        try requireMaintenanceAuthority()
        let finalSnapshot = aggregateReader.load(since: chunkFirst, until: chunkWindowEnd)
        let finalMatches = finalSnapshot.aggregates.filter { $0.source.chunkID == chunkID }
        let finalCatalog = try catalogStore.snapshotVerifiedAgainstFiles(
            shouldContinue: shouldContinue
        )
        guard !finalSnapshot.diagnostics.limitExceeded,
              finalSnapshot.diagnostics.rejectedManifests == 0,
              finalMatches.count == 1,
              finalMatches.first == aggregate,
              finalCatalog.chunks.first(where: { $0.id == chunkID }) == rawChunk,
              rawChunk.state == .sealed,
              FileManager.default.fileExists(atPath: rawURL.path),
              shouldContinue(),
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
        diagnostics(shouldContinue: { true })!
    }

    /// Exact recovered-pipeline form. Its caller supplies the ticket's
    /// cooperative authority, so a BG lease duty-cycles inside file/segment
    /// walks and a foreground token can stop them at the next bounded stride.
    static func diagnostics(
        shouldContinue: () -> Bool
    ) -> Diagnostics? {
        guard shouldContinue() else { return nil }
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
            var segmentIndexes: [DiagnosticsIndex] = []
            for (segmentOffset, segmentURL) in rotatedSegmentFileURLs()
                .filter({
                    $0.standardizedFileURL != url.standardizedFileURL
                }).enumerated() {
                if segmentOffset.isMultiple(of: 16), !shouldContinue() {
                    return nil
                }
                let segmentAttributes = archiveAttributes(for: segmentURL)
                if let segmentIndex = readDiagnosticsIndex(for: segmentURL, attributes: segmentAttributes) {
                    segmentIndexes.append(segmentIndex)
                    continue
                }
                guard segmentAttributes.byteCount <= 8 * 1024 * 1024,
                      let segmentIndex = scanDiagnosticsIndex(
                        for: segmentURL,
                        attributes: segmentAttributes,
                        shouldContinue: shouldContinue
                      ) else {
                    if !shouldContinue() { return nil }
                    continue
                }
                writeDiagnosticsIndex(segmentIndex, for: segmentURL)
                segmentIndexes.append(segmentIndex)
            }
            if !segmentIndexes.isEmpty {
                guard let aggregate = aggregateDiagnosticsIndex(
                    base: index,
                    segments: segmentIndexes,
                    shouldContinue: shouldContinue
                ) else { return nil }
                return diagnostics(from: aggregate, reason: "aggregate_index_ok")
            }
            return diagnostics(from: index, reason: index.rows > 0 ? "index_ok" : "empty_archive_index")
        }

        guard attributes.byteCount <= maxImmediateDiagnosticsScanBytes else {
            guard let probe = quickMetricReadinessProbe(
                shouldContinue: shouldContinue
            ) else { return nil }
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

        if let index = scanDiagnosticsIndex(
            for: url,
            attributes: attributes,
            shouldContinue: shouldContinue
        ) {
            writeDiagnosticsIndex(index, for: url)
            return diagnostics(from: index, reason: index.rows > 0 ? "scanned_index_written" : "empty_archive")
        } else {
            guard shouldContinue() else { return nil }
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
        quickMetricReadinessProbe(
            maxRows: maxRows,
            shouldContinue: { true }
        )!
    }

    private static func quickMetricReadinessProbe(
        maxRows: Int = 20_000,
        shouldContinue: () -> Bool
    ) -> MetricReadinessProbe? {
        guard shouldContinue() else { return nil }
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
            guard shouldContinue() else { return nil }
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
                if rowsScanned.isMultiple(of: 128), !shouldContinue() {
                    return nil
                }
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
            guard shouldContinue() else { return nil }
            rowsScanned += 1
            if let data = lineBuffer.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if metricUsable(object: object) { metricRows += 1 }
                if object["currentSessionUsable"] as? Bool == true { currentRows += 1 }
            }
        }

        guard shouldContinue() else { return nil }
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
            // Cheap byte-scan prefilter (2026-08-04 foreground-kill fix,
            // layer 2): fail-open chunks still put ~170MB of mostly
            // out-of-window rows through this closure, and a full
            // JSONSerialization parse per row was the dirty-page churn that
            // ballooned phys_footprint. The scanner's cutoff already floors
            // the range; enforce the ceiling too before any real parse.
            // Unparseable stamps fall through to the full parse (fail-open).
            if let stamp = AtriaHistoricalJSONLRecentScanner.timestamp(in: line),
               stamp > scanEnd.timeIntervalSince1970 {
                return
            }
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
    /// daily motion and an interrupted/overflowed scan. This read never mutates
    /// the compact store; legacy migration requires the separately budgeted
    /// maintenance facade below.
    static func motionTickDayEvidenceRead(
        start: Date,
        end: Date,
        bankCoverage: [DateInterval],
        strapIdentifier: String
    ) -> MotionTickDayEvidenceRead {
        motionTickDayEvidenceReadImpl(
            start: start,
            end: end,
            bankCoverage: bankCoverage,
            strapIdentifier: strapIdentifier,
            compactMigrationStore: nil,
            migrationBudget: nil
        )
    }

    /// The sole canonical-JSONL -> compact migration facade. Callers must mint
    /// a safe-background admission and provide explicit file/byte ceilings;
    /// any source set outside that envelope fails closed before opening a file.
    static func boundedLegacyMotionTickDayEvidenceMigrationRead(
        start: Date,
        end: Date,
        bankCoverage: [DateInterval],
        strapIdentifier: String,
        budget: MotionTickDayEvidenceMigrationBudget,
        compactMigrationStore: AtriaWhoop4MotionTickCompactStore
    ) -> MotionTickDayEvidenceRead {
        motionTickDayEvidenceReadImpl(
            start: start,
            end: end,
            bankCoverage: bankCoverage,
            strapIdentifier: strapIdentifier,
            compactMigrationStore: compactMigrationStore,
            migrationBudget: budget
        )
    }

    static func motionTickDayEvidenceMigrationSourcesFitBudget(
        _ descriptors: [AtriaHistoricalJSONLRecentScanner.FileDescriptor],
        budget: MotionTickDayEvidenceMigrationBudget
    ) -> Bool {
        guard budget.maximumFileCount > 0,
              budget.maximumTotalBytes > 0,
              descriptors.count <= budget.maximumFileCount else {
            return false
        }
        var total: UInt64 = 0
        for descriptor in descriptors {
            guard !descriptor.isCompressed,
                  total <= budget.maximumTotalBytes,
                  descriptor.size <= budget.maximumTotalBytes - total else {
                return false
            }
            total += descriptor.size
        }
        return total <= budget.maximumTotalBytes
    }

    private static func motionTickDayEvidenceReadImpl(
        start: Date,
        end: Date,
        bankCoverage: [DateInterval],
        strapIdentifier: String,
        compactMigrationStore: AtriaWhoop4MotionTickCompactStore?,
        migrationBudget: MotionTickDayEvidenceMigrationBudget?
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
        if compactMigrationStore != nil {
            guard let migrationBudget,
                  motionTickDayEvidenceMigrationSourcesFitBudget(
                    descriptors,
                    budget: migrationBudget
                  ) else {
                AtriaDebugLog(
                    "ATRIADBG whoop4_motion_compact status=canonical_migration_deferred reason=source_budget files=%d bytes=%llu",
                    descriptors.count,
                    descriptors.reduce(UInt64(0)) { partial, descriptor in
                        let (sum, overflow) = partial.addingReportingOverflow(
                            descriptor.size
                        )
                        return overflow ? UInt64.max : sum
                    }
                )
                return .incomplete
            }
        }
        typealias Point = AtriaWhoop4MotionTickSequenceReducer.Point
        typealias CadencePoint = AtriaWhoop4GravityCadenceStepModel.Point
        var rows: [String: (
            counter: Point,
            cadence: CadencePoint
        )] = [:]
        var clockOffsetByPayload: [String: Int] = [:]
        var clockResolutionByPayload:
            [String: MotionTickPayloadClockResolution] = [:]
        // Budgeted passes on dying threads (2026-08-05 climber fix): this
        // daily read previously ran ONE continuous budget-less scan on the
        // long-lived projection queue. Under the iOS 27 reclaim law that
        // stretch accumulated every line's transient parse garbage — on a
        // ~1GB backlogged archive it ballooned ~350MB/s to jetsam (the +65s
        // cold-launch climber, workflow-verified). Same driver pattern as the
        // recovered scan: resumable 32MB passes, each on a thread that dies.
        func consumeDayEvidenceLine(_ line: Data) {
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
        let dayScanCutoff = scanStart.addingTimeInterval(
            -(tolerance + maximumClockOffset)
        ).timeIntervalSince1970
        let passByteBudget = 32 * 1024 * 1024
        let maximumPasses = 256
        var remainingSources = descriptors.map {
            AtriaHistoricalJSONLRecentScanner.Source(descriptor: $0, startOffset: 0)
        }
        var mergedDayScanStates:
            [String: AtriaHistoricalJSONLRecentScanner.FileState] = [:]
        var dayScanComplete = true
        var dayScanPassIndex = 0
        while !remainingSources.isEmpty {
            dayScanPassIndex += 1
            var passResult = AtriaHistoricalJSONLRecentScanner.Result(
                states: [:],
                statistics: .init(),
                complete: false)
            let passDone = DispatchSemaphore(value: 0)
            let passSources = remainingSources
            let passThread = Thread {
                passResult = autoreleasepool {
                    AtriaHistoricalJSONLRecentScanner.scan(
                        sources: passSources,
                        cutoff: dayScanCutoff,
                        byteBudget: passByteBudget,
                        consumeCandidate: consumeDayEvidenceLine)
                }
                passDone.signal()
            }
            passThread.name = "atria.step-receipt-day.pass\(dayScanPassIndex)"
            passThread.qualityOfService = .utility
            passThread.start()
            passDone.wait()
            passResult.states.forEach { mergedDayScanStates[$0.key] = $0.value }
            if !passResult.exhaustedByteBudget {
                dayScanComplete = passResult.complete
                break
            }
            remainingSources = remainingSources.compactMap { source in
                guard let state = mergedDayScanStates[source.descriptor.path] else {
                    return source
                }
                guard !source.descriptor.isCompressed else { return nil }
                guard state.processedOffset < source.descriptor.size else {
                    return nil
                }
                return AtriaHistoricalJSONLRecentScanner.Source(
                    descriptor: source.descriptor,
                    startOffset: state.processedOffset)
            }
            guard dayScanPassIndex < maximumPasses else {
                dayScanComplete = false
                break
            }
        }
        guard dayScanComplete else { return .incomplete }
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

    /// Automatic foreground refreshes may reuse an already-materialized process
    /// cache or decode one demonstrably small append-only tail. A missing cache,
    /// source replacement/truncation/removal, or a larger tail is a rebuild-class
    /// request and belongs to SessionStore's power/thermal-guarded BGProcessing
    /// lane. Eight MiB is one quarter of the scanner's already-bounded pass size,
    /// keeping this freshness lane materially smaller than a full archive pass.
    static let maximumAutomaticRecoveredDataIncrementalBytes: UInt64 =
        8 * 1024 * 1024
    /// A current-cycle projection normally touches only the active chunk plus
    /// a handful of recently sealed chunks. Refuse an unexpectedly broad
    /// source image before either serializing authority or installing a cold
    /// cache; this bounds metadata, JSON size, and planner work independently
    /// of the byte ceiling.
    static let maximumAutomaticRecoveredDataCacheAuthoritySourceCount = 64
    private static let maximumAutomaticRecoveredDataCacheAuthorityWindow:
        TimeInterval = 6 * 24 * 60 * 60
    private static let maximumAutomaticRecoveredDataCacheAuthorityPathBytes =
        4_096
    private static let maximumAutomaticRecoveredDataCacheAuthorityIdentifierBytes =
        1_024
    private static let maximumAutomaticRecoveredDataBootstrapSourceBytes:
        UInt64 = 512 * 1024 * 1024
    private static let maximumAutomaticRecoveredDataBootstrapCheckpointBytes:
        UInt64 = 64 * 1024 * 1024
    private static let maximumAutomaticRecoveredDataBootstrapAge:
        TimeInterval = 6 * 24 * 60 * 60
    private static let automaticRecoveredDataBootstrapBudget =
        RecoveredProjectionBudget(
            maximumHeartRatePoints: 200_000,
            maximumRRRecords: 200_000,
            maximumSkinTemperaturePoints: 200_000,
            maximumGravitySamples: 200_000,
            maximumMotionReplayIdentities: 200_000
        )
    private static var automaticRecoveredDataBootstrapCheckpointURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("atria-projections", isDirectory: true)
        .appendingPathComponent(
            "recovered-current-bootstrap-v1.plist",
            isDirectory: false
        )
    }

    static func automaticRecoveredDataProjectionPlanIsBounded(
        _ plan: AtriaHistoricalJSONLRecentScanner.Plan,
        maximumIncrementalBytes: UInt64 =
            maximumAutomaticRecoveredDataIncrementalBytes,
        allowsBoundedRebuild: Bool = false
    ) -> Bool {
        let sources: [AtriaHistoricalJSONLRecentScanner.Source]
        switch plan {
        case .reuse:
            return true
        case .rebuild(let rebuildSources):
            guard allowsBoundedRebuild,
                  rebuildSources.allSatisfy({ $0.startOffset == 0 }) else {
                return false
            }
            sources = rebuildSources
        case .incremental(let incrementalSources):
            sources = incrementalSources
        }
        var total: UInt64 = 0
        for source in sources {
            // Compressed artifacts are all-or-nothing and their expanded byte
            // cost is not bounded by the on-disk descriptor. Stable filesystem
            // identity is required for both a first-install bounded seed and a
            // later append; path/size alone cannot fence replacement.
            guard source.descriptor.resourceIdentifier != nil,
                  !source.descriptor.isCompressed,
                  source.startOffset <= source.descriptor.size else {
                return false
            }
            let addition = source.descriptor.size - source.startOffset
            guard total <= maximumIncrementalBytes,
                  addition <= maximumIncrementalBytes - total else {
                return false
            }
            total += addition
        }
        return total <= maximumIncrementalBytes
    }

    /// Reconstructs the scanner plan represented by persisted complete-line
    /// offsets. The authority never supplies current EOF: descriptors are
    /// captured again, and only scanner-proven reuse or an uncompressed,
    /// stable-identity append totaling at most the caller's byte ceiling is
    /// accepted. This is pure so cold-process and race boundaries can be tested
    /// without opening an archive file.
    static func automaticRecoveredDataCacheAuthorityRestorationPlan(
        _ authority: AutomaticRecoveredDataCacheAuthority,
        since: Date,
        descriptors: [AtriaHistoricalJSONLRecentScanner.FileDescriptor],
        maximumIncrementalBytes: UInt64 =
            maximumAutomaticRecoveredDataIncrementalBytes
    ) -> AtriaHistoricalJSONLRecentScanner.Plan? {
        let cutoff = since.timeIntervalSince1970
        guard maximumIncrementalBytes > 0,
              cutoff.isFinite,
              authority.version == AutomaticRecoveredDataCacheAuthority.schema,
              authority.coveredSince.isFinite,
              authority.coveredSince <= cutoff,
              cutoff - authority.coveredSince
                <= maximumAutomaticRecoveredDataCacheAuthorityWindow,
              !authority.sources.isEmpty,
              authority.sources.count
                <= maximumAutomaticRecoveredDataCacheAuthoritySourceCount,
              !descriptors.isEmpty,
              descriptors.count
                <= maximumAutomaticRecoveredDataCacheAuthoritySourceCount else {
            return nil
        }

        var seenPaths = Set<String>()
        var seenIdentifiers = Set<String>()
        var states: [String: AtriaHistoricalJSONLRecentScanner.FileState] = [:]
        states.reserveCapacity(authority.sources.count)
        for source in authority.sources {
            let canonicalPath = URL(fileURLWithPath: source.path)
                .standardizedFileURL.path
            guard !source.path.isEmpty,
                  source.path.utf8.count
                    <= maximumAutomaticRecoveredDataCacheAuthorityPathBytes,
                  canonicalPath == source.path,
                  source.modificationTime.isFinite,
                  !source.resourceIdentifier.isEmpty,
                  source.resourceIdentifier.utf8.count
                    <= maximumAutomaticRecoveredDataCacheAuthorityIdentifierBytes,
                  seenPaths.insert(source.path).inserted,
                  seenIdentifiers.insert(source.resourceIdentifier).inserted else {
                return nil
            }
            states[source.path] = .init(
                path: source.path,
                processedOffset: source.processedOffset,
                modificationTime: source.modificationTime,
                resourceIdentifier: source.resourceIdentifier
            )
        }

        var currentPaths = Set<String>()
        for descriptor in descriptors {
            let canonicalPath = descriptor.url.standardizedFileURL.path
            guard canonicalPath == descriptor.path,
                  descriptor.modificationTime.isFinite,
                  currentPaths.insert(descriptor.path).inserted else {
                return nil
            }
        }
        let plan = AtriaHistoricalJSONLRecentScanner.plan(
            previousStates: states,
            current: descriptors
        )
        return automaticRecoveredDataProjectionPlanIsBounded(
            plan,
            maximumIncrementalBytes: maximumIncrementalBytes
        ) ? plan : nil
    }

    /// Metadata-only validation used while writing the paired UI/scanner
    /// checkpoint. It intentionally validates the snapshot's old offsets
    /// against the latest descriptors; it never derives or advances an offset
    /// from those descriptors.
    static func automaticRecoveredDataCacheAuthorityHasBoundedCurrentPlan(
        _ authority: AutomaticRecoveredDataCacheAuthority,
        since: Date,
        maximumIncrementalBytes: UInt64 =
            maximumAutomaticRecoveredDataIncrementalBytes
    ) -> Bool {
        precondition(
            !Thread.isMainThread,
            "Recovered cache authority validation must run off the main thread"
        )
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: recentRecoveredReadableFileURLs(
                since: since.timeIntervalSince1970
            )
        )
        return automaticRecoveredDataCacheAuthorityRestorationPlan(
            authority,
            since: since,
            descriptors: descriptors,
            maximumIncrementalBytes: maximumIncrementalBytes
        ) != nil
    }

    /// Installs a sparse recovered-data cache after a cold process launch. Raw
    /// physiology/motion arrays are deliberately not serialized: SessionStore's
    /// paired bounded checkpoint is the base projection, while this cache owns
    /// only exact complete-line offsets for decoding the next small delta.
    @discardableResult
    static func restoreAutomaticRecoveredDataCacheAuthority(
        _ authority: AutomaticRecoveredDataCacheAuthority,
        since: Date,
        maximumIncrementalBytes: UInt64 =
            maximumAutomaticRecoveredDataIncrementalBytes
    ) -> Bool {
        precondition(
            !Thread.isMainThread,
            "Recovered cache authority restoration must run off the main thread"
        )
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: recentRecoveredReadableFileURLs(
                since: since.timeIntervalSince1970
            )
        )
        return restoreAutomaticRecoveredDataCacheAuthority(
            authority,
            since: since,
            descriptors: descriptors,
            maximumIncrementalBytes: maximumIncrementalBytes
        )
    }

    /// Dependency-injected cold-process seam. Validation happens before the
    /// cache lock; a later source change is re-planned by metadata admission
    /// and again by the authoritative scanner worker, so it can only make the
    /// lane fail closed.
    @discardableResult
    static func restoreAutomaticRecoveredDataCacheAuthority(
        _ authority: AutomaticRecoveredDataCacheAuthority,
        since: Date,
        descriptors: [AtriaHistoricalJSONLRecentScanner.FileDescriptor],
        maximumIncrementalBytes: UInt64 =
            maximumAutomaticRecoveredDataIncrementalBytes
    ) -> Bool {
        guard automaticRecoveredDataCacheAuthorityRestorationPlan(
            authority,
            since: since,
            descriptors: descriptors,
            maximumIncrementalBytes: maximumIncrementalBytes
        ) != nil else { return false }
        let states = Dictionary(
            uniqueKeysWithValues: authority.sources.map { source in
                (
                    source.path,
                    AtriaHistoricalJSONLRecentScanner.FileState(
                        path: source.path,
                        processedOffset: source.processedOffset,
                        modificationTime: source.modificationTime,
                        resourceIdentifier: source.resourceIdentifier
                    )
                )
            }
        )
        recoveredDataCacheLock.lock()
        defer { recoveredDataCacheLock.unlock() }
        // Never replace a live process cache with an older disk checkpoint.
        guard recoveredDataCache == nil else { return false }
        _ = replaceRecoveredDataCacheWhileLocked(with: RecoveredDataCache(
            coveredSince: authority.coveredSince,
            // This sparse cursor was created by the bounded automatic lane;
            // preserve that origin so unchanged/tail-only metadata admission
            // can reuse its exact file states. It is not a production cache,
            // and therefore does not weaken production -> automatic rejection.
            budget: .automaticForeground,
            fileStates: states,
            heartRatePoints: [],
            rrAccumulator: .init(),
            skinTemperatureRawPoints: [],
            gravitySamples: [],
            motionRecordIdentities: [],
            truncatedChannels: []
        ))
        return true
    }

    static var automaticRecoveredDataBootstrapCheckpointExists: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: automaticRecoveredDataBootstrapCheckpointURL.path
        ),
        let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            return false
        }
        return size > 0
            && size <= maximumAutomaticRecoveredDataBootstrapCheckpointBytes
    }

    static func removeAutomaticRecoveredDataBootstrapCheckpoint() {
        try? FileManager.default.removeItem(
            at: automaticRecoveredDataBootstrapCheckpointURL
        )
    }

    /// Selects only catalog-qualified chunks that can overlap the bounded
    /// current-cycle/prior-night cutoff. A source image whose entire physical
    /// size is already <=8 MiB may bootstrap without catalog metadata because
    /// that complete rebuild is independently byte-bounded. Larger unknown,
    /// compressed, or unverified source sets fail closed.
    private static func automaticRecoveredDataBootstrapSourceImage(
        since: Date
    ) -> AutomaticRecoveredDataBootstrapSourceImage? {
        let candidates = recentReadableFileURLs()
        let allDescriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: candidates
        )
        if automaticRecoveredDataBootstrapDescriptorsAreAdmissible(
            allDescriptors,
            maximumTotalBytes: maximumAutomaticRecoveredDataIncrementalBytes
        ) {
            let generation = (try? catalogStoreLocked())
                .flatMap { try? $0.snapshot().generation }
            return .init(
                catalogGeneration: generation,
                descriptors: allDescriptors
            )
        }

        let cutoff = since.timeIntervalSince1970
        guard cutoff.isFinite,
              let store = try? catalogStoreLocked(),
              let catalog = try? store.snapshot(),
              (try? catalog.validate()) != nil else { return nil }
        let selectedURLs = recoveredProjectionFileURLs(
            candidates: candidates,
            catalog: catalog,
            archiveRoot: archiveDirectory,
            since: cutoff
        )
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: selectedURLs
        )
        guard automaticRecoveredDataBootstrapDescriptorsAreAdmissible(
            descriptors,
            maximumTotalBytes:
                maximumAutomaticRecoveredDataBootstrapSourceBytes
        ) else { return nil }

        let root = archiveDirectory.standardizedFileURL
        let chunksByPath = Dictionary(grouping: catalog.chunks) { chunk in
            root.appendingPathComponent(chunk.relativePath)
                .standardizedFileURL.path
        }
        for descriptor in descriptors {
            let matches = chunksByPath[descriptor.path] ?? []
            guard matches.count == 1, let chunk = matches.first else {
                return nil
            }
            switch chunk.state {
            case .active:
                guard chunk.id == catalog.activeChunkID,
                      chunk.compressedStorage == nil else { return nil }
            case .sealed:
                guard chunk.compressedStorage == nil,
                      let sealedAt = chunk.sealedAt,
                      let rows = chunk.rowCount,
                      rows > 0,
                      let first = chunk.firstTimestamp,
                      let last = chunk.lastTimestamp,
                      last >= first,
                      last.timeIntervalSince1970 >= cutoff,
                      let digest = chunk.contentSHA256,
                      digest.count == 64,
                      let attributes = try? FileManager.default
                        .attributesOfItem(atPath: descriptor.path),
                      (attributes[.type] as? FileAttributeType)
                        == .typeRegular,
                      (attributes[.size] as? NSNumber)?.uint64Value
                        == chunk.byteCount,
                      let modified = attributes[.modificationDate] as? Date,
                      modified.timeIntervalSince(sealedAt) <= 1 else {
                    return nil
                }
            case .retired:
                return nil
            }
        }
        return .init(
            catalogGeneration: catalog.generation,
            descriptors: descriptors
        )
    }

    private static func automaticRecoveredDataBootstrapDescriptorsAreAdmissible(
        _ descriptors: [AtriaHistoricalJSONLRecentScanner.FileDescriptor],
        maximumTotalBytes: UInt64
    ) -> Bool {
        guard maximumTotalBytes > 0,
              !descriptors.isEmpty,
              descriptors.count
                <= maximumAutomaticRecoveredDataCacheAuthoritySourceCount else {
            return false
        }
        var paths = Set<String>()
        var identifiers = Set<String>()
        var total: UInt64 = 0
        for descriptor in descriptors {
            guard !descriptor.isCompressed,
                  let identifier = descriptor.resourceIdentifier,
                  !identifier.isEmpty,
                  identifier.utf8.count
                    <= maximumAutomaticRecoveredDataCacheAuthorityIdentifierBytes,
                  descriptor.path.utf8.count
                    <= maximumAutomaticRecoveredDataCacheAuthorityPathBytes,
                  descriptor.path
                    == descriptor.url.standardizedFileURL.path,
                  descriptor.modificationTime.isFinite,
                  paths.insert(descriptor.path).inserted,
                  identifiers.insert(identifier).inserted,
                  total <= maximumTotalBytes,
                  descriptor.size <= maximumTotalBytes - total else {
                return false
            }
            total += descriptor.size
        }
        return total <= maximumTotalBytes
    }

    private enum AutomaticRecoveredDataBootstrapCheckpointReadResult {
        case loaded(AutomaticRecoveredDataBootstrapCheckpoint)
        case invalid
        case cancelled
    }

    private enum AutomaticRecoveredDataBootstrapCheckpointWriteResult {
        case written
        case failed
        case cancelled
    }

    private static func readAutomaticRecoveredDataBootstrapCheckpoint(
        from url: URL,
        now: Date,
        requestedCutoff: Date,
        shouldContinue: @escaping () -> Bool,
        onProgress: ((String, Int) -> Void)?
    ) -> AutomaticRecoveredDataBootstrapCheckpointReadResult {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value,
        byteCount > 0,
        byteCount <= maximumAutomaticRecoveredDataBootstrapCheckpointBytes,
        byteCount <= UInt64(Int.max) else {
            return .invalid
        }
        let authority = AtriaRecoveredCheckpointCodingAuthority(
            shouldContinue: shouldContinue,
            onProgress: onProgress,
            maximumRRRecords: automaticRecoveredDataBootstrapBudget
                .maximumRRRecords
        )
        let data: Data
        do {
            try authority.checkpoint(stage: "checkpoint_read", index: 0)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(Int(byteCount))
            let chunkBytes = 256 * 1_024
            while buffer.count < Int(byteCount) {
                try authority.checkpoint(
                    stage: "checkpoint_read",
                    index: buffer.count
                )
                let requested = min(
                    chunkBytes,
                    Int(byteCount) - buffer.count
                )
                guard let chunk = try handle.read(upToCount: requested),
                      !chunk.isEmpty else {
                    return .invalid
                }
                buffer.append(chunk)
            }
            try authority.checkpoint(
                stage: "checkpoint_read_complete",
                index: buffer.count
            )
            data = buffer
        } catch AtriaRecoveredCheckpointCodingError.authorityRevoked {
            return .cancelled
        } catch {
            return .invalid
        }

        var checkpoint: AutomaticRecoveredDataBootstrapCheckpoint
        do {
            let decoder = PropertyListDecoder()
            decoder.userInfo[.atriaRecoveredCheckpointCodingAuthority]
                = authority
            checkpoint = try decoder.decode(
                AutomaticRecoveredDataBootstrapCheckpoint.self,
                from: data
            )
        } catch AtriaRecoveredCheckpointCodingError.authorityRevoked {
            return .cancelled
        } catch {
            return .invalid
        }
        guard
        checkpoint.version
            == AutomaticRecoveredDataBootstrapCheckpoint.schema,
        checkpoint.cutoff.isFinite,
        checkpoint.updatedAt.isFinite,
        checkpoint.updatedAt <= now.timeIntervalSince1970 + 5 * 60,
        now.timeIntervalSince1970 - checkpoint.updatedAt
            <= maximumAutomaticRecoveredDataBootstrapAge,
        !checkpoint.sources.isEmpty,
        checkpoint.sources.count
            <= maximumAutomaticRecoveredDataCacheAuthoritySourceCount,
        checkpoint.heartRatePoints.count
            <= automaticRecoveredDataBootstrapBudget.maximumHeartRatePoints,
        checkpoint.rrAccumulator.acceptedRecordCount
            <= automaticRecoveredDataBootstrapBudget.maximumRRRecords,
        checkpoint.skinTemperatureRawPoints.count
            <= automaticRecoveredDataBootstrapBudget
                .maximumSkinTemperaturePoints,
        checkpoint.gravitySamples.count
            <= automaticRecoveredDataBootstrapBudget.maximumGravitySamples,
        automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
            automaticRecoveredDataBootstrapRetainedCounts(
                heartRate: checkpoint.heartRatePoints,
                rrAccumulator: checkpoint.rrAccumulator,
                skin: checkpoint.skinTemperatureRawPoints,
                gravity: checkpoint.gravitySamples
            )
        )
        else { return .invalid }

        let requested = requestedCutoff.timeIntervalSince1970
        guard requested.isFinite,
              checkpoint.cutoff <= requested,
              requested - checkpoint.cutoff
                <= maximumAutomaticRecoveredDataCacheAuthorityWindow else {
            return .invalid
        }
        if requested > checkpoint.cutoff {
            do {
                var heartRate: [HeartRatePoint] = []
                heartRate.reserveCapacity(checkpoint.heartRatePoints.count)
                for (index, point) in checkpoint.heartRatePoints.enumerated() {
                    if index.isMultiple(of: 256) {
                        try authority.checkpoint(
                            stage: "checkpoint_prune_heart_rate",
                            index: index
                        )
                    }
                    if point.t.timeIntervalSince1970 >= requested {
                        heartRate.append(point)
                    }
                }
                var rr = checkpoint.rrAccumulator
                var rrIndex = 0
                guard rr.prune(
                    before: requested,
                    shouldContinue: {
                        defer { rrIndex += 256 }
                        do {
                            try authority.checkpoint(
                                stage: "checkpoint_prune_rr",
                                index: rrIndex
                            )
                            return true
                        } catch {
                            return false
                        }
                    }
                ) else {
                    return .cancelled
                }
                var skin: [SkinTemperatureRawPoint] = []
                skin.reserveCapacity(
                    checkpoint.skinTemperatureRawPoints.count
                )
                for (index, point) in checkpoint
                    .skinTemperatureRawPoints.enumerated() {
                    if index.isMultiple(of: 256) {
                        try authority.checkpoint(
                            stage: "checkpoint_prune_skin",
                            index: index
                        )
                    }
                    if point.t.timeIntervalSince1970 >= requested {
                        skin.append(point)
                    }
                }
                var gravity: [GravitySample] = []
                gravity.reserveCapacity(checkpoint.gravitySamples.count)
                for (index, sample) in checkpoint.gravitySamples.enumerated() {
                    if index.isMultiple(of: 256) {
                        try authority.checkpoint(
                            stage: "checkpoint_prune_gravity",
                            index: index
                        )
                    }
                    if sample.timestamp >= requested {
                        gravity.append(sample)
                    }
                }
                try authority.checkpoint(
                    stage: "checkpoint_prune_complete",
                    index: heartRate.count + rr.acceptedRecordCount
                        + skin.count + gravity.count
                )
                checkpoint.cutoff = requested
                checkpoint.heartRatePoints = heartRate
                checkpoint.rrAccumulator = rr
                checkpoint.skinTemperatureRawPoints = skin
                checkpoint.gravitySamples = gravity
                guard automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
                    automaticRecoveredDataBootstrapRetainedCounts(
                        heartRate: checkpoint.heartRatePoints,
                        rrAccumulator: checkpoint.rrAccumulator,
                        skin: checkpoint.skinTemperatureRawPoints,
                        gravity: checkpoint.gravitySamples
                    )
                ) else { return .invalid }
            } catch AtriaRecoveredCheckpointCodingError.authorityRevoked {
                return .cancelled
            } catch {
                return .invalid
            }
        }
        return .loaded(checkpoint)
    }

    private static func writeAutomaticRecoveredDataBootstrapCheckpoint(
        _ checkpoint: AutomaticRecoveredDataBootstrapCheckpoint,
        to url: URL,
        shouldContinue: @escaping () -> Bool,
        onProgress: ((String, Int) -> Void)?
    ) -> AutomaticRecoveredDataBootstrapCheckpointWriteResult {
        guard automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
            automaticRecoveredDataBootstrapRetainedCounts(
                heartRate: checkpoint.heartRatePoints,
                rrAccumulator: checkpoint.rrAccumulator,
                skin: checkpoint.skinTemperatureRawPoints,
                gravity: checkpoint.gravitySamples
            )
        ) else { return .failed }
        let authority = AtriaRecoveredCheckpointCodingAuthority(
            shouldContinue: shouldContinue,
            onProgress: onProgress,
            maximumRRRecords: automaticRecoveredDataBootstrapBudget
                .maximumRRRecords
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        encoder.userInfo[.atriaRecoveredCheckpointCodingAuthority] = authority
        let data: Data
        do {
            data = try encoder.encode(checkpoint)
            try authority.checkpoint(
                stage: "checkpoint_encode_data_complete",
                index: data.count
            )
        } catch AtriaRecoveredCheckpointCodingError.authorityRevoked {
            return .cancelled
        } catch {
            // PropertyListEncoder may wrap an error thrown by a nested
            // Encodable container. The coding authority records the first
            // observed revocation before throwing, so cancellation remains
            // distinguishable from malformed or failed checkpoint encoding.
            return authority.wasRevoked ? .cancelled : .failed
        }
        guard UInt64(data.count)
                <= maximumAutomaticRecoveredDataBootstrapCheckpointBytes else {
            return .failed
        }
        do {
            try authority.checkpoint(
                stage: "checkpoint_write_begin",
                index: 0
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temporaryURL = url.deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
                )
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard FileManager.default.createFile(
                atPath: temporaryURL.path,
                contents: nil
            ) else {
                return .failed
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            defer { try? handle.close() }
            let chunkBytes = 256 * 1_024
            var offset = 0
            while offset < data.count {
                try authority.checkpoint(
                    stage: "checkpoint_write",
                    index: offset
                )
                let upperBound = min(offset + chunkBytes, data.count)
                try handle.write(contentsOf: data[offset..<upperBound])
                offset = upperBound
            }
            try handle.synchronize()
            try authority.checkpoint(
                stage: "checkpoint_write_complete",
                index: offset
            )
            try handle.close()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(
                    url,
                    withItemAt: temporaryURL
                )
            } else {
                try FileManager.default.moveItem(
                    at: temporaryURL,
                    to: url
                )
            }
            return .written
        } catch AtriaRecoveredCheckpointCodingError.authorityRevoked {
            return .cancelled
        } catch {
            AtriaDebugLog(
                "ATRIADBG recovered_bootstrap status=checkpoint_write_failed error=%@",
                error.localizedDescription
            )
            return .failed
        }
    }

    private static func makeAutomaticRecoveredDataBootstrapCheckpoint(
        since: Date,
        sourceImage: AutomaticRecoveredDataBootstrapSourceImage,
        now: Date,
        shouldContinue: () -> Bool
    ) -> AutomaticRecoveredDataBootstrapCheckpoint? {
        let cutoff = since.timeIntervalSince1970
        guard cutoff.isFinite, shouldContinue() else { return nil }

        recoveredDataCacheLock.lock()
        defer { recoveredDataCacheLock.unlock() }
        guard shouldContinue() else { return nil }
        let existingCache = recoveredDataCache
        let seed: RecoveredDataCache?
        if let existingCache {
            guard existingCache.coveredSince <= cutoff,
                  cutoff - existingCache.coveredSince
                    <= maximumAutomaticRecoveredDataCacheAuthorityWindow,
                  existingCache.truncatedChannels.isEmpty else { return nil }
            guard let pruned = prunedRecoveredCache(
                existingCache,
                since: cutoff,
                shouldContinue: shouldContinue
            ) else { return nil }
            let plan = AtriaHistoricalJSONLRecentScanner.plan(
                previousStates: pruned.fileStates,
                current: sourceImage.descriptors
            )
            guard automaticRecoveredDataProjectionPlanIsBounded(
                plan,
                maximumIncrementalBytes:
                    maximumAutomaticRecoveredDataBootstrapSourceBytes
            ),
            pruned.heartRatePoints.count
                <= automaticRecoveredDataBootstrapBudget.maximumHeartRatePoints,
            pruned.rrAccumulator.acceptedRecordCount
                <= automaticRecoveredDataBootstrapBudget.maximumRRRecords,
            pruned.skinTemperatureRawPoints.count
                <= automaticRecoveredDataBootstrapBudget
                    .maximumSkinTemperaturePoints,
            pruned.gravitySamples.count
                <= automaticRecoveredDataBootstrapBudget.maximumGravitySamples,
            automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
                automaticRecoveredDataBootstrapRetainedCounts(
                    heartRate: pruned.heartRatePoints,
                    rrAccumulator: pruned.rrAccumulator,
                    skin: pruned.skinTemperatureRawPoints,
                    gravity: pruned.gravitySamples
                )
            )
            else { return nil }
            seed = pruned
        } else {
            seed = nil
        }

        let states = seed?.fileStates ?? [:]
        var sources: [AutomaticRecoveredDataBootstrapCheckpoint.Source] = []
        sources.reserveCapacity(sourceImage.descriptors.count)
        for (index, descriptor) in sourceImage.descriptors.enumerated() {
            if index.isMultiple(of: 16), !shouldContinue() { return nil }
            sources.append(AutomaticRecoveredDataBootstrapCheckpoint.Source(
                path: descriptor.path,
                targetSize: descriptor.size,
                processedOffset:
                    states[descriptor.path]?.processedOffset ?? 0,
                modificationTime: descriptor.modificationTime,
                resourceIdentifier: descriptor.resourceIdentifier!
            ))
        }
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &sources,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: { $0.path < $1.path }
        ) else { return nil }
        var rr = seed?.rrAccumulator
            ?? AtriaRecoveredRRProjection.Accumulator()
        guard rr.prune(
            before: cutoff,
            shouldContinue: shouldContinue
        ) else { return nil }
        let heartRate = seed?.heartRatePoints ?? []
        let skin = seed?.skinTemperatureRawPoints ?? []
        let gravity = seed?.gravitySamples ?? []
        guard shouldContinue(),
              automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
                automaticRecoveredDataBootstrapRetainedCounts(
                    heartRate: heartRate,
                    rrAccumulator: rr,
                    skin: skin,
                    gravity: gravity
                )
              ) else { return nil }
        return .init(
            version: AutomaticRecoveredDataBootstrapCheckpoint.schema,
            cutoff: cutoff,
            updatedAt: now.timeIntervalSince1970,
            sourceFingerprint: makeConsumerSourceFingerprint(
                catalogGeneration: sourceImage.catalogGeneration,
                descriptors: sourceImage.descriptors
            ),
            sources: sources,
            heartRatePoints: heartRate,
            rrAccumulator: rr,
            skinTemperatureRawPoints: skin,
            gravitySamples: gravity
        )
    }

    /// Revalidates persisted target EOFs against a new metadata image. Growth
    /// extends the target without advancing the processed cursor; removal,
    /// truncation, replacement, same-size mutation, compression, or an
    /// over-broad current image invalidates the partial projection.
    private static func updateAutomaticRecoveredDataBootstrapSources(
        _ checkpoint: inout AutomaticRecoveredDataBootstrapCheckpoint,
        sourceImage: AutomaticRecoveredDataBootstrapSourceImage
    ) -> String? {
        guard automaticRecoveredDataBootstrapDescriptorsAreAdmissible(
            sourceImage.descriptors,
            maximumTotalBytes:
                maximumAutomaticRecoveredDataBootstrapSourceBytes
        ) else { return "source_image_unbounded_or_compressed" }
        let currentByPath = Dictionary(
            uniqueKeysWithValues: sourceImage.descriptors.map {
                ($0.path, $0)
            }
        )
        let priorPaths = Set(checkpoint.sources.map(\.path))
        guard priorPaths.isSubset(of: Set(currentByPath.keys)) else {
            return "source_removed"
        }
        for index in checkpoint.sources.indices {
            var source = checkpoint.sources[index]
            guard let descriptor = currentByPath[source.path],
                  descriptor.resourceIdentifier
                    == source.resourceIdentifier else {
                return "source_replaced"
            }
            guard descriptor.size >= source.targetSize,
                  descriptor.size >= source.processedOffset else {
                return "source_truncated"
            }
            if descriptor.size == source.targetSize {
                guard descriptor.modificationTime
                        == source.modificationTime else {
                    return "source_same_size_mutated"
                }
            } else {
                source.targetSize = descriptor.size
                source.modificationTime = descriptor.modificationTime
                checkpoint.sources[index] = source
            }
        }
        for descriptor in sourceImage.descriptors
        where !priorPaths.contains(descriptor.path) {
            checkpoint.sources.append(.init(
                path: descriptor.path,
                targetSize: descriptor.size,
                processedOffset: 0,
                modificationTime: descriptor.modificationTime,
                resourceIdentifier: descriptor.resourceIdentifier!
            ))
        }
        checkpoint.sources.sort { $0.path < $1.path }
        checkpoint.sourceFingerprint = makeConsumerSourceFingerprint(
            catalogGeneration: sourceImage.catalogGeneration,
            descriptors: sourceImage.descriptors
        )
        return nil
    }

    private static func canonicalizeAutomaticRecoveredDataBootstrapEvidence(
        _ checkpoint: inout AutomaticRecoveredDataBootstrapCheckpoint,
        shouldContinue: () -> Bool
    ) -> Bool {
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &checkpoint.heartRatePoints,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: {
            if $0.t != $1.t { return $0.t < $1.t }
            return $0.bpm < $1.bpm
        }) else { return false }
        var canonicalHeartRate: [HeartRatePoint] = []
        canonicalHeartRate.reserveCapacity(checkpoint.heartRatePoints.count)
        for (index, point) in checkpoint.heartRatePoints.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return false }
            if canonicalHeartRate.last != point { canonicalHeartRate.append(point) }
        }
        checkpoint.heartRatePoints = canonicalHeartRate
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &checkpoint.skinTemperatureRawPoints,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: {
            if $0.t != $1.t { return $0.t < $1.t }
            if $0.raw != $1.raw { return $0.raw < $1.raw }
            return ($0.strapIdentifier ?? "") < ($1.strapIdentifier ?? "")
        }) else { return false }
        var canonicalSkin: [SkinTemperatureRawPoint] = []
        canonicalSkin.reserveCapacity(checkpoint.skinTemperatureRawPoints.count)
        for (index, point) in checkpoint.skinTemperatureRawPoints.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return false }
            if canonicalSkin.last != point { canonicalSkin.append(point) }
        }
        checkpoint.skinTemperatureRawPoints = canonicalSkin
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &checkpoint.gravitySamples,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            if $0.x != $1.x { return $0.x < $1.x }
            if $0.y != $1.y { return $0.y < $1.y }
            if $0.z != $1.z { return $0.z < $1.z }
            if $0.validated != $1.validated {
                return !$0.validated && $1.validated
            }
            return !$0.timestampValidated && $1.timestampValidated
        }) else { return false }
        var canonicalGravity: [GravitySample] = []
        canonicalGravity.reserveCapacity(checkpoint.gravitySamples.count)
        for (index, sample) in checkpoint.gravitySamples.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return false }
            if canonicalGravity.last != sample { canonicalGravity.append(sample) }
        }
        checkpoint.gravitySamples = canonicalGravity
        return shouldContinue()
    }

    private static func remainingAutomaticRecoveredDataBootstrapBytes(
        _ checkpoint: AutomaticRecoveredDataBootstrapCheckpoint
    ) -> UInt64 {
        checkpoint.sources.reduce(UInt64(0)) { total, source in
            let remaining = source.targetSize >= source.processedOffset
                ? source.targetSize - source.processedOffset
                : UInt64.max
            let (sum, overflow) = total.addingReportingOverflow(remaining)
            return overflow ? UInt64.max : sum
        }
    }

    private static func installAutomaticRecoveredDataBootstrapCache(
        _ checkpoint: AutomaticRecoveredDataBootstrapCheckpoint,
        retainedCountsForAdmission:
            AutomaticRecoveredDataBootstrapRetainedCounts? = nil,
        shouldContinue: () -> Bool,
        onInstalled: () -> Void = {}
    ) -> Bool {
        let retainedCounts = retainedCountsForAdmission
            ?? automaticRecoveredDataBootstrapRetainedCounts(
                heartRate: checkpoint.heartRatePoints,
                rrAccumulator: checkpoint.rrAccumulator,
                skin: checkpoint.skinTemperatureRawPoints,
                gravity: checkpoint.gravitySamples
            )
        guard shouldContinue(),
              remainingAutomaticRecoveredDataBootstrapBytes(checkpoint) == 0,
              checkpoint.heartRatePoints.count
                <= automaticRecoveredDataBootstrapBudget
                    .maximumHeartRatePoints,
              checkpoint.rrAccumulator.acceptedRecordCount
                <= automaticRecoveredDataBootstrapBudget.maximumRRRecords,
              checkpoint.skinTemperatureRawPoints.count
                <= automaticRecoveredDataBootstrapBudget
                    .maximumSkinTemperaturePoints,
              checkpoint.gravitySamples.count
                <= automaticRecoveredDataBootstrapBudget
                    .maximumGravitySamples,
              automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
                retainedCounts
              ) else { return false }
        let states = Dictionary(
            uniqueKeysWithValues: checkpoint.sources.map { source in
                (
                    source.path,
                    AtriaHistoricalJSONLRecentScanner.FileState(
                        path: source.path,
                        processedOffset: source.processedOffset,
                        modificationTime: source.modificationTime,
                        resourceIdentifier: source.resourceIdentifier
                    )
                )
            }
        )
        let cache = RecoveredDataCache(
            coveredSince: checkpoint.cutoff,
            // The resumable bootstrap is the durable half of the bounded
            // automatic lane, so retain its actual stricter construction
            // budget. Directional compatibility lets the immediate production
            // BG continuation consume this complete image, while the inverse
            // production-to-automatic reuse remains forbidden.
            budget: .automaticForeground,
            fileStates: states,
            heartRatePoints: checkpoint.heartRatePoints,
            rrAccumulator: checkpoint.rrAccumulator,
            skinTemperatureRawPoints: checkpoint.skinTemperatureRawPoints,
            gravitySamples: checkpoint.gravitySamples,
            // Chunk cursors never overlap, and bootstrap canonicalization
            // removes exact gravity replays across chunks. The ordinary
            // incremental lane will add fresh replay identities from here.
            motionRecordIdentities: [],
            truncatedChannels: []
        )
        return installRecoveredDataCacheAtomically(
            cache,
            shouldContinue: shouldContinue,
            onInstalled: {
                onInstalled()
                recordRetainedCacheFootprint(
                    cache,
                    plan: "bootstrap",
                    shouldContinue: shouldContinue
                )
            }
        )
    }

#if DEBUG
    /// Count-only seam for the final bootstrap publication gate. It exercises
    /// the production installer without allocating 250,001 retained values.
    static func installAutomaticRecoveredDataBootstrapRetainedCountsForTesting(
        heartRate: Int,
        rr: Int,
        skin: Int,
        gravity: Int,
        shouldContinue: () -> Bool = { true },
        onInstalled: () -> Void = {}
    ) -> Bool {
        let checkpoint = AutomaticRecoveredDataBootstrapCheckpoint(
            version: AutomaticRecoveredDataBootstrapCheckpoint.schema,
            cutoff: 0,
            updatedAt: 0,
            sourceFingerprint: .init(
                catalogGeneration: nil,
                sources: []
            ),
            sources: [.init(
                path: "/debug/bootstrap-aggregate.jsonl",
                targetSize: 0,
                processedOffset: 0,
                modificationTime: 0,
                resourceIdentifier: "debug-bootstrap-aggregate"
            )],
            heartRatePoints: [],
            rrAccumulator: .init(),
            skinTemperatureRawPoints: [],
            gravitySamples: []
        )
        return installAutomaticRecoveredDataBootstrapCache(
            checkpoint,
            retainedCountsForAdmission: .init(
                heartRate: heartRate,
                rr: rr,
                skin: skin,
                gravity: gravity
            ),
            shouldContinue: shouldContinue,
            onInstalled: onInstalled
        )
    }
#endif

    /// Runs exactly one <=8 MiB resumable current-window pass under the live
    /// BGProcessing throttle lease. A completed bootstrap installs a normal
    /// production cache; SessionStore then enters the existing bounded
    /// current-cycle/latest-night publication pipeline.
    static func performAutomaticRecoveredDataBootstrapStep(
        since: Date,
        lease: AtriaBackgroundProjectionThrottle.ActiveLease,
        maximumBytesPerStep: UInt64 =
            maximumAutomaticRecoveredDataIncrementalBytes
    ) -> AutomaticRecoveredDataBootstrapStepResult {
        precondition(
            !Thread.isMainThread,
            "Recovered bootstrap must run off the main thread"
        )
        return performAutomaticRecoveredDataBootstrapStep(
            since: since,
            checkpointURL: automaticRecoveredDataBootstrapCheckpointURL,
            maximumBytesPerStep: maximumBytesPerStep,
            sourceImageProvider: {
                automaticRecoveredDataBootstrapSourceImage(since: since)
            },
            shouldContinue: {
                AtriaBackgroundProjectionThrottle.shared
                    .activeLeaseShouldContinue(lease)
            },
            cooperativeShouldContinue: {
                !AtriaBackgroundProjectionThrottle.shared
                    .cooperativeCheckpointShouldAbort(
                        lease: lease,
                        processedDelta: 256
                    )
            }
        )
    }

#if DEBUG
    /// Exercises the exact production-budget planner used immediately after a
    /// real resumable BG bootstrap reaches `.ready`, while allowing a fixture
    /// descriptor image instead of touching the process archive directory.
    static func makeProductionRecoveredDataSnapshotForTesting(
        since: Date,
        descriptors: [AtriaHistoricalJSONLRecentScanner.FileDescriptor]
    ) -> RecoveredDataSnapshot? {
        makeRecoveredDataSnapshot(
            since: since,
            budget: .production,
            descriptors: descriptors,
            started: DispatchTime.now().uptimeNanoseconds,
            maximumAutomaticIncrementalBytes: nil,
            decodedWorkBudget: nil,
            backgroundProjectionLease: nil,
            executionShouldContinue: { true },
            onScanProgress: nil
        )
    }

    static func performAutomaticRecoveredDataBootstrapStepForTesting(
        since: Date,
        descriptors: @escaping () ->
            [AtriaHistoricalJSONLRecentScanner.FileDescriptor]?,
        checkpointURL: URL,
        maximumBytesPerStep: UInt64,
        shouldContinue: @escaping () -> Bool = { true },
        cooperativeShouldContinue: (() -> Bool)? = nil,
        onStage: ((String) -> Void)? = nil,
        onCheckpointProgress: ((String, Int) -> Void)? = nil
    ) -> AutomaticRecoveredDataBootstrapStepResult {
        performAutomaticRecoveredDataBootstrapStep(
            since: since,
            checkpointURL: checkpointURL,
            maximumBytesPerStep: maximumBytesPerStep,
            sourceImageProvider: {
                descriptors().map {
                    AutomaticRecoveredDataBootstrapSourceImage(
                        catalogGeneration: 1,
                        descriptors: $0
                    )
                }
            },
            shouldContinue: shouldContinue,
            cooperativeShouldContinue:
                cooperativeShouldContinue ?? shouldContinue,
            onStage: onStage,
            onCheckpointProgress: onCheckpointProgress
        )
    }
#endif

    private static func performAutomaticRecoveredDataBootstrapStep(
        since: Date,
        checkpointURL: URL,
        maximumBytesPerStep: UInt64,
        sourceImageProvider: () -> AutomaticRecoveredDataBootstrapSourceImage?,
        shouldContinue: () -> Bool,
        cooperativeShouldContinue: @escaping () -> Bool,
        onStage: ((String) -> Void)? = nil,
        onCheckpointProgress: ((String, Int) -> Void)? = nil
    ) -> AutomaticRecoveredDataBootstrapStepResult {
        guard maximumBytesPerStep > 0,
              maximumBytesPerStep
                <= maximumAutomaticRecoveredDataIncrementalBytes else {
            return .deferred(reason: "invalid_step_budget")
        }
        guard shouldContinue() else {
            return .deferred(reason: "background_authority_revoked")
        }
        let now = Date()
        guard let initialImage = sourceImageProvider(),
              automaticRecoveredDataBootstrapDescriptorsAreAdmissible(
                initialImage.descriptors,
                maximumTotalBytes:
                    maximumAutomaticRecoveredDataBootstrapSourceBytes
              ) else {
            return .deferred(reason: "current_window_source_unqualified")
        }

        var checkpoint: AutomaticRecoveredDataBootstrapCheckpoint
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            switch readAutomaticRecoveredDataBootstrapCheckpoint(
                from: checkpointURL,
                now: now,
                requestedCutoff: since,
                shouldContinue: cooperativeShouldContinue,
                onProgress: onCheckpointProgress
            ) {
            case .loaded(let restored):
                checkpoint = restored
            case .cancelled:
                return .deferred(reason: "background_authority_revoked")
            case .invalid:
                try? FileManager.default.removeItem(at: checkpointURL)
                return .invalidated(reason: "checkpoint_invalid")
            }
        } else {
            guard let created = makeAutomaticRecoveredDataBootstrapCheckpoint(
                since: since,
                sourceImage: initialImage,
                now: now,
                shouldContinue: cooperativeShouldContinue
            ) else {
                guard cooperativeShouldContinue() else {
                    return .deferred(
                        reason: "background_authority_revoked"
                    )
                }
                return .invalidated(reason: "cache_seed_unavailable")
            }
            checkpoint = created
        }
        if let invalidation = updateAutomaticRecoveredDataBootstrapSources(
            &checkpoint,
            sourceImage: initialImage
        ) {
            try? FileManager.default.removeItem(at: checkpointURL)
            return .invalidated(reason: invalidation)
        }

        guard automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
            automaticRecoveredDataBootstrapRetainedCounts(
                heartRate: checkpoint.heartRatePoints,
                rrAccumulator: checkpoint.rrAccumulator,
                skin: checkpoint.skinTemperatureRawPoints,
                gravity: checkpoint.gravitySamples
            )
        ) else {
            try? FileManager.default.removeItem(at: checkpointURL)
            return .invalidated(
                reason: "partial_projection_aggregate_budget_exceeded"
            )
        }

        var limitations = recoveredBudgetLimitations(
            heartRateCount: checkpoint.heartRatePoints.count,
            rrRecordCount: checkpoint.rrAccumulator.acceptedRecordCount,
            skinTemperatureCount:
                checkpoint.skinTemperatureRawPoints.count,
            gravityCount: checkpoint.gravitySamples.count,
            motionIdentityCount: 0,
            budget: automaticRecoveredDataBootstrapBudget
        )
        guard limitations.isEmpty else {
            try? FileManager.default.removeItem(at: checkpointURL)
            return .invalidated(reason: "partial_projection_budget_exceeded")
        }

        let sources = checkpoint.sources.compactMap { source ->
            AtriaHistoricalJSONLRecentScanner.Source? in
            guard source.processedOffset < source.targetSize else { return nil }
            return .init(
                descriptor: .init(
                    url: URL(fileURLWithPath: source.path),
                    size: source.targetSize,
                    modificationTime: source.modificationTime,
                    resourceIdentifier: source.resourceIdentifier
                ),
                startOffset: source.processedOffset
            )
        }
        var motionIdentities = Set<AtriaRecoveredMotionReplayIdentity>()
        var strapIdentifierIntern: [String: String] = [:]
        var retainedAggregateBudgetExceeded = false
        let scanResult = AtriaHistoricalJSONLRecentScanner.scan(
            sources: sources,
            cutoff: checkpoint.cutoff,
            byteBudget: Int(maximumBytesPerStep),
            shouldContinue: {
                !retainedAggregateBudgetExceeded
                    && cooperativeShouldContinue()
            }
        ) { line in
            guard let record = Record(scanLine: line) else { return }
            appendRecoveredRecord(
                record,
                cutoff: checkpoint.cutoff,
                budget: automaticRecoveredDataBootstrapBudget,
                limitations: &limitations,
                heartRate: &checkpoint.heartRatePoints,
                rrAccumulator: &checkpoint.rrAccumulator,
                skinTemperatureRawPoints:
                    &checkpoint.skinTemperatureRawPoints,
                gravity: &checkpoint.gravitySamples,
                motionRecordIdentities: &motionIdentities,
                strapIdentifierIntern: &strapIdentifierIntern
            )
            if !automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
                automaticRecoveredDataBootstrapRetainedCounts(
                    heartRate: checkpoint.heartRatePoints,
                    rrAccumulator: checkpoint.rrAccumulator,
                    skin: checkpoint.skinTemperatureRawPoints,
                    gravity: checkpoint.gravitySamples
                )
            ) {
                retainedAggregateBudgetExceeded = true
            }
        }
        guard scanResult.statistics.byteCount <= Int(maximumBytesPerStep) else {
            try? FileManager.default.removeItem(at: checkpointURL)
            return .invalidated(reason: "step_byte_budget_exceeded")
        }
        guard !retainedAggregateBudgetExceeded,
              automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
                automaticRecoveredDataBootstrapRetainedCounts(
                    heartRate: checkpoint.heartRatePoints,
                    rrAccumulator: checkpoint.rrAccumulator,
                    skin: checkpoint.skinTemperatureRawPoints,
                    gravity: checkpoint.gravitySamples
                )
              ) else {
            // The external durable bootstrap intent remains pending; discard
            // only this over-budget partial image so the next safe window can
            // restart from a later/pruned cutoff.
            try? FileManager.default.removeItem(at: checkpointURL)
            return .invalidated(
                reason: "partial_projection_aggregate_budget_exceeded"
            )
        }
        guard !scanResult.cancelled else {
            return .deferred(reason: "background_authority_revoked")
        }
        guard scanResult.complete || scanResult.exhaustedByteBudget else {
            return .deferred(reason: "source_read_incomplete")
        }
        guard limitations.isEmpty else {
            try? FileManager.default.removeItem(at: checkpointURL)
            return .invalidated(reason: "partial_projection_budget_exceeded")
        }
        for (path, state) in scanResult.states {
            guard let index = checkpoint.sources.firstIndex(where: {
                $0.path == path
            }) else {
                try? FileManager.default.removeItem(at: checkpointURL)
                return .invalidated(reason: "scanner_state_unknown_source")
            }
            checkpoint.sources[index].processedOffset = state.processedOffset
        }
        onStage?("before_canonicalization")
        guard canonicalizeAutomaticRecoveredDataBootstrapEvidence(
            &checkpoint,
            shouldContinue: cooperativeShouldContinue
        ) else {
            return .deferred(reason: "background_authority_revoked")
        }
        onStage?("after_canonicalization")
        guard automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
            automaticRecoveredDataBootstrapRetainedCounts(
                heartRate: checkpoint.heartRatePoints,
                rrAccumulator: checkpoint.rrAccumulator,
                skin: checkpoint.skinTemperatureRawPoints,
                gravity: checkpoint.gravitySamples
            )
        ) else {
            try? FileManager.default.removeItem(at: checkpointURL)
            return .invalidated(
                reason: "partial_projection_aggregate_budget_exceeded"
            )
        }

        guard shouldContinue() else {
            return .deferred(reason: "background_authority_revoked")
        }
        guard let finalImage = sourceImageProvider() else {
            return .deferred(reason: "source_revalidation_unavailable")
        }
        guard shouldContinue() else {
            return .deferred(reason: "background_authority_revoked")
        }
        if let invalidation = updateAutomaticRecoveredDataBootstrapSources(
            &checkpoint,
            sourceImage: finalImage
        ) {
            try? FileManager.default.removeItem(at: checkpointURL)
            return .invalidated(reason: invalidation)
        }
        guard automaticRecoveredDataBootstrapRetainedCountsAreAdmissible(
            automaticRecoveredDataBootstrapRetainedCounts(
                heartRate: checkpoint.heartRatePoints,
                rrAccumulator: checkpoint.rrAccumulator,
                skin: checkpoint.skinTemperatureRawPoints,
                gravity: checkpoint.gravitySamples
            )
        ) else {
            try? FileManager.default.removeItem(at: checkpointURL)
            return .invalidated(
                reason: "partial_projection_aggregate_budget_exceeded"
            )
        }
        checkpoint.updatedAt = Date().timeIntervalSince1970
        onStage?("before_checkpoint_write")
        switch writeAutomaticRecoveredDataBootstrapCheckpoint(
            checkpoint,
            to: checkpointURL,
            shouldContinue: cooperativeShouldContinue,
            onProgress: onCheckpointProgress
        ) {
        case .cancelled:
            return .deferred(reason: "background_authority_revoked")
        case .failed:
            return .deferred(reason: "checkpoint_write_failed")
        case .written:
            break
        }
        onStage?("after_checkpoint_write")
        guard shouldContinue() else {
            return .deferred(reason: "background_authority_revoked")
        }
        let remaining = remainingAutomaticRecoveredDataBootstrapBytes(
            checkpoint
        )
        guard remaining == 0 else {
            return .progressed(
                readBytes: scanResult.statistics.byteCount,
                remainingBytes: remaining
            )
        }
        onStage?("before_cache_install")
        guard shouldContinue() else {
            return .deferred(reason: "background_authority_revoked")
        }
        guard installAutomaticRecoveredDataBootstrapCache(
            checkpoint,
            shouldContinue: shouldContinue,
            onInstalled: {
                onStage?("after_bootstrap_cache_install")
            }
        ) else {
            guard shouldContinue() else {
                return .deferred(reason: "background_authority_revoked")
            }
            return .invalidated(reason: "completed_cache_install_failed")
        }
        return .ready(readBytes: scanResult.statistics.byteCount)
    }

    /// Metadata-only admission check for the automatic incremental freshness
    /// lane. This performs the same source selection and scanner planning as the
    /// real snapshot but opens/decodes no history rows. It must stay off-main.
    static func automaticRecoveredDataProjectionHasBoundedIncrementalPlan(
        since: Date,
        budget: RecoveredProjectionBudget = .automaticForeground,
        maximumIncrementalBytes: UInt64 =
            maximumAutomaticRecoveredDataIncrementalBytes
    ) -> Bool {
        precondition(
            !Thread.isMainThread,
            "Recovered projection admission metadata must run off the main thread"
        )
        let cutoff = since.timeIntervalSince1970
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: recentRecoveredReadableFileURLs(since: cutoff)
        )
        return automaticRecoveredDataProjectionHasBoundedIncrementalPlan(
            since: since,
            budget: budget,
            descriptors: descriptors,
            maximumIncrementalBytes: maximumIncrementalBytes
        )
    }

    /// Dependency-injected metadata seam for cold-process restoration tests.
    /// No source is opened or decoded.
    static func automaticRecoveredDataProjectionHasBoundedIncrementalPlan(
        since: Date,
        budget: RecoveredProjectionBudget = .automaticForeground,
        descriptors: [AtriaHistoricalJSONLRecentScanner.FileDescriptor],
        maximumIncrementalBytes: UInt64 =
            maximumAutomaticRecoveredDataIncrementalBytes
    ) -> Bool {
        let cutoff = since.timeIntervalSince1970
        recoveredDataCacheLock.lock()
        defer { recoveredDataCacheLock.unlock() }
        let cache = recoveredDataCache
        let reusableStates = cache.flatMap {
            $0.budget == budget && $0.coveredSince <= cutoff
                ? $0.fileStates
                : nil
        }
        return automaticRecoveredDataProjectionPlanIsBounded(
            AtriaHistoricalJSONLRecentScanner.plan(
                previousStates: reusableStates,
                current: descriptors
            ),
            maximumIncrementalBytes: maximumIncrementalBytes,
            allowsBoundedRebuild: cache == nil
        )
    }

    /// Performs the authoritative automatic-lane admission and the matching
    /// snapshot from one descriptor image. The private snapshot planner holds
    /// `recoveredDataCacheLock` from plan construction through materialization,
    /// and the scanner reads only through each captured descriptor's EOF. A
    /// source observed growing, disappearing, or being replaced after the
    /// notification's metadata preflight is therefore refused here before any
    /// row is decoded; a still-later append cannot enlarge this captured scan.
    /// `nil` means the durable input must wait for the guarded BGProcessing lane.
    static func makeAutomaticallyAdmittedRecoveredDataSnapshot(
        since: Date,
        budget: RecoveredProjectionBudget = .automaticForeground,
        maximumIncrementalBytes: UInt64 =
            maximumAutomaticRecoveredDataIncrementalBytes,
        decodedWorkBudget: RecoveredDecodedWorkBudget = .automaticForeground,
        executionShouldContinue: @escaping () -> Bool = { true },
        onScanProgress: ((AtriaHistoricalJSONLRecentScanner.Statistics) -> Void)? = nil
    ) -> RecoveredDataSnapshot? {
        precondition(
            !Thread.isMainThread,
            "Automatic recovered archive decoding must run off the main thread"
        )
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
            maximumAutomaticIncrementalBytes: maximumIncrementalBytes,
            decodedWorkBudget: decodedWorkBudget,
            backgroundProjectionLease: nil,
            executionShouldContinue: executionShouldContinue,
            onScanProgress: onScanProgress
        )
    }

#if DEBUG
    /// Dependency-injected worker seam for proving that a completed resumable
    /// bootstrap is immediately consumable by the same bounded automatic lane.
    /// Production callers always obtain descriptors from the archive catalog.
    static func makeAutomaticallyAdmittedRecoveredDataSnapshotForTesting(
        since: Date,
        descriptors: [AtriaHistoricalJSONLRecentScanner.FileDescriptor],
        maximumIncrementalBytes: UInt64 =
            maximumAutomaticRecoveredDataIncrementalBytes,
        decodedWorkBudget: RecoveredDecodedWorkBudget =
            .automaticForeground,
        executionShouldContinue: @escaping () -> Bool = { true },
        onDecodedWorkCount: ((Int, Int) -> Void)? = nil,
        onRetainedAggregateCount: ((Int) -> Void)? = nil,
        onStage: ((String) -> Void)? = nil
    ) -> RecoveredDataSnapshot? {
        precondition(
            !Thread.isMainThread,
            "Automatic recovered archive decoding must run off the main thread"
        )
        return makeRecoveredDataSnapshot(
            since: since,
            budget: .automaticForeground,
            descriptors: descriptors,
            started: DispatchTime.now().uptimeNanoseconds,
            maximumAutomaticIncrementalBytes: maximumIncrementalBytes,
            decodedWorkBudget: decodedWorkBudget,
            backgroundProjectionLease: nil,
            executionShouldContinue: executionShouldContinue,
            onDecodedWorkCount: onDecodedWorkCount,
            onRetainedAggregateCount: onRetainedAggregateCount,
            onStage: onStage,
            onScanProgress: nil
        )
    }
#endif

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
        // `maximumAutomaticIncrementalBytes` is nil, so this unrestricted
        // exact/background path cannot be refused by the private planner.
        return makeRecoveredDataSnapshot(
            since: since,
            budget: budget,
            descriptors: descriptors,
            started: started,
            maximumAutomaticIncrementalBytes: nil,
            backgroundProjectionLease: nil,
            onScanProgress: onScanProgress
        )!
    }

    /// Exact/manual foreground form. It retains the production evidence bounds
    /// but returns nil as soon as its sticky ticket authority is revoked.
    static func makeCancellableRecoveredDataSnapshot(
        since: Date,
        budget: RecoveredProjectionBudget = .production,
        executionShouldContinue: @escaping () -> Bool,
        onScanProgress:
            ((AtriaHistoricalJSONLRecentScanner.Statistics) -> Void)? = nil
    ) -> RecoveredDataSnapshot? {
        precondition(
            !Thread.isMainThread,
            "Recovered archive decoding must run off the main thread"
        )
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
            maximumAutomaticIncrementalBytes: nil,
            decodedWorkBudget: nil,
            backgroundProjectionLease: nil,
            executionShouldContinue: executionShouldContinue,
            onScanProgress: onScanProgress
        )
    }

    /// Cancellable form owned by one exact background-projection throttle
    /// generation. Scene activation, BGTask expiration, or budget expiry makes
    /// this return nil without publishing a partial recovered cache.
    static func makeBackgroundRecoveredDataSnapshot(
        since: Date,
        budget: RecoveredProjectionBudget = .production,
        lease: AtriaBackgroundProjectionThrottle.ActiveLease,
        onScanProgress:
            ((AtriaHistoricalJSONLRecentScanner.Statistics) -> Void)? = nil
    ) -> RecoveredDataSnapshot? {
        precondition(
            !Thread.isMainThread,
            "Background recovered archive decoding must run off the main thread"
        )
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
            maximumAutomaticIncrementalBytes: nil,
            decodedWorkBudget: nil,
            backgroundProjectionLease: lease,
            executionShouldContinue: {
                AtriaBackgroundProjectionThrottle.shared
                    .activeLeaseShouldContinue(lease)
            },
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
        // Bounded (was a whole-archive .load()): only the lightweight accepted
        // source list is needed to choose which sources to read; each
        // `reader.readSource` then window-loads its own dependency range.
        guard let streamed = aggregateReader.streamedWholeArchiveDigest(
            limits: AtriaHistoricalAggregateReader.LoadLimits.unboundedConsumerProjection
        ) else {
            return .init(committedSourceCount: 0,
                         attemptedSourceCount: 0,
                         deliveredSourceCount: 0,
                         wasBounded: true,
                         rejectedManifestCount: 0)
        }
        guard !streamed.diagnostics.limitExceeded,
              streamed.diagnostics.rejectedManifests == 0 else {
            return .init(committedSourceCount: streamed.diagnostics.acceptedAggregates,
                         attemptedSourceCount: 0,
                         deliveredSourceCount: 0,
                         wasBounded: streamed.diagnostics.limitExceeded,
                         rejectedManifestCount: streamed.diagnostics.rejectedManifests)
        }
        let sources = streamed.sources.sorted {
            if $0.lastTimestamp != $1.lastTimestamp {
                return $0.lastTimestamp > $1.lastTimestamp
            }
            return $0.chunkID < $1.chunkID
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
                consume(reader.readSource(chunkID: source.chunkID,
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
        // Test/retention callers exercise the unrestricted production path.
        return makeRecoveredDataSnapshot(
            since: since,
            budget: budget,
            descriptors: descriptors,
            started: started,
            maximumAutomaticIncrementalBytes: nil,
            backgroundProjectionLease: nil,
            onScanProgress: onScanProgress
        )!
    }

    private static func makeRecoveredDataSnapshot(
        since: Date,
        budget: RecoveredProjectionBudget,
        descriptors: [AtriaHistoricalJSONLRecentScanner.FileDescriptor],
        started: UInt64,
        maximumAutomaticIncrementalBytes: UInt64?,
        decodedWorkBudget: RecoveredDecodedWorkBudget? = nil,
        backgroundProjectionLease:
            AtriaBackgroundProjectionThrottle.ActiveLease?,
        executionShouldContinue: @escaping () -> Bool = { true },
        onDecodedWorkCount: ((Int, Int) -> Void)? = nil,
        onRetainedAggregateCount: ((Int) -> Void)? = nil,
        onStage: ((String) -> Void)? = nil,
        onScanProgress: ((AtriaHistoricalJSONLRecentScanner.Statistics) -> Void)?
    ) -> RecoveredDataSnapshot? {
        let cutoff = since.timeIntervalSince1970

        // A background lease has two distinct checks. `executionShouldContinue`
        // is the non-sleeping exact-generation authority used at admission and
        // immediately before publication. Archive-sized off-main transforms
        // additionally participate in the throttle's duty cycle at their
        // existing 256-element checkpoints. Foreground/manual callers have no
        // background lease, so this remains only their sticky authority poll.
        func transformShouldContinue() -> Bool {
            guard executionShouldContinue() else { return false }
            guard let backgroundProjectionLease else { return true }
            return !AtriaBackgroundProjectionThrottle.shared
                .cooperativeCheckpointShouldAbort(
                    lease: backgroundProjectionLease,
                    processedDelta: 256
                )
        }

        recoveredDataCacheLock.lock()
        defer { recoveredDataCacheLock.unlock() }

        guard executionShouldContinue() else { return nil }

        let hadRecoveredDataCache = recoveredDataCache != nil
        if let decodedWorkBudget,
           let cache = recoveredDataCache,
           !decodedWorkBudget.admitsRetainedCounts(
                heartRate: cache.heartRatePoints.count,
                rr: cache.rrAccumulator.acceptedRecordCount,
                skin: cache.skinTemperatureRawPoints.count,
                gravity: cache.gravitySamples.count,
                motionIdentities: cache.motionRecordIdentities.count
           ) {
            // O(1) automatic admission: never copy/prune/materialize a retained
            // million-row cache merely because its scanner plan says `.reuse`.
            return nil
        }
        var reusableCache: RecoveredDataCache?
        if let cache = recoveredDataCache,
           recoveredProjectionCacheBudgetIsReusable(
                cached: cache.budget,
                requested: budget,
                hasTruncatedChannels: !cache.truncatedChannels.isEmpty
           ),
           cache.coveredSince <= cutoff,
           maximumAutomaticIncrementalBytes != nil
                || cutoff - cache.coveredSince
                    <= recoveredDataCacheMaximumWindowDrift {
            guard let pruned = prunedRecoveredCache(
                cache,
                since: cutoff,
                shouldContinue: transformShouldContinue
            ) else { return nil }
            reusableCache = pruned
        }
        guard executionShouldContinue() else { return nil }
        let plan = AtriaHistoricalJSONLRecentScanner.plan(
            previousStates: reusableCache?.fileStates,
            current: descriptors
        )
        if let maximumAutomaticIncrementalBytes,
           !automaticRecoveredDataProjectionPlanIsBounded(
                plan,
                maximumIncrementalBytes: maximumAutomaticIncrementalBytes,
                allowsBoundedRebuild: !hadRecoveredDataCache
           ) {
            return nil
        }
        if case .reuse = plan, let reusableCache {
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            var limitations = recoveredBudgetLimitations(cache: reusableCache, budget: budget)
            for channel in reusableCache.truncatedChannels where limitations[channel] == nil {
                limitations[channel] = recoveredBudgetLimit(for: channel, budget: budget)
            }
            guard let snapshot = recoveredSnapshot(
                from: reusableCache,
                scan: .init(fileReadCount: 0,
                            byteCount: 0,
                            decodedRecordCount: 0,
                            elapsedMilliseconds: elapsed),
                limitations: limitations,
                includesCompleteScannerImage: true,
                shouldContinue: transformShouldContinue
            ) else { return nil }
            guard executionShouldContinue() else { return nil }
            // Retain only after cancellable RR/materialization completed. A
            // revoked ticket may not install even a pruned cache image.
            guard installRecoveredDataCacheWhileLocked(
                reusableCache,
                shouldContinue: executionShouldContinue,
                onInstalled: {
                    onStage?("after_recovered_cache_install")
                    Self.recordRetainedCacheFootprint(
                        reusableCache,
                        plan: "reuse",
                        shouldContinue: executionShouldContinue
                    )
                }
            ) else { return nil }
            return snapshot
        }

        var decodedRecordCount = 0
        let coveredSince = cutoff
        var heartRate = reusableCache?.heartRatePoints ?? []
        var rrAccumulator = reusableCache?.rrAccumulator
            ?? AtriaRecoveredRRProjection.Accumulator()
        var skinTemperatureRawPoints = reusableCache?.skinTemperatureRawPoints ?? []
        var gravity = reusableCache?.gravitySamples ?? []
        var motionRecordIdentities = reusableCache?.motionRecordIdentities ?? []
        // Strap identifiers repeat a handful of distinct values, and measured
        // strapIdMaxLen=36 exceeds the 15-byte small-string inline limit — so
        // every un-interned copy is its own heap allocation across the ~718K
        // retained skin points (2026-08-05 bounding design, Edit 3). Interning
        // is intra-scan only (verdict F5): points reused from the prior cache
        // keep their instances, and an incremental scan adds at most one new
        // instance per distinct value. The table dies with this call.
        var strapIdentifierIntern: [String: String] = [:]
        var truncatedChannels = reusableCache?.truncatedChannels ?? []
        var limitations = recoveredBudgetLimitations(
            heartRateCount: heartRate.count,
            rrRecordCount: rrAccumulator.acceptedRecordCount,
            skinTemperatureCount: skinTemperatureRawPoints.count,
            gravityCount: gravity.count,
            motionIdentityCount: motionRecordIdentities.count,
            budget: budget
        )
        for channel in truncatedChannels where limitations[channel] == nil {
            limitations[channel] = recoveredBudgetLimit(for: channel, budget: budget)
        }
        let sources: [AtriaHistoricalJSONLRecentScanner.Source]
        switch plan {
        case .reuse:
            sources = []
        case .incremental(let additions), .rebuild(let additions):
            sources = additions
        }
        if case .rebuild = plan {
            heartRate.removeAll(keepingCapacity: true)
            rrAccumulator = AtriaRecoveredRRProjection.Accumulator()
            skinTemperatureRawPoints.removeAll(keepingCapacity: true)
            gravity.removeAll(keepingCapacity: true)
            motionRecordIdentities.removeAll(keepingCapacity: true)
            // A rebuild starts from nothing: limitations seeded from the
            // pre-clear reused counts would silently block appends into the
            // now-empty arrays (pre-existing quirk, fixed 2026-08-04).
            truncatedChannels = []
            limitations = [:]
        }

        var pressureReliefCountdown = 16
        var lastThrottledCandidateCount = 0
        var candidateWorkCount = 0
        var decodedWorkBudgetExceeded = false
        func backgroundProjectionShouldContinue() -> Bool {
            executionShouldContinue()
                && !decodedWorkBudgetExceeded
                && !AtriaBackgroundProjectionThrottle.shared
                .cooperativeCheckpointShouldAbort(
                    lease: backgroundProjectionLease,
                    processedDelta: 0
                )
        }
        func scanProgressTick(_ statistics: AtriaHistoricalJSONLRecentScanner.Statistics) {
                // Footprint probe proved the scan accumulates ~1.4KB of
                // freed-but-dirty malloc pages per decoded line (3.4GB over a
                // ~125MB scan) while retained arrays stay tiny — the decode
                // churn never returns pages to the OS on its own. Ask malloc
                // to return free pages every ~1MB of input (2026-08-04).
                pressureReliefCountdown -= 1
                if pressureReliefCountdown <= 0 {
                    pressureReliefCountdown = 16
                    malloc_zone_pressure_relief(nil, 0)
                }
                // CPU duty-cycle for a BACKGROUND projection pass (2026-08-08):
                // projection throttled memory but never CPU, which tripped
                // cpu_resource_fatal on a long background run. This is a no-op in
                // the foreground / whenever no background pass armed the throttle,
                // so the live scan path is unchanged; when armed it sleeps this
                // (dying, off-main) snapshot thread to hold average CPU near 50%.
                let candidateDelta = max(0, statistics.candidateLineCount - lastThrottledCandidateCount)
                lastThrottledCandidateCount = statistics.candidateLineCount
                _ = AtriaBackgroundProjectionThrottle.shared
                    .cooperativeCheckpointShouldAbort(
                        lease: backgroundProjectionLease,
                        processedDelta: candidateDelta
                    )
                onScanProgress?(statistics)
        }
        func consumeScanCandidate(_ lineData: Data) {
            guard !decodedWorkBudgetExceeded else { return }
            candidateWorkCount += 1
            onDecodedWorkCount?(candidateWorkCount, decodedRecordCount)
            if let decodedWorkBudget,
               candidateWorkCount > decodedWorkBudget.maximumCandidateLines {
                decodedWorkBudgetExceeded = true
                return
            }
            // Foundation JSON is banned from this hot path: decode-only
            // bisects proved BOTH JSONDecoder and JSONSerialization retain
            // live memory per parse on iOS 27.0 beta (~2.6GB per scan,
            // surviving per-line/per-chunk pools and instance recycling —
            // they share swift-foundation's JSON engine there).
            // Record(scanLine:) is a hand-rolled byte parser; parity with
            // JSONDecoder enforced by AtriaRecordScanParserParityTests.
            guard let record = Record(scanLine: lineData) else { return }
            decodedRecordCount += 1
            onDecodedWorkCount?(candidateWorkCount, decodedRecordCount)
            if let decodedWorkBudget,
               decodedRecordCount > decodedWorkBudget.maximumDecodedRecords {
                decodedWorkBudgetExceeded = true
                return
            }
            if let decodedWorkBudget {
                let counts = [
                    heartRate.count,
                    rrAccumulator.acceptedRecordCount,
                    skinTemperatureRawPoints.count,
                    gravity.count,
                    motionRecordIdentities.count,
                ]
                // A single physical row can add at most one element to each
                // retained channel. Refuse it before decoding its payload when
                // that worst-case append could cross the declared hard total;
                // automatic work may be conservative but can never overshoot.
                guard counts.allSatisfy({
                    $0 < decodedWorkBudget.maximumRetainedChannelElements
                }), counts.reduce(0, +)
                    <= decodedWorkBudget.maximumRetainedAggregateElements - 5
                else {
                    decodedWorkBudgetExceeded = true
                    return
                }
            }
            appendRecoveredRecord(record,
                                  cutoff: coveredSince,
                                  budget: budget,
                                  limitations: &limitations,
                                  heartRate: &heartRate,
                                  rrAccumulator: &rrAccumulator,
                                  skinTemperatureRawPoints: &skinTemperatureRawPoints,
                                  gravity: &gravity,
                                  motionRecordIdentities: &motionRecordIdentities,
                                  strapIdentifierIntern: &strapIdentifierIntern,
                                  skipMotion: false,
                                  skipRR: false,
                                  skipSkin: false)
            onRetainedAggregateCount?(
                heartRate.count
                    + rrAccumulator.acceptedRecordCount
                    + skinTemperatureRawPoints.count
                    + gravity.count
                    + motionRecordIdentities.count
            )
            if let decodedWorkBudget,
               !decodedWorkBudget.admitsRetainedCounts(
                    heartRate: heartRate.count,
                    rr: rrAccumulator.acceptedRecordCount,
                    skin: skinTemperatureRawPoints.count,
                    gravity: gravity.count,
                    motionIdentities: motionRecordIdentities.count
               ) {
                // Fresh and incremental automatic scans obey the same total
                // decoded-work contract as retained-cache reuse. Stop on the
                // first record that crosses it, before any sort, snapshot, or
                // cache publication can walk the accumulated image.
                decodedWorkBudgetExceeded = true
            }
        }
        // BUDGETED PASSES (2026-08-04, the balloon's architectural fix): the
        // 3-way append bisect proved every per-line lane contributes transient
        // garbage that accumulates ~1:1 into phys_footprint for as long as the
        // scan runs continuously — the iOS 27 beta allocator reclaims nothing
        // until the scan machinery unwinds (decode-and-discard released its
        // full ~2GB only AFTER rec_scan_done). So never run the archive in one
        // continuous stretch: scan in resumable ~160MB slices and unwind
        // between them, making peak memory per-pass instead of per-archive.
        // 32MB, not more: the candidate-dense region generates ~15KB of
        // transient garbage per KB read (a 168MB pass ballooned 587→2573MB
        // on-device, 2026-08-04) — the budget must bound the DENSE-region
        // pass, and sparse-region passes just run more often.
        let passByteBudget = 32 * 1024 * 1024
        let maximumPasses = 256
        var remainingSources = sources
        var priorPassStatistics = AtriaHistoricalJSONLRecentScanner.Statistics()
        var mergedScanStates: [String: AtriaHistoricalJSONLRecentScanner.FileState] = [:]
        var scanComplete = true
        var passIndex = 0
        while !remainingSources.isEmpty {
            guard backgroundProjectionShouldContinue() else { return nil }
            passIndex += 1
            let passBase = priorPassStatistics
            // Each pass runs on a THREAD THAT DIES at pass end: the on-device
            // evidence (decode-only releasing its full ~2GB only after the
            // work item finished; a mid-loop nap reclaiming almost nothing)
            // says the beta allocator returns this garbage when the worker
            // thread's malloc magazine is torn down — not at autoreleasepool
            // drains, not at malloc_zone_pressure_relief, not on a sleep.
            // Sequential handoff via semaphore: no concurrent access to the
            // captured accumulator state.
            var passResult = AtriaHistoricalJSONLRecentScanner.Result(
                states: [:],
                statistics: .init(),
                complete: false)
            let passDone = DispatchSemaphore(value: 0)
            let passSources = remainingSources
            let passThread = Thread {
                passResult = autoreleasepool {
                    AtriaHistoricalJSONLRecentScanner.scan(
                        sources: passSources,
                        cutoff: coveredSince,
                        byteBudget: passByteBudget,
                        onProgress: { passStatistics in
                            // Callers renew inactivity leases from a MONOTONIC
                            // byte count; pass-local statistics restart at
                            // zero, so re-base onto completed passes' totals.
                            var statistics = passStatistics
                            statistics.byteCount += passBase.byteCount
                            statistics.fileReadCount += passBase.fileReadCount
                            statistics.lineCount += passBase.lineCount
                            statistics.candidateLineCount += passBase.candidateLineCount
                            scanProgressTick(statistics)
                        },
                        shouldContinue: backgroundProjectionShouldContinue,
                        consumeCandidate: consumeScanCandidate)
                }
                passDone.signal()
            }
            passThread.name = "atria.recovered-scan.pass\(passIndex)"
            passThread.qualityOfService = .userInitiated
            passThread.start()
            passDone.wait()
            guard !passResult.cancelled,
                  backgroundProjectionShouldContinue() else { return nil }
            passResult.states.forEach { mergedScanStates[$0.key] = $0.value }
            priorPassStatistics.byteCount += passResult.statistics.byteCount
            priorPassStatistics.fileReadCount += passResult.statistics.fileReadCount
            priorPassStatistics.lineCount += passResult.statistics.lineCount
            priorPassStatistics.candidateLineCount += passResult.statistics.candidateLineCount
            if !passResult.exhaustedByteBudget {
                scanComplete = passResult.complete
                break
            }
            remainingSources = remainingSources.compactMap { source in
                guard let state = mergedScanStates[source.descriptor.path] else {
                    return source  // untouched this pass
                }
                guard !source.descriptor.isCompressed else {
                    // Compressed sources are all-or-nothing; a state entry
                    // means the whole file was consumed.
                    return nil
                }
                guard state.processedOffset < source.descriptor.size else { return nil }
                return AtriaHistoricalJSONLRecentScanner.Source(
                    descriptor: source.descriptor,
                    startOffset: state.processedOffset)
            }
            guard passIndex < maximumPasses else {
                scanComplete = false
                break
            }
            // Adaptive unwind wait: give the dead pass thread's magazine
            // teardown time to actually return pages before the next burst.
            // Bounded — progress beats a stall if reclaim never comes.
            let unwindDeadline = Date().addingTimeInterval(2.0)
            var footprint = Self.currentPhysFootprintBytes()
            while footprint > 900 * 1024 * 1024, Date() < unwindDeadline {
                guard backgroundProjectionShouldContinue() else { return nil }
                usleep(120_000)
                footprint = Self.currentPhysFootprintBytes()
            }
        }
        guard backgroundProjectionShouldContinue(),
              !decodedWorkBudgetExceeded else { return nil }
        let scanResult = AtriaHistoricalJSONLRecentScanner.Result(
            states: mergedScanStates,
            statistics: priorPassStatistics,
            complete: scanComplete)
        guard executionShouldContinue() else { return nil }
        onStage?("before_recovered_sort")
        guard sortRecoveredData(
            heartRate: &heartRate,
            skinTemperatureRawPoints: &skinTemperatureRawPoints,
            gravity: &gravity,
            shouldContinue: transformShouldContinue
        ) else { return nil }
        onStage?("after_recovered_sort")

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
                                       rrAccumulator: rrAccumulator,
                                       skinTemperatureRawPoints: skinTemperatureRawPoints,
                                       gravitySamples: gravity,
                                       motionRecordIdentities: motionRecordIdentities,
                                       truncatedChannels: truncatedChannels
                                           .union(limitations.keys))
        if maximumAutomaticIncrementalBytes != nil,
           (!limitations.isEmpty || !cache.truncatedChannels.isEmpty) {
            // Automatic work never installs a partial cache. The caller retains
            // the durable bootstrap intent for a separately leased BG pass.
            return nil
        }
        guard executionShouldContinue() else { return nil }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        guard let snapshot = recoveredSnapshot(
            from: cache,
            scan: .init(fileReadCount: scanResult.statistics.fileReadCount,
                        byteCount: scanResult.statistics.byteCount,
                        decodedRecordCount: decodedRecordCount,
                        elapsedMilliseconds: elapsed),
            limitations: limitations,
            includesCompleteScannerImage: scanResult.complete,
            shouldContinue: transformShouldContinue
        ) else { return nil }
        guard executionShouldContinue() else { return nil }
        if scanResult.complete {
            // Retain even when a channel capped: `truncatedChannels` keeps that
            // channel reporting budgetExceeded after pruning (so a narrower
            // window can never look complete — the concern that used to force
            // `recoveredDataCache = nil`), while every complete channel stays
            // incremental instead of paying a full-archive rebuild scan on the
            // next recompute (the 3.45GB jetsam amplifier, 2026-08-04).
            guard installRecoveredDataCacheWhileLocked(
                cache,
                shouldContinue: executionShouldContinue,
                onInstalled: {
                    onStage?("after_recovered_cache_install")
                    Self.recordRetainedCacheFootprint(
                        cache,
                        plan: "scan",
                        shouldContinue: executionShouldContinue
                    )
                }
            ) else { return nil }
        } else {
            // A truncated FILE READ leaves fileStates untrustworthy; only this
            // case still discards the cache.
            _ = replaceRecoveredDataCacheWhileLocked(with: nil)
        }

        return snapshot
    }

    private static func appendRecoveredRecord(
        _ record: Record,
        cutoff: TimeInterval,
        budget: RecoveredProjectionBudget,
        limitations: inout [RecoveredDataCompleteness.Channel: Int],
        heartRate: inout [HeartRatePoint],
        rrAccumulator: inout AtriaRecoveredRRProjection.Accumulator,
        skinTemperatureRawPoints: inout [SkinTemperatureRawPoint],
        gravity: inout [GravitySample],
        motionRecordIdentities: inout Set<AtriaRecoveredMotionReplayIdentity>,
        strapIdentifierIntern: inout [String: String],
        // TEMPORARY bisect levers (2026-08-04 footprint hunt): each skips
        // exactly one append subsystem so a device run can name the lane
        // whose transient garbage ignites the balloon. Remove with the
        // memprobe.
        skipMotion: Bool = false,
        skipRR: Bool = false,
        skipSkin: Bool = false
    ) {
        let unix = record.clockCorrectedUnix7 ?? record.unix7
        guard unix > 0, record.subsec11 < 32_768 else { return }
        let timestamp = TimeInterval(unix) + TimeInterval(record.subsec11) / 32_768
        guard timestamp >= cutoff else { return }
        // One hex decode per record, shared by every consumer below —
        // gravity and skin-temperature previously each re-decoded the
        // payload per line (2026-08-04 scan-garbage fix).
        let payload = bytes(fromHex: record.rawPayloadHex)
        let motionAlreadyLimited = limitations[.motionReplayIdentity] != nil
            || limitations[.gravity] != nil
        if !motionAlreadyLimited, !skipMotion {
            let motionIdentity = AtriaRecoveredMotionReplayIdentity(record: record)
            if !motionRecordIdentities.contains(motionIdentity) {
                if motionRecordIdentities.count >= budget.maximumMotionReplayIdentities {
                    limitations[.motionReplayIdentity] = budget.maximumMotionReplayIdentities
                } else if let sample = gravitySample(from: record, payload: payload) {
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
        if !skipSkin,
           let raw = whoop4SkinTemperatureRaw(from: record, payload: payload),
           limitations[.skinTemperature] == nil {
            if skinTemperatureRawPoints.count >= budget.maximumSkinTemperaturePoints {
                limitations[.skinTemperature] = budget.maximumSkinTemperaturePoints
            } else {
                skinTemperatureRawPoints.append(.init(
                    t: Date(timeIntervalSince1970: timestamp),
                    raw: raw,
                    strapIdentifier: internedStrapIdentifier(
                        record.strapIdentifier, in: &strapIdentifierIntern)
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
        if record.whoofRRNum18 > 0, !skipRR {
            if limitations[.rrRecords] == nil {
                if rrAccumulator.acceptedRecordCount >= budget.maximumRRRecords {
                    limitations[.rrRecords] = budget.maximumRRRecords
                } else {
                    // Verify-at-ingest: rejected rows no longer consume the
                    // budget (previously every whoofRRNum18>0 row counted,
                    // verified or not), so the cap now measures retained
                    // verified records only.
                    rrAccumulator.ingest(record)
                }
            }
        }
    }

    /// Nil-preserving: `Record.strapIdentifier` is Optional and interning
    /// must never invent or drop a value — only alias byte-equal copies.
    private static func internedStrapIdentifier(
        _ value: String?,
        in intern: inout [String: String]
    ) -> String? {
        guard let value else { return nil }
        if let canonical = intern[value] { return canonical }
        intern[value] = value
        return value
    }

    private static func sortRecoveredData(
        heartRate: inout [HeartRatePoint],
        skinTemperatureRawPoints: inout [SkinTemperatureRawPoint],
        gravity: inout [GravitySample],
        shouldContinue: () -> Bool
    ) -> Bool {
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &heartRate,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: {
            if $0.t != $1.t { return $0.t < $1.t }
            return $0.bpm < $1.bpm
        }) else { return false }
        // RR needs no sort pass here: Accumulator.finish() emits beats in the
        // projection's canonical deterministic order.
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &skinTemperatureRawPoints,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: { $0.t < $1.t }
        ) else { return false }
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &gravity,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.sequence < $1.sequence
        }) else { return false }
        return shouldContinue()
    }

    private static func whoop4SkinTemperatureRaw(from record: Record,
                                                 payload: [UInt8]?) -> Int? {
        guard record.layoutVersion == layoutVersion(for: 24),
              record.gravityValidated,
              let payload,
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
        prunedRecoveredCache(
            cache,
            since: cutoff,
            shouldContinue: { true }
        )!
    }

    private static func prunedRecoveredCache(
        _ cache: RecoveredDataCache,
        since cutoff: TimeInterval,
        shouldContinue: () -> Bool
    ) -> RecoveredDataCache? {
        guard shouldContinue() else { return nil }
        var prunedRR = cache.rrAccumulator
        guard prunedRR.prune(
            before: cutoff,
            shouldContinue: shouldContinue
        ) else { return nil }
        func retained<Value>(
            _ values: [Value],
            where predicate: (Value) -> Bool
        ) -> [Value]? {
            var result: [Value] = []
            result.reserveCapacity(values.count)
            for (index, value) in values.enumerated() {
                if index.isMultiple(of: 256), !shouldContinue() {
                    return nil
                }
                if predicate(value) { result.append(value) }
            }
            return shouldContinue() ? result : nil
        }
        guard let heartRate = retained(cache.heartRatePoints, where: {
                  $0.t.timeIntervalSince1970 >= cutoff
              }),
              let skin = retained(cache.skinTemperatureRawPoints, where: {
                  $0.t.timeIntervalSince1970 >= cutoff
              }),
              let gravity = retained(cache.gravitySamples, where: {
                  $0.timestamp >= cutoff
              }) else { return nil }
        var motion = Set<AtriaRecoveredMotionReplayIdentity>()
        motion.reserveCapacity(cache.motionRecordIdentities.count)
        for (index, identity) in cache.motionRecordIdentities.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() {
                return nil
            }
            if identity.projectedTimestamp >= cutoff {
                motion.insert(identity)
            }
        }
        guard shouldContinue() else { return nil }
        return RecoveredDataCache(
            coveredSince: cutoff,
            budget: cache.budget,
            fileStates: cache.fileStates,
            heartRatePoints: heartRate,
            rrAccumulator: prunedRR,
            skinTemperatureRawPoints: skin,
            gravitySamples: gravity,
            motionRecordIdentities: motion,
            truncatedChannels: cache.truncatedChannels
        )
    }

    @discardableResult
    private static func replaceRecoveredDataCacheWhileLocked(
        with cache: RecoveredDataCache?
    ) -> RecoveredDataCacheInstallOwnership? {
        recoveredDataCacheMutationGeneration &+= 1
        recoveredDataCache = cache
        guard cache != nil else {
            recoveredDataCacheInstallOwnership = nil
            return nil
        }
        let ownership = RecoveredDataCacheInstallOwnership(
            generation: recoveredDataCacheMutationGeneration,
            authorityTag: UUID()
        )
        recoveredDataCacheInstallOwnership = ownership
        return ownership
    }

    private static func rollbackRecoveredDataCacheInstallWhileLocked(
        ownedBy ownership: RecoveredDataCacheInstallOwnership
    ) {
        guard recoveredDataCacheInstallOwnership == ownership else { return }
        _ = replaceRecoveredDataCacheWhileLocked(with: nil)
    }

    /// Used by ordinary projection, whose planner intentionally holds the cache
    /// lock from source planning through publication. The post-assignment
    /// authority check is paired with ownership-scoped rollback; returning false
    /// can therefore never leave this revoked image reusable.
    private static func installRecoveredDataCacheWhileLocked(
        _ cache: RecoveredDataCache,
        shouldContinue: () -> Bool,
        onInstalled: () -> Void
    ) -> Bool {
        guard shouldContinue(),
              let ownership = replaceRecoveredDataCacheWhileLocked(with: cache)
        else { return false }
        onInstalled()
        guard recoveredDataCacheInstallOwnership == ownership,
              shouldContinue() else {
            rollbackRecoveredDataCacheInstallWhileLocked(ownedBy: ownership)
            return false
        }
        return true
    }

    /// Bootstrap does not own the ordinary planner's long-lived lock, so hold
    /// the cache lock across assignment, test seam, footprint edge, and final
    /// authority validation. No concurrent consumer can derive a snapshot from
    /// a provisional image that this exact owner is about to roll back.
    private static func installRecoveredDataCacheAtomically(
        _ cache: RecoveredDataCache,
        shouldContinue: () -> Bool,
        onInstalled: () -> Void
    ) -> Bool {
        recoveredDataCacheLock.lock()
        defer { recoveredDataCacheLock.unlock() }
        return installRecoveredDataCacheWhileLocked(
            cache,
            shouldContinue: shouldContinue,
            onInstalled: onInstalled
        )
    }

    /// Working-set breadcrumb (2026-08-05, bounding design Edit 0): retained
    /// cache counts + phys footprint, written to the PULLABLE prefs channel
    /// (console/AtriaDebugLog is launch-arg-gated and unreachable via
    /// devicectl — the July-gap saga's lesson). Overwritten per publish;
    /// bounded. This is the go/no-go measurement gating compaction Edits 1-3
    /// (verdict F1: attribution must be measured, not assumed) and stays in
    /// as the regression tripwire afterward.
    private static func recordRetainedCacheFootprint(
        _ cache: RecoveredDataCache,
        plan: String,
        shouldContinue: () -> Bool
    ) {
        guard shouldContinue() else { return }
        let line = "plan=\(plan) hr=\(cache.heartRatePoints.count)"
            + " rrRecords=\(cache.rrAccumulator.acceptedRecordCount)"
            + " skin=\(cache.skinTemperatureRawPoints.count)"
            + " grav=\(cache.gravitySamples.count)"
            + " motionIDs=\(cache.motionRecordIdentities.count)"
            + " physMB=\(currentPhysFootprintBytes() / (1024 * 1024))"
            + " at=\(Int(Date().timeIntervalSince1970))"
        guard shouldContinue() else { return }
        UserDefaults.standard.set(
            line, forKey: "atria.debug.recoveredCacheFootprint.v1"
        )
    }

    /// phys_footprint — the metric jetsam enforces. Used by the budgeted
    /// scan's adaptive unwind wait (permanent architecture, 2026-08-04/05).
    static func currentPhysFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    private static func recoveredBudgetLimit(
        for channel: RecoveredDataCompleteness.Channel,
        budget: RecoveredProjectionBudget
    ) -> Int {
        switch channel {
        case .heartRate: return budget.maximumHeartRatePoints
        case .rrRecords: return budget.maximumRRRecords
        case .skinTemperature: return budget.maximumSkinTemperaturePoints
        case .gravity: return budget.maximumGravitySamples
        case .motionReplayIdentity: return budget.maximumMotionReplayIdentities
        }
    }

    private static let recoveredBudgetChannelOrder: [RecoveredDataCompleteness.Channel] = [
        .heartRate, .rrRecords, .skinTemperature, .gravity, .motionReplayIdentity
    ]

    private static func recoveredBudgetLimitations(
        cache: RecoveredDataCache,
        budget: RecoveredProjectionBudget
    ) -> [RecoveredDataCompleteness.Channel: Int] {
        recoveredBudgetLimitations(heartRateCount: cache.heartRatePoints.count,
                                   rrRecordCount: cache.rrAccumulator.acceptedRecordCount,
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
        limitations: [RecoveredDataCompleteness.Channel: Int],
        includesCompleteScannerImage: Bool = false,
        shouldContinue: () -> Bool = { true }
    ) -> RecoveredDataSnapshot? {
        guard shouldContinue(),
              let rrProjection = cache.rrAccumulator.finish(
                shouldContinue: shouldContinue
              ),
              shouldContinue() else { return nil }
        let orderedLimitations = recoveredBudgetChannelOrder.compactMap { channel in
            limitations[channel].map {
                RecoveredDataBudgetLimitation(channel: channel, limit: $0)
            }
        }
        let motionCompleteness = recoveredCompleteness(
            limitations: limitations,
            channels: [.gravity, .motionReplayIdentity]
        )
        guard shouldContinue() else { return nil }
        return .init(heartRatePoints: cache.heartRatePoints,
                     rrProjection: rrProjection,
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
                     budgetLimitations: orderedLimitations,
                     automaticCacheAuthority:
                        includesCompleteScannerImage
                            ? automaticRecoveredDataCacheAuthority(
                                from: cache,
                                limitations: limitations
                              )
                            : nil)
    }

    /// Builds authority from the cache's scanner offsets, never from a later
    /// filesystem stat. This keeps the persisted UI image and its source cursor
    /// exactly paired even when a writer appends between scan EOF and the
    /// asynchronous checkpoint write.
    private static func automaticRecoveredDataCacheAuthority(
        from cache: RecoveredDataCache,
        limitations: [RecoveredDataCompleteness.Channel: Int]
    ) -> AutomaticRecoveredDataCacheAuthority? {
        guard (cache.budget == .production
                || cache.budget == .automaticForeground),
              cache.coveredSince.isFinite,
              limitations.isEmpty,
              cache.truncatedChannels.isEmpty,
              !cache.fileStates.isEmpty,
              cache.fileStates.count
                <= maximumAutomaticRecoveredDataCacheAuthoritySourceCount else {
            return nil
        }
        let sources: [AutomaticRecoveredDataCacheAuthority.Source] = cache
            .fileStates.values.compactMap { state in
                guard let identifier = state.resourceIdentifier else {
                    return nil
                }
                return .init(
                    path: state.path,
                    processedOffset: state.processedOffset,
                    modificationTime: state.modificationTime,
                    resourceIdentifier: identifier
                )
            }
            .sorted { $0.path < $1.path }
        guard sources.count == cache.fileStates.count else { return nil }
        let authority = AutomaticRecoveredDataCacheAuthority(
            version: AutomaticRecoveredDataCacheAuthority.schema,
            coveredSince: cache.coveredSince,
            sources: sources
        )
        // Validate the compact form itself against an exact-EOF descriptor
        // image. Later descriptors may only preserve this reuse plan or turn it
        // into a separately bounded append plan.
        let descriptors = sources.map { source in
            AtriaHistoricalJSONLRecentScanner.FileDescriptor(
                url: URL(fileURLWithPath: source.path),
                size: source.processedOffset,
                modificationTime: source.modificationTime,
                resourceIdentifier: source.resourceIdentifier
            )
        }
        guard automaticRecoveredDataCacheAuthorityRestorationPlan(
            authority,
            since: Date(timeIntervalSince1970: cache.coveredSince),
            descriptors: descriptors
        ) != nil else { return nil }
        return authority
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
        var rrAccumulator = AtriaRecoveredRRProjection.Accumulator()
        var skinTemperatureRawPoints: [SkinTemperatureRawPoint] = []
        var gravity: [GravitySample] = []
        var motionRecordIdentities = Set<AtriaRecoveredMotionReplayIdentity>()
        var strapIdentifierIntern: [String: String] = [:]
        var limitations: [RecoveredDataCompleteness.Channel: Int] = [:]
        for record in records {
            appendRecoveredRecord(record,
                                  cutoff: cutoff,
                                  budget: budget,
                                  limitations: &limitations,
                                  heartRate: &heartRate,
                                  rrAccumulator: &rrAccumulator,
                                  skinTemperatureRawPoints: &skinTemperatureRawPoints,
                                  gravity: &gravity,
                                  motionRecordIdentities: &motionRecordIdentities,
                                  strapIdentifierIntern: &strapIdentifierIntern)
        }
        _ = sortRecoveredData(
            heartRate: &heartRate,
            skinTemperatureRawPoints: &skinTemperatureRawPoints,
            gravity: &gravity,
            shouldContinue: { true }
        )
        let cache = RecoveredDataCache(coveredSince: cutoff,
                                       budget: budget,
                                       fileStates: [:],
                                       heartRatePoints: heartRate,
                                       rrAccumulator: rrAccumulator,
                                       skinTemperatureRawPoints: skinTemperatureRawPoints,
                                       gravitySamples: gravity,
                                       motionRecordIdentities: motionRecordIdentities,
                                       truncatedChannels: Set(limitations.keys))
        return recoveredSnapshot(
            from: cache,
            scan: .init(fileReadCount: 0,
                        byteCount: 0,
                        decodedRecordCount: records.count,
                        elapsedMilliseconds: 0),
            limitations: limitations
        )!
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
        let requestStartedAt = Date()
        let candidates = recentReadableFileURLs()
        let catalog = (try? catalogStoreLocked()).flatMap { try? $0.snapshot() }
        // Warm repeat-navigation path: any archive mutation changes the
        // fingerprint (paths/sizes/mtimes/catalog generation) so a stale hit
        // is structurally impossible.
        let fingerprint = makeConsumerSourceFingerprint(
            catalogGeneration: catalog?.generation,
            descriptors: AtriaHistoricalJSONLRecentScanner.descriptors(for: candidates)
        )
        var fingerprintHasher = Hasher()
        if let encoded = try? JSONEncoder().encode(fingerprint) {
            fingerprintHasher.combine(encoded)
        }
        let cacheKey = HeartRateWindowResultCache.Key(
            startUnix: start.timeIntervalSince1970,
            endUnix: end.timeIntervalSince1970,
            fingerprintHash: fingerprintHasher.finalize(),
            readerVersion: HeartRateChunkIndex.readerVersion
        )
        if let cached = HeartRateWindowResultCache.value(for: cacheKey) {
            AtriaDebugLog("ATRIADBG hr_window_read status=cache_hit elapsed_ms=%d points=%d",
                          Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                          cached.points.count)
            return cached
        }
        var diagnostics = HeartRateWindowReadDiagnostics(
            startUnix: start.timeIntervalSince1970,
            endUnix: end.timeIntervalSince1970,
            elapsedMilliseconds: 0,
            candidateFileCount: candidates.count,
            trustedOutsideWindowSkipped: 0,
            selectedFileCount: 0,
            scannedFileCount: 0,
            scannedByteCount: 0,
            scannedLineCount: 0,
            heartRateCandidateLineCount: 0,
            inWindowPointCount: 0,
            catalogGeneration: catalog?.generation ?? 0,
            catalogChunkCount: catalog?.chunks.count ?? 0,
            terminal: "unset"
        )
        let read = exactMetricHeartRatePoints(
            in: candidates,
            catalog: catalog,
            archiveRoot: archiveDirectory,
            start: start,
            end: end,
            maximumPoints: maximumPoints,
            diagnostics: &diagnostics
        )
        diagnostics.elapsedMilliseconds = Int(
            Date().timeIntervalSince(requestStartedAt) * 1_000
        )
        diagnostics.terminal = read == nil
            ? "incomplete"
            : (read?.points.isEmpty == true ? "empty" : "points")
        diagnostics.persistToRing()
        if let read {
            HeartRateWindowResultCache.install(read, for: cacheKey)
        }
        AtriaDebugLog("ATRIADBG hr_window_read elapsed_ms=%d candidates=%d skipped=%d selected=%d bytes=%d lines=%d hr_lines=%d points=%d terminal=%@",
                      diagnostics.elapsedMilliseconds,
                      diagnostics.candidateFileCount,
                      diagnostics.trustedOutsideWindowSkipped,
                      diagnostics.selectedFileCount,
                      diagnostics.scannedByteCount,
                      diagnostics.scannedLineCount,
                      diagnostics.heartRateCandidateLineCount,
                      diagnostics.inWindowPointCount,
                      diagnostics.terminal)
        return read
    }

    static func exactMetricHeartRatePoints(
        in candidates: [URL],
        catalog: AtriaHistoricalArchiveCatalog?,
        archiveRoot: URL,
        start: Date,
        end: Date,
        maximumPoints: Int,
        fileManager: FileManager = .default
    ) -> HeartRateWindowRead? {
        var diagnostics = HeartRateWindowReadDiagnostics(
            startUnix: 0, endUnix: 0, elapsedMilliseconds: 0,
            candidateFileCount: 0, trustedOutsideWindowSkipped: 0,
            selectedFileCount: 0, scannedFileCount: 0, scannedByteCount: 0,
            scannedLineCount: 0, heartRateCandidateLineCount: 0,
            inWindowPointCount: 0, catalogGeneration: 0,
            catalogChunkCount: 0, terminal: "unset"
        )
        return exactMetricHeartRatePoints(
            in: candidates,
            catalog: catalog,
            archiveRoot: archiveRoot,
            start: start,
            end: end,
            maximumPoints: maximumPoints,
            fileManager: fileManager,
            diagnostics: &diagnostics
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
        fileManager: FileManager = .default,
        diagnostics: inout HeartRateWindowReadDiagnostics
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
        diagnostics.trustedOutsideWindowSkipped = candidates.count - selected.count
        diagnostics.selectedFileCount = selected.count
        guard selected.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            return nil
        }

        // Per-file processing (handoff-8 CP1): a sealed, digested chunk with
        // a binding-valid sidecar is served from ~1 MB of sorted HR rows; a
        // sealed chunk WITHOUT one pays the raw scan exactly once and leaves
        // a sidecar behind (built from the same pass, best effort). Active,
        // legacy, digestless, or mismatch cases stay on the conservative raw
        // scan — the sidecar is an accelerator, never a second truth source.
        let canonicalRoot = archiveRoot.standardizedFileURL
        let chunksByCanonicalPath: [String: [AtriaHistoricalArchiveCatalog.RawChunk]]
        if let catalog {
            chunksByCanonicalPath = Dictionary(grouping: catalog.chunks) { chunk in
                canonicalRoot.appendingPathComponent(chunk.relativePath)
                    .standardizedFileURL.path
            }
        } else {
            chunksByCanonicalPath = [:]
        }

        var points: [HeartRatePoint] = []
        let durationCapacity = Int(min(Double(maximumPoints),
                                       max(2, end.timeIntervalSince(start) + 1)))
        points.reserveCapacity(durationCapacity)
        var overflowed = false
        var scannedLines = 0
        var heartRateLines = 0
        var scannedFiles = 0
        var scannedBytes = 0

        func rawScan(_ url: URL,
                     collectAllRows: Bool) -> (windowRows: [HeartRatePoint],
                                               allRows: [HeartRatePoint])? {
            let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(for: [url])
            guard !descriptors.isEmpty else { return nil }
            var windowRows: [HeartRatePoint] = []
            var allRows: [HeartRatePoint] = []
            let result = AtriaHistoricalJSONLRecentScanner.scan(
                sources: descriptors.map { .init(descriptor: $0, startOffset: 0) },
                // Current-session rows may need capturedAt correction, so raw
                // unix is not a safe lower-bound prefilter here.
                cutoff: 0
            ) { line in
                scannedLines += 1
                guard let text = String(data: line, encoding: .utf8),
                      let point = fastHeartRatePoint(from: text) else { return }
                heartRateLines += 1
                if collectAllRows { allRows.append(point) }
                guard point.t >= start, point.t < end else { return }
                windowRows.append(point)
            }
            scannedFiles += result.statistics.fileReadCount
            scannedBytes += result.statistics.byteCount
            guard result.complete else { return nil }
            return (windowRows, allRows)
        }

        for url in selected {
            let canonicalPath = url.standardizedFileURL.path
            let matching = chunksByCanonicalPath[canonicalPath] ?? []
            if matching.count == 1,
               let chunk = matching.first,
               chunk.state == .sealed,
               chunk.contentSHA256 != nil {
                let sidecarURL = heartRateSidecarURL(
                    forChunkRelativePath: chunk.relativePath,
                    archiveRoot: canonicalRoot
                )
                if validHeartRateSidecarBinding(sidecarURL: sidecarURL,
                                                chunk: chunk,
                                                fileManager: fileManager) != nil,
                   let sidecarPoints = sidecarHeartRatePoints(
                    sidecarURL: sidecarURL,
                    start: start,
                    end: end,
                    maximumPoints: max(1, maximumPoints - points.count)
                   ) {
                    heartRateLines += sidecarPoints.count
                    points.append(contentsOf: sidecarPoints)
                    if points.count >= maximumPoints { overflowed = true; break }
                    continue
                }
                // First touch of this sealed chunk: one raw scan, sidecar
                // written from the same pass so it never scans again.
                guard let scanned = rawScan(url, collectAllRows: true) else {
                    return nil
                }
                writeHeartRateSidecar(rows: scanned.allRows,
                                      chunk: chunk,
                                      archiveRoot: canonicalRoot,
                                      fileManager: fileManager)
                points.append(contentsOf: scanned.windowRows)
            } else {
                guard let scanned = rawScan(url, collectAllRows: false) else {
                    return nil
                }
                points.append(contentsOf: scanned.windowRows)
            }
            if points.count >= maximumPoints { overflowed = true; break }
        }

        diagnostics.scannedLineCount = scannedLines
        diagnostics.heartRateCandidateLineCount = heartRateLines
        diagnostics.scannedFileCount = scannedFiles
        diagnostics.scannedByteCount = scannedBytes
        diagnostics.inWindowPointCount = points.count
        guard !overflowed else { return nil }
        points.sort {
            if $0.t != $1.t { return $0.t < $1.t }
            return $0.bpm < $1.bpm
        }
        return .init(points: points,
                     scannedFileCount: scannedFiles,
                     scannedByteCount: scannedBytes)
    }

    private static func appendJSONLine<T: Encodable>(_ value: T) throws -> URL {
        let url = try appendJSONLineHoldingPromotionLock(value)
        // Handoff-9 CP1: derived HR-sidecar work is scheduled strictly AFTER
        // the promotion lock (and the catalog lock inside it) is released. It
        // is best-effort and can never delay or fail the append that just
        // completed.
        scheduleHeartRateSidecarBuildsForFreshlySealedChunks()
        return url
    }

    private static func appendJSONLineHoldingPromotionLock<T: Encodable>(
        _ value: T
    ) throws -> URL {
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
        // Same clock tolerances the scan itself applies: a record's device
        // stamp can drift up to the bootstrap policy's maximum, and the read
        // pads its cutoffs by the boundary tolerance.
        let windowPad: TimeInterval = 3
            + AtriaWhoop4ProductionHistoryBootstrapPolicy.maximumClockDrift
        let scanStart = start.addingTimeInterval(-windowPad)
        let scanEnd = end.addingTimeInterval(windowPad)
        return candidates.filter { candidate in
            let canonicalCandidate = candidate.standardizedFileURL
            let matching = chunksByCanonicalPath[canonicalCandidate.path] ?? []
            guard matching.count == 1,
                  let chunk = matching.first,
                  chunk.state == .sealed,
                  let sealedAt = chunk.sealedAt,
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
                // Unverifiable chunk: fail open and scan it.
                return true
            }
            if sealedAt < start { return false }
            // Range prune (2026-08-04, the 3.4GB foreground-kill fix): the
            // drain replays OLDEST-FIRST, so a chunk sealed TODAY holds
            // weeks-old records and `sealedAt < start` can never exclude it —
            // one workout window was scanning 463MB across 18 files. A
            // verified chunk whose recorded row range misses the padded window
            // cannot contribute; skip it.
            if let first = chunk.firstTimestamp,
               let last = chunk.lastTimestamp,
               last >= first,
               (last < scanStart || first > scanEnd) {
                return false
            }
            return true
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
    // MARK: - Exact-window HR chunk sidecar index (handoff-8 CP1)
    //
    // Attribution receipt from the physical Aug-11 probe: exclusion worked
    // (171 candidates → 8 selected) but the selected files held 226 MB /
    // 157k mixed-channel lines, ground through at ~2.7 MB/s for 83 s. The
    // day's rows genuinely live inside huge sealed chunks, so the fix is a
    // once-per-chunk HR channel extraction: a versioned sidecar bound to the
    // exact catalog identity (relative path + byte count + content digest —
    // the same proof the exclusion path trusts; deliberately NOT file mtime,
    // which container migrations rewrite). Reads then touch ~1 MB of sorted
    // HR rows instead of the raw archive. Anything unproven — active,
    // legacy, digestless, corrupt or mismatched sidecars — falls back to the
    // conservative raw scan. The raw archive is never rewritten.
    enum HeartRateChunkIndex {
        static let readerVersion = 1
        static let directoryName = "hr-index-v1"

        struct Binding: Codable, Equatable {
            let version: Int
            let relativePath: String
            let byteCount: UInt64
            let contentSHA256: String
            let rowCount: Int
        }
    }

    static func heartRateSidecarDirectory(archiveRoot: URL) -> URL {
        archiveRoot.appendingPathComponent(
            HeartRateChunkIndex.directoryName, isDirectory: true
        )
    }

    static func heartRateSidecarURL(
        forChunkRelativePath relativePath: String,
        archiveRoot: URL
    ) -> URL {
        let sanitized = relativePath
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: "..", with: "_")
        return heartRateSidecarDirectory(archiveRoot: archiveRoot)
            .appendingPathComponent(sanitized + ".hr.v\(HeartRateChunkIndex.readerVersion).jsonl")
    }

    /// A sidecar is trusted only when its header binding matches the CURRENT
    /// catalog row byte-for-byte on identity: version, relative path, raw
    /// byte count, and content digest. Any mismatch, truncation, or decode
    /// failure fails closed to the raw scan.
    static func validHeartRateSidecarBinding(
        sidecarURL: URL,
        chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        fileManager: FileManager = .default
    ) -> HeartRateChunkIndex.Binding? {
        guard chunk.state == .sealed,
              let digest = chunk.contentSHA256,
              fileManager.fileExists(atPath: sidecarURL.path),
              let handle = try? FileHandle(forReadingFrom: sidecarURL) else {
            return nil
        }
        defer { try? handle.close() }
        guard let headerData = try? handle.read(upToCount: 4_096),
              let newline = headerData.firstIndex(of: 0x0A) else { return nil }
        let headerLine = headerData[headerData.startIndex..<newline]
        guard let binding = try? JSONDecoder().decode(
            HeartRateChunkIndex.Binding.self, from: Data(headerLine)
        ),
              binding.version == HeartRateChunkIndex.readerVersion,
              binding.relativePath == chunk.relativePath,
              binding.byteCount == chunk.byteCount,
              binding.contentSHA256 == digest,
              binding.rowCount >= 0 else {
            return nil
        }
        return binding
    }

    /// Sorted in-window HR rows from a validated sidecar. Returns nil on any
    /// malformed row so the caller falls back to the raw scan — a sidecar is
    /// an accelerator, never a second source of truth.
    static func sidecarHeartRatePoints(
        sidecarURL: URL,
        start: Date,
        end: Date,
        maximumPoints: Int
    ) -> [HeartRatePoint]? {
        guard let data = try? Data(contentsOf: sidecarURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var points: [HeartRatePoint] = []
        var isHeader = true
        let startUnix = start.timeIntervalSince1970
        let endUnix = end.timeIntervalSince1970
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if isHeader { isHeader = false; continue }
            let parts = line.split(separator: " ")
            guard parts.count == 2,
                  let t = Double(parts[0]),
                  let bpm = Int(parts[1]),
                  t.isFinite, bpm > 0 else { return nil }
            if t >= endUnix { break }   // rows are written sorted
            guard t >= startUnix else { continue }
            guard points.count < maximumPoints else { return nil }
            points.append(HeartRatePoint(t: Date(timeIntervalSince1970: t), bpm: bpm))
        }
        return points
    }

    /// Extracts the full HR channel of one chunk (already scanned rows) into
    /// an atomically-written sidecar. Best effort: failure to persist never
    /// fails the read that produced the rows.
    @discardableResult
    static func writeHeartRateSidecar(
        rows: [HeartRatePoint],
        chunk: AtriaHistoricalArchiveCatalog.RawChunk,
        archiveRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard chunk.state == .sealed,
              let digest = chunk.contentSHA256 else { return false }
        let binding = HeartRateChunkIndex.Binding(
            version: HeartRateChunkIndex.readerVersion,
            relativePath: chunk.relativePath,
            byteCount: chunk.byteCount,
            contentSHA256: digest,
            rowCount: rows.count
        )
        guard let header = try? JSONEncoder().encode(binding),
              let headerLine = String(data: header, encoding: .utf8) else {
            return false
        }
        var body = headerLine + "\n"
        for row in rows.sorted(by: { $0.t < $1.t }) {
            body += "\(row.t.timeIntervalSince1970) \(row.bpm)\n"
        }
        let directory = heartRateSidecarDirectory(archiveRoot: archiveRoot)
        let destination = heartRateSidecarURL(
            forChunkRelativePath: chunk.relativePath,
            archiveRoot: archiveRoot
        )
        do {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(
                destination.lastPathComponent + ".tmp-\(UUID().uuidString)"
            )
            try body.data(using: .utf8)?.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try? fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            return true
        } catch {
            return false
        }
    }

    /// One-time cooperative backfill: build sidecars for sealed, digested
    /// chunks that lack a valid one. Runs off-main (launch follow-up) so
    /// real navigations meet a warm index. Returns the number built.
    @discardableResult
    static func backfillHeartRateSidecars(
        shouldContinue: @escaping () -> Bool = { true }
    ) -> Int {
        guard let catalog = (try? catalogStoreLocked()).flatMap({ try? $0.snapshot() }),
              (try? catalog.validate()) != nil else { return 0 }
        let root = archiveDirectory
        var built = 0
        for chunk in catalog.chunks {
            guard shouldContinue() else { break }
            guard chunk.state == .sealed, chunk.contentSHA256 != nil else { continue }
            let fileURL = root.appendingPathComponent(chunk.relativePath)
                .standardizedFileURL
            let sidecarURL = heartRateSidecarURL(
                forChunkRelativePath: chunk.relativePath, archiveRoot: root
            )
            if validHeartRateSidecarBinding(sidecarURL: sidecarURL, chunk: chunk) != nil {
                continue
            }
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(for: [fileURL])
            guard !descriptors.isEmpty else { continue }
            var rows: [HeartRatePoint] = []
            let result = AtriaHistoricalJSONLRecentScanner.scan(
                sources: descriptors.map { .init(descriptor: $0, startOffset: 0) },
                cutoff: 0
            ) { line in
                guard let text = String(data: line, encoding: .utf8),
                      let point = fastHeartRatePoint(from: text) else { return }
                rows.append(point)
            }
            guard result.complete else { continue }
            if writeHeartRateSidecar(rows: rows, chunk: chunk, archiveRoot: root) {
                built += 1
            }
        }
        if built > 0 {
            AtriaDebugLog("ATRIADBG hr_sidecar_backfill status=built count=%d", built)
        }
        return built
    }

    // MARK: - Seal-triggered sidecar builds (handoff-9 CP1)

    private static let heartRateSidecarBuildQueue = DispatchQueue(
        label: "atria.historical.hr-sidecar-build", qos: .utility
    )
    private static let heartRateSidecarBuildStateLock = NSLock()
    private static var heartRateSidecarBuildsInFlight: Set<String> = []

    /// Drains the catalog store's freshly-sealed queue and schedules one
    /// coalesced sidecar build per chunk. Called only after the promotion and
    /// catalog locks are released; a failure here never surfaces to appends.
    static func scheduleHeartRateSidecarBuildsForFreshlySealedChunks() {
        guard let store = try? catalogStoreLocked() else { return }
        let sealedIDs = store.takeSealedChunksAwaitingDerivedIndexes()
        for chunkID in sealedIDs {
            scheduleHeartRateSidecarBuild(forSealedChunkID: chunkID)
        }
    }

    /// Coalesced by exact chunk identity: while a build for a chunk is in
    /// flight, further requests drop. A query racing the build either scans
    /// conservatively or sees a complete binding-valid sidecar — the atomic
    /// temp-file+rename write means a partial file is never visible.
    static func scheduleHeartRateSidecarBuild(forSealedChunkID chunkID: String) {
        heartRateSidecarBuildStateLock.lock()
        let alreadyRunning = heartRateSidecarBuildsInFlight.contains(chunkID)
        if !alreadyRunning { heartRateSidecarBuildsInFlight.insert(chunkID) }
        heartRateSidecarBuildStateLock.unlock()
        guard !alreadyRunning else { return }
        heartRateSidecarBuildQueue.async {
            defer {
                heartRateSidecarBuildStateLock.lock()
                heartRateSidecarBuildsInFlight.remove(chunkID)
                heartRateSidecarBuildStateLock.unlock()
            }
            buildHeartRateSidecarNow(chunkID: chunkID)
        }
    }

    private static func buildHeartRateSidecarNow(chunkID: String) {
        guard let catalog = (try? catalogStoreLocked()).flatMap({ try? $0.snapshot() }),
              let chunk = catalog.chunks.first(where: { $0.id == chunkID }),
              chunk.state == .sealed,
              chunk.contentSHA256 != nil else { return }
        let root = archiveDirectory
        let fileURL = root.appendingPathComponent(chunk.relativePath)
            .standardizedFileURL
        let sidecarURL = heartRateSidecarURL(
            forChunkRelativePath: chunk.relativePath, archiveRoot: root
        )
        if validHeartRateSidecarBinding(sidecarURL: sidecarURL, chunk: chunk) != nil {
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(for: [fileURL])
        guard !descriptors.isEmpty else { return }
        var rows: [HeartRatePoint] = []
        let result = AtriaHistoricalJSONLRecentScanner.scan(
            sources: descriptors.map { .init(descriptor: $0, startOffset: 0) },
            cutoff: 0
        ) { line in
            guard let text = String(data: line, encoding: .utf8),
                  let point = fastHeartRatePoint(from: text) else { return }
            rows.append(point)
        }
        guard result.complete else { return }
        if writeHeartRateSidecar(rows: rows, chunk: chunk, archiveRoot: root) {
            AtriaDebugLog("ATRIADBG hr_sidecar_seal_build status=built chunk=%@ rows=%d",
                          chunkID, rows.count)
        }
    }

    /// Test seam: block until every currently queued sidecar build drains.
    static func flushHeartRateSidecarBuildQueueForTesting() {
        heartRateSidecarBuildQueue.sync {}
    }

    // MARK: - Exact-window HR result cache (handoff-8 CP1)

    /// In-memory repeat-navigation cache. The key folds the closed-open
    /// window, the reader version, and a hash of the full consumer source
    /// fingerprint (paths + sizes + mtimes + catalog generation), so any
    /// archive mutation produces a different key rather than a stale hit.
    enum HeartRateWindowResultCache {
        struct Key: Hashable {
            let startUnix: Double
            let endUnix: Double
            let fingerprintHash: Int
            let readerVersion: Int
        }

        private static let lock = NSLock()
        private static var storage: [Key: HeartRateWindowRead] = [:]
        private static var order: [Key] = []
        private static let capacity = 16

        static func value(for key: Key) -> HeartRateWindowRead? {
            lock.lock(); defer { lock.unlock() }
            return storage[key]
        }

        static func install(_ read: HeartRateWindowRead, for key: Key) {
            lock.lock(); defer { lock.unlock() }
            if storage[key] == nil {
                order.append(key)
                if order.count > capacity {
                    storage.removeValue(forKey: order.removeFirst())
                }
            }
            storage[key] = read
        }

        static func removeAll() {
            lock.lock(); defer { lock.unlock() }
            storage.removeAll(); order.removeAll()
        }
    }

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
                                             attributes: (byteCount: Int, modificationTime: TimeInterval),
                                             shouldContinue: () -> Bool) -> DiagnosticsIndex? {
        guard shouldContinue(),
              let content = try? String(contentsOf: url, encoding: .utf8),
              shouldContinue() else { return nil }
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
        for (lineOffset, rawLine) in content
            .split(whereSeparator: \.isNewline).enumerated() {
            if lineOffset.isMultiple(of: 128), !shouldContinue() {
                return nil
            }
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            append(object: object, to: &index)
        }
        return shouldContinue() ? index : nil
    }

    private static func aggregateDiagnosticsIndex(base: DiagnosticsIndex,
                                                  segments: [DiagnosticsIndex],
                                                  shouldContinue: () -> Bool) -> DiagnosticsIndex? {
        var aggregate = base
        for (index, segment) in segments.enumerated() {
            if index.isMultiple(of: 16), !shouldContinue() { return nil }
            aggregate = DiagnosticsIndex(fileSize: aggregate.fileSize + segment.fileSize,
                             modificationTime: max(aggregate.modificationTime, segment.modificationTime),
                             rows: aggregate.rows + segment.rows,
                             schemas: sortedUnion(aggregate.schemas, segment.schemas),
                             layoutVersions: sortedUnion(aggregate.layoutVersions, segment.layoutVersions),
                             metricUsableRows: aggregate.metricUsableRows + segment.metricUsableRows,
                             currentSessionUsableRows: aggregate.currentSessionUsableRows + segment.currentSessionUsableRows,
                             undecodableRows: aggregate.undecodableRows + segment.undecodableRows,
                             rawPayloadRows: aggregate.rawPayloadRows + segment.rawPayloadRows,
                             unixFirst: minOptional(aggregate.unixFirst, segment.unixFirst),
                             unixLast: maxOptional(aggregate.unixLast, segment.unixLast),
                             correctedUnixFirst: minOptional(aggregate.correctedUnixFirst, segment.correctedUnixFirst),
                             correctedUnixLast: maxOptional(aggregate.correctedUnixLast, segment.correctedUnixLast),
                             gravityRows: aggregate.gravityRows + segment.gravityRows,
                             gravityValidatedRows: aggregate.gravityValidatedRows + segment.gravityValidatedRows)
        }
        return shouldContinue() ? aggregate : nil
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
        // Sync-progress frontier (2026-08-07): the newest strap record durably
        // on the phone, written at durable-flush cadence so the Overview
        // footer's "behind" number visibly FALLS while the drain runs. The
        // archive-status refresh path may lag materialization by hours;
        // monotonic-max here so display never regresses to that lag.
        let frontier = accumulators.compactMap { accumulator -> Double? in
            guard let index = accumulator.index else { return nil }
            let last = index.correctedUnixLast ?? index.unixLast
            return last.map(Double.init)
        }.max() ?? 0
        if frontier > 0 {
            let defaults = UserDefaults.standard
            let key = AtriaBLEManager.OfflineSyncDefaults.drainedThroughUnix
            if frontier > defaults.double(forKey: key) {
                defaults.set(frontier, forKey: key)
            }
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

    fileprivate struct GravitySample: Codable, Equatable {
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
        let rrAccumulator: AtriaRecoveredRRProjection.Accumulator
        let skinTemperatureRawPoints: [SkinTemperatureRawPoint]
        let gravitySamples: [GravitySample]
        let motionRecordIdentities: Set<AtriaRecoveredMotionReplayIdentity>
        /// Channels that hit their budget cap during THIS cache's ingest
        /// history (2026-08-04). A truncated channel is missing arbitrary
        /// mid-scan rows, so it must keep reporting budgetExceeded even after
        /// pruning drops its count back under the cap — previously the whole
        /// cache was discarded instead, which forced a full-archive rebuild
        /// scan on every recompute once any channel capped (the systemic
        /// 3.45GB jetsam amplifier).
        var truncatedChannels: Set<RecoveredDataCompleteness.Channel> = []
    }

    private struct RecentGravityCache {
        let loadedAt: Date
        let targetBytes: UInt64
        let samples: [GravitySample]
        let latestTimestamp: TimeInterval?
        /// Source-file identity at load time. While this is unchanged, a
        /// reload would decode byte-identical inputs — so the cache stays
        /// valid even for windows the corpus doesn't cover (2026-08-04 fix:
        /// during drain backfill the archive's gravity ALWAYS lags "now", so
        /// the coverage check alone missed on every sleep-candidate pass and
        /// re-decoded the full tail each time — the 3.45GB-footprint /
        /// cpu_resource_fatal lane).
        let fingerprint: RecentGravityArchiveFingerprint?
    }

    /// Cheap stat-level identity of the readable gravity source files.
    struct RecentGravityArchiveFingerprint: Equatable {
        let fileCount: Int
        let totalBytes: UInt64
        let latestModification: TimeInterval
    }

    private static func recentGravityArchiveFingerprint() -> RecentGravityArchiveFingerprint? {
        var fileCount = 0
        var totalBytes: UInt64 = 0
        var latestModification: TimeInterval = 0
        for url in recentReadableFileURLs() {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey,
                                                                 .contentModificationDateKey]) else {
                return nil
            }
            fileCount += 1
            totalBytes += UInt64(values.fileSize ?? 0)
            if let modified = values.contentModificationDate?.timeIntervalSince1970 {
                latestModification = Swift.max(latestModification, modified)
            }
        }
        return RecentGravityArchiveFingerprint(fileCount: fileCount,
                                               totalBytes: totalBytes,
                                               latestModification: latestModification)
    }

    private static func loadGravitySamples() -> [GravitySample] {
#if DEBUG
        fullGravityInstrumentationLock.lock()
        fullGravityLoadCount += 1
        fullGravityInstrumentationLock.unlock()
#endif
        // One file resident at a time (2026-08-04): the old
        // `.compactMap { String(contentsOf:) }` materialized EVERY raw file's
        // full contents simultaneously (~1GB archive → 2-3GB burst in seconds
        // — the post-recompute footprint kill), before parsing even began.
        return recentReadableFileURLs()
            .flatMap { url -> [GravitySample] in
                autoreleasepool {
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                        return []
                    }
                    return gravitySamples(from: content)
                }
            }
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

        // Stat the source files BEFORE taking the cache lock: if they are
        // byte-identical to what the cache decoded, a reload cannot produce
        // different samples, so the cache is valid no matter how far the
        // requested window outruns the (lagging, still-draining) corpus.
        let currentFingerprint = recentGravityArchiveFingerprint()

        recentGravityCacheLock.lock()
        if let cache = recentGravityCache,
           cache.targetBytes >= targetBytes,
           recentGravityCacheCovers(cache, end: end)
               || (currentFingerprint != nil && cache.fingerprint == currentFingerprint)
               // Reload rate limit (2026-08-04, second balloon fix): during an
               // active drain the writer appends to these files continuously,
               // so the fingerprint invalidates on every call and the decode
               // loop returns exactly when the app is busiest. Motion evidence
               // that is ≤45s stale is fine for sleep candidacy — candidates
               // are re-evaluated on later passes anyway.
               || Date().timeIntervalSince(cache.loadedAt) < 45 {
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
                let fingerprint = recentGravityArchiveFingerprint()
                let samples = loadRecentGravitySamplesUncached(targetBytes: targetBytes)
                publishRecentGravityCache(samples: samples,
                                          targetBytes: targetBytes,
                                          generation: loadGeneration,
                                          fingerprint: fingerprint)
            }
            return []
        }

        let samples = loadRecentGravitySamplesUncached(targetBytes: targetBytes)
        publishRecentGravityCache(samples: samples,
                                  targetBytes: targetBytes,
                                  generation: loadGeneration,
                                  fingerprint: currentFingerprint)
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
                                                  generation: UInt64,
                                                  fingerprint: RecentGravityArchiveFingerprint?) {
        recentGravityCacheLock.lock()
        guard generation == recentGravityLoadGeneration else {
            recentGravityCacheLock.unlock()
            return
        }
        // The fingerprint was taken BEFORE the load: if a writer landed during
        // the decode, the stored identity is older than the files, the next
        // lookup mismatches, and a fresh reload happens — stale-conservative.
        recentGravityCache = RecentGravityCache(loadedAt: Date(),
                                                targetBytes: targetBytes,
                                                samples: samples,
                                                latestTimestamp: samples.last?.timestamp,
                                                fingerprint: fingerprint)
        recentGravityLoadInFlight = false
        recentGravityCacheLock.unlock()
    }

#if DEBUG
    static func resetRecoveredDataCacheForTesting() {
        recoveredDataCacheLock.lock()
        _ = replaceRecoveredDataCacheWhileLocked(with: nil)
        recoveredDataCacheLock.unlock()
    }

    /// Deterministic ownership race: a stale installer is superseded before
    /// its unwind reaches rollback. The production rollback helper must leave
    /// the newer generation/tag (and therefore its cache image) untouched.
    static func staleRecoveredDataCacheRollbackPreservesReplacementForTesting()
        -> Bool {
        recoveredDataCacheLock.lock()
        defer { recoveredDataCacheLock.unlock() }
        guard let cache = recoveredDataCache,
              let staleOwnership = replaceRecoveredDataCacheWhileLocked(
                with: cache
              ),
              let replacementOwnership = replaceRecoveredDataCacheWhileLocked(
                with: cache
              ) else { return false }
        rollbackRecoveredDataCacheInstallWhileLocked(
            ownedBy: staleOwnership
        )
        return recoveredDataCache != nil
            && recoveredDataCacheInstallOwnership == replacementOwnership
    }

    static var recoveredDataCacheIsInstalledForTesting: Bool {
        recoveredDataCacheLock.lock()
        defer { recoveredDataCacheLock.unlock() }
        return recoveredDataCache != nil
    }

    static func resetRecentGravityCacheForTesting() {
        recentGravityCacheLock.lock()
        recentGravityLoadGeneration &+= 1
        recentGravityCache = nil
        recentGravityLoadInFlight = false
        recentGravityCacheLock.unlock()

        recoveredDataCacheLock.lock()
        _ = replaceRecoveredDataCacheWhileLocked(with: nil)
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
            return gravitySample(from: record,
                                 payload: bytes(fromHex: record.rawPayloadHex))
        }
    }

    /// RR-equivalent verification for historical gravity. Stored metadata is
    /// not trusted until the versioned decoder reproduces its clock identity;
    /// subsecond ticks and flash counter are preserved for deterministic order.
    private static func gravitySample(from record: Record,
                                      payload: [UInt8]?) -> GravitySample? {
        guard record.unix7 > 0,
              record.subsec11 < 32_768,
              let payload,
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
        // Fast path (2026-08-04 scan-garbage fix): pure-ASCII hex decoded
        // byte-wise — no trimmed String copy, no per-pair substrings. This
        // runs multiple times per scanned line (identity/gravity/skin);
        // the Character-based version was a dominant footprint contributor.
        // Semantics preserved: leading/trailing ASCII whitespace trimmed,
        // interior whitespace rejects (a whitespace-split pair never parsed
        // before either). Any non-ASCII byte falls back to the original.
        var sawNonASCII = false
        var fast: [UInt8] = []
        fast.reserveCapacity(hex.utf8.count / 2)
        var nibbles = 0
        var pending: UInt8 = 0
        var trailingWhitespace = false
        scan: for byte in hex.utf8 {
            switch byte {
            case 0x80...:
                sawNonASCII = true
                break scan
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
                if nibbles > 0 { trailingWhitespace = true }
                continue
            case 0x30...0x39, 0x41...0x46, 0x61...0x66:
                guard !trailingWhitespace else { return nil }  // interior gap
                let digit = byte <= 0x39 ? byte - 0x30
                    : (byte <= 0x46 ? byte - 0x41 + 10 : byte - 0x61 + 10)
                if nibbles % 2 == 0 {
                    pending = digit << 4
                } else {
                    fast.append(pending | digit)
                }
                nibbles += 1
            default:
                return nil
            }
        }
        if !sawNonASCII {
            guard nibbles % 2 == 0 else { return nil }
            return fast
        }
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

    private static func maintenanceAuthorityRevokedCompactionResult(
        bytesBefore: Int = 0,
        bytesAfter: Int = 0
    ) -> CompactionResult {
        .init(
            status: "deferred_maintenance_authority_revoked",
            scannedRows: 0,
            keptRows: 0,
            compactedRows: 0,
            summaryRows: 0,
            bytesBefore: bytesBefore,
            bytesAfter: bytesAfter
        )
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
                               now: Date = Date(),
                               shouldContinue: @escaping () -> Bool = { true })
        -> CompactionResult {
        var authorityRevoked = false
        func maintenanceShouldContinue() -> Bool {
            guard !authorityRevoked else { return false }
            guard shouldContinue() else {
                authorityRevoked = true
                return false
            }
            return true
        }
        guard maintenanceShouldContinue() else {
            return maintenanceAuthorityRevokedCompactionResult()
        }
        do {
            let store = try catalogStoreLocked()
            let retirementExecutor = AtriaHistoricalRawRetirementExecutor(
                archiveRoot: archiveDirectory,
                catalogStore: store
            )
            guard maintenanceShouldContinue() else {
                return maintenanceAuthorityRevokedCompactionResult()
            }
            if let recovered = try retirementExecutor.recoverFirstPendingIntent(
                shouldContinue: maintenanceShouldContinue
            ) {
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
            guard maintenanceShouldContinue() else {
                return maintenanceAuthorityRevokedCompactionResult()
            }
            // Recover crash-left immutable generations before high-volume
            // accounting. The collector follows every durable current pointer
            // and never removes necessary typed history.
            do {
                let collected = try AtriaHistoricalGeneratedArtifactGC(
                    archiveRoot: archiveDirectory,
                    now: now
                ).prune(shouldContinue: maintenanceShouldContinue)
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
                guard maintenanceShouldContinue() else {
                    return maintenanceAuthorityRevokedCompactionResult()
                }
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
                guard maintenanceShouldContinue() else {
                    return maintenanceAuthorityRevokedCompactionResult()
                }
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
            guard maintenanceShouldContinue() else {
                return maintenanceAuthorityRevokedCompactionResult()
            }
            do {
                let diagnostics = try AtriaHistoricalHighVolumeDiagnosticsCoordinator
                    .evaluate(
                        archiveRoot: archiveDirectory,
                        catalog: catalog,
                        shouldContinue: maintenanceShouldContinue
                    )
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
            guard maintenanceShouldContinue() else {
                return maintenanceAuthorityRevokedCompactionResult()
            }
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
            guard maintenanceShouldContinue() else {
                return maintenanceAuthorityRevokedCompactionResult()
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
            guard maintenanceShouldContinue() else {
                return maintenanceAuthorityRevokedCompactionResult(
                    bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                    bytesAfter: Int(clamping: retention.plan.rawBytesBefore)
                )
            }
            let outcome = AtriaHistoricalShadowCompactionCoordinator.commitFirst(
                candidates: retention.uncommittedCandidates
            ) { chunk in
                guard maintenanceShouldContinue() else {
                    throw AtriaHistoricalRetentionTransaction.TransactionError
                        .maintenanceAuthorityRevoked
                }
                let sourceURL = archiveDirectory.appendingPathComponent(chunk.relativePath)
                let build = try AtriaHistoricalAggregateBuilder.build(sourceURL: sourceURL,
                                                                      chunkID: chunk.id,
                                                                      createdAt: chunk.sealedAt
                                                                        ?? chunk.createdAt)
                guard maintenanceShouldContinue() else {
                    throw AtriaHistoricalRetentionTransaction.TransactionError
                        .maintenanceAuthorityRevoked
                }
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
                    shouldContinue: maintenanceShouldContinue,
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

            guard maintenanceShouldContinue() else {
                return maintenanceAuthorityRevokedCompactionResult(
                    bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                    bytesAfter: Int(clamping: retention.plan.rawBytesBefore)
                )
            }

            switch outcome {
            case .noCandidates:
                let status: String
                if !retention.missingSourceCandidateIDs.isEmpty {
                    status = "deferred_retention_source_unavailable"
                } else if let chunkID = retention.shadowCommittedCandidateIDs.first {
                    guard maintenanceShouldContinue() else {
                        return maintenanceAuthorityRevokedCompactionResult(
                            bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                            bytesAfter: Int(clamping: retention.plan.rawBytesBefore)
                        )
                    }
                    do {
                        let cutover = try publishAndVerifyHistoricalConsumerCutover(
                            chunkID: chunkID,
                            archiveRoot: archiveDirectory,
                            catalogStore: store,
                            configuration: configuration,
                            shouldContinue: maintenanceShouldContinue
                        )
                        guard maintenanceShouldContinue() else {
                            return maintenanceAuthorityRevokedCompactionResult(
                                bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                                bytesAfter: Int(clamping: retention.plan.rawBytesBefore)
                            )
                        }
                        let retired = try retirementExecutor.retire(
                            chunkID: cutover.chunkID,
                            shouldContinue: maintenanceShouldContinue
                        )
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
                        guard maintenanceShouldContinue() else {
                            return maintenanceAuthorityRevokedCompactionResult(
                                bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                                bytesAfter: Int(clamping: retention.plan.rawBytesBefore)
                            )
                        }
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
                    guard maintenanceShouldContinue() else {
                        return maintenanceAuthorityRevokedCompactionResult(
                            bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                            bytesAfter: Int(clamping: retention.plan.rawBytesBefore)
                        )
                    }
                    let cutover = try publishAndVerifyHistoricalConsumerCutover(
                        chunkID: value.chunk.id,
                        archiveRoot: archiveDirectory,
                        catalogStore: store,
                        configuration: configuration,
                        shouldContinue: maintenanceShouldContinue
                    )
                    guard maintenanceShouldContinue() else {
                        return maintenanceAuthorityRevokedCompactionResult(
                            bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                            bytesAfter: Int(clamping: retention.plan.rawBytesBefore)
                        )
                    }
                    let retired = try retirementExecutor.retire(
                        chunkID: cutover.chunkID,
                        shouldContinue: maintenanceShouldContinue
                    )
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
                    guard maintenanceShouldContinue() else {
                        return maintenanceAuthorityRevokedCompactionResult(
                            bytesBefore: Int(clamping: retention.plan.rawBytesBefore),
                            bytesAfter: Int(clamping: retention.plan.rawBytesBefore)
                        )
                    }
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
            guard maintenanceShouldContinue() else {
                return maintenanceAuthorityRevokedCompactionResult()
            }
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
        maximumElapsed: TimeInterval = 8,
        shouldContinue: @escaping () -> Bool = { true }
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
            guard shouldContinue() else {
                return maintenanceAuthorityRevokedCompactionResult(
                    bytesBefore: firstBytesBefore ?? 0,
                    bytesAfter: last?.bytesAfter ?? firstBytesBefore ?? 0
                )
            }
            let result = compactArchive(pinnedWindows: pinnedWindows,
                                        reason: reason,
                                        configuration: configuration,
                                        now: now,
                                        shouldContinue: shouldContinue)
            if firstBytesBefore == nil { firstBytesBefore = result.bytesBefore }
            scanned &+= result.scannedRows
            kept &+= result.keptRows
            compacted &+= result.compactedRows
            summaries &+= result.summaryRows
            last = result
            if result.status == "deferred_maintenance_authority_revoked" {
                return .init(
                    status: result.status,
                    scannedRows: scanned,
                    keptRows: kept,
                    compactedRows: compacted,
                    summaryRows: summaries,
                    bytesBefore: firstBytesBefore ?? result.bytesBefore,
                    bytesAfter: result.bytesAfter
                )
            }
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

// MARK: - Scan-path Record parser (allocation-frugal, 2026-08-04)

extension HistoricalArchive.Record {
    /// Parses one archive JSONL line IN PLACE, allocating only what the
    /// Record itself keeps (its String fields and Int/String arrays).
    ///
    /// Why this exists (the 3.4GB scan-kill saga's final layer): the
    /// recovered-data scan reads ~1GB and visits millions of lines; the
    /// footprint probe proved the killer was per-line PARSE GARBAGE —
    /// transient heap allocations outrunning the allocator's page reclaim
    /// (violent climb to a ~2GB plateau, full release only after the scan
    /// ends). Every object-graph parser hit it: JSONDecoder,
    /// JSONSerialization (shared swift-foundation engine on iOS 27.0 beta),
    /// and a first-cut byte parser that copied each line into [UInt8]
    /// (~1.5KB × millions). count-only mode — same bytes, no per-line
    /// allocation — stays flat at ~411MB, which is the proof and the bar.
    /// So: no line copy, no key Strings, no number Strings (integers
    /// accumulate from bytes; only decimal tokens round-trip through a
    /// short String for correctly-rounded Double conversion), and string
    /// fields decode straight from the buffer slice.
    /// Field-for-field parity with JSONDecoder is enforced by
    /// AtriaRecordScanParserParityTests — extend BOTH when Record changes.
    /// Known divergence (documented, pathological-input-only): a key
    /// spelled with \u escapes is treated as unknown rather than matched.
    init?(scanLine line: Data) {
        let parsed = line.withUnsafeBytes { raw -> HistoricalArchive.Record? in
            var parser = AtriaScanRecordParser(raw.bindMemory(to: UInt8.self))
            return parser.parseRecord()
        }
        guard let parsed else { return nil }
        self = parsed
    }
}

private struct AtriaScanRecordParser {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    // MARK: field slots

    private var schema: Int?
    private var capturedAt: Date?
    private var strapIdentifier: String??
    private var source: String?
    private var layoutVersion: String?
    private var sequence: Int?
    private var command: Int?
    private var unix7: UInt32?
    private var subsec11: UInt16?
    private var flash13: UInt32?
    private var payloadLength: Int?
    private var whoofHR17: Int?
    private var whoofRRNum18: Int?
    private var whoofRR19: [Int]?
    private var kRR64: [Int]?
    private var gravityX36: Double??
    private var gravityY40: Double??
    private var gravityZ44: Double??
    private var unknownMotionScalar32: Double??
    private var gravityMagnitude: Double??
    private var gravityValidated: Bool?
    private var motionTickCounter88: Int??
    private var candidateRR: [String]?
    private var rawPayloadHex: String?
    private var clockDeviceRef: UInt32??
    private var clockWallRef: UInt32??
    private var clockDriftSeconds: Int??
    private var clockCorrectedUnix7: UInt32??
    private var clockCorrectionStatus: String?
    private var currentSessionUsable: Bool?
    private var metricUsable: Bool?
    private var usabilityReason: String?

    mutating func parseRecord() -> HistoricalArchive.Record? {
        skipWhitespace()
        guard consume(0x7B) else { return nil }  // {
        skipWhitespace()
        if consume(0x7D) {  // } — empty object: every required key missing
            return nil
        }
        while true {
            skipWhitespace()
            guard let key = parseStringSpan() else { return nil }
            skipWhitespace()
            guard consume(0x3A) else { return nil }  // :
            skipWhitespace()
            guard storeValue(keyStart: key.start, keyEnd: key.end,
                             keyHasEscape: key.hasEscape) else { return nil }
            skipWhitespace()
            if consume(0x2C) { continue }  // ,
            if consume(0x7D) { break }     // }
            return nil
        }
        skipWhitespace()
        guard index == bytes.count else { return nil }  // trailing garbage

        guard let schema, let capturedAt, let source, let layoutVersion,
              let sequence, let command, let unix7, let subsec11, let flash13,
              let payloadLength, let whoofHR17, let whoofRRNum18,
              let whoofRR19, let kRR64, let gravityValidated, let candidateRR,
              let rawPayloadHex, let clockCorrectionStatus,
              let currentSessionUsable, let metricUsable, let usabilityReason
        else { return nil }
        return HistoricalArchive.Record(
            schema: schema,
            capturedAt: capturedAt,
            strapIdentifier: strapIdentifier ?? nil,
            source: source,
            layoutVersion: layoutVersion,
            sequence: sequence,
            command: command,
            unix7: unix7,
            subsec11: subsec11,
            flash13: flash13,
            payloadLength: payloadLength,
            whoofHR17: whoofHR17,
            whoofRRNum18: whoofRRNum18,
            whoofRR19: whoofRR19,
            kRR64: kRR64,
            gravityX36: gravityX36 ?? nil,
            gravityY40: gravityY40 ?? nil,
            gravityZ44: gravityZ44 ?? nil,
            unknownMotionScalar32: unknownMotionScalar32 ?? nil,
            gravityMagnitude: gravityMagnitude ?? nil,
            gravityValidated: gravityValidated,
            motionTickCounter88: motionTickCounter88 ?? nil,
            candidateRR: candidateRR,
            rawPayloadHex: rawPayloadHex,
            clockDeviceRef: clockDeviceRef ?? nil,
            clockWallRef: clockWallRef ?? nil,
            clockDriftSeconds: clockDriftSeconds ?? nil,
            clockCorrectedUnix7: clockCorrectedUnix7 ?? nil,
            clockCorrectionStatus: clockCorrectionStatus,
            currentSessionUsable: currentSessionUsable,
            metricUsable: metricUsable,
            usabilityReason: usabilityReason)
    }

    private mutating func storeValue(keyStart: Int, keyEnd: Int,
                                     keyHasEscape: Bool) -> Bool {
        // Escaped keys (never produced by the writer) fall through to the
        // unknown-key skip; see the documented divergence above.
        guard !keyHasEscape else { return skipValue() }
        func keyIs(_ literal: StaticString) -> Bool {
            spanEquals(keyStart, keyEnd, literal)
        }
        if keyIs("schema")              { return store(\.schema) { $0.parseInt() } }
        if keyIs("capturedAt") {
            guard let span = parseStringSpan(), !span.hasEscape,
                  let date = parseISO8601(span.start, span.end)
            else { return false }
            capturedAt = date
            return true
        }
        if keyIs("strapIdentifier")     { return storeOptional(\.strapIdentifier) { $0.parseString() } }
        if keyIs("source")              { return store(\.source) { $0.parseString() } }
        if keyIs("layoutVersion")       { return store(\.layoutVersion) { $0.parseString() } }
        if keyIs("sequence")            { return store(\.sequence) { $0.parseInt() } }
        if keyIs("command")             { return store(\.command) { $0.parseInt() } }
        if keyIs("unix7")               { return store(\.unix7) { $0.parseUInt32() } }
        if keyIs("subsec11")            { return store(\.subsec11) { $0.parseUInt16() } }
        if keyIs("flash13")             { return store(\.flash13) { $0.parseUInt32() } }
        if keyIs("payloadLength")       { return store(\.payloadLength) { $0.parseInt() } }
        if keyIs("whoofHR17")           { return store(\.whoofHR17) { $0.parseInt() } }
        if keyIs("whoofRRNum18")        { return store(\.whoofRRNum18) { $0.parseInt() } }
        if keyIs("whoofRR19")           { return store(\.whoofRR19) { $0.parseIntArray() } }
        if keyIs("kRR64")               { return store(\.kRR64) { $0.parseIntArray() } }
        if keyIs("gravityX36")          { return storeOptional(\.gravityX36) { $0.parseDouble() } }
        if keyIs("gravityY40")          { return storeOptional(\.gravityY40) { $0.parseDouble() } }
        if keyIs("gravityZ44")          { return storeOptional(\.gravityZ44) { $0.parseDouble() } }
        if keyIs("unknownMotionScalar32") {
            return storeOptional(\.unknownMotionScalar32) { $0.parseDouble() }
        }
        if keyIs("gravityMagnitude")    { return storeOptional(\.gravityMagnitude) { $0.parseDouble() } }
        if keyIs("gravityValidated")    { return store(\.gravityValidated) { $0.parseBool() } }
        if keyIs("motionTickCounter88") { return storeOptional(\.motionTickCounter88) { $0.parseInt() } }
        if keyIs("candidateRR")         { return store(\.candidateRR) { $0.parseStringArray() } }
        if keyIs("rawPayloadHex")       { return store(\.rawPayloadHex) { $0.parseString() } }
        if keyIs("clockDeviceRef")      { return storeOptional(\.clockDeviceRef) { $0.parseUInt32() } }
        if keyIs("clockWallRef")        { return storeOptional(\.clockWallRef) { $0.parseUInt32() } }
        if keyIs("clockDriftSeconds")   { return storeOptional(\.clockDriftSeconds) { $0.parseInt() } }
        if keyIs("clockCorrectedUnix7") { return storeOptional(\.clockCorrectedUnix7) { $0.parseUInt32() } }
        if keyIs("clockCorrectionStatus") {
            return store(\.clockCorrectionStatus) { $0.parseString() }
        }
        if keyIs("currentSessionUsable") { return store(\.currentSessionUsable) { $0.parseBool() } }
        if keyIs("metricUsable")        { return store(\.metricUsable) { $0.parseBool() } }
        if keyIs("usabilityReason")     { return store(\.usabilityReason) { $0.parseString() } }
        return skipValue()  // unknown keys ignored
    }

    /// Sequential parse-then-store: the closure's `inout self` access ends
    /// before the keypath write begins (a direct `assign(&slot, parse())`
    /// overlaps exclusive accesses to self and does not compile).
    private mutating func store<T>(
        _ keyPath: WritableKeyPath<AtriaScanRecordParser, T?>,
        _ parse: (inout AtriaScanRecordParser) -> T?
    ) -> Bool {
        guard let value = parse(&self) else { return false }
        self[keyPath: keyPath] = value
        return true
    }

    private mutating func storeOptional<T>(
        _ keyPath: WritableKeyPath<AtriaScanRecordParser, T??>,
        _ parse: (inout AtriaScanRecordParser) -> T?
    ) -> Bool {
        if consumeLiteral("null") {
            self[keyPath: keyPath] = T?.none
            return true
        }
        guard let value = parse(&self) else { return false }
        self[keyPath: keyPath] = value
        return true
    }

    // MARK: lexing

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func consumeLiteral(_ literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else { return false }
        let start = index
        let matched = literal.withUTF8Buffer { buffer -> Bool in
            for offset in 0..<count where bytes[start + offset] != buffer[offset] {
                return false
            }
            return true
        }
        guard matched else { return false }
        index += count
        return true
    }

    private func spanEquals(_ start: Int, _ end: Int,
                            _ literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard end - start == count else { return false }
        return literal.withUTF8Buffer { buffer -> Bool in
            for offset in 0..<count where bytes[start + offset] != buffer[offset] {
                return false
            }
            return true
        }
    }

    private mutating func skipWhitespace() {
        while let byte = current,
              byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    /// Scans the raw span of a JSON string without decoding it. Validates
    /// escape SHAPES (so the cursor lands correctly) but defers unescaping
    /// to the slow path; the fast no-escape path is a zero-copy slice.
    private mutating func parseStringSpan() -> (start: Int, end: Int, hasEscape: Bool)? {
        guard consume(0x22) else { return nil }  // "
        let start = index
        var hasEscape = false
        while let byte = current {
            switch byte {
            case 0x22:
                let end = index
                index += 1
                return (start, end, hasEscape)
            case 0x5C:
                hasEscape = true
                index += 1
                guard let escape = current else { return nil }
                index += 1
                if escape == 0x75 {  // \uXXXX — validate 4 hex digits exist
                    guard parseHex4() != nil else { return nil }
                } else {
                    switch escape {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: break
                    default: return nil
                    }
                }
            case 0x00...0x1F:
                return nil  // raw control characters are invalid in JSON
            default:
                index += 1
            }
        }
        return nil  // unterminated
    }

    private mutating func parseString() -> String? {
        guard let span = parseStringSpan() else { return nil }
        if !span.hasEscape {
            return String(decoding: UnsafeBufferPointer(
                rebasing: bytes[span.start..<span.end]), as: UTF8.self)
        }
        return Self.unescape(bytes, span.start, span.end)
    }

    /// Slow path: decodes a validated escaped span into a String.
    private static func unescape(_ bytes: UnsafeBufferPointer<UInt8>,
                                 _ start: Int, _ end: Int) -> String? {
        var out: [UInt8] = []
        out.reserveCapacity(end - start)
        var position = start
        while position < end {
            let byte = bytes[position]
            position += 1
            guard byte == 0x5C else {
                out.append(byte)
                continue
            }
            let escape = bytes[position]
            position += 1
            switch escape {
            case 0x22, 0x5C, 0x2F: out.append(escape)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                guard var unit = hex4(bytes, position) else { return nil }
                position += 4
                if (0xD800...0xDBFF).contains(unit) {
                    // surrogate pair: require \uDC00–\uDFFF
                    guard position + 6 <= end,
                          bytes[position] == 0x5C, bytes[position + 1] == 0x75,
                          let low = hex4(bytes, position + 2),
                          (0xDC00...0xDFFF).contains(low) else { return nil }
                    position += 6
                    unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(unit) {
                    return nil  // unpaired low surrogate
                }
                guard let scalar = Unicode.Scalar(unit) else { return nil }
                out.append(contentsOf: Array(String(scalar).utf8))
            default:
                return nil
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func parseHex4() -> UInt32? {
        guard let value = Self.hex4(bytes, index) else { return nil }
        index += 4
        return value
    }

    private static func hex4(_ bytes: UnsafeBufferPointer<UInt8>,
                             _ start: Int) -> UInt32? {
        guard start + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for offset in 0..<4 {
            let byte = bytes[start + offset]
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
            default: return nil
            }
            value = value << 4 | digit
        }
        return value
    }

    /// Collects one JSON number token as a span. Integral tokens later
    /// accumulate exactly from the bytes; decimal/exponent tokens go
    /// through Swift's correctly-rounded Double(String) — the same
    /// rounding JSONDecoder applies (the only per-number allocation left).
    private mutating func parseNumberToken() -> (start: Int, end: Int, isIntegral: Bool)? {
        let start = index
        var isIntegral = true
        if current == 0x2D { index += 1 }  // -
        var sawDigit = false
        loop: while let byte = current {
            switch byte {
            case 0x30...0x39:
                sawDigit = true
                index += 1
            case 0x2E, 0x65, 0x45, 0x2B, 0x2D:  // . e E + -
                isIntegral = false
                index += 1
            default:
                break loop
            }
        }
        guard sawDigit else { return nil }
        return (start, index, isIntegral)
    }

    private mutating func parseIntegerExactly() -> Int64? {
        guard let token = parseNumberToken() else { return nil }
        if token.isIntegral {
            var position = token.start
            var negative = false
            if bytes[position] == 0x2D {
                negative = true
                position += 1
            }
            guard position < token.end else { return nil }
            var value: Int64 = 0
            while position < token.end {
                let byte = bytes[position]
                guard (0x30...0x39).contains(byte) else { return nil }
                let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
                let (added, addOverflow) = multiplied.addingReportingOverflow(Int64(byte - 0x30))
                guard !multiplyOverflow, !addOverflow else { return nil }
                value = added
                position += 1
            }
            return negative ? -value : value
        }
        // Integral-valued decimals (4.0) convert when exact, mirroring the
        // NSNumber-exactly semantics the parity suite pins.
        guard let value = doubleValue(token), let exact = Int64(exactly: value)
        else { return nil }
        return exact
    }

    private func doubleValue(_ token: (start: Int, end: Int, isIntegral: Bool)) -> Double? {
        Double(String(decoding: UnsafeBufferPointer(
            rebasing: bytes[token.start..<token.end]), as: UTF8.self))
    }

    private mutating func parseInt() -> Int? {
        parseIntegerExactly().flatMap { Int(exactly: $0) }
    }

    private mutating func parseUInt32() -> UInt32? {
        parseIntegerExactly().flatMap { UInt32(exactly: $0) }
    }

    private mutating func parseUInt16() -> UInt16? {
        parseIntegerExactly().flatMap { UInt16(exactly: $0) }
    }

    private mutating func parseDouble() -> Double? {
        guard let token = parseNumberToken() else { return nil }
        return doubleValue(token)
    }

    private mutating func parseBool() -> Bool? {
        if consumeLiteral("true") { return true }
        if consumeLiteral("false") { return false }
        return nil
    }

    private mutating func parseIntArray() -> [Int]? {
        guard consume(0x5B) else { return nil }  // [
        var values: [Int] = []
        skipWhitespace()
        if consume(0x5D) { return values }  // ]
        while true {
            skipWhitespace()
            guard let value = parseInt() else { return nil }
            values.append(value)
            skipWhitespace()
            if consume(0x2C) { continue }
            if consume(0x5D) { return values }
            return nil
        }
    }

    private mutating func parseStringArray() -> [String]? {
        guard consume(0x5B) else { return nil }
        var values: [String] = []
        skipWhitespace()
        if consume(0x5D) { return values }
        while true {
            skipWhitespace()
            guard let value = parseString() else { return nil }
            values.append(value)
            skipWhitespace()
            if consume(0x2C) { continue }
            if consume(0x5D) { return values }
            return nil
        }
    }

    /// Generic value skip for unknown keys (JSONDecoder ignores them).
    private mutating func skipValue() -> Bool {
        skipWhitespace()
        switch current {
        case 0x22:
            return parseStringSpan() != nil
        case 0x7B:  // {
            index += 1
            skipWhitespace()
            if consume(0x7D) { return true }
            while true {
                skipWhitespace()
                guard parseStringSpan() != nil else { return false }
                skipWhitespace()
                guard consume(0x3A), skipValue() else { return false }
                skipWhitespace()
                if consume(0x2C) { continue }
                if consume(0x7D) { return true }
                return false
            }
        case 0x5B:  // [
            index += 1
            skipWhitespace()
            if consume(0x5D) { return true }
            while true {
                guard skipValue() else { return false }
                skipWhitespace()
                if consume(0x2C) { continue }
                if consume(0x5D) { return true }
                return false
            }
        case 0x74, 0x66, 0x6E:  // t f n
            return consumeLiteral("true") || consumeLiteral("false")
                || consumeLiteral("null")
        default:
            return parseNumberToken() != nil
        }
    }

    // MARK: dates

    /// yyyy-MM-dd'T'HH:mm:ss with Z or ±HH(:)MM over the raw span —
    /// exactly the shapes ISO8601DateFormatter(.withInternetDateTime)
    /// accepts (JSONDecoder's .iso8601); fractional seconds rejected, as
    /// that strategy does. Civil-days algorithm avoids Calendar/TimeZone
    /// and allocates nothing.
    private func parseISO8601(_ start: Int, _ end: Int) -> Date? {
        let count = end - start
        func digits(_ offset: Int, _ length: Int) -> Int? {
            var value = 0
            for position in (start + offset)..<(start + offset + length) {
                guard position < end,
                      (0x30...0x39).contains(bytes[position]) else { return nil }
                value = value * 10 + Int(bytes[position] - 0x30)
            }
            return value
        }
        func byteAt(_ offset: Int) -> UInt8 { bytes[start + offset] }
        guard count >= 20,
              let year = digits(0, 4), byteAt(4) == 0x2D,
              let month = digits(5, 2), byteAt(7) == 0x2D,
              let day = digits(8, 2), byteAt(10) == 0x54,
              let hour = digits(11, 2), byteAt(13) == 0x3A,
              let minute = digits(14, 2), byteAt(16) == 0x3A,
              let second = digits(17, 2)
        else { return nil }
        guard (1...12).contains(month), hour <= 23, minute <= 59, second <= 59
        else { return nil }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        // No array literal here — this runs per line; stay allocation-free.
        let daysInMonth: Int
        switch month {
        case 2: daysInMonth = leap ? 29 : 28
        case 4, 6, 9, 11: daysInMonth = 30
        default: daysInMonth = 31
        }
        guard day >= 1, day <= daysInMonth else { return nil }

        var offsetSeconds = 0
        switch byteAt(19) {
        case 0x5A:  // Z
            guard count == 20 else { return nil }
        case 0x2B, 0x2D:  // + -
            let sign = byteAt(19) == 0x2B ? 1 : -1
            let offsetHour: Int?
            let offsetMinute: Int?
            if count == 25, byteAt(22) == 0x3A {  // ±HH:MM
                offsetHour = digits(20, 2)
                offsetMinute = digits(23, 2)
            } else if count == 24 {               // ±HHMM
                offsetHour = digits(20, 2)
                offsetMinute = digits(22, 2)
            } else {
                return nil
            }
            guard let offsetHour, let offsetMinute,
                  offsetHour <= 23, offsetMinute <= 59 else { return nil }
            offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
        default:
            return nil
        }

        // Howard Hinnant's days-from-civil (public domain), exact for the
        // proleptic Gregorian calendar Foundation uses for UTC.
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let daysSinceEpoch = era * 146_097 + dayOfEra - 719_468
        let unix = daysSinceEpoch * 86_400 + hour * 3600 + minute * 60 + second
            - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }
}
