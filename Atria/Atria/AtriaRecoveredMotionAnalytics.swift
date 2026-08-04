import Foundation

/// Timestamped, bounded motion evidence projected from validated historical
/// gravity rows. Persisting epoch features (rather than raw frames) keeps the
/// session archive compact while preserving the temporal alignment required by
/// sleep staging and activity review.
struct AtriaRecoveredMotionEpoch: Codable, Equatable, Sendable {
    static let source = "historical_gravity_recovered_epoch_v1"

    let start: Date
    let end: Date
    let rows: Int
    let validatedRows: Int
    let stillnessRatio: Double?
    let movementIntensity: Double?
    let p95VectorDelta: Double?
    let maximumGapSeconds: Int
    let measurementValidated: Bool
    let lowMotionQualified: Bool
    let reason: String
}

enum AtriaRecoveredMotionAnalytics {
    struct SleepProvenance: Equatable, Sendable {
        let hasRecoveredEpochs: Bool
        let measurementSufficient: Bool
        let lowMotionValidated: Bool
        let validatedCoverageFraction: Double
        let lowMotionCoverageFraction: Double
        let meanMovementIntensity: Double?
        let maximumGapSeconds: TimeInterval
        let source: String
    }

    struct TimedHeartRate: Equatable, Sendable {
        let timestamp: Date
        let bpm: Int
    }

    struct ActivityAssessment: Equatable, Sendable {
        let hasRecoveredEpochs: Bool
        let evidenceSufficient: Bool
        let activitySupported: Bool
        let suggestedActivityType: AtriaWorkoutActivityType?
        let validatedMotionCoverageFraction: Double
        let alignedActiveFraction: Double
        let reason: String
    }

    /// Seconds inside [start, end] covered by SUSTAINED wake movement:
    /// consecutive measurement-validated epochs that are NOT low-motion
    /// qualified, merged into blocks, counting only blocks at least
    /// `minimumBlock` long. Brief stirring (rollovers) stays below the floor
    /// and is never deducted; unvalidated epochs are never trusted either way.
    ///
    /// 2026-08-04 (user-caught defect): a recovered candidate spanning
    /// 11:33PM–8:59AM reported duration == span while the drained archive
    /// showed 110–596mg wrist movement (vs ≤6mg sleep-still) through a
    /// ~40-minute awake stretch. Candidate duration must exclude detectable
    /// wake; this helper is the measurement.
    static func sustainedAwakeSeconds(
        epochs: [AtriaRecoveredMotionEpoch],
        start: Date,
        end: Date,
        minimumBlock: TimeInterval = 10 * 60
    ) -> TimeInterval {
        let wakeEpochs = overlappingEpochs(epochs, start: start, end: end)
            .filter { $0.measurementValidated && !$0.lowMotionQualified }
            .sorted { $0.start < $1.start }
        guard !wakeEpochs.isEmpty else { return 0 }
        var total: TimeInterval = 0
        var blockStart = max(wakeEpochs[0].start, start)
        var blockEnd = min(wakeEpochs[0].end, end)
        func closeBlock() {
            let length = blockEnd.timeIntervalSince(blockStart)
            if length >= minimumBlock { total += length }
        }
        for epoch in wakeEpochs.dropFirst() {
            let s = max(epoch.start, start)
            let e = min(epoch.end, end)
            // Allow tiny seams between adjacent epochs (epoch emission is
            // windowed); anything larger separates two distinct blocks.
            if s.timeIntervalSince(blockEnd) <= 60 {
                blockEnd = max(blockEnd, e)
            } else {
                closeBlock()
                blockStart = s
                blockEnd = e
            }
        }
        closeBlock()
        return total
    }

