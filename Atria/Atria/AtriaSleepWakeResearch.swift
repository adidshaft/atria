import Foundation

/// Stable ordering for checked sleep projections. Swift's standard-library
/// sort is intentionally retained by every unchecked/legacy entry point; the
/// merge path exists only so a bounded projection can observe cancellation or
/// its absolute deadline while ordering a dense night.
enum AtriaSleepCooperativeAlgorithms {
    static func stableSort<Element>(
        _ values: inout [Element],
        cooperativeDeadline: AtriaSleepSettlementDeadline,
        areInIncreasingOrder: (Element, Element) -> Bool
    ) throws {
        try cooperativeDeadline.checkpoint()
        guard values.count > 1 else { return }
        var source = values
        var destination = values
        var width = 1
        while width < source.count {
            try cooperativeDeadline.checkpoint()
            var lower = 0
            while lower < source.count {
                let middle = min(lower + width, source.count)
                let upper = min(lower + width + width, source.count)
                var left = lower
                var right = middle
                var output = lower
                while output < upper {
                    if output.isMultiple(of: 256) {
                        try cooperativeDeadline.checkpoint()
                    }
                    if left < middle,
                       (right >= upper
                        || !areInIncreasingOrder(source[right], source[left])) {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                    output += 1
                }
                lower = upper
            }
            swap(&source, &destination)
            width = width > source.count / 2 ? source.count : width * 2
        }
        values = source
        try cooperativeDeadline.checkpoint()
    }
}

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

    /// Test-visible accounting for the bounded stage path. `sampleVisits`
    /// counts actual timestamped HR/motion inspections in the inner algorithm,
    /// not merely the number of inputs handed to it. This makes an accidental
    /// epoch-times-night rescan fail deterministically without wall-clock tests.
    struct FallbackStageDiagnostics: Equatable {
        let segments: [SleepStageSegment]
        let sampleVisits: Int
    }

    private final class StageWorkCounter {
        private(set) var sampleVisits = 0

        func visit(_ count: Int = 1) {
            sampleVisits += max(0, count)
        }
    }

