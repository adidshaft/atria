import Foundation

/// Reads only aggregates with a valid committed manifest. Orphan/torn/tampered
/// files are ignored; they can never become lookback truth merely by existing.
struct AtriaHistoricalAggregateReader {
    struct Diagnostics: Equatable, Sendable {
        let committedManifests: Int
        let acceptedAggregates: Int
        let rejectedManifests: Int
        let limitExceeded: Bool

        init(committedManifests: Int,
             acceptedAggregates: Int,
             rejectedManifests: Int,
             limitExceeded: Bool = false) {
            self.committedManifests = committedManifests
            self.acceptedAggregates = acceptedAggregates
            self.rejectedManifests = rejectedManifests
            self.limitExceeded = limitExceeded
        }
    }

    struct Snapshot: Sendable {
        let aggregates: [AtriaHistoricalAggregateChunk]
        let diagnostics: Diagnostics
    }

    /// Stable newest-to-oldest cursor used by history surfaces. The timestamp
    /// alone is insufficient because several committed chunks can end in the
    /// same device second.
    struct PageCursor: Codable, Equatable, Sendable {
        let sourceLastTimestamp: Date
        let sourceChunkID: String
    }

    struct Page: Sendable {
        let snapshot: Snapshot
        let nextCursor: PageCursor?
        let hasMore: Bool
    }

    struct ChunkIDSnapshot: Sendable {
        let chunkIDs: Set<String>
        let rejectedManifests: Int
        let limitExceeded: Bool
    }

    struct LoadLimits: Equatable, Sendable {
        let maximumManifestCount: Int
        let maximumManifestBytes: UInt64
        let maximumAggregateBytes: UInt64
        let maximumTotalAggregateBytes: UInt64

        var isValid: Bool {
            maximumManifestCount > 0
                && maximumManifestBytes > 0
                && maximumAggregateBytes > 0
                && maximumTotalAggregateBytes > 0
        }
    }

    struct HeartRateChartPoint: Equatable, Sendable {
        let minuteStart: Date
        let averageBPM: Double
        let minimumBPM: Int
        let maximumBPM: Int
        let sampleCount: Int
    }

    struct LoadBasis: Equatable, Sendable {
        let terminalBPMSeconds: [Int: Double]
        let transitionHalfBPMSeconds: [Int: Double]
        let coveredSeconds: Double
        let droppedGapSeconds: Double
    }

    struct RRStatistics: Equatable, Sendable {
        let beatCount: Int
        let sumNNMilliseconds: Int64
        let sumNNSquaredMilliseconds: Double
        let adjacentDifferenceCount: Int
        let sumAdjacentDifferenceSquaredMilliseconds: Double
        let adjacentDifferenceOver50Count: Int
    }

    let aggregateDirectoryURL: URL
    let manifestDirectoryURL: URL
    var fileManager: FileManager = .default