    static func savedSessionFields(
        epochs: [AtriaRecoveredMotionEpoch],
        start: Date,
        end: Date
    ) -> AtriaRecoveredMotionProjection.SavedSessionFields {
        let bounded = overlappingEpochs(epochs, start: start, end: end)
        let validated = bounded.filter(\.measurementValidated)
        let duration = max(0, end.timeIntervalSince(start))
        let coverage = duration > 0
            ? coveredDuration(validated, start: start, end: end) / duration
            : 0
        let gap = maximumUncoveredGap(validated, start: start, end: end)
        let stillness = validated.compactMap(\.stillnessRatio)
        let intensity = validated.compactMap(\.movementIntensity)
        let measurementSufficient = duration >= 10 * 60
            && coverage >= 0.80
            && gap <= 90
            && !stillness.isEmpty
            && !intensity.isEmpty
        guard measurementSufficient else {
            return .init(motionEvidenceSource: "\(AtriaRecoveredMotionEpoch.source)_insufficient",
                         motionEvidenceValidated: false,
                         imuSampleCount: nil,
                         imuFrameCount: nil,
                         imuStillnessRatio: nil,
                         imuMovementIntensity: nil,
                         imuActivityBursts: nil,
                         imuValidationState: nil,
                         strapStepResearchCount: nil)
        }
        let meanStillness = stillness.reduce(0, +) / Double(stillness.count)
        let meanIntensity = intensity.reduce(0, +) / Double(intensity.count)
        let lowMotion = duration >= 20 * 60
            && meanStillness >= 0.72
            && meanIntensity <= 0.18
        let rows = validated.reduce(0) { $0 + $1.validatedRows }
        return .init(motionEvidenceSource: AtriaRecoveredMotionEpoch.source,
                     motionEvidenceValidated: lowMotion,
                     imuSampleCount: nil,
                     imuFrameCount: rows,
                     imuStillnessRatio: meanStillness,
                     imuMovementIntensity: meanIntensity,
                     imuActivityBursts: nil,
                     imuValidationState: "historical_gravity_epoch_measurement_validated",
                     strapStepResearchCount: nil)
    }

    static func sleepProvenance(
        epochs: [AtriaRecoveredMotionEpoch],
        start: Date,
        end: Date
    ) -> SleepProvenance {
        let bounded = overlappingEpochs(epochs, start: start, end: end)
        guard end > start, !bounded.isEmpty else {
            return SleepProvenance(hasRecoveredEpochs: false,
                                   measurementSufficient: false,
                                   lowMotionValidated: false,
                                   validatedCoverageFraction: 0,
                                   lowMotionCoverageFraction: 0,
                                   meanMovementIntensity: nil,
                                   maximumGapSeconds: max(0, end.timeIntervalSince(start)),
                                   source: "\(AtriaRecoveredMotionEpoch.source)_missing")
        }

        let duration = end.timeIntervalSince(start)
        let validated = bounded.filter(\.measurementValidated)
        let validatedCoverage = coveredDuration(validated, start: start, end: end)
        let lowMotionCoverage = coveredDuration(validated.filter(\.lowMotionQualified),
                                                start: start,
                                                end: end)
        let validatedFraction = min(1, validatedCoverage / duration)
        let lowMotionFraction = validatedCoverage > 0
            ? min(1, lowMotionCoverage / validatedCoverage)
            : 0
        let maximumGap = maximumUncoveredGap(validated, start: start, end: end)
        let intensities = validated.compactMap(\.movementIntensity)
        let meanIntensity = intensities.isEmpty
            ? nil
            : intensities.reduce(0, +) / Double(intensities.count)
        let sufficient = duration >= 20 * 60
            && validatedFraction >= 0.80
            && maximumGap <= 90
            && !intensities.isEmpty
        let lowMotion = sufficient
            && lowMotionFraction >= 0.72
            && (meanIntensity ?? .infinity) <= 0.18
        return SleepProvenance(
            hasRecoveredEpochs: true,
            measurementSufficient: sufficient,
            lowMotionValidated: lowMotion,
            validatedCoverageFraction: validatedFraction,
            lowMotionCoverageFraction: lowMotionFraction,
            meanMovementIntensity: meanIntensity,
            maximumGapSeconds: maximumGap,
            source: sufficient
                ? AtriaRecoveredMotionEpoch.source
                : "\(AtriaRecoveredMotionEpoch.source)_insufficient"
        )
    }

