import CryptoKit
import Darwin
import Foundation

/// Loss-bounded, decoded history for aggregates that no longer need minute or
/// 30-second detail. This type is deliberately not a raw-data reconstruction:
/// it preserves exact daily distributions/sufficient statistics and durable
/// consumer receipt references, while partial-day historical reanalysis must
/// fail closed.
struct AtriaHistoricalLongTermRollup: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let calendarVersion = "utc-gregorian-v1"

    struct Source: Codable, Equatable, Hashable, Sendable {
        let chunkID: String
        let rawSHA256: String
        let aggregateSHA256: String
        let aggregateSchema: Int
        let firstTimestamp: Date
        let lastTimestamp: Date
        let rawRows: Int
        let decodedRows: Int
        let metricUsableRows: Int
        let heartRateSamples: Int
        let heartRateSumBPM: Int64
        let acceptedRRBeats: Int
        let acceptedRRSumMilliseconds: Int64
        let validatedGravityRows: Int
        let motionEpochs: Int
        let projectionReceipts: Int
    }

    struct ValueCount: Codable, Equatable, Sendable {
        let value: Double
        let count: Int
    }

    struct StageFacts: Codable, Equatable, Sendable {
        let stage: String
        let epochCount: Int
        let coverageSeconds: Int
        let confidenceDistribution: [ValueCount]
        let confidenceMissingEpochs: Int
    }

    struct HeartRateFacts: Codable, Equatable, Sendable {
        let sampleCount: Int
        let sumBPM: Int64
        let minimumBPM: Int
        let maximumBPM: Int
        let samplesByBPM: [Int: Int]
        let terminalBPMSeconds: [Int: Double]
        let transitionHalfBPMSeconds: [Int: Double]
        let coveredSeconds: Double
        let droppedGapSeconds: Double
    }

    /// Statistics for epochs wholly contained by the UTC day. The first/last
    /// values and epoch bounds preserve exact RR-difference bridging when two
    /// adjacent daily summaries are combined. Epochs crossing midnight remain
    /// as exact boundary facts instead of being assigned to a fabricated day.
    struct RRFacts: Codable, Equatable, Sendable {
        let epochCount: Int
        let firstEpochStart: Date?
        let lastEpochEnd: Date?
        let sourceRecordCount: Int
        let acceptedBeatCount: Int
        let rejectedBeatCount: Int
        let sumNNMilliseconds: Int64
        let sumNNSquaredMilliseconds: Double
        let adjacentDifferenceCount: Int
        let sumAdjacentDifferenceSquaredMilliseconds: Double
        let adjacentDifferenceOver50Count: Int
        let firstNNMilliseconds: Int?
        let lastNNMilliseconds: Int?
        let coverageSeconds: Double
        let maximumGapSeconds: Double
        let projectionFingerprints: [String: Int]
        let provenances: [String: Int]
    }

    struct MotionFacts: Codable, Equatable, Sendable {
        let epochCount: Int
        let rows: Int
        let validatedRows: Int
        let rejectedRows: Int
        let coverageSeconds: Int
        let maximumGapSeconds: Int
        let measurementValidatedEpochs: Int
        let lowMotionQualifiedEpochs: Int
        /// Exact distributions of the already-decoded epoch values. Missing
        /// values remain absent and have separate counts; zero is never used as
        /// a substitute for an unsupported decoder result.
        let stillnessDistribution: [ValueCount]
        let stillnessMissingEpochs: Int
        let movementIntensityDistribution: [ValueCount]
        let movementIntensityMissingEpochs: Int
        let p95VectorDeltaDistribution: [ValueCount]
        let p95VectorDeltaMissingEpochs: Int
        let activityBurstsKnownEpochs: Int
        let activityBurstsSum: Int64
        let stepKnownEpochs: Int
        let stepDeltaSum: Int64
        let stages: [StageFacts]
        let algorithms: [String: Int]
        let provenances: [String: Int]
    }

    struct Day: Codable, Equatable, Sendable {
        let start: Date
        let end: Date
        let heartRate: HeartRateFacts
        let rr: RRFacts
        let boundaryRREpochs: [AtriaHistoricalAggregateChunk.RREpoch]
        let motion: MotionFacts
    }

    struct ProjectionReference: Codable, Equatable, Sendable {
        let sourceChunkID: String
        let kind: AtriaHistoricalAggregateChunk.MaterializedProjection.Kind
        let identifier: String
        let start: Date
        let end: Date
        let schemaVersion: Int
        let contentSHA256: String
        let settledAt: Date
    }

    struct Parity: Codable, Equatable, Sendable {
        let sourceAggregates: Int
        let rawRows: Int
        let decodedRows: Int
        let metricUsableRows: Int
        let heartRateSamples: Int
        let heartRateSumBPM: Int64
        let acceptedRRBeats: Int
        let acceptedRRSumMilliseconds: Int64
        let validatedGravityRows: Int
        let motionEpochs: Int
        let projectionReferences: Int
    }

    let schema: Int
    let calendarVersion: String
    let createdAt: Date
    let periodStart: Date
    let periodEnd: Date
    let sources: [Source]
    let days: [Day]
    let projectionReferences: [ProjectionReference]
    let parity: Parity

    enum ValidationError: Error, Equatable {
        case unsupportedSchema
        case invalidPeriod
        case invalidSource
        case duplicateSource
        case invalidDay
        case invalidHeartRate
        case invalidRR
        case invalidMotion
        case invalidProjectionReference
        case parityMismatch
        case nonFiniteValue
    }

    func validate() throws {
        guard schema == Self.currentSchema,
              calendarVersion == Self.calendarVersion else {
            throw ValidationError.unsupportedSchema
        }
        guard periodEnd > periodStart,
              Self.utcMonthInterval(containing: periodStart) == DateInterval(start: periodStart,
                                                                              end: periodEnd) else {
            throw ValidationError.invalidPeriod
        }
        let shaCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        guard !sources.isEmpty,
              sources == sources.sorted(by: Self.sourceOrder),
              sources.allSatisfy({ source in
                  !source.chunkID.isEmpty
                      && source.rawSHA256.count == 64
                      && source.rawSHA256.unicodeScalars.allSatisfy(shaCharacters.contains)
                      && source.aggregateSHA256.count == 64
                      && source.aggregateSHA256.unicodeScalars.allSatisfy(shaCharacters.contains)
                      && source.aggregateSchema > 0
                      && source.lastTimestamp > source.firstTimestamp
                      && source.firstTimestamp >= periodStart
                      && source.lastTimestamp <= periodEnd
                      && source.rawRows >= 0
                      && source.decodedRows >= 0
                      && source.metricUsableRows >= 0
                      && source.heartRateSamples >= 0
                      && source.acceptedRRBeats >= 0
                      && source.validatedGravityRows >= 0
                      && source.motionEpochs >= 0
                      && source.projectionReceipts >= 0
              }) else {
            throw ValidationError.invalidSource
        }
        guard Set(sources.map(\.aggregateSHA256)).count == sources.count,
              Set(sources.map(\.chunkID)).count == sources.count else {
            throw ValidationError.duplicateSource
        }
        guard days == days.sorted(by: { $0.start < $1.start }),
              Set(days.map(\.start)).count == days.count else {
            throw ValidationError.invalidDay
        }
        for day in days {
            guard day.end == day.start.addingTimeInterval(86_400),
                  day.start >= periodStart,
                  day.end <= periodEnd else {
                throw ValidationError.invalidDay
            }
            try Self.validate(day.heartRate)
            try Self.validate(day.rr, day: DateInterval(start: day.start, end: day.end))
            try Self.validate(day.motion)
            guard day.boundaryRREpochs.allSatisfy({ epoch in
                epoch.start < day.end && epoch.end > day.end
                    && Self.validBoundaryEpoch(epoch)
            }) else {
                throw ValidationError.invalidRR
            }
        }
        guard projectionReferences == projectionReferences.sorted(by: Self.projectionOrder),
              Set(projectionReferences.map(Self.projectionIdentity)).count
                == projectionReferences.count,
              projectionReferences.allSatisfy({ reference in
                  sources.contains(where: { $0.chunkID == reference.sourceChunkID })
                      && !reference.identifier.isEmpty
                      && reference.end > reference.start
                      && reference.schemaVersion > 0
                      && reference.contentSHA256.count == 64
                      && reference.contentSHA256.unicodeScalars.allSatisfy(shaCharacters.contains)
                      && reference.settledAt >= reference.end
              }) else {
            throw ValidationError.invalidProjectionReference
        }
        guard parity == Self.computedParity(sources: sources,
                                            projectionReferences: projectionReferences),
              days.reduce(0, { $0 + $1.heartRate.sampleCount }) == parity.heartRateSamples,
              days.reduce(Int64(0), { $0 + $1.heartRate.sumBPM }) == parity.heartRateSumBPM,
              days.reduce(0, { partial, day in
                  partial + day.rr.acceptedBeatCount
                      + day.boundaryRREpochs.reduce(0) { $0 + $1.acceptedBeatCount }
              }) == parity.acceptedRRBeats,
              days.reduce(Int64(0), { partial, day in
                  partial + day.rr.sumNNMilliseconds
                      + day.boundaryRREpochs.reduce(Int64(0)) { $0 + $1.sumNNMilliseconds }
              }) == parity.acceptedRRSumMilliseconds,
              days.reduce(0, { $0 + $1.motion.validatedRows }) == parity.validatedGravityRows,
              days.reduce(0, { $0 + $1.motion.epochCount }) == parity.motionEpochs,
              sources.reduce(0, { $0 + $1.projectionReceipts })
                == projectionReferences.count else {
            throw ValidationError.parityMismatch
        }
    }

    private static func validate(_ facts: HeartRateFacts) throws {
        guard facts.coveredSeconds.isFinite,
              facts.droppedGapSeconds.isFinite,
              facts.terminalBPMSeconds.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              facts.transitionHalfBPMSeconds.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ValidationError.nonFiniteValue
        }
        guard facts.sampleCount >= 0,
              facts.samplesByBPM.values.reduce(0, +) == facts.sampleCount,
              facts.samplesByBPM.reduce(Int64(0), { $0 + Int64($1.key * $1.value) }) == facts.sumBPM,
              (facts.sampleCount == 0
               ? facts.minimumBPM == 0 && facts.maximumBPM == 0
               : facts.samplesByBPM.keys.min() == facts.minimumBPM
                    && facts.samplesByBPM.keys.max() == facts.maximumBPM) else {
            throw ValidationError.invalidHeartRate
        }
    }

    private static func validate(_ facts: RRFacts, day: DateInterval) throws {
        guard facts.sumNNSquaredMilliseconds.isFinite,
              facts.sumAdjacentDifferenceSquaredMilliseconds.isFinite,
              facts.coverageSeconds.isFinite,
              facts.maximumGapSeconds.isFinite else {
            throw ValidationError.nonFiniteValue
        }
        guard facts.epochCount >= 0,
              facts.sourceRecordCount >= 0,
              facts.acceptedBeatCount >= 0,
              facts.rejectedBeatCount >= 0,
              facts.adjacentDifferenceCount >= 0,
              facts.adjacentDifferenceOver50Count >= 0,
              facts.adjacentDifferenceOver50Count <= facts.adjacentDifferenceCount,
              facts.coverageSeconds >= 0,
              facts.maximumGapSeconds >= 0 else {
            throw ValidationError.invalidRR
        }
        guard facts.projectionFingerprints.values.reduce(0, +) == facts.epochCount,
              facts.provenances.values.reduce(0, +) == facts.epochCount,
              !facts.projectionFingerprints.keys.contains(where: \.isEmpty),
              !facts.provenances.keys.contains(where: \.isEmpty) else {
            throw ValidationError.invalidRR
        }
        if facts.epochCount == 0 {
            guard facts.firstEpochStart == nil, facts.lastEpochEnd == nil,
                  facts.acceptedBeatCount == 0, facts.firstNNMilliseconds == nil,
                  facts.lastNNMilliseconds == nil else { throw ValidationError.invalidRR }
        } else {
            guard let first = facts.firstEpochStart,
                  let last = facts.lastEpochEnd,
                  first >= day.start, last <= day.end, last > first else {
                throw ValidationError.invalidRR
            }
        }
    }

    private static func validate(_ facts: MotionFacts) throws {
        let distributions = [facts.stillnessDistribution,
                             facts.movementIntensityDistribution,
                             facts.p95VectorDeltaDistribution]
        guard distributions.flatMap({ $0 }).allSatisfy({ $0.value.isFinite && $0.count > 0 }),
              facts.stages.flatMap(\.confidenceDistribution)
                .allSatisfy({ $0.value.isFinite && (0...1).contains($0.value) && $0.count > 0 }) else {
            throw ValidationError.nonFiniteValue
        }
        guard facts.epochCount >= 0,
              facts.rows >= 0,
              facts.validatedRows >= 0,
              facts.rejectedRows >= 0,
              facts.validatedRows + facts.rejectedRows == facts.rows,
              facts.measurementValidatedEpochs >= 0,
              facts.lowMotionQualifiedEpochs >= 0,
              facts.activityBurstsKnownEpochs >= 0,
              facts.activityBurstsKnownEpochs <= facts.epochCount,
              facts.stepKnownEpochs >= 0,
              facts.stepKnownEpochs <= facts.epochCount,
              facts.stillnessDistribution.reduce(0, { $0 + $1.count })
                + facts.stillnessMissingEpochs == facts.epochCount,
              facts.movementIntensityDistribution.reduce(0, { $0 + $1.count })
                + facts.movementIntensityMissingEpochs == facts.epochCount,
              facts.p95VectorDeltaDistribution.reduce(0, { $0 + $1.count })
                + facts.p95VectorDeltaMissingEpochs == facts.epochCount,
              facts.algorithms.values.reduce(0, +) == facts.epochCount,
              facts.provenances.values.reduce(0, +) == facts.epochCount else {
            throw ValidationError.invalidMotion
        }
        guard facts.stages.allSatisfy({ stage in
            !stage.stage.isEmpty
                && stage.epochCount > 0
                && stage.confidenceDistribution.reduce(0, { $0 + $1.count })
                    + stage.confidenceMissingEpochs == stage.epochCount
        }) else { throw ValidationError.invalidMotion }
    }

    private static func validBoundaryEpoch(_ epoch: AtriaHistoricalAggregateChunk.RREpoch) -> Bool {
        epoch.end > epoch.start
            && epoch.acceptedBeatCount >= 0
            && epoch.rejectedBeatCount >= 0
            && epoch.sumNNSquaredMilliseconds.isFinite
            && epoch.sumAdjacentDifferenceSquaredMilliseconds.isFinite
            && epoch.coverageSeconds.isFinite
            && epoch.maximumGapSeconds.isFinite
    }

    fileprivate static func computedParity(
        sources: [Source],
        projectionReferences: [ProjectionReference]
    ) -> Parity {
        computedParity(sources: sources,
                       projectionReferenceCount: projectionReferences.count)
    }

    fileprivate static func computedParity(
        sources: [Source],
        projectionReferenceCount: Int
    ) -> Parity {
        .init(sourceAggregates: sources.count,
              rawRows: sources.reduce(0) { $0 + $1.rawRows },
              decodedRows: sources.reduce(0) { $0 + $1.decodedRows },
              metricUsableRows: sources.reduce(0) { $0 + $1.metricUsableRows },
              heartRateSamples: sources.reduce(0) { $0 + $1.heartRateSamples },
              heartRateSumBPM: sources.reduce(Int64(0)) { $0 + $1.heartRateSumBPM },
              acceptedRRBeats: sources.reduce(0) { $0 + $1.acceptedRRBeats },
              acceptedRRSumMilliseconds: sources.reduce(Int64(0)) { $0 + $1.acceptedRRSumMilliseconds },
              validatedGravityRows: sources.reduce(0) { $0 + $1.validatedGravityRows },
              motionEpochs: sources.reduce(0) { $0 + $1.motionEpochs },
              projectionReferences: projectionReferenceCount)
    }

    fileprivate static func sourceOrder(_ lhs: Source, _ rhs: Source) -> Bool {
        lhs.firstTimestamp == rhs.firstTimestamp
            ? lhs.chunkID < rhs.chunkID
            : lhs.firstTimestamp < rhs.firstTimestamp
    }

    fileprivate static func projectionOrder(_ lhs: ProjectionReference,
                                             _ rhs: ProjectionReference) -> Bool {
        if lhs.sourceChunkID != rhs.sourceChunkID { return lhs.sourceChunkID < rhs.sourceChunkID }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.identifier < rhs.identifier
    }

    private static func projectionIdentity(_ value: ProjectionReference) -> String {
        "\(value.sourceChunkID)|\(value.kind.rawValue)|\(value.identifier)|\(value.contentSHA256)"
    }

    fileprivate static func utcMonthInterval(containing date: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: components)!
        return calendar.dateInterval(of: .month, for: start)!
    }
}