    /// Research stage output is presentation-eligible only when both streams
    /// stay locally supported. These match the recovered-motion receipt's
    /// maximum tolerated hole and are intentionally stricter than the old
    /// whole-window HR fallback.
    private static let maximumEvidenceGap: TimeInterval = 90
    private static let minimumTimelineCoverageFraction = 0.85
    private static let maximumHeartRateGap: TimeInterval = 15
    private static let minimumHeartRateSamplesPerMinute = 6.0

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
                              motionValidated _: Bool,
                              motionEpochs: [AtriaRecoveredMotionEpoch] = []) -> [SleepStageSegment] {
        (try? stageSegmentsCore(samples: samples,
                                start: start,
                                end: end,
                                restingHR: restingHR,
                                isNap: isNap,
                                motionEpochs: motionEpochs,
                                workCounter: nil,
                                cooperativeDeadline: nil)) ?? []
    }

    /// Checked equivalent used only by foreground-authorized bounded work. It
    /// returns the complete legacy-equivalent timeline or throws; a deadline or
    /// cancellation can never publish a partially classified night.
    static func stageSegments(
        samples: [HeartSample],
        start: Date,
        end: Date,
        restingHR: Int,
        isNap: Bool,
        motionValidated _: Bool,
        motionEpochs: [AtriaRecoveredMotionEpoch] = [],
        cooperativeDeadline: AtriaSleepSettlementDeadline
    ) throws -> [SleepStageSegment] {
        try stageSegmentsCore(samples: samples,
                              start: start,
                              end: end,
                              restingHR: restingHR,
                              isNap: isNap,
                              motionEpochs: motionEpochs,
                              workCounter: nil,
                              cooperativeDeadline: cooperativeDeadline)
    }

    private static func stageSegmentsCore(
        samples: [HeartSample],
        start: Date,
        end: Date,
        restingHR: Int,
        isNap: Bool,
        motionEpochs: [AtriaRecoveredMotionEpoch],
        workCounter: StageWorkCounter?,
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> [SleepStageSegment] {
        try cooperativeDeadline?.checkpoint()
        let duration = end.timeIntervalSince(start)
        guard duration >= 20 * 60,
              restingHR > 0 else { return [] }

        // A record-level Boolean is not time-aligned evidence. Stages require
        // actual recovered epochs covering this exact window; otherwise fail
        // closed even when a legacy record says `motionValidated == true`.
        workCounter?.visit(motionEpochs.count)
        let motionProvenance: AtriaRecoveredMotionAnalytics.SleepProvenance
        if let cooperativeDeadline {
            motionProvenance = try AtriaRecoveredMotionAnalytics.sleepProvenance(
                epochs: motionEpochs,
                start: start,
                end: end,
                cooperativeDeadline: cooperativeDeadline
            )
        } else {
            motionProvenance = AtriaRecoveredMotionAnalytics.sleepProvenance(
                epochs: motionEpochs,
                start: start,
                end: end
            )
        }
        guard motionProvenance.measurementSufficient else { return [] }

        workCounter?.visit(samples.count)
        let sorted: [HeartSample]
        if let cooperativeDeadline {
            var checked: [HeartSample] = []
            checked.reserveCapacity(samples.count)
            for (index, sample) in samples.enumerated() {
                if index.isMultiple(of: 256) {
                    try cooperativeDeadline.checkpoint()
                }
                if sample.t >= start, sample.t <= end, sample.bpm > 0 {
                    checked.append(sample)
                }
            }
            try AtriaSleepCooperativeAlgorithms.stableSort(
                &checked,
                cooperativeDeadline: cooperativeDeadline,
                areInIncreasingOrder: { $0.t < $1.t }
            )
            sorted = checked
        } else {
            sorted = samples
                .filter { $0.t >= start && $0.t <= end && $0.bpm > 0 }
                .sorted { $0.t < $1.t }
        }
        guard try heartRateEvidenceIsDense(sorted,
                                           start: start,
                                           end: end,
                                           workCounter: workCounter,
                                           cooperativeDeadline: cooperativeDeadline) else {
            return []
        }

        let epoch: TimeInterval = 30
        let epochCount = max(1, Int(duration / epoch))
        let features = try epochFeatures(samples: sorted,
                                         start: start,
                                         end: end,
                                         epochCount: epochCount,
                                         motionEpochs: motionEpochs,
                                         workCounter: workCounter,
                                         cooperativeDeadline: cooperativeDeadline)
        var staged: [(start: Date, end: Date, stage: SleepStageKind)] = []

        for (index, feature) in features.enumerated() {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            let stage = stage(feature: feature,
                              restingHR: restingHR,
                              isNap: isNap)
            staged.append((feature.start, feature.end, stage))
        }

        guard staged.count >= max(8, epochCount / 3) else { return [] }
        let merged = try merge(staged, cooperativeDeadline: cooperativeDeadline)
        return try timelineHasDenseLocalEvidence(merged,
                                                 start: start,
                                                 end: end,
                                                 cooperativeDeadline: cooperativeDeadline)
            ? merged
            : []
    }

    private static func epochFeatures(samples: [HeartSample],
                                      start: Date,
                                      end: Date,
                                      epochCount: Int,
                                      motionEpochs: [AtriaRecoveredMotionEpoch],
                                      workCounter: StageWorkCounter?,
                                      cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> [EpochFeature] {
        try cooperativeDeadline?.checkpoint()
        let epoch: TimeInterval = 30
        let duration = max(1, end.timeIntervalSince(start))
        let orderedMotionEpochs: [AtriaRecoveredMotionEpoch]
        if let cooperativeDeadline {
            var checked = motionEpochs
            try AtriaSleepCooperativeAlgorithms.stableSort(
                &checked,
                cooperativeDeadline: cooperativeDeadline,
                areInIncreasingOrder: {
                    if $0.start != $1.start { return $0.start < $1.start }
                    return $0.end < $1.end
                }
            )
            orderedMotionEpochs = checked
        } else {
            orderedMotionEpochs = motionEpochs.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
        }
        var nextMotionIndex = 0
        var activeMotionEpochs: [AtriaRecoveredMotionEpoch] = []
        var features: [EpochFeature] = []
        features.reserveCapacity(epochCount)

        for index in 0..<epochCount {
            if index.isMultiple(of: 8) {
                try cooperativeDeadline?.checkpoint()
            }
            let epochStart = start.addingTimeInterval(Double(index) * epoch)
            let epochEnd = index == epochCount - 1 ? end : min(end, epochStart.addingTimeInterval(epoch))
            let center = epochStart.addingTimeInterval(epochEnd.timeIntervalSince(epochStart) / 2)

            // Stage epochs advance monotonically. Retain only motion intervals
            // that can overlap this epoch, then admit newly starting intervals
            // once. The former filter-per-epoch implementation rescanned the
            // complete night of motion for every 30-second output epoch.
            var retainedMotionEpochs: [AtriaRecoveredMotionEpoch] = []
            retainedMotionEpochs.reserveCapacity(activeMotionEpochs.count)
            for (activeIndex, motionEpoch) in activeMotionEpochs.enumerated() {
                if activeIndex.isMultiple(of: 64) {
                    try cooperativeDeadline?.checkpoint()
                }
                workCounter?.visit()
                if motionEpoch.end > epochStart {
                    retainedMotionEpochs.append(motionEpoch)
                }
            }
            activeMotionEpochs = retainedMotionEpochs
            while nextMotionIndex < orderedMotionEpochs.count {
                if nextMotionIndex.isMultiple(of: 64) {
                    try cooperativeDeadline?.checkpoint()
                }
                let motionEpoch = orderedMotionEpochs[nextMotionIndex]
                workCounter?.visit()
                guard motionEpoch.start < epochEnd else { break }
                if motionEpoch.end > epochStart {
                    activeMotionEpochs.append(motionEpoch)
                }
                nextMotionIndex += 1
            }

            let epochRange = try sampleRange(in: samples,
                                             from: epochStart,
                                             through: epochEnd,
                                             workCounter: workCounter,
                                             cooperativeDeadline: cooperativeDeadline)
            // Never borrow a distant HR sample to paint an unsupported epoch.
            // Wider windows remain useful only for smoothing/variability after
            // a real sample anchors this exact 30-second epoch.
            guard !epochRange.isEmpty else { continue }
            let nearbyRange = try sampleRange(in: samples,
                                              from: center.addingTimeInterval(-5 * 60),
                                              through: center.addingTimeInterval(5 * 60),
                                              workCounter: workCounter,
                                              cooperativeDeadline: cooperativeDeadline)
            let averageHR = try averageHeartRate(in: samples,
                                                 range: epochRange,
                                                 workCounter: workCounter,
                                                 cooperativeDeadline: cooperativeDeadline) ?? 0
            let shortSmoothHR = try gaussianSmoothedHR(samples: samples,
                                                       center: center,
                                                       sigma: 120,
                                                       workCounter: workCounter,
                                                       cooperativeDeadline: cooperativeDeadline) ?? averageHR
            let longSmoothHR = try gaussianSmoothedHR(samples: samples,
                                                      center: center,
                                                      sigma: 600,
                                                      workCounter: workCounter,
                                                      cooperativeDeadline: cooperativeDeadline) ?? shortSmoothHR
            let variability = try heartRateStandardDeviation(in: samples,
                                                             range: nearbyRange,
                                                             workCounter: workCounter,
                                                             cooperativeDeadline: cooperativeDeadline)
            let progress = epochStart.timeIntervalSince(start) / duration
            let motion = try motionContext(epochs: activeMotionEpochs,
                                           start: epochStart,
                                           end: epochEnd,
                                           workCounter: workCounter,
                                           cooperativeDeadline: cooperativeDeadline)
            // An epoch without sufficiently covered, validated, time-aligned
            // motion remains blank; a whole-record Boolean cannot fill it.
            guard let motion else { continue }
            features.append(EpochFeature(start: epochStart,
                                         end: epochEnd,
                                         averageHR: averageHR,
                                         shortSmoothHR: shortSmoothHR,
                                         longSmoothHR: longSmoothHR,
                                         differenceOfGaussians: shortSmoothHR - longSmoothHR,
                                         localVariability: variability,
                                         progress: progress,
                                         motionStillnessPrior: motion.stillness,
                                         motionMovementIntensity: motion.intensity,
                                         motionMeasurementValidated: true))
        }
        try cooperativeDeadline?.checkpoint()
        return features
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

    /// Kept as a test-visible compatibility surface for the former fallback.
    /// It now runs the same fail-closed engine and never expands global HR
    /// statistics across epochs that lack local HR or motion evidence.
    static func fallbackStageDiagnostics(samples: [HeartSample],
                                         start: Date,
                                         end: Date,
                                         restingHR: Int,
                                         isNap: Bool,
                                         motionValidated: Bool,
                                         motionEpochs: [AtriaRecoveredMotionEpoch] = []) -> FallbackStageDiagnostics {
        _ = motionValidated
        let workCounter = StageWorkCounter()
        return FallbackStageDiagnostics(
            segments: (try? stageSegmentsCore(samples: samples,
                                              start: start,
                                              end: end,
                                              restingHR: restingHR,
                                              isNap: isNap,
                                              motionEpochs: motionEpochs,
                                              workCounter: workCounter,
                                              cooperativeDeadline: nil)) ?? [],
            sampleVisits: workCounter.sampleVisits
        )
    }

    /// Test-visible probe for the dominant checked inner loop. Production calls
    /// this only through `stageSegments`; exposing the narrow probe lets a
    /// deterministic clock prove cancellation occurs inside Gaussian work rather
    /// than merely before or after the stage engine.
    static func checkedGaussianSmoothingForTesting(
        samples: [HeartSample],
        center: Date,
        sigma: TimeInterval,
        cooperativeDeadline: AtriaSleepSettlementDeadline
    ) throws -> Double? {
        try gaussianSmoothedHR(samples: samples,
                               center: center,
                               sigma: sigma,
                               workCounter: nil,
                               cooperativeDeadline: cooperativeDeadline)
    }

    private static func timelineHasDenseLocalEvidence(
        _ segments: [SleepStageSegment],
        start: Date,
        end: Date,
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> Bool {
        try cooperativeDeadline?.checkpoint()
        let duration = end.timeIntervalSince(start)
        guard duration > 0, !segments.isEmpty else { return false }
        var covered: TimeInterval = 0
        var previousEnd = start
        var maximumGap: TimeInterval = 0
        for (index, segment) in segments.enumerated() {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            guard segment.end > segment.start,
                  segment.start >= previousEnd,
                  segment.start >= start,
                  segment.end <= end else { return false }
            maximumGap = max(maximumGap, segment.start.timeIntervalSince(previousEnd))
            covered += segment.duration
            previousEnd = segment.end
        }
        maximumGap = max(maximumGap, end.timeIntervalSince(previousEnd))
        return covered / duration >= minimumTimelineCoverageFraction
            && maximumGap <= maximumEvidenceGap
    }

    private static func heartRateEvidenceIsDense(
        _ samples: [HeartSample],
        start: Date,
        end: Date,
        workCounter: StageWorkCounter?,
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> Bool {
        try cooperativeDeadline?.checkpoint()
        let duration = end.timeIntervalSince(start)
        guard duration > 0,
              let first = samples.first,
              let last = samples.last else { return false }
        let requiredSamples = Int(ceil(
            duration / 60 * minimumHeartRateSamplesPerMinute
        ))
        guard samples.count >= requiredSamples,
              first.t.timeIntervalSince(start) <= maximumHeartRateGap,
              end.timeIntervalSince(last.t) <= maximumHeartRateGap else {
            return false
        }
        for index in 1..<samples.count {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit(2)
            if samples[index].t.timeIntervalSince(samples[index - 1].t) > maximumHeartRateGap {
                return false
            }
        }
        return true
    }

    private static func motionContext(
        epochs: [AtriaRecoveredMotionEpoch],
        start: Date,
        end: Date,
        workCounter: StageWorkCounter?,
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> (stillness: Double, intensity: Double)? {
        struct MotionSupport {
            var start: Date
            var end: Date
            let stillness: Double
            let intensity: Double
        }

        try cooperativeDeadline?.checkpoint()
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return nil }
        let support: [MotionSupport]
        if let cooperativeDeadline {
            var checked: [MotionSupport] = []
            checked.reserveCapacity(epochs.count)
            for (index, epoch) in epochs.enumerated() {
                if index.isMultiple(of: 64) {
                    try cooperativeDeadline.checkpoint()
                }
                workCounter?.visit()
                guard epoch.measurementValidated,
                      epoch.end > start,
                      epoch.start < end,
                      let stillness = epoch.stillnessRatio,
                      let intensity = epoch.movementIntensity,
                      stillness.isFinite,
                      intensity.isFinite else { continue }
                let lower = max(start, epoch.start)
                let upper = min(end, epoch.end)
                guard upper > lower else { continue }
                checked.append(MotionSupport(start: lower,
                                             end: upper,
                                             stillness: stillness,
                                             intensity: intensity))
            }
            try AtriaSleepCooperativeAlgorithms.stableSort(
                &checked,
                cooperativeDeadline: cooperativeDeadline,
                areInIncreasingOrder: {
                    if $0.start != $1.start { return $0.start < $1.start }
                    return $0.end < $1.end
                }
            )
            support = checked
        } else {
            support = epochs.compactMap { epoch -> MotionSupport? in
                workCounter?.visit()
                guard epoch.measurementValidated,
                      epoch.end > start,
                      epoch.start < end,
                      let stillness = epoch.stillnessRatio,
                      let intensity = epoch.movementIntensity,
                      stillness.isFinite,
                      intensity.isFinite else { return nil }
                let lower = max(start, epoch.start)
                let upper = min(end, epoch.end)
                guard upper > lower else { return nil }
                return MotionSupport(start: lower,
                                     end: upper,
                                     stillness: stillness,
                                     intensity: intensity)
            }.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
        }

        // Compact latest-night preparation can attach the same recovered epoch
        // to both saved sessions at a reconnect boundary. Count identical
        // support once. If overlapping projections disagree, that wall-clock
        // interval has no single measurement authority, so withhold the entire
        // 30-second stage epoch instead of averaging a conflict into precision.
        var uniqueSupport: [MotionSupport] = []
        uniqueSupport.reserveCapacity(support.count)
        for (index, candidate) in support.enumerated() {
            if index.isMultiple(of: 64) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit()
            guard var previous = uniqueSupport.last else {
                uniqueSupport.append(candidate)
                continue
            }
            let overlaps = candidate.start < previous.end
            let sameMeasurement = candidate.stillness == previous.stillness
                && candidate.intensity == previous.intensity
            if overlaps {
                guard sameMeasurement else { return nil }
                previous.end = max(previous.end, candidate.end)
                uniqueSupport[uniqueSupport.count - 1] = previous
            } else if candidate.start == previous.end, sameMeasurement {
                previous.end = candidate.end
                uniqueSupport[uniqueSupport.count - 1] = previous
            } else {
                uniqueSupport.append(candidate)
            }
        }

        var covered: TimeInterval = 0
        var weightedStillness = 0.0
        var weightedIntensity = 0.0
        for (index, interval) in uniqueSupport.enumerated() {
            if index.isMultiple(of: 64) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit()
            let intervalDuration = interval.end.timeIntervalSince(interval.start)
            covered += intervalDuration
            weightedStillness += interval.stillness * intervalDuration
            weightedIntensity += interval.intensity * intervalDuration
        }
        guard covered / duration >= 0.80 else { return nil }
        try cooperativeDeadline?.checkpoint()
        return (weightedStillness / covered, weightedIntensity / covered)
    }

    private static func gaussianSmoothedHR(samples: [HeartSample],
                                           center: Date,
                                           sigma: TimeInterval,
                                           workCounter: StageWorkCounter?,
                                           cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> Double? {
        try cooperativeDeadline?.checkpoint()
        guard sigma > 0 else { return nil }
        let radius = sigma * 3
        let range = try sampleRange(in: samples,
                                    from: center.addingTimeInterval(-radius),
                                    through: center.addingTimeInterval(radius),
                                    workCounter: workCounter,
                                    cooperativeDeadline: cooperativeDeadline)
        guard !range.isEmpty else { return nil }
        var weighted = 0.0
        var weights = 0.0
        for index in range {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit()
            let sample = samples[index]
            let distance = sample.t.timeIntervalSince(center)
            let weight = exp(-0.5 * pow(distance / sigma, 2))
            weighted += Double(sample.bpm) * weight
            weights += weight
        }
        try cooperativeDeadline?.checkpoint()
        guard weights > 0 else { return nil }
        return weighted / weights
    }

    private static func sampleRange(in samples: [HeartSample],
                                    from start: Date,
                                    through end: Date,
                                    workCounter: StageWorkCounter?,
                                    cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> Range<Int> {
        try cooperativeDeadline?.checkpoint()
        var lowerLow = 0
        var lowerHigh = samples.count
        while lowerLow < lowerHigh {
            let middle = (lowerLow + lowerHigh) / 2
            workCounter?.visit()
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
            workCounter?.visit()
            if samples[middle].t <= end {
                upperLow = middle + 1
            } else {
                upperHigh = middle
            }
        }
        try cooperativeDeadline?.checkpoint()
        return lowerLow..<upperLow
    }

    private static func averageHeartRate(in samples: [HeartSample],
                                         range: Range<Int>,
                                         workCounter: StageWorkCounter?,
                                         cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> Double? {
        guard !range.isEmpty else { return nil }
        var total = 0.0
        for index in range {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit()
            total += Double(samples[index].bpm)
        }
        return total / Double(range.count)
    }

    private static func heartRateStandardDeviation(in samples: [HeartSample],
                                                   range: Range<Int>,
                                                   workCounter: StageWorkCounter?,
                                                   cooperativeDeadline: AtriaSleepSettlementDeadline?) throws -> Double {
        guard range.count >= 2,
              let mean = try averageHeartRate(in: samples,
                                              range: range,
                                              workCounter: workCounter,
                                              cooperativeDeadline: cooperativeDeadline) else { return 0 }
        var squaredDeltaTotal = 0.0
        for index in range {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            workCounter?.visit()
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

    private static func merge(
        _ staged: [(start: Date, end: Date, stage: SleepStageKind)],
        cooperativeDeadline: AtriaSleepSettlementDeadline?
    ) throws -> [SleepStageSegment] {
        try cooperativeDeadline?.checkpoint()
        var merged: [(start: Date, end: Date, stage: SleepStageKind)] = []
        for (index, item) in staged.enumerated() {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            // NOTE: must peek at `merged.last` (not `popLast()`) — popping before the
            // stage/adjacency check unconditionally discards the previous run when the
            // check fails, collapsing the whole segmentation down to just the final run.
            if let last = merged.last, last.stage == item.stage, item.start.timeIntervalSince(last.end) <= 1 {
                merged[merged.count - 1].end = item.end
            } else {
                merged.append(item)
            }
        }
        if cooperativeDeadline == nil {
            return merged.enumerated().map { index, item in
                SleepStageSegment(id: "research-motion-v2-\(Int(item.start.timeIntervalSince1970))-\(index)-\(item.stage.rawValue)",
                                  start: item.start,
                                  end: item.end,
                                  stage: item.stage)
            }
        }
        var segments: [SleepStageSegment] = []
        segments.reserveCapacity(merged.count)
        for (index, item) in merged.enumerated() {
            if index.isMultiple(of: 256) {
                try cooperativeDeadline?.checkpoint()
            }
            segments.append(SleepStageSegment(
                id: "research-motion-v2-\(Int(item.start.timeIntervalSince1970))-\(index)-\(item.stage.rawValue)",
                start: item.start,
                end: item.end,
                stage: item.stage
            ))
        }
        try cooperativeDeadline?.checkpoint()
        return segments
    }
}
