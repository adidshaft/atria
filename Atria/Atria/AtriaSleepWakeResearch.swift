import Foundation

enum AtriaSleepWakeResearch {
    struct Result: Equatable {
        let state: String
        let confidence: String
        let reason: String
    }

    struct HeartSample: Equatable {
        let t: Date
        let bpm: Int
    }

    /// Test-visible accounting for the sparse-data fallback. `sampleVisits`
    /// counts values consumed by the fallback's statistics, making its
    /// range-bounded work shape verifiable without timing-sensitive tests.
    struct FallbackStageDiagnostics: Equatable {
        let segments: [SleepStageSegment]
        let sampleVisits: Int
    }

    private struct EpochFeature: Equatable {
        let start: Date
        let end: Date
        let averageHR: Double
        let shortSmoothHR: Double
        let longSmoothHR: Double
        let differenceOfGaussians: Double
        let localVariability: Double
        let progress: Double
        let motionStillnessPrior: Double
        let motionMovementIntensity: Double
        let motionMeasurementValidated: Bool
    }

    static func classify(duration: TimeInterval,
                         averageHR: Int,
                         restingHR: Int,
                         imuStillnessRatio: Double?,
                         imuMovementIntensity: Double?,
                         strapSteps: Int?,
                         /// A zero step count is useful only after at least one
                         /// strap-motion frame established that the step channel
                         /// was actually observed.  `nil`/false is not zero.
                         strapStepEvidenceAvailable: Bool = false,
                         windowStart: Date? = nil,
                         hrStandardDeviation: Double? = nil,
                         calendar: Calendar = .current) -> Result {
        guard duration >= 20 * 60 else {
            return Result(state: "learning", confidence: "none", reason: "short_window")
        }
        guard let imuStillnessRatio, let imuMovementIntensity else {
            if duration >= 3 * 60 * 60,
               averageHR <= restingHR + 12,
               (hrStandardDeviation ?? .infinity) <= 9,
               let windowStart,
               hrOnlySleepStartReady(windowStart, calendar: calendar) {
                return Result(state: "sleep_research", confidence: "hr_only", reason: "hr_pattern_no_imu")
            }
            return Result(state: "learning", confidence: "none", reason: "imu_missing")
        }
        let lowMotion = imuStillnessRatio >= 0.72 && imuMovementIntensity <= 0.18
        let lowHR = averageHR <= restingHR + 18
        // Do not turn an absent R10 step channel into a measured zero.  That
        // previously let a quiet-looking HR/IMU interval from active wear
        // become `sleep_research`, which can surface as a false nap and can
        // suppress normal activity accounting.  Overnight HR-only handling is
        // deliberately separate above; this is the motion-backed path and
        // requires its independent strap-step evidence.
        guard strapStepEvidenceAvailable, let strapSteps else {
            return Result(state: "learning", confidence: "none", reason: "strap_steps_missing")
        }
        let lowSteps = strapSteps <= max(8, Int(duration / 600))
        if lowMotion && lowHR && lowSteps {
            return Result(state: "sleep_research", confidence: "research", reason: "low_motion_low_hr")
        }
        return Result(state: "wake_research", confidence: "research", reason: "motion_or_hr_active")
    }

