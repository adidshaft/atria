import CryptoKit
import Foundation

/// Cryptographic evidence that an immutable catalog generation was inspected
/// across a closed time range. A timestamp alone is deliberately insufficient
/// to certify a historical no-result decision.
struct AtriaHistoricalSessionInspectionProof: Equatable, Sendable {
    struct ClosedCoverageInterval: Codable, Equatable, Sendable {
        let start: Date
        let end: Date
        /// Zero explicitly records that the durable scan found no catalog rows.
        let recordCount: Int
    }

    struct Evidence: Codable, Equatable, Sendable {
        let generationIdentifier: String
        let catalogContentSHA256: String
        let scanGenerationManifestSHA256: String
        let closedCoverageIntervals: [ClosedCoverageInterval]
    }

    private struct Manifest: Codable, Equatable {
        static let currentSchema = 1

        let schema: Int
        let generationIdentifier: String
        let catalogContentSHA256: String
        let closedCoverageIntervals: [ClosedCoverageInterval]

        func canonicalData() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }
    }

    let catalogSnapshot: Data
    let scanGenerationManifest: Data

    static func make(
        generationIdentifier: String,
        catalogSnapshot: Data,
        closedCoverageIntervals: [ClosedCoverageInterval]
    ) throws -> Self {
        guard !generationIdentifier.isEmpty, !catalogSnapshot.isEmpty else {
            throw AtriaHistoricalSessionProjectionError.invalidInspectionProof
        }
        let intervals = closedCoverageIntervals.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        let manifest = Manifest(schema: Manifest.currentSchema,
                                generationIdentifier: generationIdentifier,
                                catalogContentSHA256: sha256(catalogSnapshot),
                                closedCoverageIntervals: intervals)
        return .init(catalogSnapshot: catalogSnapshot,
                     scanGenerationManifest: try manifest.canonicalData())
    }

    func validatedEvidence(covering requiredRange: ClosedRange<Date>) throws -> Evidence {
        guard !catalogSnapshot.isEmpty, !scanGenerationManifest.isEmpty else {
            throw AtriaHistoricalSessionProjectionError.invalidInspectionProof
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: scanGenerationManifest)
        } catch {
            throw AtriaHistoricalSessionProjectionError.invalidInspectionProof
        }
        let intervals = manifest.closedCoverageIntervals
        guard manifest.schema == Manifest.currentSchema,
              !manifest.generationIdentifier.isEmpty,
              Self.isSHA256(manifest.catalogContentSHA256),
              manifest.catalogContentSHA256 == Self.sha256(catalogSnapshot),
              try manifest.canonicalData() == scanGenerationManifest,
              !intervals.isEmpty,
              intervals == intervals.sorted(by: {
                  if $0.start != $1.start { return $0.start < $1.start }
                  return $0.end < $1.end
              }),
              intervals.allSatisfy({ interval in
                  interval.start.timeIntervalSince1970.isFinite
                      && interval.end.timeIntervalSince1970.isFinite
                      && interval.end >= interval.start
                      && interval.recordCount >= 0
              }) else {
            throw AtriaHistoricalSessionProjectionError.invalidInspectionProof
        }

        var coveredThrough: Date?
        for interval in intervals where interval.end >= requiredRange.lowerBound {
            if coveredThrough == nil {
                guard interval.start <= requiredRange.lowerBound else {
                    throw AtriaHistoricalSessionProjectionError.incompleteInspectionCoverage
                }
                coveredThrough = interval.end
            } else if interval.start <= coveredThrough! {
                coveredThrough = max(coveredThrough!, interval.end)
            } else {
                throw AtriaHistoricalSessionProjectionError.incompleteInspectionCoverage
            }
            if coveredThrough! >= requiredRange.upperBound { break }
        }
        guard let coveredThrough, coveredThrough >= requiredRange.upperBound else {
            throw AtriaHistoricalSessionProjectionError.incompleteInspectionCoverage
        }
        return .init(generationIdentifier: manifest.generationIdentifier,
                     catalogContentSHA256: manifest.catalogContentSHA256,
                     scanGenerationManifestSHA256: Self.sha256(scanGenerationManifest),
                     closedCoverageIntervals: intervals)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "0123456789abcdef").contains
        )
    }
}

enum AtriaHistoricalSessionProjectionError: Error, Equatable {
    case invalidConfiguration
    case invalidAggregate(String)
    case duplicateDependency(String)
    case sourceMissing
    case sourceMismatch
    case invalidInspectionProof
    case incompleteInspectionCoverage
    case insufficientLookahead
    case numericOverflow
    case productionCatalogAttestationRequired
    case invalidArtifact
}

enum AtriaHistoricalSessionProjectionSupport {
    struct Source: Codable, Equatable, Sendable {
        let chunkID: String
        let rawSHA256: String
        let firstTimestamp: Date
        let lastTimestamp: Date
        let aggregateFactsSHA256: String
    }

    struct Dependency: Codable, Equatable, Sendable {
        let chunkID: String
        let rawSHA256: String
        let firstTimestamp: Date
        let lastTimestamp: Date
        let aggregateFactsSHA256: String
    }

