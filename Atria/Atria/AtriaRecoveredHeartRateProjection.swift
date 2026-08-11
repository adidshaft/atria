import Foundation
import CryptoKit

/// A deterministic, side-effect-free bridge between validated archive heart
/// rate and the session analytics pipeline.
///
/// The projection deliberately does not resample. Every emitted value is one
/// of the caller's exact historical or live samples. Live data wins when both
/// sources contain the same timestamp, and large holes become separate windows
/// rather than synthetic heart-rate points.
enum AtriaRecoveredHeartRateProjection {
    enum Source: String, Equatable, Sendable {
        case historicalArchive
        case live
    }

    struct Configuration: Equatable, Sendable {
        /// A strictly larger adjacent-sample interval starts a new window.
        let maximumGap: TimeInterval
        /// The cadence used only to calculate coverage. It never creates data.
        let expectedSampleInterval: TimeInterval

        init(maximumGap: TimeInterval,
             expectedSampleInterval: TimeInterval) {
            precondition(maximumGap > 0 && maximumGap.isFinite,
                         "maximumGap must be finite and greater than zero")
            precondition(expectedSampleInterval > 0 && expectedSampleInterval.isFinite,
                         "expectedSampleInterval must be finite and greater than zero")
            self.maximumGap = maximumGap
            self.expectedSampleInterval = expectedSampleInterval
        }
    }

    struct Sample: Equatable, Sendable {
        /// Timestamp-only identity. Replacing an archive value with a live value
        /// cannot create a second logical sample during an idempotent replay.
        let stableKey: String
        let timestamp: Date
        let bpm: Int
        let source: Source
    }

    struct Coverage: Equatable, Sendable {
        let sampleCount: Int
        let historicalSampleCount: Int
        let liveSampleCount: Int
        let firstTimestamp: Date?
        let lastTimestamp: Date?
        let timelineSpanSeconds: TimeInterval
        /// Observed duration supported by adjacent points at the configured
        /// cadence. Intervals across a split gap contribute zero.
        let coveredSeconds: TimeInterval
        let uncoveredSeconds: TimeInterval
        /// Nil for an empty or single-point timeline, where duration coverage
        /// is undefined rather than optimistically reported as 100 percent.
        let coverageFraction: Double?
        let maximumObservedGapSeconds: TimeInterval?
        let splitGapCount: Int
    }

    struct Window: Equatable, Sendable, Identifiable {
        /// Deterministic across ordering, archive replays, and live replacement.
        let id: String
        let samples: [Sample]
        let coverage: Coverage

        var start: Date { samples[0].timestamp }
        var end: Date { samples[samples.count - 1].timestamp }
    }

    struct Statistics: Equatable, Sendable {
        let historicalInputCount: Int
        let liveInputCount: Int
        let invalidTimestampCount: Int
        /// All valid input rows removed because another row had the same exact
        /// timestamp, including historical replays and live overlap.
        let duplicateTimestampCount: Int
        /// Unique timestamps present in both inputs. The emitted value for each
        /// of these timestamps is guaranteed to come from the live input.
        let liveOverrideCount: Int
        let coverage: Coverage
    }

    struct Result: Equatable, Sendable {
        let windows: [Window]
        let statistics: Statistics

        var samples: [Sample] { windows.flatMap(\.samples) }
    }

    /// Converts only recovered archive samples into analytics sessions. Live
    /// samples participate in overlap resolution above, but are intentionally
    /// omitted here because their original SavedSession already owns them.
    /// The archive remains the durable source of truth; these sessions are an
    /// in-memory projection and must never be written to sessions.json.
    static func recoveredSessions(
        from result: Result,
        maximumGap: TimeInterval,
        recoveredRRBeats: [AtriaRecoveredRRProjection.Beat] = [],
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) -> [SavedSession] {
        recoveredSessionsCancellable(
            from: result,
            maximumGap: maximumGap,
            recoveredRRBeats: recoveredRRBeats,
            timeZoneIdentifier: timeZoneIdentifier,
            shouldContinue: { true }
        )!
    }