/// Pure builder and sizing plan. It has no deletion API; a caller can only ask
/// which source aggregates have independently verified long-term replacements.
struct AtriaHistoricalLongTermPlanner {
    struct Input: Sendable {
        let aggregate: AtriaHistoricalAggregateChunk
        let aggregateData: Data

        init(aggregate: AtriaHistoricalAggregateChunk, aggregateData: Data) {
            self.aggregate = aggregate
            self.aggregateData = aggregateData
        }
    }

    struct Plan: Sendable {
        let groups: [[Input]]
        let retainedFullDetail: [Input]
        let blockedSourceChunkIDs: [String]
        let retainedFullDetailBytes: UInt64
    }

    enum PlannerError: Error, Equatable {
        case invalidHorizon
        case invalidAggregate(String)
        case aggregateBytesMismatch(String)
        case duplicateAggregate(String)
        case mixedPeriod
    }

    let fullDetailHorizon: TimeInterval

    init(fullDetailHorizon: TimeInterval = 90 * 86_400) {
        self.fullDetailHorizon = fullDetailHorizon
    }

    func plan(inputs: [Input], now: Date) throws -> Plan {
        guard fullDetailHorizon >= 0, fullDetailHorizon.isFinite else {
            throw PlannerError.invalidHorizon
        }
        var seen = Set<String>()
        var groups: [Date: [Input]] = [:]
        var retained: [Input] = []
        var blocked: [String] = []
        let cutoff = now.addingTimeInterval(-fullDetailHorizon)
        for input in inputs {
            try Self.validate(input)
            let digest = Self.sha256(input.aggregateData)
            guard seen.insert(digest).inserted else {
                throw PlannerError.duplicateAggregate(digest)
            }
            let firstPeriod = AtriaHistoricalLongTermRollup.utcMonthInterval(
                containing: input.aggregate.source.firstTimestamp
            )
            let lastInstant = input.aggregate.source.lastTimestamp.addingTimeInterval(-0.000_001)
            let lastPeriod = AtriaHistoricalLongTermRollup.utcMonthInterval(containing: lastInstant)
            guard firstPeriod == lastPeriod else {
                // Splitting an aggregate would make source parity ambiguous.
                blocked.append(input.aggregate.source.chunkID)
                retained.append(input)
                continue
            }
            // Never publish a partial calendar month. A late-arriving source
            // for that month could not be merged after the first generation's
            // detailed aggregates were retired. The whole month becomes
            // eligible only when its UTC end is beyond the detail horizon.
            guard input.aggregate.source.lastTimestamp < cutoff,
                  firstPeriod.end <= cutoff else {
                retained.append(input)
                continue
            }
            groups[firstPeriod.start, default: []].append(input)
        }
        let orderedGroups = groups.keys.sorted().map { key in
            groups[key]!.sorted { lhs, rhs in
                AtriaHistoricalLongTermRollup.sourceOrder(Self.source(from: lhs),
                                                          Self.source(from: rhs))
            }
        }
        let orderedRetained = retained.sorted {
            $0.aggregate.source.firstTimestamp < $1.aggregate.source.firstTimestamp
        }
        return .init(groups: orderedGroups,
                     retainedFullDetail: orderedRetained,
                     blockedSourceChunkIDs: blocked.sorted(),
                     retainedFullDetailBytes: orderedRetained.reduce(UInt64(0)) {
                         $0 + UInt64($1.aggregateData.count)
                     })
    }