    private struct AggregateFacts: Codable {
        let source: AtriaHistoricalAggregateChunk.Source
        let heartRateMinutes: [AtriaHistoricalAggregateChunk.HeartRateMinute]
        let motionEpochs: [AtriaHistoricalAggregateChunk.MotionEpoch]
    }

    static func validatedAndSorted(
        _ chunks: [AtriaHistoricalAggregateChunk]
    ) throws -> [AtriaHistoricalAggregateChunk] {
        var byID: [String: AtriaHistoricalAggregateChunk] = [:]
        for chunk in chunks {
            do {
                try chunk.validateForCommit()
            } catch {
                throw AtriaHistoricalSessionProjectionError.invalidAggregate(chunk.source.chunkID)
            }
            guard isSHA256(chunk.source.rawSHA256) else {
                throw AtriaHistoricalSessionProjectionError.invalidAggregate(chunk.source.chunkID)
            }
            if let existing = byID[chunk.source.chunkID] {
                guard existing == chunk else {
                    throw AtriaHistoricalSessionProjectionError.duplicateDependency(chunk.source.chunkID)
                }
            } else {
                byID[chunk.source.chunkID] = chunk
            }
        }
        return byID.values.sorted {
            if $0.source.firstTimestamp != $1.source.firstTimestamp {
                return $0.source.firstTimestamp < $1.source.firstTimestamp
            }
            return $0.source.chunkID < $1.source.chunkID
        }
    }

    static func source(
        _ source: AtriaHistoricalAggregateChunk,
        in chunks: [AtriaHistoricalAggregateChunk]
    ) throws -> Source {
        guard let matching = chunks.first(where: { $0.source.chunkID == source.source.chunkID }) else {
            throw AtriaHistoricalSessionProjectionError.sourceMissing
        }
        guard matching == source else { throw AtriaHistoricalSessionProjectionError.sourceMismatch }
        return .init(chunkID: source.source.chunkID,
                     rawSHA256: source.source.rawSHA256,
                     firstTimestamp: source.source.firstTimestamp,
                     lastTimestamp: source.source.lastTimestamp,
                     aggregateFactsSHA256: try factsSHA256(source))
    }

    static func dependencies(
        _ chunks: [AtriaHistoricalAggregateChunk],
        overlapping range: ClosedRange<Date>
    ) throws -> [Dependency] {
        try chunks.filter {
            $0.source.lastTimestamp >= range.lowerBound && $0.source.firstTimestamp <= range.upperBound
        }.map {
            .init(chunkID: $0.source.chunkID,
                  rawSHA256: $0.source.rawSHA256,
                  firstTimestamp: $0.source.firstTimestamp,
                  lastTimestamp: $0.source.lastTimestamp,
                  aggregateFactsSHA256: try factsSHA256($0))
        }
    }

    static func relevantChunks(
        _ chunks: [AtriaHistoricalAggregateChunk],
        overlapping range: ClosedRange<Date>
    ) -> [AtriaHistoricalAggregateChunk] {
        chunks.filter {
            $0.source.lastTimestamp >= range.lowerBound && $0.source.firstTimestamp <= range.upperBound
        }
    }

    static func ledgerSource(
        _ source: AtriaHistoricalAggregateChunk
    ) -> AtriaHistoricalConsumerReceiptLedger.Source {
        .init(chunkID: source.source.chunkID,
              rawSHA256: source.source.rawSHA256,
              firstTimestamp: source.source.firstTimestamp,
              lastTimestamp: source.source.lastTimestamp)
    }

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256<T: Encodable>(_ value: T) throws -> String {
        sha256(try canonicalData(value))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "0123456789abcdef").contains
        )
    }

    static func localDay(_ date: Date, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func factsSHA256(_ chunk: AtriaHistoricalAggregateChunk) throws -> String {
        try sha256(AggregateFacts(
            source: chunk.source,
            heartRateMinutes: chunk.heartRateMinutes.sorted { $0.minuteStart < $1.minuteStart },
            motionEpochs: chunk.motionEpochs.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
        ))
    }
}

