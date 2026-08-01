import CryptoKit
import Foundation

/// Durable civil-day consumers derived from immutable aggregate chunks.
///
/// These artifacts deliberately retain evidence state separately from values.
/// In particular, missing step coverage never becomes a zero step count.
enum AtriaHistoricalDailyConsumerProjection {
    static let schema = 1
    static let dailyMetricsAlgorithmVersion = "historical-daily-metrics-v1"
    static let stepsAlgorithmVersion = "historical-steps-v1"

    enum EvidenceState: String, Codable, Equatable, Sendable {
        case available
        case knownEmpty
        case missing
    }

    struct Configuration: Codable, Equatable, Sendable {
        let timeZoneIdentifier: String
        /// Binds artifacts to the exact physiological-day policy, even when
        /// that policy currently happens to use civil midnight.
        let dayBoundaryPolicyVersion: String
    }

    struct Source: Codable, Equatable, Sendable {
        let chunkID: String
        let rawSHA256: String
        let firstTimestamp: Date
        let lastTimestamp: Date
        let aggregateContentSHA256: String
    }

    struct Dependency: Codable, Equatable, Sendable {
        let chunkID: String
        let rawSHA256: String
        let firstTimestamp: Date
        let lastTimestamp: Date
        /// Digest of the complete committed aggregate, not merely the facts
        /// used by one consumer. Adjacent changes therefore fail verification.
        let aggregateContentSHA256: String
    }

    struct ClosedCoverageInterval: Codable, Equatable, Sendable {
        let start: Date
        let end: Date
        /// Zero explicitly records a closed catalog scan with no chunks.
        let recordCount: Int
    }

    struct InspectionProof: Equatable, Sendable {
        let catalogSnapshot: Data
        let scanGenerationManifest: Data

        init(catalogSnapshot: Data, scanGenerationManifest: Data) {
            self.catalogSnapshot = catalogSnapshot
            self.scanGenerationManifest = scanGenerationManifest
        }

        static func make(
            generationIdentifier: String,
            catalogSnapshot: Data,
            dependencyChunks: [AtriaHistoricalAggregateChunk],
            closedCoverageIntervals: [ClosedCoverageInterval]
        ) throws -> Self {
            guard !generationIdentifier.isEmpty, !catalogSnapshot.isEmpty else {
                throw ProjectionError.invalidInspectionProof
            }
            let chunks = try validatedAndSorted(dependencyChunks)
            let manifest = ScanGenerationManifest(
                schema: ScanGenerationManifest.currentSchema,
                generationIdentifier: generationIdentifier,
                catalogContentSHA256: sha256(catalogSnapshot),
                dependencies: try chunks.map(dependency),
                closedCoverageIntervals: closedCoverageIntervals.sorted(by: intervalOrder)
            )
            return .init(catalogSnapshot: catalogSnapshot,
                         scanGenerationManifest: try canonicalData(manifest))
        }
    }

    struct InspectionEvidence: Codable, Equatable, Sendable {
        let generationIdentifier: String
        let catalogContentSHA256: String
        let scanGenerationManifestSHA256: String
        let closedCoverageIntervals: [ClosedCoverageInterval]
    }

    struct HeartRateDistribution: Codable, Equatable, Sendable {
        let sampleCount: Int
        let sumBPM: Int64
        let minimumBPM: Int?
        let maximumBPM: Int?
        let samplesByBPM: [Int: Int]
        /// Existing zone/Edwards integration can be recalculated for a new
        /// profile directly from these seconds without manufacturing samples.
        let terminalBPMSeconds: [Int: Double]
        /// Existing Banister TRIMP can be recalculated for a new profile from
        /// terminal-pair means represented as previousBPM + currentBPM.
        let transitionHalfBPMSeconds: [Int: Double]
        let coveredSeconds: Double
        let droppedGapSeconds: Double
    }

    struct DailyMetric: Codable, Equatable, Sendable {
        let localDay: String
        let dayStart: Date
        let dayEnd: Date
        let heartRateState: EvidenceState
        /// Retained for partial observed days too. State and missing coverage
        /// prevent a partial distribution from being presented as a full day.
        let observedHeartRate: HeartRateDistribution?
        let representedMinuteCount: Int
        let missingMinuteCount: Int
    }

