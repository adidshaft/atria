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
        var staged: [(start: Date, end: Date, stage: SleepStageKind)] = []

        for index in 0..<epochCount {
            let epochStart = start.addingTimeInterval(Double(index) * epoch)
            let epochEnd = index == epochCount - 1 ? end : min(end, epochStart.addingTimeInterval(epoch))
            let windowStart = epochStart.addingTimeInterval(-epoch)
            let windowEnd = epochEnd.addingTimeInterval(epoch)
            let window = sorted.filter { $0.t >= windowStart && $0.t <= windowEnd }
            guard !window.isEmpty else { continue }
            let avg = Double(window.reduce(0) { $0 + $1.bpm }) / Double(window.count)
            let progress = epochStart.timeIntervalSince(start) / max(duration, 1)
            let stage = stage(avgHR: avg,
                              restingHR: restingHR,
                              progress: progress,
                              isNap: isNap,
                              motionValidated: motionValidated)
            staged.append((epochStart, epochEnd, stage))
        }

        guard staged.count >= max(8, epochCount / 3) else { return [] }
        return merge(staged)
    }

    private static func stage(avgHR: Double,
                              restingHR: Int,
                              progress: Double,
                              isNap: Bool,
                              motionValidated: Bool) -> SleepStageKind {
        let delta = avgHR - Double(restingHR)
        if delta >= 18 { return .awake }
        if !motionValidated && delta >= 13 { return .awake }
        if isNap {
            if delta <= 3 { return .deep }
            if delta <= 7 { return .sws }
            return .light
        }
        if progress < 0.06 || progress > 0.94, delta >= 10 { return .awake }
        if delta <= 2 { return .deep }
        if delta <= 7 { return .sws }
        return .light
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