    private static func hrOnlySleepStartReady(_ start: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: start)
        return hour >= 20 || hour <= 3
    }

    static func stageSegments(samples: [HeartSample],
                              start: Date,
                              end: Date,
                              restingHR: Int,
                              isNap: Bool,
                              motionValidated: Bool,
                              motionEpochs: [AtriaRecoveredMotionEpoch] = []) -> [SleepStageSegment] {
        let duration = end.timeIntervalSince(start)
        guard duration >= 20 * 60,
              restingHR > 0 else { return [] }

        let sorted = samples
            .filter { $0.t >= start && $0.t <= end && $0.bpm > 0 }
            .sorted { $0.t < $1.t }
        guard sorted.count >= 12 else { return [] }

        let epoch: TimeInterval = 30
        let epochCount = max(1, Int(duration / epoch))
        let features = epochFeatures(samples: sorted,
                                     start: start,
                                     end: end,
                                     epochCount: epochCount,
                                     motionValidated: motionValidated,
                                     motionEpochs: motionEpochs)
        var staged: [(start: Date, end: Date, stage: SleepStageKind)] = []

        for feature in features {
            let stage = stage(feature: feature,
                              restingHR: restingHR,
                              isNap: isNap)
            staged.append((feature.start, feature.end, stage))
        }

        guard staged.count >= max(8, epochCount / 3) else {
            return fallbackStageSegments(samples: sorted,
                                         start: start,
                                         end: end,
                                         restingHR: restingHR,
                                         isNap: isNap,
                                         motionValidated: motionValidated,
                                         motionEpochs: motionEpochs)
        }
        let merged = merge(staged)
        let covered = merged.reduce(0) { $0 + max(0, $1.duration) }
        let nonAwake = merged.reduce(0) { $0 + ($1.stage == .awake ? 0 : max(0, $1.duration)) }
        if covered < duration * 0.85 || (!motionValidated && nonAwake <= 0) {
            let fallback = fallbackStageSegments(samples: sorted,
                                                 start: start,
                                                 end: end,
                                                 restingHR: restingHR,
                                                 isNap: isNap,
                                                 motionValidated: motionValidated,
                                                 motionEpochs: motionEpochs)
            if fallback.reduce(0, { $0 + max(0, $1.duration) }) > covered || nonAwake <= 0 {
                return fallback
            }
        }
        return merged
    }

    private static func epochFeatures(samples: [HeartSample],
                                      start: Date,
                                      end: Date,
                                      epochCount: Int,
                                      motionValidated: Bool,
                                      motionEpochs: [AtriaRecoveredMotionEpoch]) -> [EpochFeature] {
        let epoch: TimeInterval = 30
        let duration = max(1, end.timeIntervalSince(start))
        return (0..<epochCount).compactMap { index in
            let epochStart = start.addingTimeInterval(Double(index) * epoch)
            let epochEnd = index == epochCount - 1 ? end : min(end, epochStart.addingTimeInterval(epoch))
            let center = epochStart.addingTimeInterval(epochEnd.timeIntervalSince(epochStart) / 2)
            let epochRange = sampleRange(in: samples, from: epochStart, through: epochEnd)
            let nearbyRange = sampleRange(in: samples,
                                          from: center.addingTimeInterval(-5 * 60),
                                          through: center.addingTimeInterval(5 * 60))
            let sourceRange = epochRange.isEmpty ? nearbyRange : epochRange
            guard !sourceRange.isEmpty else { return nil }
            let averageHR = averageHeartRate(in: samples, range: sourceRange) ?? 0
            let shortSmoothHR = gaussianSmoothedHR(samples: samples, center: center, sigma: 120) ?? averageHR
            let longSmoothHR = gaussianSmoothedHR(samples: samples, center: center, sigma: 600) ?? shortSmoothHR
            let variability = heartRateStandardDeviation(in: samples, range: nearbyRange)
            let progress = epochStart.timeIntervalSince(start) / duration
            let motion = motionContext(epochs: motionEpochs,
                                       start: epochStart,
                                       end: epochEnd)
            let legacyMotionValidated = motionEpochs.isEmpty && motionValidated
            let motionStillnessPrior = motion?.stillness ?? (legacyMotionValidated ? 1.0 : 0.55)
            return EpochFeature(start: epochStart,
                                end: epochEnd,
                                averageHR: averageHR,
                                shortSmoothHR: shortSmoothHR,
                                longSmoothHR: longSmoothHR,
                                differenceOfGaussians: shortSmoothHR - longSmoothHR,
                                localVariability: variability,
                                progress: progress,
                                motionStillnessPrior: motionStillnessPrior,
                                motionMovementIntensity: motion?.intensity ?? 0,
                                motionMeasurementValidated: motion != nil || legacyMotionValidated)
        }
    }

    private static func stage(feature: EpochFeature,
                              restingHR: Int,
                              isNap: Bool) -> SleepStageKind {
        let delta = feature.averageHR - Double(restingHR)
        let trendUp = feature.differenceOfGaussians
        let variability = feature.localVariability
        let stillness = feature.motionStillnessPrior
        if delta >= 18 || (trendUp >= 7 && variability >= 4) { return .awake }
        if !feature.motionMeasurementValidated && (delta >= 13 || trendUp >= 5) { return .awake }
        if feature.motionMeasurementValidated,
           (stillness < 0.55 || feature.motionMovementIntensity > 0.35) { return .awake }
        if stillness < 0.7 && variability >= 6 { return .awake }
        if isNap {
            if feature.progress > 0.20 && delta <= 10 && variability >= 3.5 && trendUp > -1 { return .rem }
            if delta <= 3 && variability <= 3 { return .deep }
            if delta <= 7 && trendUp <= 3 { return .sws }
            return .light
        }
        if feature.progress < 0.06 || feature.progress > 0.94, delta >= 10 { return .awake }
        if feature.progress >= 0.18 && feature.progress <= 0.88 && delta >= 2 && delta <= 12 && variability >= 3.2 && trendUp > -1 {
            return .rem
        }
        if delta <= 2 && trendUp <= 1.5 && variability <= 3.5 { return .deep }
        if delta <= 7 && trendUp <= 3.5 { return .sws }
        return .light
    }

    private static func coarseStageSegments(samples: [HeartSample],
                                            start: Date,
                                            end: Date,
                                            restingHR: Int,
                                            isNap: Bool,
                                            motionValidated: Bool,
                                            motionEpochs: [AtriaRecoveredMotionEpoch],
                                            sampleVisits: inout Int) -> [SleepStageSegment] {
        let duration = end.timeIntervalSince(start)
        guard duration >= 20 * 60, !samples.isEmpty else { return [] }
        let epoch: TimeInterval = isNap ? 5 * 60 : 10 * 60
        let epochCount = max(1, Int(ceil(duration / epoch)))
        let staged: [(start: Date, end: Date, stage: SleepStageKind)] = (0..<epochCount).compactMap { index in
            let epochStart = start.addingTimeInterval(Double(index) * epoch)
            let epochEnd = index == epochCount - 1 ? end : min(end, epochStart.addingTimeInterval(epoch))
            let center = epochStart.addingTimeInterval(epochEnd.timeIntervalSince(epochStart) / 2)
            let window: TimeInterval = isNap ? 12 * 60 : 20 * 60
            let nearbyRange = sampleRange(in: samples,
                                          from: center.addingTimeInterval(-window),
                                          through: center.addingTimeInterval(window))
            guard !nearbyRange.isEmpty else { return nil }
            sampleVisits += nearbyRange.count * 3
            let averageHR = averageHeartRate(in: samples, range: nearbyRange) ?? 0
            let variability = heartRateStandardDeviation(in: samples, range: nearbyRange)
            let progress = epochStart.timeIntervalSince(start) / max(1, duration)
            let motion = motionContext(epochs: motionEpochs,
                                       start: epochStart,
                                       end: epochEnd)
            let legacyMotionValidated = motionEpochs.isEmpty && motionValidated
            let feature = EpochFeature(start: epochStart,
                                       end: epochEnd,
                                       averageHR: averageHR,
                                       shortSmoothHR: averageHR,
                                       longSmoothHR: averageHR,
                                       differenceOfGaussians: 0,
                                       localVariability: variability,
                                       progress: progress,
                                       motionStillnessPrior: motion?.stillness ?? (legacyMotionValidated ? 1.0 : 0.55),
                                       motionMovementIntensity: motion?.intensity ?? 0,
                                       motionMeasurementValidated: motion != nil || legacyMotionValidated)
            return (epochStart, epochEnd, stage(feature: feature,
                                                restingHR: restingHR,
                                                isNap: isNap))
        }
        guard !staged.isEmpty else { return [] }
        return merge(staged)
    }

    private static func fallbackStageSegments(samples: [HeartSample],
                                              start: Date,
                                              end: Date,
                                              restingHR: Int,
                                              isNap: Bool,
                                              motionValidated: Bool,
                                              motionEpochs: [AtriaRecoveredMotionEpoch]) -> [SleepStageSegment] {
        fallbackStageDiagnostics(samples: samples,
                                 start: start,
                                 end: end,
                                 restingHR: restingHR,
                                 isNap: isNap,
                                 motionValidated: motionValidated,
                                 motionEpochs: motionEpochs).segments
    }

    static func fallbackStageDiagnostics(samples: [HeartSample],
                                         start: Date,
                                         end: Date,
                                         restingHR: Int,
                                         isNap: Bool,
                                         motionValidated: Bool,
                                         motionEpochs: [AtriaRecoveredMotionEpoch] = []) -> FallbackStageDiagnostics {
        var sampleVisits = 0
        let coarse = coarseStageSegments(samples: samples,
                                         start: start,
                                         end: end,
                                         restingHR: restingHR,
                                         isNap: isNap,
                                         motionValidated: motionValidated,
                                         motionEpochs: motionEpochs,
                                         sampleVisits: &sampleVisits)
        let duration = end.timeIntervalSince(start)
        let covered = coarse.reduce(0) { $0 + max(0, $1.duration) }
        let nonAwake = coarse.reduce(0) { $0 + ($1.stage == .awake ? 0 : max(0, $1.duration)) }
        guard covered < duration * 0.85 || (!motionValidated && nonAwake <= 0) else {
            return FallbackStageDiagnostics(segments: coarse, sampleVisits: sampleVisits)
        }
        let full = fullCoverageHRStageSegments(samples: samples,
                                               start: start,
                                               end: end,
                                               restingHR: restingHR,
                                               isNap: isNap,
                                               motionValidated: motionValidated,
                                               motionEpochs: motionEpochs,
                                               sampleVisits: &sampleVisits)
        return FallbackStageDiagnostics(segments: full.isEmpty ? coarse : full,
                                        sampleVisits: sampleVisits)
    }

    private static func fullCoverageHRStageSegments(samples: [HeartSample],
                                                    start: Date,
                                                    end: Date,
                                                    restingHR: Int,
                                                    isNap: Bool,
                                                    motionValidated: Bool,
                                                    motionEpochs: [AtriaRecoveredMotionEpoch],
                                                    sampleVisits: inout Int) -> [SleepStageSegment] {
        let duration = end.timeIntervalSince(start)
        guard duration >= 20 * 60, !samples.isEmpty else { return [] }
        let epoch: TimeInterval = isNap ? 5 * 60 : 10 * 60
        let epochCount = max(1, Int(ceil(duration / epoch)))
        let allRange = samples.indices
        sampleVisits += allRange.count * 3
        let globalAverage = averageHeartRate(in: samples, range: allRange) ?? Double(restingHR)
        let globalVariability = heartRateStandardDeviation(in: samples, range: allRange)
        let staged: [(start: Date, end: Date, stage: SleepStageKind)] = (0..<epochCount).map { index in
            let epochStart = start.addingTimeInterval(Double(index) * epoch)
            let epochEnd = index == epochCount - 1 ? end : min(end, epochStart.addingTimeInterval(epoch))
            let center = epochStart.addingTimeInterval(epochEnd.timeIntervalSince(epochStart) / 2)
            let directRange = sampleRange(in: samples, from: epochStart, through: epochEnd)
            let nearbyRange = directRange.isEmpty
                ? sampleRange(in: samples,
                              from: center.addingTimeInterval(-(isNap ? 20 * 60 : 45 * 60)),
                              through: center.addingTimeInterval(isNap ? 20 * 60 : 45 * 60))
                : directRange
            let sourceRange = nearbyRange.isEmpty ? allRange : nearbyRange
            sampleVisits += sourceRange.count
            let averageHR = averageHeartRate(in: samples, range: sourceRange) ?? globalAverage
            let variability: Double
            if nearbyRange.isEmpty {
                variability = globalVariability
            } else {
                sampleVisits += sourceRange.count * 2
                variability = heartRateStandardDeviation(in: samples, range: sourceRange)
            }
            let progress = epochStart.timeIntervalSince(start) / max(1, duration)
            let motion = motionContext(epochs: motionEpochs,
                                       start: epochStart,
                                       end: epochEnd)
            let legacyMotionValidated = motionEpochs.isEmpty && motionValidated
            let stage = hrOnlyStage(averageHR: averageHR,
                                    variability: variability,
                                    progress: progress,
                                    restingHR: restingHR,
                                    isNap: isNap,
                                    motionStillnessPrior: motion?.stillness ?? (legacyMotionValidated ? 1.0 : 0.55),
                                    motionMovementIntensity: motion?.intensity ?? 0,
                                    motionMeasurementValidated: motion != nil || legacyMotionValidated)
            return (epochStart, epochEnd, stage)
        }
        return merge(staged)
    }

    private static func hrOnlyStage(averageHR: Double,
                                    variability: Double,
                                    progress: Double,
                                    restingHR: Int,
                                    isNap: Bool,
                                    motionStillnessPrior: Double,
                                    motionMovementIntensity: Double,
                                    motionMeasurementValidated: Bool) -> SleepStageKind {
        if motionMeasurementValidated {
            let feature = EpochFeature(start: Date(timeIntervalSince1970: 0),
                                       end: Date(timeIntervalSince1970: 1),
                                       averageHR: averageHR,
                                       shortSmoothHR: averageHR,
                                       longSmoothHR: averageHR,
                                       differenceOfGaussians: 0,
                                       localVariability: variability,
                                       progress: progress,
                                       motionStillnessPrior: motionStillnessPrior,
                                       motionMovementIntensity: motionMovementIntensity,
                                       motionMeasurementValidated: true)
            return stage(feature: feature,
                         restingHR: restingHR,
                         isNap: isNap)
        }
        let delta = averageHR - Double(restingHR)
        if delta >= 18 || ((progress < 0.06 || progress > 0.94) && delta >= 14) { return .awake }
        if isNap {
            if progress >= 0.25 && delta <= 11 && variability >= 3.0 { return .rem }
            if delta <= 3 && variability <= 3.5 { return .deep }
            if delta <= 7 { return .sws }
            return .light
        }
        if progress >= 0.18 && progress <= 0.88 && delta >= 2 && delta <= 14 && variability >= 3.0 {
            return .rem
        }
        if delta <= 3 && variability <= 3.5 { return .deep }
        if delta <= 8 { return .sws }
        return .light
    }

    private static func motionContext(
        epochs: [AtriaRecoveredMotionEpoch],
        start: Date,
        end: Date
    ) -> (stillness: Double, intensity: Double)? {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return nil }
        let overlapping = epochs.filter {
            $0.measurementValidated && $0.end > start && $0.start < end
        }
        var covered: TimeInterval = 0
        var weightedStillness = 0.0
        var weightedIntensity = 0.0
        for epoch in overlapping {
            let overlap = min(end, epoch.end).timeIntervalSince(max(start, epoch.start))
            guard overlap > 0,
                  let stillness = epoch.stillnessRatio,
                  let intensity = epoch.movementIntensity,
                  stillness.isFinite,
                  intensity.isFinite else { continue }
            covered += overlap
            weightedStillness += stillness * overlap
            weightedIntensity += intensity * overlap
        }
        guard covered / duration >= 0.60 else { return nil }
        return (weightedStillness / covered, weightedIntensity / covered)
    }

    private static func gaussianSmoothedHR(samples: [HeartSample],
                                           center: Date,
                                           sigma: TimeInterval) -> Double? {
        guard sigma > 0 else { return nil }
        let radius = sigma * 3
        let range = sampleRange(in: samples,
                                from: center.addingTimeInterval(-radius),
                                through: center.addingTimeInterval(radius))
        guard !range.isEmpty else { return nil }
        var weighted = 0.0
        var weights = 0.0
        for index in range {
            let sample = samples[index]
            let distance = sample.t.timeIntervalSince(center)
            let weight = exp(-0.5 * pow(distance / sigma, 2))
            weighted += Double(sample.bpm) * weight
            weights += weight
        }
        guard weights > 0 else { return nil }
        return weighted / weights
    }

    private static func sampleRange(in samples: [HeartSample],
                                    from start: Date,
                                    through end: Date) -> Range<Int> {
        var lowerLow = 0
        var lowerHigh = samples.count
        while lowerLow < lowerHigh {
            let middle = (lowerLow + lowerHigh) / 2
            if samples[middle].t < start {
                lowerLow = middle + 1
            } else {
                lowerHigh = middle
            }
        }

        var upperLow = lowerLow
        var upperHigh = samples.count
        while upperLow < upperHigh {
            let middle = (upperLow + upperHigh) / 2
            if samples[middle].t <= end {
                upperLow = middle + 1
            } else {
                upperHigh = middle
            }
        }
        return lowerLow..<upperLow
    }

    private static func averageHeartRate(in samples: [HeartSample],
                                         range: Range<Int>) -> Double? {
        guard !range.isEmpty else { return nil }
        var total = 0.0
        for index in range {
            total += Double(samples[index].bpm)
        }
        return total / Double(range.count)
    }

    private static func heartRateStandardDeviation(in samples: [HeartSample],
                                                   range: Range<Int>) -> Double {
        guard range.count >= 2,
              let mean = averageHeartRate(in: samples, range: range) else { return 0 }
        var squaredDeltaTotal = 0.0
        for index in range {
            let delta = Double(samples[index].bpm) - mean
            squaredDeltaTotal += delta * delta
        }
        return sqrt(squaredDeltaTotal / Double(range.count))
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2, let mean = average(values) else { return 0 }
        let variance = values.reduce(0) { total, value in
            total + pow(value - mean, 2)
        } / Double(values.count)
        return sqrt(variance)
    }

    private static func merge(_ staged: [(start: Date, end: Date, stage: SleepStageKind)]) -> [SleepStageSegment] {
        var merged: [(start: Date, end: Date, stage: SleepStageKind)] = []
        for item in staged {
            // NOTE: must peek at `merged.last` (not `popLast()`) — popping before the
            // stage/adjacency check unconditionally discards the previous run when the
            // check fails, collapsing the whole segmentation down to just the final run.
            if let last = merged.last, last.stage == item.stage, item.start.timeIntervalSince(last.end) <= 1 {
                merged[merged.count - 1].end = item.end
            } else {
                merged.append(item)
            }
        }
        return merged.enumerated().map { index, item in
            SleepStageSegment(id: "research-\(Int(item.start.timeIntervalSince1970))-\(index)-\(item.stage.rawValue)",
                              start: item.start,
                              end: item.end,
                              stage: item.stage)
        }
    }
}
