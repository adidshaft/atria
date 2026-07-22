import Foundation

/// Bounded bridge from durable historical projection receipts to typed values
/// that app stores may consume.
///
/// Receipt and artifact hashes are necessary but insufficient. Every read is
/// rebuilt from the strict aggregate reader and rebound to the current
/// file-verified catalog plus the durable terminal-drain record. The same
/// evidence is checked again after all five artifacts are read, so an append,
/// aggregate mutation, or completion-generation change fails the entire read
/// closed. This type never edits the catalog and never deletes raw history.
struct AtriaHistoricalVerifiedConsumerReader {
    typealias Configuration = AtriaHistoricalConsumerProjectionConfiguration

    struct Limits: Equatable, Sendable {
        let maximumAggregateCount: Int
        let maximumManifestBytes: UInt64
        let maximumAggregateBytes: UInt64
        let maximumTotalAggregateBytes: UInt64
        let maximumDependencyCount: Int
        let maximumReceiptBytes: UInt64
        let maximumArtifactBytes: UInt64

        init(maximumAggregateCount: Int,
             maximumDependencyCount: Int,
             maximumReceiptBytes: UInt64,
             maximumArtifactBytes: UInt64,
             maximumManifestBytes: UInt64 = 256 * 1_024,
             maximumAggregateBytes: UInt64 = 16 * 1_024 * 1_024,
             maximumTotalAggregateBytes: UInt64 = 256 * 1_024 * 1_024) {
            self.maximumAggregateCount = maximumAggregateCount
            self.maximumManifestBytes = maximumManifestBytes
            self.maximumAggregateBytes = maximumAggregateBytes
            self.maximumTotalAggregateBytes = maximumTotalAggregateBytes
            self.maximumDependencyCount = maximumDependencyCount
            self.maximumReceiptBytes = maximumReceiptBytes
            self.maximumArtifactBytes = maximumArtifactBytes
        }

        static let production = Limits(maximumAggregateCount: 4_096,
                                       maximumDependencyCount: 64,
                                       maximumReceiptBytes: 64 * 1_024,
                                       maximumArtifactBytes: 16 * 1_024 * 1_024)

        fileprivate var isValid: Bool {
            maximumAggregateCount > 0
                && maximumManifestBytes > 0
                && maximumAggregateBytes > 0
                && maximumTotalAggregateBytes > 0
                && maximumDependencyCount > 0
                && maximumReceiptBytes > 0
                && maximumArtifactBytes > 0
        }
    }

    enum MissingReason: Equatable, Sendable {
        case sourceNotCommitted
        case receiptNotPublished
        case artifactNotPublished
    }

    enum DeferredReason: Error, Equatable, Sendable {
        case invalidConfiguration
        case aggregateNotCommitted
        case aggregateSnapshotRejected
        case attestationUnavailable
        case verificationFailed
        case readerLimitExceeded
        case evidenceChangedDuringRead
    }

    enum ArtifactState<Value: Equatable & Sendable>: Equatable, Sendable {
        case available(Value)
        case knownEmpty
        case missing(MissingReason)
        case deferred(DeferredReason)
    }

    /// Durable identity a downstream store must retain alongside any value it
    /// materializes. Typed projection bytes without this binding are not
    /// production authority: a later receipt generation may use a different
    /// baseline/configuration or terminal catalog attestation for the same raw
    /// chunk. Keep the exact immutable receipts, rather than reducing them to a
    /// lossy candidate fingerprint.
    struct VerificationIdentity: Codable, Equatable, Sendable {
        let completionGeneration: UInt64
        let generationIdentifier: String
        let catalogSnapshotSHA256: String
        let source: AtriaHistoricalConsumerReceiptLedger.Source
        let receipts: [AtriaHistoricalConsumerReceiptLedger.Receipt]
    }