    func build(group: [Input], createdAt: Date) throws -> AtriaHistoricalLongTermRollup {
        guard let first = group.first else { throw PlannerError.mixedPeriod }
        for input in group { try Self.validate(input) }
        let period = AtriaHistoricalLongTermRollup.utcMonthInterval(
            containing: first.aggregate.source.firstTimestamp
        )
        guard group.allSatisfy({ input in
            input.aggregate.source.firstTimestamp >= period.start
                && input.aggregate.source.lastTimestamp <= period.end
        }) else { throw PlannerError.mixedPeriod }

        let sorted = group.sorted {
            AtriaHistoricalLongTermRollup.sourceOrder(Self.source(from: $0),
                                                      Self.source(from: $1))
        }
        let sources = sorted.map(Self.source)
        let projections = sorted.flatMap { input in
            input.aggregate.materializedProjections.map { projection in
                AtriaHistoricalLongTermRollup.ProjectionReference(
                    sourceChunkID: input.aggregate.source.chunkID,
                    kind: projection.kind,
                    identifier: projection.identifier,
                    start: projection.start,
                    end: projection.end,
                    schemaVersion: projection.schemaVersion,
                    contentSHA256: projection.contentSHA256,
                    settledAt: projection.settledAt
                )
            }
        }.sorted(by: AtriaHistoricalLongTermRollup.projectionOrder)

        var dayStarts = Set<Date>()
        for input in sorted {
            input.aggregate.heartRateMinutes.forEach { dayStarts.insert(Self.utcDayStart($0.minuteStart)) }
            input.aggregate.rrEpochs.forEach { dayStarts.insert(Self.utcDayStart($0.start)) }
            input.aggregate.motionEpochs.forEach { dayStarts.insert(Self.utcDayStart($0.start)) }
        }
        let days = dayStarts.sorted().map { dayStart in
            Self.day(start: dayStart, inputs: sorted)
        }
        let rollup = AtriaHistoricalLongTermRollup(
            schema: AtriaHistoricalLongTermRollup.currentSchema,
            calendarVersion: AtriaHistoricalLongTermRollup.calendarVersion,
            createdAt: createdAt,
            periodStart: period.start,
            periodEnd: period.end,
            sources: sources,
            days: days,
            projectionReferences: projections,
            parity: AtriaHistoricalLongTermRollup.computedParity(
                sources: sources,
                projectionReferences: projections
            )
        )
        try rollup.validate()
        return rollup
    }