    struct StepDay: Codable, Equatable, Sendable {
        let localDay: String
        let dayStart: Date
        let dayEnd: Date
        let state: EvidenceState
        /// Non-nil only when validated step epochs cover the entire day.
        let stepCount: Int?
        /// A partial subtotal is preserved diagnostically without promoting it
        /// to a day value when coverage is missing.
        let knownStepDeltaSum: Int
        let knownEpochCount: Int
        let rejectedOrUnknownEpochCount: Int
        let knownCoverageSeconds: Int
        let missingCoverageSeconds: Int
    }

    struct DailyMetricsArtifact: Codable, Equatable, Sendable {
        let schema: Int
        let algorithmVersion: String
        let configuration: Configuration
        let configurationSHA256: String
        let source: Source
        let dependencies: [Dependency]
        let inspectionEvidence: InspectionEvidence
        let dependencyStart: Date
        let dependencyEnd: Date
        let completionWatermark: Date
        let days: [DailyMetric]

        func encodedArtifact() throws -> Data {
            try AtriaHistoricalDailyConsumerProjection.validate(self)
            return try canonicalData(self)
        }
    }

    struct StepsArtifact: Codable, Equatable, Sendable {
        let schema: Int
        let algorithmVersion: String
        let configuration: Configuration
        let configurationSHA256: String
        let source: Source
        let dependencies: [Dependency]
        let inspectionEvidence: InspectionEvidence
        let dependencyStart: Date
        let dependencyEnd: Date
        let completionWatermark: Date
        let days: [StepDay]

        func encodedArtifact() throws -> Data {
            try AtriaHistoricalDailyConsumerProjection.validate(self)
            return try canonicalData(self)
        }
    }

    enum ProjectionError: Error, Equatable {
        case invalidConfiguration
        case invalidAggregate(String)
        case duplicateDependency(String)
        case sourceMissing
        case sourceMismatch
        case invalidInspectionProof
        case incompleteInspectionCoverage
        case dependencyProofMismatch
        case insufficientCompletionWatermark
        case invalidStepEvidence
        case invalidArtifact
        case arithmeticOverflow
        case productionCatalogAttestationRequired
    }

    static func configurationSHA256(for configuration: Configuration) throws -> String {
        try validate(configuration)
        let value = CanonicalConfiguration(schema: schema,
                                           timeZoneIdentifier: configuration.timeZoneIdentifier,
                                           dayBoundaryPolicyVersion: configuration.dayBoundaryPolicyVersion,
                                           boundaryRule: "gregorian-civil-midnight",
                                           dailyMetricsAlgorithmVersion: dailyMetricsAlgorithmVersion,
                                           stepsAlgorithmVersion: stepsAlgorithmVersion)
        return sha256(try canonicalData(value))
    }

    static func buildDailyMetrics(
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date
    ) throws -> DailyMetricsArtifact {
        let prepared = try prepare(source: source,
                                   dependencyChunks: dependencyChunks,
                                   configuration: configuration,
                                   inspectionProof: inspectionProof,
                                   completionWatermark: completionWatermark)
        return .init(schema: schema,
                     algorithmVersion: dailyMetricsAlgorithmVersion,
                     configuration: configuration,
                     configurationSHA256: prepared.configurationSHA256,
                     source: prepared.source,
                     dependencies: prepared.dependencies,
                     inspectionEvidence: prepared.inspectionEvidence,
                     dependencyStart: prepared.dependencyStart,
                     dependencyEnd: prepared.dependencyEnd,
                     completionWatermark: completionWatermark,
                     days: try dailyMetrics(days: prepared.days,
                                            chunks: prepared.chunks,
                                            timeZoneIdentifier: configuration.timeZoneIdentifier))
    }

    static func buildSteps(
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date
    ) throws -> StepsArtifact {
        let prepared = try prepare(source: source,
                                   dependencyChunks: dependencyChunks,
                                   configuration: configuration,
                                   inspectionProof: inspectionProof,
                                   completionWatermark: completionWatermark)
        return .init(schema: schema,
                     algorithmVersion: stepsAlgorithmVersion,
                     configuration: configuration,
                     configurationSHA256: prepared.configurationSHA256,
                     source: prepared.source,
                     dependencies: prepared.dependencies,
                     inspectionEvidence: prepared.inspectionEvidence,
                     dependencyStart: prepared.dependencyStart,
                     dependencyEnd: prepared.dependencyEnd,
                     completionWatermark: completionWatermark,
                     days: try stepDays(days: prepared.days,
                                         chunks: prepared.chunks,
                                         timeZoneIdentifier: configuration.timeZoneIdentifier))
    }