    struct SourceArtifacts: Equatable, Sendable {
        let sourceChunkID: String
        let verificationIdentity: VerificationIdentity?
        let activity: ArtifactState<AtriaHistoricalActivityProjection>
        let dailyMetrics: ArtifactState<AtriaHistoricalDailyConsumerProjection.DailyMetricsArtifact>
        let steps: ArtifactState<AtriaHistoricalDailyConsumerProjection.StepsArtifact>
        let sleep: ArtifactState<AtriaHistoricalSleepProjection>
        let workout: ArtifactState<AtriaHistoricalWorkoutProjection>

        var hasConsumableValue: Bool {
            activity.isConsumable
                || dailyMetrics.isConsumable
                || steps.isConsumable
                || sleep.isConsumable
                || workout.isConsumable
        }

        /// True only when one immutable verification identity binds all five
        /// typed projections. A single readable artifact is not cutover.
        var hasCompleteConsumerCoverage: Bool {
            verificationIdentity != nil
                && activity.isConsumable
                && dailyMetrics.isConsumable
                && steps.isConsumable
                && sleep.isConsumable
                && workout.isConsumable
        }
    }

    enum Checkpoint: Equatable, Sendable {
        case evidenceAttested
        case artifactsRead
    }

    let aggregateReader: AtriaHistoricalAggregateReader
    let completionStore: AtriaHistoricalDrainCompletionGenerationStore
    let receiptLedger: AtriaHistoricalConsumerReceiptLedger
    var limits: Limits = .production
    var checkpoint: (Checkpoint) throws -> Void = { _ in }

    /// Reads one source at a time so resident artifact memory has a fixed upper
    /// bound. A caller should release a bundle before advancing to the next
    /// committed source.
    func readSource(
        chunkID: String,
        catalogStore: AtriaHistoricalArchiveCatalogStore,
        configuration: Configuration
    ) -> SourceArtifacts {
        guard !chunkID.isEmpty, limits.isValid else {
            return deferredBundle(chunkID: chunkID, reason: .readerLimitExceeded)
        }

        let snapshot = aggregateReader.load(limits: aggregateLoadLimits)
        guard !snapshot.diagnostics.limitExceeded else {
            return deferredBundle(chunkID: chunkID, reason: .readerLimitExceeded)
        }
        guard snapshot.diagnostics.rejectedManifests == 0 else {
            return deferredBundle(chunkID: chunkID, reason: .aggregateSnapshotRejected)
        }
        guard snapshot.aggregates.count <= limits.maximumAggregateCount else {
            return deferredBundle(chunkID: chunkID, reason: .readerLimitExceeded)
        }

        let matches = snapshot.aggregates.filter { $0.source.chunkID == chunkID }
        guard matches.count == 1, let source = matches.first else {
            do {
                let catalog = try catalogStore.snapshotVerifiedAgainstFiles()
                let existsInCatalog = catalog.chunks.contains { $0.id == chunkID }
                return existsInCatalog
                    ? deferredBundle(chunkID: chunkID, reason: .aggregateNotCommitted)
                    : missingBundle(chunkID: chunkID, reason: .sourceNotCommitted)
            } catch {
                return deferredBundle(chunkID: chunkID, reason: .attestationUnavailable)
            }
        }

        let requestedRange: ClosedRange<Date>
        do {
            requestedRange = try requiredRange(for: source,
                                               dailyConfiguration: configuration.daily)
        } catch {
            return deferredBundle(chunkID: chunkID, reason: .invalidConfiguration)
        }

        let factory = AtriaHistoricalActivityInspectionProofFactory(
            completionStore: completionStore
        )
        let prepared: AtriaHistoricalActivityInspectionProofFactory.Prepared
        do {
            prepared = try factory.prepare(catalogStore: catalogStore,
                                           aggregateSnapshot: snapshot,
                                           requestedStart: requestedRange.lowerBound,
                                           requestedEnd: requestedRange.upperBound)
            guard prepared.dependencyChunks.count <= limits.maximumDependencyCount else {
                return deferredBundle(chunkID: chunkID, reason: .readerLimitExceeded)
            }
            try checkpoint(.evidenceAttested)
        } catch {
            return deferredBundle(chunkID: chunkID, reason: .attestationUnavailable)
        }

        let ledgerSource = AtriaHistoricalConsumerReceiptLedger.Source(
            chunkID: source.source.chunkID,
            rawSHA256: source.source.rawSHA256,
            firstTimestamp: source.source.firstTimestamp,
            lastTimestamp: source.source.lastTimestamp
        )
        let dailyProof: AtriaHistoricalDailyConsumerProjection.InspectionProof
        let sessionProof: AtriaHistoricalSessionInspectionProof
        do {
            dailyProof = try .make(
                generationIdentifier: prepared.generationIdentifier,
                catalogSnapshot: prepared.catalogSnapshot,
                dependencyChunks: prepared.dependencyChunks,
                closedCoverageIntervals: prepared.closedCoverageIntervals.map {
                    .init(start: $0.start, end: $0.end, recordCount: $0.recordCount)
                }
            )
            sessionProof = try .make(
                generationIdentifier: prepared.generationIdentifier,
                catalogSnapshot: prepared.catalogSnapshot,
                closedCoverageIntervals: prepared.closedCoverageIntervals.map {
                    .init(start: $0.start, end: $0.end, recordCount: $0.recordCount)
                }
            )
        } catch {
            return deferredBundle(chunkID: chunkID, reason: .attestationUnavailable)
        }

        let artifactSet: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind:
            AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact]
        do {
            artifactSet = try receiptLedger.validatedCurrentSet(
                for: ledgerSource,
                maximumReceiptBytes: limits.maximumReceiptBytes,
                maximumArtifactBytes: limits.maximumArtifactBytes
            )
        } catch let error as AtriaHistoricalConsumerReceiptLedger.LedgerError {
            switch error {
            case .currentSetMissing:
                return missingBundle(chunkID: chunkID, reason: .receiptNotPublished)
            case .receiptMissing, .artifactMissing:
                return missingBundle(chunkID: chunkID, reason: .artifactNotPublished)
            case .receiptTooLarge, .artifactTooLarge, .currentSetTooLarge:
                return deferredBundle(chunkID: chunkID, reason: .readerLimitExceeded)
            default:
                return deferredBundle(chunkID: chunkID, reason: .verificationFailed)
            }
        } catch {
            return deferredBundle(chunkID: chunkID, reason: .verificationFailed)
        }