    /// Produces a review-only historical activity assessment. Gravity plus HR
    /// can support that a cardiovascular movement window occurred; it cannot
    /// identify the activity without validated cadence/gyro/route context, so
    /// the user-visible type remains nil.
    static func activityAssessment(
        heartRate: [TimedHeartRate],
        epochs: [AtriaRecoveredMotionEpoch],
        start: Date,
        end: Date,
        restingHR: Int
    ) -> ActivityAssessment {
        let bounded = overlappingEpochs(epochs, start: start, end: end)
        guard end > start, !bounded.isEmpty else {
            return ActivityAssessment(hasRecoveredEpochs: false,
                                      evidenceSufficient: false,
                                      activitySupported: false,
                                      suggestedActivityType: nil,
                                      validatedMotionCoverageFraction: 0,
                                      alignedActiveFraction: 0,
                                      reason: "no_recovered_motion_epochs")
        }
        let duration = end.timeIntervalSince(start)
        let validated = bounded.filter(\.measurementValidated)
        let motionCoverage = min(1, coveredDuration(validated, start: start, end: end) / duration)
        let motionGap = maximumUncoveredGap(validated, start: start, end: end)
        let validHeartRate = heartRate
            .filter { $0.timestamp >= start && $0.timestamp <= end && (25...240).contains($0.bpm) }
            .sorted { $0.timestamp < $1.timestamp }
        let hrCoverage = heartRateCoverageFraction(validHeartRate, start: start, end: end)
        let sufficient = duration >= 10 * 60
            && validated.count >= 16
            && motionCoverage >= 0.80
            && motionGap <= 90
            && hrCoverage >= 0.80
        guard sufficient else {
            return ActivityAssessment(hasRecoveredEpochs: true,
                                      evidenceSufficient: false,
                                      activitySupported: false,
                                      suggestedActivityType: nil,
                                      validatedMotionCoverageFraction: motionCoverage,
                                      alignedActiveFraction: 0,
                                      reason: "insufficient_time_aligned_motion_or_hr")
        }

        let active = validated.filter { epoch in
            (epoch.movementIntensity ?? 0) >= 0.08
                || (epoch.stillnessRatio ?? 1) <= 0.65
        }
        let alignedActive = active.filter { epoch in
            let values = validHeartRate
                .filter { $0.timestamp >= epoch.start && $0.timestamp <= epoch.end }
                .map(\.bpm)
            guard !values.isEmpty else { return false }
            return Double(values.reduce(0, +)) / Double(values.count) >= Double(restingHR + 15)
        }
        let alignedFraction = Double(alignedActive.count) / Double(max(1, validated.count))
        guard alignedFraction >= 0.60 else {
            return ActivityAssessment(hasRecoveredEpochs: true,
                                      evidenceSufficient: true,
                                      activitySupported: false,
                                      suggestedActivityType: nil,
                                      validatedMotionCoverageFraction: motionCoverage,
                                      alignedActiveFraction: alignedFraction,
                                      reason: "motion_not_aligned_with_elevated_hr")
        }

        return ActivityAssessment(hasRecoveredEpochs: true,
                                  evidenceSufficient: true,
                                  activitySupported: true,
                                  suggestedActivityType: nil,
                                  validatedMotionCoverageFraction: motionCoverage,
                                  alignedActiveFraction: alignedFraction,
                                  reason: "validated_recovered_motion_hr_alignment")
    }

    private static func overlappingEpochs(
        _ epochs: [AtriaRecoveredMotionEpoch],
        start: Date,
        end: Date
    ) -> [AtriaRecoveredMotionEpoch] {
        epochs
            .filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
    }

    private static func coveredDuration(
        _ epochs: [AtriaRecoveredMotionEpoch],
        start: Date,
        end: Date
    ) -> TimeInterval {
        let intervals = epochs.compactMap { epoch -> (Date, Date)? in
            let lower = max(start, epoch.start)
            let upper = min(end, epoch.end)
            return upper > lower ? (lower, upper) : nil
        }
        guard var current = intervals.first else { return 0 }
        var total: TimeInterval = 0
        for interval in intervals.dropFirst() {
            if interval.0 <= current.1 {
                current.1 = max(current.1, interval.1)
            } else {
                total += current.1.timeIntervalSince(current.0)
                current = interval
            }
        }
        return total + current.1.timeIntervalSince(current.0)
    }

    private static func maximumUncoveredGap(
        _ epochs: [AtriaRecoveredMotionEpoch],
        start: Date,
        end: Date
    ) -> TimeInterval {
        guard !epochs.isEmpty else { return max(0, end.timeIntervalSince(start)) }
        var cursor = start
        var maximum: TimeInterval = 0
        for epoch in epochs {
            let lower = max(start, epoch.start)
            let upper = min(end, epoch.end)
            guard upper > lower else { continue }
            maximum = max(maximum, lower.timeIntervalSince(cursor))
            cursor = max(cursor, upper)
        }
        return max(maximum, end.timeIntervalSince(cursor))
    }

    private static func heartRateCoverageFraction(
        _ heartRate: [TimedHeartRate],
        start: Date,
        end: Date
    ) -> Double {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return 0 }
        let binSeconds: TimeInterval = 30
        let expected = max(1, Int(ceil(duration / binSeconds)))
        let bins = Set(heartRate.map {
            max(0, min(expected - 1,
                       Int($0.timestamp.timeIntervalSince(start) / binSeconds)))
        })
        return min(1, Double(bins.count) / Double(expected))
    }
}