    static func publishDailyMetricsReceipt(
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date,
        ledger: AtriaHistoricalConsumerReceiptLedger,
        settledAt: Date
    ) throws -> AtriaHistoricalConsumerReceiptLedger.Published {
        let artifact = try buildDailyMetrics(source: source,
                                             dependencyChunks: dependencyChunks,
                                             configuration: configuration,
                                             inspectionProof: inspectionProof,
                                             completionWatermark: completionWatermark)
        let bytes = try artifact.encodedArtifact()
        return try ledger.publish(.init(source: ledgerSource(source),
                                        kind: .dailyMetrics,
                                        consumerSchemaVersion: schema,
                                        algorithmVersion: dailyMetricsAlgorithmVersion,
                                        configurationSHA256: artifact.configurationSHA256,
                                        dependencyStart: artifact.dependencyStart,
                                        dependencyEnd: artifact.dependencyEnd,
                                        completionWatermark: artifact.completionWatermark,
                                        outcome: .materialized,
                                        recordCount: artifact.days.count,
                                        artifact: bytes,
                                        settledAt: settledAt))
    }

    static func publishStepsReceipt(
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date,
        ledger: AtriaHistoricalConsumerReceiptLedger,
        settledAt: Date
    ) throws -> AtriaHistoricalConsumerReceiptLedger.Published {
        let artifact = try buildSteps(source: source,
                                      dependencyChunks: dependencyChunks,
                                      configuration: configuration,
                                      inspectionProof: inspectionProof,
                                      completionWatermark: completionWatermark)
        let bytes = try artifact.encodedArtifact()
        return try ledger.publish(.init(source: ledgerSource(source),
                                        kind: .steps,
                                        consumerSchemaVersion: schema,
                                        algorithmVersion: stepsAlgorithmVersion,
                                        configurationSHA256: artifact.configurationSHA256,
                                        dependencyStart: artifact.dependencyStart,
                                        dependencyEnd: artifact.dependencyEnd,
                                        completionWatermark: artifact.completionWatermark,
                                        outcome: .materialized,
                                        recordCount: artifact.days.count,
                                        artifact: bytes,
                                        settledAt: settledAt))
    }

    static func verifyDailyMetricsReceipt(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date
    ) throws -> Bool {
        _ = try verifyDailyMetricsShadowReceipt(receipt,
                                                artifact: artifact,
                                                source: source,
                                                dependencyChunks: dependencyChunks,
                                                configuration: configuration,
                                                inspectionProof: inspectionProof,
                                                completionWatermark: completionWatermark)
        // The current catalog has no durable closed-scan watermark for gaps
        // between chunks. Self-consistent caller bytes therefore cannot be
        // accepted by the raw-retirement semantic verifier.
        throw ProjectionError.productionCatalogAttestationRequired
    }

    static func verifyDailyMetricsShadowReceipt(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date
    ) throws -> Bool {
        let rebuilt = try buildDailyMetrics(source: source,
                                            dependencyChunks: dependencyChunks,
                                            configuration: configuration,
                                            inspectionProof: inspectionProof,
                                            completionWatermark: completionWatermark)
        guard receiptMatches(receipt,
                             kind: .dailyMetrics,
                             algorithmVersion: dailyMetricsAlgorithmVersion,
                             source: source,
                             configurationSHA256: rebuilt.configurationSHA256,
                             dependencyStart: rebuilt.dependencyStart,
                             dependencyEnd: rebuilt.dependencyEnd,
                             completionWatermark: completionWatermark,
                             recordCount: rebuilt.days.count,
                             artifact: artifact) else { return false }
        let decoded: DailyMetricsArtifact
        do { decoded = try JSONDecoder().decode(DailyMetricsArtifact.self, from: artifact) }
        catch { throw ProjectionError.invalidArtifact }
        guard decoded == rebuilt, try decoded.encodedArtifact() == artifact else {
            throw ProjectionError.invalidArtifact
        }
        return true
    }

    static func verifyStepsReceipt(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date
    ) throws -> Bool {
        _ = try verifyStepsShadowReceipt(receipt,
                                         artifact: artifact,
                                         source: source,
                                         dependencyChunks: dependencyChunks,
                                         configuration: configuration,
                                         inspectionProof: inspectionProof,
                                         completionWatermark: completionWatermark)
        throw ProjectionError.productionCatalogAttestationRequired
    }