        let activity = readActivity(source: source,
                                    artifactSet: artifactSet,
                                    prepared: prepared,
                                    configuration: configuration.activity)
        let dailyMetrics = readDailyMetrics(source: source,
                                            artifactSet: artifactSet,
                                            prepared: prepared,
                                            configuration: configuration.daily,
                                            proof: dailyProof)
        let steps = readSteps(source: source,
                              artifactSet: artifactSet,
                              prepared: prepared,
                              configuration: configuration.daily,
                              proof: dailyProof)
        let sleep = readSleep(source: source,
                              artifactSet: artifactSet,
                              prepared: prepared,
                              configuration: configuration.sleep,
                              proof: sessionProof)
        let workout = readWorkout(source: source,
                                  artifactSet: artifactSet,
                                  prepared: prepared,
                                  configuration: configuration.workout,
                                  proof: sessionProof)

        do {
            try checkpoint(.artifactsRead)
            let finalSnapshot = aggregateReader.load(limits: aggregateLoadLimits)
            guard !finalSnapshot.diagnostics.limitExceeded,
                  finalSnapshot.diagnostics.rejectedManifests == 0,
                  finalSnapshot.aggregates.count <= limits.maximumAggregateCount else {
                return deferredBundle(chunkID: chunkID, reason: .evidenceChangedDuringRead)
            }
            let finalPrepared = try factory.prepare(
                catalogStore: catalogStore,
                aggregateSnapshot: finalSnapshot,
                requestedStart: requestedRange.lowerBound,
                requestedEnd: requestedRange.upperBound
            )
            guard sameAttestation(prepared, finalPrepared) else {
                return deferredBundle(chunkID: chunkID, reason: .evidenceChangedDuringRead)
            }
        } catch {
            return deferredBundle(chunkID: chunkID, reason: .evidenceChangedDuringRead)
        }