    static func recoveredSessionsCancellable(
        from result: Result,
        maximumGap: TimeInterval,
        recoveredRRBeats: [AtriaRecoveredRRProjection.Beat] = [],
        timeZoneIdentifier: String = TimeZone.current.identifier,
        shouldContinue: () -> Bool
    ) -> [SavedSession]? {
        precondition(maximumGap > 0 && maximumGap.isFinite)
        guard shouldContinue() else { return nil }
        var groups: [[Sample]] = []
        var current: [Sample] = []
        var sampleVisitCount = 0
        for window in result.windows {
            for sample in window.samples where sample.source == .historicalArchive {
                sampleVisitCount += 1
                if sampleVisitCount.isMultiple(of: 256), !shouldContinue() {
                    return nil
                }
                if let previous = current.last,
                   sample.timestamp.timeIntervalSince(previous.timestamp) > maximumGap {
                    groups.append(current)
                    current = []
                }
                current.append(sample)
            }
        }
        if !current.isEmpty { groups.append(current) }
        guard shouldContinue() else { return nil }
        guard !groups.isEmpty else { return [] }

        var rrBeatsByGroup = Array(repeating: [AtriaRecoveredRRProjection.Beat](),
                                   count: groups.count)
        guard shouldContinue() else { return nil }
        var orderedRRBeats = recoveredRRBeats
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &orderedRRBeats,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: { $0.timestamp < $1.timestamp }
        ) else { return nil }
        for (beatIndex, beat) in orderedRRBeats.enumerated() {
            if beatIndex.isMultiple(of: 256), !shouldContinue() {
                return nil
            }
            func distance(to index: Int) -> TimeInterval {
                let samples = groups[index]
                let first = samples[0].timestamp
                let last = samples[samples.count - 1].timestamp
                if beat.timestamp < first {
                    return first.timeIntervalSince(beat.timestamp)
                }
                if beat.timestamp > last {
                    return beat.timestamp.timeIntervalSince(last)
                }
                return 0
            }

            // First group whose end is not before the beat. Only it and the
            // preceding group can be nearest on this ordered timeline.
            var lower = 0
            var upper = groups.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if groups[middle].last!.timestamp < beat.timestamp {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            let candidateIndices = [lower - 1, lower].filter { groups.indices.contains($0) }
            guard let nearestIndex = candidateIndices.min(by: { lhs, rhs in
                let lhsDistance = distance(to: lhs)
                let rhsDistance = distance(to: rhs)
                return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
            }), distance(to: nearestIndex) <= maximumGap else { continue }
            rrBeatsByGroup[nearestIndex].append(beat)
        }

        var sessions: [SavedSession] = []
        sessions.reserveCapacity(groups.count)
        for (groupIndex, samples) in groups.enumerated() {
            guard shouldContinue() else { return nil }
            let heartRateStart = samples[0].timestamp
            let heartRateEnd = samples[samples.count - 1].timestamp
            // An R24 record's beat intervals end at or immediately before its
            // HR timestamp. Keep that exact leading evidence without bridging
            // a projection-sized discontinuity.
            let rrBeats = rrBeatsByGroup[groupIndex]
            let start = min(heartRateStart, rrBeats.first?.timestamp ?? heartRateStart)
            let end = max(heartRateEnd, rrBeats.last?.timestamp ?? heartRateEnd)
            var maximumObservedGap: TimeInterval = 0
            for (index, pair) in zip(samples, samples.dropFirst()).enumerated() {
                if index.isMultiple(of: 256), !shouldContinue() {
                    return nil
                }
                maximumObservedGap = max(
                    maximumObservedGap,
                    pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
                )
            }
            var points: [SavedSession.Point] = []
            points.reserveCapacity(samples.count)
            for (index, sample) in samples.enumerated() {
                if index.isMultiple(of: 256), !shouldContinue() {
                    return nil
                }
                points.append(.init(
                    t: max(0, sample.timestamp.timeIntervalSince(start)),
                    bpm: sample.bpm
                ))
            }
            var rrPoints: [SavedSession.RRPoint] = []
            rrPoints.reserveCapacity(rrBeats.count)
            for (index, beat) in rrBeats.enumerated() {
                if index.isMultiple(of: 256), !shouldContinue() {
                    return nil
                }
                rrPoints.append(.init(
                    t: max(0, beat.timestamp.timeIntervalSince(start)),
                    ms: beat.intervalMilliseconds,
                    source: .verifiedWhoop4HistoricalV24
                ))
            }
            sessions.append(SavedSession(
                id: stableSessionID(firstSampleKey: samples[0].stableKey),
                start: start,
                end: end,
                label: "Recovered strap HR",
                points: points,
                hrv: nil,
                rrPoints: rrPoints.isEmpty ? nil : rrPoints,
                hrvReferenceValidated: false,
                hrAccepted: samples.count,
                hrAcceptedGaps: 0,
                hrMaxAcceptedGap: maximumObservedGap,
                eventTimeZoneIdentifier: timeZoneIdentifier
            ))
        }
        return shouldContinue() ? sessions : nil
    }