    static func verifyStepsShadowReceipt(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date
    ) throws -> Bool {
        let rebuilt = try buildSteps(source: source,
                                     dependencyChunks: dependencyChunks,
                                     configuration: configuration,
                                     inspectionProof: inspectionProof,
                                     completionWatermark: completionWatermark)
        guard receiptMatches(receipt,
                             kind: .steps,
                             algorithmVersion: stepsAlgorithmVersion,
                             source: source,
                             configurationSHA256: rebuilt.configurationSHA256,
                             dependencyStart: rebuilt.dependencyStart,
                             dependencyEnd: rebuilt.dependencyEnd,
                             completionWatermark: completionWatermark,
                             recordCount: rebuilt.days.count,
                             artifact: artifact) else { return false }
        let decoded: StepsArtifact
        do { decoded = try JSONDecoder().decode(StepsArtifact.self, from: artifact) }
        catch { throw ProjectionError.invalidArtifact }
        guard decoded == rebuilt, try decoded.encodedArtifact() == artifact else {
            throw ProjectionError.invalidArtifact
        }
        return true
    }

    private struct CanonicalConfiguration: Codable {
        let schema: Int
        let timeZoneIdentifier: String
        let dayBoundaryPolicyVersion: String
        let boundaryRule: String
        let dailyMetricsAlgorithmVersion: String
        let stepsAlgorithmVersion: String
    }

    private struct ScanGenerationManifest: Codable, Equatable {
        static let currentSchema = 1
        let schema: Int
        let generationIdentifier: String
        let catalogContentSHA256: String
        let dependencies: [Dependency]
        let closedCoverageIntervals: [ClosedCoverageInterval]
    }

    private struct Prepared {
        let configurationSHA256: String
        let source: Source
        let dependencies: [Dependency]
        let inspectionEvidence: InspectionEvidence
        let dependencyStart: Date
        let dependencyEnd: Date
        let days: [DateInterval]
        let chunks: [AtriaHistoricalAggregateChunk]
    }