    static func canonicalData(_ rollup: AtriaHistoricalLongTermRollup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(rollup)
    }

    static func decodeCanonical(_ data: Data) throws -> AtriaHistoricalLongTermRollup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(AtriaHistoricalLongTermRollup.self, from: data)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ input: Input) throws {
        do { try input.aggregate.validateForCommit() } catch {
            throw PlannerError.invalidAggregate(input.aggregate.source.chunkID)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(AtriaHistoricalAggregateChunk.self,
                                                from: input.aggregateData),
              decoded == input.aggregate else {
            throw PlannerError.aggregateBytesMismatch(input.aggregate.source.chunkID)
        }
    }

    private static func source(from input: Input) -> AtriaHistoricalLongTermRollup.Source {
        let aggregate = input.aggregate
        return .init(chunkID: aggregate.source.chunkID,
                     rawSHA256: aggregate.source.rawSHA256,
                     aggregateSHA256: sha256(input.aggregateData),
                     aggregateSchema: aggregate.schema,
                     firstTimestamp: aggregate.source.firstTimestamp,
                     lastTimestamp: aggregate.source.lastTimestamp,
                     rawRows: aggregate.parity.rawRows,
                     decodedRows: aggregate.parity.decodedRows,
                     metricUsableRows: aggregate.parity.metricUsableRows,
                     heartRateSamples: aggregate.parity.heartRateSamples,
                     heartRateSumBPM: aggregate.parity.heartRateSumBPM,
                     acceptedRRBeats: aggregate.parity.acceptedRRBeats,
                     acceptedRRSumMilliseconds: aggregate.parity.acceptedRRSumMilliseconds,
                     validatedGravityRows: aggregate.parity.validatedGravityRows,
                     motionEpochs: aggregate.parity.motionEpochs,
                     projectionReceipts: aggregate.parity.projectionReceipts)
    }

    private static func day(start: Date, inputs: [Input]) -> AtriaHistoricalLongTermRollup.Day {
        let end = start.addingTimeInterval(86_400)
        let minutes = inputs.flatMap(\.aggregate.heartRateMinutes)
            .filter { $0.minuteStart >= start && $0.minuteStart < end }
            .sorted { $0.minuteStart < $1.minuteStart }
        let epochs = inputs.flatMap(\.aggregate.rrEpochs)
            .filter { $0.start >= start && $0.start < end }
            .sorted { $0.start < $1.start }
        let containedRR = epochs.filter { $0.end <= end }
        let boundaryRR = epochs.filter { $0.end > end }
        let motion = inputs.flatMap(\.aggregate.motionEpochs)
            .filter { $0.start >= start && $0.start < end }
            .sorted { $0.start < $1.start }
        return .init(start: start,
                     end: end,
                     heartRate: heartRateFacts(minutes),
                     rr: rrFacts(containedRR),
                     boundaryRREpochs: boundaryRR,
                     motion: motionFacts(motion))
    }

    private static func heartRateFacts(
        _ minutes: [AtriaHistoricalAggregateChunk.HeartRateMinute]
    ) -> AtriaHistoricalLongTermRollup.HeartRateFacts {
        var samples: [Int: Int] = [:]
        var terminal: [Int: Double] = [:]
        var transitions: [Int: Double] = [:]
        for minute in minutes {
            minute.samplesByBPM.forEach { samples[$0.key, default: 0] += $0.value }
            minute.terminalBPMSeconds.forEach { terminal[$0.key, default: 0] += $0.value }
            minute.transitionHalfBPMSeconds.forEach { transitions[$0.key, default: 0] += $0.value }
        }
        return .init(sampleCount: samples.values.reduce(0, +),
                     sumBPM: samples.reduce(Int64(0)) { $0 + Int64($1.key * $1.value) },
                     minimumBPM: samples.keys.min() ?? 0,
                     maximumBPM: samples.keys.max() ?? 0,
                     samplesByBPM: samples,
                     terminalBPMSeconds: terminal,
                     transitionHalfBPMSeconds: transitions,
                     coveredSeconds: minutes.reduce(0) { $0 + $1.coveredSeconds },
                     droppedGapSeconds: minutes.reduce(0) { $0 + $1.droppedGapSeconds })
    }

    private static func rrFacts(
        _ epochs: [AtriaHistoricalAggregateChunk.RREpoch]
    ) -> AtriaHistoricalLongTermRollup.RRFacts {
        var differenceCount = epochs.reduce(0) { $0 + $1.adjacentDifferenceCount }
        var differenceSquares = epochs.reduce(0) { $0 + $1.sumAdjacentDifferenceSquaredMilliseconds }
        var over50 = epochs.reduce(0) { $0 + $1.adjacentDifferenceOver50Count }
        for (previous, current) in zip(epochs, epochs.dropFirst())
            where previous.end == current.start {
            if let lhs = previous.lastNNMilliseconds,
               let rhs = current.firstNNMilliseconds {
                let difference = rhs - lhs
                differenceCount += 1
                differenceSquares += Double(difference * difference)
                if abs(difference) > 50 { over50 += 1 }
            }
        }
        return .init(epochCount: epochs.count,
                     firstEpochStart: epochs.first?.start,
                     lastEpochEnd: epochs.last?.end,
                     sourceRecordCount: epochs.reduce(0) { $0 + $1.sourceRecordCount },
                     acceptedBeatCount: epochs.reduce(0) { $0 + $1.acceptedBeatCount },
                     rejectedBeatCount: epochs.reduce(0) { $0 + $1.rejectedBeatCount },
                     sumNNMilliseconds: epochs.reduce(Int64(0)) { $0 + $1.sumNNMilliseconds },
                     sumNNSquaredMilliseconds: epochs.reduce(0) { $0 + $1.sumNNSquaredMilliseconds },
                     adjacentDifferenceCount: differenceCount,
                     sumAdjacentDifferenceSquaredMilliseconds: differenceSquares,
                     adjacentDifferenceOver50Count: over50,
                     firstNNMilliseconds: epochs.first?.firstNNMilliseconds,
                     lastNNMilliseconds: epochs.last?.lastNNMilliseconds,
                     coverageSeconds: epochs.reduce(0) { $0 + $1.coverageSeconds },
                     maximumGapSeconds: epochs.map(\.maximumGapSeconds).max() ?? 0,
                     projectionFingerprints: Dictionary(grouping: epochs,
                                                        by: \.projectionFingerprint)
                        .mapValues(\.count),
                     provenances: Dictionary(grouping: epochs, by: \.provenance)
                        .mapValues(\.count))
    }

    private static func motionFacts(
        _ epochs: [AtriaHistoricalAggregateChunk.MotionEpoch]
    ) -> AtriaHistoricalLongTermRollup.MotionFacts {
        func distribution(_ values: [Double]) -> [AtriaHistoricalLongTermRollup.ValueCount] {
            Dictionary(grouping: values, by: { $0 }).map { value, matches in
                .init(value: value, count: matches.count)
            }.sorted { $0.value < $1.value }
        }
        var stageGroups: [String: [AtriaHistoricalAggregateChunk.MotionEpoch]] = [:]
        for epoch in epochs {
            if let stage = epoch.sleepStage { stageGroups[stage, default: []].append(epoch) }
        }
        let stages = stageGroups.map { stage, members in
            let confidences = members.compactMap(\.sleepStageConfidence)
            return AtriaHistoricalLongTermRollup.StageFacts(
                stage: stage,
                epochCount: members.count,
                coverageSeconds: members.reduce(0) { $0 + $1.coverageSeconds },
                confidenceDistribution: distribution(confidences),
                confidenceMissingEpochs: members.count - confidences.count
            )
        }.sorted { $0.stage < $1.stage }
        let stillness = epochs.compactMap(\.stillnessRatio)
        let intensity = epochs.compactMap(\.movementIntensity)
        let p95 = epochs.compactMap(\.p95VectorDelta)
        return .init(epochCount: epochs.count,
                     rows: epochs.reduce(0) { $0 + $1.rows },
                     validatedRows: epochs.reduce(0) { $0 + $1.validatedRows },
                     rejectedRows: epochs.reduce(0) { $0 + $1.rejectedRows },
                     coverageSeconds: epochs.reduce(0) { $0 + $1.coverageSeconds },
                     maximumGapSeconds: epochs.map(\.maximumGapSeconds).max() ?? 0,
                     measurementValidatedEpochs: epochs.filter(\.measurementValidated).count,
                     lowMotionQualifiedEpochs: epochs.filter(\.lowMotionQualified).count,
                     stillnessDistribution: distribution(stillness),
                     stillnessMissingEpochs: epochs.count - stillness.count,
                     movementIntensityDistribution: distribution(intensity),
                     movementIntensityMissingEpochs: epochs.count - intensity.count,
                     p95VectorDeltaDistribution: distribution(p95),
                     p95VectorDeltaMissingEpochs: epochs.count - p95.count,
                     activityBurstsKnownEpochs: epochs.compactMap(\.activityBursts).count,
                     activityBurstsSum: epochs.compactMap(\.activityBursts)
                        .reduce(Int64(0)) { $0 + Int64($1) },
                     stepKnownEpochs: epochs.compactMap(\.stepDelta).count,
                     stepDeltaSum: epochs.compactMap(\.stepDelta).reduce(Int64(0)) { $0 + Int64($1) },
                     stages: stages,
                     algorithms: Dictionary(grouping: epochs, by: \.algorithmVersion)
                        .mapValues(\.count),
                     provenances: Dictionary(grouping: epochs, by: \.provenance)
                        .mapValues(\.count))
    }

    private static func utcDayStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 86_400) * 86_400)
    }
}

