import Foundation

/// Pure projection of decoded historical gravity rows into window-bounded
/// motion features. This layer deliberately does not infer steps, sleep,
/// workouts, or an activity type. Consumers must combine the evidence with
/// independently observed physiology and time context.
enum AtriaRecoveredMotionProjection {
    static let source = "historical_gravity_recovered"

    struct Sample: Equatable, Sendable {
        let timestamp: Date
        let sequence: Int
        let x: Double
        let y: Double
        let z: Double
        /// True only when the row has a clock-corrected or otherwise proven wall
        /// timestamp. A plausible vector at an unproven time cannot establish
        /// motion inside a sleep or activity window.
        let timestampValidated: Bool
        /// Validation attached by the versioned historical decoder. A plausible
        /// vector below is an additional fail-closed check, not a replacement
        /// for this provenance bit.
        let gravityValidated: Bool

        init(timestamp: Date,
             sequence: Int,
             x: Double,
             y: Double,
             z: Double,
             timestampValidated: Bool,
             gravityValidated: Bool) {
            self.timestamp = timestamp
            self.sequence = sequence
            self.x = x
            self.y = y
            self.z = z
            self.timestampValidated = timestampValidated
            self.gravityValidated = gravityValidated
        }
    }

    struct Window: Equatable, Sendable {
        let id: String
        let start: Date
        let end: Date
    }

    struct Configuration: Equatable, Sendable {
        var minimumValidatedRows = 300
        var minimumValidatedFraction = 0.95
        var minimumCoverageSeconds: TimeInterval = 30 * 60
        var maximumGapSeconds: TimeInterval = 5 * 60
        var maximumWindowSeconds: TimeInterval = 12 * 60 * 60
        var stillTransitionThreshold = 0.05
        var lowMotionStillnessRatio = 0.72
        var lowMotionIntensity = 0.18
        var plausibleGravityMagnitude = 0.5...1.5

        static let production = Configuration()
    }

    struct Evidence: Equatable, Sendable {
        let window: Window
        let rows: Int
        let validatedRows: Int
        let rejectedRows: Int
        let coverageSeconds: Int
        /// Includes both edges of the requested window. A dense sample island in
        /// the middle therefore cannot stand in for observation of the window.
        let maximumGapSeconds: Int
        let stillnessRatio: Double?
        let movementIntensity: Double?
        let p95VectorDelta: Double?
        /// Means the bounded vector features are trustworthy enough to consume.
        /// It says nothing about whether the user was asleep or active.
        let measurementValidated: Bool
        /// Narrow compatibility gate for SavedSession.motionEvidenceValidated,
        /// whose current downstream meaning is validated *low motion* for sleep.
        let lowMotionQualified: Bool
        let reason: String

        /// Explicit mapping contract for SavedSession. Insufficient evidence
        /// exports provenance only; it cannot populate classifier features.
        var savedSessionFields: SavedSessionFields {
            guard measurementValidated else {
                return SavedSessionFields(
                    motionEvidenceSource: "\(AtriaRecoveredMotionProjection.source)_insufficient",
                    motionEvidenceValidated: false,
                    imuSampleCount: nil,
                    imuFrameCount: nil,
                    imuStillnessRatio: nil,
                    imuMovementIntensity: nil,
                    imuActivityBursts: nil,
                    imuValidationState: nil,
                    strapStepResearchCount: nil
                )
            }
            return SavedSessionFields(
                motionEvidenceSource: AtriaRecoveredMotionProjection.source,
                motionEvidenceValidated: lowMotionQualified,
                // Historical gravity rows are decoded frames, not the native
                // IMU samples that may have been packed inside each frame.
                imuSampleCount: nil,
                imuFrameCount: validatedRows,
                imuStillnessRatio: stillnessRatio,
                imuMovementIntensity: movementIntensity,
                imuActivityBursts: nil,
                imuValidationState: "historical_gravity_measurement_validated",
                strapStepResearchCount: nil
            )
        }
    }