    private static func prepare(
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date
    ) throws -> Prepared {
        try validate(configuration)
        let allChunks = try validatedAndSorted(dependencyChunks)
        guard let suppliedSource = allChunks.first(where: { $0.source.chunkID == source.source.chunkID }) else {
            throw ProjectionError.sourceMissing
        }
        guard suppliedSource == source else { throw ProjectionError.sourceMismatch }

        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: configuration.timeZoneIdentifier) else {
            throw ProjectionError.invalidConfiguration
        }
        calendar.timeZone = timeZone
        let dependencyStart = calendar.startOfDay(for: source.source.firstTimestamp)
        let lastDayStart = calendar.startOfDay(for: source.source.lastTimestamp)
        guard let dependencyEnd = calendar.date(byAdding: .day, value: 1, to: lastDayStart),
              completionWatermark >= dependencyEnd else {
            throw ProjectionError.insufficientCompletionWatermark
        }
        let relevant = allChunks.filter {
            $0.source.lastTimestamp >= dependencyStart && $0.source.firstTimestamp < dependencyEnd
        }
        let dependencies = try relevant.map(dependency)
        let evidence = try validatedInspectionEvidence(inspectionProof,
                                                       covering: dependencyStart...dependencyEnd,
                                                       dependencies: dependencies)
        var days: [DateInterval] = []
        var cursor = dependencyStart
        while cursor < dependencyEnd {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else {
                throw ProjectionError.invalidConfiguration
            }
            days.append(DateInterval(start: cursor, end: next))
            cursor = next
        }
        return .init(configurationSHA256: try configurationSHA256(for: configuration),
                     source: try projectionSource(source),
                     dependencies: dependencies,
                     inspectionEvidence: evidence,
                     dependencyStart: dependencyStart,
                     dependencyEnd: dependencyEnd,
                     days: days,
                     chunks: relevant)
    }

    private static func dailyMetrics(
        days: [DateInterval],
        chunks: [AtriaHistoricalAggregateChunk],
        timeZoneIdentifier: String
    ) throws -> [DailyMetric] {
        // Flatten once before the day loop instead of O(days x facts) per day.
        let allHeartRateMinutes = chunks.flatMap(\.heartRateMinutes)
        return try days.map { day in
            // Bound the per-day Foundation/CryptoKit temporaries so they do not
            // accumulate across a long multi-day projection pass.
            try autoreleasepool {
                let facts = allHeartRateMinutes.filter {
                    $0.minuteStart >= day.start && $0.minuteStart < day.end
                }.sorted { $0.minuteStart < $1.minuteStart }
                let sampleCount = try safeSum(facts.map(\.sampleCount))
                let distribution: HeartRateDistribution? = sampleCount > 0 ? .init(
                    sampleCount: sampleCount,
                    sumBPM: try safeSum(facts.map(\.sumBPM)),
                    minimumBPM: facts.filter { $0.sampleCount > 0 }.map(\.minimumBPM).min(),
                    maximumBPM: facts.filter { $0.sampleCount > 0 }.map(\.maximumBPM).max(),
                    samplesByBPM: try mergedIntegerMaps(facts.map(\.samplesByBPM)),
                    terminalBPMSeconds: try mergedDoubleMaps(facts.map(\.terminalBPMSeconds)),
                    transitionHalfBPMSeconds: try mergedDoubleMaps(facts.map(\.transitionHalfBPMSeconds)),
                    coveredSeconds: facts.reduce(0) { $0 + $1.coveredSeconds },
                    droppedGapSeconds: facts.reduce(0) { $0 + $1.droppedGapSeconds }
                ) : nil
                let representedMinutes = Set(facts.map { Int64(floor($0.minuteStart.timeIntervalSince1970 / 60)) }).count
                let totalMinutes = Int(day.duration / 60)
                let state: EvidenceState
                if sampleCount > 0 { state = .available }
                else if representedMinutes == totalMinutes { state = .knownEmpty }
                else { state = .missing }
                return DailyMetric(localDay: localDay(day.start,
                                                      timeZoneIdentifier: timeZoneIdentifier),
                                   dayStart: day.start,
                                   dayEnd: day.end,
                                   heartRateState: state,
                                   observedHeartRate: distribution,
                                   representedMinuteCount: representedMinutes,
                                   missingMinuteCount: max(0, totalMinutes - representedMinutes))
            }
        }
    }

    private static func stepDays(
        days: [DateInterval],
        chunks: [AtriaHistoricalAggregateChunk],
        timeZoneIdentifier: String
    ) throws -> [StepDay] {
        // Flatten once before the day loop instead of O(days x epochs) per day.
        let allMotionEpochs = chunks.flatMap(\.motionEpochs)
        return try days.map { day in
            // Bound the per-day temporaries across a long projection pass. The
            // inner `continue`/`throw` stay within this closure: `continue`
            // targets the local `for epoch` loop and `throw` rethrows out of
            // `autoreleasepool`.
            try autoreleasepool {
                let epochs = allMotionEpochs.filter {
                    $0.end > day.start && $0.start < day.end
                }.sorted {
                    if $0.start != $1.start { return $0.start < $1.start }
                    return $0.end < $1.end
                }
                var accepted: [(DateInterval, Int)] = []
                var rejected = 0
                for epoch in epochs {
                    guard epoch.start >= day.start,
                          epoch.end <= day.end,
                          epoch.measurementValidated,
                          let delta = epoch.stepDelta,
                          delta >= 0 else {
                        rejected += 1
                        continue
                    }
                    let interval = DateInterval(start: epoch.start, end: epoch.end)
                    if let previous = accepted.last, interval.start < previous.0.end {
                        // Overlapping known deltas cannot be summed safely.
                        throw ProjectionError.invalidStepEvidence
                    }
                    accepted.append((interval, delta))
                }
                let knownDuration = accepted.reduce(0.0) { $0 + $1.0.duration }
                guard knownDuration.isFinite,
                      knownDuration >= 0,
                      knownDuration <= Double(Int.max),
                      day.duration.isFinite,
                      day.duration >= 0,
                      day.duration <= Double(Int.max) else {
                    throw ProjectionError.arithmeticOverflow
                }
                let knownSeconds = Int(knownDuration.rounded())
                let daySeconds = Int(day.duration.rounded())
                let fullyCovered = accepted.first?.0.start == day.start
                    && accepted.last?.0.end == day.end
                    && zip(accepted, accepted.dropFirst()).allSatisfy { $0.0.0.end == $0.1.0.start }
                    && knownSeconds == daySeconds
                let sum = try safeSum(accepted.map { $0.1 })
                let state: EvidenceState = fullyCovered ? (sum == 0 ? .knownEmpty : .available) : .missing
                return StepDay(localDay: localDay(day.start,
                                                  timeZoneIdentifier: timeZoneIdentifier),
                               dayStart: day.start,
                               dayEnd: day.end,
                               state: state,
                               stepCount: fullyCovered ? sum : nil,
                               knownStepDeltaSum: sum,
                               knownEpochCount: accepted.count,
                               rejectedOrUnknownEpochCount: rejected,
                               knownCoverageSeconds: min(daySeconds, knownSeconds),
                               missingCoverageSeconds: max(0, daySeconds - knownSeconds))
            }
        }
    }

    private static func validatedInspectionEvidence(
        _ proof: InspectionProof,
        covering range: ClosedRange<Date>,
        dependencies: [Dependency]
    ) throws -> InspectionEvidence {
        guard !proof.catalogSnapshot.isEmpty, !proof.scanGenerationManifest.isEmpty else {
            throw ProjectionError.invalidInspectionProof
        }
        let manifest: ScanGenerationManifest
        do { manifest = try JSONDecoder().decode(ScanGenerationManifest.self,
                                                 from: proof.scanGenerationManifest) }
        catch { throw ProjectionError.invalidInspectionProof }
        let intervals = manifest.closedCoverageIntervals
        guard manifest.schema == ScanGenerationManifest.currentSchema,
              !manifest.generationIdentifier.isEmpty,
              isSHA256(manifest.catalogContentSHA256),
              manifest.catalogContentSHA256 == sha256(proof.catalogSnapshot),
              try canonicalData(manifest) == proof.scanGenerationManifest,
              manifest.dependencies == manifest.dependencies.sorted(by: dependencyOrder),
              manifest.dependencies == dependencies,
              !intervals.isEmpty,
              intervals == intervals.sorted(by: intervalOrder),
              intervals.allSatisfy({ $0.end >= $0.start && $0.recordCount >= 0 }) else {
            throw ProjectionError.invalidInspectionProof
        }
        var through: Date?
        for interval in intervals where interval.end >= range.lowerBound {
            if through == nil {
                guard interval.start <= range.lowerBound else {
                    throw ProjectionError.incompleteInspectionCoverage
                }
                through = interval.end
            } else if interval.start <= through! {
                through = max(through!, interval.end)
            } else {
                throw ProjectionError.incompleteInspectionCoverage
            }
            if through! >= range.upperBound { break }
        }
        guard let through, through >= range.upperBound else {
            throw ProjectionError.incompleteInspectionCoverage
        }
        return .init(generationIdentifier: manifest.generationIdentifier,
                     catalogContentSHA256: manifest.catalogContentSHA256,
                     scanGenerationManifestSHA256: sha256(proof.scanGenerationManifest),
                     closedCoverageIntervals: intervals)
    }

    private static func validate(_ configuration: Configuration) throws {
        guard TimeZone(identifier: configuration.timeZoneIdentifier) != nil,
              !configuration.dayBoundaryPolicyVersion.isEmpty else {
            throw ProjectionError.invalidConfiguration
        }
    }

    private static func validate(_ artifact: DailyMetricsArtifact) throws {
        guard artifact.schema == schema,
              artifact.algorithmVersion == dailyMetricsAlgorithmVersion,
              artifact.configurationSHA256 == (try configurationSHA256(for: artifact.configuration)),
              validCommon(source: artifact.source,
                          dependencies: artifact.dependencies,
                          dependencyStart: artifact.dependencyStart,
                          dependencyEnd: artifact.dependencyEnd,
                          completionWatermark: artifact.completionWatermark,
                          days: artifact.days.map { ($0.dayStart, $0.dayEnd, $0.localDay) }),
              artifact.days.allSatisfy(validDailyMetric) else {
            throw ProjectionError.invalidArtifact
        }
    }

    private static func validate(_ artifact: StepsArtifact) throws {
        guard artifact.schema == schema,
              artifact.algorithmVersion == stepsAlgorithmVersion,
              artifact.configurationSHA256 == (try configurationSHA256(for: artifact.configuration)),
              validCommon(source: artifact.source,
                          dependencies: artifact.dependencies,
                          dependencyStart: artifact.dependencyStart,
                          dependencyEnd: artifact.dependencyEnd,
                          completionWatermark: artifact.completionWatermark,
                          days: artifact.days.map { ($0.dayStart, $0.dayEnd, $0.localDay) }),
              artifact.days.allSatisfy(validStepDay) else {
            throw ProjectionError.invalidArtifact
        }
    }

    private static func validCommon(
        source: Source,
        dependencies: [Dependency],
        dependencyStart: Date,
        dependencyEnd: Date,
        completionWatermark: Date,
        days: [(Date, Date, String)]
    ) -> Bool {
        isSHA256(source.rawSHA256) && isSHA256(source.aggregateContentSHA256)
            && source.lastTimestamp > source.firstTimestamp
            && dependencies == dependencies.sorted(by: dependencyOrder)
            && dependencies.contains(where: { $0.chunkID == source.chunkID
                && $0.rawSHA256 == source.rawSHA256
                && $0.aggregateContentSHA256 == source.aggregateContentSHA256 })
            && dependencies.allSatisfy { isSHA256($0.rawSHA256) && isSHA256($0.aggregateContentSHA256) }
            && dependencyStart <= source.firstTimestamp
            && dependencyEnd > source.lastTimestamp
            && completionWatermark >= dependencyEnd
            && !days.isEmpty
            && days.first?.0 == dependencyStart
            && days.last?.1 == dependencyEnd
            && zip(days, days.dropFirst()).allSatisfy { $0.0.1 == $0.1.0 }
            && days.allSatisfy { $0.1 > $0.0 && !$0.2.isEmpty }
    }

    private static func validDailyMetric(_ day: DailyMetric) -> Bool {
        guard day.dayEnd > day.dayStart,
              day.representedMinuteCount >= 0,
              day.missingMinuteCount >= 0 else { return false }
        switch day.heartRateState {
        case .available:
            return day.observedHeartRate.map { $0.sampleCount > 0 && valid($0) } ?? false
        case .knownEmpty:
            return day.observedHeartRate == nil && day.missingMinuteCount == 0
        case .missing:
            return day.missingMinuteCount > 0
                && (day.observedHeartRate.map(valid) ?? true)
        }
    }

    private static func valid(_ value: HeartRateDistribution) -> Bool {
        value.sampleCount > 0
            && value.samplesByBPM.values.reduce(0, +) == value.sampleCount
            && value.samplesByBPM.reduce(Int64(0)) { $0 + Int64($1.key * $1.value) } == value.sumBPM
            && value.minimumBPM == value.samplesByBPM.keys.min()
            && value.maximumBPM == value.samplesByBPM.keys.max()
            && value.terminalBPMSeconds.values.allSatisfy { $0.isFinite && $0 >= 0 }
            && value.transitionHalfBPMSeconds.values.allSatisfy { $0.isFinite && $0 >= 0 }
            && value.coveredSeconds.isFinite && value.coveredSeconds >= 0
            && value.droppedGapSeconds.isFinite && value.droppedGapSeconds >= 0
    }

    private static func validStepDay(_ day: StepDay) -> Bool {
        guard day.dayEnd > day.dayStart,
              day.knownStepDeltaSum >= 0,
              day.knownEpochCount >= 0,
              day.rejectedOrUnknownEpochCount >= 0,
              day.knownCoverageSeconds >= 0,
              day.missingCoverageSeconds >= 0 else { return false }
        switch day.state {
        case .available:
            return day.stepCount.map { $0 > 0 && $0 == day.knownStepDeltaSum } ?? false
                && day.missingCoverageSeconds == 0
        case .knownEmpty:
            return day.stepCount == 0 && day.knownStepDeltaSum == 0
                && day.missingCoverageSeconds == 0
        case .missing:
            return day.stepCount == nil && day.missingCoverageSeconds > 0
        }
    }

    private static func validatedAndSorted(
        _ chunks: [AtriaHistoricalAggregateChunk]
    ) throws -> [AtriaHistoricalAggregateChunk] {
        var byID: [String: AtriaHistoricalAggregateChunk] = [:]
        for chunk in chunks {
            do { try chunk.validateForCommit() }
            catch { throw ProjectionError.invalidAggregate(chunk.source.chunkID) }
            guard isSHA256(chunk.source.rawSHA256) else {
                throw ProjectionError.invalidAggregate(chunk.source.chunkID)
            }
            if let existing = byID[chunk.source.chunkID] {
                guard existing == chunk else {
                    throw ProjectionError.duplicateDependency(chunk.source.chunkID)
                }
            } else { byID[chunk.source.chunkID] = chunk }
        }
        return byID.values.sorted(by: aggregateOrder)
    }

    private static func projectionSource(_ chunk: AtriaHistoricalAggregateChunk) throws -> Source {
        .init(chunkID: chunk.source.chunkID,
              rawSHA256: chunk.source.rawSHA256,
              firstTimestamp: chunk.source.firstTimestamp,
              lastTimestamp: chunk.source.lastTimestamp,
              aggregateContentSHA256: try aggregateDigest(chunk))
    }

    private static func dependency(_ chunk: AtriaHistoricalAggregateChunk) throws -> Dependency {
        .init(chunkID: chunk.source.chunkID,
              rawSHA256: chunk.source.rawSHA256,
              firstTimestamp: chunk.source.firstTimestamp,
              lastTimestamp: chunk.source.lastTimestamp,
              aggregateContentSHA256: try aggregateDigest(chunk))
    }

    private static func aggregateDigest(_ chunk: AtriaHistoricalAggregateChunk) throws -> String {
        sha256(try canonicalData(chunk))
    }

    private static func ledgerSource(
        _ source: AtriaHistoricalAggregateChunk
    ) -> AtriaHistoricalConsumerReceiptLedger.Source {
        .init(chunkID: source.source.chunkID,
              rawSHA256: source.source.rawSHA256,
              firstTimestamp: source.source.firstTimestamp,
              lastTimestamp: source.source.lastTimestamp)
    }

    private static func receiptMatches(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        kind: AtriaHistoricalAggregateChunk.MaterializedProjection.Kind,
        algorithmVersion: String,
        source: AtriaHistoricalAggregateChunk,
        configurationSHA256: String,
        dependencyStart: Date,
        dependencyEnd: Date,
        completionWatermark: Date,
        recordCount: Int,
        artifact: Data
    ) -> Bool {
        receipt.kind == kind
            && receipt.consumerSchemaVersion == schema
            && receipt.algorithmVersion == algorithmVersion
            && receipt.configurationSHA256 == configurationSHA256
            && receipt.source == ledgerSource(source)
            && receipt.dependencyStart == dependencyStart
            && receipt.dependencyEnd == dependencyEnd
            && receipt.completionWatermark == completionWatermark
            && receipt.outcome == .materialized
            && receipt.recordCount == recordCount
            && receipt.artifactByteCount == UInt64(artifact.count)
            && receipt.artifactSHA256 == sha256(artifact)
    }

    private static func mergedIntegerMaps(_ maps: [[Int: Int]]) throws -> [Int: Int] {
        var result: [Int: Int] = [:]
        for map in maps {
            for (key, value) in map {
                let (sum, overflow) = result[key, default: 0].addingReportingOverflow(value)
                guard !overflow else { throw ProjectionError.arithmeticOverflow }
                result[key] = sum
            }
        }
        return result
    }

    private static func mergedDoubleMaps(_ maps: [[Int: Double]]) throws -> [Int: Double] {
        var result: [Int: Double] = [:]
        for map in maps {
            for (key, value) in map {
                let sum = result[key, default: 0] + value
                guard sum.isFinite else { throw ProjectionError.arithmeticOverflow }
                result[key] = sum
            }
        }
        return result
    }

    private static func safeSum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw ProjectionError.arithmeticOverflow }
            return sum
        }
    }

    private static func safeSum(_ values: [Int64]) throws -> Int64 {
        try values.reduce(Int64(0)) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw ProjectionError.arithmeticOverflow }
            return sum
        }
    }

    private static func localDay(_ date: Date, timeZoneIdentifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year!, components.month!, components.day!)
    }

    private static func aggregateOrder(
        _ lhs: AtriaHistoricalAggregateChunk,
        _ rhs: AtriaHistoricalAggregateChunk
    ) -> Bool {
        lhs.source.firstTimestamp != rhs.source.firstTimestamp
            ? lhs.source.firstTimestamp < rhs.source.firstTimestamp
            : lhs.source.chunkID < rhs.source.chunkID
    }

    private static func dependencyOrder(_ lhs: Dependency, _ rhs: Dependency) -> Bool {
        lhs.firstTimestamp != rhs.firstTimestamp
            ? lhs.firstTimestamp < rhs.firstTimestamp
            : lhs.chunkID < rhs.chunkID
    }

    private static func intervalOrder(
        _ lhs: ClosedCoverageInterval,
        _ rhs: ClosedCoverageInterval
    ) -> Bool {
        lhs.start != rhs.start ? lhs.start < rhs.start : lhs.end < rhs.end
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func isSHA256(_ value: String) -> Bool {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count == 64 && value.unicodeScalars.allSatisfy(lowercaseHex.contains)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