/// Immutable content-addressed publication. The commit manifest is written and
/// fsynced only after the rollup artifact is durable. Verification rebuilds the
/// entire rollup from the exact source aggregate bytes before returning a
/// retirement candidate; this module never removes a source file itself.
struct AtriaHistoricalLongTermStore {
    struct Manifest: Codable, Equatable, Sendable {
        static let currentVersion = 1
        let version: Int
        let periodStart: Date
        let periodEnd: Date
        let sourceSetSHA256: String
        let artifactFilename: String
        let artifactSHA256: String
        let artifactByteCount: UInt64
        let sources: [AtriaHistoricalLongTermRollup.Source]
        let parity: AtriaHistoricalLongTermRollup.Parity
        let committedAt: Date
    }

    struct Published: Equatable, Sendable {
        let manifest: Manifest
        let manifestURL: URL
        let artifactURL: URL
        let reusedExistingCommit: Bool
    }

    struct VerifiedSource: Equatable, Sendable {
        let chunkID: String
        let aggregateSHA256: String
        let manifestURL: URL
    }

    enum Checkpoint: String, Sendable {
        case artifactTemporaryDurable
        case artifactPublished
        case manifestTemporaryDurable
        case manifestPublished
    }

    enum StoreError: Error, Equatable {
        case invalidManifest
        case artifactConflict
        case manifestConflict
        case sourceInputMissing
        case semanticVerificationFailed
    }