    /// Field-for-field adapter for the existing SavedSession motion surface.
    /// Synthetic step and burst counts are structurally absent (`nil`).
    struct SavedSessionFields: Equatable, Sendable {
        let motionEvidenceSource: String
        let motionEvidenceValidated: Bool
        let imuSampleCount: Int?
        let imuFrameCount: Int?
        let imuStillnessRatio: Double?
        let imuMovementIntensity: Double?
        let imuActivityBursts: Int?
        let imuValidationState: String?
        let strapStepResearchCount: Int?
    }

    static func project(samples: [Sample],
                        windows: [Window],
                        configuration: Configuration = .production) -> [Evidence] {
        windows.map { project(samples: samples, window: $0, configuration: configuration) }
    }

    /// Produces fixed 30-second, timestamped features for downstream temporal
    /// alignment. Unlike whole-session validation, an epoch needs only enough
    /// dense rows to describe that epoch; missing epochs are retained as
    /// unvalidated records so consumers fail closed across archive holes.
    static func epochFeatures(
        samples: [Sample],
        start: Date,
        end: Date,
        epochDuration: TimeInterval = 30
    ) -> [AtriaRecoveredMotionEpoch] {
        epochFeaturesCancellable(
            samples: samples,
            start: start,
            end: end,
            epochDuration: epochDuration,
            shouldContinue: { true }
        )!
    }

