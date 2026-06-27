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
    }

    static func classify(duration: TimeInterval,
                         averageHR: Int,
                         restingHR: Int,
                         imuStillnessRatio: Double?,
                         imuMovementIntensity: Double?,
                         strapSteps: Int?) -> Result {
        guard duration >= 20 * 60 else {
            return Result(state: "learning", confidence: "none", reason: "short_window")
        }
        guard let imuStillnessRatio, let imuMovementIntensity else {
            return Result(state: "learning", confidence: "none", reason: "imu_missing")
        }
        let lowMotion = imuStillnessRatio >= 0.72 && imuMovementIntensity <= 0.18
        let lowHR = averageHR <= restingHR + 18
        let lowSteps = (strapSteps ?? 0) <= max(8, Int(duration / 600))
        if lowMotion && lowHR && lowSteps {
            return Result(state: "sleep_research", confidence: "research", reason: "low_motion_low_hr")
        }
        return Result(state: "wake_research", confidence: "research", reason: "motion_or_hr_active")
    }

    static func stageSegments(samples: [HeartSample],
                              start: Date,
                              end: Date,
                              restingHR: Int,
                              isNap: Bool,
                              motionValidated: Bool) -> [SleepStageSegment] {
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
                                     motionValidated: motionValidated)
        var staged: [(start: Date, end: Date, stage: SleepStageKind)] = []

        for feature in features {
            let stage = stage(feature: feature,
                              restingHR: restingHR,
                              isNap: isNap,
                              motionValidated: motionValidated)
            staged.append((feature.start, feature.end, stage))
        }

        guard staged.count >= max(8, epochCount / 3) else { return [] }
        return merge(staged)
    }

    private static func epochFeatures(samples: [HeartSample],
                                      start: Date,
                                      end: Date,
                                      epochCount: Int,
                                      motionValidated: Bool) -> [EpochFeature] {
        let epoch: TimeInterval = 30
        let duration = max(1, end.timeIntervalSince(start))
        return (0..<epochCount).compactMap { index in
            let epochStart = start.addingTimeInterval(Double(index) * epoch)
            let epochEnd = index == epochCount - 1 ? end : min(end, epochStart.addingTimeInterval(epoch))
            let center = epochStart.addingTimeInterval(epochEnd.timeIntervalSince(epochStart) / 2)
            let epochSamples = samples.filter { $0.t >= epochStart && $0.t <= epochEnd }
            let nearby = samples.filter { abs($0.t.timeIntervalSince(center)) <= 5 * 60 }
            let source = epochSamples.isEmpty ? nearby : epochSamples
            guard !source.isEmpty else { return nil }
            let averageHR = average(source.map { Double($0.bpm) }) ?? 0
            let shortSmoothHR = gaussianSmoothedHR(samples: samples, center: center, sigma: 120) ?? averageHR
            let longSmoothHR = gaussianSmoothedHR(samples: samples, center: center, sigma: 600) ?? shortSmoothHR
            let variability = standardDeviation(nearby.map { Double($0.bpm) })
            let progress = epochStart.timeIntervalSince(start) / duration
            let motionStillnessPrior = motionValidated ? 1.0 : 0.55
            return EpochFeature(start: epochStart,
                                end: epochEnd,
                                averageHR: averageHR,
                                shortSmoothHR: shortSmoothHR,
                                longSmoothHR: longSmoothHR,
                                differenceOfGaussians: shortSmoothHR - longSmoothHR,
                                localVariability: variability,
                                progress: progress,
                                motionStillnessPrior: motionStillnessPrior)
        }
    }

    private static func stage(feature: EpochFeature,
                              restingHR: Int,
                              isNap: Bool,
                              motionValidated: Bool) -> SleepStageKind {
        let delta = feature.averageHR - Double(restingHR)
        let trendUp = feature.differenceOfGaussians
        let variability = feature.localVariability
        let stillness = feature.motionStillnessPrior
        if delta >= 18 || (trendUp >= 7 && variability >= 4) { return .awake }
        if !motionValidated && (delta >= 13 || trendUp >= 5) { return .awake }
        if stillness < 0.7 && variability >= 6 { return .awake }
        if isNap {
            if delta <= 3 && variability <= 3 { return .deep }
            if delta <= 7 && trendUp <= 3 { return .sws }
            return .light
        }
        if feature.progress < 0.06 || feature.progress > 0.94, delta >= 10 { return .awake }
        if delta <= 2 && trendUp <= 1.5 && variability <= 3.5 { return .deep }
        if delta <= 7 && trendUp <= 3.5 { return .sws }
        return .light
    }

    private static func gaussianSmoothedHR(samples: [HeartSample],
                                           center: Date,
                                           sigma: TimeInterval) -> Double? {
        guard sigma > 0 else { return nil }
        var weighted = 0.0
        var weights = 0.0
        for sample in samples {
            let distance = sample.t.timeIntervalSince(center)
            guard abs(distance) <= sigma * 3 else { continue }
            let weight = exp(-0.5 * pow(distance / sigma, 2))
            weighted += Double(sample.bpm) * weight
            weights += weight
        }
        guard weights > 0 else { return nil }
        return weighted / weights
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
            if var last = merged.popLast(), last.stage == item.stage, item.start.timeIntervalSince(last.end) <= 1 {
                last.end = item.end
                merged.append(last)
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