    static func project(
        historical: [HistoricalArchive.HeartRatePoint],
        live: [HistoricalArchive.HeartRatePoint] = [],
        configuration: Configuration
    ) -> Result {
        projectCancellable(
            historical: historical,
            live: live,
            configuration: configuration,
            shouldContinue: { true }
        )!
    }

    static func projectCancellable(
        historical: [HistoricalArchive.HeartRatePoint],
        live: [HistoricalArchive.HeartRatePoint] = [],
        configuration: Configuration,
        shouldContinue: () -> Bool
    ) -> Result? {
        struct Candidate {
            let point: HistoricalArchive.HeartRatePoint
            let source: Source
        }

        var selectedByTimestamp: [Date: Candidate] = [:]
        var validInputCount = 0
        var invalidTimestampCount = 0
        var liveOverrideCount = 0

        func consume(_ point: HistoricalArchive.HeartRatePoint, source: Source) {
            let seconds = point.t.timeIntervalSince1970
            guard seconds.isFinite else {
                invalidTimestampCount += 1
                return
            }

            validInputCount += 1
            guard let existing = selectedByTimestamp[point.t] else {
                selectedByTimestamp[point.t] = Candidate(point: point, source: source)
                return
            }

            // Source precedence is explicit. Within one source, the BPM
            // tie-break makes the result independent of replay/input ordering;
            // the selected BPM still came from an actual supplied sample.
            let shouldReplace = sourceRank(source) > sourceRank(existing.source)
                || (source == existing.source && point.bpm > existing.point.bpm)
            if shouldReplace {
                if source == .live, existing.source == .historicalArchive {
                    liveOverrideCount += 1
                }
                selectedByTimestamp[point.t] = Candidate(point: point, source: source)
            }
        }

        for (index, point) in historical.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return nil }
            consume(point, source: .historicalArchive)
        }
        for (index, point) in live.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return nil }
            consume(point, source: .live)
        }

        guard shouldContinue() else { return nil }
        var orderedCandidates = Array(selectedByTimestamp.values)
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &orderedCandidates,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: { $0.point.t < $1.point.t }
        ) else { return nil }
        var samples: [Sample] = []
        samples.reserveCapacity(orderedCandidates.count)
        for (index, candidate) in orderedCandidates.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return nil }
            samples.append(Sample(
                stableKey: sampleKey(for: candidate.point.t),
                timestamp: candidate.point.t,
                bpm: candidate.point.bpm,
                source: candidate.source
            ))
        }

        var grouped: [[Sample]] = []
        var current: [Sample] = []
        for (index, sample) in samples.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return nil }
            if let previous = current.last,
               sample.timestamp.timeIntervalSince(previous.timestamp) > configuration.maximumGap {
                grouped.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty {
            grouped.append(current)
        }

        var windows: [Window] = []
        windows.reserveCapacity(grouped.count)
        for windowSamples in grouped {
            guard let windowCoverage = coverage(
                for: windowSamples,
                configuration: configuration,
                shouldContinue: shouldContinue
            ) else { return nil }
            windows.append(Window(
                id: windowKey(for: windowSamples),
                samples: windowSamples,
                coverage: windowCoverage
            ))
        }
        guard let overallCoverage = coverage(
            for: samples,
            configuration: configuration,
            shouldContinue: shouldContinue
        ) else { return nil }
        let statistics = Statistics(
            historicalInputCount: historical.count,
            liveInputCount: live.count,
            invalidTimestampCount: invalidTimestampCount,
            duplicateTimestampCount: validInputCount - samples.count,
            liveOverrideCount: liveOverrideCount,
            coverage: overallCoverage
        )
        return Result(windows: windows, statistics: statistics)
    }

    private static func sourceRank(_ source: Source) -> Int {
        switch source {
        case .historicalArchive: return 0
        case .live: return 1
        }
    }

    private static func coverage(
        for samples: [Sample],
        configuration: Configuration,
        shouldContinue: () -> Bool
    ) -> Coverage? {
        var historicalCount = 0
        for (index, sample) in samples.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return nil }
            if sample.source == .historicalArchive { historicalCount += 1 }
        }
        let liveCount = samples.count - historicalCount
        guard let first = samples.first?.timestamp,
              let last = samples.last?.timestamp else {
            return Coverage(sampleCount: 0,
                            historicalSampleCount: 0,
                            liveSampleCount: 0,
                            firstTimestamp: nil,
                            lastTimestamp: nil,
                            timelineSpanSeconds: 0,
                            coveredSeconds: 0,
                            uncoveredSeconds: 0,
                            coverageFraction: nil,
                            maximumObservedGapSeconds: nil,
                            splitGapCount: 0)
        }

        var covered: TimeInterval = 0
        var maximumGap: TimeInterval?
        var splitGaps = 0
        for (index, pair) in zip(samples, samples.dropFirst()).enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return nil }
            let delta = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            maximumGap = max(maximumGap ?? delta, delta)
            if delta > configuration.maximumGap {
                splitGaps += 1
            } else {
                covered += min(delta, configuration.expectedSampleInterval)
            }
        }

        let span = max(0, last.timeIntervalSince(first))
        let boundedCovered = min(span, max(0, covered))
        guard shouldContinue() else { return nil }
        return Coverage(
            sampleCount: samples.count,
            historicalSampleCount: historicalCount,
            liveSampleCount: liveCount,
            firstTimestamp: first,
            lastTimestamp: last,
            timelineSpanSeconds: span,
            coveredSeconds: boundedCovered,
            uncoveredSeconds: max(0, span - boundedCovered),
            coverageFraction: span > 0 ? boundedCovered / span : nil,
            maximumObservedGapSeconds: maximumGap,
            splitGapCount: splitGaps
        )
    }

    private static func sampleKey(for timestamp: Date) -> String {
        let seconds = timestamp.timeIntervalSince1970
        // Canonicalize negative zero so Date equality and stable identity agree.
        let bits = seconds == 0 ? UInt64(0) : seconds.bitPattern
        let hex = String(bits, radix: 16, uppercase: false)
        return "recovered-hr-sample-v1-" + String(repeating: "0", count: 16 - hex.count) + hex
    }

    private static func windowKey(for samples: [Sample]) -> String {
        precondition(!samples.isEmpty)
        return [
            "recovered-hr-window-v1",
            sampleKey(for: samples[0].timestamp),
            sampleKey(for: samples[samples.count - 1].timestamp),
            String(samples.count),
        ].joined(separator: ":")
    }

    private static func stableSessionID(firstSampleKey: String) -> UUID {
        let digest = SHA256.hash(data: Data(firstSampleKey.utf8))
        var bytes = Array(digest.prefix(16))
        // RFC 4122 variant + name-derived version bits keep the value a normal
        // UUID while remaining deterministic across replay and app restart.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                          bytes[4], bytes[5], bytes[6], bytes[7],
                          bytes[8], bytes[9], bytes[10], bytes[11],
                          bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