/// Conservative historical sleep decisions. This does not claim parity with
/// the actor-bound live detector: a candidate requires dense, validated motion
/// evidence and can never be synthesized from heart rate alone.
struct AtriaHistoricalSleepProjection: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let algorithmVersion = "historical-sleep-conservative-v1"
    static let requiredHistory: TimeInterval = 12 * 60 * 60
    static let requiredLookahead: TimeInterval = 4 * 60 * 60

    typealias Source = AtriaHistoricalSessionProjectionSupport.Source
    typealias Dependency = AtriaHistoricalSessionProjectionSupport.Dependency

    struct Configuration: Codable, Equatable, Sendable {
        let timeZoneIdentifier: String
        let minimumDurationSeconds: Int
        let minimumValidatedMotionCoverage: Double
        let stillnessThreshold: Double
        let maximumMovementIntensity: Double
    }

    enum Confidence: String, Codable, Equatable, Sendable {
        case medium
        case high
    }

    struct Coverage: Codable, Equatable, Sendable {
        let spanSeconds: Int
        let validatedMotionSeconds: Int
        let validatedMotionRatio: Double
        let heartRateMinutes: Int
        let expectedHeartRateMinutes: Int
        let heartRateCoverageRatio: Double
        let contributingChunkIDs: [String]
        let motionAlgorithmVersions: [String]
        let motionProvenance: [String]
    }

    struct Candidate: Codable, Equatable, Sendable {
        let identifier: String
        let start: Date
        let end: Date
        let localDay: String
        let confidence: Confidence
        let coverage: Coverage
    }

    enum CompletionState: String, Codable, Equatable, Sendable { case complete }

    let schema: Int
    let algorithmVersion: String
    let configuration: Configuration
    let configurationSHA256: String
    let source: Source
    let dependencies: [Dependency]
    let inspectionEvidence: AtriaHistoricalSessionInspectionProof.Evidence
    let dependencyStart: Date
    let dependencyEnd: Date
    let completionWatermark: Date
    let completionState: CompletionState
    let candidates: [Candidate]

    var outcome: AtriaHistoricalConsumerReceiptLedger.Outcome {
        candidates.isEmpty ? .explicitlyEmpty : .materialized
    }

    static func configurationSHA256(for configuration: Configuration) throws -> String {
        try validate(configuration)
        return try AtriaHistoricalSessionProjectionSupport.sha256(
            CanonicalConfiguration(schema: currentSchema,
                                   algorithmVersion: algorithmVersion,
                                   configuration: configuration,
                                   maximumQualifiedEpochGapSeconds: 90,
                                   highConfidenceMotionCoverage: 0.90,
                                   highConfidenceHeartRateCoverage: 0.50)
        )
    }

    static func build(
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: AtriaHistoricalSessionInspectionProof,
        completionWatermark: Date
    ) throws -> Self {
        try validate(configuration)
        let dependencyStart = source.source.firstTimestamp.addingTimeInterval(-requiredHistory)
        let dependencyEnd = source.source.lastTimestamp.addingTimeInterval(requiredLookahead)
        guard completionWatermark >= dependencyEnd else {
            throw AtriaHistoricalSessionProjectionError.insufficientLookahead
        }
        let evidence = try inspectionProof.validatedEvidence(covering: dependencyStart...dependencyEnd)
        let chunks = try AtriaHistoricalSessionProjectionSupport.validatedAndSorted(dependencyChunks)
        let projectionSource = try AtriaHistoricalSessionProjectionSupport.source(source, in: chunks)
        let range = dependencyStart...dependencyEnd
        let relevant = AtriaHistoricalSessionProjectionSupport.relevantChunks(chunks, overlapping: range)
        let dependencies = try AtriaHistoricalSessionProjectionSupport.dependencies(relevant,
                                                                                     overlapping: range)
        let digest = try configurationSHA256(for: configuration)
        let candidates = try detectCandidates(in: relevant,
                                              overlapping: source.source.firstTimestamp...source.source.lastTimestamp,
                                              configuration: configuration,
                                              configurationSHA256: digest,
                                              dependencyRange: range)
        return .init(schema: currentSchema,
                     algorithmVersion: algorithmVersion,
                     configuration: configuration,
                     configurationSHA256: digest,
                     source: projectionSource,
                     dependencies: dependencies,
                     inspectionEvidence: evidence,
                     dependencyStart: dependencyStart,
                     dependencyEnd: dependencyEnd,
                     completionWatermark: completionWatermark,
                     completionState: .complete,
                     candidates: candidates)
    }

    func encodedArtifact() throws -> Data {
        guard schema == Self.currentSchema,
              algorithmVersion == Self.algorithmVersion,
              configurationSHA256 == (try? Self.configurationSHA256(for: configuration)),
              completionWatermark >= dependencyEnd,
              completionState == .complete,
              candidates == candidates.sorted(by: Self.candidateSort),
              candidates.allSatisfy({ Self.validCandidate($0, configuration: configuration) }) else {
            throw AtriaHistoricalSessionProjectionError.invalidArtifact
        }
        return try AtriaHistoricalSessionProjectionSupport.canonicalData(self)
    }

    static func decodeAndVerify(
        _ artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: AtriaHistoricalSessionInspectionProof,
        completionWatermark: Date
    ) throws -> Self {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: artifact) else {
            throw AtriaHistoricalSessionProjectionError.invalidArtifact
        }
        let rebuilt = try build(source: source,
                                dependencyChunks: dependencyChunks,
                                configuration: configuration,
                                inspectionProof: inspectionProof,
                                completionWatermark: completionWatermark)
        guard decoded == rebuilt, try decoded.encodedArtifact() == artifact else {
            throw AtriaHistoricalSessionProjectionError.invalidArtifact
        }
        return decoded
    }

    static func publishReceipt(
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: AtriaHistoricalSessionInspectionProof,
        completionWatermark: Date,
        ledger: AtriaHistoricalConsumerReceiptLedger,
        settledAt: Date
    ) throws -> AtriaHistoricalConsumerReceiptLedger.Published {
        let projection = try build(source: source,
                                   dependencyChunks: dependencyChunks,
                                   configuration: configuration,
                                   inspectionProof: inspectionProof,
                                   completionWatermark: completionWatermark)
        return try ledger.publish(.init(
            source: AtriaHistoricalSessionProjectionSupport.ledgerSource(source),
            kind: .sleep,
            consumerSchemaVersion: currentSchema,
            algorithmVersion: algorithmVersion,
            configurationSHA256: projection.configurationSHA256,
            dependencyStart: projection.dependencyStart,
            dependencyEnd: projection.dependencyEnd,
            completionWatermark: projection.completionWatermark,
            outcome: projection.outcome,
            recordCount: projection.candidates.count,
            artifact: try projection.encodedArtifact(),
            settledAt: settledAt
        ))
    }

    static func verifyReceipt(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: AtriaHistoricalSessionInspectionProof,
        completionWatermark: Date
    ) throws -> Bool {
        _ = try verifyShadowReceipt(receipt,
                                    artifact: artifact,
                                    source: source,
                                    dependencyChunks: dependencyChunks,
                                    configuration: configuration,
                                    inspectionProof: inspectionProof,
                                    completionWatermark: completionWatermark)
        // Caller-constructed catalog bytes are adequate for deterministic
        // shadow parity tests, but never sufficient to authorize raw expiry.
        throw AtriaHistoricalSessionProjectionError.productionCatalogAttestationRequired
    }

    static func verifyShadowReceipt(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: AtriaHistoricalSessionInspectionProof,
        completionWatermark: Date
    ) throws -> Bool {
        let expected = try build(source: source,
                                 dependencyChunks: dependencyChunks,
                                 configuration: configuration,
                                 inspectionProof: inspectionProof,
                                 completionWatermark: completionWatermark)
        guard receipt.kind == .sleep,
              receipt.consumerSchemaVersion == currentSchema,
              receipt.algorithmVersion == algorithmVersion,
              receipt.configurationSHA256 == expected.configurationSHA256,
              receipt.source == AtriaHistoricalSessionProjectionSupport.ledgerSource(source),
              receipt.dependencyStart == expected.dependencyStart,
              receipt.dependencyEnd == expected.dependencyEnd,
              receipt.completionWatermark == expected.completionWatermark,
              receipt.outcome == expected.outcome,
              receipt.recordCount == expected.candidates.count else { return false }
        return try decodeAndVerify(artifact,
                                   source: source,
                                   dependencyChunks: dependencyChunks,
                                   configuration: configuration,
                                   inspectionProof: inspectionProof,
                                   completionWatermark: completionWatermark) == expected
    }

    private struct CanonicalConfiguration: Codable {
        let schema: Int
        let algorithmVersion: String
        let configuration: Configuration
        let maximumQualifiedEpochGapSeconds: Int
        let highConfidenceMotionCoverage: Double
        let highConfidenceHeartRateCoverage: Double
    }

    private struct CandidateIdentity: Codable {
        let schema: Int
        let algorithmVersion: String
        let configurationSHA256: String
        let start: Date
        let end: Date
        let contributingChunkIDs: [String]
    }

    private struct QualifiedEpoch {
        let fact: AtriaHistoricalAggregateChunk.MotionEpoch
        let chunkID: String
    }

    private static func validate(_ configuration: Configuration) throws {
        guard TimeZone(identifier: configuration.timeZoneIdentifier) != nil,
              (60 * 60...16 * 60 * 60).contains(configuration.minimumDurationSeconds),
              (0.5...1).contains(configuration.minimumValidatedMotionCoverage),
              (0.5...1).contains(configuration.stillnessThreshold),
              configuration.maximumMovementIntensity.isFinite,
              configuration.maximumMovementIntensity >= 0 else {
            throw AtriaHistoricalSessionProjectionError.invalidConfiguration
        }
    }

    private static func detectCandidates(
        in chunks: [AtriaHistoricalAggregateChunk],
        overlapping sourceRange: ClosedRange<Date>,
        configuration: Configuration,
        configurationSHA256: String,
        dependencyRange: ClosedRange<Date>
    ) throws -> [Candidate] {
        let epochs: [QualifiedEpoch] = chunks.flatMap { chunk in
            chunk.motionEpochs.compactMap { fact in
                guard fact.start >= dependencyRange.lowerBound,
                      fact.end <= dependencyRange.upperBound,
                      fact.measurementValidated,
                      fact.lowMotionQualified,
                      fact.coverageSeconds >= 15,
                      fact.maximumGapSeconds <= 15,
                      (fact.stillnessRatio ?? 0) >= configuration.stillnessThreshold,
                      (fact.movementIntensity ?? .infinity) <= configuration.maximumMovementIntensity else {
                    return nil
                }
                return QualifiedEpoch(fact: fact, chunkID: chunk.source.chunkID)
            }
        }.sorted {
            if $0.fact.start != $1.fact.start { return $0.fact.start < $1.fact.start }
            return $0.chunkID < $1.chunkID
        }

        var groups: [[QualifiedEpoch]] = []
        for epoch in epochs {
            if let last = groups.last?.last, epoch.fact.start <= last.fact.end.addingTimeInterval(90) {
                groups[groups.count - 1].append(epoch)
            } else {
                groups.append([epoch])
            }
        }

        // Flatten once before the group loop instead of O(groups x facts) per
        // group.
        let allHeartRateMinutes = chunks.flatMap(\.heartRateMinutes)
        var result: [Candidate] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let start = first.fact.start
            let end = group.map(\.fact.end).max() ?? last.fact.end
            let span = Int(end.timeIntervalSince(start).rounded())
            guard span >= configuration.minimumDurationSeconds,
                  end >= sourceRange.lowerBound,
                  start <= sourceRange.upperBound else { continue }

            let validatedSeconds = min(span, conservativeCoveredSeconds(in: group))
            let motionRatio = roundedRatio(validatedSeconds, span)
            guard motionRatio >= configuration.minimumValidatedMotionCoverage else { continue }
            let expectedHRMinutes = max(1, Int(ceil(Double(span) / 60)))
            let hrStarts = Set(allHeartRateMinutes.filter {
                $0.minuteStart >= start && $0.minuteStart < end && $0.sampleCount > 0
            }.map { Int64(floor($0.minuteStart.timeIntervalSince1970 / 60)) })
            let hrRatio = roundedRatio(hrStarts.count, expectedHRMinutes)
            let chunkIDs = Array(Set(group.map(\.chunkID))).sorted()
            let algorithms = Array(Set(group.map(\.fact.algorithmVersion))).sorted()
            let provenance = Array(Set(group.map(\.fact.provenance))).sorted()
            let confidence: Confidence = motionRatio >= 0.90 && hrRatio >= 0.50 ? .high : .medium
            let identity = CandidateIdentity(schema: currentSchema,
                                             algorithmVersion: algorithmVersion,
                                             configurationSHA256: configurationSHA256,
                                             start: start,
                                             end: end,
                                             contributingChunkIDs: chunkIDs)
            let identifier = "sleep-" + (try AtriaHistoricalSessionProjectionSupport.sha256(identity))
            result.append(.init(identifier: identifier,
                                start: start,
                                end: end,
                                localDay: AtriaHistoricalSessionProjectionSupport.localDay(
                                    start, timeZoneIdentifier: configuration.timeZoneIdentifier
                                ),
                                confidence: confidence,
                                coverage: .init(spanSeconds: span,
                                                validatedMotionSeconds: validatedSeconds,
                                                validatedMotionRatio: motionRatio,
                                                heartRateMinutes: hrStarts.count,
                                                expectedHeartRateMinutes: expectedHRMinutes,
                                                heartRateCoverageRatio: hrRatio,
                                                contributingChunkIDs: chunkIDs,
                                                motionAlgorithmVersions: algorithms,
                                                motionProvenance: provenance)))
        }
        return result.sorted(by: candidateSort)
    }

    private static func roundedRatio(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return (Double(numerator) / Double(denominator) * 1_000_000).rounded() / 1_000_000
    }

    /// Counts each wall-clock instant at most once. Adjacent aggregate chunks
    /// may overlap at their boundary; summing epoch coverage directly could
    /// otherwise turn replayed/duplicated motion into alleged full coverage.
    private static func conservativeCoveredSeconds(in group: [QualifiedEpoch]) -> Int {
        var coveredThrough: Date?
        var total = 0.0
        for epoch in group.sorted(by: {
            if $0.fact.start != $1.fact.start { return $0.fact.start < $1.fact.start }
            if $0.fact.end != $1.fact.end { return $0.fact.end < $1.fact.end }
            return $0.chunkID < $1.chunkID
        }) {
            let nonOverlappingStart = max(epoch.fact.start, coveredThrough ?? epoch.fact.start)
            let nonOverlappingDuration = max(0, epoch.fact.end.timeIntervalSince(nonOverlappingStart))
            total += min(nonOverlappingDuration, Double(max(0, epoch.fact.coverageSeconds)))
            coveredThrough = max(coveredThrough ?? epoch.fact.end, epoch.fact.end)
        }
        return max(0, Int(total.rounded()))
    }

    private static func candidateSort(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.identifier < rhs.identifier
    }

    private static func validCandidate(_ value: Candidate, configuration: Configuration) -> Bool {
        value.identifier.hasPrefix("sleep-")
            && value.identifier.count == 70
            && value.end > value.start
            && value.coverage.spanSeconds >= configuration.minimumDurationSeconds
            && value.coverage.validatedMotionRatio >= configuration.minimumValidatedMotionCoverage
            && value.coverage.validatedMotionRatio <= 1
            && value.coverage.heartRateCoverageRatio >= 0
            && value.coverage.heartRateCoverageRatio <= 1
            && !value.coverage.contributingChunkIDs.isEmpty
            && !value.coverage.motionAlgorithmVersions.isEmpty
            && !value.coverage.motionProvenance.isEmpty
            && (value.confidence != .high || (value.coverage.validatedMotionRatio >= 0.90
                && value.coverage.heartRateCoverageRatio >= 0.50))
    }
}