    /// Date bounds are applied from the small durable manifest before any
    /// aggregate file is hashed or decoded. Resident memory therefore scales
    /// with the requested lookback, not total archive age.
    func load(since: Date? = nil,
              until: Date? = nil,
              limits: LoadLimits? = nil) -> Snapshot {
        var manifestURLs: [URL] = []
        if let enumerator = fileManager.enumerator(
            at: manifestDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "json" {
                manifestURLs.append(url)
                if let limits,
                   manifestURLs.count > limits.maximumManifestCount {
                    return Snapshot(
                        aggregates: [],
                        diagnostics: .init(committedManifests: manifestURLs.count,
                                           acceptedAggregates: 0,
                                           rejectedManifests: 0,
                                           limitExceeded: true)
                    )
                }
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var accepted: [AtriaHistoricalAggregateChunk] = []
        var rejected = 0
        var totalAggregateBytes: UInt64 = 0
        var limitExceeded = false
        if let limits, !limits.isValid {
            return Snapshot(aggregates: [],
                            diagnostics: .init(committedManifests: manifestURLs.count,
                                               acceptedAggregates: 0,
                                               rejectedManifests: 0,
                                               limitExceeded: true))
        }
        for manifestURL in manifestURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let manifestData: Data
                if let limits {
                    manifestData = try boundedData(at: manifestURL,
                                                   maximumBytes: limits.maximumManifestBytes)
                } else {
                    manifestData = try Data(contentsOf: manifestURL)
                }
                let manifest = try decoder.decode(AtriaHistoricalRetentionTransaction.Manifest.self,
                                                  from: manifestData)
                guard manifest.version == AtriaHistoricalRetentionTransaction.Manifest.currentVersion,
                      safeFilename(manifest.aggregateFilename) else {
                    rejected += 1
                    continue
                }
                if let since, manifest.sourceLastTimestamp < since { continue }
                if let until, manifest.sourceFirstTimestamp >= until { continue }
                let aggregateURL = aggregateDirectoryURL.appendingPathComponent(manifest.aggregateFilename)
                guard fileManager.fileExists(atPath: aggregateURL.path) else {
                    rejected += 1
                    continue
                }
                let actualAggregateBytes = try fileByteCount(at: aggregateURL)
                guard actualAggregateBytes == manifest.aggregateByteCount else {
                    rejected += 1
                    continue
                }
                var aggregateReadLimit: UInt64?
                if let limits {
                    let (nextTotal, overflow) = totalAggregateBytes
                        .addingReportingOverflow(actualAggregateBytes)
                    guard !overflow,
                          actualAggregateBytes <= limits.maximumAggregateBytes,
                          nextTotal <= limits.maximumTotalAggregateBytes else {
                        limitExceeded = true
                        break
                    }
                    aggregateReadLimit = min(limits.maximumAggregateBytes,
                                             limits.maximumTotalAggregateBytes - totalAggregateBytes)
                }
                let aggregateData: Data
                if let aggregateReadLimit {
                    aggregateData = try boundedData(at: aggregateURL,
                                                    maximumBytes: aggregateReadLimit)
                } else {
                    aggregateData = try Data(contentsOf: aggregateURL)
                }
                guard UInt64(aggregateData.count) == actualAggregateBytes,
                      AtriaHistoricalRetentionTransaction.sha256(of: aggregateData)
                        == manifest.aggregateSHA256 else {
                    rejected += 1
                    continue
                }
                if limits != nil {
                    totalAggregateBytes += UInt64(aggregateData.count)
                }
                let aggregate = try decoder.decode(AtriaHistoricalAggregateChunk.self,
                                                   from: aggregateData)
                try aggregate.validateForCommit()
                guard aggregate.schema == manifest.aggregateSchema,
                      aggregate.source.chunkID == manifest.sourceChunkID,
                      aggregate.source.rawSHA256 == manifest.sourceSHA256,
                      aggregate.source.rawByteCount == manifest.sourceByteCount,
                      aggregate.source.rawRowCount == manifest.sourceRowCount,
                      aggregate.source.firstTimestamp == manifest.sourceFirstTimestamp,
                      aggregate.source.lastTimestamp == manifest.sourceLastTimestamp,
                      aggregate.heartRateMinutes.count == manifest.heartRateMinuteCount,
                      aggregate.rrEpochs.count == manifest.rrEpochCount,
                      aggregate.motionEpochs.count == manifest.motionEpochCount,
                      AtriaHistoricalAggregateBuilder.semanticParityReceipt(for: aggregate)
                        == manifest.semanticParityReceipt else {
                    rejected += 1
                    continue
                }
                accepted.append(aggregate)
            } catch BoundedReadError.limitExceeded {
                limitExceeded = true
                break
            } catch {
                rejected += 1
            }
        }
        accepted.sort {
            if $0.source.firstTimestamp != $1.source.firstTimestamp {
                return $0.source.firstTimestamp < $1.source.firstTimestamp
            }
            return $0.source.chunkID < $1.source.chunkID
        }
        return Snapshot(aggregates: accepted,
                        diagnostics: .init(committedManifests: manifestURLs.count,
                                           acceptedAggregates: accepted.count,
                                           rejectedManifests: rejected,
                                           limitExceeded: limitExceeded))
    }