        return .init(sourceChunkID: chunkID,
                     verificationIdentity: .init(
                        completionGeneration: prepared.completionGeneration,
                        generationIdentifier: prepared.generationIdentifier,
                        catalogSnapshotSHA256: AtriaHistoricalSessionProjectionSupport.sha256(
                            prepared.catalogSnapshot
                        ),
                        source: ledgerSource,
                        receipts: artifactSet.values.map(\.receipt).sorted {
                            $0.kind.rawValue < $1.kind.rawValue
                        }
                     ),
                     activity: activity,
                     dailyMetrics: dailyMetrics,
                     steps: steps,
                     sleep: sleep,
                     workout: workout)
    }

    private enum ArtifactLoad {
        case value(AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact)
        case missing(MissingReason)
        case deferred(DeferredReason)
    }

    private var aggregateLoadLimits: AtriaHistoricalAggregateReader.LoadLimits {
        .init(maximumManifestCount: limits.maximumAggregateCount,
              maximumManifestBytes: limits.maximumManifestBytes,
              maximumAggregateBytes: limits.maximumAggregateBytes,
              maximumTotalAggregateBytes: limits.maximumTotalAggregateBytes)
    }

    private func loadArtifact(
        from artifactSet: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind:
            AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact],
        kind: AtriaHistoricalConsumerReceiptLedger.ProjectionKind
    ) -> ArtifactLoad {
        guard let value = artifactSet[kind] else {
            return .missing(.receiptNotPublished)
        }
        return .value(value)
    }

    private func readActivity(
        source: AtriaHistoricalAggregateChunk,
        artifactSet: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind:
            AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact],
        prepared: AtriaHistoricalActivityInspectionProofFactory.Prepared,
        configuration: AtriaHistoricalActivityProjection.Configuration
    ) -> ArtifactState<AtriaHistoricalActivityProjection> {
        switch loadArtifact(from: artifactSet, kind: .activity) {
        case .missing(let reason): return .missing(reason)
        case .deferred(let reason): return .deferred(reason)
        case .value(let value):
            do {
                guard try AtriaHistoricalActivityProjection.verifyReceipt(
                    value.receipt,
                    artifact: value.artifact,
                    source: source,
                    dependencyChunks: prepared.dependencyChunks,
                    configuration: configuration,
                    inspectionProof: prepared.inspectionProof,
                    completionWatermark: prepared.completionWatermark
                ) else { return .deferred(.verificationFailed) }
                let projection = try AtriaHistoricalActivityProjection.decodeAndVerify(
                    value.artifact,
                    source: source,
                    dependencyChunks: prepared.dependencyChunks,
                    configuration: configuration,
                    inspectionProof: prepared.inspectionProof,
                    completionWatermark: prepared.completionWatermark
                )
                return value.receipt.outcome == .explicitlyEmpty
                    ? .knownEmpty
                    : .available(projection)
            } catch {
                return .deferred(.verificationFailed)
            }
        }
    }

    private func readDailyMetrics(
        source: AtriaHistoricalAggregateChunk,
        artifactSet: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind:
            AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact],
        prepared: AtriaHistoricalActivityInspectionProofFactory.Prepared,
        configuration: AtriaHistoricalDailyConsumerProjection.Configuration,
        proof: AtriaHistoricalDailyConsumerProjection.InspectionProof
    ) -> ArtifactState<AtriaHistoricalDailyConsumerProjection.DailyMetricsArtifact> {
        switch loadArtifact(from: artifactSet, kind: .dailyMetrics) {
        case .missing(let reason): return .missing(reason)
        case .deferred(let reason): return .deferred(reason)
        case .value(let value):
            do {
                guard try AtriaHistoricalDailyConsumerProjection.verifyDailyMetricsShadowReceipt(
                    value.receipt,
                    artifact: value.artifact,
                    source: source,
                    dependencyChunks: prepared.dependencyChunks,
                    configuration: configuration,
                    inspectionProof: proof,
                    completionWatermark: prepared.completionWatermark
                ) else { return .deferred(.verificationFailed) }
                let decoded = try JSONDecoder().decode(
                    AtriaHistoricalDailyConsumerProjection.DailyMetricsArtifact.self,
                    from: value.artifact
                )
                return value.receipt.outcome == .explicitlyEmpty
                    ? .knownEmpty
                    : .available(decoded)
            } catch {
                return .deferred(.verificationFailed)
            }
        }
    }

    private func readSteps(
        source: AtriaHistoricalAggregateChunk,
        artifactSet: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind:
            AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact],
        prepared: AtriaHistoricalActivityInspectionProofFactory.Prepared,
        configuration: AtriaHistoricalDailyConsumerProjection.Configuration,
        proof: AtriaHistoricalDailyConsumerProjection.InspectionProof
    ) -> ArtifactState<AtriaHistoricalDailyConsumerProjection.StepsArtifact> {
        switch loadArtifact(from: artifactSet, kind: .steps) {
        case .missing(let reason): return .missing(reason)
        case .deferred(let reason): return .deferred(reason)
        case .value(let value):
            do {
                guard try AtriaHistoricalDailyConsumerProjection.verifyStepsShadowReceipt(
                    value.receipt,
                    artifact: value.artifact,
                    source: source,
                    dependencyChunks: prepared.dependencyChunks,
                    configuration: configuration,
                    inspectionProof: proof,
                    completionWatermark: prepared.completionWatermark
                ) else { return .deferred(.verificationFailed) }
                let decoded = try JSONDecoder().decode(
                    AtriaHistoricalDailyConsumerProjection.StepsArtifact.self,
                    from: value.artifact
                )
                return value.receipt.outcome == .explicitlyEmpty
                    ? .knownEmpty
                    : .available(decoded)
            } catch {
                return .deferred(.verificationFailed)
            }
        }
    }

    private func readSleep(
        source: AtriaHistoricalAggregateChunk,
        artifactSet: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind:
            AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact],
        prepared: AtriaHistoricalActivityInspectionProofFactory.Prepared,
        configuration: AtriaHistoricalSleepProjection.Configuration,
        proof: AtriaHistoricalSessionInspectionProof
    ) -> ArtifactState<AtriaHistoricalSleepProjection> {
        switch loadArtifact(from: artifactSet, kind: .sleep) {
        case .missing(let reason): return .missing(reason)
        case .deferred(let reason): return .deferred(reason)
        case .value(let value):
            do {
                guard try AtriaHistoricalSleepProjection.verifyShadowReceipt(
                    value.receipt,
                    artifact: value.artifact,
                    source: source,
                    dependencyChunks: prepared.dependencyChunks,
                    configuration: configuration,
                    inspectionProof: proof,
                    completionWatermark: prepared.completionWatermark
                ) else { return .deferred(.verificationFailed) }
                let projection = try AtriaHistoricalSleepProjection.decodeAndVerify(
                    value.artifact,
                    source: source,
                    dependencyChunks: prepared.dependencyChunks,
                    configuration: configuration,
                    inspectionProof: proof,
                    completionWatermark: prepared.completionWatermark
                )
                return value.receipt.outcome == .explicitlyEmpty
                    ? .knownEmpty
                    : .available(projection)
            } catch {
                return .deferred(.verificationFailed)
            }
        }
    }

    private func readWorkout(
        source: AtriaHistoricalAggregateChunk,
        artifactSet: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind:
            AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact],
        prepared: AtriaHistoricalActivityInspectionProofFactory.Prepared,
        configuration: AtriaHistoricalWorkoutProjection.Configuration,
        proof: AtriaHistoricalSessionInspectionProof
    ) -> ArtifactState<AtriaHistoricalWorkoutProjection> {
        switch loadArtifact(from: artifactSet, kind: .workout) {
        case .missing(let reason): return .missing(reason)
        case .deferred(let reason): return .deferred(reason)
        case .value(let value):
            do {
                guard try AtriaHistoricalWorkoutProjection.verifyShadowReceipt(
                    value.receipt,
                    artifact: value.artifact,
                    source: source,
                    dependencyChunks: prepared.dependencyChunks,
                    configuration: configuration,
                    inspectionProof: proof,
                    completionWatermark: prepared.completionWatermark
                ) else { return .deferred(.verificationFailed) }
                let projection = try AtriaHistoricalWorkoutProjection.decodeAndVerify(
                    value.artifact,
                    source: source,
                    dependencyChunks: prepared.dependencyChunks,
                    configuration: configuration,
                    inspectionProof: proof,
                    completionWatermark: prepared.completionWatermark
                )
                return value.receipt.outcome == .explicitlyEmpty
                    ? .knownEmpty
                    : .available(projection)
            } catch {
                return .deferred(.verificationFailed)
            }
        }
    }

    private func requiredRange(
        for source: AtriaHistoricalAggregateChunk,
        dailyConfiguration: AtriaHistoricalDailyConsumerProjection.Configuration
    ) throws -> ClosedRange<Date> {
        guard let zone = TimeZone(identifier: dailyConfiguration.timeZoneIdentifier) else {
            throw DeferredReason.invalidConfiguration
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let dailyStart = calendar.startOfDay(for: source.source.firstTimestamp)
        let lastDay = calendar.startOfDay(for: source.source.lastTimestamp)
        guard let dailyEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) else {
            throw DeferredReason.invalidConfiguration
        }
        let history = max(AtriaHistoricalActivityProjection.requiredHistory,
                          AtriaHistoricalSleepProjection.requiredHistory,
                          AtriaHistoricalWorkoutProjection.requiredHistory)
        let lookahead = max(AtriaHistoricalActivityProjection.requiredLookahead,
                            AtriaHistoricalSleepProjection.requiredLookahead,
                            AtriaHistoricalWorkoutProjection.requiredLookahead)
        let start = min(dailyStart, source.source.firstTimestamp.addingTimeInterval(-history))
        let end = max(dailyEnd, source.source.lastTimestamp.addingTimeInterval(lookahead))
        guard start.timeIntervalSince1970.isFinite,
              end.timeIntervalSince1970.isFinite,
              end > start else {
            throw DeferredReason.invalidConfiguration
        }
        return start...end
    }

    private func sameAttestation(
        _ lhs: AtriaHistoricalActivityInspectionProofFactory.Prepared,
        _ rhs: AtriaHistoricalActivityInspectionProofFactory.Prepared
    ) -> Bool {
        lhs.completionGeneration == rhs.completionGeneration
            && lhs.completionWatermark == rhs.completionWatermark
            && lhs.generationIdentifier == rhs.generationIdentifier
            && lhs.catalogSnapshot == rhs.catalogSnapshot
            && lhs.closedCoverageIntervals == rhs.closedCoverageIntervals
            && lhs.dependencyChunks == rhs.dependencyChunks
            && lhs.inspectionProof == rhs.inspectionProof
    }

    private func missingBundle(chunkID: String,
                               reason: MissingReason) -> SourceArtifacts {
        .init(sourceChunkID: chunkID,
              verificationIdentity: nil,
              activity: .missing(reason),
              dailyMetrics: .missing(reason),
              steps: .missing(reason),
              sleep: .missing(reason),
              workout: .missing(reason))
    }

    private func deferredBundle(chunkID: String,
                                reason: DeferredReason) -> SourceArtifacts {
        .init(sourceChunkID: chunkID,
              verificationIdentity: nil,
              activity: .deferred(reason),
              dailyMetrics: .deferred(reason),
              steps: .deferred(reason),
              sleep: .deferred(reason),
              workout: .deferred(reason))
    }
}

private extension AtriaHistoricalVerifiedConsumerReader.ArtifactState {
    var isConsumable: Bool {
        switch self {
        case .available, .knownEmpty: return true
        case .missing, .deferred: return false
        }
    }
}