    let directoryURL: URL
    var fileManager: FileManager = .default
    var checkpoint: (Checkpoint) throws -> Void = { _ in }

    func publish(_ rollup: AtriaHistoricalLongTermRollup,
                 committedAt: Date) throws -> Published {
        try rollup.validate()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let artifactData = try AtriaHistoricalLongTermPlanner.canonicalData(rollup)
        let artifactDigest = AtriaHistoricalLongTermPlanner.sha256(artifactData)
        let periodKey = Self.periodKey(rollup.periodStart)
        let artifactFilename = "long-term-rollup-\(periodKey)-\(artifactDigest).json"
        let artifactURL = directoryURL.appendingPathComponent(artifactFilename)
        let sourceSetData = Data(rollup.sources.map {
            "\($0.chunkID)|\($0.aggregateSHA256)"
        }.joined(separator: "\n").utf8)
        let sourceSetDigest = AtriaHistoricalLongTermPlanner.sha256(sourceSetData)
        let manifestURL = directoryURL.appendingPathComponent(
            "long-term-commit-\(periodKey)-\(sourceSetDigest).json"
        )
        let manifest = Manifest(version: Manifest.currentVersion,
                                periodStart: rollup.periodStart,
                                periodEnd: rollup.periodEnd,
                                sourceSetSHA256: sourceSetDigest,
                                artifactFilename: artifactFilename,
                                artifactSHA256: artifactDigest,
                                artifactByteCount: UInt64(artifactData.count),
                                sources: rollup.sources,
                                parity: rollup.parity,
                                committedAt: committedAt)
        let manifestData = try Self.canonicalManifestData(manifest)

        if fileManager.fileExists(atPath: manifestURL.path) {
            guard (try? Data(contentsOf: manifestURL)) == manifestData,
                  fileManager.fileExists(atPath: artifactURL.path),
                  (try? Self.sha256(fileURL: artifactURL)) == artifactDigest else {
                throw StoreError.manifestConflict
            }
            return .init(manifest: manifest,
                         manifestURL: manifestURL,
                         artifactURL: artifactURL,
                         reusedExistingCommit: true)
        }
        if fileManager.fileExists(atPath: artifactURL.path) {
            guard try Self.sha256(fileURL: artifactURL) == artifactDigest else {
                throw StoreError.artifactConflict
            }
        } else {
            let temporary = directoryURL.appendingPathComponent(".\(artifactFilename).\(UUID().uuidString).tmp")
            try Self.writeDurable(artifactData, to: temporary)
            try checkpoint(.artifactTemporaryDurable)
            try publishTemporary(temporary, to: artifactURL, expectedDigest: artifactDigest,
                                 conflict: .artifactConflict)
            try Self.fsyncDirectory(directoryURL)
            try checkpoint(.artifactPublished)
        }
        let temporary = directoryURL.appendingPathComponent(".\(manifestURL.lastPathComponent).\(UUID().uuidString).tmp")
        try Self.writeDurable(manifestData, to: temporary)
        try checkpoint(.manifestTemporaryDurable)
        try publishTemporary(temporary,
                             to: manifestURL,
                             expectedDigest: AtriaHistoricalLongTermPlanner.sha256(manifestData),
                             conflict: .manifestConflict)
        try Self.fsyncDirectory(directoryURL)
        try checkpoint(.manifestPublished)
        return .init(manifest: manifest,
                     manifestURL: manifestURL,
                     artifactURL: artifactURL,
                     reusedExistingCommit: false)
    }