    static func epochFeaturesCancellable(
        samples: [Sample],
        start: Date,
        end: Date,
        epochDuration: TimeInterval = 30,
        shouldContinue: () -> Bool
    ) -> [AtriaRecoveredMotionEpoch]? {
        guard end > start, epochDuration > 0 else { return [] }
        var configuration = Configuration.production
        configuration.minimumValidatedRows = 4
        configuration.minimumCoverageSeconds = min(20, epochDuration * 0.65)
        configuration.maximumGapSeconds = min(12, epochDuration * 0.40)
        configuration.maximumWindowSeconds = max(60, epochDuration)

        guard shouldContinue() else { return nil }
        var ordered = samples
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &ordered,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.sequence < $1.sequence
        }) else { return nil }
        let count = max(1, Int(ceil(end.timeIntervalSince(start) / epochDuration)))
        var lower = 0
        var upper = 0
        var epochs: [AtriaRecoveredMotionEpoch] = []
        epochs.reserveCapacity(count)
        for index in 0..<count {
            if index.isMultiple(of: 64), !shouldContinue() { return nil }
            let epochStart = start.addingTimeInterval(Double(index) * epochDuration)
            let epochEnd = min(end, epochStart.addingTimeInterval(epochDuration))
            while lower < ordered.count && ordered[lower].timestamp < epochStart { lower += 1 }
            upper = max(upper, lower)
            let isFinalEpoch = epochEnd == end
            while upper < ordered.count {
                let timestamp = ordered[upper].timestamp
                guard timestamp < epochEnd || (isFinalEpoch && timestamp == epochEnd) else { break }
                upper += 1
            }
            guard let evidence = projectCancellable(
                samples: Array(ordered[lower..<upper]),
                window: Window(id: "epoch_\(index)", start: epochStart, end: epochEnd),
                configuration: configuration,
                shouldContinue: shouldContinue
            ) else { return nil }
            epochs.append(AtriaRecoveredMotionEpoch(
                start: epochStart,
                end: epochEnd,
                rows: evidence.rows,
                validatedRows: evidence.validatedRows,
                stillnessRatio: evidence.stillnessRatio,
                movementIntensity: evidence.movementIntensity,
                p95VectorDelta: evidence.p95VectorDelta,
                maximumGapSeconds: evidence.maximumGapSeconds,
                measurementValidated: evidence.measurementValidated,
                lowMotionQualified: evidence.lowMotionQualified,
                reason: evidence.reason
            ))
        }
        return shouldContinue() ? epochs : nil
    }

    /// Bounded batch adapter used by the recovered-session projection. Binary
    /// bounds prevent each session from rescanning the full archive snapshot.
    static func epochFeatures(
        samples: [Sample],
        windows: [Window],
        epochDuration: TimeInterval = 30
    ) -> [String: [AtriaRecoveredMotionEpoch]] {
        epochFeaturesCancellable(
            samples: samples,
            windows: windows,
            epochDuration: epochDuration,
            shouldContinue: { true }
        )!
    }

    static func epochFeaturesCancellable(
        samples: [Sample],
        windows: [Window],
        epochDuration: TimeInterval = 30,
        shouldContinue: () -> Bool
    ) -> [String: [AtriaRecoveredMotionEpoch]]? {
        guard shouldContinue() else { return nil }
        var ordered = samples
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &ordered,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.sequence < $1.sequence
        }) else { return nil }
        var result: [String: [AtriaRecoveredMotionEpoch]] = [:]
        result.reserveCapacity(windows.count)
        for (index, window) in windows.enumerated() {
            if index.isMultiple(of: 64), !shouldContinue() { return nil }
            let lower = lowerBound(in: ordered, date: window.start)
            let upper = upperBound(in: ordered, date: window.end, lowerBound: lower)
            guard let features = epochFeaturesCancellable(
                samples: Array(ordered[lower..<upper]),
                start: window.start,
                end: window.end,
                epochDuration: epochDuration,
                shouldContinue: shouldContinue
            ) else { return nil }
            result[window.id] = features
        }
        return shouldContinue() ? result : nil
    }

    static func project(samples: [Sample],
                        window: Window,
                        configuration: Configuration = .production) -> Evidence {
        projectCancellable(
            samples: samples,
            window: window,
            configuration: configuration,
            shouldContinue: { true }
        )!
    }

    static func projectCancellable(
        samples: [Sample],
        window: Window,
        configuration: Configuration = .production,
        shouldContinue: () -> Bool
    ) -> Evidence? {
        let duration = window.end.timeIntervalSince(window.start)
        guard duration > 0, duration.isFinite else {
            return empty(window: window, reason: "invalid_window")
        }
        guard duration <= configuration.maximumWindowSeconds else {
            return empty(window: window, reason: "window_exceeds_bound")
        }

        guard shouldContinue() else { return nil }
        var bounded: [Sample] = []
        bounded.reserveCapacity(samples.count)
        for (index, sample) in samples.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return nil }
                let timestamp = sample.timestamp.timeIntervalSince1970
            if timestamp.isFinite
                    && sample.timestamp >= window.start
                    && sample.timestamp <= window.end {
                bounded.append(sample)
            }
        }
        guard shouldContinue() else { return nil }
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &bounded,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.sequence < $1.sequence
        }) else { return nil }
        guard !bounded.isEmpty else {
            return empty(window: window, reason: "no_timestamp_overlap")
        }

        var validated: [Sample] = []
        validated.reserveCapacity(bounded.count)
        for (index, sample) in bounded.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return nil }
            if isTrustedGravity(sample, configuration: configuration) {
                validated.append(sample)
            }
        }
        let rejected = bounded.count - validated.count
        var timestamps: [Date] = []
        timestamps.reserveCapacity(validated.count)
        for (index, sample) in validated.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return nil }
            timestamps.append(sample.timestamp)
        }
        let coverage = timestamps.count >= 2
            ? max(0, Int((timestamps.last!.timeIntervalSince(timestamps.first!)).rounded()))
            : 0
        let edgeAndInternalGaps = windowGaps(timestamps: timestamps,
                                            start: window.start,
                                            end: window.end)
        let maximumGap = max(0, Int((edgeAndInternalGaps.max() ?? duration).rounded()))

        var deltas: [Double] = []
        deltas.reserveCapacity(max(0, validated.count - 1))
        for (index, pair) in zip(validated, validated.dropFirst()).enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return nil }
            let (previous, current) = pair
            let gap = current.timestamp.timeIntervalSince(previous.timestamp)
            // Never calculate a movement delta across a reconnect-sized hole.
            guard gap >= 0, gap <= configuration.maximumGapSeconds else { continue }
            let dx = current.x - previous.x
            let dy = current.y - previous.y
            let dz = current.z - previous.z
            deltas.append((dx * dx + dy * dy + dz * dz).squareRoot())
        }
        var stillTransitionCount = 0
        var deltaTotal = 0.0
        for (index, delta) in deltas.enumerated() {
            if index.isMultiple(of: 256), !shouldContinue() { return nil }
            deltaTotal += delta
            if delta <= configuration.stillTransitionThreshold {
                stillTransitionCount += 1
            }
        }
        let stillness = deltas.isEmpty
            ? nil
            : Double(stillTransitionCount) / Double(deltas.count)
        guard shouldContinue() else { return nil }
        let intensity = deltas.isEmpty
            ? nil : deltaTotal / Double(deltas.count)
        guard AtriaSleepCooperativeAlgorithms.stableSort(
            &deltas,
            shouldContinue: shouldContinue,
            areInIncreasingOrder: <
        ) else { return nil }
        let p95: Double? = deltas.isEmpty ? nil : deltas[
            Int((Double(deltas.count - 1) * 0.95).rounded(.down))
        ]
        let validatedFraction = Double(validated.count) / Double(bounded.count)

        let reason: String
        let measurementValidated: Bool
        if validated.count < configuration.minimumValidatedRows {
            reason = "insufficient_validated_rows"
            measurementValidated = false
        } else if validatedFraction < configuration.minimumValidatedFraction {
            reason = "unvalidated_row_fraction"
            measurementValidated = false
        } else if Double(coverage) < configuration.minimumCoverageSeconds {
            reason = "insufficient_coverage"
            measurementValidated = false
        } else if Double(maximumGap) > configuration.maximumGapSeconds {
            reason = "window_or_internal_gap"
            measurementValidated = false
        } else if deltas.isEmpty {
            reason = "insufficient_contiguous_transitions"
            measurementValidated = false
        } else {
            reason = "bounded_historical_gravity_validated"
            measurementValidated = true
        }

        let lowMotion = measurementValidated
            && (stillness ?? 0) >= configuration.lowMotionStillnessRatio
            && (intensity ?? .infinity) <= configuration.lowMotionIntensity
        guard shouldContinue() else { return nil }
        return Evidence(window: window,
                        rows: bounded.count,
                        validatedRows: validated.count,
                        rejectedRows: rejected,
                        coverageSeconds: coverage,
                        maximumGapSeconds: maximumGap,
                        stillnessRatio: stillness,
                        movementIntensity: intensity,
                        p95VectorDelta: p95,
                        measurementValidated: measurementValidated,
                        lowMotionQualified: lowMotion,
                        reason: reason)
    }

    private static func isTrustedGravity(_ sample: Sample,
                                         configuration: Configuration) -> Bool {
        guard sample.timestampValidated,
              sample.gravityValidated,
              sample.x.isFinite,
              sample.y.isFinite,
              sample.z.isFinite else { return false }
        let magnitude = (sample.x * sample.x + sample.y * sample.y + sample.z * sample.z).squareRoot()
        return magnitude.isFinite && configuration.plausibleGravityMagnitude.contains(magnitude)
    }

    private static func lowerBound(in samples: [Sample], date: Date) -> Int {
        var low = 0
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].timestamp < date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func upperBound(in samples: [Sample], date: Date, lowerBound: Int) -> Int {
        var low = lowerBound
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].timestamp <= date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func windowGaps(timestamps: [Date], start: Date, end: Date) -> [TimeInterval] {
        guard let first = timestamps.first, let last = timestamps.last else {
            return [end.timeIntervalSince(start)]
        }
        var gaps = [max(0, first.timeIntervalSince(start))]
        gaps.append(contentsOf: zip(timestamps, timestamps.dropFirst()).map {
            max(0, $1.timeIntervalSince($0))
        })
        gaps.append(max(0, end.timeIntervalSince(last)))
        return gaps
    }

    private static func empty(window: Window, reason: String) -> Evidence {
        Evidence(window: window,
                 rows: 0,
                 validatedRows: 0,
                 rejectedRows: 0,
                 coverageSeconds: 0,
                 maximumGapSeconds: max(0, Int(window.end.timeIntervalSince(window.start).rounded())),
                 stillnessRatio: nil,
                 movementIntensity: nil,
                 p95VectorDelta: nil,
                 measurementValidated: false,
                 lowMotionQualified: false,
                 reason: reason)
    }
}
