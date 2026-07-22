import CryptoKit
import Foundation

/// Immutable activity-candidate output derived only from committed historical
/// aggregate facts. This is intentionally independent of the live activity UI:
/// it is the durable, semantically verifiable consumer result required before
/// a sealed raw source can ever be considered for retirement.
struct AtriaHistoricalActivityProjection: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let algorithmVersion = "historical-activity-candidates-v1"
    static let requiredHistory: TimeInterval = 30 * 60
    static let requiredLookahead: TimeInterval = 30 * 60

    struct Configuration: Codable, Equatable, Sendable {
        let restingHeartRate: Int
        let maximumHeartRate: Int
        let timeZoneIdentifier: String
    }

    struct Source: Codable, Equatable, Sendable {
        let chunkID: String
        let rawSHA256: String
        let firstTimestamp: Date
        let lastTimestamp: Date
        /// Digest of the exact HR and motion facts consumed from the source.
        let aggregateFactsSHA256: String
    }

    struct Dependency: Codable, Equatable, Sendable {
        let chunkID: String
        let rawSHA256: String
        let firstTimestamp: Date
        let lastTimestamp: Date
        let aggregateFactsSHA256: String
    }

    struct ClosedCoverageInterval: Codable, Equatable, Sendable {
        let start: Date
        let end: Date
        /// Zero explicitly means the durable scan found no catalog rows.
        let recordCount: Int
    }

    /// Bytes from the immutable catalog generation plus its canonical scan
    /// manifest. Keeping the bytes as verification input prevents a caller
    /// from turning a bare timestamp into alleged no-data coverage.
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
            closedCoverageIntervals: [ClosedCoverageInterval]
        ) throws -> Self {
            guard !generationIdentifier.isEmpty, !catalogSnapshot.isEmpty else {
                throw ProjectionError.invalidInspectionProof
            }
            let manifest = ScanGenerationManifest(
                schema: ScanGenerationManifest.currentSchema,
                generationIdentifier: generationIdentifier,
                catalogContentSHA256: AtriaHistoricalActivityProjection.sha256(catalogSnapshot),
                closedCoverageIntervals: closedCoverageIntervals.sorted {
                    if $0.start != $1.start { return $0.start < $1.start }
                    return $0.end < $1.end
                }
            )
            return .init(catalogSnapshot: catalogSnapshot,
                         scanGenerationManifest: try manifest.canonicalData())
        }
    }

    struct InspectionEvidence: Codable, Equatable, Sendable {
        let generationIdentifier: String
        let catalogContentSHA256: String
        let scanGenerationManifestSHA256: String
        let closedCoverageIntervals: [ClosedCoverageInterval]
    }

    enum CandidateKind: String, Codable, Equatable, Sendable {
        case movement
        case cardio
        case vigorous
    }

    enum Confidence: String, Codable, Equatable, Sendable {
        case low
        case medium
        case high
    }

    struct Candidate: Codable, Equatable, Sendable {
        let identifier: String
        let start: Date
        let end: Date
        let localDay: String
        let kind: CandidateKind
        let confidence: Confidence
        let activeMinutes: Int
        let heartRateMinutes: Int
        let motionMinutes: Int
        let averageHeartRate: Double?
        let maximumHeartRate: Int?
        let averageMovementIntensity: Double?
    }

    enum CompletionState: String, Codable, Equatable, Sendable {
        /// The dependency interval was fully inspected. An empty candidate
        /// array is therefore a real, durable result rather than omission.
        case complete
    }

    enum ProjectionError: Error, Equatable {
        case invalidConfiguration
        case invalidAggregate(String)
        case duplicateDependency(String)
        case sourceMissing
        case sourceMismatch
        case invalidInspectionProof
        case incompleteInspectionCoverage
        case insufficientLookahead
        case invalidArtifact
    }

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
    let completionState: CompletionState
    let candidates: [Candidate]

    var outcome: AtriaHistoricalConsumerReceiptLedger.Outcome {
        candidates.isEmpty ? .explicitlyEmpty : .materialized
    }

    static func configurationSHA256(for configuration: Configuration) throws -> String {
        try validate(configuration)
        return sha256(try canonicalConfigurationData(configuration))
    }

    /// Builds a complete projection for `source`. The inspection proof must
    /// cryptographically bind a durable catalog generation to explicit closed
    /// intervals, including intervals in which the scan found no records.
    /// `completionWatermark` additionally proves ingestion is closed far
    /// enough beyond the source to settle candidates crossing its boundary.
    static func build(
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date
    ) throws -> Self {
        try validate(configuration)
        let requiredStart = source.source.firstTimestamp.addingTimeInterval(-requiredHistory)
        let requiredEnd = source.source.lastTimestamp.addingTimeInterval(requiredLookahead)
        let inspectionEvidence = try validatedInspectionEvidence(
            inspectionProof,
            covering: requiredStart...requiredEnd
        )
        guard completionWatermark >= requiredEnd else { throw ProjectionError.insufficientLookahead }

        let chunks = try validatedAndSorted(dependencyChunks)
        guard let matchingSource = chunks.first(where: { $0.source.chunkID == source.source.chunkID }) else {
            throw ProjectionError.sourceMissing
        }
        guard matchingSource == source else { throw ProjectionError.sourceMismatch }

        let factsDigest = try aggregateFactsSHA256(source)
        let projectionSource = Source(chunkID: source.source.chunkID,
                                      rawSHA256: source.source.rawSHA256,
                                      firstTimestamp: source.source.firstTimestamp,
                                      lastTimestamp: source.source.lastTimestamp,
                                      aggregateFactsSHA256: factsDigest)
        let relevantChunks = chunks.filter {
            $0.source.lastTimestamp >= requiredStart && $0.source.firstTimestamp <= requiredEnd
        }
        guard relevantChunks.contains(where: { $0.source.chunkID == source.source.chunkID }) else {
            throw ProjectionError.sourceMissing
        }
        let dependencies = try relevantChunks.map {
            Dependency(chunkID: $0.source.chunkID,
                       rawSHA256: $0.source.rawSHA256,
                       firstTimestamp: $0.source.firstTimestamp,
                       lastTimestamp: $0.source.lastTimestamp,
                       aggregateFactsSHA256: try aggregateFactsSHA256($0))
        }
        let configDigest = try configurationSHA256(for: configuration)
        let candidates = try detectCandidates(in: relevantChunks,
                                              ownedBy: source.source.chunkID,
                                              configuration: configuration,
                                              configurationSHA256: configDigest,
                                              inspectedStart: requiredStart,
                                              dependencyEnd: requiredEnd)
        return .init(schema: currentSchema,
                     algorithmVersion: algorithmVersion,
                     configuration: configuration,
                     configurationSHA256: configDigest,
                     source: projectionSource,
                     dependencies: dependencies,
                     inspectionEvidence: inspectionEvidence,
                     dependencyStart: requiredStart,
                     dependencyEnd: requiredEnd,
                     completionWatermark: completionWatermark,
                     completionState: .complete,
                     candidates: candidates)
    }

    func encodedArtifact() throws -> Data {
        guard try validatesInternalShape() else { throw ProjectionError.invalidArtifact }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decodeAndVerify(
        _ artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date
    ) throws -> Self {
        let decoded: Self
        do {
            decoded = try JSONDecoder().decode(Self.self, from: artifact)
        } catch {
            throw ProjectionError.invalidArtifact
        }
        let rebuilt = try build(source: source,
                                dependencyChunks: dependencyChunks,
                                configuration: configuration,
                                inspectionProof: inspectionProof,
                                completionWatermark: completionWatermark)
        guard decoded == rebuilt,
              try decoded.encodedArtifact() == artifact else {
            throw ProjectionError.invalidArtifact
        }
        return decoded
    }

    static func publishReceipt(
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date,
        ledger: AtriaHistoricalConsumerReceiptLedger,
        settledAt: Date
    ) throws -> AtriaHistoricalConsumerReceiptLedger.Published {
        let projection = try build(source: source,
                                   dependencyChunks: dependencyChunks,
                                   configuration: configuration,
                                   inspectionProof: inspectionProof,
                                   completionWatermark: completionWatermark)
        let artifact = try projection.encodedArtifact()
        let ledgerSource = AtriaHistoricalConsumerReceiptLedger.Source(
            chunkID: source.source.chunkID,
            rawSHA256: source.source.rawSHA256,
            firstTimestamp: source.source.firstTimestamp,
            lastTimestamp: source.source.lastTimestamp
        )
        return try ledger.publish(.init(source: ledgerSource,
                                        kind: .activity,
                                        consumerSchemaVersion: currentSchema,
                                        algorithmVersion: algorithmVersion,
                                        configurationSHA256: projection.configurationSHA256,
                                        dependencyStart: projection.dependencyStart,
                                        dependencyEnd: projection.dependencyEnd,
                                        completionWatermark: projection.completionWatermark,
                                        outcome: projection.outcome,
                                        recordCount: projection.candidates.count,
                                        artifact: artifact,
                                        settledAt: settledAt))
    }

    static func verifyReceipt(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        artifact: Data,
        source: AtriaHistoricalAggregateChunk,
        dependencyChunks: [AtriaHistoricalAggregateChunk],
        configuration: Configuration,
        inspectionProof: InspectionProof,
        completionWatermark: Date
    ) throws -> Bool {
        let expectedConfigDigest = try configurationSHA256(for: configuration)
        let requiredStart = source.source.firstTimestamp.addingTimeInterval(-requiredHistory)
        let expectedInspection = try validatedInspectionEvidence(
            inspectionProof,
            covering: requiredStart...source.source.lastTimestamp.addingTimeInterval(requiredLookahead)
        )
        guard receipt.kind == .activity,
              receipt.consumerSchemaVersion == currentSchema,
              receipt.algorithmVersion == algorithmVersion,
              receipt.configurationSHA256 == expectedConfigDigest,
              receipt.source.chunkID == source.source.chunkID,
              receipt.source.rawSHA256 == source.source.rawSHA256,
              receipt.source.firstTimestamp == source.source.firstTimestamp,
              receipt.source.lastTimestamp == source.source.lastTimestamp,
              receipt.dependencyStart == requiredStart,
              receipt.dependencyEnd == source.source.lastTimestamp.addingTimeInterval(requiredLookahead),
              receipt.completionWatermark == completionWatermark else {
            return false
        }
        let projection = try decodeAndVerify(artifact,
                                             source: source,
                                             dependencyChunks: dependencyChunks,
                                             configuration: configuration,
                                             inspectionProof: inspectionProof,
                                             completionWatermark: completionWatermark)
        return projection.inspectionEvidence == expectedInspection
            && receipt.outcome == projection.outcome
            && receipt.recordCount == projection.candidates.count
    }

    private struct CanonicalConfiguration: Codable {
        let schema: Int
        let algorithmVersion: String
        let restingHeartRate: Int
        let maximumHeartRate: Int
        let timeZoneIdentifier: String
        let requiredHistorySeconds: Int
        let requiredLookaheadSeconds: Int
        let minimumActiveMinutes: Int
        let permittedInactiveMinutes: Int
        let heartRateReserveThreshold: Double
        let movementIntensityThreshold: Double
        let stillnessThreshold: Double
        let p95VectorDeltaThreshold: Double
    }

    private struct ScanGenerationManifest: Codable, Equatable {
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

    private struct AggregateFacts: Codable {
        let source: AtriaHistoricalAggregateChunk.Source
        let heartRateMinutes: [AtriaHistoricalAggregateChunk.HeartRateMinute]
        let motionEpochs: [AtriaHistoricalAggregateChunk.MotionEpoch]
    }

    private struct MinuteAccumulator {
        let minuteStart: Date
        var heartRateSamples = 0
        var heartRateSum = Int64(0)
        var maximumHeartRate: Int?
        var validatedMotionWeight = 0
        var movementWeightedSum = 0.0
        var stillnessWeightedSum = 0.0
        var stillnessWeight = 0
        var p95VectorDelta = 0.0
        var activityBursts = 0
        var contributorChunkIDs: Set<String> = []
    }

    private struct ActiveMinute {
        let start: Date
        let contributorChunkIDs: Set<String>
        let heartRate: Double?
        let maximumHeartRate: Int?
        let movementIntensity: Double?
        let hasHeartRate: Bool
        let hasMotion: Bool
    }

    private static func validate(_ configuration: Configuration) throws {
        guard (25...150).contains(configuration.restingHeartRate),
              (60...240).contains(configuration.maximumHeartRate),
              configuration.maximumHeartRate >= configuration.restingHeartRate + 20,
              TimeZone(identifier: configuration.timeZoneIdentifier) != nil else {
            throw ProjectionError.invalidConfiguration
        }
    }

    private static func canonicalConfigurationData(_ configuration: Configuration) throws -> Data {
        let canonical = CanonicalConfiguration(
            schema: currentSchema,
            algorithmVersion: algorithmVersion,
            restingHeartRate: configuration.restingHeartRate,
            maximumHeartRate: configuration.maximumHeartRate,
            timeZoneIdentifier: configuration.timeZoneIdentifier,
            requiredHistorySeconds: Int(requiredHistory),
            requiredLookaheadSeconds: Int(requiredLookahead),
            minimumActiveMinutes: 3,
            permittedInactiveMinutes: 2,
            heartRateReserveThreshold: 0.18,
            movementIntensityThreshold: 0.12,
            stillnessThreshold: 0.72,
            p95VectorDeltaThreshold: 0.08
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(canonical)
    }

    private static func validatedInspectionEvidence(
        _ proof: InspectionProof,
        covering requiredRange: ClosedRange<Date>
    ) throws -> InspectionEvidence {
        guard !proof.catalogSnapshot.isEmpty,
              !proof.scanGenerationManifest.isEmpty else {
            throw ProjectionError.invalidInspectionProof
        }
        let manifest: ScanGenerationManifest
        do {
            manifest = try JSONDecoder().decode(ScanGenerationManifest.self,
                                                from: proof.scanGenerationManifest)
        } catch {
            throw ProjectionError.invalidInspectionProof
        }
        let intervals = manifest.closedCoverageIntervals
        guard manifest.schema == ScanGenerationManifest.currentSchema,
              !manifest.generationIdentifier.isEmpty,
              isSHA256(manifest.catalogContentSHA256),
              manifest.catalogContentSHA256 == sha256(proof.catalogSnapshot),
              try manifest.canonicalData() == proof.scanGenerationManifest,
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
            throw ProjectionError.invalidInspectionProof
        }

        var coveredThrough: Date?
        for interval in intervals {
            guard interval.end >= requiredRange.lowerBound else { continue }
            if coveredThrough == nil {
                guard interval.start <= requiredRange.lowerBound else {
                    throw ProjectionError.incompleteInspectionCoverage
                }
                coveredThrough = interval.end
            } else if interval.start <= coveredThrough! {
                coveredThrough = max(coveredThrough!, interval.end)
            } else {
                throw ProjectionError.incompleteInspectionCoverage
            }
            if coveredThrough! >= requiredRange.upperBound { break }
        }
        guard let coveredThrough, coveredThrough >= requiredRange.upperBound else {
            throw ProjectionError.incompleteInspectionCoverage
        }
        return .init(generationIdentifier: manifest.generationIdentifier,
                     catalogContentSHA256: manifest.catalogContentSHA256,
                     scanGenerationManifestSHA256: sha256(proof.scanGenerationManifest),
                     closedCoverageIntervals: intervals)
    }

    private static func validatedAndSorted(
        _ chunks: [AtriaHistoricalAggregateChunk]
    ) throws -> [AtriaHistoricalAggregateChunk] {
        var byID: [String: AtriaHistoricalAggregateChunk] = [:]
        for chunk in chunks {
            do {
                try chunk.validateForCommit()
            } catch {
                throw ProjectionError.invalidAggregate(chunk.source.chunkID)
            }
            guard isSHA256(chunk.source.rawSHA256) else {
                throw ProjectionError.invalidAggregate(chunk.source.chunkID)
            }
            if let existing = byID[chunk.source.chunkID] {
                guard existing == chunk else {
                    throw ProjectionError.duplicateDependency(chunk.source.chunkID)
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

    private static func aggregateFactsSHA256(
        _ chunk: AtriaHistoricalAggregateChunk
    ) throws -> String {
        let facts = AggregateFacts(source: chunk.source,
                                   heartRateMinutes: chunk.heartRateMinutes.sorted {
                                       $0.minuteStart < $1.minuteStart
                                   },
                                   motionEpochs: chunk.motionEpochs.sorted {
                                       if $0.start != $1.start { return $0.start < $1.start }
                                       return $0.end < $1.end
                                   })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(facts))
    }

    private static func detectCandidates(
        in chunks: [AtriaHistoricalAggregateChunk],
        ownedBy sourceChunkID: String,
        configuration: Configuration,
        configurationSHA256: String,
        inspectedStart: Date,
        dependencyEnd: Date
    ) throws -> [Candidate] {
        var minutes: [Int64: MinuteAccumulator] = [:]
        let descriptors = Dictionary(uniqueKeysWithValues: chunks.map { ($0.source.chunkID, $0.source) })

        for chunk in chunks {
            for fact in chunk.heartRateMinutes.sorted(by: { $0.minuteStart < $1.minuteStart }) {
                let key = minuteKey(fact.minuteStart)
                let start = Date(timeIntervalSince1970: TimeInterval(key * 60))
                guard start >= inspectedStart.addingTimeInterval(-60), start <= dependencyEnd else { continue }
                var minute = minutes[key] ?? MinuteAccumulator(minuteStart: start)
                minute.heartRateSamples += fact.sampleCount
                minute.heartRateSum += fact.sumBPM
                if fact.sampleCount > 0 {
                    minute.maximumHeartRate = max(minute.maximumHeartRate ?? fact.maximumBPM,
                                                  fact.maximumBPM)
                }
                minute.contributorChunkIDs.insert(chunk.source.chunkID)
                minutes[key] = minute
            }
            for fact in chunk.motionEpochs.sorted(by: { $0.start < $1.start }) {
                let key = minuteKey(fact.start)
                let start = Date(timeIntervalSince1970: TimeInterval(key * 60))
                guard start >= inspectedStart.addingTimeInterval(-60), start <= dependencyEnd else { continue }
                var minute = minutes[key] ?? MinuteAccumulator(minuteStart: start)
                if fact.measurementValidated {
                    let weight = max(1, fact.validatedRows)
                    minute.validatedMotionWeight += weight
                    if let movement = fact.movementIntensity {
                        minute.movementWeightedSum += movement * Double(weight)
                    }
                    if let stillness = fact.stillnessRatio {
                        minute.stillnessWeightedSum += stillness * Double(weight)
                        minute.stillnessWeight += weight
                    }
                    minute.p95VectorDelta = max(minute.p95VectorDelta,
                                                fact.p95VectorDelta ?? 0)
                    minute.activityBursts += fact.activityBursts ?? 0
                }
                minute.contributorChunkIDs.insert(chunk.source.chunkID)
                minutes[key] = minute
            }
        }

        let reserve = Double(configuration.maximumHeartRate - configuration.restingHeartRate)
        let elevatedThreshold = Double(configuration.restingHeartRate)
            + max(15, ceil(reserve * 0.18))
        let activeMinutes: [ActiveMinute] = minutes.values
            .sorted(by: { $0.minuteStart < $1.minuteStart })
            .compactMap { minute in
                let heartRate = minute.heartRateSamples > 0
                    ? Double(minute.heartRateSum) / Double(minute.heartRateSamples)
                    : nil
                let movement = minute.validatedMotionWeight > 0
                    ? minute.movementWeightedSum / Double(minute.validatedMotionWeight)
                    : nil
                let stillness = minute.stillnessWeight > 0
                    ? minute.stillnessWeightedSum / Double(minute.stillnessWeight)
                    : nil
                let heartRateActive = heartRate.map { $0 >= elevatedThreshold } ?? false
                let motionActive = minute.validatedMotionWeight > 0
                    && ((movement ?? 0) >= 0.12
                        || (stillness.map { $0 <= 0.72 } ?? false)
                        || minute.p95VectorDelta >= 0.08
                        || minute.activityBursts > 0)
                guard heartRateActive || motionActive else { return nil }
                return ActiveMinute(start: minute.minuteStart,
                                    contributorChunkIDs: minute.contributorChunkIDs,
                                    heartRate: heartRate,
                                    maximumHeartRate: minute.maximumHeartRate,
                                    movementIntensity: movement,
                                    hasHeartRate: minute.heartRateSamples > 0,
                                    hasMotion: minute.validatedMotionWeight > 0)
            }

        var groups: [[ActiveMinute]] = []
        for minute in activeMinutes {
            if let last = groups.last?.last,
               minute.start.timeIntervalSince(last.start) <= 3 * 60 {
                groups[groups.count - 1].append(minute)
            } else {
                groups.append([minute])
            }
        }

        var result: [Candidate] = []
        for group in groups where group.count >= 3 {
            guard let first = group.first, let last = group.last else { continue }
            let owner = first.contributorChunkIDs.compactMap { descriptors[$0] }.sorted {
                if $0.firstTimestamp != $1.firstTimestamp {
                    return $0.firstTimestamp > $1.firstTimestamp
                }
                return $0.chunkID < $1.chunkID
            }.first?.chunkID
            guard owner == sourceChunkID else { continue }

            let hrValues = group.compactMap(\.heartRate)
            let maxValues = group.compactMap(\.maximumHeartRate)
            let movementValues = group.compactMap(\.movementIntensity)
            let averageHR = roundedMean(hrValues)
            let maximumHR = maxValues.max()
            let averageMovement = roundedMean(movementValues)
            let vigorousThreshold = Double(configuration.restingHeartRate) + reserve * 0.45
            let kind: CandidateKind
            if (maximumHR.map { Double($0) >= vigorousThreshold } ?? false) {
                kind = .vigorous
            } else if (averageHR.map { $0 >= elevatedThreshold } ?? false) {
                kind = .cardio
            } else {
                kind = .movement
            }
            let hrCount = group.filter(\.hasHeartRate).count
            let motionCount = group.filter(\.hasMotion).count
            let confidence: Confidence
            if group.count >= 10 && hrCount >= 3 && motionCount >= 3 {
                confidence = .high
            } else if group.count >= 5 && (hrCount >= 3 || motionCount >= 3) {
                confidence = .medium
            } else {
                confidence = .low
            }
            let end = last.start.addingTimeInterval(60)
            let identity = CandidateIdentity(sourceChunkID: sourceChunkID,
                                             configurationSHA256: configurationSHA256,
                                             start: first.start,
                                             end: end,
                                             kind: kind,
                                             activeMinutes: group.count,
                                             averageHeartRate: averageHR,
                                             maximumHeartRate: maximumHR,
                                             averageMovementIntensity: averageMovement)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let identifier = "activity-" + sha256(try encoder.encode(identity))
            result.append(.init(identifier: identifier,
                                start: first.start,
                                end: end,
                                localDay: localDay(for: first.start,
                                                   timeZoneIdentifier: configuration.timeZoneIdentifier),
                                kind: kind,
                                confidence: confidence,
                                activeMinutes: group.count,
                                heartRateMinutes: hrCount,
                                motionMinutes: motionCount,
                                averageHeartRate: averageHR,
                                maximumHeartRate: maximumHR,
                                averageMovementIntensity: averageMovement))
        }
        return result.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.identifier < $1.identifier
        }
    }

    private struct CandidateIdentity: Codable {
        let sourceChunkID: String
        let configurationSHA256: String
        let start: Date
        let end: Date
        let kind: CandidateKind
        let activeMinutes: Int
        let averageHeartRate: Double?
        let maximumHeartRate: Int?
        let averageMovementIntensity: Double?
    }

    private func validatesInternalShape() throws -> Bool {
        guard schema == Self.currentSchema,
              algorithmVersion == Self.algorithmVersion,
              configurationSHA256 == (try Self.configurationSHA256(for: configuration)),
              Self.isSHA256(source.rawSHA256),
              Self.isSHA256(source.aggregateFactsSHA256),
              source.lastTimestamp > source.firstTimestamp,
              dependencyStart == source.firstTimestamp.addingTimeInterval(-Self.requiredHistory),
              dependencyEnd == source.lastTimestamp.addingTimeInterval(Self.requiredLookahead),
              completionWatermark >= dependencyEnd,
              completionState == .complete,
              !inspectionEvidence.generationIdentifier.isEmpty,
              Self.isSHA256(inspectionEvidence.catalogContentSHA256),
              Self.isSHA256(inspectionEvidence.scanGenerationManifestSHA256),
              inspectionEvidence.closedCoverageIntervals
                == inspectionEvidence.closedCoverageIntervals.sorted(by: {
                    if $0.start != $1.start { return $0.start < $1.start }
                    return $0.end < $1.end
                }),
              inspectionEvidence.closedCoverageIntervals.allSatisfy({
                  $0.start.timeIntervalSince1970.isFinite
                      && $0.end.timeIntervalSince1970.isFinite
                      && $0.end >= $0.start
                      && $0.recordCount >= 0
              }),
              Self.coverageCovers(inspectionEvidence.closedCoverageIntervals,
                                  from: dependencyStart,
                                  through: dependencyEnd),
              dependencies.contains(where: {
                  $0.chunkID == source.chunkID
                      && $0.rawSHA256 == source.rawSHA256
                      && $0.aggregateFactsSHA256 == source.aggregateFactsSHA256
              }),
              Set(dependencies.map(\.chunkID)).count == dependencies.count,
              dependencies == dependencies.sorted(by: {
                  if $0.firstTimestamp != $1.firstTimestamp {
                      return $0.firstTimestamp < $1.firstTimestamp
                  }
                  return $0.chunkID < $1.chunkID
              }),
              dependencies.allSatisfy({
                  Self.isSHA256($0.rawSHA256)
                      && Self.isSHA256($0.aggregateFactsSHA256)
                      && $0.lastTimestamp > $0.firstTimestamp
              }),
              candidates == candidates.sorted(by: {
                  if $0.start != $1.start { return $0.start < $1.start }
                  return $0.identifier < $1.identifier
              }),
              Set(candidates.map(\.identifier)).count == candidates.count,
              candidates.allSatisfy({
                  $0.identifier.hasPrefix("activity-")
                      && Self.isSHA256(String($0.identifier.dropFirst("activity-".count)))
                      && $0.end > $0.start
                      && $0.activeMinutes >= 3
                      && $0.heartRateMinutes >= 0
                      && $0.motionMinutes >= 0
                      && !$0.localDay.isEmpty
              }) else {
            return false
        }
        return true
    }

    private static func coverageCovers(
        _ intervals: [ClosedCoverageInterval],
        from requiredStart: Date,
        through requiredEnd: Date
    ) -> Bool {
        var coveredThrough: Date?
        for interval in intervals.sorted(by: {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }) where interval.end >= requiredStart {
            if coveredThrough == nil {
                guard interval.start <= requiredStart else { return false }
                coveredThrough = interval.end
            } else if interval.start <= coveredThrough! {
                coveredThrough = max(coveredThrough!, interval.end)
            } else {
                return false
            }
            if coveredThrough! >= requiredEnd { return true }
        }
        return false
    }

    private static func minuteKey(_ date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / 60))
    }

    private static func roundedMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return (mean * 1_000).rounded() / 1_000
    }

    private static func localDay(for date: Date, timeZoneIdentifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0,
                      components.month ?? 0,
                      components.day ?? 0)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count == 64
            && value.unicodeScalars.allSatisfy(lowercaseHex.contains)
    }
}