    func verifiedRetirementCandidates(
        inputs: [AtriaHistoricalLongTermPlanner.Input],
        now: Date,
        fullDetailHorizon: TimeInterval = 90 * 86_400,
        /// Must re-open, hash, decode, and semantically compare the actual
        /// durable consumer artifact represented by the reference. Metadata
        /// copied into a rollup is never proof by itself. The default therefore
        /// authorizes only sources that genuinely have no projection receipts.
        projectionVerifier: (AtriaHistoricalLongTermRollup.ProjectionReference) throws -> Bool = { _ in false }
    ) -> [VerifiedSource] {
        guard fullDetailHorizon >= 0, fullDetailHorizon.isFinite else { return [] }
        let cutoff = now.addingTimeInterval(-fullDetailHorizon)
        var byDigest: [String: AtriaHistoricalLongTermPlanner.Input] = [:]
        for input in inputs {
            let digest = AtriaHistoricalLongTermPlanner.sha256(input.aggregateData)
            guard byDigest.updateValue(input, forKey: digest) == nil else { return [] }
        }
        let manifests = ((try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.lastPathComponent.hasPrefix("long-term-commit-") && $0.pathExtension == "json" }
        var verified: [VerifiedSource] = []
        for manifestURL in manifests.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? Self.decodeManifest(manifestData),
                  Self.valid(manifest),
                  let artifactURL = Self.safeArtifactURL(manifest.artifactFilename,
                                                         directoryURL: directoryURL),
                  fileManager.fileExists(atPath: artifactURL.path),
                  let artifactData = try? Data(contentsOf: artifactURL),
                  UInt64(artifactData.count) == manifest.artifactByteCount,
                  AtriaHistoricalLongTermPlanner.sha256(artifactData) == manifest.artifactSHA256,
                  let stored = try? AtriaHistoricalLongTermPlanner.decodeCanonical(artifactData),
                  (try? stored.validate()) != nil,
                  stored.sources == manifest.sources,
                  stored.parity == manifest.parity else { continue }
            let sourceInputs = manifest.sources.compactMap { byDigest[$0.aggregateSHA256] }
            guard sourceInputs.count == manifest.sources.count,
                  let rebuilt = try? AtriaHistoricalLongTermPlanner(
                    fullDetailHorizon: fullDetailHorizon
                  ).build(group: sourceInputs, createdAt: stored.createdAt),
                  rebuilt == stored,
                  (try? AtriaHistoricalLongTermPlanner.canonicalData(rebuilt)) == artifactData,
                  stored.projectionReferences.allSatisfy({ reference in
                      (try? projectionVerifier(reference)) == true
                  }) else {
                continue
            }
            for source in manifest.sources where source.lastTimestamp < cutoff {
                verified.append(.init(chunkID: source.chunkID,
                                      aggregateSHA256: source.aggregateSHA256,
                                      manifestURL: manifestURL))
            }
        }
        return Dictionary(grouping: verified, by: \.aggregateSHA256).compactMap { _, matches in
            matches.count == 1 ? matches[0] : nil
        }.sorted { $0.chunkID < $1.chunkID }
    }