    /// Reads at most one bounded page of aggregate payloads. Manifest commit
    /// markers are small and are inspected to select the page first; only the
    /// selected aggregate files are hashed and decoded. This keeps launch work
    /// proportional to the requested page rather than total archive payload.
    func loadPage(
        after cursor: PageCursor? = nil,
        maximumAggregateCount: Int,
        limits: LoadLimits
    ) -> Page {
        guard maximumAggregateCount > 0, limits.isValid else {
            return Page(snapshot: Snapshot(aggregates: [],
                                           diagnostics: .init(committedManifests: 0,
                                                              acceptedAggregates: 0,
                                                              rejectedManifests: 0,
                                                              limitExceeded: true)),
                        nextCursor: nil,
                        hasMore: false)
        }

        var manifestURLs: [URL] = []
        if let enumerator = fileManager.enumerator(
            at: manifestDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "json" {
                manifestURLs.append(url)
                if manifestURLs.count > limits.maximumManifestCount {
                    return Page(snapshot: Snapshot(aggregates: [],
                                                   diagnostics: .init(committedManifests: manifestURLs.count,
                                                                      acceptedAggregates: 0,
                                                                      rejectedManifests: 0,
                                                                      limitExceeded: true)),
                                nextCursor: nil,
                                hasMore: false)
                }
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var candidates: [(manifest: AtriaHistoricalRetentionTransaction.Manifest, url: URL)] = []
        var rejected = 0
        for url in manifestURLs {
            do {
                let data = try boundedData(at: url, maximumBytes: limits.maximumManifestBytes)
                let manifest = try decoder.decode(
                    AtriaHistoricalRetentionTransaction.Manifest.self,
                    from: data
                )
                guard manifest.version == AtriaHistoricalRetentionTransaction.Manifest.currentVersion,
                      safeFilename(manifest.aggregateFilename),
                      manifest.sourceLastTimestamp > manifest.sourceFirstTimestamp,
                      !manifest.sourceChunkID.isEmpty else {
                    rejected += 1
                    continue
                }
                if let cursor {
                    let followsCursor = manifest.sourceLastTimestamp < cursor.sourceLastTimestamp
                        || (manifest.sourceLastTimestamp == cursor.sourceLastTimestamp
                            && manifest.sourceChunkID > cursor.sourceChunkID)
                    guard followsCursor else { continue }
                }
                candidates.append((manifest, url))
                candidates.sort(by: Self.manifestPageOrder)
                if candidates.count > maximumAggregateCount + 1 {
                    candidates.removeLast()
                }
            } catch BoundedReadError.limitExceeded {
                return Page(snapshot: Snapshot(aggregates: [],
                                               diagnostics: .init(committedManifests: manifestURLs.count,
                                                                  acceptedAggregates: 0,
                                                                  rejectedManifests: rejected,
                                                                  limitExceeded: true)),
                            nextCursor: nil,
                            hasMore: false)
            } catch {
                rejected += 1
            }
        }

        let hasMore = candidates.count > maximumAggregateCount
        let selected = Array(candidates.prefix(maximumAggregateCount))
        var accepted: [AtriaHistoricalAggregateChunk] = []
        var totalAggregateBytes: UInt64 = 0
        var limitExceeded = false
        for candidate in selected {
            do {
                let manifest = candidate.manifest
                let aggregateURL = aggregateDirectoryURL.appendingPathComponent(
                    manifest.aggregateFilename
                )
                guard fileManager.fileExists(atPath: aggregateURL.path) else {
                    rejected += 1
                    continue
                }
                let actualBytes = try fileByteCount(at: aggregateURL)
                let (nextTotal, overflow) = totalAggregateBytes.addingReportingOverflow(actualBytes)
                guard !overflow,
                      actualBytes == manifest.aggregateByteCount,
                      actualBytes <= limits.maximumAggregateBytes,
                      nextTotal <= limits.maximumTotalAggregateBytes else {
                    limitExceeded = true
                    break
                }
                let data = try boundedData(at: aggregateURL,
                                           maximumBytes: limits.maximumAggregateBytes)
                guard UInt64(data.count) == actualBytes,
                      AtriaHistoricalRetentionTransaction.sha256(of: data)
                        == manifest.aggregateSHA256 else {
                    rejected += 1
                    continue
                }
                let aggregate = try decoder.decode(AtriaHistoricalAggregateChunk.self, from: data)
                try aggregate.validateForCommit()
                guard aggregate.schema == manifest.aggregateSchema,
                      aggregate.source.chunkID == manifest.sourceChunkID,
                      aggregate.source.rawSHA256 == manifest.sourceSHA256,
                      aggregate.source.rawByteCount == manifest.sourceByteCount,
                      aggregate.source.rawRowCount == manifest.sourceRowCount,
                      aggregate.source.firstTimestamp == manifest.sourceFirstTimestamp,
                      aggregate.source.lastTimestamp == manifest.sourceLastTimestamp,
                      aggregate.heartRateMinutes.count == manifest.heartRateMinuteCount,
                      aggregate.rrEpochs.count == manifest.rrEpochCount,
                      aggregate.motionEpochs.count == manifest.motionEpochCount,
                      AtriaHistoricalAggregateBuilder.semanticParityReceipt(for: aggregate)
                        == manifest.semanticParityReceipt else {
                    rejected += 1
                    continue
                }
                totalAggregateBytes = nextTotal
                accepted.append(aggregate)
            } catch BoundedReadError.limitExceeded {
                limitExceeded = true
                break
            } catch {
                rejected += 1
            }
        }
        accepted.sort {
            if $0.source.lastTimestamp != $1.source.lastTimestamp {
                return $0.source.lastTimestamp > $1.source.lastTimestamp
            }
            return $0.source.chunkID < $1.source.chunkID
        }
        let nextCursor = selected.last.map {
            PageCursor(sourceLastTimestamp: $0.manifest.sourceLastTimestamp,
                       sourceChunkID: $0.manifest.sourceChunkID)
        }
        return Page(snapshot: Snapshot(
            aggregates: accepted,
            diagnostics: .init(committedManifests: manifestURLs.count,
                               acceptedAggregates: accepted.count,
                               rejectedManifests: rejected,
                               limitExceeded: limitExceeded)
        ), nextCursor: nextCursor, hasMore: hasMore && !limitExceeded)
    }

    /// Walks committed aggregates in bounded payload pages and retains only
    /// their small source identifiers. Retention policy needs membership, not
    /// every decoded aggregate resident at once; using `load()` here made a
    /// lifetime byte limit an eventual hard stop for raw retirement.
    func loadCommittedChunkIDs(
        maximumManifestCount: Int = 200_000,
        pageSize: Int = 64
    ) -> ChunkIDSnapshot {
        guard maximumManifestCount > 0, pageSize > 0 else {
            return .init(chunkIDs: [], rejectedManifests: 0, limitExceeded: true)
        }
        let limits = LoadLimits(
            maximumManifestCount: maximumManifestCount,
            maximumManifestBytes: 512 * 1_024,
            maximumAggregateBytes: 64 * 1_024 * 1_024,
            maximumTotalAggregateBytes: 128 * 1_024 * 1_024
        )
        var cursor: PageCursor?
        var identifiers = Set<String>()
        var rejected = 0
        repeat {
            let page = loadPage(after: cursor,
                                maximumAggregateCount: pageSize,
                                limits: limits)
            rejected = max(rejected, page.snapshot.diagnostics.rejectedManifests)
            guard !page.snapshot.diagnostics.limitExceeded else {
                return .init(chunkIDs: identifiers,
                             rejectedManifests: rejected,
                             limitExceeded: true)
            }
            for aggregate in page.snapshot.aggregates {
                guard identifiers.insert(aggregate.source.chunkID).inserted else {
                    return .init(chunkIDs: identifiers,
                                 rejectedManifests: rejected + 1,
                                 limitExceeded: false)
                }
            }
            guard page.hasMore else { break }
            guard let next = page.nextCursor, next != cursor else {
                return .init(chunkIDs: identifiers,
                             rejectedManifests: rejected + 1,
                             limitExceeded: false)
            }
            cursor = next
        } while true
        return .init(chunkIDs: identifiers,
                     rejectedManifests: rejected,
                     limitExceeded: false)
    }

    private static func manifestPageOrder(
        _ lhs: (manifest: AtriaHistoricalRetentionTransaction.Manifest, url: URL),
        _ rhs: (manifest: AtriaHistoricalRetentionTransaction.Manifest, url: URL)
    ) -> Bool {
        if lhs.manifest.sourceLastTimestamp != rhs.manifest.sourceLastTimestamp {
            return lhs.manifest.sourceLastTimestamp > rhs.manifest.sourceLastTimestamp
        }
        return lhs.manifest.sourceChunkID < rhs.manifest.sourceChunkID
    }

    func heartRateChartPoints(snapshot: Snapshot,
                              since: Date,
                              until: Date) -> [HeartRateChartPoint] {
        guard until > since else { return [] }
        // A transaction is one source of truth per chunk. If a migration ever
        // publishes overlapping chunks, de-duplicate exact minute facts using
        // the newest aggregate creation time.
        var byMinute: [Date: (createdAt: Date, minute: AtriaHistoricalAggregateChunk.HeartRateMinute)] = [:]
        for aggregate in snapshot.aggregates {
            for minute in aggregate.heartRateMinutes
                where minute.minuteStart >= since && minute.minuteStart < until && minute.sampleCount > 0 {
                if let existing = byMinute[minute.minuteStart], existing.createdAt > aggregate.createdAt {
                    continue
                }
                byMinute[minute.minuteStart] = (aggregate.createdAt, minute)
            }
        }
        return byMinute.sorted(by: { $0.key < $1.key }).map { _, value in
            .init(minuteStart: value.minute.minuteStart,
                  averageBPM: Double(value.minute.sumBPM) / Double(value.minute.sampleCount),
                  minimumBPM: value.minute.minimumBPM,
                  maximumBPM: value.minute.maximumBPM,
                  sampleCount: value.minute.sampleCount)
        }
    }

    func loadBasis(snapshot: Snapshot,
                   since: Date,
                   until: Date) -> LoadBasis {
        var terminal: [Int: Double] = [:]
        var transitions: [Int: Double] = [:]
        var covered = 0.0
        var dropped = 0.0
        for aggregate in snapshot.aggregates {
            for minute in aggregate.heartRateMinutes
                where minute.minuteStart >= since && minute.minuteStart < until {
                minute.terminalBPMSeconds.forEach { terminal[$0.key, default: 0] += $0.value }
                minute.transitionHalfBPMSeconds.forEach { transitions[$0.key, default: 0] += $0.value }
                covered += minute.coveredSeconds
                dropped += minute.droppedGapSeconds
            }
        }
        return .init(terminalBPMSeconds: terminal,
                     transitionHalfBPMSeconds: transitions,
                     coveredSeconds: covered,
                     droppedGapSeconds: dropped)
    }

    /// Exact only for complete persisted epochs. Arbitrary partial-window
    /// reanalysis after raw expiry is intentionally unsupported.
    func rrStatisticsForCompleteEpochs(snapshot: Snapshot,
                                       since: Date,
                                       until: Date) -> RRStatistics {
        let epochs = snapshot.aggregates.flatMap(\.rrEpochs)
            .filter { $0.start >= since && $0.end <= until }
            .sorted { $0.start < $1.start }
        var beatCount = 0
        var sum: Int64 = 0
        var sumSquares = 0.0
        var diffCount = 0
        var diffSquares = 0.0
        var over50 = 0
        var previous: AtriaHistoricalAggregateChunk.RREpoch?
        for epoch in epochs {
            beatCount += epoch.acceptedBeatCount
            sum += epoch.sumNNMilliseconds
            sumSquares += epoch.sumNNSquaredMilliseconds
            diffCount += epoch.adjacentDifferenceCount
            diffSquares += epoch.sumAdjacentDifferenceSquaredMilliseconds
            over50 += epoch.adjacentDifferenceOver50Count
            if let previous,
               previous.end == epoch.start,
               let lhs = previous.lastNNMilliseconds,
               let rhs = epoch.firstNNMilliseconds {
                let difference = rhs - lhs
                diffCount += 1
                diffSquares += Double(difference * difference)
                if abs(difference) > 50 { over50 += 1 }
            }
            previous = epoch
        }
        return .init(beatCount: beatCount,
                     sumNNMilliseconds: sum,
                     sumNNSquaredMilliseconds: sumSquares,
                     adjacentDifferenceCount: diffCount,
                     sumAdjacentDifferenceSquaredMilliseconds: diffSquares,
                     adjacentDifferenceOver50Count: over50)
    }

    private func safeFilename(_ value: String) -> Bool {
        !value.isEmpty
            && URL(fileURLWithPath: value).lastPathComponent == value
            && value != "."
            && value != ".."
    }

    private enum BoundedReadError: Error {
        case limitExceeded
    }

    private func boundedData(at url: URL, maximumBytes: UInt64) throws -> Data {
        guard maximumBytes > 0,
              maximumBytes < UInt64(Int.max),
              try fileByteCount(at: url) <= maximumBytes else {
            throw BoundedReadError.limitExceeded
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Int(maximumBytes) + 1) ?? Data()
        guard UInt64(data.count) <= maximumBytes else {
            throw BoundedReadError.limitExceeded
        }
        return data
    }

    private func fileByteCount(at url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