/// Conservative historical workout decisions. Dense elevated HR is mandatory;
/// motion upgrades confidence but sparse HR alone never produces a candidate.
struct AtriaHistoricalWorkoutProjection: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let algorithmVersion = "historical-workout-conservative-v1"
    static let requiredHistory: TimeInterval = 30 * 60
    static let requiredLookahead: TimeInterval = 30 * 60

    typealias Source = AtriaHistoricalSessionProjectionSupport.Source
    typealias Dependency = AtriaHistoricalSessionProjectionSupport.Dependency

    struct Configuration: Codable, Equatable, Sendable {
        let restingHeartRate: Int
        let maximumHeartRate: Int
        let timeZoneIdentifier: String
        let minimumDurationMinutes: Int
        let minimumHeartRateCoverage: Double
    }

    enum Confidence: String, Codable, Equatable, Sendable { case medium, high }

    struct Coverage: Codable, Equatable, Sendable {
        let spanMinutes: Int
        let elevatedHeartRateMinutes: Int
        let denseHeartRateMinutes: Int
        let heartRateCoverageRatio: Double
        let validatedMotionMinutes: Int
        let motionCoverageRatio: Double
        let contributingChunkIDs: [String]
        let motionProvenance: [String]
    }

    struct Candidate: Codable, Equatable, Sendable {
        let identifier: String
        let start: Date
        let end: Date
        let localDay: String
        let confidence: Confidence
        let averageHeartRate: Double
        let maximumHeartRate: Int
        let coverage: Coverage
    }

    enum CompletionState: String, Codable, Equatable, Sendable { case complete }

    let schema: Int
    let algorithmVersion: String
    let configuration: Configuration
    let configurationSHA256: String
    let source: Source
    let dependencies: [Dependency]
    let inspectionEvidence: AtriaHistoricalSessionInspectionProof.Evidence
    let dependencyStart: Date
    let dependencyEnd: Date
    let completionWatermark: Date
    let completionState: CompletionState
    let candidates: [Candidate]

    var outcome: AtriaHistoricalConsumerReceiptLedger.Outcome {
        candidates.isEmpty ? .explicitlyEmpty : .materialized
    }

    static func configurationSHA256(for configuration: Configuration) throws -> String {
        try validate(configuration)
        return try AtriaHistoricalSessionProjectionSupport.sha256(
            CanonicalConfiguration(schema: currentSchema,
                                   algorithmVersion: algorithmVersion,
                                   configuration: configuration,
                                   heartRateReserveFraction: 0.30,
                                   maximumInactiveGapMinutes: 2,
                                   highConfidenceMotionCoverage: 0.50,
                                   denseMinuteMinimumCoveredSeconds: 20)
        )
    }

    static func build(
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: AtriaHistoricalSessionInspectionProof,
        completionWatermark: Date
    ) throws -> Self {
        try validate(configuration)
        let dependencyStart = source.source.firstTimestamp.addingTimeInterval(-requiredHistory)
        let dependencyEnd = source.source.lastTimestamp.addingTimeInterval(requiredLookahead)
        guard completionWatermark >= dependencyEnd else {
            throw AtriaHistoricalSessionProjectionError.insufficientLookahead
        }
        let evidence = try inspectionProof.validatedEvidence(covering: dependencyStart...dependencyEnd)
        let chunks = try AtriaHistoricalSessionProjectionSupport.validatedAndSorted(dependencyChunks)
        let projectionSource = try AtriaHistoricalSessionProjectionSupport.source(source, in: chunks)
        let range = dependencyStart...dependencyEnd
        let relevant = AtriaHistoricalSessionProjectionSupport.relevantChunks(chunks, overlapping: range)
        let dependencies = try AtriaHistoricalSessionProjectionSupport.dependencies(relevant,
                                                                                     overlapping: range)
        let digest = try configurationSHA256(for: configuration)
        let candidates = try detectCandidates(in: relevant,
                                              overlapping: source.source.firstTimestamp...source.source.lastTimestamp,
                                              configuration: configuration,
                                              configurationSHA256: digest,
                                              dependencyRange: range)
        return .init(schema: currentSchema,
                     algorithmVersion: algorithmVersion,
                     configuration: configuration,
                     configurationSHA256: digest,
                     source: projectionSource,
                     dependencies: dependencies,
                     inspectionEvidence: evidence,
                     dependencyStart: dependencyStart,
                     dependencyEnd: dependencyEnd,
                     completionWatermark: completionWatermark,
                     completionState: .complete,
                     candidates: candidates)
    }

    func encodedArtifact() throws -> Data {
        guard schema == Self.currentSchema,
              algorithmVersion == Self.algorithmVersion,
              configurationSHA256 == (try? Self.configurationSHA256(for: configuration)),
              completionWatermark >= dependencyEnd,
              completionState == .complete,
              candidates == candidates.sorted(by: Self.candidateSort),
              candidates.allSatisfy({ Self.validCandidate($0, configuration: configuration) }) else {
            throw AtriaHistoricalSessionProjectionError.invalidArtifact
        }
        return try AtriaHistoricalSessionProjectionSupport.canonicalData(self)
    }

    static func decodeAndVerify(
        _ artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: AtriaHistoricalSessionInspectionProof,
        completionWatermark: Date
    ) throws -> Self {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: artifact) else {
            throw AtriaHistoricalSessionProjectionError.invalidArtifact
        }
        let rebuilt = try build(source: source,
                                dependencyChunks: dependencyChunks,
                                configuration: configuration,
                                inspectionProof: inspectionProof,
                                completionWatermark: completionWatermark)
        guard decoded == rebuilt, try decoded.encodedArtifact() == artifact else {
            throw AtriaHistoricalSessionProjectionError.invalidArtifact
        }
        return decoded
    }

    static func publishReceipt(
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: AtriaHistoricalSessionInspectionProof,
        completionWatermark: Date,
        ledger: AtriaHistoricalConsumerReceiptLedger,
        settledAt: Date
    ) throws -> AtriaHistoricalConsumerReceiptLedger.Published {
        let projection = try build(source: source,
                                   dependencyChunks: dependencyChunks,
                                   configuration: configuration,
                                   inspectionProof: inspectionProof,
                                   completionWatermark: completionWatermark)
        return try ledger.publish(.init(
            source: AtriaHistoricalSessionProjectionSupport.ledgerSource(source),
            kind: .workout,
            consumerSchemaVersion: currentSchema,
            algorithmVersion: algorithmVersion,
            configurationSHA256: projection.configurationSHA256,
            dependencyStart: projection.dependencyStart,
            dependencyEnd: projection.dependencyEnd,
            completionWatermark: projection.completionWatermark,
            outcome: projection.outcome,
            recordCount: projection.candidates.count,
            artifact: try projection.encodedArtifact(),
            settledAt: settledAt
        ))
    }

    static func verifyReceipt(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: AtriaHistoricalSessionInspectionProof,
        completionWatermark: Date
    ) throws -> Bool {
        _ = try verifyShadowReceipt(receipt,
                                    artifact: artifact,
                                    source: source,
                                    dependencyChunks: dependencyChunks,
                                    configuration: configuration,
                                    inspectionProof: inspectionProof,
                                    completionWatermark: completionWatermark)
        throw AtriaHistoricalSessionProjectionError.productionCatalogAttestationRequired
    }

    static func verifyShadowReceipt(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: AtriaHistoricalSessionInspectionProof,
        completionWatermark: Date
    ) throws -> Bool {
        let expected = try build(source: source,
                                 dependencyChunks: dependencyChunks,
                                 configuration: configuration,
                                 inspectionProof: inspectionProof,
                                 completionWatermark: completionWatermark)
        guard receipt.kind == .workout,
              receipt.consumerSchemaVersion == currentSchema,
              receipt.algorithmVersion == algorithmVersion,
              receipt.configurationSHA256 == expected.configurationSHA256,
              receipt.source == AtriaHistoricalSessionProjectionSupport.ledgerSource(source),
              receipt.dependencyStart == expected.dependencyStart,
              receipt.dependencyEnd == expected.dependencyEnd,
              receipt.completionWatermark == expected.completionWatermark,
              receipt.outcome == expected.outcome,
              receipt.recordCount == expected.candidates.count else { return false }
        return try decodeAndVerify(artifact,
                                   source: source,
                                   dependencyChunks: dependencyChunks,
                                   configuration: configuration,
                                   inspectionProof: inspectionProof,
                                   completionWatermark: completionWatermark) == expected
    }

    private struct CanonicalConfiguration: Codable {
        let schema: Int
        let algorithmVersion: String
        let configuration: Configuration
        let heartRateReserveFraction: Double
        let maximumInactiveGapMinutes: Int
        let highConfidenceMotionCoverage: Double
        let denseMinuteMinimumCoveredSeconds: Int
    }

    private struct CandidateIdentity: Codable {
        let schema: Int
        let algorithmVersion: String
        let configurationSHA256: String
        let start: Date
        let end: Date
        let averageHeartRate: Double
        let maximumHeartRate: Int
        let contributingChunkIDs: [String]
    }

    private struct ElevatedMinute {
        let start: Date
        let sumBPM: Int64
        let samples: Int
        let maximumBPM: Int
        let chunkID: String
    }

    private static func validate(_ configuration: Configuration) throws {
        guard (25...150).contains(configuration.restingHeartRate),
              (60...240).contains(configuration.maximumHeartRate),
              configuration.maximumHeartRate >= configuration.restingHeartRate + 20,
              TimeZone(identifier: configuration.timeZoneIdentifier) != nil,
              (5...240).contains(configuration.minimumDurationMinutes),
              (0.5...1).contains(configuration.minimumHeartRateCoverage) else {
            throw AtriaHistoricalSessionProjectionError.invalidConfiguration
        }
    }

    private static func detectCandidates(
        in chunks: [AtriaHistoricalAggregateChunk],
        overlapping sourceRange: ClosedRange<Date>,
        configuration: Configuration,
        configurationSHA256: String,
        dependencyRange: ClosedRange<Date>
    ) throws -> [Candidate] {
        let elevatedThreshold = Double(configuration.restingHeartRate)
            + Double(configuration.maximumHeartRate - configuration.restingHeartRate) * 0.30
        let elevated: [ElevatedMinute] = chunks.flatMap { chunk in
            chunk.heartRateMinutes.compactMap { fact in
                guard fact.minuteStart >= dependencyRange.lowerBound,
                      fact.minuteStart <= dependencyRange.upperBound,
                      fact.sampleCount > 0,
                      fact.coveredSeconds >= 20,
                      Double(fact.sumBPM) / Double(fact.sampleCount) >= elevatedThreshold else {
                    return nil
                }
                let minute = Date(timeIntervalSince1970:
                    floor(fact.minuteStart.timeIntervalSince1970 / 60) * 60)
                return ElevatedMinute(start: minute,
                                      sumBPM: fact.sumBPM,
                                      samples: fact.sampleCount,
                                      maximumBPM: fact.maximumBPM,
                                      chunkID: chunk.source.chunkID)
            }
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.chunkID < $1.chunkID
        }

        var groups: [[ElevatedMinute]] = []
        for minute in elevated {
            if let last = groups.last?.last, minute.start.timeIntervalSince(last.start) <= 3 * 60 {
                groups[groups.count - 1].append(minute)
            } else {
                groups.append([minute])
            }
        }

        // Flatten once before the group loop instead of O(groups x epochs) per
        // group.
        let allMotionEpochs = chunks.flatMap(\.motionEpochs)
        var result: [Candidate] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let start = first.start
            let end = last.start.addingTimeInterval(60)
            let spanMinutes = max(1, Int(ceil(end.timeIntervalSince(start) / 60)))
            let uniqueMinutes = Set(group.map { Int64($0.start.timeIntervalSince1970 / 60) })
            let denseMinutes = uniqueMinutes.count
            let hrRatio = roundedRatio(denseMinutes, spanMinutes)
            guard spanMinutes >= configuration.minimumDurationMinutes,
                  hrRatio >= configuration.minimumHeartRateCoverage,
                  end >= sourceRange.lowerBound,
                  start <= sourceRange.upperBound else { continue }

            let candidateMotionEpochs = allMotionEpochs.filter { epoch in
                epoch.start >= start
                    && epoch.start < end
                    && epoch.measurementValidated
                    && epoch.coverageSeconds >= 15
                    && epoch.maximumGapSeconds <= 15
            }
            var motionMinuteKeys = Set<Int64>()
            for epoch in candidateMotionEpochs {
                motionMinuteKeys.insert(Int64(floor(epoch.start.timeIntervalSince1970 / 60)))
            }
            let motionRatio = roundedRatio(motionMinuteKeys.count, spanMinutes)
            let chunkIDs = Array(Set(group.map(\.chunkID))).sorted()
            let provenance = Array(Set(candidateMotionEpochs.map(\.provenance))).sorted()
            var samples = 0
            var sum: Int64 = 0
            for minute in group {
                let (nextSamples, sampleOverflow) = samples.addingReportingOverflow(minute.samples)
                let (nextSum, sumOverflow) = sum.addingReportingOverflow(minute.sumBPM)
                guard !sampleOverflow, !sumOverflow else {
                    throw AtriaHistoricalSessionProjectionError.numericOverflow
                }
                samples = nextSamples
                sum = nextSum
            }
            guard samples > 0 else { continue }
            let averageHR = (Double(sum) / Double(samples) * 1_000).rounded() / 1_000
            let maximumHR = group.map(\.maximumBPM).max() ?? 0
            let confidence: Confidence = motionRatio >= 0.50 ? .high : .medium
            let identity = CandidateIdentity(schema: currentSchema,
                                             algorithmVersion: algorithmVersion,
                                             configurationSHA256: configurationSHA256,
                                             start: start,
                                             end: end,
                                             averageHeartRate: averageHR,
                                             maximumHeartRate: maximumHR,
                                             contributingChunkIDs: chunkIDs)
            let identifier = "workout-" + (try AtriaHistoricalSessionProjectionSupport.sha256(identity))
            result.append(.init(identifier: identifier,
                                start: start,
                                end: end,
                                localDay: AtriaHistoricalSessionProjectionSupport.localDay(
                                    start, timeZoneIdentifier: configuration.timeZoneIdentifier
                                ),
                                confidence: confidence,
                                averageHeartRate: averageHR,
                                maximumHeartRate: maximumHR,
                                coverage: .init(spanMinutes: spanMinutes,
                                                elevatedHeartRateMinutes: denseMinutes,
                                                denseHeartRateMinutes: denseMinutes,
                                                heartRateCoverageRatio: hrRatio,
                                                validatedMotionMinutes: motionMinuteKeys.count,
                                                motionCoverageRatio: motionRatio,
                                                contributingChunkIDs: chunkIDs,
                                                motionProvenance: provenance)))
        }
        return result.sorted(by: candidateSort)
    }

    private static func roundedRatio(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return (Double(numerator) / Double(denominator) * 1_000_000).rounded() / 1_000_000
    }

    private static func candidateSort(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.identifier < rhs.identifier
    }

    private static func validCandidate(_ value: Candidate, configuration: Configuration) -> Bool {
        value.identifier.hasPrefix("workout-")
            && value.identifier.count == 72
            && value.end > value.start
            && value.coverage.spanMinutes >= configuration.minimumDurationMinutes
            && value.coverage.heartRateCoverageRatio >= configuration.minimumHeartRateCoverage
            && value.coverage.heartRateCoverageRatio <= 1
            && value.coverage.motionCoverageRatio >= 0
            && value.coverage.motionCoverageRatio <= 1
            && !value.coverage.contributingChunkIDs.isEmpty
            && value.averageHeartRate.isFinite
            && value.maximumHeartRate > 0
            && (value.confidence != .high || value.coverage.motionCoverageRatio >= 0.50)
    }
}