    private func publishTemporary(_ temporaryURL: URL,
                                  to finalURL: URL,
                                  expectedDigest: String,
                                  conflict: StoreError) throws {
        if fileManager.fileExists(atPath: finalURL.path) {
            guard try Self.sha256(fileURL: finalURL) == expectedDigest else { throw conflict }
            try? fileManager.removeItem(at: temporaryURL)
            return
        }
        do {
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            if fileManager.fileExists(atPath: finalURL.path),
               try Self.sha256(fileURL: finalURL) == expectedDigest {
                try? fileManager.removeItem(at: temporaryURL)
                return
            }
            throw error
        }
    }

    private static func valid(_ manifest: Manifest) -> Bool {
        guard manifest.version == Manifest.currentVersion,
              manifest.periodEnd > manifest.periodStart,
              manifest.artifactByteCount > 0,
              !manifest.sources.isEmpty,
              manifest.sources == manifest.sources.sorted(by: AtriaHistoricalLongTermRollup.sourceOrder),
              manifest.parity == AtriaHistoricalLongTermRollup.computedParity(
                sources: manifest.sources,
                projectionReferenceCount: manifest.parity.projectionReferences
              ),
              Self.isSHA256(manifest.sourceSetSHA256),
              Self.isSHA256(manifest.artifactSHA256),
              manifest.artifactFilename == "long-term-rollup-\(periodKey(manifest.periodStart))-\(manifest.artifactSHA256).json" else {
            return false
        }
        let expectedSourceSet = Data(manifest.sources.map {
            "\($0.chunkID)|\($0.aggregateSHA256)"
        }.joined(separator: "\n").utf8)
        return AtriaHistoricalLongTermPlanner.sha256(expectedSourceSet) == manifest.sourceSetSHA256
    }

    private static func safeArtifactURL(_ filename: String, directoryURL: URL) -> URL? {
        guard !filename.isEmpty,
              URL(fileURLWithPath: filename).lastPathComponent == filename else { return nil }
        let url = directoryURL.appendingPathComponent(filename)
        return url.deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL
            ? url : nil
    }

    private static func canonicalManifestData(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    private static func decodeManifest(_ data: Data) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Manifest.self, from: data)
    }

    private static func writeDurable(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func fsyncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    private static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        let characters = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count == 64 && value.unicodeScalars.allSatisfy(characters.contains)
    }

    private static func periodKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }
}
