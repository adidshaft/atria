import CryptoKit
import Foundation

/// Canonical raw-to-aggregate projection for immutable history chunks.
/// Decodable rows become canonical aggregate facts. Unknown legacy envelopes
/// remain counted in parity and require the immutable source to stay on disk;
/// an aggregate containing any such row can never authorize raw retirement.
enum AtriaHistoricalAggregateBuilder {
    enum BuildError: Error, Equatable {
        case sourceMissing
        case emptySource
        case tornTrailingRow
        case undecodableRows(Int)
        case rowCountMismatch(expected: Int, actual: Int)
        case invalidTimestamp
        case sourceChangedDuringProjection
    }

    struct FileBuildResult {
        let aggregate: AtriaHistoricalAggregateChunk
        let semanticParityReceipt: String
    }

    /// Capability proving that one immutable retained raw source produced this
    /// exact canonical aggregate. The initializer is intentionally private:
    /// callers cannot turn an aggregate's self-hash into raw-semantic proof.
    ///
    /// This proof is only eligible for shadow publication where raw remains
    /// authoritative. Irreversible retirement continues to rebuild from raw.
    struct RetainedRawShadowProof {
        let aggregate: AtriaHistoricalAggregateChunk
        let semanticParityReceipt: String
        let sourceIdentity: AtriaHistoricalJSONLInput.Identity
        fileprivate let seal: String

        fileprivate init(
            aggregate: AtriaHistoricalAggregateChunk,
            semanticParityReceipt: String,
            sourceIdentity: AtriaHistoricalJSONLInput.Identity,
            seal: String
        ) {
            self.aggregate = aggregate
            self.semanticParityReceipt = semanticParityReceipt
            self.sourceIdentity = sourceIdentity
            self.seal = seal
        }
    }

    private struct HRPoint {
        let timestamp: Date
        let bpm: Int
    }

    private struct HRBucket {
        var samplesByBPM: [Int: Int] = [:]
        var terminalBPMSeconds: [Int: Double] = [:]
        var transitionHalfBPMSeconds: [Int: Double] = [:]
        var coveredSeconds = 0.0
        var droppedGapSeconds = 0.0
        var first: HRPoint?
        var last: HRPoint?
    }

    static func build(sourceURL: URL,
                      chunkID: String,
                      createdAt: Date,
                      materializedProjections: [AtriaHistoricalAggregateChunk.MaterializedProjection] = []) throws -> FileBuildResult {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw BuildError.sourceMissing }
        let identity = try AtriaHistoricalJSONLInput.identity(at: sourceURL)
        return try build(
            sourceURL: sourceURL,
            chunkID: chunkID,
            createdAt: createdAt,
            materializedProjections: materializedProjections,
            identity: identity
        )
    }

    /// Builds canonical shadow facts once and seals the source identity on both
    /// sides of that projection. Hash-only passes are intentionally cheaper
    /// than repeating JSON decode, RR projection, and motion projection.
    static func buildRetainedRawShadowProof(
        sourceURL: URL,
        chunkID: String,
        createdAt: Date,
        materializedProjections: [AtriaHistoricalAggregateChunk.MaterializedProjection] = []
    ) throws -> RetainedRawShadowProof {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw BuildError.sourceMissing
        }
        let before = try AtriaHistoricalJSONLInput.identity(at: sourceURL)
        let result = try build(
            sourceURL: sourceURL,
            chunkID: chunkID,
            createdAt: createdAt,
            materializedProjections: materializedProjections,
            identity: before
        )
        let after = try AtriaHistoricalJSONLInput.identity(at: sourceURL)
        guard before == after,
              result.aggregate.source.rawSHA256 == after.sha256,
              result.aggregate.source.rawByteCount == after.byteCount else {
            throw BuildError.sourceChangedDuringProjection
        }
        return .init(
            aggregate: result.aggregate,
            semanticParityReceipt: result.semanticParityReceipt,
            sourceIdentity: after,
            seal: retainedRawShadowSeal(
                aggregate: result.aggregate,
                semanticParityReceipt: result.semanticParityReceipt,
                sourceIdentity: after
            )
        )
    }

    static func validateRetainedRawShadowProof(
        _ proof: RetainedRawShadowProof
    ) -> Bool {
        proof.aggregate.source.rawSHA256 == proof.sourceIdentity.sha256
            && proof.aggregate.source.rawByteCount == proof.sourceIdentity.byteCount
            && semanticParityReceipt(for: proof.aggregate)
                == proof.semanticParityReceipt
            && retainedRawShadowSeal(
                aggregate: proof.aggregate,
                semanticParityReceipt: proof.semanticParityReceipt,
                sourceIdentity: proof.sourceIdentity
            ) == proof.seal
    }

    private static func build(
        sourceURL: URL,
        chunkID: String,
        createdAt: Date,
        materializedProjections: [AtriaHistoricalAggregateChunk.MaterializedProjection],
        identity: AtriaHistoricalJSONLInput.Identity
    ) throws -> FileBuildResult {
        let scan = try decodeRecords(at: sourceURL)
        guard !scan.records.isEmpty else { throw BuildError.emptySource }
        let timestamps = scan.records.compactMap(effectiveTimestamp)
        guard let first = timestamps.min(), let last = timestamps.max() else {
            throw BuildError.invalidTimestamp
        }
        let source = AtriaHistoricalAggregateChunk.Source(
            chunkID: chunkID,
            rawSHA256: identity.sha256,
            rawByteCount: identity.byteCount,
            rawRowCount: scan.rowCount,
            firstTimestamp: first,
            lastTimestamp: last,
            decoderSchema: HistoricalArchive.schema,
            validatedLayouts: Array(HistoricalArchive.validatedMetricLayoutVersions).sorted()
        )
        let aggregate = try build(records: scan.records,
                                  source: source,
                                  createdAt: createdAt,
                                  materializedProjections: materializedProjections,
                                  undecodableRowsRetainedRaw: scan.undecodableRows)
        return FileBuildResult(aggregate: aggregate,
                               semanticParityReceipt: semanticParityReceipt(for: aggregate))
    }

    static func build(records: [HistoricalArchive.Record],
                      source: AtriaHistoricalAggregateChunk.Source,
                      createdAt: Date,
                      materializedProjections: [AtriaHistoricalAggregateChunk.MaterializedProjection] = [],
                      undecodableRowsRetainedRaw: Int = 0) throws -> AtriaHistoricalAggregateChunk {
        guard undecodableRowsRetainedRaw >= 0,
              records.count + undecodableRowsRetainedRaw == source.rawRowCount else {
            throw BuildError.rowCountMismatch(
                expected: source.rawRowCount,
                actual: records.count + max(0, undecodableRowsRetainedRaw)
            )
        }
        let hrMinutes = buildHeartRateMinutes(records: records)
        let rrEpochs = buildRREpochs(records: records)
        let motionEpochs = buildMotionEpochs(records: records,
                                             start: source.firstTimestamp,
                                             end: source.lastTimestamp)
        let metricUsable = records.filter(\.metricUsable).count
        let hrCount = hrMinutes.reduce(0) { $0 + $1.sampleCount }
        let hrSum = hrMinutes.reduce(Int64(0)) { $0 + $1.sumBPM }
        let rrCount = rrEpochs.reduce(0) { $0 + $1.acceptedBeatCount }
        let rrSum = rrEpochs.reduce(Int64(0)) { $0 + $1.sumNNMilliseconds }
        let validatedGravity = motionEpochs.reduce(0) { $0 + $1.validatedRows }
        let aggregate = AtriaHistoricalAggregateChunk(
            schema: AtriaHistoricalAggregateChunk.currentSchema,
            createdAt: createdAt,
            source: source,
            heartRateMinutes: hrMinutes,
            rrEpochs: rrEpochs,
            motionEpochs: motionEpochs,
            materializedProjections: materializedProjections,
            parity: .init(rawRows: source.rawRowCount,
                          decodedRows: records.count,
                          undecodableRowsRetainedRaw: undecodableRowsRetainedRaw,
                          metricUsableRows: metricUsable,
                          heartRateSamples: hrCount,
                          heartRateSumBPM: hrSum,
                          acceptedRRBeats: rrCount,
                          acceptedRRSumMilliseconds: rrSum,
                          validatedGravityRows: validatedGravity,
                          motionEpochs: motionEpochs.count,
                          projectionReceipts: materializedProjections.count)
        )
        try aggregate.validateForCommit()
        return aggregate
    }

    /// Rebuilds canonical raw-derived facts and verifies the content-addressed
    /// receipt used by `AtriaHistoricalRetentionTransaction`.
    static func verify(sourceURL: URL,
                       aggregate: AtriaHistoricalAggregateChunk,
                       semanticParityReceipt: String) throws -> Bool {
        guard try AtriaHistoricalJSONLInput.identity(at: sourceURL).sha256
            == aggregate.source.rawSHA256 else {
            return false
        }
        let rebuilt = try build(sourceURL: sourceURL,
                                chunkID: aggregate.source.chunkID,
                                createdAt: aggregate.createdAt,
                                materializedProjections: aggregate.materializedProjections).aggregate
        return rebuilt == aggregate
            && Self.semanticParityReceipt(for: rebuilt) == semanticParityReceipt
    }

    static func semanticParityReceipt(for aggregate: AtriaHistoricalAggregateChunk) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let content = (try? encoder.encode(aggregate)) ?? Data()
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        return "historical-semantic-parity-v2-\(digest)"
    }

    private static func retainedRawShadowSeal(
        aggregate: AtriaHistoricalAggregateChunk,
        semanticParityReceipt: String,
        sourceIdentity: AtriaHistoricalJSONLInput.Identity
    ) -> String {
        let content = [
            "historical-retained-raw-shadow-v1",
            sourceIdentity.sha256,
            String(sourceIdentity.byteCount),
            aggregate.source.chunkID,
            semanticParityReceipt,
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "historical-retained-raw-shadow-proof-v1-\(digest)"
    }

    private static func buildHeartRateMinutes(
        records: [HistoricalArchive.Record]
    ) -> [AtriaHistoricalAggregateChunk.HeartRateMinute] {
        let points = records.compactMap { record -> HRPoint? in
            guard record.metricUsable,
                  HistoricalArchive.metricLayoutValidated(record.layoutVersion),
                  record.clockCorrectionStatus == "clock_ref_present",
                  record.clockCorrectedUnix7 != nil,
                  (35...240).contains(record.whoofHR17),
                  let timestamp = effectiveTimestamp(record) else { return nil }
            return HRPoint(timestamp: timestamp, bpm: record.whoofHR17)
        }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.bpm < $1.bpm
        }

        var buckets: [Int: HRBucket] = [:]
        for point in points {
            let minute = Int(point.timestamp.timeIntervalSince1970) / 60 * 60
            var bucket = buckets[minute] ?? HRBucket()
            bucket.samplesByBPM[point.bpm, default: 0] += 1
            if bucket.first == nil { bucket.first = point }
            bucket.last = point
            buckets[minute] = bucket
        }
        for (previous, current) in zip(points, points.dropFirst()) {
            let dt = current.timestamp.timeIntervalSince(previous.timestamp)
            guard dt > 0 else { continue }
            let minute = Int(current.timestamp.timeIntervalSince1970) / 60 * 60
            var bucket = buckets[minute] ?? HRBucket()
            if dt <= AtriaAnalytics.Strain.maximumLoadEvidenceGap {
                bucket.terminalBPMSeconds[current.bpm, default: 0] += dt
                bucket.transitionHalfBPMSeconds[previous.bpm + current.bpm, default: 0] += dt
                bucket.coveredSeconds += dt
            } else {
                bucket.droppedGapSeconds += dt
            }
            buckets[minute] = bucket
        }
        return buckets.sorted(by: { $0.key < $1.key }).map { minute, bucket in
            let count = bucket.samplesByBPM.values.reduce(0, +)
            let sum = bucket.samplesByBPM.reduce(Int64(0)) {
                $0 + Int64($1.key * $1.value)
            }
            return .init(minuteStart: Date(timeIntervalSince1970: TimeInterval(minute)),
                         sampleCount: count,
                         sumBPM: sum,
                         minimumBPM: bucket.samplesByBPM.keys.min() ?? 0,
                         maximumBPM: bucket.samplesByBPM.keys.max() ?? 0,
                         samplesByBPM: bucket.samplesByBPM,
                         terminalBPMSeconds: bucket.terminalBPMSeconds,
                         transitionHalfBPMSeconds: bucket.transitionHalfBPMSeconds,
                         coveredSeconds: bucket.coveredSeconds,
                         droppedGapSeconds: bucket.droppedGapSeconds,
                         firstSampleUnix: bucket.first?.timestamp.timeIntervalSince1970,
                         firstSampleBPM: bucket.first?.bpm,
                         lastSampleUnix: bucket.last?.timestamp.timeIntervalSince1970,
                         lastSampleBPM: bucket.last?.bpm)
        }
    }

    private static func buildRREpochs(
        records: [HistoricalArchive.Record]
    ) -> [AtriaHistoricalAggregateChunk.RREpoch] {
        let result = AtriaRecoveredRRProjection.project(records: records)
        let epochSeconds = 5 * 60
        let grouped = Dictionary(grouping: result.beats) { beat in
            Int(beat.timestamp.timeIntervalSince1970) / epochSeconds * epochSeconds
        }
        return grouped.sorted(by: { $0.key < $1.key }).map { startUnix, unsorted in
            let beats = unsorted.sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id < $1.id
            }
            let intervals = beats.map(\.intervalMilliseconds)
            let differences = zip(intervals, intervals.dropFirst()).map { $1 - $0 }
            let fingerprintInput = beats.map {
                "\($0.id)|\($0.timestamp.timeIntervalSince1970.bitPattern)|\($0.intervalMilliseconds)"
            }.joined(separator: "\n")
            let fingerprint = SHA256.hash(data: Data(fingerprintInput.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let coverage = beats.count > 1
                ? beats.last!.timestamp.timeIntervalSince(beats.first!.timestamp)
                : 0
            let gaps = zip(beats, beats.dropFirst()).map { $1.timestamp.timeIntervalSince($0.timestamp) }
            return .init(start: Date(timeIntervalSince1970: TimeInterval(startUnix)),
                         end: Date(timeIntervalSince1970: TimeInterval(startUnix + epochSeconds)),
                         sourceRecordCount: Set(beats.map(\.recordID)).count,
                         acceptedBeatCount: beats.count,
                         rejectedBeatCount: 0,
                         sumNNMilliseconds: intervals.reduce(Int64(0)) { $0 + Int64($1) },
                         sumNNSquaredMilliseconds: intervals.reduce(0) { $0 + Double($1 * $1) },
                         adjacentDifferenceCount: differences.count,
                         sumAdjacentDifferenceSquaredMilliseconds: differences.reduce(0) {
                             $0 + Double($1 * $1)
                         },
                         adjacentDifferenceOver50Count: differences.filter { abs($0) > 50 }.count,
                         firstNNMilliseconds: intervals.first,
                         lastNNMilliseconds: intervals.last,
                         coverageSeconds: coverage,
                         maximumGapSeconds: gaps.max() ?? 0,
                         projectionFingerprint: "rr-epoch-v1-\(fingerprint)",
                         provenance: AtriaRecoveredRRProjection.Provenance
                            .verifiedWhoop4HistoricalV24.rawValue)
        }
    }

    private static func buildMotionEpochs(
        records: [HistoricalArchive.Record],
        start: Date,
        end: Date
    ) -> [AtriaHistoricalAggregateChunk.MotionEpoch] {
        guard end > start else { return [] }
        let samples = records.compactMap { record -> AtriaRecoveredMotionProjection.Sample? in
            guard let timestamp = effectiveTimestamp(record),
                  let x = record.gravityX36,
                  let y = record.gravityY40,
                  let z = record.gravityZ44 else { return nil }
            return .init(timestamp: timestamp,
                         sequence: record.sequence,
                         x: x,
                         y: y,
                         z: z,
                         timestampValidated: record.clockCorrectionStatus == "clock_ref_present"
                            && record.clockCorrectedUnix7 != nil,
                         gravityValidated: record.gravityValidated)
        }
        var projected = AtriaRecoveredMotionProjection.epochFeatures(
            samples: samples,
            start: start,
            end: end
        )
        var coalescedTerminal = false
        if let terminal = projected.last,
           wholeSecond(terminal.start) == wholeSecond(terminal.end) {
            // Foundation's canonical ISO-8601 persistence drops fractional
            // seconds. A sub-second terminal bucket would therefore decode as
            // a zero-duration, invalid epoch. Preserve the exact source end
            // and every source row by recomputing the previous bucket plus the
            // tail as one bounded terminal epoch. No future time is invented.
            if projected.count >= 2 {
                let mergedStart = projected[projected.count - 2].start
                let mergedDuration = end.timeIntervalSince(mergedStart)
                let mergedSamples = samples.filter {
                    $0.timestamp >= mergedStart && $0.timestamp <= end
                }
                let merged = AtriaRecoveredMotionProjection.epochFeatures(
                    samples: mergedSamples,
                    start: mergedStart,
                    end: end,
                    epochDuration: mergedDuration
                )
                if let terminal = merged.first, merged.count == 1 {
                    projected.removeLast(2)
                    projected.append(terminal)
                    coalescedTerminal = true
                }
            } else {
                // A source shorter than one persisted second cannot carry a
                // truthful bounded motion interval in schema v2. The retained
                // raw remains authoritative; do not invent an interval.
                projected.removeAll()
            }
        }
        return projected.enumerated().map { index, epoch in
            .init(start: epoch.start,
                  end: epoch.end,
                  rows: epoch.rows,
                  validatedRows: epoch.validatedRows,
                  rejectedRows: epoch.rows - epoch.validatedRows,
                  coverageSeconds: max(0, Int(epoch.end.timeIntervalSince(epoch.start).rounded())),
                  maximumGapSeconds: epoch.maximumGapSeconds,
                  stillnessRatio: epoch.stillnessRatio,
                  movementIntensity: epoch.movementIntensity,
                  p95VectorDelta: epoch.p95VectorDelta,
                  activityBursts: nil,
                  stepDelta: AtriaHistoricalStepRecovery.stepDeltaFromHistoricalGravity(),
                  measurementValidated: epoch.measurementValidated,
                  lowMotionQualified: epoch.lowMotionQualified,
                  sleepStage: nil,
                  sleepStageConfidence: nil,
                  algorithmVersion: coalescedTerminal && index == projected.count - 1
                    ? "recovered-motion-epoch-v2"
                    : "recovered-motion-epoch-v1",
                  provenance: AtriaRecoveredMotionProjection.source)
        }
    }

    private static func wholeSecond(_ date: Date) -> TimeInterval {
        floor(date.timeIntervalSince1970)
    }

    private static func effectiveTimestamp(_ record: HistoricalArchive.Record) -> Date? {
        let unix = record.clockCorrectedUnix7 ?? record.unix7
        guard unix > 0, record.subsec11 < 32_768 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(unix) + TimeInterval(record.subsec11) / 32_768)
    }

    private static func decodeRecords(at url: URL) throws -> (records: [HistoricalArchive.Record], rowCount: Int, undecodableRows: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [HistoricalArchive.Record] = []
        var rowCount = 0
        var undecodable = 0
        do {
            try AtriaHistoricalJSONLInput.forEachLine(at: url) { line in
                guard !line.isEmpty else { return }
                rowCount += 1
                if let record = try? decoder.decode(HistoricalArchive.Record.self, from: line) {
                    records.append(record)
                } else {
                    undecodable += 1
                }
            }
        } catch AtriaHistoricalSealedJSONLCompression.TransactionError.tornTrailingRow {
            throw BuildError.tornTrailingRow
        }
        return (records, rowCount, undecodable)
    }
}
