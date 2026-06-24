import SwiftUI
import Charts
import CryptoKit

/// A finished heart-rate session, persisted locally (no cloud, no WHOOP account).
struct SavedSession: Codable, Identifiable {
    let id: UUID
    let start: Date
    let end: Date
    let label: String
    /// (secondsFromStart, bpm) points — compact representation of the HR series.
    let points: [Point]
    /// Representative HRV (RMSSD, ms) for the session, if the realtime channel
    /// produced RR intervals. Optional so older saved sessions still decode.
    var hrv: Int?
    /// True SDNN (ms) from the same RR window that passed external validation.
    /// HealthKit's HRV type is SDNN, while Atria displays RMSSD in-app.
    var hrvSDNN: Double? = nil
    /// Respiratory rate inferred from RR modulation, in breaths per minute.
    /// Optional because older sessions and insufficient RR windows have none.
    var respiratoryRate: Double? = nil
    /// Real decoded RR/IBI intervals received from WHOOP realtime frames during
    /// this saved session. These are preserved for audit/replay, but do not make
    /// HRV clinically usable unless the strict continuity and reference gates pass.
    var rrPoints: [RRPoint]? = nil
    /// True only after this session's RMSSD has been compared against an
    /// external RR/IBI reference within the Gate B tolerance.
    var hrvReferenceValidated: Bool?
    /// Diagnostic-only motion/sleep hints extracted from WHOOP `0x32` text
    /// packets while this session was active. These are not validated IMU
    /// metrics and must not raise sleep confidence by themselves.
    var motionHintCount: Int? = nil
    var motionHintKinds: String? = nil
    var motionEvidenceSource: String? = nil
    var motionEvidenceValidated: Bool? = nil
    /// Numeric `motion_short` values observed in diagnostic `0x32` text packets.
    /// These are stored for audit only and are not treated as validated IMU data.
    var motionShortCount: Int? = nil
    var motionShortMean: Double? = nil
    var motionShortMin: Double? = nil
    var motionShortMax: Double? = nil
    var motionShortOverOneCount: Int? = nil
    /// Phone accelerometer audit captured by the cabled Atria app. This can
    /// corroborate that the debug rig was still, but it is not wrist/strap IMU
    /// and must not validate sleep motion by itself.
    var phoneMotionSource: String? = nil
    var phoneMotionValidated: Bool? = nil
    var phoneMotionSamples: Int? = nil
    var phoneMotionMeanDeltaG: Double? = nil
    var phoneMotionMaxDeltaG: Double? = nil
    var phoneMotionOverStillThreshold: Int? = nil
    var phoneMotionStillThresholdG: Double? = nil
    /// Phone pedometer evidence captured locally while the cabled app is
    /// running. This can explain ambulatory activity, but it is phone-side
    /// adjunct evidence and never validates wrist motion or workout export.
    var phoneStepSource: String? = nil
    var phoneStepValidated: Bool? = nil
    var phoneStepCount: Int? = nil
    var phoneStepDistanceMeters: Double? = nil
    var phoneStepFloorsAscended: Int? = nil
    var phoneStepFloorsDescended: Int? = nil
    /// Audit-only HR sample attribution for this saved session. These fields
    /// explain coverage gaps; they do not relax workout or HRV gates.
    var hrRaw2A37: Int? = nil
    var hrAccepted: Int? = nil
    var hrZero: Int? = nil
    var hrArtifactHeld: Int? = nil
    var hrArtifactDropped: Int? = nil
    var hrRawGaps: Int? = nil
    var hrAcceptedGaps: Int? = nil
    var hrMaxRawGap: Double? = nil
    var hrMaxAcceptedGap: Double? = nil

    struct Point: Codable { let t: Double; let bpm: Int }
    struct RRPoint: Codable { let t: Double; let ms: Int }

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var bpms: [Int] { points.map(\.bpm) }
    var rrSampleCount: Int { rrPoints?.count ?? 0 }
    var avg: Int { bpms.isEmpty ? 0 : bpms.reduce(0,+) / bpms.count }
    var peak: Int { bpms.max() ?? 0 }
    var resting: Int { bpms.min() ?? 0 }
    var referenceValidatedHRV: Int? {
        hrvReferenceValidated == true ? hrv : nil
    }
    var localRMSSD: Int? {
        guard let hrv, hrv > 0 else { return nil }
        return hrv
    }
    var referenceValidatedSDNN: Double? {
        guard hrvReferenceValidated == true else { return nil }
        if let hrvSDNN, hrvSDNN > 0 {
            return hrvSDNN
        }
        guard let rrPoints,
              rrPoints.count >= 2 else { return nil }
        let values = rrPoints.map { Double($0.ms) }.filter { (300...2000).contains($0) }
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return sqrt(variance)
    }
    var motionHintCountValue: Int { motionHintCount ?? 0 }
    var motionHintKindsValue: String {
        let trimmed = (motionHintKinds ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "none" : trimmed
    }
    var motionEvidenceSourceValue: String {
        let trimmed = (motionEvidenceSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return motionHintCountValue > 0 ? "diagnostic_observe_only" : "unavailable"
    }
    var motionEvidenceValidatedValue: Bool { motionEvidenceValidated == true }
    var motionShortCountValue: Int { motionShortCount ?? 0 }
    var motionShortOverOneCountValue: Int { motionShortOverOneCount ?? 0 }
    var motionShortMeanValue: Double? { motionShortMean }
    var motionShortMinValue: Double? { motionShortMin }
    var motionShortMaxValue: Double? { motionShortMax }
    var phoneMotionSourceValue: String {
        let trimmed = (phoneMotionSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unavailable" : trimmed
    }
    var phoneMotionValidatedValue: Bool { phoneMotionValidated == true }
    var phoneMotionSamplesValue: Int { phoneMotionSamples ?? 0 }
    var phoneMotionOverStillThresholdValue: Int { phoneMotionOverStillThreshold ?? 0 }
    var phoneStepSourceValue: String {
        let trimmed = (phoneStepSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unavailable" : trimmed
    }
    var phoneStepValidatedValue: Bool { phoneStepValidated == true }
    var phoneStepCountValue: Int { phoneStepCount ?? 0 }
    var hasPhoneStepWorkoutEvidence: Bool {
        duration >= 10 * 60 && phoneStepCountValue >= max(250, Int(duration / 60 * 15))
    }
    var phoneStepEvidenceClause: String? {
        guard phoneStepCountValue > 0 else { return nil }
        let distanceClause = phoneStepDistanceMeters.map { String(format: ", %.0fm", $0) } ?? ""
        return "phone steps \(phoneStepCountValue)\(distanceClause); WHOOP HR/RR remains primary, phone motion is adjunct only"
    }
    var hrRaw2A37Value: Int { hrRaw2A37 ?? 0 }
    var hrAcceptedValue: Int { hrAccepted ?? 0 }
    var hrZeroValue: Int { hrZero ?? 0 }
    var hrArtifactHeldValue: Int { hrArtifactHeld ?? 0 }
    var hrArtifactDroppedValue: Int { hrArtifactDropped ?? 0 }
    var hrRawGapsValue: Int { hrRawGaps ?? 0 }
    var hrAcceptedGapsValue: Int { hrAcceptedGaps ?? 0 }
    var hrMaxRawGapValue: Double { hrMaxRawGap ?? 0 }
    var hrMaxAcceptedGapValue: Double { hrMaxAcceptedGap ?? 0 }

    /// More robust resting estimate than the raw min: the 10th percentile, so a
    /// single low blip doesn't define "resting". Used to train the baseline.
    var restingStable: Int {
        percentileHR(0.10)
    }

    /// Gate E/C fallback for RHR: during an HR-only sleep candidate, use the
    /// 5th percentile to approximate resting HR while avoiding a single-sample
    /// minimum. Motion is not decoded yet, so this remains low-confidence sleep.
    var sleepCandidateRestingHR: Int {
        percentileHR(0.05)
    }

    private func percentileHR(_ percentile: Double) -> Int {
        guard !bpms.isEmpty else { return 0 }
        let s = bpms.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = min(s.count - 1, max(0, Int((Double(s.count - 1) * clamped).rounded(.down))))
        return s[index]
    }

    /// Banister TRIMP for this session (input to the strain score).
    func trimp(rest: Int, max: Int) -> Double {
        Metrics.trimp(points.map { (t: $0.t, bpm: $0.bpm) }, rest: rest, max: max)
    }

    /// Seconds spent in each HR zone, given a max-HR setting.
    func timeInZone(maxHR: Int) -> [HRZone: Double] {
        guard points.count > 1 else { return [:] }
        var out: [HRZone: Double] = [:]
        for i in 1..<points.count {
            let dt = points[i].t - points[i-1].t
            let z = HRZone.zone(for: points[i].bpm, maxHR: maxHR)
            out[z, default: 0] += max(0, dt)
        }
        return out
    }

    var durationText: String {
        let s = Int(duration)
        return s >= 60 ? "\(s/60)m \(s%60)s" : "\(s)s"
    }
}

struct ActivityDetection: Identifiable, Equatable {
    enum Kind: String {
        case activityCandidate = "Activity candidate"
        case workout = "Workout"
        case sleepCandidate = "Sleep candidate"
        case restCandidate = "Rest candidate"
    }

    enum Confidence: String {
        case low
        case medium
        case high
    }

    let id: UUID
    let kind: Kind
    let confidence: Confidence
    let start: Date
    let end: Date
    let duration: TimeInterval
    let avgHR: Int
    let peakHR: Int
    let reason: String
}

struct WorkoutReadiness {
    let duration: TimeInterval
    let observedDuration: TimeInterval
    let avgHR: Int
    let peakHR: Int
    let p90HR: Int
    let p95HR: Int
    let p99HR: Int
    let thresholdHR: Int
    let thresholdGapBPM: Int
    let samplesAboveThreshold: Int
    let samplesAboveBorderline: Int
    let elevatedSeconds: TimeInterval
    let elevatedFraction: Double
    let longestElevatedBout: TimeInterval
    let borderlineThresholdHR: Int
    let borderlineElevatedSeconds: TimeInterval
    let borderlineLongestBout: TimeInterval
    let borderlineElevatedFraction: Double
    let requiredElevatedSeconds: TimeInterval
    let requiredElevatedBout: TimeInterval
    let droppedGapSeconds: TimeInterval
    let maxSampleGap: TimeInterval
    let gapCount: Int
    let streamCoveragePercent: Int
    let primaryBlocker: String
    let avgOverRest: Int
    let peakOverRest: Int
    let ready: Bool

    var status: String {
        ready ? "ready" : "learning"
    }

    var streamBlocked: Bool {
        primaryBlocker.contains("stream_gaps") || streamCoveragePercent < 75
    }

    var nearMiss: Bool {
        guard !ready else { return false }
        let enoughObservedData = observedDuration >= 10 * 60
        let enoughSparseCoverageToInspect = streamCoveragePercent >= 20
        let closeToThreshold = thresholdGapBPM <= 5 || elevatedSeconds > 0
        return enoughObservedData && enoughSparseCoverageToInspect && closeToThreshold
    }

    var nearMissReason: String {
        guard nearMiss else { return "none" }
        var reasons: [String] = []
        if streamBlocked {
            reasons.append("stream_coverage_low")
        }
        if thresholdGapBPM > 0 {
            reasons.append("peak_within_\(thresholdGapBPM)_bpm_below_threshold")
        }
        if elevatedSeconds < requiredElevatedSeconds {
            reasons.append("elevated_seconds_below_required")
        }
        if longestElevatedBout < requiredElevatedBout {
            reasons.append("continuous_bout_below_required")
        }
        return reasons.isEmpty ? "near_miss_low_confidence" : reasons.joined(separator: "+")
    }

    var strengthCandidate: Bool {
        guard !ready else { return false }
        guard observedDuration >= 10 * 60, streamCoveragePercent >= 20 else { return false }
        let closeToWorkoutBand = thresholdGapBPM <= 5 || elevatedSeconds > 0
        let hasBorderlineEvidence = borderlineElevatedSeconds >= 30 || borderlineLongestBout >= 10
        return closeToWorkoutBand && hasBorderlineEvidence
    }

    var strengthCandidateReason: String {
        guard strengthCandidate else { return "none" }
        var reasons = ["diagnostic_only"]
        if streamBlocked {
            reasons.append("stream_gaps_prevent_count")
        }
        if thresholdGapBPM > 0 {
            reasons.append("peak_within_\(thresholdGapBPM)_bpm_below_hrr50")
        }
        if borderlineElevatedSeconds > 0 {
            reasons.append("borderline_hr_band_\(Int(borderlineElevatedSeconds.rounded()))s")
        }
        if elevatedSeconds < requiredElevatedSeconds {
            reasons.append("workout_band_time_insufficient")
        }
        if longestElevatedBout < requiredElevatedBout {
            reasons.append("continuous_bout_insufficient")
        }
        return reasons.joined(separator: "+")
    }

    var hrDistributionBelowWorkoutBand: Bool {
        guard !ready, thresholdHR > 0 else { return false }
        return p95HR < thresholdHR && elevatedSeconds < 60
    }

    var nextAction: String {
        if ready { return "count_workout" }
        if strengthCandidate {
            return "observe_strength_signal_without_counting_and_validate_hr_reference"
        }
        let hasStreamGap = streamBlocked
        let needsHRReference = peakHR < thresholdHR
        if hasStreamGap && needsHRReference {
            return "fix_stream_continuity_and_validate_intensity"
        }
        if hasStreamGap {
            return "fix_stream_continuity_before_counting"
        }
        if needsHRReference {
            return "validate_intensity_with_reference_or_profile"
        }
        if hrDistributionBelowWorkoutBand {
            return "validate_wrist_hr_underreporting_or_profile_before_more_workouts"
        }
        if elevatedSeconds < requiredElevatedSeconds || longestElevatedBout < requiredElevatedBout {
            return "keep_learning_until_sustained_hr"
        }
        return "inspect_detector_inputs"
    }

    var reason: String {
        if observedDuration < 10 * 60 {
            if gapCount > 0 {
                return "observed_duration_below_10m_stream_gaps"
            }
            return "duration_below_10m"
        }
        if elevatedSeconds < requiredElevatedSeconds {
            return "elevated_seconds_below_required"
        }
        if longestElevatedBout < requiredElevatedBout {
            return "elevated_bout_below_required"
        }
        return ready ? "sustained_elevated_hr" : "detector_not_workout"
    }
}

struct DailyRollup {
    let day: Date
    let sessions: Int
    let activityCandidates: Int
    let workouts: Int
    let confirmedWorkouts: Int
    let restCandidates: Int
    let sleepReady: Int
    let sleepCandidates: Int
    let duration: TimeInterval
    let strain: Double
    let avgHRV: Int?
    let restingHR: Int?
    let avgRespiratoryRate: Double?
}

struct UserConfirmedWorkout: Codable, Identifiable, Equatable {
    let id: String
    let createdAt: Date
    let start: Date
    let end: Date
    let label: String
    let source: String
    let confidence: String
    let sessions: Int
    let samples: Int
    let avgHR: Int
    let peakHR: Int
    let p95HR: Int
    let p99HR: Int
    let thresholdHR: Int
    let streamCoveragePercent: Int
    let observedDuration: TimeInterval
    let reason: String

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct UserConfirmedSleep: Codable, Identifiable, Equatable {
    let id: String
    let createdAt: Date
    let start: Date
    let end: Date
    let source: String
    let confidence: String
    let sessions: Int
    let samples: Int
    let avgHR: Int
    let peakHR: Int
    let restingHR: Int
    let duration: TimeInterval
    let span: TimeInterval
    let reason: String
    let motionSource: String
    let motionValidated: Bool
}

struct BehaviorJournalEntry: Codable, Identifiable, Equatable {
    enum Tag: String, Codable, CaseIterable, Identifiable {
        case sleep
        case alcohol
        case caffeine
        case training
        case stress

        var id: String { rawValue }

        var label: String {
            switch self {
            case .sleep: return "Sleep"
            case .alcohol: return "Alcohol"
            case .caffeine: return "Caffeine"
            case .training: return "Training"
            case .stress: return "Stress"
            }
        }
    }

    let id: String
    let day: Date
    let createdAt: Date
    var tags: [Tag]
}

struct BehaviorCorrelationSummary: Equatable {
    let tag: BehaviorJournalEntry.Tag
    let days: Int
    let recoveryDelta: Double?
    let hrvDelta: Double?

    var recoveryText: String {
        recoveryDelta.map { String(format: "%+.0f%%", $0) } ?? "Learning"
    }

    var hrvText: String {
        hrvDelta.map { String(format: "%+.0f ms", $0) } ?? "Learning"
    }

    var detail: String {
        guard recoveryDelta != nil || hrvDelta != nil else {
            return "\(days) tagged days"
        }
        return "\(days) tagged days · local correlation"
    }
}

struct GateEWorkoutTrainingStatus: Equatable {
    let present: Bool
    let confirmedID: String
    let source: String
    let confidence: String
    let autoReady: Bool
    let autoStatus: String
    let autoReason: String
    let primaryBlocker: String
    let nextAction: String
    let samples: Int
    let overlap: TimeInterval
    let duration: TimeInterval
    let observedDuration: TimeInterval
    let streamCoveragePercent: Int
    let peakHR: Int
    let p95HR: Int
    let p99HR: Int
    let thresholdHR: Int
    let thresholdGapBPM: Int
    let restHR: Int
    let profileMaxHR: Int
    let requiredProfileMaxHRForP95AtHRR50: Int
    let requiredProfileMaxHRForP99AtHRR50: Int
    let requiredProfileMaxHRForPeakAtHRR50: Int
    let elevatedSeconds: TimeInterval
    let requiredElevatedSeconds: TimeInterval
    let longestBout: TimeInterval
    let requiredBout: TimeInterval

    static let missing = GateEWorkoutTrainingStatus(present: false,
                                                    confirmedID: "none",
                                                    source: "none",
                                                    confidence: "none",
                                                    autoReady: false,
                                                    autoStatus: "learning",
                                                    autoReason: "no_confirmed_workout",
                                                    primaryBlocker: "no_confirmed_workout",
                                                    nextAction: "confirm_or_capture_workout",
                                                    samples: 0,
                                                    overlap: 0,
                                                    duration: 0,
                                                    observedDuration: 0,
                                                    streamCoveragePercent: 0,
                                                    peakHR: 0,
                                                    p95HR: 0,
                                                    p99HR: 0,
                                                    thresholdHR: 0,
                                                    thresholdGapBPM: 0,
                                                    restHR: 0,
                                                    profileMaxHR: 0,
                                                    requiredProfileMaxHRForP95AtHRR50: 0,
                                                    requiredProfileMaxHRForP99AtHRR50: 0,
                                                    requiredProfileMaxHRForPeakAtHRR50: 0,
                                                    elevatedSeconds: 0,
                                                    requiredElevatedSeconds: 0,
                                                    longestBout: 0,
                                                    requiredBout: 0)
}

struct GateESleepTrainingStatus: Equatable {
    let present: Bool
    let confirmedID: String
    let source: String
    let confidence: String
    let autoReady: Bool
    let autoReason: String
    let matchedSource: String
    let overlap: TimeInterval
    let duration: TimeInterval
    let span: TimeInterval
    let candidateDuration: TimeInterval
    let candidateSpan: TimeInterval
    let avgHR: Int
    let peakHR: Int
    let sleepRHR: Int
    let motionSource: String
    let motionValidated: Bool
    let motionHints: Int
    let historicalMotionStatus: String
    let fallbackAccepted: Bool
    let fallbackPolicy: String

    static let missing = GateESleepTrainingStatus(present: false,
                                                  confirmedID: "none",
                                                  source: "none",
                                                  confidence: "none",
                                                  autoReady: false,
                                                  autoReason: "no_confirmed_sleep",
                                                  matchedSource: "none",
                                                  overlap: 0,
                                                  duration: 0,
                                                  span: 0,
                                                  candidateDuration: 0,
                                                  candidateSpan: 0,
                                                  avgHR: 0,
                                                  peakHR: 0,
                                                  sleepRHR: 0,
                                                  motionSource: "unavailable",
                                                  motionValidated: false,
                                                  motionHints: 0,
                                                  historicalMotionStatus: "none",
                                                  fallbackAccepted: false,
                                                  fallbackPolicy: "none")
}

struct GateETrainingSummary: Equatable {
    let workout: GateEWorkoutTrainingStatus
    let sleep: GateESleepTrainingStatus

    var hasConfirmedEvidence: Bool {
        workout.present || sleep.present
    }

    var autoReady: Bool {
        workout.autoReady && sleep.autoReady
    }

    var primaryBlocker: String {
        if autoReady { return "none" }
        var blockers: [String] = []
        if !sleep.autoReady { blockers.append("sleep_\(sleep.autoReason)") }
        if !workout.autoReady { blockers.append("workout_\(compactWorkoutBlocker)") }
        return blockers.isEmpty ? "no_confirmed_training_evidence" : blockers.joined(separator: "+")
    }

    var workoutProofNeeded: String {
        guard workout.present else { return "confirm_or_capture_workout" }
        guard !workout.autoReady else { return "none" }
        if workoutCoverageAndIntensityBlocked {
            return "capture_clean_hrr50_or_validate_received_hr"
        }
        if workoutCoverageBlocked {
            return "capture_clean_sustained_hrr50_with_stream_coverage"
        }
        if workout.elevatedSeconds < workout.requiredElevatedSeconds {
            return "capture_sustained_hrr50_elevated_time"
        }
        if workout.longestBout < workout.requiredBout {
            return "capture_single_hrr50_bout"
        }
        if workout.thresholdGapBPM <= 0 {
            return "validate_hr_reference_or_profile_hrmax"
        }
        return "validate_workout_detector_inputs"
    }

    var workoutProofStatus: String {
        guard workout.present else { return "confirm_or_capture_workout" }
        guard !workout.autoReady else { return "auto_workout_ready" }
        if workoutCoverageAndIntensityBlocked {
            return "needs_stream_coverage_\(workoutCoverageTargetPercent)p_missing_\(workoutCoverageMissingPercent)p+needs_sustained_hrr50_\(workoutElevatedMissingSeconds)s"
        }
        if workoutCoverageBlocked {
            return "needs_stream_coverage_75p_missing_\(workoutCoverageMissingPercent)p"
        }
        if workout.thresholdGapBPM > 0 {
            return "needs_hrr50_plus_\(workout.thresholdGapBPM)bpm"
        }
        if workout.elevatedSeconds < workout.requiredElevatedSeconds {
            return "needs_elevated_\(workoutElevatedMissingSeconds)s"
        }
        if workout.longestBout < workout.requiredBout {
            return "needs_single_bout_\(workoutBoutMissingSeconds)s"
        }
        return "validate_workout_detector_inputs"
    }

    var workoutElevatedMissingSeconds: Int {
        max(0, Int((workout.requiredElevatedSeconds - workout.elevatedSeconds).rounded(.up)))
    }

    var workoutBoutMissingSeconds: Int {
        max(0, Int((workout.requiredBout - workout.longestBout).rounded(.up)))
    }

    var workoutCoverageMissingPercent: Int {
        max(0, 75 - workout.streamCoveragePercent)
    }

    var workoutObservedTargetSeconds: Int {
        600
    }

    var workoutObservedSeconds: Int {
        Int(workout.observedDuration.rounded())
    }

    var workoutObservedMissingSeconds: Int {
        max(0, workoutObservedTargetSeconds - workoutObservedSeconds)
    }

    var workoutCoverageTargetPercent: Int {
        75
    }

    var workoutCoverageBlocked: Bool {
        workout.streamCoveragePercent < workoutCoverageTargetPercent || workout.primaryBlocker.contains("stream_gaps")
    }

    var workoutIntensityEvidenceMissing: Bool {
        guard workout.present, !workout.autoReady else { return false }
        guard workoutObservedMissingSeconds == 0 else { return false }
        let receivedHRMostlyBelowWorkoutBand = workout.p95HR < workout.thresholdHR
        return receivedHRMostlyBelowWorkoutBand
            || workoutElevatedMissingSeconds > 0
            || workoutBoutMissingSeconds > 0
    }

    var workoutCoverageAndIntensityBlocked: Bool {
        workoutCoverageBlocked && workoutIntensityEvidenceMissing
    }

    var workoutElevatedSeconds: Int {
        Int(workout.elevatedSeconds.rounded())
    }

    var workoutElevatedTargetSeconds: Int {
        Int(workout.requiredElevatedSeconds.rounded())
    }

    var workoutBoutSeconds: Int {
        Int(workout.longestBout.rounded())
    }

    var workoutBoutTargetSeconds: Int {
        Int(workout.requiredBout.rounded())
    }

    var workoutThresholdProgress: String {
        "\(workout.peakHR)/\(workout.thresholdHR)bpm"
    }

    var workoutP95GapBPM: Int {
        max(0, workout.thresholdHR - workout.p95HR)
    }

    var workoutPeakGapBPM: Int {
        max(0, workout.thresholdHR - workout.peakHR)
    }

    var workoutProfileMaxLoweringForP95BPM: Int {
        guard workout.profileMaxHR > 0, workout.requiredProfileMaxHRForP95AtHRR50 > 0 else { return 0 }
        return max(0, workout.profileMaxHR - workout.requiredProfileMaxHRForP95AtHRR50)
    }

    var workoutProfileSensitivityProof: String {
        guard workout.present else { return "missing_confirmed_workout" }
        guard !workout.autoReady else { return "none" }
        if workout.p95HR < workout.thresholdHR {
            return "profile_fix_would_require_maxhr_\(workout.requiredProfileMaxHRForP95AtHRR50)_current_\(workout.profileMaxHR)_lower_by_\(workoutProfileMaxLoweringForP95BPM)bpm"
        }
        if workout.p99HR < workout.thresholdHR {
            return "profile_fix_would_require_maxhr_\(workout.requiredProfileMaxHRForP99AtHRR50)_current_\(workout.profileMaxHR)"
        }
        if workout.peakHR < workout.thresholdHR {
            return "profile_fix_would_require_maxhr_\(workout.requiredProfileMaxHRForPeakAtHRR50)_current_\(workout.profileMaxHR)"
        }
        return "profile_not_primary_blocker"
    }

    var workoutIntensityProof: String {
        guard workout.present else { return "missing_confirmed_workout" }
        guard !workout.autoReady else { return "none" }
        if workout.p95HR < workout.thresholdHR {
            return "received_hr_p95_\(workout.p95HR)_below_threshold_\(workout.thresholdHR)_by_\(workoutP95GapBPM)bpm"
        }
        if workoutElevatedMissingSeconds > 0 || workoutBoutMissingSeconds > 0 {
            return "received_hr_not_sustained_hrr50"
        }
        if workout.thresholdGapBPM > 0 {
            return "peak_hr_below_threshold_by_\(workoutPeakGapBPM)bpm"
        }
        return "review_detector_inputs"
    }

    var workoutProofProgress: String {
        guard workout.present else { return "missing_confirmed_workout" }
        return "coverage_\(workout.streamCoveragePercent)_of_\(workoutCoverageTargetPercent)+observed_\(workoutObservedSeconds)_of_\(workoutObservedTargetSeconds)+elevated_\(workoutElevatedSeconds)_of_\(workoutElevatedTargetSeconds)+bout_\(workoutBoutSeconds)_of_\(workoutBoutTargetSeconds)+peak_\(workout.peakHR)_of_\(workout.thresholdHR)"
    }

    var workoutProofNextStep: String {
        guard workout.present else { return "capture_or_confirm_workout" }
        guard !workout.autoReady else { return "none" }
        if workoutCoverageAndIntensityBlocked {
            return "keep_phone_near_strap_and_validate_received_hr_intensity"
        }
        if workoutCoverageBlocked {
            return "keep_phone_near_strap_until_coverage_75p"
        }
        if workoutObservedMissingSeconds > 0 {
            return "capture_at_least_10m_observed_data"
        }
        if workoutElevatedMissingSeconds > 0 {
            return "sustain_hrr50_until_elevated_target"
        }
        if workoutBoutMissingSeconds > 0 {
            return "hold_one_continuous_hrr50_bout"
        }
        if workout.thresholdGapBPM > 0 {
            return "validate_hr_reference_or_profile_hrmax"
        }
        return "review_detector_inputs"
    }

    var workoutProofReadyIf: String {
        guard workout.present else { return "confirm_workout" }
        guard !workout.autoReady else { return "none" }
        return "coverage>=75+observed>=600+elevated>=\(Int(workout.requiredElevatedSeconds.rounded()))+bout>=\(Int(workout.requiredBout.rounded()))+hr>=\(workout.thresholdHR)"
    }

    var sleepProofNeeded: String {
        guard sleep.present else { return "confirm_or_capture_sleep" }
        guard !sleep.autoReady else { return "none" }
        if sleep.fallbackAccepted { return "none" }
        if !sleep.motionValidated {
            if sleep.historicalMotionStatus.contains("stale") {
                return "refresh_or_decode_wrist_motion_archive"
            }
            if sleep.motionSource == "unavailable" {
                return "decode_wrist_motion_or_label_hr_only_sleep_fallback"
            }
            return "validate_sleep_motion_confidence"
        }
        if sleep.candidateDuration < 10_800 {
            return "capture_overnight_low_hr_3h_total"
        }
        return "validate_sleep_detector_inputs"
    }

    var nextProof: String {
        if autoReady { return "none" }
        var items: [String] = []
        if sleepProofNeeded != "none" { items.append("sleep:\(sleepProofNeeded)") }
        if workoutProofNeeded != "none" { items.append("workout:\(workoutProofNeeded)") }
        return items.isEmpty ? "no_confirmed_training_evidence" : items.joined(separator: "+")
    }

    var compactSleepBlocker: String {
        if !sleep.present { return "missing_confirmed_sleep" }
        if sleep.autoReady { return "ready" }
        if sleep.fallbackAccepted { return "hr_only_fallback_labeled" }
        if !sleep.motionValidated { return "motion_unvalidated" }
        if sleep.candidateDuration < 10_800 { return "low_hr_total_below_3h" }
        return "detector_inputs"
    }

    var sleepProofStatus: String {
        if sleep.autoReady { return "auto_sleep_ready" }
        if sleep.fallbackAccepted { return sleep.fallbackPolicy }
        return sleepProofNeeded
    }

    var compactWorkoutBlocker: String {
        if !workout.present { return "missing_confirmed_workout" }
        if workout.autoReady { return "ready" }
        if workoutCoverageAndIntensityBlocked {
            return "stream_gaps+intensity_unvalidated"
        }
        if workoutCoverageBlocked {
            return "stream_gaps"
        }
        if workout.elevatedSeconds < workout.requiredElevatedSeconds {
            return "elevated_time_below_required"
        }
        if workout.longestBout < workout.requiredBout {
            return "bout_below_required"
        }
        return workout.primaryBlocker
    }
}

struct SavedWorkoutAttemptStatus: Equatable {
    let source: String
    let label: String
    let chunks: Int
    let status: String
    let reason: String
    let primaryBlocker: String
    let nearMiss: Bool
    let nearMissReason: String
    let streamCoveragePercent: Int
    let duration: TimeInterval
    let observedDuration: TimeInterval
    let droppedGapSeconds: TimeInterval
    let maxSampleGap: TimeInterval
    let gapCount: Int
    let peakHR: Int
    let p95HR: Int
    let p99HR: Int
    let thresholdHR: Int
    let thresholdGapBPM: Int
    let samplesAboveThreshold: Int
    let samplesAboveBorderline: Int
    let elevatedSeconds: TimeInterval
    let requiredElevatedSeconds: TimeInterval
    let longestBout: TimeInterval
    let requiredBout: TimeInterval
    let borderlineThresholdHR: Int
    let borderlineElevatedSeconds: TimeInterval
    let borderlineLongestBout: TimeInterval
    let hrDistributionBelowWorkoutBand: Bool
    let restHR: Int
    let profileMaxHR: Int
    let requiredProfileMaxHRForP95AtHRR50: Int
    let requiredProfileMaxHRForP99AtHRR50: Int
    let requiredProfileMaxHRForPeakAtHRR50: Int
    let currentProfileMinusP99RequiredBPM: Int
    let ready: Bool

    var streamBlocked: Bool {
        primaryBlocker.contains("stream_gaps") || streamCoveragePercent < 75
    }

    var strengthCandidate: Bool {
        guard !ready else { return false }
        guard observedDuration >= 10 * 60, streamCoveragePercent >= 20 else { return false }
        let closeToWorkoutBand = thresholdGapBPM <= 5 || elevatedSeconds > 0
        let hasBorderlineEvidence = borderlineElevatedSeconds >= 30 || borderlineLongestBout >= 10
        return closeToWorkoutBand && hasBorderlineEvidence
    }

    var strengthCandidateReason: String {
        guard strengthCandidate else { return "none" }
        var reasons = ["diagnostic_only"]
        if streamBlocked {
            reasons.append("stream_gaps_prevent_count")
        }
        if thresholdGapBPM > 0 {
            reasons.append("peak_within_\(thresholdGapBPM)_bpm_below_hrr50")
        }
        if borderlineElevatedSeconds > 0 {
            reasons.append("borderline_hr_band_\(Int(borderlineElevatedSeconds.rounded()))s")
        }
        if elevatedSeconds < requiredElevatedSeconds {
            reasons.append("workout_band_time_insufficient")
        }
        if longestBout < requiredBout {
            reasons.append("continuous_bout_insufficient")
        }
        return reasons.joined(separator: "+")
    }

    var captureDiagnosis: String {
        if source == "none" { return "no_saved_session" }
        if ready { return "valid_workout_candidate" }
        if streamBlocked && peakHR < thresholdHR {
            return "fragmented_stream_and_below_threshold"
        }
        if streamBlocked {
            return "fragmented_stream"
        }
        if peakHR < thresholdHR {
            return "received_hr_below_threshold"
        }
        if hrDistributionBelowWorkoutBand {
            return "wrist_hr_distribution_below_workout_band"
        }
        if elevatedSeconds < requiredElevatedSeconds {
            return "insufficient_elevated_time"
        }
        if longestBout < requiredBout {
            return "insufficient_continuous_bout"
        }
        return primaryBlocker
    }

    var captureAction: String {
        if strengthCandidate {
            return "observe_strength_signal_without_counting"
        }
        switch captureDiagnosis {
        case "valid_workout_candidate":
            return "count_workout"
        case "no_saved_session":
            return "collect_saved_hr_session"
        case "fragmented_stream_and_below_threshold":
            return "fix_continuity_then_validate_hr_intensity"
        case "fragmented_stream":
            return "fix_continuity_before_counting_workout"
        case "received_hr_below_threshold":
            return "keep_learning_or_validate_expected_hr_with_reference"
        case "wrist_hr_distribution_below_workout_band":
            return "validate_wrist_hr_underreporting_or_profile_before_more_workouts"
        case "insufficient_elevated_time", "insufficient_continuous_bout":
            return "keep_learning_until_sustained_elevated_hr"
        default:
            return "inspect_saved_workout_evidence"
        }
    }

    var p99HRRPercent: Int {
        let reserve = max(profileMaxHR - restHR, 0)
        guard reserve > 0 else { return 0 }
        return Int((Double(p99HR - restHR) / Double(reserve) * 100).rounded())
    }

    var hrComparisonNeed: String {
        if ready { return "workout_ready" }
        if source == "none" { return "need_saved_hr_session" }
        if p99HR < thresholdHR { return "p99_below_hrr50_validate_wrist_hr" }
        if elevatedSeconds < requiredElevatedSeconds { return "insufficient_sustained_hrr50_time" }
        if longestBout < requiredBout { return "insufficient_continuous_hrr50_bout" }
        if streamBlocked { return "stream_continuity_validation_needed" }
        return "inspect_detector_inputs"
    }

    var hrComparisonAction: String {
        switch hrComparisonNeed {
        case "workout_ready":
            return "count_workout_after_gate_status"
        case "need_saved_hr_session":
            return "record_next_workout_with_atria"
        case "p99_below_hrr50_validate_wrist_hr":
            return "compare_next_workout_to_independent_hr_reference"
        case "insufficient_sustained_hrr50_time", "insufficient_continuous_hrr50_bout":
            return "collect_sustained_elevated_hr_or_reference"
        case "stream_continuity_validation_needed":
            return "fix_hr_stream_gaps_before_counting"
        default:
            return "inspect_saved_workout_evidence"
        }
    }

    static let empty = SavedWorkoutAttemptStatus(source: "none",
                                                 label: "none",
                                                 chunks: 0,
                                                 status: "learning",
                                                 reason: "no_saved_session",
                                                 primaryBlocker: "no_saved_session",
                                                 nearMiss: false,
                                                 nearMissReason: "none",
                                                 streamCoveragePercent: 0,
                                                 duration: 0,
                                                 observedDuration: 0,
                                                 droppedGapSeconds: 0,
                                                 maxSampleGap: 0,
                                                 gapCount: 0,
                                                 peakHR: 0,
                                                 p95HR: 0,
                                                 p99HR: 0,
                                                 thresholdHR: 0,
                                                 thresholdGapBPM: 0,
                                                 samplesAboveThreshold: 0,
                                                 samplesAboveBorderline: 0,
                                                 elevatedSeconds: 0,
                                                 requiredElevatedSeconds: 0,
                                                 longestBout: 0,
                                                 requiredBout: 0,
                                                 borderlineThresholdHR: 0,
                                                 borderlineElevatedSeconds: 0,
                                                 borderlineLongestBout: 0,
                                                 hrDistributionBelowWorkoutBand: false,
                                                 restHR: 0,
                                                 profileMaxHR: 0,
                                                 requiredProfileMaxHRForP95AtHRR50: 0,
                                                 requiredProfileMaxHRForP99AtHRR50: 0,
                                                 requiredProfileMaxHRForPeakAtHRR50: 0,
                                                 currentProfileMinusP99RequiredBPM: 0,
                                                 ready: false)
}

struct BaselineLearningEvidence {
    let value: Int
    let source: String
    let accepted: Bool
    let reason: String
}

struct AggregateSleepCandidate {
    static let strictMinimumDuration: TimeInterval = 3 * 60 * 60
    static let fragmentedMinimumDuration: TimeInterval = 2.5 * 60 * 60
    static let fragmentedMinimumSpan: TimeInterval = 3 * 60 * 60

    let day: Date
    let sessions: Int
    let start: Date
    let end: Date
    let duration: TimeInterval
    let span: TimeInterval
    let maxGap: TimeInterval
    let samples: Int
    let avgHR: Int
    let peakHR: Int
    let restingHR: Int
    let confidence: ActivityDetection.Confidence
    let reason: String
    let motionHintCount: Int
    let motionHintKinds: String
    let motionEvidenceSource: String
    let motionEvidenceValidated: Bool
    let motionShortCount: Int
    let motionShortMean: Double?
    let motionShortMin: Double?
    let motionShortMax: Double?
    let motionShortOverOneCount: Int
    let historicalMotionStatus: String
    let historicalMotionReason: String
    let historicalMotionRows: Int
    let historicalMotionValidatedRows: Int
    let historicalMotionCoverageSeconds: Int
    let historicalMotionMeanVectorDelta: Double?
    let historicalMotionP95VectorDelta: Double?
    let historicalMotionMagnitudeStdDev: Double?
    let historicalMotionArchiveFirstUnix: Int
    let historicalMotionArchiveLastUnix: Int
    let historicalMotionNearestSeparationSeconds: Int
    let historicalMotionValidated: Bool
}

struct SleepEvidenceStatus {
    let ready: Bool
    let state: String
    let blocker: String
    let confidence: String
    let candidates: Int
    let readyCandidates: Int
    let motionSource: String
    let motionValidated: Bool
    let fallbackAvailable: Bool
    let fallbackSource: String
    let fallbackReason: String
    let fallbackDuration: TimeInterval
    let fallbackSpan: TimeInterval
    let fallbackSessions: Int
}

struct CurrentCollectionStatus {
    let ready: Bool
    let source: String
    let blocker: String
    let label: String
    let samples: Int
    let rrValues: Int
    let ageSeconds: Int
    let durationSeconds: Int

    var evidence: String {
        "current_collection_ready=\(ready ? 1 : 0); current_collection_source=\(source); current_collection_blocker=\(blocker); current_collection_label=\(label); current_collection_samples=\(samples); current_collection_rr_values=\(rrValues); current_collection_age_s=\(ageSeconds); current_collection_duration_s=\(durationSeconds); current_collection_metric_promotions=0"
    }
}

struct AggregateWorkoutCandidate {
    let id: UUID
    let source: String
    let day: Date
    let sessions: Int
    let labels: [String]
    let label: String
    let start: Date
    let end: Date
    let duration: TimeInterval
    let span: TimeInterval
    let samples: Int
    let avgHR: Int
    let peakHR: Int
    let hrRaw2A37: Int
    let hrAccepted: Int
    let hrZero: Int
    let hrArtifactHeld: Int
    let hrArtifactDropped: Int
    let hrRawGaps: Int
    let hrAcceptedGaps: Int
    let hrMaxRawGap: TimeInterval
    let hrMaxAcceptedGap: TimeInterval
    let readiness: WorkoutReadiness
}

struct TrendSummary: Identifiable, Equatable {
    enum Window: Int, CaseIterable {
        case seven = 7
        case thirty = 30
        case ninety = 90
    }

    let id: Int
    let days: Int
    let sessions: Int
    let coverageDays: Int
    let requiredCoverageDays: Int
    let coveragePercent: Int
    let confidence: String
    let avgRecovery: Int?
    let avgHRV: Int?
    let avgRHR: Int?
    let avgStrain: Double?
    let avgRespiratoryRate: Double?
    let anomalies: [String]
    let anomalySource: String
    let anomalySampleDays: Int
    let hrvState: String
    let detail: String
    let blockers: String
}

struct TrainingLoadSummary: Equatable {
    let acuteLoad: Double
    let chronicLoad: Double
    let ratio: Double?
    let confidence: String
    let targetBand: ClosedRange<Double>?
    let detail: String

    var ratioText: String {
        ratio.map { String(format: "%.2f", $0) } ?? "Learning"
    }

    var targetBandText: String {
        guard let targetBand else { return "Learning" }
        return String(format: "%.1f-%.1f", targetBand.lowerBound, targetBand.upperBound)
    }
}

struct VO2MaxEstimateSummary: Equatable {
    let value: Double?
    let confidence: String
    let detail: String
    let narrative: String

    var valueText: String {
        value.map { String(format: "%.1f", $0) } ?? "Learning"
    }
}

private struct RRLedgerReplaySummary {
    let sessionsWithRR: Int
    let rrSamples: Int
    let bestReady: Bool
    let bestSessionLabel: String
    let bestRaw: Int
    let bestKept: Int
    let bestConfidencePercent: Int
    let bestWindowSeconds: TimeInterval
    let bestMaxRRGapSeconds: TimeInterval
    let bestRejectedOutOfRange: Int
    let bestRejectedDeltaOver20Percent: Int
    let bestInterpolated: Int
    let bestRMSSD: Double?
    let bestSDNN: Double?
    let bestPNN50: Double?
    let bestLnRMSSD: Double?
    let bestRespiratoryRate: Double?
    let reason: String

    static let empty = RRLedgerReplaySummary(sessionsWithRR: 0,
                                             rrSamples: 0,
                                             bestReady: false,
                                             bestSessionLabel: "none",
                                             bestRaw: 0,
                                             bestKept: 0,
                                             bestConfidencePercent: 0,
                                             bestWindowSeconds: 0,
                                             bestMaxRRGapSeconds: 0,
                                             bestRejectedOutOfRange: 0,
                                             bestRejectedDeltaOver20Percent: 0,
                                             bestInterpolated: 0,
                                             bestRMSSD: nil,
                                             bestSDNN: nil,
                                             bestPNN50: nil,
                                             bestLnRMSSD: nil,
                                             bestRespiratoryRate: nil,
                                             reason: "no_saved_rr")
}

private struct RRSavedReferenceWindow {
    let session: SavedSession
    let samples: [(t: Date, ms: Double)]
    let snapshot: HRVSnapshot
    let strictGap: TimeInterval
    let windowStart: Date
    let windowEnd: Date
    let ready: Bool
    let reason: String
}

private struct ExternalRRPoint {
    let t: TimeInterval
    let ms: Double
}

private struct ExternalHRSample {
    let t: TimeInterval
    let bpm: Double
}

private struct RRReferenceScore {
    let raw: Int
    let kept: Int
    let confidencePercent: Int
    let duration: TimeInterval
    let maxGap: TimeInterval
    let rmssd: Double?
    let ready: Bool
    let reason: String
}

private struct HRReferenceComparison {
    let pairs: Int
    let duration: TimeInterval
    let meanDelta: Double?
    let medianDelta: Double?
    let maxDelta: Double?
    let withinTolerancePercent: Int
    let ready: Bool
    let reason: String
}

struct CSVHRReferenceDiagnostics: Equatable {
    let status: String
    let reason: String
    let validated: Bool
    let source: String
    let pairs: Int
    let referenceSamples: Int
    let duration: TimeInterval
    let meanDelta: Double?
    let medianDelta: Double?
    let maxDelta: Double?
    let withinTolerancePercent: Int
}

struct RRPackageStatus: Equatable {
    let ready: Bool
    let reason: String
    let sessionsWithRR: Int
    let rrSamples: Int
    let bestLabel: String
    let raw: Int
    let kept: Int
    let confidencePercent: Int
    let maxGapSeconds: TimeInterval
    let rmssd: Double?

    static let empty = RRPackageStatus(ready: false,
                                       reason: "no_saved_rr",
                                       sessionsWithRR: 0,
                                       rrSamples: 0,
                                       bestLabel: "none",
                                       raw: 0,
                                       kept: 0,
                                       confidencePercent: 0,
                                       maxGapSeconds: 0,
                                       rmssd: nil)
}

private struct HRSavedReferenceSession {
    let session: SavedSession
    let samples: [SavedSession.Point]
}

private struct WorkoutReplaySummary {
    let rawSessions: Int
    let canonicalSessions: Int
    let sessionsEvaluated: Int
    let readySessions: Int
    let bestSource: String
    let bestChunkCount: Int
    let bestStart: Date?
    let bestEnd: Date?
    let bestSpan: TimeInterval
    let bestLabel: String
    let bestStatus: String
    let bestReason: String
    let bestDuration: TimeInterval
    let bestObservedDuration: TimeInterval
    let bestSamples: Int
    let bestAvgHR: Int
    let bestPeakHR: Int
    let bestP95HR: Int
    let bestP99HR: Int
    let bestThresholdHR: Int
    let bestThresholdGapBPM: Int
    let bestSamplesAboveThreshold: Int
    let bestSamplesAboveBorderline: Int
    let bestElevatedSeconds: TimeInterval
    let bestRequiredElevatedSeconds: TimeInterval
    let bestLongestBout: TimeInterval
    let bestRequiredBout: TimeInterval
    let bestElevatedFraction: Double
    let bestBorderlineThresholdHR: Int
    let bestBorderlineElevatedSeconds: TimeInterval
    let bestBorderlineLongestBout: TimeInterval
    let bestDroppedGapSeconds: TimeInterval
    let bestMaxSampleGap: TimeInterval
    let bestGapCount: Int
    let bestStreamCoveragePercent: Int
    let bestPrimaryBlocker: String
    let bestHRRaw2A37: Int
    let bestHRAccepted: Int
    let bestHRZero: Int
    let bestHRArtifactHeld: Int
    let bestHRArtifactDropped: Int
    let bestHRRawGaps: Int
    let bestHRAcceptedGaps: Int
    let bestHRMaxRawGap: TimeInterval
    let bestHRMaxAcceptedGap: TimeInterval
    let restHR: Int
    let maxHR: Int

    var bestHasBlockingStreamGap: Bool {
        bestPrimaryBlocker.contains("stream_gaps") || bestStreamCoveragePercent < 75
    }

    var bestHRDistributionBelowWorkoutBand: Bool {
        guard bestSamples > 0, bestThresholdHR > 0 else { return false }
        return bestP95HR < bestThresholdHR && bestElevatedSeconds < 60
    }

    var profileMaxHRForBestP95AtHRR50: Int {
        Self.profileMaxHRForHRR50Threshold(rest: restHR, targetHR: bestP95HR)
    }

    var profileMaxHRForBestP99AtHRR50: Int {
        Self.profileMaxHRForHRR50Threshold(rest: restHR, targetHR: bestP99HR)
    }

    var profileMaxHRForBestPeakAtHRR50: Int {
        Self.profileMaxHRForHRR50Threshold(rest: restHR, targetHR: bestPeakHR)
    }

    var p99ProfileMaxHRGap: Int {
        max(0, maxHR - profileMaxHRForBestP99AtHRR50)
    }

    var nearMiss: Bool {
        guard bestStatus != "ready" else { return false }
        let enoughObservedData = bestObservedDuration >= 10 * 60
        let enoughSparseCoverageToInspect = bestStreamCoveragePercent >= 20
        let closeToThreshold = bestThresholdGapBPM <= 5 || bestElevatedSeconds > 0
        return enoughObservedData && enoughSparseCoverageToInspect && closeToThreshold
    }

    var nearMissReason: String {
        guard nearMiss else { return "none" }
        var reasons: [String] = []
        if bestHasBlockingStreamGap {
            reasons.append("stream_coverage_low")
        }
        if bestThresholdGapBPM > 0 {
            reasons.append("peak_within_\(bestThresholdGapBPM)_bpm_below_threshold")
        }
        if bestElevatedSeconds < bestRequiredElevatedSeconds {
            reasons.append("elevated_seconds_below_required")
        }
        if bestLongestBout < bestRequiredBout {
            reasons.append("continuous_bout_below_required")
        }
        return reasons.isEmpty ? "near_miss_low_confidence" : reasons.joined(separator: "+")
    }

    var strengthCandidate: Bool {
        guard bestStatus != "ready" else { return false }
        guard bestObservedDuration >= 10 * 60, bestStreamCoveragePercent >= 20 else { return false }
        let closeToWorkoutBand = bestThresholdGapBPM <= 5 || bestElevatedSeconds > 0
        let hasBorderlineEvidence = bestBorderlineElevatedSeconds >= 30 || bestBorderlineLongestBout >= 10
        return closeToWorkoutBand && hasBorderlineEvidence
    }

    var strengthCandidateReason: String {
        guard strengthCandidate else { return "none" }
        var reasons = ["diagnostic_only"]
        if bestHasBlockingStreamGap {
            reasons.append("stream_gaps_prevent_count")
        }
        if bestThresholdGapBPM > 0 {
            reasons.append("peak_within_\(bestThresholdGapBPM)_bpm_below_hrr50")
        }
        if bestBorderlineElevatedSeconds > 0 {
            reasons.append("borderline_hr_band_\(Int(bestBorderlineElevatedSeconds.rounded()))s")
        }
        if bestElevatedSeconds < bestRequiredElevatedSeconds {
            reasons.append("workout_band_time_insufficient")
        }
        if bestLongestBout < bestRequiredBout {
            reasons.append("continuous_bout_insufficient")
        }
        return reasons.joined(separator: "+")
    }

    var bestNextAction: String {
        if bestStatus == "ready" { return "count_workout" }
        if strengthCandidate {
            return "observe_strength_signal_without_counting_and_validate_hr_reference"
        }
        let hasStreamGap = bestHasBlockingStreamGap
        let needsHRReference = bestPeakHR < bestThresholdHR
        if hasStreamGap && needsHRReference {
            return "fix_stream_continuity_and_validate_intensity"
        }
        if hasStreamGap {
            return "fix_stream_continuity_before_counting"
        }
        if needsHRReference {
            return "validate_intensity_with_reference_or_profile"
        }
        if bestHRDistributionBelowWorkoutBand {
            return "validate_wrist_hr_underreporting_or_profile_before_more_workouts"
        }
        if bestElevatedSeconds < bestRequiredElevatedSeconds || bestLongestBout < bestRequiredBout {
            return "keep_learning_until_sustained_hr"
        }
        return "inspect_detector_inputs"
    }

    private static func profileMaxHRForHRR50Threshold(rest: Int, targetHR: Int) -> Int {
        guard targetHR > rest else { return rest }
        return rest + (2 * (targetHR - rest))
    }

    static func empty(rest: Int, maxHR: Int) -> WorkoutReplaySummary {
        WorkoutReplaySummary(rawSessions: 0,
                             canonicalSessions: 0,
                             sessionsEvaluated: 0,
                             readySessions: 0,
                             bestSource: "none",
                             bestChunkCount: 0,
                             bestStart: nil,
                             bestEnd: nil,
                             bestSpan: 0,
                             bestLabel: "none",
                             bestStatus: "learning",
                             bestReason: "no_saved_session",
                             bestDuration: 0,
                             bestObservedDuration: 0,
                             bestSamples: 0,
                             bestAvgHR: 0,
                             bestPeakHR: 0,
                             bestP95HR: 0,
                             bestP99HR: 0,
                             bestThresholdHR: 0,
                             bestThresholdGapBPM: 0,
                             bestSamplesAboveThreshold: 0,
                             bestSamplesAboveBorderline: 0,
                             bestElevatedSeconds: 0,
                             bestRequiredElevatedSeconds: 0,
                             bestLongestBout: 0,
                             bestRequiredBout: 0,
                             bestElevatedFraction: 0,
                             bestBorderlineThresholdHR: 0,
                             bestBorderlineElevatedSeconds: 0,
                             bestBorderlineLongestBout: 0,
                             bestDroppedGapSeconds: 0,
                             bestMaxSampleGap: 0,
                             bestGapCount: 0,
                             bestStreamCoveragePercent: 0,
                             bestPrimaryBlocker: "no_saved_session",
                             bestHRRaw2A37: 0,
                             bestHRAccepted: 0,
                             bestHRZero: 0,
                             bestHRArtifactHeld: 0,
                             bestHRArtifactDropped: 0,
                             bestHRRawGaps: 0,
                             bestHRAcceptedGaps: 0,
                             bestHRMaxRawGap: 0,
                             bestHRMaxAcceptedGap: 0,
                             restHR: rest,
                             maxHR: maxHR)
    }
}

struct HistoricalGapRepairSummary: Equatable {
    let status: String
    let reason: String
    let archiveRows: Int
    let archiveCurrentUsableRows: Int
    let archiveMetricUsableRows: Int
    let archiveStartUnix: Int
    let archiveEndUnix: Int
    let workoutStartUnix: Int
    let workoutEndUnix: Int
    let overlapSeconds: Int
    let separationSeconds: Int
    let diagnosticOnly: Bool
    let metricUsable: Bool
}

struct StrainValidationSummary: Equatable {
    let daysEvaluated: Int
    let sessionsEvaluated: Int
    let bestDay: Date?
    let bestSessions: Int
    let restHR: Int
    let maxHR: Int
    let reserveHR: Int
    let samples: Int
    let totalSeconds: TimeInterval
    let droppedGapSeconds: TimeInterval
    let streamCoveragePercent: Int
    let secondsZ0: TimeInterval
    let secondsZ1: TimeInterval
    let secondsZ2: TimeInterval
    let secondsZ3: TimeInterval
    let secondsZ4: TimeInterval
    let minHRReserve: Double
    let maxHRReserve: Double
    let trimp: Double
    let strain: Double
    let restToMaxReady: Bool
    let externalHRReferenceValidated: Bool
    let ready: Bool
    let primaryBlocker: String

    var highZoneSeconds: TimeInterval { secondsZ3 + secondsZ4 }

    static func empty(rest: Int, maxHR: Int, sessions: Int = 0) -> StrainValidationSummary {
        StrainValidationSummary(daysEvaluated: 0,
                                sessionsEvaluated: sessions,
                                bestDay: nil,
                                bestSessions: 0,
                                restHR: rest,
                                maxHR: maxHR,
                                reserveHR: max(0, maxHR - rest),
                                samples: 0,
                                totalSeconds: 0,
                                droppedGapSeconds: 0,
                                streamCoveragePercent: 0,
                                secondsZ0: 0,
                                secondsZ1: 0,
                                secondsZ2: 0,
                                secondsZ3: 0,
                                secondsZ4: 0,
                                minHRReserve: 0,
                                maxHRReserve: 0,
                                trimp: 0,
                                strain: 0,
                                restToMaxReady: false,
                                externalHRReferenceValidated: false,
                                ready: false,
                                primaryBlocker: "no_saved_hr_sessions")
    }
}

struct SessionBackupEnvelope: Codable {
    let schema: Int
    let createdAt: Date
    let app: String
    let sessions: [SavedSession]
    let baseline: PersonalBaseline
    let profile: AthleteProfile
}

struct SessionBackupStatus: Equatable {
    let available: Bool
    let current: Bool
    let path: String
    let sessions: Int
    let rrSamples: Int
    let bytes: Int
    let reason: String

    static let missing = SessionBackupStatus(available: false,
                                             current: false,
                                             path: "none",
                                             sessions: 0,
                                             rrSamples: 0,
                                             bytes: 0,
                                             reason: "no_backup")
}

private struct SessionBackupContentFingerprint: Codable {
    let schema: Int
    let app: String
    let sessions: [SavedSession]
    let baseline: PersonalBaseline
    let profile: AthleteProfile
}

extension SavedSession {
    /// Standard BLE Heart Rate (`2A37`) can legitimately arrive in short bursts
    /// instead of at a perfect 1 Hz cadence. Use this only for HR/workout/strain
    /// coverage. RR/HRV continuity keeps its stricter no->3s-gap contract.
    static let workoutContinuityGapLimit: TimeInterval = 15
    fileprivate static let workoutBorderlineThresholdMarginBPM = 5
    fileprivate static let restReviewMinimumDuration: TimeInterval = 2 * 60
    fileprivate static let strictRestAvgOverRestBPM = 18
    fileprivate static let strictRestPeakOverRestBPM = 45
    fileprivate static let restReviewAvgOverRestBPM = 30
    fileprivate static let restReviewP95OverRestBPM = 42
    fileprivate static let restReviewPeakOverRestBPM = 55

    func workoutReadiness(rest: Int, maxHR: Int, thresholdFraction: Double = 0.50) -> WorkoutReadiness {
        let sustained = sustainedElevatedEvidence(rest: rest, maxHR: maxHR, thresholdFraction: thresholdFraction)
        let thresholdHR = Self.workoutElevatedThreshold(rest: rest, maxHR: maxHR, fraction: thresholdFraction)
        let borderlineThresholdHR = max(rest, thresholdHR - Self.workoutBorderlineThresholdMarginBPM)
        let borderline = sustainedEvidence(minimumHR: borderlineThresholdHR)
        let samplesAboveThreshold = bpms.filter { $0 >= thresholdHR }.count
        let samplesAboveBorderline = bpms.filter { $0 >= borderlineThresholdHR }.count
        let elevatedSeconds = sustained.total
        let observedDuration = sustained.observedDuration
        let requiredElevatedSeconds = min(max(observedDuration * 0.35, 5 * 60), 20 * 60)
        let requiredElevatedBout = min(max(observedDuration * 0.20, 3 * 60), 8 * 60)
        let avgOverRest = avg - rest
        let peakOverRest = peak - rest
        let thresholdGapBPM = max(0, thresholdHR - peak)
        let streamCoveragePercent = Self.workoutStreamCoveragePercent(observed: observedDuration, duration: duration)
        let ready = observedDuration >= 10 * 60
            && streamCoveragePercent >= 75
            && elevatedSeconds >= requiredElevatedSeconds
            && sustained.longestBout >= requiredElevatedBout
        let primaryBlocker = Self.workoutPrimaryBlocker(ready: ready,
                                                        duration: duration,
                                                        observedDuration: observedDuration,
                                                        streamCoveragePercent: streamCoveragePercent,
                                                        droppedGapSeconds: sustained.droppedGapSeconds,
                                                        maxSampleGap: sustained.maxGap,
                                                        peakHR: peak,
                                                        thresholdHR: thresholdHR,
                                                        elevatedSeconds: elevatedSeconds,
                                                        requiredElevatedSeconds: requiredElevatedSeconds,
                                                        longestBout: sustained.longestBout,
                                                        requiredBout: requiredElevatedBout)
        return WorkoutReadiness(duration: duration,
                                observedDuration: observedDuration,
                                avgHR: avg,
                                peakHR: peak,
                                p90HR: Self.percentileHR(0.90, values: bpms),
                                p95HR: Self.percentileHR(0.95, values: bpms),
                                p99HR: Self.percentileHR(0.99, values: bpms),
                                thresholdHR: thresholdHR,
                                thresholdGapBPM: thresholdGapBPM,
                                samplesAboveThreshold: samplesAboveThreshold,
                                samplesAboveBorderline: samplesAboveBorderline,
                                elevatedSeconds: elevatedSeconds,
                                elevatedFraction: observedDuration > 0 ? elevatedSeconds / observedDuration : 0,
                                longestElevatedBout: sustained.longestBout,
                                borderlineThresholdHR: borderlineThresholdHR,
                                borderlineElevatedSeconds: borderline.total,
                                borderlineLongestBout: borderline.longestBout,
                                borderlineElevatedFraction: borderline.observedDuration > 0 ? borderline.total / borderline.observedDuration : 0,
                                requiredElevatedSeconds: requiredElevatedSeconds,
                                requiredElevatedBout: requiredElevatedBout,
                                droppedGapSeconds: sustained.droppedGapSeconds,
                                maxSampleGap: sustained.maxGap,
                                gapCount: sustained.gapCount,
                                streamCoveragePercent: streamCoveragePercent,
                                primaryBlocker: primaryBlocker,
                                avgOverRest: avgOverRest,
                                peakOverRest: peakOverRest,
                                ready: ready)
    }

    func detectedActivity(rest: Int, maxHR: Int, calendar: Calendar = .current) -> ActivityDetection? {
        guard duration >= Self.restReviewMinimumDuration, !points.isEmpty else { return nil }

        let startHour = calendar.component(.hour, from: start)
        let endHour = calendar.component(.hour, from: end)
        let overnight = startHour >= 20 || startHour <= 3 || endHour <= 10
        let lowHR = avg <= rest + 15 && peak <= rest + 35
        if duration >= 10 * 60 {
            let readiness = workoutReadiness(rest: rest, maxHR: maxHR)
            if readiness.ready {
                let stepClause = phoneStepEvidenceClause.map { "; \($0)" } ?? ""
                let reason = "sustained elevated HR\(stepClause)"
                return ActivityDetection(id: id, kind: .workout, confidence: .medium,
                                         start: start, end: end, duration: duration,
                                         avgHR: avg, peakHR: peak, reason: reason)
            }
            if readiness.nearMiss {
                let stepClause = phoneStepEvidenceClause.map { "; \($0)" } ?? ""
                return ActivityDetection(id: id, kind: .activityCandidate, confidence: .low,
                                         start: start, end: end, duration: duration,
                                         avgHR: avg, peakHR: peak,
                                         reason: "HR-only workout-like signal\(stepClause); \(readiness.nearMissReason); not counted as workout")
            }
            if readiness.strengthCandidate {
                let stepClause = phoneStepEvidenceClause.map { "; \($0)" } ?? ""
                return ActivityDetection(id: id, kind: .activityCandidate, confidence: .low,
                                         start: start, end: end, duration: duration,
                                         avgHR: avg, peakHR: peak,
                                         reason: "Strength-like HR signal\(stepClause); \(readiness.strengthCandidateReason); not counted as workout")
            }
            if hasPhoneStepWorkoutEvidence {
                let stepClause = phoneStepEvidenceClause ?? "phone step evidence"
                return ActivityDetection(id: id, kind: .activityCandidate, confidence: .low,
                                         start: start, end: end, duration: duration,
                                         avgHR: avg, peakHR: peak,
                                         reason: "\(stepClause); HR workout gate not met; not counted as workout")
            }
            if duration >= 3 * 60 * 60 && overnight && lowHR {
                let motionClause = motionHintCountValue > 0
                    ? "diagnostic motion observed unvalidated (\(motionHintKindsValue))"
                    : "motion not decoded"
                return ActivityDetection(id: id, kind: .sleepCandidate, confidence: .low,
                                         start: start, end: end, duration: duration,
                                         avgHR: avg, peakHR: peak,
                                         reason: "HR-only overnight low-HR window; \(motionClause)")
            }
        }
        if duration < 3 * 60 * 60
            && avg <= rest + Self.strictRestAvgOverRestBPM
            && peak <= rest + Self.strictRestPeakOverRestBPM {
            let motionClause = motionHintCountValue > 0
                ? "diagnostic motion observed unvalidated (\(motionHintKindsValue))"
                : "motion not decoded"
            return ActivityDetection(id: id, kind: .restCandidate, confidence: .low,
                                     start: start, end: end, duration: duration,
                                     avgHR: avg, peakHR: peak,
                                     reason: "Short low-HR rest/nap candidate; diagnostic only; \(motionClause)")
        }
        let p95 = Self.percentileHR(0.95, values: bpms)
        let workoutFloor = Self.workoutElevatedThreshold(rest: rest, maxHR: maxHR, fraction: 0.50)
        if duration < 3 * 60 * 60
            && avg <= rest + Self.restReviewAvgOverRestBPM
            && p95 <= rest + Self.restReviewP95OverRestBPM
            && peak <= min(workoutFloor - 5, rest + Self.restReviewPeakOverRestBPM) {
            let motionClause = motionHintCountValue > 0
                ? "diagnostic motion observed unvalidated (\(motionHintKindsValue))"
                : "motion not decoded"
            return ActivityDetection(id: id, kind: .restCandidate, confidence: .low,
                                     start: start, end: end, duration: duration,
                                     avgHR: avg, peakHR: peak,
                                     reason: "Quiet HR-only rest/nap review; below workout band; not counted as sleep or workout; \(motionClause)")
        }
        return nil
    }

    func restingHRForBaseline(rest: Int, maxHR: Int, calendar: Calendar = .current) -> (value: Int, source: String) {
        if let detection = detectedActivity(rest: rest, maxHR: maxHR, calendar: calendar),
           detection.kind == .sleepCandidate {
            return (sleepCandidateRestingHR, "hr_only_sleep_candidate_5th_percentile")
        }
        return (restingStable, "session_10th_percentile")
    }

    func baselineLearningEvidence(rest: Int, maxHR: Int, calendar: Calendar = .current) -> BaselineLearningEvidence {
        let restingEvidence = restingHRForBaseline(rest: rest, maxHR: maxHR, calendar: calendar)
        if restingEvidence.source == "hr_only_sleep_candidate_5th_percentile" {
            return BaselineLearningEvidence(value: restingEvidence.value,
                                            source: restingEvidence.source,
                                            accepted: true,
                                            reason: "sleep_candidate")
        }
        if localRMSSD != nil && duration >= 5 * 60 {
            return BaselineLearningEvidence(value: restingEvidence.value,
                                            source: hrvReferenceValidated == true
                                                ? "validated_hrv_window_10th_percentile"
                                                : "local_hrv_window_10th_percentile",
                                            accepted: true,
                                            reason: hrvReferenceValidated == true
                                                ? "validated_hrv_window"
                                                : "local_hrv_window")
        }
        if duration < 20 * 60 {
            return BaselineLearningEvidence(value: restingEvidence.value,
                                            source: restingEvidence.source,
                                            accepted: false,
                                            reason: "duration_below_20m")
        }
        if avg > rest + 15 {
            return BaselineLearningEvidence(value: restingEvidence.value,
                                            source: restingEvidence.source,
                                            accepted: false,
                                            reason: "avg_hr_above_rest_window")
        }
        if peak > rest + 35 {
            return BaselineLearningEvidence(value: restingEvidence.value,
                                            source: restingEvidence.source,
                                            accepted: false,
                                            reason: "peak_hr_above_rest_window")
        }
        return BaselineLearningEvidence(value: restingEvidence.value,
                                        source: "session_10th_percentile_low_hr_window",
                                        accepted: true,
                                        reason: "low_hr_window")
    }

    private func sustainedElevatedEvidence(rest: Int,
                                           maxHR: Int,
                                           thresholdFraction: Double = 0.50) -> (total: TimeInterval,
                                                                                longestBout: TimeInterval,
                                                                                observedDuration: TimeInterval,
                                                                                droppedGapSeconds: TimeInterval,
                                                                                maxGap: TimeInterval,
                                                                                gapCount: Int) {
        let elevatedThreshold = Self.workoutElevatedThreshold(rest: rest, maxHR: maxHR, fraction: thresholdFraction)
        return sustainedEvidence(minimumHR: elevatedThreshold)
    }

    private func sustainedEvidence(minimumHR: Int) -> (total: TimeInterval,
                                                       longestBout: TimeInterval,
                                                       observedDuration: TimeInterval,
                                                       droppedGapSeconds: TimeInterval,
                                                       maxGap: TimeInterval,
                                                       gapCount: Int) {
        guard points.count > 1 else { return (0, 0, 0, 0, 0, 0) }
        var total: TimeInterval = 0
        var currentBout: TimeInterval = 0
        var longestBout: TimeInterval = 0
        var observedDuration: TimeInterval = 0
        var droppedGapSeconds: TimeInterval = 0
        var maxGap: TimeInterval = 0
        var gapCount = 0
        for i in 1..<points.count {
            let dt = max(0, points[i].t - points[i - 1].t)
            if dt > Self.workoutContinuityGapLimit {
                droppedGapSeconds += dt
                maxGap = max(maxGap, dt)
                gapCount += 1
                currentBout = 0
                continue
            }
            observedDuration += dt
            let elevated = points[i].bpm >= minimumHR
            if elevated {
                total += dt
                currentBout += dt
                longestBout = max(longestBout, currentBout)
            } else {
                currentBout = 0
            }
        }
        return (total, longestBout, observedDuration, droppedGapSeconds, maxGap, gapCount)
    }

    static func workoutElevatedThreshold(rest: Int, maxHR: Int, fraction: Double = 0.50) -> Int {
        let reserve = max(0, maxHR - rest)
        guard reserve > 0 else {
            return max(rest, maxHR)
        }
        let clamped = min(max(fraction, 0), 1)
        return rest + Int((Double(reserve) * clamped).rounded())
    }

    private static func percentileHR(_ percentile: Double, values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * clamped).rounded(.down))))
        return sorted[index]
    }

    private static func workoutStreamCoveragePercent(observed: TimeInterval, duration: TimeInterval) -> Int {
        guard duration > 0 else { return 0 }
        let percent = (observed / duration) * 100
        return min(100, max(0, Int(percent.rounded())))
    }

    private static func workoutPrimaryBlocker(ready: Bool,
                                              duration: TimeInterval,
                                              observedDuration: TimeInterval,
                                              streamCoveragePercent: Int,
                                              droppedGapSeconds: TimeInterval,
                                              maxSampleGap: TimeInterval,
                                              peakHR: Int,
                                              thresholdHR: Int,
                                              elevatedSeconds: TimeInterval,
                                              requiredElevatedSeconds: TimeInterval,
                                              longestBout: TimeInterval,
                                              requiredBout: TimeInterval) -> String {
        if ready { return "none" }
        let durationBlocked = observedDuration < 10 * 60
        let actualStreamGaps = droppedGapSeconds > 0 || maxSampleGap > Self.workoutContinuityGapLimit
        let coverageBlocked = streamCoveragePercent < 75
        let streamGapBlocked = actualStreamGaps && (durationBlocked
            || (duration > 0 && droppedGapSeconds / duration >= 0.25)
            || maxSampleGap > 30
        )
        let hrBelowThreshold = peakHR < thresholdHR
        if durationBlocked && !actualStreamGaps && hrBelowThreshold { return "duration_below_10m_and_hr_below_threshold" }
        if durationBlocked && !actualStreamGaps { return "duration_below_10m" }
        if coverageBlocked && hrBelowThreshold { return "stream_gaps_and_hr_below_threshold" }
        if coverageBlocked { return "stream_gaps" }
        if streamGapBlocked && hrBelowThreshold { return "stream_gaps_and_hr_below_threshold" }
        if streamGapBlocked { return "stream_gaps" }
        if hrBelowThreshold { return "hr_below_threshold" }
        if elevatedSeconds < requiredElevatedSeconds { return "insufficient_elevated_time" }
        if longestBout < requiredBout { return "insufficient_continuous_bout" }
        return "detector_not_workout"
    }
}

/// Loads/saves sessions to a JSON file in the app's Documents directory.
@MainActor
final class SessionStore: ObservableObject {
    struct HomeDashboardDiagnostics {
        let rest: Int
        let rrPackage: RRPackageStatus
        let sleep: SleepEvidenceStatus
        let workout: SavedWorkoutAttemptStatus
        let collection: CurrentCollectionStatus
        let backup: SessionBackupStatus
        let trend90: TrendSummary
    }

    struct HomeSavedAggregate {
        let rest: Int
        let maxHR: Int
        let savedTodayTRIMP: Double
        let hasSavedToday: Bool
        let sessionsCount: Int
    }

    private struct DeferredLoadPreparation {
        let latestReferenceValidatedHRV: Int?
        let canonicalSessions: [SavedSession]
        let baseline: PersonalBaseline
        let didRebuildBaseline: Bool
        let backupStatus: SessionBackupStatus
    }

    @Published private(set) var sessions: [SavedSession] = []
    @Published private(set) var baseline = PersonalBaseline.load()
    @Published private(set) var profile = AthleteProfile.load()
    @Published private(set) var dashboardRevision = 0
    private let healthKitExporter = HealthKitExporter()
    private let persistenceQueue = DispatchQueue(label: "com.adidshaft.atria.session-store.persistence",
                                                 qos: .utility)
    private var pendingSessionSaveWorkItem: DispatchWorkItem?
    private static let checkpointPersistenceDelay: TimeInterval = 2.25
    private var sessionPersistenceRevision = 0
    private var lastCompletedSessionPersistenceRevision = 0
    private var pendingSessionPersistenceRevision = 0
    private var cachedLatestReferenceValidatedHRV: Int?
    private var cachedConfirmedWorkouts: [UserConfirmedWorkout]
    private var cachedConfirmedSleeps: [UserConfirmedSleep]
    private var cachedBehaviorJournalEntries: [BehaviorJournalEntry]
    private var cachedSessionBackupStatus: SessionBackupStatus
    private var cachedCanonicalSessions: [SavedSession]
    private var cachedHomeDashboardDiagnostics: HomeDashboardDiagnostics?
    private var cachedHomeSavedAggregate: HomeSavedAggregate?
    private var cachedCurrentCollectionStatus: (evaluatedAt: Date, status: CurrentCollectionStatus)?
    private static let currentCollectionStatusCacheTTL: TimeInterval = 3

    private enum ConfirmedWorkoutDefaults {
        static let key = "atria.confirmedWorkouts.v1"
    }

    private enum ConfirmedSleepDefaults {
        static let key = "atria.confirmedSleeps.v1"
    }

    private enum BehaviorJournalDefaults {
        static let key = "atria.behaviorJournal.v1"
    }

    private enum ExternalReferenceDefaults {
        static let hrValidated = "atria.reference.hr.validated"
        static let hrValidatedAt = "atria.reference.hr.validatedAt"
        static let hrSource = "atria.reference.hr.source"
        static let hrStatus = "atria.reference.hr.status"
        static let hrReason = "atria.reference.hr.reason"
        static let hrPairs = "atria.reference.hr.pairs"
        static let hrReferenceSamples = "atria.reference.hr.referenceSamples"
        static let hrDuration = "atria.reference.hr.duration"
        static let hrMeanDelta = "atria.reference.hr.meanDelta"
        static let hrMedianDelta = "atria.reference.hr.medianDelta"
        static let hrMaxDelta = "atria.reference.hr.maxDelta"
        static let hrWithinTolerancePercent = "atria.reference.hr.withinTolerancePercent"
        static let hrSessionID = "atria.reference.hr.sessionID"
        static let hrSessionLabel = "atria.reference.hr.sessionLabel"
    }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sessions.json")
    }()

    init() {
        self.cachedConfirmedWorkouts = Self.readConfirmedWorkouts()
        self.cachedConfirmedSleeps = Self.readConfirmedSleeps()
        self.cachedBehaviorJournalEntries = Self.readBehaviorJournalEntries()
        self.cachedSessionBackupStatus = .missing
        self.cachedLatestReferenceValidatedHRV = nil
        self.cachedCanonicalSessions = []
        self.cachedHomeDashboardDiagnostics = nil
        self.cachedHomeSavedAggregate = nil
        self.cachedCurrentCollectionStatus = nil
        loadPersistedSessionsDeferred()
        refreshSessionDerivedCaches()
    }

    var latestReferenceValidatedHRV: Int? {
        cachedLatestReferenceValidatedHRV
    }

    var latestLocalRMSSD: Int? {
        sessions.first(where: { $0.localRMSSD != nil })?.localRMSSD
    }

    var confirmedWorkouts: [UserConfirmedWorkout] {
        cachedConfirmedWorkouts
    }

    var confirmedSleeps: [UserConfirmedSleep] {
        cachedConfirmedSleeps
    }

    var behaviorJournalEntries: [BehaviorJournalEntry] {
        cachedBehaviorJournalEntries
    }

    private func refreshSessionDerivedCaches() {
        cachedLatestReferenceValidatedHRV = sessions.first(where: { $0.referenceValidatedHRV != nil })?.referenceValidatedHRV
        cachedCanonicalSessions = Self.makeCanonicalSessions(from: sessions)
        cachedHomeSavedAggregate = nil
        cachedCurrentCollectionStatus = nil
    }

    private func refreshSessionDerivedCachesAfterUpsert(_ session: SavedSession) {
        cachedLatestReferenceValidatedHRV = sessions.first(where: { $0.referenceValidatedHRV != nil })?.referenceValidatedHRV
        cachedCanonicalSessions = Self.makeCanonicalSessions(from: cachedCanonicalSessions + [session],
                                                             preferredSession: preferredSession)
        cachedHomeSavedAggregate = nil
        cachedCurrentCollectionStatus = nil
    }

    private func refreshBackupStatusCache() {
        cachedSessionBackupStatus = computeSessionBackupStatus()
    }

    private func refreshHomeDashboardDiagnosticsCache() {
        let rest = baseline.restingInt ?? sessions.first?.restingStable ?? 60
        let maxHR = profile.maxHR
        cachedHomeDashboardDiagnostics = HomeDashboardDiagnostics(rest: rest,
                                                                 rrPackage: rrPackageStatusFast(),
                                                                 sleep: sleepEvidenceStatusFast(rest: rest),
                                                                 workout: savedWorkoutAttemptStatusFast(rest: rest, maxHR: maxHR),
                                                                 collection: currentCollectionStatus(),
                                                                 backup: cachedSessionBackupStatus,
                                                                 trend90: trendSummaryFast(rest: rest, maxHR: maxHR, days: 90))
    }

    private func publishDashboardRevision() {
        dashboardRevision &+= 1
    }

    private func invalidateHomeDashboardDiagnosticsCache() {
        cachedHomeDashboardDiagnostics = nil
        cachedCurrentCollectionStatus = nil
    }

    private func markSessionPersistenceDirty() {
        sessionPersistenceRevision &+= 1
    }

    func homeSavedAggregate(rest: Int, maxHR: Int, calendar: Calendar = .current) -> HomeSavedAggregate {
        if let cachedHomeSavedAggregate,
           cachedHomeSavedAggregate.rest == rest,
           cachedHomeSavedAggregate.maxHR == maxHR {
            return cachedHomeSavedAggregate
        }

        var savedTodayTRIMP = 0.0
        var hasSavedToday = false
        for session in sessions {
            guard calendar.isDateInToday(session.start) else { break }
            hasSavedToday = true
            savedTodayTRIMP += session.trimp(rest: rest, max: maxHR)
        }

        let aggregate = HomeSavedAggregate(rest: rest,
                                           maxHR: maxHR,
                                           savedTodayTRIMP: savedTodayTRIMP,
                                           hasSavedToday: hasSavedToday,
                                           sessionsCount: sessions.count)
        cachedHomeSavedAggregate = aggregate
        return aggregate
    }

    private func scheduleSessionFilePersist(reason: String, delay: TimeInterval) {
        guard sessionPersistenceRevision > lastCompletedSessionPersistenceRevision else { return }
        let snapshot = sessions
        let sourceURL = url
        let revision = sessionPersistenceRevision

        pendingSessionSaveWorkItem?.cancel()
        pendingSessionPersistenceRevision = revision
        let workItem = DispatchWorkItem { [weak self] in
            Self.persistSessionsSnapshot(snapshot, to: sourceURL, reason: reason)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastCompletedSessionPersistenceRevision = max(self.lastCompletedSessionPersistenceRevision, revision)
                if self.pendingSessionPersistenceRevision == revision {
                    self.pendingSessionPersistenceRevision = 0
                }
            }
        }
        pendingSessionSaveWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func requestPersistenceFlush(reason: String) {
        guard sessionPersistenceRevision > lastCompletedSessionPersistenceRevision else { return }
        let snapshot = sessions
        let sourceURL = url
        let revision = sessionPersistenceRevision

        pendingSessionSaveWorkItem?.cancel()
        pendingSessionPersistenceRevision = revision
        let workItem = DispatchWorkItem { [weak self] in
            Self.persistSessionsSnapshot(snapshot, to: sourceURL, reason: reason)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastCompletedSessionPersistenceRevision = max(self.lastCompletedSessionPersistenceRevision, revision)
                if self.pendingSessionPersistenceRevision == revision {
                    self.pendingSessionPersistenceRevision = 0
                }
            }
        }
        pendingSessionSaveWorkItem = workItem
        persistenceQueue.async(execute: workItem)
    }

    func flushScheduledPersistence(reason: String) {
        guard sessionPersistenceRevision > lastCompletedSessionPersistenceRevision else { return }
        let snapshot = sessions
        let sourceURL = url
        let revision = sessionPersistenceRevision
        pendingSessionSaveWorkItem?.cancel()
        pendingSessionSaveWorkItem = nil
        pendingSessionPersistenceRevision = revision
        persistenceQueue.sync {
            Self.persistSessionsSnapshot(snapshot, to: sourceURL, reason: reason)
        }
        lastCompletedSessionPersistenceRevision = max(lastCompletedSessionPersistenceRevision, revision)
        if pendingSessionPersistenceRevision == revision {
            pendingSessionPersistenceRevision = 0
        }
    }

    func performBackgroundMaintenance(reason: String) {
        flushScheduledPersistence(reason: "\(reason)_persistence")
        _ = dailyRollups(rest: baseline.restingInt ?? 60, maxHR: profile.maxHR)
        _ = trendSummaries(rest: baseline.restingInt ?? 60, maxHR: profile.maxHR)
        writeAutomaticSessionBackup(reason: reason)
        let health = HealthKitExporter.diagnostics(for: sessions,
                                                    rest: baseline.restingInt ?? 60,
                                                    maxHR: profile.maxHR,
                                                    confirmedWorkouts: confirmedWorkouts,
                                                    confirmedSleeps: confirmedSleeps)
        WHOOPDebugLog("WHOOPDBG bg_maintenance status=ok reason=%@ sessions=%d healthkit_hr_samples=%d healthkit_resting_hr_samples=%d healthkit_hrv_samples=%d healthkit_respiratory_rate_samples=%d healthkit_workouts=%d healthkit_sleeps=%d",
              reason,
              sessions.count,
              health.planned.hrSamples,
              health.planned.restingHRSamples,
              health.planned.hrvSamples,
              health.planned.respiratoryRateSamples,
              health.planned.workouts,
              health.planned.sleeps)
    }

    private static func persistSessionsSnapshot(_ sessions: [SavedSession], to url: URL, reason: String) {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: url, options: .atomic)
            WHOOPDebugLog("WHOOPDBG session_store_save status=ok op=%@ sessions=%d bytes=%d",
                  reason,
                  sessions.count,
                  data.count)
        } catch {
            WHOOPDebugLog("WHOOPDBG session_store_save status=failed op=%@ error=%@",
                  reason,
                  error.localizedDescription)
        }
    }

    private func insertionIndex(for start: Date) -> Int {
        var low = 0
        var high = sessions.count
        while low < high {
            let mid = (low + high) / 2
            if sessions[mid].start > start {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func upsertSession(_ session: SavedSession) -> String {
        if let existingIndex = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions.remove(at: existingIndex)
            let destination = insertionIndex(for: session.start)
            sessions.insert(session, at: destination)
            return "replace"
        }

        let destination = insertionIndex(for: session.start)
        sessions.insert(session, at: destination)
        return "insert"
    }

    func homeDashboardDiagnostics() -> HomeDashboardDiagnostics {
        if let cachedHomeDashboardDiagnostics {
            return cachedHomeDashboardDiagnostics
        }
        refreshHomeDashboardDiagnosticsCache()
        return cachedHomeDashboardDiagnostics ?? HomeDashboardDiagnostics(rest: baseline.restingInt ?? sessions.first?.restingStable ?? 60,
                                                                         rrPackage: .empty,
                                                                         sleep: SleepEvidenceStatus(ready: false,
                                                                                                    state: "learning",
                                                                                                    blocker: "sleep_learning",
                                                                                                    confidence: "none",
                                                                                                    candidates: 0,
                                                                                                    readyCandidates: 0,
                                                                                                    motionSource: "unavailable",
                                                                                                    motionValidated: false,
                                                                                                    fallbackAvailable: false,
                                                                                                    fallbackSource: "none",
                                                                                                    fallbackReason: "none",
                                                                                                    fallbackDuration: 0,
                                                                                                    fallbackSpan: 0,
                                                                                                    fallbackSessions: 0),
                                                                         workout: .empty,
                                                                         collection: currentCollectionStatus(),
                                                                         backup: cachedSessionBackupStatus,
                                                                         trend90: TrendSummary(id: 90,
                                                                                               days: 90,
                                                                                               sessions: 0,
                                                                                               coverageDays: 0,
                                                                                               requiredCoverageDays: trendRequiredCoverageDays(windowDays: 90),
                                                                                               coveragePercent: 0,
                                                                                               confidence: "learning",
                                                                                               avgRecovery: nil,
                                                                                               avgHRV: nil,
                                                                                               avgRHR: nil,
                                                                                               avgStrain: nil,
                                                                                               avgRespiratoryRate: nil,
                                                                                               anomalies: [],
                                                                                               anomalySource: "none",
                                                                                               anomalySampleDays: 0,
                                                                                               hrvState: "learning",
                                                                                               detail: "Saved trends are preparing.",
                                                                                               blockers: "loading"))
    }

    var externalHRReferenceValidated: Bool {
        UserDefaults.standard.bool(forKey: ExternalReferenceDefaults.hrValidated)
    }

    var externalHRReferenceSource: String {
        guard externalHRReferenceValidated else { return "missing" }
        return UserDefaults.standard.string(forKey: ExternalReferenceDefaults.hrSource) ?? "csv"
    }

    var csvHRReferenceDiagnostics: CSVHRReferenceDiagnostics {
        let defaults = UserDefaults.standard
        let mean = defaults.double(forKey: ExternalReferenceDefaults.hrMeanDelta)
        let median = defaults.double(forKey: ExternalReferenceDefaults.hrMedianDelta)
        let max = defaults.double(forKey: ExternalReferenceDefaults.hrMaxDelta)
        return CSVHRReferenceDiagnostics(
            status: defaults.string(forKey: ExternalReferenceDefaults.hrStatus) ?? "not_run",
            reason: defaults.string(forKey: ExternalReferenceDefaults.hrReason) ?? "not_run",
            validated: defaults.bool(forKey: ExternalReferenceDefaults.hrValidated),
            source: defaults.string(forKey: ExternalReferenceDefaults.hrSource) ?? "missing",
            pairs: defaults.integer(forKey: ExternalReferenceDefaults.hrPairs),
            referenceSamples: defaults.integer(forKey: ExternalReferenceDefaults.hrReferenceSamples),
            duration: defaults.double(forKey: ExternalReferenceDefaults.hrDuration),
            meanDelta: mean >= 0 ? mean : nil,
            medianDelta: median >= 0 ? median : nil,
            maxDelta: max >= 0 ? max : nil,
            withinTolerancePercent: defaults.integer(forKey: ExternalReferenceDefaults.hrWithinTolerancePercent)
        )
    }

    func gateETrainingSummary(rest: Int, maxHR: Int) -> GateETrainingSummary {
        let workoutStatus: GateEWorkoutTrainingStatus
        if let workout = confirmedWorkouts.sorted(by: { $0.start > $1.start }).first {
            let exact = exactWorkoutTrainingReadiness(for: workout, rest: rest, maxHR: maxHR)
            workoutStatus = GateEWorkoutTrainingStatus(present: true,
                                                       confirmedID: workout.id,
                                                       source: workout.source,
                                                       confidence: workout.confidence,
                                                       autoReady: exact.readiness.ready,
                                                       autoStatus: exact.readiness.status,
                                                       autoReason: exact.readiness.reason,
                                                       primaryBlocker: exact.readiness.primaryBlocker,
                                                       nextAction: exact.readiness.nextAction,
                                                       samples: exact.samples,
                                                       overlap: exact.overlap,
                                                       duration: workout.duration,
                                                       observedDuration: exact.readiness.observedDuration,
                                                       streamCoveragePercent: exact.readiness.streamCoveragePercent,
                                                       peakHR: exact.readiness.peakHR,
                                                       p95HR: exact.readiness.p95HR,
                                                       p99HR: exact.readiness.p99HR,
                                                       thresholdHR: exact.readiness.thresholdHR,
                                                       thresholdGapBPM: exact.readiness.thresholdGapBPM,
                                                       restHR: rest,
                                                       profileMaxHR: maxHR,
                                                       requiredProfileMaxHRForP95AtHRR50: Self.profileMaxHRForHRR50Threshold(rest: rest, targetHR: exact.readiness.p95HR),
                                                       requiredProfileMaxHRForP99AtHRR50: Self.profileMaxHRForHRR50Threshold(rest: rest, targetHR: exact.readiness.p99HR),
                                                       requiredProfileMaxHRForPeakAtHRR50: Self.profileMaxHRForHRR50Threshold(rest: rest, targetHR: exact.readiness.peakHR),
                                                       elevatedSeconds: exact.readiness.elevatedSeconds,
                                                       requiredElevatedSeconds: exact.readiness.requiredElevatedSeconds,
                                                       longestBout: exact.readiness.longestElevatedBout,
                                                       requiredBout: exact.readiness.requiredElevatedBout)
        } else {
            workoutStatus = .missing
        }

        let sleepStatus: GateESleepTrainingStatus
        if let sleep = confirmedSleeps.sorted(by: { $0.start > $1.start }).first {
            let match = bestSleepTrainingMatch(for: sleep, rest: rest)
            sleepStatus = GateESleepTrainingStatus(present: true,
                                                   confirmedID: sleep.id,
                                                   source: sleep.source,
                                                   confidence: sleep.confidence,
                                                   autoReady: match.autoReady,
                                                   autoReason: match.reason,
                                                   matchedSource: match.source,
                                                   overlap: match.overlap,
                                                   duration: sleep.duration,
                                                   span: sleep.span,
                                                   candidateDuration: match.duration,
                                                   candidateSpan: match.span,
                                                   avgHR: sleep.avgHR,
                                                   peakHR: sleep.peakHR,
                                                   sleepRHR: sleep.restingHR,
                                                   motionSource: match.motionSource,
                                                   motionValidated: match.motionValidated,
                                                   motionHints: match.motionHints,
                                                   historicalMotionStatus: match.historicalMotionStatus,
                                                   fallbackAccepted: match.fallbackAccepted,
                                                   fallbackPolicy: match.fallbackPolicy)
        } else {
            sleepStatus = .missing
        }

        return GateETrainingSummary(workout: workoutStatus, sleep: sleepStatus)
    }

    private static func profileMaxHRForHRR50Threshold(rest: Int, targetHR: Int) -> Int {
        guard targetHR > rest else { return rest }
        return rest + (2 * (targetHR - rest))
    }

    func rrPackageStatusFast(limitSessions: Int = 12) -> RRPackageStatus {
        let summary = replaySavedRRLedger(limitSessions: limitSessions,
                                          includeActiveJournal: true)
        guard summary.rrSamples > 0 else { return .empty }
        return RRPackageStatus(ready: summary.bestReady,
                               reason: summary.reason,
                               sessionsWithRR: summary.sessionsWithRR,
                               rrSamples: summary.rrSamples,
                               bestLabel: summary.bestSessionLabel,
                               raw: summary.bestRaw,
                               kept: summary.bestKept,
                               confidencePercent: summary.bestConfidencePercent,
                               maxGapSeconds: summary.bestMaxRRGapSeconds,
                               rmssd: summary.bestRMSSD)
    }

    func currentCollectionStatus(now: Date = Date()) -> CurrentCollectionStatus {
        if let cachedCurrentCollectionStatus,
           now.timeIntervalSince(cachedCurrentCollectionStatus.evaluatedAt) <= Self.currentCollectionStatusCacheTTL {
            return cachedCurrentCollectionStatus.status
        }

        let status: CurrentCollectionStatus
        if let record = ActiveSessionJournal.load() {
            let age = max(0, Int(now.timeIntervalSince(record.updatedAt).rounded()))
            let samples = record.samples.count
            let duration = max(0, Int(((record.samples.last?.t ?? record.updatedAt).timeIntervalSince(record.startedAt)).rounded()))
            let fresh = age <= 90
            let label = Self.diagnosticToken(record.label.isEmpty ? "Long wear" : record.label)
            if fresh && samples > 0 {
                status = CurrentCollectionStatus(ready: true,
                                                 source: "active_journal",
                                                 blocker: "none",
                                                 label: label,
                                                 samples: samples,
                                                 rrValues: record.rrSamples?.count ?? 0,
                                                 ageSeconds: age,
                                                 durationSeconds: duration)
            } else {
                status = CurrentCollectionStatus(ready: false,
                                                 source: "active_journal",
                                                 blocker: fresh ? "active_journal_empty" : "active_journal_stale",
                                                 label: label,
                                                 samples: samples,
                                                 rrValues: record.rrSamples?.count ?? 0,
                                                 ageSeconds: age,
                                                 durationSeconds: duration)
            }
        } else if let latest = sessions.first {
            let age = max(0, Int(now.timeIntervalSince(latest.end).rounded()))
            if age <= 300 && !latest.points.isEmpty {
                status = CurrentCollectionStatus(ready: true,
                                                 source: "saved_session_tail",
                                                 blocker: "none",
                                                 label: Self.diagnosticToken(latest.label),
                                                 samples: latest.points.count,
                                                 rrValues: latest.rrSampleCount,
                                                 ageSeconds: age,
                                                 durationSeconds: max(0, Int(latest.duration.rounded())))
            } else {
                status = CurrentCollectionStatus(ready: false,
                                                 source: "saved_session_tail",
                                                 blocker: age <= 300 ? "saved_tail_empty" : "saved_tail_stale",
                                                 label: Self.diagnosticToken(latest.label),
                                                 samples: latest.points.count,
                                                 rrValues: latest.rrSampleCount,
                                                 ageSeconds: age,
                                                 durationSeconds: max(0, Int(latest.duration.rounded())))
            }
        } else {
            status = CurrentCollectionStatus(ready: false,
                                             source: "none",
                                             blocker: "no_active_or_saved_tail",
                                             label: "none",
                                             samples: 0,
                                             rrValues: 0,
                                             ageSeconds: -1,
                                             durationSeconds: 0)
        }

        cachedCurrentCollectionStatus = (evaluatedAt: now, status: status)
        return status
    }

    private static func diagnosticToken(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? "none" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return text.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }

    private func totalRRSamples(in sessions: [SavedSession]) -> Int {
        sessions.reduce(0) { $0 + $1.rrSampleCount }
    }

    private func totalMotionHints(in sessions: [SavedSession]) -> Int {
        sessions.reduce(0) { $0 + $1.motionHintCountValue }
    }

    private func totalMotionShortSamples(in sessions: [SavedSession]) -> Int {
        sessions.reduce(0) { $0 + $1.motionShortCountValue }
    }

    private func totalHRRaw2A37(in sessions: [SavedSession]) -> Int {
        sessions.reduce(0) { $0 + $1.hrRaw2A37Value }
    }

    private func totalHRAccepted(in sessions: [SavedSession]) -> Int {
        sessions.reduce(0) { $0 + $1.hrAcceptedValue }
    }

    private func totalHRRawGaps(in sessions: [SavedSession]) -> Int {
        sessions.reduce(0) { $0 + $1.hrRawGapsValue }
    }

    private func totalHRAcceptedGaps(in sessions: [SavedSession]) -> Int {
        sessions.reduce(0) { $0 + $1.hrAcceptedGapsValue }
    }

    private func recentCanonicalSessions(windowDays: Int? = nil,
                                         limitSessions: Int? = nil,
                                         includeActiveJournal: Bool = false,
                                         now: Date = Date()) -> [SavedSession] {
        var recent = canonicalSessions(includeActiveJournal: includeActiveJournal)
        if let windowDays {
            let cutoff = now.addingTimeInterval(-Double(windowDays) * 24 * 60 * 60)
            recent = recent.filter { $0.start >= cutoff }
        }
        if let limitSessions {
            recent = Array(recent.prefix(max(1, limitSessions)))
        }
        return recent
    }

    private func canonicalSessions(includeActiveJournal: Bool = false) -> [SavedSession] {
        guard includeActiveJournal, let active = activeJournalSessionIfFresh() else {
            return cachedCanonicalSessions
        }
        return Self.makeCanonicalSessions(from: cachedCanonicalSessions + [active],
                                          preferredSession: preferredSession)
    }

    private nonisolated static func makeCanonicalSessions(from source: [SavedSession],
                                                          preferredSession: ((SavedSession, SavedSession) -> Bool)? = nil) -> [SavedSession] {
        var byID: [UUID: SavedSession] = [:]
        for session in source {
            if let existing = byID[session.id] {
                let prefersIncoming = preferredSession?(session, existing)
                    ?? defaultPreferredSession(session, over: existing)
                byID[session.id] = prefersIncoming ? session : existing
            } else {
                byID[session.id] = session
            }
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start > rhs.start }
            return lhs.end > rhs.end
        }
    }

    private nonisolated static func defaultPreferredSession(_ lhs: SavedSession, over rhs: SavedSession) -> Bool {
        if lhs.points.count != rhs.points.count {
            return lhs.points.count > rhs.points.count
        }
        if lhs.rrSampleCount != rhs.rrSampleCount {
            return lhs.rrSampleCount > rhs.rrSampleCount
        }
        if lhs.end != rhs.end {
            return lhs.end > rhs.end
        }
        return lhs.start > rhs.start
    }

    private func activeJournalSessionIfFresh(now: Date = Date()) -> SavedSession? {
        guard let record = ActiveSessionJournal.load(),
              record.schema == ActiveSessionJournal.schema,
              now.timeIntervalSince(record.updatedAt) <= 90 else {
            return nil
        }
        let samples = record.samples.sorted { $0.t < $1.t }
        guard let first = samples.first, let last = samples.last, samples.count > 1 else {
            return nil
        }
        let rr = (record.rrSamples ?? [])
            .filter { $0.t >= first.t && $0.t <= last.t.addingTimeInterval(1) }
            .sorted { $0.t < $1.t }
        let label = record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Long wear active"
            : "\(record.label) active"
        return SavedSession(id: record.id,
                            start: first.t,
                            end: last.t,
                            label: label,
                            points: samples.map { SavedSession.Point(t: $0.t.timeIntervalSince(first.t), bpm: $0.bpm) },
                            hrv: nil,
                            rrPoints: rr.isEmpty ? nil : rr.map { SavedSession.RRPoint(t: $0.t.timeIntervalSince(first.t), ms: $0.ms) },
                            hrvReferenceValidated: false,
                            motionHintCount: nil,
                            motionHintKinds: nil,
                            motionEvidenceSource: "active_journal_unvalidated",
                            motionEvidenceValidated: false,
                            motionShortCount: nil,
                            motionShortMean: nil,
                            motionShortMin: nil,
                            motionShortMax: nil,
                            motionShortOverOneCount: nil,
                            phoneMotionSource: nil,
                            phoneMotionValidated: false,
                            phoneMotionSamples: nil,
                            phoneMotionMeanDeltaG: nil,
                            phoneMotionMaxDeltaG: nil,
                            phoneMotionOverStillThreshold: nil,
                            phoneMotionStillThresholdG: nil,
                            hrRaw2A37: record.rawHRNotifications,
                            hrAccepted: record.acceptedHRSamples,
                            hrZero: record.zeroHRSamples,
                            hrArtifactHeld: record.heldArtifacts,
                            hrArtifactDropped: record.droppedArtifacts,
                            hrRawGaps: record.rawHRGaps,
                            hrAcceptedGaps: record.acceptedHRGaps,
                            hrMaxRawGap: record.maxRawHRGap,
                            hrMaxAcceptedGap: record.maxAcceptedHRGap)
    }

    private func preferredSession(_ candidate: SavedSession, over existing: SavedSession) -> Bool {
        if candidate.points.count != existing.points.count {
            return candidate.points.count > existing.points.count
        }
        if candidate.duration != existing.duration {
            return candidate.duration > existing.duration
        }
        return candidate.end > existing.end
    }

    @discardableResult
    func add(_ s: SavedSession) -> Bool {
        let mode = upsertSession(s)
        markSessionPersistenceDirty()
        refreshSessionDerivedCachesAfterUpsert(s)
        invalidateHomeDashboardDiagnosticsCache()
        scheduleSessionFilePersist(reason: "add", delay: 0.10)
        if mode == "replace" {
            rebuildBaselineFromEligibleSessions(reason: "session-add-replace")
        } else {
            learnBaselineIfEligible(from: s, reason: "session-add")
        }
        if let detection = s.detectedActivity(rest: baseline.restingInt ?? s.restingStable,
                                              maxHR: profile.maxHR) {
            WHOOPDebugLog("WHOOPDBG activity_detect kind=%@ confidence=%@ duration_s=%.0f avg_hr=%d peak_hr=%d reason=%@ motion_source=%@ motion_hints=%d motion_hint_kinds=%@ motion_validated=%d",
                  detection.kind.rawValue,
                  detection.confidence.rawValue,
                  detection.duration,
                  detection.avgHR,
                  detection.peakHR,
                  detection.reason,
                  s.motionEvidenceSourceValue,
                  s.motionHintCountValue,
                  s.motionHintKindsValue,
                  s.motionEvidenceValidatedValue ? 1 : 0)
        }
        writeAutomaticSessionBackup(reason: "session-add")
        return true
    }

    private func learnBaselineIfEligible(from session: SavedSession, reason: String) {
        let evidence = session.baselineLearningEvidence(rest: baseline.restingInt ?? session.restingStable,
                                                        maxHR: profile.maxHR)
        guard evidence.accepted else {
            WHOOPDebugLog("WHOOPDBG resting_baseline_sample status=skipped reason=%@ value=%d source=%@ label=%@ duration_s=%.0f avg_hr=%d peak_hr=%d hrv_validated=%d trigger=%@",
                  evidence.reason,
                  evidence.value,
                  evidence.source,
                  session.label,
                  session.duration,
                  session.avg,
                  session.peak,
                  session.referenceValidatedHRV == nil ? 0 : 1,
                  reason)
            return
        }
        baseline.learn(fromResting: evidence.value,
                       hrv: session.localRMSSD ?? 0,
                       at: session.end)
        baseline.save()
        refreshHomeDashboardDiagnosticsCache()
        WHOOPDebugLog("WHOOPDBG resting_baseline_sample status=accepted reason=%@ value=%d source=%@ label=%@ duration_s=%.0f avg_hr=%d peak_hr=%d hrv_validated=%d trigger=%@",
              evidence.reason,
              evidence.value,
              evidence.source,
              session.label,
              session.duration,
              session.avg,
              session.peak,
              session.referenceValidatedHRV == nil ? 0 : 1,
              reason)
    }

    private func rebuildBaselineFromEligibleSessions(reason: String,
                                                     refreshDiagnosticsCache: Bool = true) {
        let previousRest = baseline.restingInt
        let previousSamples = baseline.restingSampleCount
        var rebuilt = PersonalBaseline()
        var accepted = 0
        var skipped = 0
        for session in sessions.sorted(by: { $0.start < $1.start }) {
            let rest = rebuilt.restingInt ?? previousRest ?? session.restingStable
            let evidence = session.baselineLearningEvidence(rest: rest, maxHR: profile.maxHR)
            if evidence.accepted {
                rebuilt.learn(fromResting: evidence.value,
                              hrv: session.localRMSSD ?? 0,
                              at: session.end)
                accepted += 1
            } else {
                skipped += 1
            }
        }
        baseline = rebuilt
        baseline.save()
        if refreshDiagnosticsCache {
            refreshHomeDashboardDiagnosticsCache()
        } else {
            cachedHomeDashboardDiagnostics = nil
        }
        WHOOPDebugLog("WHOOPDBG baseline_rebuild status=ok reason=%@ accepted=%d skipped=%d old_rest=%@ new_rest=%@ old_samples=%d new_samples=%d hrv_baseline_samples=%d",
              reason,
              accepted,
              skipped,
              previousRest.map(String.init) ?? "learning",
              baseline.restingInt.map(String.init) ?? "learning",
              previousSamples,
              baseline.restingSampleCount,
              baseline.hrvSampleCount)
    }

    @discardableResult
    func checkpoint(_ s: SavedSession) -> Bool {
        _ = upsertSession(s)
        markSessionPersistenceDirty()
        refreshSessionDerivedCachesAfterUpsert(s)
        scheduleSessionFilePersist(reason: "checkpoint", delay: Self.checkpointPersistenceDelay)
        if let detection = s.detectedActivity(rest: baseline.restingInt ?? s.restingStable,
                                              maxHR: profile.maxHR) {
            WHOOPDebugLog("WHOOPDBG activity_detect kind=%@ confidence=%@ duration_s=%.0f avg_hr=%d peak_hr=%d reason=%@ source=checkpoint motion_source=%@ motion_hints=%d motion_hint_kinds=%@ motion_validated=%d",
                  detection.kind.rawValue,
                  detection.confidence.rawValue,
                  detection.duration,
                  detection.avgHR,
                  detection.peakHR,
                  detection.reason,
                  s.motionEvidenceSourceValue,
                  s.motionHintCountValue,
                  s.motionHintKindsValue,
                  s.motionEvidenceValidatedValue ? 1 : 0)
        }
        return true
    }

    func delete(_ offsets: IndexSet) {
        sessions.remove(atOffsets: offsets)
        markSessionPersistenceDirty()
        refreshSessionDerivedCaches()
        invalidateHomeDashboardDiagnosticsCache()
        scheduleSessionFilePersist(reason: "delete", delay: 0.10)
        writeAutomaticSessionBackup(reason: "session-delete")
    }

    func deleteSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        delete(IndexSet(integer: index))
    }

    func updateProfile(_ edit: (inout AthleteProfile) -> Void) {
        var next = profile
        edit(&next)
        next.clamp()
        guard next != profile else { return }
        profile = next
        profile.save()
        invalidateHomeDashboardDiagnosticsCache()
        WHOOPDebugLog("WHOOPDBG strain_profile age=%d source=%@ max_hr=%d measured_max_hr=%d",
              profile.age, profile.maxHRSource.rawValue, profile.maxHR, profile.measuredMaxHR)
        writeAutomaticSessionBackup(reason: "profile-update")
    }

    func completeOnboarding(with profile: AthleteProfile) {
        var next = profile
        next.completeOnboarding()
        guard next != self.profile else { return }
        self.profile = next
        self.profile.save()
        invalidateHomeDashboardDiagnosticsCache()
        WHOOPDebugLog("WHOOPDBG onboarding complete=1 age=%d source=%@ max_hr=%d measured_max_hr=%d",
              self.profile.age,
              self.profile.maxHRSource.rawValue,
              self.profile.maxHR,
              self.profile.measuredMaxHR)
        writeAutomaticSessionBackup(reason: "onboarding")
    }

    func completeOnboardingFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard AtriaDeveloperMode.isEnabled else { return }
        guard arguments.contains("--whoop-complete-onboarding") else { return }
        completeOnboarding(with: profile)
    }

    func logBaselineMaturityFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-log-baseline") else { return }
        let restingStats = baseline.restingStats
        let hrvStats = baseline.lnRMSSDStats
        let latestValidated = latestReferenceValidatedHRV ?? 0
        let hrvReady = baseline.hrvSampleCount >= 7
        let recoveryPersonalReady = hrvReady && baseline.restingStats != nil
        let recoveryValidatedReady = recoveryPersonalReady && latestValidated > 0
        WHOOPDebugLog("WHOOPDBG baseline_maturity sessions=%d resting_samples=%d resting_mean=%@ resting_sd=%@ hrv_baseline_samples=%d hrv_required=7 hrv_ready=%d latest_validated_hrv=%d recovery_personal_ready=%d recovery_validated_ready=%d",
              baseline.sessions,
              baseline.restingSampleCount,
              restingStats.map { String(format: "%.1f", $0.mean) } ?? "learning",
              restingStats.map { String(format: "%.1f", $0.sd) } ?? "learning",
              baseline.hrvSampleCount,
              hrvReady ? 1 : 0,
              latestValidated,
              recoveryPersonalReady ? 1 : 0,
              recoveryValidatedReady ? 1 : 0)
        WHOOPDebugLog("WHOOPDBG baseline_hrv_stats count=%d lnrmssd_mean=%@ lnrmssd_sd=%@ state=%@",
              hrvStats?.count ?? 0,
              hrvStats.map { String(format: "%.3f", $0.mean) } ?? "learning",
              hrvStats.map { String(format: "%.3f", $0.sd) } ?? "learning",
              recoveryPersonalReady ? "personal_baseline" : "learning")
    }

    func logCollectionHealthFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-log-collection-health") else { return }
        if !arguments.contains("--whoop-log-collection-health-delay-fired"),
           let delayIndex = arguments.firstIndex(of: "--whoop-log-collection-health-after"),
           arguments.indices.contains(arguments.index(after: delayIndex)),
           let delay = Double(arguments[arguments.index(after: delayIndex)]),
           delay > 0 {
            WHOOPDebugLog("WHOOPDBG collection_health_schedule delay_s=%.1f", delay)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                var delayedArguments = arguments
                delayedArguments.append("--whoop-log-collection-health-delay-fired")
                self.logCollectionHealthFromLaunchIfRequested(arguments: delayedArguments)
            }
            return
        }
        let phase = arguments.contains("--whoop-log-collection-health-delay-fired") ? "delayed" : "launch"
        let journal = ActiveSessionJournal.diagnostics()
        let linkEvidence = WhoopBLEManager.linkEvidence().replacingOccurrences(of: " ", with: "_")
        let sampleEvidence = WhoopBLEManager.sampleGapEvidence().replacingOccurrences(of: " ", with: "_")
        let watchdogEvidence = WhoopBLEManager.watchdogRecoveryEvidence().replacingOccurrences(of: " ", with: "_")
        let rrState: String
        if journal.rrContinuityReady {
            rrState = "gate_b_window_ready"
        } else if journal.recentRRContinuityClean {
            rrState = "recent_rr_clean"
        } else if journal.hasCurrentRR {
            rrState = "rr_present_learning"
        } else {
            rrState = "hr_only_or_missing"
        }
        let collectionReady = journal.present && journal.fresh && journal.samples > 0
        let blocker: String
        if collectionReady {
            blocker = "none"
        } else if !journal.present {
            blocker = "active_journal_missing"
        } else if !journal.fresh {
            blocker = "active_journal_stale"
        } else {
            blocker = "active_journal_empty"
        }
        WHOOPDebugLog("WHOOPDBG collection_health phase=%@ status=%@ blocker=%@ active_journal_present=%d active_journal_fresh=%d active_journal_samples=%d active_journal_rr_values=%d active_journal_duration_s=%d active_journal_rr_coverage_3s_percent=%d active_journal_recent_rr_values=%d active_journal_recent_rr_duration_s=%d active_journal_recent_rr_coverage_3s_percent=%d rr_state=%@ gate_b_current_rr_ready=%d metric_promotions=0 %@ %@ %@",
              phase,
              collectionReady ? "ready" : "learning",
              blocker,
              journal.present ? 1 : 0,
              journal.fresh ? 1 : 0,
              journal.samples,
              journal.rrValues,
              Int(journal.duration.rounded()),
              journal.rrCoverage3Percent,
              journal.recentRRValues,
              Int(journal.recentRRDuration.rounded()),
              journal.recentRRCoverage3Percent,
              rrState,
              journal.rrContinuityReady ? 1 : 0,
              linkEvidence,
              sampleEvidence,
              watchdogEvidence)
    }

    func logGateReadinessFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-log-gate-readiness") else { return }
        if !arguments.contains("--whoop-log-gate-readiness-delay-fired") {
            let delay = arguments.contains("--whoop-standard-hr-only") || arguments.contains("--whoop-long-wear-mode") ? 8.0 : 1.0
            WHOOPDebugLog("WHOOPDBG gate_readiness_ui schedule delay_s=%.1f reason=launch_arg", delay)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                var delayedArguments = arguments
                delayedArguments.append("--whoop-log-gate-readiness-delay-fired")
                self.logGateReadinessFromLaunchIfRequested(arguments: delayedArguments)
            }
            return
        }

        let rest = baseline.restingInt ?? 60
        let maxHR = profile.maxHR
        let hrvValidated = sessions.compactMap(\.referenceValidatedHRV).filter { $0 > 0 }.count
        let health = HealthKitExporter.diagnostics(for: sessions,
                                                   rest: rest,
                                                   maxHR: maxHR,
                                                   confirmedWorkouts: confirmedWorkouts,
                                                   confirmedSleeps: confirmedSleeps)
        let widget = WidgetSnapshotPublisher.diagnostics
        let archive = HistoricalArchive.diagnostics()
        let healthHRVReady = hrvValidated > 0 && health.planned.hrvSamples > 0
        let healthWorkoutReady = health.planned.workouts > 0
        let gateGPlatformBlockers = [
            health.entitlementPresent ? nil : "healthkit_entitlement",
            health.healthDataAvailable ? nil : "healthkit_unavailable",
            health.planned.hrSamples > 0 ? nil : "healthkit_hr_missing",
            health.readback.dataAppears ? nil : "healthkit_hr_readback_missing",
            widget.widgetTargetPresent ? nil : "widget_target",
            widget.appGroupEnabled ? nil : "app_group",
            widget.complicationTargetPresent ? nil : "complication_target"
        ].compactMap { $0 }
        let gateGMetricBlockers = [
            health.readback.overfilledTotalAtriaHRSamples > 0 ? "healthkit_hr_overfilled:\(health.readback.overfilledTotalAtriaHRSamples)" : nil,
            health.readback.expectedTotalAtriaHRSamples <= 0 || health.readback.expectedTotalCovered ? nil : "healthkit_hr_backfill_pending:\(health.readback.missingTotalAtriaHRSamples)",
            healthHRVReady ? nil : (hrvValidated > 0 ? "healthkit_hrv_missing" : "healthkit_hrv_reference_pending"),
            healthWorkoutReady ? nil : "healthkit_workout_learning"
        ].compactMap { $0 }
        let gateGPlatformReady = gateGPlatformBlockers.isEmpty
        let gateGStatus = gateGPlatformReady
            ? (gateGMetricBlockers.isEmpty ? "ready" : "metric_gated")
            : "partial"
        let gateGBlocker = gateGStatus == "ready"
            ? "none"
            : (gateGPlatformReady
               ? "platform_ready_metric_blockers:\(gateGMetricBlockers.joined(separator: "+"))"
               : "platform_blockers:\(gateGPlatformBlockers.joined(separator: "+"))")

        let strainSummary = strainValidationStatus(rest: rest, maxHR: maxHR)
        let healthReference = health.referenceAudit
        let externalHRReferenceReady = healthReference.externalReferenceReady || externalHRReferenceValidated
        let gateDBlocker = strainSummary.ready
            ? "none"
            : (externalHRReferenceReady
               ? strainSummary.primaryBlocker
               : (healthReference.status == "ok" ? healthReference.validationReason : "healthkit_reference_\(healthReference.status)"))

        let gateETraining = gateETrainingSummary(rest: rest, maxHR: maxHR)
        let gateEStatus: String
        let gateEBlocker: String
        if gateETraining.autoReady {
            gateEStatus = "ready"
            gateEBlocker = "none"
        } else if gateETraining.hasConfirmedEvidence {
            gateEStatus = "user_confirmed"
            gateEBlocker = "auto_detection_required:\(gateETraining.nextProof)"
        } else {
            gateEStatus = "partial"
            gateEBlocker = gateETraining.primaryBlocker
        }

        let trend90 = trendSummaries(rest: rest, maxHR: maxHR).first { $0.days == 90 }
        let gateFReadinessStatus = gateFStatus(summary: trend90, hrvValidated: hrvValidated)
        let gateHProtocolReady = archive.exists
            && archive.parseOK
            && archive.rows > 0
            && archive.rawPayloadRows > 0
            && archive.undecodableRows == 0
        let gateHBlocker = gateHProtocolReady
            ? "none"
            : (archive.exists ? "historical_archive_incomplete" : "historical_download_missing")
        let rows: [(gate: String, status: String, blocker: String)] = [
            ("A", "runtime_required", "physical_device_runtime"),
            ("B", hrvValidated > 0 ? "reference_partial" : "reference_pending", "external_rr_reference"),
            ("C", latestReferenceValidatedHRV != nil && baseline.hrvSampleCount >= 7 ? "ready" : "learning", "validated_hrv_baseline_\(baseline.hrvSampleCount)_of_7"),
            ("D", strainSummary.ready ? "ready" : "partial", gateDBlocker),
            ("E", gateEStatus, gateEBlocker),
            ("F", gateFReadinessStatus, "coverage_\(trend90?.coveragePercent ?? 0)pct_hrv_gated"),
            ("G", gateGStatus, gateGBlocker),
            ("H", gateHProtocolReady ? "ready" : "partial", gateHBlocker)
        ]
        let readyCount = rows.filter { $0.status == "ready" }.count
        let evidence = rows
            .map { "\($0.gate)=\($0.status)[\($0.blocker)]" }
            .joined(separator: ";")
            .replacingOccurrences(of: " ", with: "_")
        WHOOPDebugLog("WHOOPDBG gate_readiness_ui source=launch_arg gates=%d ready=%d evidence=%@",
              rows.count,
              readyCount,
              evidence)
    }

    func logGateStatusFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-log-gate-status") else { return }
        let explicitDelay: Double? = {
            guard let delayIndex = arguments.firstIndex(of: "--whoop-log-gate-status-after"),
                  arguments.indices.contains(arguments.index(after: delayIndex)),
                  let delay = Double(arguments[arguments.index(after: delayIndex)]),
                  delay > 0 else { return nil }
            return delay
        }()
        let liveCollectionSettleDelay: Double? = {
            guard !arguments.contains("--whoop-log-gate-status-delay-fired"),
                  explicitDelay == nil,
                  arguments.contains("--whoop-standard-hr-only") || arguments.contains("--whoop-long-wear-mode") else {
                return nil
            }
            return 18
        }()
        if !arguments.contains("--whoop-log-gate-status-delay-fired"),
           let delay = explicitDelay ?? liveCollectionSettleDelay {
            let clampedDelay = min(max(delay, 0), 86_400)
            WHOOPDebugLog("WHOOPDBG gate_status schedule delay_s=%.1f reason=%@", clampedDelay, explicitDelay != nil ? "launch_arg" : "live_collection_settle")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(clampedDelay))
                var delayedArguments = arguments
                delayedArguments.append("--whoop-log-gate-status-delay-fired")
                logGateStatusFromLaunchIfRequested(arguments: delayedArguments)
            }
            return
        }
        let includeDeepReplay = arguments.contains("--whoop-log-gate-status-deep")
        let mode = includeDeepReplay ? "deep" : "fast"
        let rest = baseline.restingInt ?? 60
        let hrvValidated = sessions.compactMap(\.referenceValidatedHRV).filter { $0 > 0 }.count
        let hrvBaselineReady = baseline.hrvSampleCount >= 7
        let recoveryHighReady = hrvBaselineReady && latestReferenceValidatedHRV != nil
        let rrSessions = sessions.filter { $0.rrSampleCount > 0 }.count
        let rrSamples = totalRRSamples(in: sessions)
        let hrAcceptedSamples = totalHRAccepted(in: sessions)
        let boundedLargeStore = sessions.count > 120 || hrAcceptedSamples > 20_000 || rrSamples > 20_000
        let workoutReplayLimit = boundedLargeStore ? 80 : nil
        let workoutReplayScope = boundedLargeStore ? "bounded_large_store" : "full"
        WHOOPDebugLog("WHOOPDBG gate_status_start mode=%@ deep_replay=%d sessions=%d rr_sessions=%d rr_samples=%d hr_accepted=%d hrv_validated_sessions=%d hrv_baseline_samples=%d workout_replay_scope=%@ workout_replay_limit=%d",
              mode,
              includeDeepReplay ? 1 : 0,
              sessions.count,
              rrSessions,
              rrSamples,
              hrAcceptedSamples,
              hrvValidated,
              baseline.hrvSampleCount,
              workoutReplayScope,
              workoutReplayLimit ?? 0)
        if boundedLargeStore && !includeDeepReplay {
            logBoundedLargeStoreGateStatus(mode: mode,
                                           rest: rest,
                                           hrvValidated: hrvValidated,
                                           hrvBaselineReady: hrvBaselineReady,
                                           recoveryHighReady: recoveryHighReady,
                                           rrSessions: rrSessions,
                                           rrSamples: rrSamples,
                                           hrAcceptedSamples: hrAcceptedSamples,
                                           workoutReplayLimit: workoutReplayLimit)
            return
        }
        let rollups = dailyRollups(rest: rest, maxHR: profile.maxHR)
        let sleepDays = rollups.filter { $0.sleepReady > 0 }.count
        let sleepCandidateDays = rollups.filter { $0.sleepCandidates > 0 }.count
        let workoutDays = rollups.filter { $0.workouts > 0 }.count
        let motionHintSessions = sessions.filter { $0.motionHintCountValue > 0 }.count
        let motionHintTotal = sessions.reduce(0) { $0 + $1.motionHintCountValue }
        let sleepMotionSource = motionHintTotal > 0 ? "diagnostic_observe_only" : "unavailable"
        let trendSummaries = trendSummaries(rest: rest, maxHR: profile.maxHR)
        let trend90 = trendSummaries.first { $0.days == 90 }
        let trend90Blockers = trendBlockers(summary: trend90, hrvValidated: hrvValidated)
        let trend90AnomalyFlags = trend90.map { trendAnomalyFlags($0.anomalies) } ?? "none"
        let latestBackup = latestSessionBackupURL()
        let backupAvailable = latestBackup != nil
        let backupLabel = latestBackup.map { backupRelativePath(for: $0) } ?? "none"
        let backupCurrent = latestBackup.map { latestBackupMatchesCurrentStore($0) } ?? false
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=local_rollups mode=%@ days=%d sleep_days=%d sleep_candidate_days=%d workout_days=%d trend90_coverage_percent=%d backup_available=%d backup_current=%d",
              mode,
              rollups.count,
              sleepDays,
              sleepCandidateDays,
              workoutDays,
              trend90?.coveragePercent ?? 0,
              backupAvailable ? 1 : 0,
              backupCurrent ? 1 : 0)
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=healthkit_diagnostics_start mode=%@", mode)
        let confirmedWorkoutRecords = confirmedWorkouts
        let confirmedSleepRecords = confirmedSleeps
        let confirmedWorkoutCount = confirmedWorkoutRecords.count
        let confirmedSleepCount = confirmedSleepRecords.count
        let healthKit = HealthKitExporter.diagnostics(for: sessions,
                                                      rest: rest,
                                                      maxHR: profile.maxHR,
                                                      confirmedWorkouts: confirmedWorkoutRecords,
                                                      confirmedSleeps: confirmedSleepRecords)
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=healthkit_diagnostics_done mode=%@ entitlement=%d available=%d planned_hr=%d planned_workouts=%d planned_hrv=%d planned_sleeps=%d reference_status=%@ reference_ready=%d readback_status=%@ readback_missing_total_atria_hr_samples=%d readback_overfill_total_atria_hr_samples=%d readback_reconciliation=%@",
              mode,
              healthKit.entitlementPresent ? 1 : 0,
              healthKit.healthDataAvailable ? 1 : 0,
              healthKit.planned.hrSamples,
              healthKit.planned.workouts,
              healthKit.planned.hrvSamples,
              healthKit.planned.sleeps,
              healthKit.referenceAudit.status,
              healthKit.referenceAudit.externalReferenceReady ? 1 : 0,
              healthKit.readback.status,
              healthKit.readback.missingTotalAtriaHRSamples,
              healthKit.readback.overfilledTotalAtriaHRSamples,
              healthKit.readback.reconciliationStatus)
        let csvHRReference = csvHRReferenceDiagnostics
        let csvHRReferenceReady = externalHRReferenceValidated
        let externalHRReferenceReady = healthKit.referenceAudit.externalReferenceReady || csvHRReferenceReady
        let externalHRReferenceSourceLabel = healthKit.referenceAudit.externalReferenceReady
            ? "healthkit_validated"
            : self.externalHRReferenceSource
        let widget = WidgetSnapshotPublisher.diagnostics
        let checkpointArmed = UserDefaults.standard.bool(forKey: WhoopBLEManager.CheckpointDefaults.armed)
        let checkpointInterval = UserDefaults.standard.double(forKey: WhoopBLEManager.CheckpointDefaults.interval)
        let checkpointLabel = UserDefaults.standard.string(forKey: WhoopBLEManager.CheckpointDefaults.label) ?? "none"
        let checkpointSource = UserDefaults.standard.string(forKey: WhoopBLEManager.CheckpointDefaults.source) ?? "none"
        let checkpointLastStatus = UserDefaults.standard.string(forKey: WhoopBLEManager.CheckpointDefaults.lastStatus) ?? "none"
        let checkpointLastIndex = UserDefaults.standard.integer(forKey: WhoopBLEManager.CheckpointDefaults.lastIndex)
        let checkpointLastSamples = UserDefaults.standard.integer(forKey: WhoopBLEManager.CheckpointDefaults.lastSamples)
        let checkpointLastDuration = UserDefaults.standard.integer(forKey: WhoopBLEManager.CheckpointDefaults.lastDuration)
        let checkpointEvidence = "checkpoint_armed=\(checkpointArmed ? 1 : 0); checkpoint_interval_s=\(Int(checkpointInterval)); checkpoint_source=\(checkpointSource); checkpoint_label=\(checkpointLabel); checkpoint_last_status=\(checkpointLastStatus); checkpoint_last_index=\(checkpointLastIndex); checkpoint_last_samples=\(checkpointLastSamples); checkpoint_last_duration_s=\(checkpointLastDuration)"
        let linkEvidence = WhoopBLEManager.linkEvidence()
        let sampleEvidence = WhoopBLEManager.sampleGapEvidence()
        let watchdogEvidence = WhoopBLEManager.watchdogRecoveryEvidence()
        let batteryEvidence = WhoopBLEManager.batteryEvidence()
        let radioEvidence = WhoopBLEManager.radioEvidence()
        let offlineSyncEvidence = WhoopBLEManager.offlineSyncEvidence()
        let protocolEvidence = WhoopBLEManager.protocolEvidence()
        let journalEvidence = WhoopBLEManager.activeSessionJournalEvidence()
        let historicalArchive = HistoricalArchive.diagnostics()
        let historicalArchiveSchemas = historicalArchive.schemas.isEmpty ? "none" : historicalArchive.schemas.joined(separator: ",")
        let historicalArchiveLayouts = historicalArchive.layoutVersions.isEmpty ? "none" : historicalArchive.layoutVersions.joined(separator: ",")
        let historicalDownloadProtocolValidated = historicalArchive.exists
            && historicalArchive.parseOK
            && historicalArchive.rows > 0
            && historicalArchive.rawPayloadRows > 0
            && historicalArchive.undecodableRows == 0
        let historicalRRMetricReady = historicalDownloadProtocolValidated
            && historicalArchive.metricUsableRows > 0
            && historicalArchive.currentSessionUsableRows > 0
        let gateHStatus = historicalDownloadProtocolValidated ? "ready" : "partial"
        let reserveHR = max(profile.maxHR - rest, 0)
        let thresholdHR = rest + Int((Double(reserveHR) * 0.50).rounded())
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=workout_replay_start mode=%@ sessions=%d scope=%@ limit=%d",
              mode,
              sessions.count,
              workoutReplayScope,
              workoutReplayLimit ?? 0)
        let workoutReplay = replaySavedWorkoutReadiness(rest: rest,
                                                        maxHR: profile.maxHR,
                                                        limitSessions: workoutReplayLimit,
                                                        includeAggregates: workoutReplayLimit == nil,
                                                        includeActiveJournal: true)
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=workout_replay_done mode=%@ ready=%d best_source=%@ best_blocker=%@ best_next_action=%@ scope=%@ limit=%d",
              mode,
              workoutReplay.readySessions,
              workoutReplay.bestSource,
              workoutReplay.bestPrimaryBlocker,
              workoutReplay.bestNextAction,
              workoutReplayScope,
              workoutReplayLimit ?? 0)
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=historical_gap_repair_start mode=%@", mode)
        let historicalGapRepair = historicalGapRepairSummary(workoutReplay: workoutReplay,
                                                             archive: historicalArchive)
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=historical_gap_repair_done mode=%@ status=%@ reason=%@ metric_usable=%d",
              mode,
              historicalGapRepair.status,
              historicalGapRepair.reason,
              historicalGapRepair.metricUsable ? 1 : 0)
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=strain_validation_start mode=%@", mode)
        let strainValidation = strainValidationSummary(rest: rest, maxHR: profile.maxHR)
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=strain_validation_done mode=%@ ready=%d blocker=%@ stream_coverage_percent=%d max_hrr_percent=%d",
              mode,
              strainValidation.ready ? 1 : 0,
              strainValidation.primaryBlocker,
              strainValidation.streamCoveragePercent,
              Int((strainValidation.maxHRReserve * 100).rounded()))
        WHOOPDebugLog("WHOOPDBG gate_status_summary mode=%@ deep_replay=%d sessions=%d days=%d rest_hr=%d max_hr=%d hrv_validated_sessions=%d hrv_baseline_samples=%d backup_available=%d backup_current=%d healthkit_entitlement=%d healthkit_available=%d healthkit_hr_samples=%d healthkit_workouts=%d healthkit_hrv_samples=%d healthkit_sleeps=%d",
              mode,
              includeDeepReplay ? 1 : 0,
              sessions.count,
              rollups.count,
              rest,
              profile.maxHR,
              hrvValidated,
              baseline.hrvSampleCount,
              backupAvailable ? 1 : 0,
              backupCurrent ? 1 : 0,
              healthKit.entitlementPresent ? 1 : 0,
              healthKit.healthDataAvailable ? 1 : 0,
              healthKit.planned.hrSamples,
              healthKit.planned.workouts,
              healthKit.planned.hrvSamples,
              healthKit.planned.sleeps)
        let rrReplayLimit = includeDeepReplay ? 0 : 12
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=rr_replay_start mode=%@ rr_sessions=%d rr_samples=%d limit=%d",
              mode,
              rrSessions,
              rrSamples,
              rrReplayLimit)
        let rrReplay = replaySavedRRLedger(limitSessions: rrReplayLimit == 0 ? nil : rrReplayLimit,
                                           includeActiveJournal: true)
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=rr_replay_done mode=%@ ready=%d label=%@ raw=%d kept=%d conf=%d max_gap_s=%.1f reason=%@ limit=%d",
              mode,
              rrReplay.bestReady ? 1 : 0,
              rrReplay.bestSessionLabel,
              rrReplay.bestRaw,
              rrReplay.bestKept,
              rrReplay.bestConfidencePercent,
              rrReplay.bestMaxRRGapSeconds,
              rrReplay.reason,
              rrReplayLimit)
        let collectionEvidence = currentCollectionStatus().evidence
        let sleepEvidence = sleepEvidenceStatus(rest: rest, sleepDays: sleepDays)
        let sleepState = sleepEvidence.state
        let sleepEvidenceReady = sleepEvidence.ready
        let gateEReady = sleepEvidenceReady && workoutReplay.readySessions > 0
        let userConfirmedGateE = confirmedWorkoutCount > 0 && confirmedSleepCount > 0
        let gateEStatus = gateEReady
            ? "ready"
            : (userConfirmedGateE ? "user_confirmed" : "partial")
        logGateStatus("local", status: "dashboard",
                      evidence: "status_mode=\(mode); sleep_days=\(sleepDays); sleep_candidate_days=\(sleepCandidateDays); sleep_state=\(sleepDays > 0 ? "ready" : (sleepCandidateDays > 0 ? "candidate" : "learning")); sleep_fallback_available=\(sleepEvidence.fallbackAvailable ? 1 : 0); sleep_fallback_source=\(sleepEvidence.fallbackSource); sleep_fallback_duration_s=\(Int(sleepEvidence.fallbackDuration.rounded())); sleep_fallback_span_s=\(Int(sleepEvidence.fallbackSpan.rounded())); sleep_fallback_chunks=\(sleepEvidence.fallbackSessions); sleep_fallback_diagnostic_only=1; workout_days=\(workoutDays); workout_state=\(workoutReplay.readySessions > 0 ? "ready" : "learning"); workout_replay_scope=\(workoutReplayScope); workout_replay_limit_sessions=\(workoutReplayLimit ?? 0); hrv_state=\(hrvValidated > 0 ? "reference_partial" : "reference_pending"); hrv_validated_sessions=\(hrvValidated); hrv_baseline_samples=\(baseline.hrvSampleCount); recovery_state=\(recoveryHighReady ? "ready" : "learning"); trend90_coverage_percent=\(trend90?.coveragePercent ?? 0); trend_state=\(trend90?.confidence ?? "learning"); motion_source=\(sleepMotionSource); motion_hint_sessions=\(motionHintSessions); motion_hints=\(motionHintTotal); motion_validated=0; historical_gap_repair_status=\(historicalGapRepair.status); historical_gap_repair_reason=\(historicalGapRepair.reason); historical_gap_repair_metric_usable=\(historicalGapRepair.metricUsable ? 1 : 0); historical_gap_repair_diagnostic_only=1; external_rr_reference=\(hrvValidated > 0 ? "present" : "missing"); \(checkpointEvidence); \(linkEvidence); \(sampleEvidence); \(watchdogEvidence); \(batteryEvidence); \(radioEvidence); \(offlineSyncEvidence); \(protocolEvidence); \(journalEvidence); \(collectionEvidence)")
        logGateStatus("A", status: "runtime_required", evidence: "BLE realtime must be checked in live WHOOPDBG for this launch")
        let hrvDisplayTier = hrvValidated > 0 ? "validated" : (rrReplay.bestReady ? "personal_baseline" : "learning")
        logGateStatus("B", status: hrvValidated > 0 ? "reference_partial" : "reference_pending",
                      evidence: "status_mode=\(mode); display_tier=\(hrvDisplayTier); validated_hrv_sessions=\(hrvValidated); saved_rr_ready=\(rrReplay.bestReady ? 1 : 0); saved_rr_sessions=\(rrReplay.sessionsWithRR); saved_rr_samples=\(rrReplay.rrSamples); saved_rr_best_label=\(rrReplay.bestSessionLabel); saved_rr_best_raw=\(rrReplay.bestRaw); saved_rr_best_kept=\(rrReplay.bestKept); saved_rr_best_conf=\(rrReplay.bestConfidencePercent); saved_rr_best_gap_s=\(String(format: "%.1f", rrReplay.bestMaxRRGapSeconds)); saved_rr_best_rmssd=\(rrReplay.bestRMSSD.map { String(format: "%.1f", $0) } ?? "learning"); saved_rr_reason=\(rrReplay.reason); rr_replay=\(rrReplayLimit == 0 ? "computed_exhaustive" : "computed_bounded_fast"); rr_replay_limit=\(rrReplayLimit); rr_replay_active_journal=1; external_rr_reference_optional=1; validated_tier_requires_external_reference=1; reference_validated=\(hrvValidated > 0 ? 1 : 0)")
        logGateStatus("C", status: recoveryHighReady ? "ready" : "learning",
                      evidence: "validated_hrv_baseline=\(baseline.hrvSampleCount)/7; latest_validated_hrv=\(latestReferenceValidatedHRV ?? 0)")
        let healthReference = healthKit.referenceAudit
        let gateDPrimaryBlocker = strainValidation.ready
            ? "none"
            : strainValidation.primaryBlocker
        logGateStatus("D", status: strainValidation.ready ? "ready" : "partial",
                      evidence: "status_mode=\(mode); profile_max_hr=\(profile.maxHR); rest_hr=\(rest); reserve_hr=\(reserveHR); hr_accepted_samples=\(hrAcceptedSamples); rest_to_max_ready=\(strainValidation.restToMaxReady ? 1 : 0); ready=\(strainValidation.ready ? 1 : 0); primary_blocker=\(gateDPrimaryBlocker); healthkit_reference_status=\(healthReference.status); healthkit_total_hr_samples=\(healthReference.totalHRSamples); healthkit_atria_hr_samples=\(healthReference.atriaHRSamples); healthkit_independent_candidate_hr_samples=\(healthReference.independentCandidateHRSamples); healthkit_user_entered_hr_samples=\(healthReference.userEnteredHRSamples); healthkit_rejected_user_entered_hr_samples=\(healthReference.rejectedUserEnteredHRSamples); healthkit_independent_hr_samples=\(healthReference.independentHRSamples); healthkit_independent_sources=\(healthReference.independentSources); healthkit_reference_pairs=\(healthReference.validationPairs); healthkit_reference_mean_delta_bpm=\(healthReference.validationMeanDelta.map { String(format: "%.2f", $0) } ?? "none"); healthkit_reference_max_delta_bpm=\(healthReference.validationMaxDelta.map { String(format: "%.2f", $0) } ?? "none"); healthkit_reference_reason=\(healthReference.validationReason); healthkit_external_reference_ready=\(healthReference.externalReferenceReady ? 1 : 0); csv_reference_status=\(csvHRReference.status); csv_reference_reason=\(csvHRReference.reason); csv_reference_pairs=\(csvHRReference.pairs); csv_reference_samples=\(csvHRReference.referenceSamples); csv_reference_mean_delta_bpm=\(csvHRReference.meanDelta.map { String(format: "%.2f", $0) } ?? "none"); csv_reference_median_delta_bpm=\(csvHRReference.medianDelta.map { String(format: "%.2f", $0) } ?? "none"); csv_reference_max_delta_bpm=\(csvHRReference.maxDelta.map { String(format: "%.2f", $0) } ?? "none"); csv_reference_within_tolerance_percent=\(csvHRReference.withinTolerancePercent); csv_external_hr_reference_ready=\(csvHRReferenceReady ? 1 : 0); external_hr_reference_source=\(externalHRReferenceSourceLabel); external_hr_reference_required=1")
        logGateStatus("E", status: gateEStatus,
                      evidence: "status_mode=\(mode); sleep_days=\(sleepDays); sleep_state=\(sleepState); sleep_ready=\(sleepEvidenceReady ? 1 : 0); sleep_blocker=\(sleepEvidence.blocker); sleep_confidence=\(sleepEvidence.confidence); sleep_candidates=\(sleepEvidence.candidates); sleep_ready_candidates=\(sleepEvidence.readyCandidates); sleep_fallback_available=\(sleepEvidence.fallbackAvailable ? 1 : 0); sleep_fallback_source=\(sleepEvidence.fallbackSource); sleep_fallback_duration_s=\(Int(sleepEvidence.fallbackDuration.rounded())); sleep_fallback_span_s=\(Int(sleepEvidence.fallbackSpan.rounded())); sleep_fallback_chunks=\(sleepEvidence.fallbackSessions); sleep_fallback_reason=\(sleepEvidence.fallbackReason); sleep_fallback_diagnostic_only=1; confirmed_workouts=\(confirmedWorkoutCount); confirmed_sleeps=\(confirmedSleepCount); user_confirmed_gate_e=\(userConfirmedGateE ? 1 : 0); auto_gate_e_ready=\(gateEReady ? 1 : 0); auto_detection_required=\(gateEReady ? 0 : 1); workout_days=\(workoutReplay.readySessions); workout_state=\(workoutReplay.readySessions > 0 ? "ready" : "learning"); workout_replay_scope=\(workoutReplayScope); workout_replay_limit_sessions=\(workoutReplayLimit ?? 0); workout_replay_aggregates=\(workoutReplayLimit == nil ? 1 : 0); workout_replay_active_journal=1; workout_saved_ready=\(workoutReplay.readySessions); workout_near_miss=\(workoutReplay.nearMiss ? 1 : 0); workout_near_miss_reason=\(workoutReplay.nearMissReason); workout_strength_candidate=\(workoutReplay.strengthCandidate ? 1 : 0); workout_strength_candidate_reason=\(workoutReplay.strengthCandidateReason); workout_strength_diagnostic_only=1; workout_next_action=\(workoutReplay.bestNextAction); workout_best_source=\(workoutReplay.bestSource); workout_best_chunks=\(workoutReplay.bestChunkCount); workout_best_reason=\(workoutReplay.bestReason); workout_best_blocker=\(workoutReplay.bestPrimaryBlocker); workout_best_stream_coverage_percent=\(workoutReplay.bestStreamCoveragePercent); workout_best_threshold_gap_bpm=\(workoutReplay.bestThresholdGapBPM); workout_best_p95_hr=\(workoutReplay.bestP95HR); workout_best_p99_hr=\(workoutReplay.bestP99HR); workout_best_samples_above_threshold=\(workoutReplay.bestSamplesAboveThreshold); workout_best_samples_above_borderline=\(workoutReplay.bestSamplesAboveBorderline); workout_best_duration_s=\(Int(workoutReplay.bestDuration.rounded())); workout_best_observed_s=\(Int(workoutReplay.bestObservedDuration.rounded())); workout_best_dropped_gap_s=\(Int(workoutReplay.bestDroppedGapSeconds.rounded())); workout_best_elevated_s=\(Int(workoutReplay.bestElevatedSeconds.rounded())); workout_best_longest_bout_s=\(Int(workoutReplay.bestLongestBout.rounded())); workout_best_required_bout_s=\(Int(workoutReplay.bestRequiredBout.rounded())); workout_threshold_hr=\(thresholdHR); profile_max_hr=\(profile.maxHR); profile_sensitivity_diagnostic_only=1; required_profile_max_hr_for_p95_hrr50=\(workoutReplay.profileMaxHRForBestP95AtHRR50); required_profile_max_hr_for_p99_hrr50=\(workoutReplay.profileMaxHRForBestP99AtHRR50); required_profile_max_hr_for_peak_hrr50=\(workoutReplay.profileMaxHRForBestPeakAtHRR50); current_profile_minus_p99_required_bpm=\(workoutReplay.p99ProfileMaxHRGap); historical_gap_repair_status=\(historicalGapRepair.status); historical_gap_repair_reason=\(historicalGapRepair.reason); historical_gap_repair_overlap_s=\(historicalGapRepair.overlapSeconds); historical_gap_repair_separation_s=\(historicalGapRepair.separationSeconds); historical_gap_repair_current_usable_rows=\(historicalGapRepair.archiveCurrentUsableRows); historical_gap_repair_metric_usable=\(historicalGapRepair.metricUsable ? 1 : 0); historical_gap_repair_diagnostic_only=1; sleep_motion_source=\(sleepEvidence.motionSource); motion_hint_sessions=\(motionHintSessions); motion_hints=\(motionHintTotal); motion_validated=\(sleepEvidence.motionValidated ? 1 : 0); hrv_state=\(hrvValidated > 0 ? "reference_partial" : "reference_pending"); hrv_baseline_samples=\(baseline.hrvSampleCount)/7; recovery_state=\(recoveryHighReady ? "ready" : "learning"); trend90_coverage_percent=\(trend90?.coveragePercent ?? 0); \(checkpointEvidence); \(linkEvidence); \(sampleEvidence); \(watchdogEvidence); \(radioEvidence); \(offlineSyncEvidence); \(journalEvidence)")
        logGateETrainingDiagnostics(rest: rest,
                                    maxHR: profile.maxHR,
                                    confirmedWorkouts: confirmedWorkoutRecords,
                                    confirmedSleeps: confirmedSleepRecords)
        let trend90RequiredCoverageDays = trendRequiredCoverageDays(windowDays: TrendSummary.Window.ninety.rawValue)
        let gateFStatus = gateFStatus(summary: trend90, hrvValidated: hrvValidated)
        logGateStatus("F", status: gateFStatus,
                      evidence: "trend90_coverage_days=\(trend90?.coverageDays ?? 0); trend90_required_coverage_days=\(trend90RequiredCoverageDays); trend90_required_coverage_percent=70; trend90_coverage_percent=\(trend90?.coveragePercent ?? 0); trend90_sessions=\(trend90?.sessions ?? 0); trend90_recovery_points=\(trend90?.avgRecovery == nil ? 0 : 1); trend90_hrv_points=\(trend90?.avgHRV == nil ? 0 : 1); trend90_rhr_points=\(trend90?.avgRHR == nil ? 0 : 1); trend90_strain_points=\(trend90?.avgStrain == nil ? 0 : 1); trend90_anomalies=\(trend90?.anomalies.count ?? 0); trend90_anomaly_flags=\(trend90AnomalyFlags); hrv_reference_gated=\(hrvValidated == 0 ? 1 : 0); trend_blockers=\(trend90Blockers)")
        let gateGPlatformReady = backupAvailable
            && backupCurrent
            && healthKit.entitlementPresent
            && healthKit.healthDataAvailable
            && healthKit.readback.dataAppears
            && widget.appGroupEnabled
            && widget.widgetTargetPresent
            && widget.complicationTargetPresent
        let gateGMetricBlockers = [
            healthKit.readback.overfilledTotalAtriaHRSamples > 0 ? "healthkit_hr_overfilled" : nil,
            healthKit.readback.expectedTotalAtriaHRSamples <= 0 || healthKit.readback.expectedTotalCovered ? nil : "healthkit_hr_backfill_pending",
            healthKit.planned.hrSamples > 0 ? nil : "healthkit_hr_missing",
            hrvValidated > 0 && healthKit.planned.hrvSamples > 0 ? nil : (hrvValidated > 0 ? "healthkit_hrv_missing" : "healthkit_hrv_reference_pending"),
            healthKit.planned.workouts > 0 ? nil : "healthkit_workout_learning"
        ].compactMap { $0 }
        let gateGReady = gateGPlatformReady && gateGMetricBlockers.isEmpty
        let gateGStatus = gateGReady ? "ready" : (gateGPlatformReady ? "metric_gated" : "partial")
        let appGroupWidgetStatus = widget.appGroupEnabled
            && widget.widgetTargetPresent
            && widget.complicationTargetPresent ? "shared_ready" : "diagnostic_only"
        logGateStatus("G", status: gateGStatus,
                      evidence: "platform_ready=\(gateGPlatformReady ? 1 : 0); metric_blockers=\(gateGMetricBlockers.isEmpty ? "none" : gateGMetricBlockers.joined(separator: "+")); backup_available=\(backupAvailable ? 1 : 0); backup_current=\(backupCurrent ? 1 : 0); backup=\(backupLabel); healthkit_entitlement=\(healthKit.entitlementPresent ? "present" : "missing"); healthkit_available=\(healthKit.healthDataAvailable ? 1 : 0); healthkit_hr_samples=\(healthKit.planned.hrSamples); healthkit_workouts=\(healthKit.planned.workouts); healthkit_hrv_samples=\(healthKit.planned.hrvSamples); healthkit_sleeps=\(healthKit.planned.sleeps); healthkit_readback_status=\(healthKit.readback.status); healthkit_readback_reason=\(healthKit.readback.reason); healthkit_readback_data_appears=\(healthKit.readback.dataAppears ? 1 : 0); healthkit_readback_atria_hr_samples=\(healthKit.readback.readbackAtriaHRSamples); healthkit_readback_total_hr_samples=\(healthKit.readback.totalHRSamples); healthkit_readback_expected_delta_hr_samples=\(healthKit.readback.expectedDeltaHRSamples); healthkit_readback_expected_total_atria_hr_samples=\(healthKit.readback.expectedTotalAtriaHRSamples); healthkit_readback_missing_total_atria_hr_samples=\(healthKit.readback.missingTotalAtriaHRSamples); healthkit_readback_overfill_total_atria_hr_samples=\(healthKit.readback.overfilledTotalAtriaHRSamples); healthkit_readback_expected_total_covered=\(healthKit.readback.expectedTotalCovered ? 1 : 0); healthkit_readback_expected_total_reconciled=\(healthKit.readback.expectedTotalReconciled ? 1 : 0); healthkit_readback_reconciliation=\(healthKit.readback.reconciliationStatus); notifications=production_cadence_confidence_gated; notification_delivery=debug_verified; \(batteryEvidence); widget_storage=\(widget.storage); widget_app_group=\(widget.appGroupEnabled ? 1 : 0); widget_target=\(widget.widgetTargetPresent ? 1 : 0); complication_target=\(widget.complicationTargetPresent ? 1 : 0); app_group_widget=\(appGroupWidgetStatus); \(radioEvidence)")
        logGateStatus("H", status: gateHStatus,
                      evidence: "historical_download_validated=\(historicalDownloadProtocolValidated ? 1 : 0); gate_h_protocol_exit_ready=\(historicalDownloadProtocolValidated ? 1 : 0); historical_archive_local=\(historicalArchive.exists ? 1 : 0); historical_archive_parse_ok=\(historicalArchive.parseOK ? 1 : 0); historical_archive_rows=\(historicalArchive.rows); historical_archive_bytes=\(historicalArchive.bytes); historical_archive_schemas=\(historicalArchiveSchemas); historical_archive_layouts=\(historicalArchiveLayouts); historical_archive_raw_payload_rows=\(historicalArchive.rawPayloadRows); historical_archive_undecodable_rows=\(historicalArchive.undecodableRows); historical_archive_metric_usable=\(historicalArchive.metricUsableRows); historical_archive_current_usable=\(historicalArchive.currentSessionUsableRows); historical_archive_unix_first=\(historicalArchive.unixFirst ?? 0); historical_archive_unix_last=\(historicalArchive.unixLast ?? 0); historical_archive_corrected_unix_first=\(historicalArchive.correctedUnixFirst ?? 0); historical_archive_corrected_unix_last=\(historicalArchive.correctedUnixLast ?? 0); historical_archive_gravity_rows=\(historicalArchive.gravityRows); historical_archive_gravity_validated_rows=\(historicalArchive.gravityValidatedRows); historical_archive_reason=\(historicalArchive.reason); historical_rr_metric_ready=\(historicalRRMetricReady ? 1 : 0); historical_metric_fail_closed=\(historicalRRMetricReady ? 0 : 1); historical_gravity_motion_validated=0; new_sensor_validated=0; \(protocolEvidence)")
        logExecutionPriority(hrvValidated: hrvValidated,
                             hrvBaselineSamples: baseline.hrvSampleCount,
                             externalHRReferenceReady: externalHRReferenceReady,
                             gateDReady: strainValidation.ready,
                             recoveryHighReady: recoveryHighReady,
                             sleepDays: sleepDays,
                             sleepEvidenceReady: sleepEvidenceReady,
                             sleepEvidenceBlocker: sleepEvidence.blocker,
                             rrReplay: rrReplay,
                             workoutReplay: workoutReplay,
                             trend90CoveragePercent: trend90?.coveragePercent ?? 0,
                             gateGPlatformReady: gateGPlatformReady,
                             gateGMetricBlockers: gateGMetricBlockers,
                             historicalDownloadProtocolValidated: historicalDownloadProtocolValidated,
                             activeJournal: ActiveSessionJournal.diagnostics(),
                             historicalArchive: historicalArchive)
        guard includeDeepReplay else { return }
        logGateStatus("E.deep", status: workoutReplay.readySessions > 0 ? "ready" : "partial",
                      evidence: "workout_replay_scope=\(workoutReplayScope); workout_replay_limit_sessions=\(workoutReplayLimit ?? 0); workout_replay_aggregates=\(workoutReplayLimit == nil ? 1 : 0); workout_saved_ready=\(workoutReplay.readySessions); workout_near_miss=\(workoutReplay.nearMiss ? 1 : 0); workout_near_miss_reason=\(workoutReplay.nearMissReason); workout_strength_candidate=\(workoutReplay.strengthCandidate ? 1 : 0); workout_strength_candidate_reason=\(workoutReplay.strengthCandidateReason); workout_strength_diagnostic_only=1; workout_next_action=\(workoutReplay.bestNextAction); workout_best_source=\(workoutReplay.bestSource); workout_best_chunks=\(workoutReplay.bestChunkCount); workout_best_reason=\(workoutReplay.bestReason); workout_best_blocker=\(workoutReplay.bestPrimaryBlocker); workout_best_stream_coverage_percent=\(workoutReplay.bestStreamCoveragePercent); workout_best_threshold_gap_bpm=\(workoutReplay.bestThresholdGapBPM); workout_best_p95_hr=\(workoutReplay.bestP95HR); workout_best_p99_hr=\(workoutReplay.bestP99HR); workout_best_samples_above_threshold=\(workoutReplay.bestSamplesAboveThreshold); workout_best_samples_above_borderline=\(workoutReplay.bestSamplesAboveBorderline); workout_best_duration_s=\(Int(workoutReplay.bestDuration.rounded())); workout_best_observed_s=\(Int(workoutReplay.bestObservedDuration.rounded())); workout_best_dropped_gap_s=\(Int(workoutReplay.bestDroppedGapSeconds.rounded())); workout_best_elevated_s=\(Int(workoutReplay.bestElevatedSeconds.rounded())); workout_best_longest_bout_s=\(Int(workoutReplay.bestLongestBout.rounded())); workout_best_required_bout_s=\(Int(workoutReplay.bestRequiredBout.rounded())); profile_sensitivity_diagnostic_only=1; required_profile_max_hr_for_p95_hrr50=\(workoutReplay.profileMaxHRForBestP95AtHRR50); required_profile_max_hr_for_p99_hrr50=\(workoutReplay.profileMaxHRForBestP99AtHRR50); required_profile_max_hr_for_peak_hrr50=\(workoutReplay.profileMaxHRForBestPeakAtHRR50); current_profile_minus_p99_required_bpm=\(workoutReplay.p99ProfileMaxHRGap); historical_gap_repair_status=\(historicalGapRepair.status); historical_gap_repair_reason=\(historicalGapRepair.reason); historical_gap_repair_overlap_s=\(historicalGapRepair.overlapSeconds); historical_gap_repair_separation_s=\(historicalGapRepair.separationSeconds); historical_gap_repair_current_usable_rows=\(historicalGapRepair.archiveCurrentUsableRows); historical_gap_repair_metric_usable=\(historicalGapRepair.metricUsable ? 1 : 0); diagnostic_only=1")
        WHOOPDebugLog("WHOOPDBG gate_status_deep status=ready stage=e_deep_logged deep_mode=%@ workout_replay_limit=%d rr_replay=skipped_bounded_deep_status rr_samples=%d workout_ready=%d workout_near_miss=%d strain_ready=%d historical_gap_status=%@ historical_gap_reason=%@",
              workoutReplayScope,
              workoutReplayLimit ?? 0,
              rrSamples,
              workoutReplay.readySessions,
              workoutReplay.nearMiss ? 1 : 0,
              strainValidation.ready ? 1 : 0,
              historicalGapRepair.status,
              historicalGapRepair.reason)
        guard workoutReplayLimit == nil else {
            WHOOPDebugLog("WHOOPDBG gate_status_deep_detail status=skipped reason=bounded_large_store sessions=%d hr_accepted=%d rr_samples=%d action=use_fast_rows_or_run_targeted_workout_diagnostics diagnostic_only=1",
                  sessions.count,
                  hrAcceptedSamples,
                  rrSamples)
            return
        }
        logWorkoutReplay(workoutReplay)
        logWorkoutThresholdSensitivity(rest: rest, maxHR: profile.maxHR)
        logHistoricalGapRepair(historicalGapRepair)
        WHOOPDebugLog("WHOOPDBG gate_status_deep rr_replay=%@ rr_samples=%d workout_ready=%d workout_near_miss=%d strain_ready=%d historical_gap_status=%@ historical_gap_reason=%@",
              "skipped_bounded_deep_status",
              rrSamples,
              workoutReplay.readySessions,
              workoutReplay.nearMiss ? 1 : 0,
              strainValidation.ready ? 1 : 0,
              historicalGapRepair.status,
              historicalGapRepair.reason)
    }

    private func logBoundedLargeStoreGateStatus(mode: String,
                                                rest: Int,
                                                hrvValidated: Int,
                                                hrvBaselineReady: Bool,
                                                recoveryHighReady: Bool,
                                                rrSessions: Int,
                                                rrSamples: Int,
                                                hrAcceptedSamples: Int,
                                                workoutReplayLimit: Int?) {
        let latestBackup = latestSessionBackupURL()
        let backupAvailable = latestBackup != nil
        let backupLabel = latestBackup.map { backupRelativePath(for: $0) } ?? "none"
        let backupCurrent = latestBackup.map { latestBackupMatchesCurrentStore($0) } ?? false
        let activeJournal = ActiveSessionJournal.diagnostics()
        let csvHRReference = csvHRReferenceDiagnostics
        let externalHRReferenceReady = externalHRReferenceValidated
        let confirmedWorkoutRecords = confirmedWorkouts
        let confirmedSleepRecords = confirmedSleeps
        let confirmedWorkoutCount = confirmedWorkoutRecords.count
        let confirmedSleepCount = confirmedSleepRecords.count
        let healthKit = HealthKitExporter.diagnostics(for: sessions,
                                                      rest: rest,
                                                      maxHR: profile.maxHR,
                                                      confirmedWorkouts: confirmedWorkoutRecords,
                                                      confirmedSleeps: confirmedSleepRecords)
        let widget = WidgetSnapshotPublisher.diagnostics
        let linkEvidence = WhoopBLEManager.linkEvidence()
        let sampleEvidence = WhoopBLEManager.sampleGapEvidence()
        let watchdogEvidence = WhoopBLEManager.watchdogRecoveryEvidence()
        let batteryEvidence = WhoopBLEManager.batteryEvidence()
        let radioEvidence = WhoopBLEManager.radioEvidence()
        let offlineSyncEvidence = WhoopBLEManager.offlineSyncEvidence()
        let protocolEvidence = WhoopBLEManager.protocolEvidence()
        let journalEvidence = WhoopBLEManager.activeSessionJournalEvidence()
        let collectionEvidence = currentCollectionStatus().evidence
        let historicalArchive = HistoricalArchive.diagnostics()
        let historicalArchiveSchemas = historicalArchive.schemas.isEmpty ? "none" : historicalArchive.schemas.joined(separator: ",")
        let historicalArchiveLayouts = historicalArchive.layoutVersions.isEmpty ? "none" : historicalArchive.layoutVersions.joined(separator: ",")
        let historicalDownloadProtocolValidated = historicalArchive.exists
            && historicalArchive.parseOK
            && historicalArchive.rows > 0
            && historicalArchive.rawPayloadRows > 0
            && historicalArchive.undecodableRows == 0
        let historicalRRMetricReady = historicalDownloadProtocolValidated
            && historicalArchive.metricUsableRows > 0
            && historicalArchive.currentSessionUsableRows > 0
        let reserveHR = max(profile.maxHR - rest, 0)
        let currentRRWindowInspectable = activeJournal.duration >= 60 || activeJournal.samples >= 60
        let currentRRCaptureHasIssue = hrvValidated == 0
            && activeJournal.present
            && activeJournal.fresh
            && currentRRWindowInspectable
            && !activeJournal.rrContinuityReady
        let currentRRBlocker = activeJournal.rrValues > 0
            ? "B:current_rr_continuity_gap_\(Int(activeJournal.maxRRGap.rounded()))s_coverage_\(activeJournal.rrCoverage3Percent)p"
            : "B:current_rr_missing_current_hr_samples_\(activeJournal.samples)"
        let nextLocalGate: String
        let nextLocalAction: String
        let secondaryLocalGate: String
        let secondaryLocalAction: String
        let userConfirmedGateE = confirmedWorkoutCount > 0 && confirmedSleepCount > 0
        let gateETraining = gateETrainingSummary(rest: rest, maxHR: profile.maxHR)
        let gateEStatus = userConfirmedGateE
            ? "user_confirmed"
            : ((confirmedWorkoutCount > 0 || confirmedSleepCount > 0) ? "partial" : "learning")
        let gateENextAction = userConfirmedGateE
            ? gateETraining.nextProof
            : "run_targeted_sleep_or_workout_diagnostics"
        let externalBlocked = [
            hrvValidated == 0 ? "B:external_rr_reference" : nil,
            hrvValidated == 0 ? "C:validated_hrv_baseline_\(baseline.hrvSampleCount)_of_7" : nil,
            externalHRReferenceReady ? nil : "D:external_hr_reference"
        ].compactMap { $0 }.joined(separator: ",")
        let gateGPlatformReady = backupAvailable
            && backupCurrent
            && healthKit.entitlementPresent
            && healthKit.healthDataAvailable
            && healthKit.readback.dataAppears
            && widget.appGroupEnabled
            && widget.widgetTargetPresent
            && widget.complicationTargetPresent
        let gateGMetricBlockers = [
            healthKit.readback.overfilledTotalAtriaHRSamples > 0 ? "healthkit_hr_overfilled" : nil,
            healthKit.readback.expectedTotalAtriaHRSamples <= 0 || healthKit.readback.expectedTotalCovered ? nil : "healthkit_hr_backfill_pending",
            healthKit.planned.hrSamples > 0 ? nil : "healthkit_hr_missing",
            hrvValidated > 0 && healthKit.planned.hrvSamples > 0 ? nil : (hrvValidated > 0 ? "healthkit_hrv_missing" : "healthkit_hrv_reference_pending"),
            healthKit.planned.workouts > 0 ? nil : "healthkit_workout_learning"
        ].compactMap { $0 }
        let gateGLocalMetricBlockers = gateGMetricBlockers.filter {
            $0 != "healthkit_hrv_reference_pending" && $0 != "healthkit_workout_learning"
        }
        let gateGReady = gateGPlatformReady && gateGMetricBlockers.isEmpty
        let gateGStatus = gateGReady ? "ready" : (gateGPlatformReady ? "metric_gated" : "partial")
        let appGroupWidgetStatus = widget.appGroupEnabled
            && widget.widgetTargetPresent
            && widget.complicationTargetPresent ? "shared_ready" : "diagnostic_only"
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=bounded_rr_replay_start mode=%@ sessions=%d rr_samples=%d",
              mode,
              sessions.count,
              rrSamples)
        let rrReplay = replaySavedRRLedger(limitSessions: nil, includeActiveJournal: true)
        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=bounded_rr_replay_done mode=%@ ready=%d label=%@ raw=%d kept=%d conf=%d max_gap_s=%.1f reason=%@",
              mode,
              rrReplay.bestReady ? 1 : 0,
              rrReplay.bestSessionLabel,
              rrReplay.bestRaw,
              rrReplay.bestKept,
              rrReplay.bestConfidencePercent,
              rrReplay.bestMaxRRGapSeconds,
              rrReplay.reason)
        let currentRRCaptureBlocked = currentRRCaptureHasIssue && !rrReplay.bestReady
        let nextAction = hrvValidated == 0
            ? (currentRRCaptureBlocked ? "restore_current_rr_continuity_before_external_reference" : (rrReplay.bestReady ? "provide_external_rr_reference_for_ready_rr_window" : "provide_external_rr_reference_or_capture_clean_rr_window"))
            : "capture_real_sustained_elevated_hr_workout"
        let localBlocked = [
            currentRRCaptureBlocked ? currentRRBlocker : nil,
            gateGPlatformReady ? nil : "G:platform_evidence_missing",
            gateGLocalMetricBlockers.isEmpty ? nil : "G:\(gateGLocalMetricBlockers.joined(separator: "+"))"
        ].compactMap { $0 }.joined(separator: ",")
        if currentRRCaptureBlocked {
            nextLocalGate = "B"
            nextLocalAction = activeJournal.rrValues > 0
                ? "restore_current_rr_continuity_no_gap_over_3s"
                : "restore_current_rr_presence_from_2a37"
            secondaryLocalGate = gateGPlatformReady && gateGLocalMetricBlockers.isEmpty ? "E" : "G"
            secondaryLocalAction = gateGPlatformReady && gateGLocalMetricBlockers.isEmpty
                ? "run_targeted_sleep_or_workout_diagnostics"
                : "run_healthkit_readback_after_rr_presence"
        } else if !gateGPlatformReady || !gateGLocalMetricBlockers.isEmpty {
            nextLocalGate = "G"
            nextLocalAction = !gateGPlatformReady
                ? "finish_platform_plumbing"
                : "repair_healthkit_export_readback"
            secondaryLocalGate = "E"
            secondaryLocalAction = "run_targeted_sleep_or_workout_diagnostics"
        } else {
            nextLocalGate = "E"
            nextLocalAction = gateENextAction
            secondaryLocalGate = "H"
            secondaryLocalAction = "decode_historical_or_new_sensor_when_new_evidence_exists"
        }

        WHOOPDebugLog("WHOOPDBG gate_status_progress stage=bounded_fast_large_store mode=%@ sessions=%d rr_samples=%d hr_accepted=%d reason=avoid_inline_large_store_replay healthkit_cached=1 widget_cached=1 backup_current=%d",
              mode,
              sessions.count,
              rrSamples,
              hrAcceptedSamples,
              backupCurrent ? 1 : 0)
        logGateStatus("local", status: "dashboard_bounded",
                      evidence: "status_mode=\(mode); bounded_large_store=1; sessions=\(sessions.count); rr_sessions=\(rrSessions); rr_samples=\(rrSamples); hr_accepted_samples=\(hrAcceptedSamples); workout_replay_limit_sessions=\(workoutReplayLimit ?? 0); workout_replay=skipped_bounded_audit; rr_replay=skipped_bounded_audit; healthkit_diagnostics=cached_fast; historical_archive=skipped_bounded_audit; recovery_state=\(recoveryHighReady ? "ready" : "learning"); hrv_validated_sessions=\(hrvValidated); hrv_baseline_samples=\(baseline.hrvSampleCount); backup_available=\(backupAvailable ? 1 : 0); backup_current=\(backupCurrent ? 1 : 0); backup=\(backupLabel); healthkit_readback_status=\(healthKit.readback.status); healthkit_readback_data_appears=\(healthKit.readback.dataAppears ? 1 : 0); widget_app_group=\(widget.appGroupEnabled ? 1 : 0); widget_target=\(widget.widgetTargetPresent ? 1 : 0); complication_target=\(widget.complicationTargetPresent ? 1 : 0); external_hr_reference=\(csvHRReference.status); \(linkEvidence); \(sampleEvidence); \(watchdogEvidence); \(batteryEvidence); \(radioEvidence); \(offlineSyncEvidence); \(protocolEvidence); \(journalEvidence); \(collectionEvidence)")
        logGateStatus("A", status: "runtime_required",
                      evidence: "BLE realtime must be checked in live WHOOPDBG for this launch")
        let boundedHRVDisplayTier = hrvValidated > 0 ? "validated" : (rrReplay.bestReady ? "personal_baseline" : "learning")
        logGateStatus("B", status: hrvValidated > 0 ? "reference_partial" : "reference_pending",
                      evidence: "status_mode=\(mode); bounded_large_store=1; display_tier=\(boundedHRVDisplayTier); validated_hrv_sessions=\(hrvValidated); saved_rr_ready=\(rrReplay.bestReady ? 1 : 0); saved_rr_sessions=\(rrReplay.sessionsWithRR); saved_rr_samples=\(rrReplay.rrSamples); saved_rr_best_label=\(rrReplay.bestSessionLabel); saved_rr_best_raw=\(rrReplay.bestRaw); saved_rr_best_kept=\(rrReplay.bestKept); saved_rr_best_conf=\(rrReplay.bestConfidencePercent); saved_rr_best_gap_s=\(String(format: "%.1f", rrReplay.bestMaxRRGapSeconds)); saved_rr_best_rmssd=\(rrReplay.bestRMSSD.map { String(format: "%.1f", $0) } ?? "learning"); saved_rr_reason=\(rrReplay.reason); rr_replay=computed_exhaustive_rr_only; active_journal_present=\(activeJournal.present ? 1 : 0); active_journal_fresh=\(activeJournal.fresh ? 1 : 0); active_journal_samples=\(activeJournal.samples); active_journal_rr_values=\(activeJournal.rrValues); active_journal_rr_coverage_3s_percent=\(activeJournal.rrCoverage3Percent); active_journal_max_rr_gap_s=\(String(format: "%.1f", activeJournal.maxRRGap)); active_journal_recent_rr_values=\(activeJournal.recentRRValues); active_journal_recent_rr_duration_s=\(Int(activeJournal.recentRRDuration.rounded())); active_journal_recent_rr_coverage_3s_percent=\(activeJournal.recentRRCoverage3Percent); active_journal_recent_rr_max_gap_s=\(String(format: "%.1f", activeJournal.recentRRMaxGap)); active_journal_recent_rr_clean=\(activeJournal.recentRRContinuityClean ? 1 : 0); external_rr_reference_optional=1; validated_tier_requires_external_reference=1; reference_validated=\(hrvValidated > 0 ? 1 : 0)")
        logGateStatus("C", status: recoveryHighReady ? "ready" : "learning",
                      evidence: "validated_hrv_baseline=\(baseline.hrvSampleCount)/7; hrv_baseline_ready=\(hrvBaselineReady ? 1 : 0); latest_validated_hrv=\(latestReferenceValidatedHRV ?? 0)")
        logGateStatus("D", status: externalHRReferenceReady ? "reference_ready_metric_pending" : "partial",
                      evidence: "profile_max_hr=\(profile.maxHR); rest_hr=\(rest); reserve_hr=\(reserveHR); hr_accepted_samples=\(hrAcceptedSamples); csv_reference_status=\(csvHRReference.status); csv_reference_reason=\(csvHRReference.reason); csv_reference_pairs=\(csvHRReference.pairs); external_hr_reference_ready=\(externalHRReferenceReady ? 1 : 0); strain_replay=skipped_bounded_audit")
        logGateStatus("E", status: gateEStatus,
                      evidence: "bounded_large_store=1; confirmed_workouts=\(confirmedWorkoutCount); confirmed_sleeps=\(confirmedSleepCount); user_confirmed_gate_e=\(userConfirmedGateE ? 1 : 0); auto_gate_e_ready=\(gateETraining.autoReady ? 1 : 0); auto_detection_required=\(gateETraining.autoReady ? 0 : 1); sleep_replay=skipped_bounded_audit; workout_replay=skipped_bounded_audit; sleep_blocker=\(gateETraining.compactSleepBlocker); workout_blocker=\(gateETraining.compactWorkoutBlocker); sleep_proof=\(gateETraining.sleepProofNeeded); sleep_proof_status=\(gateETraining.sleepProofStatus); sleep_fallback_accepted=\(gateETraining.sleep.fallbackAccepted ? 1 : 0); sleep_fallback_policy=\(gateETraining.sleep.fallbackPolicy); workout_proof=\(gateETraining.workoutProofNeeded); workout_proof_status=\(gateETraining.workoutProofStatus); workout_intensity_proof=\(gateETraining.workoutIntensityProof); workout_profile_proof=\(gateETraining.workoutProfileSensitivityProof); workout_progress=\(gateETraining.workoutProofProgress); workout_next_step=\(gateETraining.workoutProofNextStep); workout_required_coverage_percent=\(gateETraining.workoutCoverageTargetPercent); workout_missing_coverage_percent=\(gateETraining.workoutCoverageMissingPercent); workout_observed_s=\(gateETraining.workoutObservedSeconds); workout_required_observed_s=\(gateETraining.workoutObservedTargetSeconds); workout_missing_observed_s=\(gateETraining.workoutObservedMissingSeconds); workout_p95_hr=\(gateETraining.workout.p95HR); workout_p99_hr=\(gateETraining.workout.p99HR); workout_p95_gap_bpm=\(gateETraining.workoutP95GapBPM); workout_peak_gap_bpm=\(gateETraining.workoutPeakGapBPM); workout_profile_max_hr=\(gateETraining.workout.profileMaxHR); workout_required_profile_max_hr_for_p95_hrr50=\(gateETraining.workout.requiredProfileMaxHRForP95AtHRR50); workout_profile_max_lowering_for_p95_bpm=\(gateETraining.workoutProfileMaxLoweringForP95BPM); workout_missing_elevated_s=\(gateETraining.workoutElevatedMissingSeconds); workout_missing_bout_s=\(gateETraining.workoutBoutMissingSeconds); workout_ready_if=\(gateETraining.workoutProofReadyIf); action=\(gateENextAction)")
        logGateETrainingDiagnostics(rest: rest,
                                    maxHR: profile.maxHR,
                                    confirmedWorkouts: confirmedWorkoutRecords,
                                    confirmedSleeps: confirmedSleepRecords)
        let boundedTrendSummaries = trendSummaries(rest: rest, maxHR: profile.maxHR)
        let boundedTrend90 = boundedTrendSummaries.first { $0.days == 90 }
        let boundedTrend90Blockers = trendBlockers(summary: boundedTrend90, hrvValidated: hrvValidated)
        let boundedTrend90AnomalyFlags = boundedTrend90.map { trendAnomalyFlags($0.anomalies) } ?? "none"
        let boundedTrend90AnomalySource = boundedTrend90?.anomalySource ?? "none"
        let boundedTrend90AnomalyDays = boundedTrend90?.anomalySampleDays ?? 0
        let boundedLocalWindows = boundedTrendSummaries.filter { $0.avgRHR != nil || $0.avgStrain != nil }.count
        let boundedLocalTrendReady = boundedLocalWindows > 0
        let boundedGateFStatus = gateFStatus(summary: boundedTrend90, hrvValidated: hrvValidated)
        WHOOPDebugLog("WHOOPDBG trend_fast_local windows=%d local_windows=%d rhr_points=%d strain_points=%d recovery_points=%d hrv_points=%d trend90_confidence=%@ trend90_coverage_days=%d trend90_required_coverage_days=%d trend90_coverage_percent=%d trend90_anomaly_source=%@ trend90_anomaly_days=%d hrv_reference_gated=%d status=%@ blockers=%@",
              boundedTrendSummaries.count,
              boundedLocalWindows,
              boundedTrendSummaries.filter { $0.avgRHR != nil }.count,
              boundedTrendSummaries.filter { $0.avgStrain != nil }.count,
              boundedTrendSummaries.filter { $0.avgRecovery != nil }.count,
              boundedTrendSummaries.filter { $0.avgHRV != nil }.count,
              boundedTrend90?.confidence ?? "learning",
              boundedTrend90?.coverageDays ?? 0,
              boundedTrend90?.requiredCoverageDays ?? trendRequiredCoverageDays(windowDays: TrendSummary.Window.ninety.rawValue),
              boundedTrend90?.coveragePercent ?? 0,
              boundedTrend90AnomalySource,
              boundedTrend90AnomalyDays,
              hrvValidated == 0 ? 1 : 0,
              boundedGateFStatus,
              boundedTrend90Blockers)
        logGateStatus("F", status: boundedGateFStatus,
                      evidence: "bounded_large_store=1; trend_replay=fast_local_summary; local_non_hrv_trends_ready=\(boundedLocalTrendReady ? 1 : 0); local_non_hrv_windows=\(boundedLocalWindows); trend90_coverage_days=\(boundedTrend90?.coverageDays ?? 0); trend90_required_coverage_days=\(boundedTrend90?.requiredCoverageDays ?? trendRequiredCoverageDays(windowDays: TrendSummary.Window.ninety.rawValue)); trend90_required_coverage_percent=70; trend90_coverage_percent=\(boundedTrend90?.coveragePercent ?? 0); trend90_sessions=\(boundedTrend90?.sessions ?? 0); trend90_recovery_points=\(boundedTrend90?.avgRecovery == nil ? 0 : 1); trend90_hrv_points=\(boundedTrend90?.avgHRV == nil ? 0 : 1); trend90_rhr_points=\(boundedTrend90?.avgRHR == nil ? 0 : 1); trend90_strain_points=\(boundedTrend90?.avgStrain == nil ? 0 : 1); trend90_anomalies=\(boundedTrend90?.anomalies.count ?? 0); trend90_anomaly_flags=\(boundedTrend90AnomalyFlags); trend90_anomaly_source=\(boundedTrend90AnomalySource); trend90_anomaly_days=\(boundedTrend90AnomalyDays); hrv_reference_gated=\(hrvValidated == 0 ? 1 : 0); trend_blockers=\(boundedTrend90Blockers)")
        logGateStatus("G", status: gateGStatus,
                      evidence: "bounded_large_store=1; platform_ready=\(gateGPlatformReady ? 1 : 0); metric_blockers=\(gateGMetricBlockers.isEmpty ? "none" : gateGMetricBlockers.joined(separator: "+")); backup_available=\(backupAvailable ? 1 : 0); backup_current=\(backupCurrent ? 1 : 0); backup=\(backupLabel); healthkit_entitlement=\(healthKit.entitlementPresent ? "present" : "missing"); healthkit_available=\(healthKit.healthDataAvailable ? 1 : 0); healthkit_hr_samples=\(healthKit.planned.hrSamples); healthkit_workouts=\(healthKit.planned.workouts); healthkit_hrv_samples=\(healthKit.planned.hrvSamples); healthkit_sleeps=\(healthKit.planned.sleeps); healthkit_readback_status=\(healthKit.readback.status); healthkit_readback_reason=\(healthKit.readback.reason); healthkit_readback_data_appears=\(healthKit.readback.dataAppears ? 1 : 0); healthkit_readback_atria_hr_samples=\(healthKit.readback.readbackAtriaHRSamples); healthkit_readback_total_hr_samples=\(healthKit.readback.totalHRSamples); healthkit_readback_expected_delta_hr_samples=\(healthKit.readback.expectedDeltaHRSamples); healthkit_readback_expected_total_atria_hr_samples=\(healthKit.readback.expectedTotalAtriaHRSamples); healthkit_readback_missing_total_atria_hr_samples=\(healthKit.readback.missingTotalAtriaHRSamples); healthkit_readback_overfill_total_atria_hr_samples=\(healthKit.readback.overfilledTotalAtriaHRSamples); healthkit_readback_expected_total_covered=\(healthKit.readback.expectedTotalCovered ? 1 : 0); healthkit_readback_expected_total_reconciled=\(healthKit.readback.expectedTotalReconciled ? 1 : 0); healthkit_readback_reconciliation=\(healthKit.readback.reconciliationStatus); notifications=production_cadence_confidence_gated; notification_delivery=debug_verified; \(batteryEvidence); widget_storage=\(widget.storage); widget_app_group=\(widget.appGroupEnabled ? 1 : 0); widget_target=\(widget.widgetTargetPresent ? 1 : 0); complication_target=\(widget.complicationTargetPresent ? 1 : 0); app_group_widget=\(appGroupWidgetStatus); \(radioEvidence)")
        logGateStatus("H", status: historicalDownloadProtocolValidated ? "ready" : "partial",
                      evidence: "bounded_large_store=1; historical_archive=cached_diagnostics; historical_download_validated=\(historicalDownloadProtocolValidated ? 1 : 0); gate_h_protocol_exit_ready=\(historicalDownloadProtocolValidated ? 1 : 0); historical_archive_local=\(historicalArchive.exists ? 1 : 0); historical_archive_parse_ok=\(historicalArchive.parseOK ? 1 : 0); historical_archive_rows=\(historicalArchive.rows); historical_archive_bytes=\(historicalArchive.bytes); historical_archive_schemas=\(historicalArchiveSchemas); historical_archive_layouts=\(historicalArchiveLayouts); historical_archive_raw_payload_rows=\(historicalArchive.rawPayloadRows); historical_archive_undecodable_rows=\(historicalArchive.undecodableRows); historical_archive_metric_usable=\(historicalArchive.metricUsableRows); historical_archive_current_usable=\(historicalArchive.currentSessionUsableRows); historical_archive_unix_first=\(historicalArchive.unixFirst ?? 0); historical_archive_unix_last=\(historicalArchive.unixLast ?? 0); historical_archive_corrected_unix_first=\(historicalArchive.correctedUnixFirst ?? 0); historical_archive_corrected_unix_last=\(historicalArchive.correctedUnixLast ?? 0); historical_archive_gravity_rows=\(historicalArchive.gravityRows); historical_archive_gravity_validated_rows=\(historicalArchive.gravityValidatedRows); historical_archive_reason=\(historicalArchive.reason); historical_rr_metric_ready=\(historicalRRMetricReady ? 1 : 0); historical_metric_fail_closed=\(historicalRRMetricReady ? 0 : 1); historical_gravity_motion_validated=0; new_sensor_validated=0; action=skip_blind_history_selector_until_new_evidence")
        logExecutionPrioritySnapshot(nextGate: hrvValidated == 0 ? "B" : "E",
                                     nextAction: nextAction,
                                     nextLocalGate: nextLocalGate,
                                     nextLocalAction: nextLocalAction,
                                     secondaryLocalGate: secondaryLocalGate,
                                     secondaryLocalAction: secondaryLocalAction,
                                     externalBlocked: externalBlocked.isEmpty ? "none" : externalBlocked,
                                     realWorldNeeded: userConfirmedGateE ? "E:auto_detection_validation_from_confirmed_examples,F:more_real_history_or_hrv_reference" : "E:real_sustained_workout,F:more_real_history_or_hrv_reference",
                                     localBlocked: localBlocked.isEmpty ? "none" : localBlocked,
                                     ready: userConfirmedGateE ? "E:user_confirmed_sleep_and_workout" : "none",
                                     diagnosticOnly: historicalRRMetricReady ? "bounded_large_store_fast_audit" : "bounded_large_store_fast_audit,H:historical_metrics_fail_closed",
                                     skip: "no_start_retry_no_blind_history_selector_no_fake_metrics")
    }

    private func logGateStatus(_ gate: String, status: String, evidence: String) {
        let sanitizedEvidence = evidence.replacingOccurrences(of: " ", with: "_")
        persistGateStatusSnapshotLine("WHOOPDBG gate_status gate=\(gate) status=\(status) evidence=\(sanitizedEvidence)",
                                      reset: gate == "local")
        WHOOPDebugLog("WHOOPDBG gate_status gate=%@ status=%@ evidence=%@",
              gate,
              status,
              sanitizedEvidence)
    }

    private func logExecutionPrioritySnapshot(nextGate: String,
                                              nextAction: String,
                                              nextLocalGate: String,
                                              nextLocalAction: String,
                                              secondaryLocalGate: String? = nil,
                                              secondaryLocalAction: String? = nil,
                                              externalBlocked: String,
                                              realWorldNeeded: String,
                                              localBlocked: String,
                                              ready: String,
                                              diagnosticOnly: String,
                                              skip: String) {
        let secondary = secondaryLocalGate.flatMap { gate -> String? in
            guard let action = secondaryLocalAction else { return nil }
            return " secondary_local_gate=\(gate) secondary_local_action=\(action)"
        } ?? ""
        let line = "WHOOPDBG execution_priority next_gate=\(nextGate) next_action=\(nextAction) next_local_gate=\(nextLocalGate) next_local_action=\(nextLocalAction)\(secondary) external_blocked=\(externalBlocked) real_world_needed=\(realWorldNeeded) local_blocked=\(localBlocked) ready=\(ready) diagnostic_only=\(diagnosticOnly) skip=\(skip)"
        persistGateStatusSnapshotLine(line, reset: false)
        if let secondaryLocalGate, let secondaryLocalAction {
            WHOOPDebugLog("WHOOPDBG execution_priority next_gate=%@ next_action=%@ next_local_gate=%@ next_local_action=%@ secondary_local_gate=%@ secondary_local_action=%@ external_blocked=%@ real_world_needed=%@ local_blocked=%@ ready=%@ diagnostic_only=%@ skip=%@",
                  nextGate,
                  nextAction,
                  nextLocalGate,
                  nextLocalAction,
                  secondaryLocalGate,
                  secondaryLocalAction,
                  externalBlocked,
                  realWorldNeeded,
                  localBlocked,
                  ready,
                  diagnosticOnly,
                  skip)
        } else {
            WHOOPDebugLog("WHOOPDBG execution_priority next_gate=%@ next_action=%@ next_local_gate=%@ next_local_action=%@ external_blocked=%@ real_world_needed=%@ local_blocked=%@ ready=%@ diagnostic_only=%@ skip=%@",
                  nextGate,
                  nextAction,
                  nextLocalGate,
                  nextLocalAction,
                  externalBlocked,
                  realWorldNeeded,
                  localBlocked,
                  ready,
                  diagnosticOnly,
                  skip)
        }
    }

    private func logGateETrainingDiagnostics(rest: Int,
                                             maxHR: Int,
                                             confirmedWorkouts: [UserConfirmedWorkout],
                                             confirmedSleeps: [UserConfirmedSleep]) {
        guard !confirmedWorkouts.isEmpty || !confirmedSleeps.isEmpty else { return }
        let summary = gateETrainingSummary(rest: rest, maxHR: maxHR)
        logGateETrainingLine("WHOOPDBG gate_e_training kind=plan auto_ready=\(summary.autoReady ? 1 : 0) auto_detection_required=\(summary.autoReady ? 0 : 1) blocker=\(summary.primaryBlocker) sleep_blocker=\(summary.compactSleepBlocker) workout_blocker=\(summary.compactWorkoutBlocker) sleep_proof=\(summary.sleepProofNeeded) sleep_proof_status=\(summary.sleepProofStatus) sleep_fallback_accepted=\(summary.sleep.fallbackAccepted ? 1 : 0) sleep_fallback_policy=\(summary.sleep.fallbackPolicy) workout_proof=\(summary.workoutProofNeeded) workout_proof_status=\(summary.workoutProofStatus) workout_intensity_proof=\(summary.workoutIntensityProof) workout_profile_proof=\(summary.workoutProfileSensitivityProof) workout_progress=\(summary.workoutProofProgress) workout_next_step=\(summary.workoutProofNextStep) workout_required_coverage_percent=\(summary.workoutCoverageTargetPercent) workout_missing_coverage_percent=\(summary.workoutCoverageMissingPercent) workout_observed_s=\(summary.workoutObservedSeconds) workout_required_observed_s=\(summary.workoutObservedTargetSeconds) workout_missing_observed_s=\(summary.workoutObservedMissingSeconds) workout_p95_hr=\(summary.workout.p95HR) workout_p99_hr=\(summary.workout.p99HR) workout_p95_gap_bpm=\(summary.workoutP95GapBPM) workout_peak_gap_bpm=\(summary.workoutPeakGapBPM) workout_profile_max_hr=\(summary.workout.profileMaxHR) workout_required_profile_max_hr_for_p95_hrr50=\(summary.workout.requiredProfileMaxHRForP95AtHRR50) workout_profile_max_lowering_for_p95_bpm=\(summary.workoutProfileMaxLoweringForP95BPM) workout_missing_elevated_s=\(summary.workoutElevatedMissingSeconds) workout_missing_bout_s=\(summary.workoutBoutMissingSeconds) workout_ready_if=\(summary.workoutProofReadyIf) next_proof=\(summary.nextProof)")
        let workout = summary.workout
        if workout.present {
            logGateETrainingLine("WHOOPDBG gate_e_training kind=workout confirmed=1 id=\(workout.confirmedID) source=\(workout.source) confidence=\(workout.confidence) auto_ready=\(workout.autoReady ? 1 : 0) auto_status=\(workout.autoStatus) auto_reason=\(workout.autoReason) primary_blocker=\(workout.primaryBlocker) proof_status=\(summary.workoutProofStatus) intensity_proof=\(summary.workoutIntensityProof) profile_proof=\(summary.workoutProfileSensitivityProof) progress=\(summary.workoutProofProgress) next_step=\(summary.workoutProofNextStep) samples=\(workout.samples) overlap_s=\(Int(workout.overlap.rounded())) duration_s=\(Int(workout.duration.rounded())) observed_s=\(summary.workoutObservedSeconds) required_observed_s=\(summary.workoutObservedTargetSeconds) missing_observed_s=\(summary.workoutObservedMissingSeconds) coverage_percent=\(workout.streamCoveragePercent) required_coverage_percent=\(summary.workoutCoverageTargetPercent) missing_coverage_percent=\(summary.workoutCoverageMissingPercent) peak_hr=\(workout.peakHR) p95_hr=\(workout.p95HR) p99_hr=\(workout.p99HR) p95_gap_bpm=\(summary.workoutP95GapBPM) peak_gap_bpm=\(summary.workoutPeakGapBPM) threshold_hr=\(workout.thresholdHR) threshold_gap_bpm=\(workout.thresholdGapBPM) profile_max_hr=\(workout.profileMaxHR) required_profile_max_hr_for_p95_hrr50=\(workout.requiredProfileMaxHRForP95AtHRR50) profile_max_lowering_for_p95_bpm=\(summary.workoutProfileMaxLoweringForP95BPM) elevated_s=\(summary.workoutElevatedSeconds) required_elevated_s=\(summary.workoutElevatedTargetSeconds) missing_elevated_s=\(summary.workoutElevatedMissingSeconds) longest_bout_s=\(summary.workoutBoutSeconds) required_bout_s=\(summary.workoutBoutTargetSeconds) missing_bout_s=\(summary.workoutBoutMissingSeconds) ready_if=\(summary.workoutProofReadyIf) auto_detection_required=\(workout.autoReady ? 0 : 1)")
        }
        let sleep = summary.sleep
        if sleep.present {
            logGateETrainingLine("WHOOPDBG gate_e_training kind=sleep confirmed=1 id=\(sleep.confirmedID) source=\(sleep.source) confidence=\(sleep.confidence) auto_ready=\(sleep.autoReady ? 1 : 0) auto_reason=\(sleep.autoReason) matched_source=\(sleep.matchedSource) overlap_s=\(Int(sleep.overlap.rounded())) duration_s=\(Int(sleep.duration.rounded())) span_s=\(Int(sleep.span.rounded())) candidate_duration_s=\(Int(sleep.candidateDuration.rounded())) candidate_span_s=\(Int(sleep.candidateSpan.rounded())) avg_hr=\(sleep.avgHR) peak_hr=\(sleep.peakHR) sleep_rhr=\(sleep.sleepRHR) motion_source=\(sleep.motionSource) motion_validated=\(sleep.motionValidated ? 1 : 0) motion_hints=\(sleep.motionHints) historical_motion_status=\(sleep.historicalMotionStatus) fallback_accepted=\(sleep.fallbackAccepted ? 1 : 0) fallback_policy=\(sleep.fallbackPolicy) auto_detection_required=\(sleep.autoReady ? 0 : 1)")
        }
    }

    private func logGateETrainingLine(_ line: String) {
        let sanitized = line.replacingOccurrences(of: " ", with: "_")
        persistGateStatusSnapshotLine(sanitized, reset: false)
        WHOOPDebugLog("%@", sanitized)
    }

    private func exactWorkoutTrainingReadiness(for workout: UserConfirmedWorkout,
                                               rest: Int,
                                               maxHR: Int) -> (readiness: WorkoutReadiness, overlap: TimeInterval, samples: Int) {
        let overlapping = canonicalSessions().filter { overlapSeconds($0.start, $0.end, workout.start, workout.end) > 0 }
        let overlap = overlapping.reduce(0) { $0 + overlapSeconds($1.start, $1.end, workout.start, workout.end) }
        let points = overlapping.flatMap { session in
            session.points.compactMap { point -> SavedSession.Point? in
                let absolute = session.start.addingTimeInterval(point.t)
                guard absolute >= workout.start, absolute <= workout.end else { return nil }
                return SavedSession.Point(t: absolute.timeIntervalSince(workout.start), bpm: point.bpm)
            }
        }.sorted { lhs, rhs in
            if lhs.t != rhs.t { return lhs.t < rhs.t }
            return lhs.bpm < rhs.bpm
        }
        let session = SavedSession(id: UUID(),
                                   start: workout.start,
                                   end: workout.end,
                                   label: "Confirmed workout training window",
                                   points: points,
                                   hrv: nil,
                                   rrPoints: nil,
                                   hrvReferenceValidated: false,
                                   motionHintCount: overlapping.reduce(0) { $0 + $1.motionHintCountValue },
                                   motionHintKinds: motionHintKindsSummary(for: overlapping),
                                   motionEvidenceSource: overlapping.contains { $0.motionHintCountValue > 0 } ? "diagnostic_observe_only" : "unavailable",
                                   motionEvidenceValidated: false,
                                   motionShortCount: nil,
                                   motionShortMean: nil,
                                   motionShortMin: nil,
                                   motionShortMax: nil,
                                   motionShortOverOneCount: nil,
                                   phoneStepSource: overlapping.contains { $0.phoneStepCountValue > 0 } ? "phone_coremotion_pedometer" : "unavailable",
                                   phoneStepValidated: false,
                                   phoneStepCount: overlapping.reduce(0) { $0 + $1.phoneStepCountValue },
                                   phoneStepDistanceMeters: overlapping
                                       .compactMap(\.phoneStepDistanceMeters)
                                       .reduce(0, +),
                                   phoneStepFloorsAscended: overlapping
                                       .compactMap(\.phoneStepFloorsAscended)
                                       .reduce(0, +),
                                   phoneStepFloorsDescended: overlapping
                                       .compactMap(\.phoneStepFloorsDescended)
                                       .reduce(0, +),
                                   hrRaw2A37: overlapping.reduce(0) { $0 + $1.hrRaw2A37Value },
                                   hrAccepted: overlapping.reduce(0) { $0 + $1.hrAcceptedValue },
                                   hrZero: overlapping.reduce(0) { $0 + $1.hrZeroValue },
                                   hrArtifactHeld: overlapping.reduce(0) { $0 + $1.hrArtifactHeldValue },
                                   hrArtifactDropped: overlapping.reduce(0) { $0 + $1.hrArtifactDroppedValue },
                                   hrRawGaps: overlapping.reduce(0) { $0 + $1.hrRawGapsValue },
                                   hrAcceptedGaps: overlapping.reduce(0) { $0 + $1.hrAcceptedGapsValue },
                                   hrMaxRawGap: overlapping.map(\.hrMaxRawGapValue).max() ?? 0,
                                   hrMaxAcceptedGap: overlapping.map(\.hrMaxAcceptedGapValue).max() ?? 0)
        return (session.workoutReadiness(rest: rest, maxHR: maxHR), overlap, points.count)
    }

    private func bestSleepTrainingMatch(for sleep: UserConfirmedSleep,
                                        rest: Int) -> (autoReady: Bool,
                                                       reason: String,
                                                       source: String,
                                                       overlap: TimeInterval,
                                                       duration: TimeInterval,
                                                       span: TimeInterval,
                                                       motionSource: String,
                                                       motionValidated: Bool,
                                                       motionHints: Int,
                                                       historicalMotionStatus: String,
                                                       fallbackAccepted: Bool,
                                                       fallbackPolicy: String) {
        let candidates = aggregateSleepCandidates(rest: rest, calendar: .current)
        guard let best = candidates.max(by: {
            overlapSeconds($0.start, $0.end, sleep.start, sleep.end) < overlapSeconds($1.start, $1.end, sleep.start, sleep.end)
        }) else {
            return (false, "no_auto_sleep_candidate", "none", 0, 0, 0, sleep.motionSource, sleep.motionValidated, 0, "none", false, "none")
        }
        let overlap = overlapSeconds(best.start, best.end, sleep.start, sleep.end)
        let autoReady = best.motionEvidenceValidated && best.confidence != .low
        let overlapDenominator = max(min(sleep.span, best.span), 1)
        let overlapFraction = overlap / overlapDenominator
        let hrOnlyFallbackAccepted = !autoReady
            && !best.motionEvidenceValidated
            && overlapFraction >= 0.60
            && best.duration >= AggregateSleepCandidate.fragmentedMinimumDuration
            && best.span >= AggregateSleepCandidate.fragmentedMinimumSpan
        let fallbackPolicy = hrOnlyFallbackAccepted
            ? "hr_only_sleep_fallback_labeled_confirmed_overlap"
            : "none"
        let reason = autoReady
            ? "auto_sleep_ready"
            : "\(best.reason)_motion_validated_\(best.motionEvidenceValidated ? 1 : 0)_hr_only_fallback_labeled_\(hrOnlyFallbackAccepted ? 1 : 0)"
        return (autoReady,
                reason,
                best.sessions > 1 ? "aggregate_sleep" : "sleep_window",
                overlap,
                best.duration,
                best.span,
                best.motionEvidenceSource,
                best.motionEvidenceValidated,
                best.motionHintCount,
                best.historicalMotionStatus,
                hrOnlyFallbackAccepted,
                fallbackPolicy)
    }

    private func overlapSeconds(_ startA: Date, _ endA: Date, _ startB: Date, _ endB: Date) -> TimeInterval {
        max(0, min(endA, endB).timeIntervalSince(max(startA, startB)))
    }

    private func persistGateStatusSnapshotLine(_ line: String, reset: Bool) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("atria-gate-status.txt")
        let text = line + "\n"
        do {
            if reset || !FileManager.default.fileExists(atPath: url.path) {
                try text.write(to: url, atomically: true, encoding: .utf8)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            WHOOPDebugLog("WHOOPDBG gate_status_snapshot_error error=%@", String(describing: error))
        }
    }

    private func logExecutionPriority(hrvValidated: Int,
                                      hrvBaselineSamples: Int,
                                      externalHRReferenceReady: Bool,
                                      gateDReady: Bool,
                                      recoveryHighReady _: Bool,
                                      sleepDays: Int,
                                      sleepEvidenceReady: Bool,
                                      sleepEvidenceBlocker: String,
                                      rrReplay: RRLedgerReplaySummary,
                                      workoutReplay: WorkoutReplaySummary,
                                      trend90CoveragePercent: Int,
                                      gateGPlatformReady: Bool,
                                      gateGMetricBlockers: [String],
                                      historicalDownloadProtocolValidated: Bool,
                                      activeJournal: ActiveSessionJournal.Diagnostics,
                                      historicalArchive: HistoricalArchive.Diagnostics) {
        var externalBlocked: [String] = []
        var realWorldNeeded: [String] = []
        var localBlocked: [String] = []
        var ready: [String] = []
        var diagnosticOnly: [String] = []
        let currentRRWindowInspectable = activeJournal.duration >= 60 || activeJournal.samples >= 60
        let currentRRCaptureBlocked = hrvValidated == 0
            && activeJournal.present
            && activeJournal.fresh
            && currentRRWindowInspectable
            && !activeJournal.rrContinuityReady
            && !activeJournal.recentRRContinuityClean
            && !rrReplay.bestReady
        let currentRRBlocker = activeJournal.rrValues > 0
            ? "B:current_rr_continuity_gap_\(Int(activeJournal.maxRRGap.rounded()))s_coverage_\(activeJournal.rrCoverage3Percent)p"
            : "B:current_rr_missing_current_hr_samples_\(activeJournal.samples)"
        let currentRRAction = activeJournal.rrValues > 0
            ? "restore_current_rr_continuity_before_external_reference"
            : "restore_current_rr_presence_before_external_reference"
        let currentRRLocalAction = activeJournal.rrValues > 0
            ? "restore_current_rr_continuity_no_gap_over_3s"
            : "restore_current_rr_presence_from_2a37"

        if hrvValidated == 0 {
            externalBlocked.append("B:external_rr_reference")
            externalBlocked.append("C:validated_hrv_baseline_\(hrvBaselineSamples)_of_7")
            if currentRRCaptureBlocked {
                localBlocked.append(currentRRBlocker)
            }
        } else if hrvBaselineSamples < 7 {
            localBlocked.append("C:personal_baseline_hrv_\(hrvBaselineSamples)_of_7")
        }
        if !externalHRReferenceReady {
            externalBlocked.append("D:external_hr_reference")
        }
        if !sleepEvidenceReady {
            realWorldNeeded.append(sleepDays > 0 ? "E:\(sleepEvidenceBlocker)" : "E:sleep_capture")
        }
        if workoutReplay.readySessions == 0 {
            realWorldNeeded.append("E:real_sustained_workout")
        }
        if trend90CoveragePercent < 70 || hrvValidated == 0 {
            realWorldNeeded.append("F:more_real_history_or_hrv_reference")
        }
        if !gateGPlatformReady {
            localBlocked.append("G:platform_plumbing")
        }
        let gateGLocalMetricBlockers = gateGMetricBlockers.filter {
            $0 != "healthkit_hrv_reference_pending" && $0 != "healthkit_workout_learning"
        }
        if !gateGLocalMetricBlockers.isEmpty {
            localBlocked.append("G:\(gateGLocalMetricBlockers.joined(separator: "+"))")
        }
        if historicalDownloadProtocolValidated {
            ready.append("H:historical_protocol_exit")
        } else {
            localBlocked.append("H:historical_download")
        }
        if historicalArchive.currentSessionUsableRows == 0 {
            diagnosticOnly.append("H:historical_metrics_fail_closed")
        }

        let nextGate: String
        let nextAction: String
        let nextLocalGate: String
        let nextLocalAction: String
        if hrvValidated == 0 {
            nextGate = "B"
            nextAction = currentRRCaptureBlocked
                ? currentRRAction
                : rrReplay.bestReady
                ? "provide_external_rr_reference_for_ready_rr_window"
                : "capture_clean_5min_rr_window_before_reference"
        } else if workoutReplay.readySessions == 0 {
            nextGate = "E"
            nextAction = workoutReplay.bestNextAction == "inspect_detector_inputs"
                ? "capture_real_sustained_elevated_hr_workout"
                : workoutReplay.bestNextAction
        } else if !externalHRReferenceReady {
            nextGate = "D"
            nextAction = "provide_external_hr_reference_for_rest_to_max"
        } else if trend90CoveragePercent < 70 {
            nextGate = "F"
            nextAction = "accumulate_real_history"
        } else if !gateGMetricBlockers.isEmpty {
            nextGate = "G"
            nextAction = "export_metrics_after_source_gates_ready"
        } else {
            nextGate = "none"
            nextAction = "preserve_ready_gates_and_collect_references"
        }
        if !gateGPlatformReady {
            nextLocalGate = "G"
            nextLocalAction = "finish_platform_plumbing"
        } else if currentRRCaptureBlocked {
            nextLocalGate = "B"
            nextLocalAction = currentRRLocalAction
        } else if !gateGLocalMetricBlockers.isEmpty {
            nextLocalGate = "G"
            nextLocalAction = "repair_healthkit_export_readback"
        } else if workoutReplay.readySessions == 0 || !sleepEvidenceReady {
            nextLocalGate = "E"
            nextLocalAction = "run_targeted_sleep_or_workout_diagnostics"
        } else if !historicalDownloadProtocolValidated {
            nextLocalGate = "H"
            nextLocalAction = "finish_historical_download_or_new_sensor_decode"
        } else if hrvBaselineSamples < 7 {
            nextLocalGate = "C"
            nextLocalAction = "accumulate_personal_hrv_baseline"
        } else {
            nextLocalGate = "none"
            nextLocalAction = "no_local_code_unblocker_collect_external_reference_or_real_workout"
        }

        logHRProfileValidationPlan(workoutReplay: workoutReplay,
                                   externalHRReferenceReady: externalHRReferenceReady,
                                   gateDReady: gateDReady)
        logExecutionPrioritySnapshot(nextGate: nextGate,
                                     nextAction: nextAction,
                                     nextLocalGate: nextLocalGate,
                                     nextLocalAction: nextLocalAction,
                                     externalBlocked: externalBlocked.isEmpty ? "none" : externalBlocked.joined(separator: ","),
                                     realWorldNeeded: realWorldNeeded.isEmpty ? "none" : realWorldNeeded.joined(separator: ","),
                                     localBlocked: localBlocked.isEmpty ? "none" : localBlocked.joined(separator: ","),
                                     ready: ready.isEmpty ? "none" : ready.joined(separator: ","),
                                     diagnosticOnly: diagnosticOnly.isEmpty ? "none" : diagnosticOnly.joined(separator: ","),
                                     skip: "no_start_retry_no_blind_history_selector_no_fake_metrics")
    }

    private func logHRProfileValidationPlan(workoutReplay: WorkoutReplaySummary,
                                            externalHRReferenceReady: Bool,
                                            gateDReady: Bool) {
        guard workoutReplay.readySessions == 0 else { return }
        let action = workoutReplay.bestNextAction
        let reserve = max(workoutReplay.maxHR - workoutReplay.restHR, 0)
        let p95HRR = reserve > 0
            ? Int((Double(workoutReplay.bestP95HR - workoutReplay.restHR) / Double(reserve) * 100).rounded())
            : 0
        let p99HRR = reserve > 0
            ? Int((Double(workoutReplay.bestP99HR - workoutReplay.restHR) / Double(reserve) * 100).rounded())
            : 0
        let thresholdHRR = reserve > 0
            ? Int((Double(workoutReplay.bestThresholdHR - workoutReplay.restHR) / Double(reserve) * 100).rounded())
            : 0
        let reason = workoutReplay.bestHRDistributionBelowWorkoutBand
            ? "wrist_hr_distribution_below_workout_band"
            : workoutReplay.bestPrimaryBlocker
        let referenceState = externalHRReferenceReady
            ? "available_validate_rest_to_max"
            : "missing_independent_hr_reference"
        let nextProof = externalHRReferenceReady
            ? "rerun_gate_status_and_strain_validation_with_reference"
            : "export_atria_hr_package_then_compare_independent_hr_csv_or_healthkit_non_atria"
        let requiredProof: String
        if workoutReplay.bestHasBlockingStreamGap {
            requiredProof = "sustained_hrr50_480s_with_stream_coverage_75_percent_or_reconnect_fix_plus_reference"
        } else if workoutReplay.bestPeakHR < workoutReplay.bestThresholdHR || workoutReplay.bestHRDistributionBelowWorkoutBand {
            requiredProof = "independent_hr_reference_or_profile_update_before_counting_workout"
        } else if workoutReplay.bestElevatedSeconds < workoutReplay.bestRequiredElevatedSeconds
                    || workoutReplay.bestLongestBout < workoutReplay.bestRequiredBout {
            requiredProof = "sustained_hrr50_required_elevated_time_and_continuous_bout"
        } else {
            requiredProof = "inspect_detector_inputs_no_metric_credit"
        }

        WHOOPDebugLog("WHOOPDBG hr_profile_validation_plan status=needed reason=%@ gate_d_ready=%d gate_e_ready=0 workout_ready=0 next_action=%@ next_proof=%@ required_proof=%@ reference_state=%@ reference_required=independent_hr_csv_or_healthkit_non_atria export_action=run_--export-hr-reference-package validate_action=push_independent_hr_csv_to_Documents/atria-reference/hr-reference.csv_then_run_--validate-hr-reference cannot_count_workout_without=sustained_hr_or_external_reference source=%@ chunks=%d coverage_percent=%d duration_s=%.0f observed_s=%.0f dropped_gap_s=%.0f max_gap_s=%.1f samples=%d rest_hr=%d profile_max_hr=%d reserve_hr=%d threshold_hr=%d threshold_hrr_percent=%d peak_hr=%d p95_hr=%d p95_hrr_percent=%d p99_hr=%d p99_hrr_percent=%d required_profile_max_hr_for_p95_hrr50=%d required_profile_max_hr_for_p99_hrr50=%d required_profile_max_hr_for_peak_hrr50=%d current_profile_minus_p99_required_bpm=%d profile_sensitivity_diagnostic_only=1 samples_above_threshold=%d samples_above_borderline=%d elevated_s=%.0f required_elevated_s=%.0f longest_bout_s=%.0f required_bout_s=%.0f hr_distribution_below_workout_band=%d primary_blocker=%@ stream_coverage_required_percent=75 hrr50_required=1 external_hr_reference_required=1 always_emit_when_workout_ready_0=1",
              reason,
              gateDReady ? 1 : 0,
              action,
              nextProof,
              requiredProof,
              referenceState,
              workoutReplay.bestSource,
              workoutReplay.bestChunkCount,
              workoutReplay.bestStreamCoveragePercent,
              workoutReplay.bestDuration,
              workoutReplay.bestObservedDuration,
              workoutReplay.bestDroppedGapSeconds,
              workoutReplay.bestMaxSampleGap,
              workoutReplay.bestSamples,
              workoutReplay.restHR,
              workoutReplay.maxHR,
              reserve,
              workoutReplay.bestThresholdHR,
              thresholdHRR,
              workoutReplay.bestPeakHR,
              workoutReplay.bestP95HR,
              p95HRR,
              workoutReplay.bestP99HR,
              p99HRR,
              workoutReplay.profileMaxHRForBestP95AtHRR50,
              workoutReplay.profileMaxHRForBestP99AtHRR50,
              workoutReplay.profileMaxHRForBestPeakAtHRR50,
              workoutReplay.p99ProfileMaxHRGap,
              workoutReplay.bestSamplesAboveThreshold,
              workoutReplay.bestSamplesAboveBorderline,
              workoutReplay.bestElevatedSeconds,
              workoutReplay.bestRequiredElevatedSeconds,
              workoutReplay.bestLongestBout,
              workoutReplay.bestRequiredBout,
              workoutReplay.bestHRDistributionBelowWorkoutBand ? 1 : 0,
              workoutReplay.bestPrimaryBlocker)
    }

    private func logRRLedgerReplay(_ summary: RRLedgerReplaySummary) {
        let metricSummary: String
        if summary.bestReady {
            metricSummary = String(format: "rmssd=%.1f sdnn=%.1f pnn50=%.1f lnrmssd=%.2f resp=%@",
                                   summary.bestRMSSD ?? 0,
                                   summary.bestSDNN ?? 0,
                                   summary.bestPNN50 ?? 0,
                                   summary.bestLnRMSSD ?? 0,
                                   formatDouble(summary.bestRespiratoryRate))
        } else {
            metricSummary = "rmssd=learning sdnn=learning pnn50=learning lnrmssd=learning resp=learning"
        }
        WHOOPDebugLog("WHOOPDBG rr_ledger_summary sessions=%d rr_samples=%d best_ready=%d best_label=%@ raw=%d kept=%d rejected_out_of_range=%d rejected_delta_over_20_percent=%d interpolated=%d conf=%d window=%.0f max_rr_gap_s=%.1f reason=%@ source=saved_rr_points reference_validated=0 %@",
              summary.sessionsWithRR,
              summary.rrSamples,
              summary.bestReady ? 1 : 0,
              summary.bestSessionLabel,
              summary.bestRaw,
              summary.bestKept,
              summary.bestRejectedOutOfRange,
              summary.bestRejectedDeltaOver20Percent,
              summary.bestInterpolated,
              summary.bestConfidencePercent,
              summary.bestWindowSeconds,
              summary.bestMaxRRGapSeconds,
              summary.reason,
              metricSummary)
    }

    private func replaySavedRRLedger(limitSessions: Int? = nil,
                                     includeActiveJournal: Bool = false) -> RRLedgerReplaySummary {
        let replaySessions = canonicalSessions(includeActiveJournal: includeActiveJournal)
        let sessionsWithRR = replaySessions.filter { $0.rrSampleCount > 0 }.count
        let rrSamples = totalRRSamples(in: replaySessions)
        guard let best = bestSavedRRReferenceWindow(limitSessions: limitSessions,
                                                    includeActiveJournal: includeActiveJournal) else {
            if rrSamples > 0 {
                return RRLedgerReplaySummary(sessionsWithRR: sessionsWithRR,
                                             rrSamples: rrSamples,
                                             bestReady: false,
                                             bestSessionLabel: "none",
                                             bestRaw: 0,
                                             bestKept: 0,
                                             bestConfidencePercent: 0,
                                             bestWindowSeconds: 0,
                                             bestMaxRRGapSeconds: 0,
                                             bestRejectedOutOfRange: 0,
                                             bestRejectedDeltaOver20Percent: 0,
                                             bestInterpolated: 0,
                                             bestRMSSD: nil,
                                             bestSDNN: nil,
                                             bestPNN50: nil,
                                             bestLnRMSSD: nil,
                                             bestRespiratoryRate: nil,
                                             reason: "no_300s_window")
            }
            return RRLedgerReplaySummary.empty
        }
        return RRLedgerReplaySummary(sessionsWithRR: sessionsWithRR,
                                     rrSamples: rrSamples,
                                     bestReady: best.ready,
                                     bestSessionLabel: best.session.label,
                                     bestRaw: best.snapshot.raw,
                                     bestKept: best.snapshot.kept,
                                     bestConfidencePercent: best.snapshot.confidencePercent,
                                     bestWindowSeconds: 300,
                                     bestMaxRRGapSeconds: best.strictGap,
                                     bestRejectedOutOfRange: best.snapshot.rejectedOutOfRange,
                                     bestRejectedDeltaOver20Percent: best.snapshot.rejectedDeltaOver20Percent,
                                     bestInterpolated: best.snapshot.interpolated,
                                     bestRMSSD: best.ready ? best.snapshot.rmssd : nil,
                                     bestSDNN: best.ready ? best.snapshot.sdnn : nil,
                                     bestPNN50: best.ready ? best.snapshot.pnn50 : nil,
                                     bestLnRMSSD: best.ready ? best.snapshot.lnRMSSD : nil,
                                     bestRespiratoryRate: best.ready ? best.snapshot.respiratoryRate : nil,
                                     reason: best.reason)
    }

    private func bestSavedRRReferenceWindow(limitSessions: Int? = nil,
                                            includeActiveJournal: Bool = false) -> RRSavedReferenceWindow? {
        let scanStep: TimeInterval = 15
        var best: RRSavedReferenceWindow?
        var candidates = canonicalSessions(includeActiveJournal: includeActiveJournal)
            .filter { ($0.rrPoints?.count ?? 0) >= 2 }
        candidates.sort {
            if $0.rrSampleCount != $1.rrSampleCount {
                return $0.rrSampleCount > $1.rrSampleCount
            }
            return $0.end > $1.end
        }
        if let limitSessions {
            candidates = Array(candidates.prefix(max(1, limitSessions)))
        }
        for session in candidates {
            guard let points = session.rrPoints, points.count >= 2 else { continue }
            let sorted = points.sorted { $0.t < $1.t }
            guard let first = sorted.first?.t, let last = sorted.last?.t, last >= 300 else { continue }
            var startIndex = 0
            var endIndex = 0
            let firstEnd = max(300, ceil(first / scanStep) * scanStep)
            var endSeconds = firstEnd
            while endSeconds <= last {
                let windowStartSeconds = endSeconds - 300
                while startIndex < sorted.count && sorted[startIndex].t < windowStartSeconds {
                    startIndex += 1
                }
                while endIndex + 1 < sorted.count && sorted[endIndex + 1].t <= endSeconds {
                    endIndex += 1
                }
                if endIndex < startIndex || endIndex - startIndex + 1 < 2 {
                    endSeconds += scanStep
                    continue
                }
                let candidate = sorted[startIndex...endIndex].map { point in
                    (t: session.start.addingTimeInterval(point.t), ms: Double(point.ms))
                }
                let windowStart = session.start.addingTimeInterval(windowStartSeconds)
                let now = session.start.addingTimeInterval(endSeconds)
                let strictGap = strictRRGapSeconds(candidate,
                                                   windowStart: windowStart,
                                                   windowEnd: now)
                guard let snapshot = rrReferenceSnapshot(candidate,
                                                         windowStart: windowStart,
                                                         windowEnd: now,
                                                         strictGap: strictGap) else {
                    endSeconds += scanStep
                    continue
                }
                let ready = strictGap <= HRVSnapshot.maxReadyRRGapSeconds
                    && snapshot.kept >= 240
                    && snapshot.confidence >= 0.75
                let reason = ready ? "ready" : replayReason(snapshot: snapshot, strictGap: strictGap)
                let window = RRSavedReferenceWindow(session: session,
                                                    samples: candidate,
                                                    snapshot: snapshot,
                                                    strictGap: strictGap,
                                                    windowStart: windowStart,
                                                    windowEnd: now,
                                                    ready: ready,
                                                    reason: reason)
                if let current = best {
                    if isBetterRRReferenceWindow(window, than: current) {
                        best = window
                    }
                } else {
                    best = window
                }
                endSeconds += scanStep
            }
        }
        return best
    }

    private func rrReferenceSnapshot(_ samples: [(t: Date, ms: Double)],
                                     windowStart: Date,
                                     windowEnd: Date,
                                     strictGap: TimeInterval) -> HRVSnapshot? {
        guard samples.count >= 2 else { return nil }
        var kept: [(t: Date, ms: Double)] = []
        var rejectedOutOfRange = 0
        var rejectedDeltaOver20Percent = 0
        for rr in samples {
            guard (300...2000).contains(rr.ms) else {
                rejectedOutOfRange += 1
                continue
            }
            if let previous = kept.last {
                let delta = abs(rr.ms - previous.ms) / previous.ms
                guard delta <= 0.20 else {
                    rejectedDeltaOver20Percent += 1
                    continue
                }
            }
            kept.append(rr)
        }
        guard kept.count >= 2 else {
            return HRVSnapshot(rmssd: 0,
                               sdnn: 0,
                               pnn50: 0,
                               lnRMSSD: 0,
                               confidence: Double(kept.count) / Double(samples.count),
                               kept: kept.count,
                               raw: samples.count,
                               rejectedOutOfRange: rejectedOutOfRange,
                               rejectedDeltaOver20Percent: rejectedDeltaOver20Percent,
                               rejectedHRMismatch: 0,
                               interpolated: 0,
                               windowSeconds: windowEnd.timeIntervalSince(windowStart),
                               maxRRGapSeconds: strictGap,
                               respiratoryRate: nil)
        }
        let sorted = kept.sorted { $0.t < $1.t }
        let diffs = zip(sorted.dropFirst(), sorted).map { $0.ms - $1.ms }
        let rmssd = sqrt(diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count))
        let mean = sorted.map(\.ms).reduce(0, +) / Double(sorted.count)
        let sdnn = sqrt(sorted.map { pow($0.ms - mean, 2) }.reduce(0, +) / Double(sorted.count - 1))
        let pnn50 = Double(diffs.filter { abs($0) > 50 }.count) / Double(diffs.count) * 100
        return HRVSnapshot(rmssd: rmssd,
                           sdnn: sdnn,
                           pnn50: pnn50,
                           lnRMSSD: rmssd > 0 ? log(rmssd) : 0,
                           confidence: Double(kept.count) / Double(samples.count),
                           kept: kept.count,
                           raw: samples.count,
                           rejectedOutOfRange: rejectedOutOfRange,
                           rejectedDeltaOver20Percent: rejectedDeltaOver20Percent,
                           rejectedHRMismatch: 0,
                           interpolated: 0,
                           windowSeconds: windowEnd.timeIntervalSince(windowStart),
                           maxRRGapSeconds: strictGap,
                           respiratoryRate: nil)
    }

    private func replayReason(snapshot: HRVSnapshot, strictGap: TimeInterval) -> String {
        if strictGap > HRVSnapshot.maxReadyRRGapSeconds { return "gap" }
        if snapshot.kept < 240 { return "beats" }
        if snapshot.confidence < 0.75 { return "confidence" }
        return "learning"
    }

    private func strictRRGapSeconds(_ samples: [(t: Date, ms: Double)], windowStart: Date, windowEnd: Date) -> TimeInterval {
        guard let first = samples.first else { return windowEnd.timeIntervalSince(windowStart) }
        var maxGap = first.t.timeIntervalSince(windowStart)
        var previous = first.t
        for sample in samples.dropFirst() {
            maxGap = max(maxGap, sample.t.timeIntervalSince(previous))
            previous = sample.t
        }
        maxGap = max(maxGap, windowEnd.timeIntervalSince(previous))
        return maxGap
    }

    private func isBetterRRLedgerSummary(_ lhs: RRLedgerReplaySummary, than rhs: RRLedgerReplaySummary) -> Bool {
        if lhs.bestReady != rhs.bestReady { return lhs.bestReady }
        if lhs.bestKept != rhs.bestKept { return lhs.bestKept > rhs.bestKept }
        if lhs.bestConfidencePercent != rhs.bestConfidencePercent {
            return lhs.bestConfidencePercent > rhs.bestConfidencePercent
        }
        return lhs.bestMaxRRGapSeconds < rhs.bestMaxRRGapSeconds
    }

    private func isBetterRRReferenceWindow(_ lhs: RRSavedReferenceWindow, than rhs: RRSavedReferenceWindow) -> Bool {
        if lhs.ready != rhs.ready { return lhs.ready }
        if lhs.snapshot.kept != rhs.snapshot.kept { return lhs.snapshot.kept > rhs.snapshot.kept }
        if lhs.snapshot.confidencePercent != rhs.snapshot.confidencePercent {
            return lhs.snapshot.confidencePercent > rhs.snapshot.confidencePercent
        }
        return lhs.strictGap < rhs.strictGap
    }

    private func logWorkoutReplay(_ summary: WorkoutReplaySummary) {
        WHOOPDebugLog("WHOOPDBG workout_replay_summary raw_sessions=%d canonical_sessions=%d sessions=%d ready=%d near_miss=%d near_miss_reason=%@ strength_candidate=%d strength_candidate_reason=%@ strength_diagnostic_only=1 next_action=%@ best_source=%@ best_chunks=%d best_span_s=%.0f best_label=%@ status=%@ reason=%@ primary_blocker=%@ stream_coverage_percent=%d duration_s=%.0f observed_duration_s=%.0f dropped_gap_s=%.0f max_gap_s=%.1f gap_count=%d samples=%d avg_hr=%d peak_hr=%d p95_hr=%d p99_hr=%d rest_hr=%d max_hr=%d threshold_hr=%d threshold_gap_bpm=%d samples_above_threshold=%d samples_above_borderline=%d hr_distribution_below_workout_band=%d elevated_s=%.0f required_elevated_s=%.0f longest_bout_s=%.0f required_bout_s=%.0f elevated_fraction=%.2f borderline_threshold_hr=%d borderline_elevated_s=%.0f borderline_longest_bout_s=%.0f borderline_diagnostic_only=1 hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f source=saved_sessions_plus_aggregates",
              summary.rawSessions,
              summary.canonicalSessions,
              summary.sessionsEvaluated,
              summary.readySessions,
              summary.nearMiss ? 1 : 0,
              summary.nearMissReason,
              summary.strengthCandidate ? 1 : 0,
              summary.strengthCandidateReason,
              summary.bestNextAction,
              summary.bestSource,
              summary.bestChunkCount,
              summary.bestSpan,
              summary.bestLabel,
              summary.bestStatus,
              summary.bestReason,
              summary.bestPrimaryBlocker,
              summary.bestStreamCoveragePercent,
              summary.bestDuration,
              summary.bestObservedDuration,
              summary.bestDroppedGapSeconds,
              summary.bestMaxSampleGap,
              summary.bestGapCount,
              summary.bestSamples,
              summary.bestAvgHR,
              summary.bestPeakHR,
              summary.bestP95HR,
              summary.bestP99HR,
              summary.restHR,
              summary.maxHR,
              summary.bestThresholdHR,
              summary.bestThresholdGapBPM,
              summary.bestSamplesAboveThreshold,
              summary.bestSamplesAboveBorderline,
              summary.bestHRDistributionBelowWorkoutBand ? 1 : 0,
              summary.bestElevatedSeconds,
              summary.bestRequiredElevatedSeconds,
              summary.bestLongestBout,
              summary.bestRequiredBout,
              summary.bestElevatedFraction,
              summary.bestBorderlineThresholdHR,
              summary.bestBorderlineElevatedSeconds,
              summary.bestBorderlineLongestBout,
              summary.bestHRRaw2A37,
              summary.bestHRAccepted,
              summary.bestHRZero,
              summary.bestHRArtifactHeld,
              summary.bestHRArtifactDropped,
              summary.bestHRRawGaps,
              summary.bestHRAcceptedGaps,
              summary.bestHRMaxRawGap,
              summary.bestHRMaxAcceptedGap)
    }

    private func historicalGapRepairSummary(workoutReplay: WorkoutReplaySummary,
                                            archive: HistoricalArchive.Diagnostics) -> HistoricalGapRepairSummary {
        let archiveStart = (archive.correctedUnixFirst ?? archive.unixFirst).map { Double($0) }
        let archiveEnd = (archive.correctedUnixLast ?? archive.unixLast).map { Double($0) }
        let workoutStart = workoutReplay.bestStart?.timeIntervalSince1970
        let workoutEnd = workoutReplay.bestEnd?.timeIntervalSince1970
        let overlap = Self.overlapSeconds(archiveStart: archiveStart,
                                          archiveEnd: archiveEnd,
                                          workoutStart: workoutStart,
                                          workoutEnd: workoutEnd)
        let separation = Self.separationSeconds(archiveStart: archiveStart,
                                                archiveEnd: archiveEnd,
                                                workoutStart: workoutStart,
                                                workoutEnd: workoutEnd)
        let reason: String
        if workoutReplay.sessionsEvaluated == 0 || workoutStart == nil || workoutEnd == nil {
            reason = "no_saved_workout_attempt"
        } else if !archive.exists {
            reason = "missing_archive"
        } else if !archive.parseOK {
            reason = "archive_parse_failed"
        } else if archive.rows == 0 || archiveStart == nil || archiveEnd == nil {
            reason = "no_historical_time_range"
        } else if overlap <= 0 {
            reason = "no_workout_overlap"
        } else if archive.currentSessionUsableRows == 0 {
            reason = "current_session_not_marked_usable"
        } else if archive.metricUsableRows == 0 {
            reason = "metric_fail_closed_layout_unvalidated"
        } else {
            reason = "candidate_overlap_requires_strict_replay"
        }
        let metricUsable = false
        return HistoricalGapRepairSummary(status: "fail_closed",
                                          reason: reason,
                                          archiveRows: archive.rows,
                                          archiveCurrentUsableRows: archive.currentSessionUsableRows,
                                          archiveMetricUsableRows: archive.metricUsableRows,
                                          archiveStartUnix: Int(archiveStart ?? 0),
                                          archiveEndUnix: Int(archiveEnd ?? 0),
                                          workoutStartUnix: Int(workoutStart ?? 0),
                                          workoutEndUnix: Int(workoutEnd ?? 0),
                                          overlapSeconds: Int(overlap.rounded()),
                                          separationSeconds: Int(separation.rounded()),
                                          diagnosticOnly: true,
                                          metricUsable: metricUsable)
    }

    private func logHistoricalGapRepair(_ summary: HistoricalGapRepairSummary) {
        WHOOPDebugLog("WHOOPDBG historical_gap_repair status=%@ reason=%@ diagnostic_only=%d metric_usable=%d archive_rows=%d archive_current_usable_rows=%d archive_metric_usable_rows=%d archive_start_unix=%d archive_end_unix=%d workout_start_unix=%d workout_end_unix=%d overlap_s=%d separation_s=%d source=historical_archive_vs_saved_workout",
              summary.status,
              summary.reason,
              summary.diagnosticOnly ? 1 : 0,
              summary.metricUsable ? 1 : 0,
              summary.archiveRows,
              summary.archiveCurrentUsableRows,
              summary.archiveMetricUsableRows,
              summary.archiveStartUnix,
              summary.archiveEndUnix,
              summary.workoutStartUnix,
              summary.workoutEndUnix,
              summary.overlapSeconds,
              summary.separationSeconds)
    }

    private static func overlapSeconds(archiveStart: Double?,
                                       archiveEnd: Double?,
                                       workoutStart: Double?,
                                       workoutEnd: Double?) -> Double {
        guard let archiveStart, let archiveEnd, let workoutStart, let workoutEnd else { return 0 }
        return max(0, min(archiveEnd, workoutEnd) - max(archiveStart, workoutStart))
    }

    private static func separationSeconds(archiveStart: Double?,
                                          archiveEnd: Double?,
                                          workoutStart: Double?,
                                          workoutEnd: Double?) -> Double {
        guard let archiveStart, let archiveEnd, let workoutStart, let workoutEnd else { return 0 }
        if overlapSeconds(archiveStart: archiveStart,
                          archiveEnd: archiveEnd,
                          workoutStart: workoutStart,
                          workoutEnd: workoutEnd) > 0 {
            return 0
        }
        if archiveEnd < workoutStart {
            return workoutStart - archiveEnd
        }
        return archiveStart - workoutEnd
    }

    func savedWorkoutAttemptStatus(rest: Int, maxHR: Int) -> SavedWorkoutAttemptStatus {
        let summary = replaySavedWorkoutReadiness(rest: rest, maxHR: maxHR)
        guard summary.sessionsEvaluated > 0 else { return .empty }
        return SavedWorkoutAttemptStatus(source: summary.bestSource,
                                         label: summary.bestLabel,
                                         chunks: summary.bestChunkCount,
                                         status: summary.bestStatus,
                                         reason: summary.bestReason,
                                         primaryBlocker: summary.bestPrimaryBlocker,
                                         nearMiss: summary.nearMiss,
                                         nearMissReason: summary.nearMissReason,
                                         streamCoveragePercent: summary.bestStreamCoveragePercent,
                                         duration: summary.bestDuration,
                                         observedDuration: summary.bestObservedDuration,
                                         droppedGapSeconds: summary.bestDroppedGapSeconds,
                                         maxSampleGap: summary.bestMaxSampleGap,
                                         gapCount: summary.bestGapCount,
                                         peakHR: summary.bestPeakHR,
                                         p95HR: summary.bestP95HR,
                                         p99HR: summary.bestP99HR,
                                         thresholdHR: summary.bestThresholdHR,
                                         thresholdGapBPM: summary.bestThresholdGapBPM,
                                         samplesAboveThreshold: summary.bestSamplesAboveThreshold,
                                         samplesAboveBorderline: summary.bestSamplesAboveBorderline,
                                         elevatedSeconds: summary.bestElevatedSeconds,
                                         requiredElevatedSeconds: summary.bestRequiredElevatedSeconds,
                                         longestBout: summary.bestLongestBout,
                                         requiredBout: summary.bestRequiredBout,
                                         borderlineThresholdHR: summary.bestBorderlineThresholdHR,
                                         borderlineElevatedSeconds: summary.bestBorderlineElevatedSeconds,
                                         borderlineLongestBout: summary.bestBorderlineLongestBout,
                                         hrDistributionBelowWorkoutBand: summary.bestHRDistributionBelowWorkoutBand,
                                         restHR: summary.restHR,
                                         profileMaxHR: summary.maxHR,
                                         requiredProfileMaxHRForP95AtHRR50: summary.profileMaxHRForBestP95AtHRR50,
                                         requiredProfileMaxHRForP99AtHRR50: summary.profileMaxHRForBestP99AtHRR50,
                                         requiredProfileMaxHRForPeakAtHRR50: summary.profileMaxHRForBestPeakAtHRR50,
                                         currentProfileMinusP99RequiredBPM: summary.p99ProfileMaxHRGap,
                                         ready: summary.readySessions > 0)
    }

    func savedWorkoutAttemptStatusFast(rest: Int,
                                       maxHR: Int,
                                       limitSessions: Int = 12) -> SavedWorkoutAttemptStatus {
        let summary = replaySavedWorkoutReadiness(rest: rest,
                                                 maxHR: maxHR,
                                                 limitSessions: limitSessions,
                                                 includeAggregates: false)
        guard summary.sessionsEvaluated > 0 else { return .empty }
        return SavedWorkoutAttemptStatus(source: "fast_\(summary.bestSource)",
                                         label: summary.bestLabel,
                                         chunks: summary.bestChunkCount,
                                         status: summary.bestStatus,
                                         reason: summary.bestReason,
                                         primaryBlocker: summary.bestPrimaryBlocker,
                                         nearMiss: summary.nearMiss,
                                         nearMissReason: summary.nearMissReason,
                                         streamCoveragePercent: summary.bestStreamCoveragePercent,
                                         duration: summary.bestDuration,
                                         observedDuration: summary.bestObservedDuration,
                                         droppedGapSeconds: summary.bestDroppedGapSeconds,
                                         maxSampleGap: summary.bestMaxSampleGap,
                                         gapCount: summary.bestGapCount,
                                         peakHR: summary.bestPeakHR,
                                         p95HR: summary.bestP95HR,
                                         p99HR: summary.bestP99HR,
                                         thresholdHR: summary.bestThresholdHR,
                                         thresholdGapBPM: summary.bestThresholdGapBPM,
                                         samplesAboveThreshold: summary.bestSamplesAboveThreshold,
                                         samplesAboveBorderline: summary.bestSamplesAboveBorderline,
                                         elevatedSeconds: summary.bestElevatedSeconds,
                                         requiredElevatedSeconds: summary.bestRequiredElevatedSeconds,
                                         longestBout: summary.bestLongestBout,
                                         requiredBout: summary.bestRequiredBout,
                                         borderlineThresholdHR: summary.bestBorderlineThresholdHR,
                                         borderlineElevatedSeconds: summary.bestBorderlineElevatedSeconds,
                                         borderlineLongestBout: summary.bestBorderlineLongestBout,
                                         hrDistributionBelowWorkoutBand: summary.bestHRDistributionBelowWorkoutBand,
                                         restHR: rest,
                                         profileMaxHR: maxHR,
                                         requiredProfileMaxHRForP95AtHRR50: summary.profileMaxHRForBestP95AtHRR50,
                                         requiredProfileMaxHRForP99AtHRR50: summary.profileMaxHRForBestP99AtHRR50,
                                         requiredProfileMaxHRForPeakAtHRR50: summary.profileMaxHRForBestPeakAtHRR50,
                                         currentProfileMinusP99RequiredBPM: summary.p99ProfileMaxHRGap,
                                         ready: summary.readySessions > 0)
    }

    func confirmBestWorkoutCandidateForUI(rest: Int, maxHR: Int, source: String = "ui") -> UserConfirmedWorkout? {
        confirmBestWorkoutCandidate(rest: rest, maxHR: maxHR, source: source)
    }

    func confirmBestWorkoutCandidateFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-confirm-best-workout-candidate") else { return }
        let rest = baseline.restingInt ?? 60
        _ = confirmBestWorkoutCandidate(rest: rest, maxHR: profile.maxHR, source: "launch_arg")
    }

    private func confirmBestWorkoutCandidate(rest: Int,
                                             maxHR: Int,
                                             source: String) -> UserConfirmedWorkout? {
        let summary = replaySavedWorkoutReadiness(rest: rest, maxHR: maxHR)
        guard let bestStart = summary.bestStart,
              let bestEnd = summary.bestEnd else {
            WHOOPDebugLog("WHOOPDBG workout_confirm status=learning reason=no_confirmable_window source=%@ rest_hr=%d max_hr=%d metric_promotions=0",
                  source,
                  rest,
                  maxHR)
            return nil
        }
        guard summary.sessionsEvaluated > 0,
              summary.bestSource != "none",
              bestEnd > bestStart else {
            WHOOPDebugLog("WHOOPDBG workout_confirm status=learning reason=no_confirmable_candidate source=%@ rest_hr=%d max_hr=%d metric_promotions=0",
                  source,
                  rest,
                  maxHR)
            return nil
        }
        let confirmable = summary.bestObservedDuration >= 10 * 60
            && (summary.nearMiss || summary.strengthCandidate || summary.readySessions > 0 || summary.bestStreamCoveragePercent >= 20)
        guard confirmable else {
            WHOOPDebugLog("WHOOPDBG workout_confirm status=learning reason=candidate_too_weak source=%@ candidate_source=%@ observed_s=%.0f stream_coverage_percent=%d near_miss=%d strength_candidate=%d auto_ready=%d metric_promotions=0",
                  source,
                  summary.bestSource,
                  summary.bestObservedDuration,
                  summary.bestStreamCoveragePercent,
                  summary.nearMiss ? 1 : 0,
                  summary.strengthCandidate ? 1 : 0,
                  summary.readySessions > 0 ? 1 : 0)
            return nil
        }
        var existing = cachedConfirmedWorkouts
        let id = confirmedWorkoutID(start: bestStart, end: bestEnd, source: summary.bestSource)
        if let already = existing.first(where: { $0.id == id }) {
            WHOOPDebugLog("WHOOPDBG workout_confirm status=already_confirmed id=%@ source=%@ candidate_source=%@ start=%@ end=%@ confidence=%@ metric_promotions=0 auto_gate_e_unchanged=1",
                  already.id,
                  source,
                  already.source,
                  isoString(already.start),
                  isoString(already.end),
                  already.confidence)
            return already
        }
        let confidence = summary.readySessions > 0 ? "auto_ready_user_confirmed" :
            (summary.nearMiss ? "user_confirmed_near_miss" : "user_confirmed_candidate")
        let confirmed = UserConfirmedWorkout(id: id,
                                             createdAt: Date(),
                                             start: bestStart,
                                             end: bestEnd,
                                             label: summary.bestLabel,
                                             source: summary.bestSource,
                                             confidence: confidence,
                                             sessions: summary.bestChunkCount,
                                             samples: summary.bestSamples,
                                             avgHR: summary.bestAvgHR,
                                             peakHR: summary.bestPeakHR,
                                             p95HR: summary.bestP95HR,
                                             p99HR: summary.bestP99HR,
                                             thresholdHR: summary.bestThresholdHR,
                                             streamCoveragePercent: summary.bestStreamCoveragePercent,
                                             observedDuration: summary.bestObservedDuration,
                                             reason: summary.bestReason)
        existing.append(confirmed)
        saveConfirmedWorkouts(existing)
        WHOOPDebugLog("WHOOPDBG workout_confirm status=confirmed id=%@ source=%@ candidate_source=%@ label=%@ start=%@ end=%@ duration_s=%.0f observed_s=%.0f chunks=%d samples=%d avg_hr=%d peak_hr=%d p95_hr=%d p99_hr=%d threshold_hr=%d stream_coverage_percent=%d confidence=%@ auto_gate_e_unchanged=1 healthkit_source=user_confirmed",
              confirmed.id,
              source,
              confirmed.source,
              confirmed.label,
              isoString(confirmed.start),
              isoString(confirmed.end),
              confirmed.duration,
              confirmed.observedDuration,
              confirmed.sessions,
              confirmed.samples,
              confirmed.avgHR,
              confirmed.peakHR,
              confirmed.p95HR,
              confirmed.p99HR,
              confirmed.thresholdHR,
              confirmed.streamCoveragePercent,
              confirmed.confidence)
        return confirmed
    }

    private static func readConfirmedWorkouts() -> [UserConfirmedWorkout] {
        guard let data = UserDefaults.standard.data(forKey: ConfirmedWorkoutDefaults.key),
              let decoded = try? JSONDecoder().decode([UserConfirmedWorkout].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.start > $1.start }
    }

    private func saveConfirmedWorkouts(_ workouts: [UserConfirmedWorkout]) {
        let sorted = workouts.sorted(by: { $0.start > $1.start })
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        UserDefaults.standard.set(data, forKey: ConfirmedWorkoutDefaults.key)
        cachedConfirmedWorkouts = sorted
    }

    private func confirmedWorkoutID(start: Date, end: Date, source: String) -> String {
        let startSeconds = Int(start.timeIntervalSince1970.rounded())
        let endSeconds = Int(end.timeIntervalSince1970.rounded())
        return "\(startSeconds)-\(endSeconds)-\(source)"
    }

    func confirmBestSleepCandidateForUI(rest: Int, source: String = "ui") -> UserConfirmedSleep? {
        confirmBestSleepCandidate(rest: rest, source: source)
    }

    func confirmBestSleepCandidateFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-confirm-best-sleep-candidate") else { return }
        let rest = baseline.restingInt ?? 60
        _ = confirmBestSleepCandidate(rest: rest, source: "launch_arg")
    }

    private func confirmBestSleepCandidate(rest: Int, source: String) -> UserConfirmedSleep? {
        guard let best = aggregateSleepCandidates(rest: rest, calendar: .current).first else {
            WHOOPDebugLog("WHOOPDBG sleep_confirm status=learning reason=no_confirmable_candidate source=%@ rest_hr=%d metric_promotions=0 auto_gate_e_unchanged=1",
                  source,
                  rest)
            return nil
        }
        let confirmable = best.duration >= AggregateSleepCandidate.fragmentedMinimumDuration
            && best.span >= AggregateSleepCandidate.fragmentedMinimumSpan
        guard confirmable else {
            WHOOPDebugLog("WHOOPDBG sleep_confirm status=learning reason=candidate_too_short source=%@ duration_s=%.0f span_s=%.0f sessions=%d metric_promotions=0 auto_gate_e_unchanged=1",
                  source,
                  best.duration,
                  best.span,
                  best.sessions)
            return nil
        }
        var existing = cachedConfirmedSleeps
        let id = confirmedSleepID(start: best.start, end: best.end, source: best.sessions > 1 ? "aggregate_sleep" : "sleep_window")
        if let already = existing.first(where: { $0.id == id }) {
            WHOOPDebugLog("WHOOPDBG sleep_confirm status=already_confirmed id=%@ source=%@ candidate_source=%@ start=%@ end=%@ confidence=%@ motion_source=%@ motion_validated=%d metric_promotions=0 auto_gate_e_unchanged=1",
                  already.id,
                  source,
                  already.source,
                  isoString(already.start),
                  isoString(already.end),
                  already.confidence,
                  already.motionSource,
                  already.motionValidated ? 1 : 0)
            return already
        }
        let candidateSource = best.sessions > 1 ? "aggregate_sleep" : "sleep_window"
        let confidence = best.motionEvidenceValidated ? "user_confirmed_motion_validated" : "user_confirmed_hr_only"
        let confirmed = UserConfirmedSleep(id: id,
                                           createdAt: Date(),
                                           start: best.start,
                                           end: best.end,
                                           source: candidateSource,
                                           confidence: confidence,
                                           sessions: best.sessions,
                                           samples: best.samples,
                                           avgHR: best.avgHR,
                                           peakHR: best.peakHR,
                                           restingHR: best.restingHR,
                                           duration: best.duration,
                                           span: best.span,
                                           reason: best.reason,
                                           motionSource: best.motionEvidenceSource,
                                           motionValidated: best.motionEvidenceValidated)
        existing.append(confirmed)
        saveConfirmedSleeps(existing)
        WHOOPDebugLog("WHOOPDBG sleep_confirm status=confirmed id=%@ source=%@ candidate_source=%@ start=%@ end=%@ duration_s=%.0f span_s=%.0f sessions=%d samples=%d avg_hr=%d peak_hr=%d rest_hr=%d sleep_rhr=%d confidence=%@ motion_source=%@ motion_validated=%d reason=%@ metric_promotions=0 auto_gate_e_unchanged=1 healthkit_source=none local_only=1",
              confirmed.id,
              source,
              confirmed.source,
              isoString(confirmed.start),
              isoString(confirmed.end),
              confirmed.duration,
              confirmed.span,
              confirmed.sessions,
              confirmed.samples,
              confirmed.avgHR,
              confirmed.peakHR,
              rest,
              confirmed.restingHR,
              confirmed.confidence,
              confirmed.motionSource,
              confirmed.motionValidated ? 1 : 0,
              confirmed.reason)
        return confirmed
    }

    private static func readConfirmedSleeps() -> [UserConfirmedSleep] {
        guard let data = UserDefaults.standard.data(forKey: ConfirmedSleepDefaults.key),
              let decoded = try? JSONDecoder().decode([UserConfirmedSleep].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.start > $1.start }
    }

    private func saveConfirmedSleeps(_ sleeps: [UserConfirmedSleep]) {
        let sorted = sleeps.sorted(by: { $0.start > $1.start })
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        UserDefaults.standard.set(data, forKey: ConfirmedSleepDefaults.key)
        cachedConfirmedSleeps = sorted
    }

    func behaviorJournalEntry(for day: Date = Date(), calendar: Calendar = .current) -> BehaviorJournalEntry {
        let start = calendar.startOfDay(for: day)
        if let entry = cachedBehaviorJournalEntries.first(where: { calendar.isDate($0.day, inSameDayAs: start) }) {
            return entry
        }
        return BehaviorJournalEntry(id: behaviorJournalID(for: start),
                                    day: start,
                                    createdAt: Date(),
                                    tags: [])
    }

    func toggleBehaviorTag(_ tag: BehaviorJournalEntry.Tag, day: Date = Date(), calendar: Calendar = .current) {
        var entry = behaviorJournalEntry(for: day, calendar: calendar)
        if entry.tags.contains(tag) {
            entry.tags.removeAll { $0 == tag }
        } else {
            entry.tags.append(tag)
        }
        entry.tags.sort { $0.rawValue < $1.rawValue }

        var entries = cachedBehaviorJournalEntries.filter { !calendar.isDate($0.day, inSameDayAs: entry.day) }
        if !entry.tags.isEmpty {
            entries.append(entry)
        }
        saveBehaviorJournalEntries(entries)
        dashboardRevision += 1
        WHOOPDebugLog("WHOOPDBG behavior_journal status=updated day=%@ tag=%@ active=%d tags=%@ local_only=1",
              isoString(entry.day),
              tag.rawValue,
              entry.tags.contains(tag) ? 1 : 0,
              entry.tags.map(\.rawValue).joined(separator: ","))
    }

    func behaviorCorrelationSummaries(rest: Int,
                                      maxHR: Int,
                                      calendar: Calendar = .current) -> [BehaviorCorrelationSummary] {
        let rollupsByDay = Dictionary(uniqueKeysWithValues: dailyRollups(rest: rest, maxHR: maxHR, calendar: calendar).map {
            (calendar.startOfDay(for: $0.day), $0)
        })
        guard !rollupsByDay.isEmpty else {
            return BehaviorJournalEntry.Tag.allCases.map {
                BehaviorCorrelationSummary(tag: $0, days: 0, recoveryDelta: nil, hrvDelta: nil)
            }
        }
        let allRecovery = averageDouble(rollupsByDay.values.map(\.strain).map { max(0, 100 - $0 * 4) })
        let allHRV = averageDouble(rollupsByDay.values.compactMap { $0.avgHRV.map(Double.init) })

        return BehaviorJournalEntry.Tag.allCases.map { tag in
            let taggedRollups = cachedBehaviorJournalEntries.compactMap { entry -> DailyRollup? in
                guard entry.tags.contains(tag) else { return nil }
                return rollupsByDay[calendar.startOfDay(for: entry.day)]
            }
            let taggedRecovery = averageDouble(taggedRollups.map(\.strain).map { max(0, 100 - $0 * 4) })
            let taggedHRV = averageDouble(taggedRollups.compactMap { $0.avgHRV.map(Double.init) })
            let recoveryDelta: Double?
            if taggedRollups.count >= 3, let taggedRecovery, let allRecovery {
                recoveryDelta = taggedRecovery - allRecovery
            } else {
                recoveryDelta = nil
            }
            let hrvDelta: Double?
            if taggedRollups.count >= 3, let taggedHRV, let allHRV {
                hrvDelta = taggedHRV - allHRV
            } else {
                hrvDelta = nil
            }
            return BehaviorCorrelationSummary(tag: tag,
                                              days: taggedRollups.count,
                                              recoveryDelta: recoveryDelta,
                                              hrvDelta: hrvDelta)
        }
    }

    private static func readBehaviorJournalEntries() -> [BehaviorJournalEntry] {
        guard let data = UserDefaults.standard.data(forKey: BehaviorJournalDefaults.key),
              let decoded = try? JSONDecoder().decode([BehaviorJournalEntry].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.day > $1.day }
    }

    private func saveBehaviorJournalEntries(_ entries: [BehaviorJournalEntry]) {
        let sorted = entries.sorted(by: { $0.day > $1.day })
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        UserDefaults.standard.set(data, forKey: BehaviorJournalDefaults.key)
        cachedBehaviorJournalEntries = sorted
    }

    private func behaviorJournalID(for day: Date) -> String {
        "\(Int(day.timeIntervalSince1970.rounded()))-behavior"
    }

    private func confirmedSleepID(start: Date, end: Date, source: String) -> String {
        let startSeconds = Int(start.timeIntervalSince1970.rounded())
        let endSeconds = Int(end.timeIntervalSince1970.rounded())
        return "\(startSeconds)-\(endSeconds)-\(source)"
    }

    private func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    func historicalGapRepairStatus(rest: Int, maxHR: Int) -> HistoricalGapRepairSummary {
        historicalGapRepairSummary(workoutReplay: replaySavedWorkoutReadiness(rest: rest, maxHR: maxHR),
                                   archive: HistoricalArchive.diagnostics())
    }

    private func logWorkoutThresholdSensitivity(rest: Int, maxHR: Int) {
        let fractions = [0.35, 0.40, 0.45, 0.50]
        var readyFractions: [String] = []
        for fraction in fractions {
            let summary = replaySavedWorkoutReadiness(rest: rest, maxHR: maxHR, thresholdFraction: fraction)
            let fractionPercent = Int((fraction * 100).rounded())
            if summary.readySessions > 0 {
                readyFractions.append("hrr\(fractionPercent)")
            }
            WHOOPDebugLog("WHOOPDBG workout_threshold_sensitivity hrr_percent=%d rest_hr=%d max_hr=%d threshold_hr=%d ready=%d ready_candidates=%d best_source=%@ best_chunks=%d best_label=%@ status=%@ reason=%@ primary_blocker=%@ stream_coverage_percent=%d duration_s=%.0f observed_duration_s=%.0f dropped_gap_s=%.0f max_gap_s=%.1f samples=%d peak_hr=%d threshold_gap_bpm=%d elevated_s=%.0f required_elevated_s=%.0f longest_bout_s=%.0f required_bout_s=%.0f borderline_threshold_hr=%d borderline_elevated_s=%.0f borderline_longest_bout_s=%.0f diagnostic_only=1 detector_threshold_hrr50_unchanged=1",
                  fractionPercent,
                  rest,
                  maxHR,
                  summary.bestThresholdHR,
                  summary.readySessions > 0 ? 1 : 0,
                  summary.readySessions,
                  summary.bestSource,
                  summary.bestChunkCount,
                  summary.bestLabel,
                  summary.bestStatus,
                  summary.bestReason,
                  summary.bestPrimaryBlocker,
                  summary.bestStreamCoveragePercent,
                  summary.bestDuration,
                  summary.bestObservedDuration,
                  summary.bestDroppedGapSeconds,
                  summary.bestMaxSampleGap,
                  summary.bestSamples,
                  summary.bestPeakHR,
                  summary.bestThresholdGapBPM,
                  summary.bestElevatedSeconds,
                  summary.bestRequiredElevatedSeconds,
                  summary.bestLongestBout,
                  summary.bestRequiredBout,
                  summary.bestBorderlineThresholdHR,
                  summary.bestBorderlineElevatedSeconds,
                  summary.bestBorderlineLongestBout)
        }
        WHOOPDebugLog("WHOOPDBG workout_threshold_sensitivity_summary fractions=%@ ready_fractions=%@ diagnostic_only=1 detector_threshold_hrr50_unchanged=1",
              fractions.map { "hrr\(Int(($0 * 100).rounded()))" }.joined(separator: ","),
              readyFractions.isEmpty ? "none" : readyFractions.joined(separator: ","))
    }

    private func replaySavedWorkoutReadiness(rest: Int,
                                             maxHR: Int,
                                             thresholdFraction: Double = 0.50,
                                             limitSessions: Int? = nil,
                                             includeAggregates: Bool = true,
                                             includeActiveJournal: Bool = false) -> WorkoutReplaySummary {
        var best = WorkoutReplaySummary.empty(rest: rest, maxHR: maxHR)
        var replaySessions = canonicalSessions(includeActiveJournal: includeActiveJournal)
        let rawSessions = sessions.count + (includeActiveJournal && activeJournalSessionIfFresh() != nil ? 1 : 0)
        if let limitSessions {
            replaySessions.sort {
                if $0.points.count != $1.points.count {
                    return $0.points.count > $1.points.count
                }
                if $0.duration != $1.duration {
                    return $0.duration > $1.duration
                }
                return $0.end > $1.end
            }
            replaySessions = Array(replaySessions.prefix(max(1, limitSessions)))
        }
        let aggregateCandidates = includeAggregates
            ? aggregateWorkoutCandidates(rest: rest, maxHR: maxHR, calendar: Calendar.current, thresholdFraction: thresholdFraction)
            : []
        let readySessions = replaySessions.filter { $0.workoutReadiness(rest: rest, maxHR: maxHR, thresholdFraction: thresholdFraction).ready }.count
            + aggregateCandidates.filter { $0.readiness.ready }.count
        let evaluated = replaySessions.count + aggregateCandidates.count
        for session in replaySessions {
            let readiness = session.workoutReadiness(rest: rest, maxHR: maxHR, thresholdFraction: thresholdFraction)
            let candidate = WorkoutReplaySummary(rawSessions: rawSessions,
                                                 canonicalSessions: replaySessions.count,
                                                 sessionsEvaluated: evaluated,
                                                 readySessions: readySessions,
                                                 bestSource: "single_session",
                                                 bestChunkCount: 1,
                                                 bestStart: session.start,
                                                 bestEnd: session.end,
                                                 bestSpan: session.duration,
                                                 bestLabel: session.label,
                                                 bestStatus: readiness.status,
                                                 bestReason: readiness.reason,
                                                 bestDuration: readiness.duration,
                                                 bestObservedDuration: readiness.observedDuration,
                                                 bestSamples: session.points.count,
                                                 bestAvgHR: readiness.avgHR,
                                                 bestPeakHR: readiness.peakHR,
                                                 bestP95HR: readiness.p95HR,
                                                 bestP99HR: readiness.p99HR,
                                                 bestThresholdHR: readiness.thresholdHR,
                                                 bestThresholdGapBPM: readiness.thresholdGapBPM,
                                                 bestSamplesAboveThreshold: readiness.samplesAboveThreshold,
                                                 bestSamplesAboveBorderline: readiness.samplesAboveBorderline,
                                                 bestElevatedSeconds: readiness.elevatedSeconds,
                                                 bestRequiredElevatedSeconds: readiness.requiredElevatedSeconds,
                                                 bestLongestBout: readiness.longestElevatedBout,
                                                 bestRequiredBout: readiness.requiredElevatedBout,
                                                 bestElevatedFraction: readiness.elevatedFraction,
                                                 bestBorderlineThresholdHR: readiness.borderlineThresholdHR,
                                                 bestBorderlineElevatedSeconds: readiness.borderlineElevatedSeconds,
                                                 bestBorderlineLongestBout: readiness.borderlineLongestBout,
                                                 bestDroppedGapSeconds: readiness.droppedGapSeconds,
                                                 bestMaxSampleGap: readiness.maxSampleGap,
                                                 bestGapCount: readiness.gapCount,
                                                 bestStreamCoveragePercent: readiness.streamCoveragePercent,
                                                 bestPrimaryBlocker: readiness.primaryBlocker,
                                                 bestHRRaw2A37: session.hrRaw2A37Value,
                                                 bestHRAccepted: session.hrAcceptedValue,
                                                 bestHRZero: session.hrZeroValue,
                                                 bestHRArtifactHeld: session.hrArtifactHeldValue,
                                                 bestHRArtifactDropped: session.hrArtifactDroppedValue,
                                                 bestHRRawGaps: session.hrRawGapsValue,
                                                 bestHRAcceptedGaps: session.hrAcceptedGapsValue,
                                                 bestHRMaxRawGap: session.hrMaxRawGapValue,
                                                 bestHRMaxAcceptedGap: session.hrMaxAcceptedGapValue,
                                                 restHR: rest,
                                                 maxHR: maxHR)
            if isBetterWorkoutReplaySummary(candidate, than: best) {
                best = candidate
            }
        }
        for aggregate in aggregateCandidates {
            let readiness = aggregate.readiness
            let candidate = WorkoutReplaySummary(rawSessions: rawSessions,
                                                 canonicalSessions: replaySessions.count,
                                                 sessionsEvaluated: evaluated,
                                                 readySessions: readySessions,
                                                 bestSource: aggregate.source,
                                                 bestChunkCount: aggregate.sessions,
                                                 bestStart: aggregate.start,
                                                 bestEnd: aggregate.end,
                                                 bestSpan: aggregate.span,
                                                 bestLabel: aggregate.label,
                                                 bestStatus: readiness.status,
                                                 bestReason: readiness.reason,
                                                 bestDuration: readiness.duration,
                                                 bestObservedDuration: readiness.observedDuration,
                                                 bestSamples: aggregate.samples,
                                                 bestAvgHR: readiness.avgHR,
                                                 bestPeakHR: readiness.peakHR,
                                                 bestP95HR: readiness.p95HR,
                                                 bestP99HR: readiness.p99HR,
                                                 bestThresholdHR: readiness.thresholdHR,
                                                 bestThresholdGapBPM: readiness.thresholdGapBPM,
                                                 bestSamplesAboveThreshold: readiness.samplesAboveThreshold,
                                                 bestSamplesAboveBorderline: readiness.samplesAboveBorderline,
                                                 bestElevatedSeconds: readiness.elevatedSeconds,
                                                 bestRequiredElevatedSeconds: readiness.requiredElevatedSeconds,
                                                 bestLongestBout: readiness.longestElevatedBout,
                                                 bestRequiredBout: readiness.requiredElevatedBout,
                                                 bestElevatedFraction: readiness.elevatedFraction,
                                                 bestBorderlineThresholdHR: readiness.borderlineThresholdHR,
                                                 bestBorderlineElevatedSeconds: readiness.borderlineElevatedSeconds,
                                                 bestBorderlineLongestBout: readiness.borderlineLongestBout,
                                                 bestDroppedGapSeconds: readiness.droppedGapSeconds,
                                                 bestMaxSampleGap: readiness.maxSampleGap,
                                                 bestGapCount: readiness.gapCount,
                                                 bestStreamCoveragePercent: readiness.streamCoveragePercent,
                                                 bestPrimaryBlocker: readiness.primaryBlocker,
                                                 bestHRRaw2A37: aggregate.hrRaw2A37,
                                                 bestHRAccepted: aggregate.hrAccepted,
                                                 bestHRZero: aggregate.hrZero,
                                                 bestHRArtifactHeld: aggregate.hrArtifactHeld,
                                                 bestHRArtifactDropped: aggregate.hrArtifactDropped,
                                                 bestHRRawGaps: aggregate.hrRawGaps,
                                                 bestHRAcceptedGaps: aggregate.hrAcceptedGaps,
                                                 bestHRMaxRawGap: aggregate.hrMaxRawGap,
                                                 bestHRMaxAcceptedGap: aggregate.hrMaxAcceptedGap,
                                                 restHR: rest,
                                                 maxHR: maxHR)
            if isBetterWorkoutReplaySummary(candidate, than: best) {
                best = candidate
            }
        }
        if replaySessions.isEmpty && aggregateCandidates.isEmpty {
            return .empty(rest: rest, maxHR: maxHR)
        }
        return best
    }

    private func isBetterWorkoutReplaySummary(_ lhs: WorkoutReplaySummary, than rhs: WorkoutReplaySummary) -> Bool {
        if rhs.sessionsEvaluated == 0 { return true }
        if lhs.bestStatus != rhs.bestStatus { return lhs.bestStatus == "ready" }
        if lhs.nearMiss != rhs.nearMiss { return lhs.nearMiss }
        let lhsLongEnough = lhs.bestObservedDuration >= 10 * 60
        let rhsLongEnough = rhs.bestObservedDuration >= 10 * 60
        if lhsLongEnough != rhsLongEnough { return lhsLongEnough }
        let lhsHasElevatedEvidence = lhs.bestElevatedSeconds > 0 || lhs.bestPeakHR >= lhs.bestThresholdHR
        let rhsHasElevatedEvidence = rhs.bestElevatedSeconds > 0 || rhs.bestPeakHR >= rhs.bestThresholdHR
        if lhsHasElevatedEvidence != rhsHasElevatedEvidence { return lhsHasElevatedEvidence }
        if lhs.bestLongestBout != rhs.bestLongestBout {
            return lhs.bestLongestBout > rhs.bestLongestBout
        }
        if lhs.bestElevatedSeconds != rhs.bestElevatedSeconds {
            return lhs.bestElevatedSeconds > rhs.bestElevatedSeconds
        }
        if lhs.bestBorderlineLongestBout != rhs.bestBorderlineLongestBout {
            return lhs.bestBorderlineLongestBout > rhs.bestBorderlineLongestBout
        }
        if lhs.bestBorderlineElevatedSeconds != rhs.bestBorderlineElevatedSeconds {
            return lhs.bestBorderlineElevatedSeconds > rhs.bestBorderlineElevatedSeconds
        }
        if lhs.bestPeakHR != rhs.bestPeakHR {
            return lhs.bestPeakHR > rhs.bestPeakHR
        }
        if lhs.bestStreamCoveragePercent != rhs.bestStreamCoveragePercent {
            return lhs.bestStreamCoveragePercent > rhs.bestStreamCoveragePercent
        }
        if lhs.bestObservedDuration != rhs.bestObservedDuration {
            return lhs.bestObservedDuration > rhs.bestObservedDuration
        }
        return lhs.bestMaxSampleGap < rhs.bestMaxSampleGap
    }

    private func latestBackupMatchesCurrentStore(_ latest: URL) -> Bool {
        guard let data = try? Data(contentsOf: latest) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(SessionBackupEnvelope.self, from: data),
              envelope.schema == 1,
              envelope.sessions.count == sessions.count else {
            return false
        }
        let backupDigest = backupContentDigest(sessions: envelope.sessions,
                                               baseline: envelope.baseline,
                                               profile: envelope.profile)
        let currentDigest = backupContentDigest(sessions: sessions,
                                                baseline: baseline,
                                                profile: profile)
        return backupDigest != nil && backupDigest == currentDigest
    }

    private nonisolated static func computeSessionBackupStatus(currentSessions: [SavedSession],
                                                               baseline: PersonalBaseline,
                                                               profile: AthleteProfile,
                                                               sessionFileURL: URL) -> SessionBackupStatus {
        guard let latest = latestSessionBackupURL(sessionFileURL: sessionFileURL,
                                                  includeSafetyBackups: false) else {
            return .missing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rrSamples = { (sessions: [SavedSession]) in
            sessions.reduce(0) { $0 + ($1.rrPoints?.count ?? 0) }
        }
        do {
            let data = try Data(contentsOf: latest)
            let envelope = try decoder.decode(SessionBackupEnvelope.self, from: data)
            guard envelope.schema == 1 else {
                return SessionBackupStatus(available: true,
                                           current: false,
                                           path: backupRelativePath(for: latest),
                                           sessions: envelope.sessions.count,
                                           rrSamples: rrSamples(envelope.sessions),
                                           bytes: data.count,
                                           reason: "unsupported_schema_\(envelope.schema)")
            }
            let current = latestBackupMatchesCurrentStore(latest,
                                                          currentSessions: currentSessions,
                                                          baseline: baseline,
                                                          profile: profile)
            return SessionBackupStatus(available: true,
                                       current: current,
                                       path: backupRelativePath(for: latest),
                                       sessions: envelope.sessions.count,
                                       rrSamples: rrSamples(envelope.sessions),
                                       bytes: data.count,
                                       reason: current ? "current" : "digest_mismatch")
        } catch {
            return SessionBackupStatus(available: true,
                                       current: false,
                                       path: backupRelativePath(for: latest),
                                       sessions: 0,
                                       rrSamples: 0,
                                       bytes: 0,
                                       reason: "decode_error")
        }
    }

    private nonisolated static func latestBackupMatchesCurrentStore(_ latest: URL,
                                                                    currentSessions: [SavedSession],
                                                                    baseline: PersonalBaseline,
                                                                    profile: AthleteProfile) -> Bool {
        guard let data = try? Data(contentsOf: latest) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(SessionBackupEnvelope.self, from: data),
              envelope.schema == 1,
              envelope.sessions.count == currentSessions.count else {
            return false
        }
        let backupDigest = makeBackupContentDigest(sessions: envelope.sessions,
                                                   baseline: envelope.baseline,
                                                   profile: envelope.profile)
        let currentDigest = makeBackupContentDigest(sessions: currentSessions,
                                                    baseline: baseline,
                                                    profile: profile)
        return backupDigest != nil && backupDigest == currentDigest
    }

    private nonisolated static func latestSessionBackupURL(sessionFileURL: URL,
                                                           includeSafetyBackups: Bool) -> URL? {
        var allFiles: [URL] = []
        for backupDir in sessionBackupDirectoriesForReading(sessionFileURL: sessionFileURL) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: backupDir,
                                                                           includingPropertiesForKeys: nil,
                                                                           options: [.skipsHiddenFiles])
                .filter({
                    $0.pathExtension == "json"
                        && (includeSafetyBackups || !$0.deletingPathExtension().lastPathComponent.hasSuffix("-pre-restore"))
                }) else {
                continue
            }
            allFiles.append(contentsOf: files)
        }
        return allFiles.max { backupSortDate($0) < backupSortDate($1) }
    }

    private nonisolated static func sessionBackupDirectoriesForReading(sessionFileURL: URL) -> [URL] {
        let documentsURL = sessionFileURL.deletingLastPathComponent()
        return [
            documentsURL.appendingPathComponent("atria-backups"),
            documentsURL.appendingPathComponent("whoop-backups")
        ]
    }

    private nonisolated static func backupRelativePath(for backupURL: URL) -> String {
        let directory = backupURL.deletingLastPathComponent().lastPathComponent
        return "Documents/\(directory)/\(backupURL.lastPathComponent)"
    }

    private nonisolated static func backupSortDate(_ backupURL: URL) -> Date {
        if let date = (try? FileManager.default.attributesOfItem(atPath: backupURL.path)[.modificationDate]) as? Date {
            return date
        }
        return .distantPast
    }

    func sessionBackupStatus() -> SessionBackupStatus {
        cachedSessionBackupStatus
    }

    private func computeSessionBackupStatus() -> SessionBackupStatus {
        guard let latest = latestSessionBackupURL() else {
            return .missing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: latest)
            let envelope = try decoder.decode(SessionBackupEnvelope.self, from: data)
            guard envelope.schema == 1 else {
                return SessionBackupStatus(available: true,
                                           current: false,
                                           path: backupRelativePath(for: latest),
                                           sessions: envelope.sessions.count,
                                           rrSamples: totalRRSamples(in: envelope.sessions),
                                           bytes: data.count,
                                           reason: "unsupported_schema_\(envelope.schema)")
            }
            let current = latestBackupMatchesCurrentStore(latest)
            return SessionBackupStatus(available: true,
                                       current: current,
                                       path: backupRelativePath(for: latest),
                                       sessions: envelope.sessions.count,
                                       rrSamples: totalRRSamples(in: envelope.sessions),
                                       bytes: data.count,
                                       reason: current ? "current" : "digest_mismatch")
        } catch {
            return SessionBackupStatus(available: true,
                                       current: false,
                                       path: backupRelativePath(for: latest),
                                       sessions: 0,
                                       rrSamples: 0,
                                       bytes: 0,
                                       reason: "decode_error")
        }
    }

    func logActivityDetectionsFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-log-activity-detections") else { return }
        let detections = detectedActivities(rest: baseline.restingInt ?? 60, maxHR: profile.maxHR)
        let maxRows = 12
        let kindCounts = Dictionary(grouping: detections, by: \.kind).mapValues(\.count)
        let rankedDetections = detections.sorted { lhs, rhs in
            if confidenceRank(lhs.confidence) != confidenceRank(rhs.confidence) {
                return confidenceRank(lhs.confidence) > confidenceRank(rhs.confidence)
            }
            if kindRank(lhs.kind) != kindRank(rhs.kind) {
                return kindRank(lhs.kind) > kindRank(rhs.kind)
            }
            if lhs.duration != rhs.duration {
                return lhs.duration > rhs.duration
            }
            return lhs.peakHR > rhs.peakHR
        }
        WHOOPDebugLog("WHOOPDBG activity_detect_summary sessions=%d detections=%d emitted=%d suppressed=%d workouts=%d activity_candidates=%d sleep_candidates=%d rest_candidates=%d rest_hr=%d max_hr=%d",
              sessions.count,
              detections.count,
              min(maxRows, detections.count),
              max(0, detections.count - maxRows),
              kindCounts[.workout, default: 0],
              kindCounts[.activityCandidate, default: 0],
              kindCounts[.sleepCandidate, default: 0],
              kindCounts[.restCandidate, default: 0],
              baseline.restingInt ?? 60,
              profile.maxHR)
        for detection in rankedDetections.prefix(maxRows) {
            WHOOPDebugLog("WHOOPDBG activity_detect kind=%@ confidence=%@ duration_s=%.0f avg_hr=%d peak_hr=%d reason=%@",
                  detection.kind.rawValue,
                  detection.confidence.rawValue,
                  detection.duration,
                  detection.avgHR,
                  detection.peakHR,
                  detection.reason)
        }
    }

    private func kindRank(_ kind: ActivityDetection.Kind) -> Int {
        switch kind {
        case .workout: return 4
        case .sleepCandidate: return 3
        case .activityCandidate: return 2
        case .restCandidate: return 1
        }
    }

    private func confidenceRank(_ confidence: ActivityDetection.Confidence) -> Int {
        switch confidence {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }

    func logWorkoutPreflightFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-log-workout-preflight") else { return }
        let rest = baseline.restingInt ?? 60
        let maxHR = profile.maxHR
        let reserve = max(0, maxHR - rest)
        let hrr50Threshold = SavedSession.workoutElevatedThreshold(rest: rest, maxHR: maxHR)
        let elevatedThreshold = hrr50Threshold
        let minDuration = 10 * 60
        let minElevated = min(max(Double(minDuration) * 0.35, 5 * 60), 20 * 60)
        let minBout = min(max(Double(minDuration) * 0.20, 3 * 60), 8 * 60)
        WHOOPDebugLog("WHOOPDBG workout_preflight rest_hr=%d max_hr=%d reserve_hr=%d threshold_hr=%d hrr50_hr=%d threshold_method=hrr50 min_duration_s=%d min_elevated_s=%.0f min_bout_s=%.0f elevated_rule=max(duration*0.35,5m)_cap20m bout_rule=max(duration*0.20,3m)_cap8m saved_sessions=%d",
              rest,
              maxHR,
              reserve,
              elevatedThreshold,
              hrr50Threshold,
              minDuration,
              minElevated,
              minBout,
              sessions.count)
    }

    func logStrainValidationFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-log-strain-validation") else { return }
        let rest = baseline.restingInt ?? 60
        logStrainValidation(strainValidationSummary(rest: rest, maxHR: profile.maxHR))
    }

    func strainValidationStatus(rest: Int, maxHR: Int) -> StrainValidationSummary {
        strainValidationSummary(rest: rest, maxHR: maxHR)
    }

    private func logStrainValidation(_ summary: StrainValidationSummary) {
        WHOOPDebugLog("WHOOPDBG strain_validation ready=%d rest_to_max_ready=%d primary_blocker=%@ external_hr_reference_validated=%d days=%d sessions=%d best_day=%@ best_day_sessions=%d rest_hr=%d max_hr=%d reserve_hr=%d samples=%d total_s=%.0f dropped_gap_s=%.0f stream_coverage_percent=%d z0_lt30_s=%.0f z1_30_50_s=%.0f z2_50_70_s=%.0f z3_70_85_s=%.0f z4_85_100_s=%.0f high_z3_z4_s=%.0f min_hrr=%.2f max_hrr=%.2f max_hrr_percent=%d trimp=%.2f strain=%.2f criteria=total>=600_low_z0>=60_high_z3_z4>=60_max_hrr>=0.85_stream_coverage>=75_external_hr_reference_required source=saved_sessions_grouped_by_day_no_hr_estimation",
              summary.ready ? 1 : 0,
              summary.restToMaxReady ? 1 : 0,
              summary.primaryBlocker,
              summary.externalHRReferenceValidated ? 1 : 0,
              summary.daysEvaluated,
              summary.sessionsEvaluated,
              formatDate(summary.bestDay),
              summary.bestSessions,
              summary.restHR,
              summary.maxHR,
              summary.reserveHR,
              summary.samples,
              summary.totalSeconds,
              summary.droppedGapSeconds,
              summary.streamCoveragePercent,
              summary.secondsZ0,
              summary.secondsZ1,
              summary.secondsZ2,
              summary.secondsZ3,
              summary.secondsZ4,
              summary.highZoneSeconds,
              summary.minHRReserve,
              summary.maxHRReserve,
              Int((summary.maxHRReserve * 100).rounded()),
              summary.trimp,
              summary.strain)
    }

    private func strainValidationSummary(rest: Int, maxHR: Int,
                                         calendar: Calendar = .current) -> StrainValidationSummary {
        let eligible = sessions.filter { !$0.points.isEmpty }
        guard !eligible.isEmpty, maxHR > rest else {
            return .empty(rest: rest, maxHR: maxHR, sessions: sessions.count)
        }

        let grouped = Dictionary(grouping: eligible) { session in
            calendar.startOfDay(for: session.start)
        }
        let summaries = grouped.map { day, daySessions -> StrainValidationSummary in
            let zones = daySessions.reduce(Metrics.StrainZoneSummary.empty) { partial, session in
                partial + Metrics.strainZoneSummary(session.points.map { (t: $0.t, bpm: $0.bpm) },
                                                    rest: rest,
                                                    max: maxHR)
            }
            let trimp = daySessions.reduce(0.0) { $0 + $1.trimp(rest: rest, max: maxHR) }
            let totalWithGaps = zones.totalSeconds + zones.droppedGapSeconds
            let streamCoverage = totalWithGaps > 0
                ? min(100, max(0, Int(((zones.totalSeconds / totalWithGaps) * 100).rounded())))
                : 0
            let restToMaxReady = zones.totalSeconds >= 10 * 60
                && zones.secondsZ0 >= 60
                && zones.secondsZ3 + zones.secondsZ4 >= 60
                && zones.maxHRReserve >= 0.85
                && streamCoverage >= 75
            let healthReference = HealthKitExporter.diagnostics(for: daySessions,
                                                                rest: rest,
                                                                maxHR: maxHR).referenceAudit
            let externalValidated = externalHRReferenceValidated || healthReference.externalReferenceReady
            let blocker = strainValidationBlocker(zones: zones,
                                                  streamCoveragePercent: streamCoverage,
                                                  restToMaxReady: restToMaxReady,
                                                  externalHRReferenceValidated: externalValidated)
            return StrainValidationSummary(daysEvaluated: grouped.count,
                                           sessionsEvaluated: eligible.count,
                                           bestDay: day,
                                           bestSessions: daySessions.count,
                                           restHR: rest,
                                           maxHR: maxHR,
                                           reserveHR: max(0, maxHR - rest),
                                           samples: daySessions.reduce(0) { $0 + $1.points.count },
                                           totalSeconds: zones.totalSeconds,
                                           droppedGapSeconds: zones.droppedGapSeconds,
                                           streamCoveragePercent: streamCoverage,
                                           secondsZ0: zones.secondsZ0,
                                           secondsZ1: zones.secondsZ1,
                                           secondsZ2: zones.secondsZ2,
                                           secondsZ3: zones.secondsZ3,
                                           secondsZ4: zones.secondsZ4,
                                           minHRReserve: zones.minHRReserve,
                                           maxHRReserve: zones.maxHRReserve,
                                           trimp: trimp,
                                           strain: Metrics.strain(fromTRIMP: trimp),
                                           restToMaxReady: restToMaxReady,
                                           externalHRReferenceValidated: externalValidated,
                                           ready: restToMaxReady && externalValidated,
                                           primaryBlocker: blocker)
        }
        return summaries.max(by: isBetterStrainValidationSummary) ?? .empty(rest: rest, maxHR: maxHR, sessions: sessions.count)
    }

    private func strainValidationBlocker(zones: Metrics.StrainZoneSummary,
                                         streamCoveragePercent: Int,
                                         restToMaxReady: Bool,
                                         externalHRReferenceValidated: Bool) -> String {
        if zones.samples == 0 { return "no_saved_hr_sessions" }
        var blockers: [String] = []
        if zones.totalSeconds < 10 * 60 { blockers.append("duration_below_10m") }
        if streamCoveragePercent < 75 { blockers.append("stream_coverage_below_75_percent") }
        if zones.secondsZ0 < 60 { blockers.append("missing_rest_zone_exposure") }
        if zones.secondsZ3 + zones.secondsZ4 < 60 { blockers.append("missing_high_zone_exposure") }
        if zones.maxHRReserve < 0.85 { blockers.append("max_hrr_below_85_percent") }
        if !restToMaxReady && blockers.isEmpty { blockers.append("rest_to_max_validation_missing") }
        if !externalHRReferenceValidated { blockers.append("external_hr_reference_missing") }
        return blockers.isEmpty ? "none" : blockers.joined(separator: "+")
    }

    private func isBetterStrainValidationSummary(_ lhs: StrainValidationSummary,
                                                 _ rhs: StrainValidationSummary) -> Bool {
        if lhs.restToMaxReady != rhs.restToMaxReady { return !lhs.restToMaxReady && rhs.restToMaxReady }
        if lhs.highZoneSeconds != rhs.highZoneSeconds { return lhs.highZoneSeconds < rhs.highZoneSeconds }
        if lhs.maxHRReserve != rhs.maxHRReserve { return lhs.maxHRReserve < rhs.maxHRReserve }
        if lhs.totalSeconds != rhs.totalSeconds { return lhs.totalSeconds < rhs.totalSeconds }
        return lhs.droppedGapSeconds > rhs.droppedGapSeconds
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "none" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Sum of today's saved sessions' TRIMP — combine with the live session to
    /// get day strain (strain accumulates across the whole day, like WHOOP).
    func todayTRIMP(rest: Int, max: Int) -> Double {
        let cal = Calendar.current
        return canonicalSessions().filter { cal.isDateInToday($0.start) }
            .reduce(0) { $0 + $1.trimp(rest: rest, max: max) }
    }

    func detectedActivities(rest: Int, maxHR: Int) -> [ActivityDetection] {
        let replaySessions = canonicalSessions()
        let single = replaySessions.compactMap { $0.detectedActivity(rest: rest, maxHR: maxHR) }
        let aggregateWorkouts = aggregateWorkoutCandidates(rest: rest, maxHR: maxHR, calendar: Calendar.current)
            .filter { $0.readiness.ready || $0.readiness.nearMiss || $0.readiness.strengthCandidate }
            .map { aggregate in
                let kind: ActivityDetection.Kind = aggregate.readiness.ready ? .workout : .activityCandidate
                let confidence: ActivityDetection.Confidence = aggregate.readiness.ready ? .medium : .low
                let reason = aggregate.readiness.ready
                    ? "sustained elevated HR across saved chunks"
                    : "HR-only workout-like signal across saved chunks; \(aggregate.readiness.nearMiss ? aggregate.readiness.nearMissReason : aggregate.readiness.strengthCandidateReason); not counted as workout"
                return ActivityDetection(id: aggregate.id,
                                         kind: kind,
                                         confidence: confidence,
                                         start: aggregate.start,
                                         end: aggregate.end,
                                         duration: aggregate.duration,
                                         avgHR: aggregate.avgHR,
                                         peakHR: aggregate.peakHR,
                                         reason: reason)
            }
        return (single + aggregateWorkouts).sorted { $0.start > $1.start }
    }

    func dailyRollups(rest: Int, maxHR: Int, calendar: Calendar = .current) -> [DailyRollup] {
        let replaySessions = canonicalSessions()
        let grouped = Dictionary(grouping: replaySessions) { session in
            calendar.startOfDay(for: session.start)
        }
        let aggregateSleeps = Dictionary(uniqueKeysWithValues: aggregateSleepCandidates(rest: rest, calendar: calendar).map { ($0.day, $0) })
        let aggregateCandidatesByDay = Dictionary(grouping: aggregateWorkoutCandidates(rest: rest, maxHR: maxHR, calendar: calendar).filter {
            $0.readiness.ready || $0.readiness.nearMiss || $0.readiness.strengthCandidate
        }) { candidate in
            candidate.day
        }
        let confirmedWorkoutsByDay = Dictionary(grouping: cachedConfirmedWorkouts) { workout in
            calendar.startOfDay(for: workout.start)
        }
        return grouped.map { day, daySessions in
            let detections = daySessions.compactMap { $0.detectedActivity(rest: rest, maxHR: maxHR, calendar: calendar) }
            let singleSessionWorkouts = detections.filter { $0.kind == .workout }.count
            let aggregateCandidates = aggregateCandidatesByDay[day] ?? []
            let aggregateWorkoutDay = aggregateCandidates.contains { $0.readiness.ready } ? 1 : 0
            let workouts = max(singleSessionWorkouts, aggregateWorkoutDay)
            let singleActivityCandidates = detections.filter { $0.kind == .activityCandidate }.count
            let aggregateActivityDay = aggregateCandidates.contains { !$0.readiness.ready } ? 1 : 0
            let activityCandidates = max(singleActivityCandidates, aggregateActivityDay)
            let restCandidates = detections.filter { $0.kind == .restCandidate }.count
            let singleSessionSleepCandidates = detections.filter { $0.kind == .sleepCandidate }.count
            let aggregateSleep = aggregateSleeps[day]
            let aggregateSleepReady = (aggregateSleep?.motionEvidenceValidated == true && aggregateSleep?.confidence != .low) ? 1 : 0
            let sleepCandidates = max(singleSessionSleepCandidates, aggregateSleep == nil ? 0 : 1)
            let duration = daySessions.reduce(0) { $0 + $1.duration }
            let strainTRIMP = daySessions.reduce(0) { $0 + $1.trimp(rest: rest, max: maxHR) }
            let hrvs = daySessions.compactMap(\.localRMSSD).filter { $0 > 0 }
            let respiratoryRates = daySessions.compactMap(\.respiratoryRate).filter { $0 > 0 }
            let sleepRHRs = daySessions.compactMap { session -> Int? in
                guard session.detectedActivity(rest: rest, maxHR: maxHR, calendar: calendar)?.kind == .sleepCandidate else {
                    return nil
                }
                return session.sleepCandidateRestingHR
            }.filter { $0 > 0 }
            let fallbackRHRs = daySessions.map(\.restingStable).filter { $0 > 0 }
            return DailyRollup(day: day,
                               sessions: daySessions.count,
                               activityCandidates: activityCandidates,
                               workouts: workouts,
                               confirmedWorkouts: confirmedWorkoutsByDay[day]?.count ?? 0,
                               restCandidates: restCandidates,
                               sleepReady: aggregateSleepReady,
                               sleepCandidates: sleepCandidates,
                               duration: duration,
                               strain: Metrics.strain(fromTRIMP: strainTRIMP),
                               avgHRV: averageInt(hrvs),
                               restingHR: aggregateSleep?.restingHR ?? sleepRHRs.min() ?? fallbackRHRs.min(),
                               avgRespiratoryRate: averageDouble(respiratoryRates))
        }
        .sorted { $0.day > $1.day }
    }

    func aggregateWorkoutCandidates(rest: Int,
                                    maxHR: Int,
                                    calendar: Calendar = .current,
                                    thresholdFraction: Double = 0.50) -> [AggregateWorkoutCandidate] {
        let eligible = canonicalSessions().filter { !$0.points.isEmpty && $0.duration >= 60 }
        let grouped = Dictionary(grouping: eligible) { session in
            calendar.startOfDay(for: session.start)
        }
        return grouped.flatMap { day, daySessions in
            workoutClusters(from: daySessions, maxGap: 30 * 60).flatMap { cluster -> [AggregateWorkoutCandidate] in
                guard let start = cluster.map(\.start).min(),
                      let end = cluster.map(\.end).max() else { return [] }
                let ordered = cluster.sorted { $0.start < $1.start }
                let points = ordered.flatMap { session in
                    session.points.map { point in
                        SavedSession.Point(t: session.start.addingTimeInterval(point.t).timeIntervalSince(start),
                                           bpm: point.bpm)
                    }
                }.sorted { lhs, rhs in
                    if lhs.t != rhs.t { return lhs.t < rhs.t }
                    return lhs.bpm < rhs.bpm
                }
                guard points.count >= 2 else { return [] }
                let labels = Array(Set(ordered.map(\.label))).sorted()
                let label: String
                if labels.count == 1 {
                    label = ordered.count == 1 ? labels[0] : "\(labels[0]) aggregate"
                } else if let first = labels.first {
                    label = "\(first) + \(labels.count - 1) chunks"
                } else {
                    label = "Workout aggregate"
                }
                var candidates: [AggregateWorkoutCandidate] = []
                if ordered.count > 1,
                   let wholeCluster = makeAggregateWorkoutCandidate(source: "aggregate_chunks",
                                                                    day: day,
                                                                    ordered: ordered,
                                                                    labels: labels,
                                                                    label: label,
                                                                    start: start,
                                                                    end: end,
                                                                    points: points,
                                                                    rest: rest,
                                                                    maxHR: maxHR,
                                                                    thresholdFraction: thresholdFraction) {
                    candidates.append(wholeCluster)
                }
                if ordered.count > 1,
                   let stitchedPoints = stitchedObservedWorkoutPoints(from: ordered),
                   let stitchedCluster = makeAggregateWorkoutCandidate(source: "stitched_observed_chunks",
                                                                       day: day,
                                                                       ordered: ordered,
                                                                       labels: labels,
                                                                       label: "\(label) observed",
                                                                       start: start,
                                                                       end: start.addingTimeInterval(stitchedPoints.duration),
                                                                       points: stitchedPoints.points,
                                                                       rest: rest,
                                                                       maxHR: maxHR,
                                                                       thresholdFraction: thresholdFraction) {
                    candidates.append(AggregateWorkoutCandidate(id: stitchedCluster.id,
                                                               source: stitchedCluster.source,
                                                               day: stitchedCluster.day,
                                                               sessions: stitchedCluster.sessions,
                                                               labels: stitchedCluster.labels,
                                                               label: stitchedCluster.label,
                                                               start: start,
                                                               end: end,
                                                               duration: stitchedCluster.duration,
                                                               span: end.timeIntervalSince(start),
                                                               samples: stitchedCluster.samples,
                                                               avgHR: stitchedCluster.avgHR,
                                                               peakHR: stitchedCluster.peakHR,
                                                               hrRaw2A37: stitchedCluster.hrRaw2A37,
                                                               hrAccepted: stitchedCluster.hrAccepted,
                                                               hrZero: stitchedCluster.hrZero,
                                                               hrArtifactHeld: stitchedCluster.hrArtifactHeld,
                                                               hrArtifactDropped: stitchedCluster.hrArtifactDropped,
                                                               hrRawGaps: stitchedCluster.hrRawGaps,
                                                               hrAcceptedGaps: stitchedCluster.hrAcceptedGaps,
                                                               hrMaxRawGap: stitchedCluster.hrMaxRawGap,
                                                               hrMaxAcceptedGap: stitchedCluster.hrMaxAcceptedGap,
                                                               readiness: stitchedCluster.readiness))
                }
                candidates.append(contentsOf: windowedWorkoutCandidates(day: day,
                                                                        ordered: ordered,
                                                                        labels: labels,
                                                                        clusterLabel: label,
                                                                        rest: rest,
                                                                        maxHR: maxHR,
                                                                        thresholdFraction: thresholdFraction))
                return candidates
            }
        }
        .sorted { lhs, rhs in
            if lhs.readiness.ready != rhs.readiness.ready { return lhs.readiness.ready }
            if lhs.readiness.longestElevatedBout != rhs.readiness.longestElevatedBout {
                return lhs.readiness.longestElevatedBout > rhs.readiness.longestElevatedBout
            }
            if lhs.readiness.elevatedSeconds != rhs.readiness.elevatedSeconds {
                return lhs.readiness.elevatedSeconds > rhs.readiness.elevatedSeconds
            }
            if lhs.readiness.borderlineLongestBout != rhs.readiness.borderlineLongestBout {
                return lhs.readiness.borderlineLongestBout > rhs.readiness.borderlineLongestBout
            }
            if lhs.readiness.borderlineElevatedSeconds != rhs.readiness.borderlineElevatedSeconds {
                return lhs.readiness.borderlineElevatedSeconds > rhs.readiness.borderlineElevatedSeconds
            }
            if lhs.peakHR != rhs.peakHR {
                return lhs.peakHR > rhs.peakHR
            }
            if lhs.readiness.streamCoveragePercent != rhs.readiness.streamCoveragePercent {
                return lhs.readiness.streamCoveragePercent > rhs.readiness.streamCoveragePercent
            }
            return lhs.start > rhs.start
        }
    }

    private func stitchedObservedWorkoutPoints(from sessions: [SavedSession]) -> (points: [SavedSession.Point], duration: TimeInterval)? {
        var stitched: [SavedSession.Point] = []
        var cursor: TimeInterval = 0
        let resetGap = SavedSession.workoutContinuityGapLimit + 1
        for session in sessions.sorted(by: { $0.start < $1.start }) {
            let points = session.points.sorted { lhs, rhs in
                if lhs.t != rhs.t { return lhs.t < rhs.t }
                return lhs.bpm < rhs.bpm
            }
            guard let first = points.first else { continue }
            var previous = first
            stitched.append(SavedSession.Point(t: cursor, bpm: first.bpm))
            for point in points.dropFirst() {
                let dt = max(0, point.t - previous.t)
                cursor += dt > SavedSession.workoutContinuityGapLimit ? resetGap : dt
                stitched.append(SavedSession.Point(t: cursor, bpm: point.bpm))
                previous = point
            }
            cursor += resetGap
        }
        guard stitched.count >= 2, let last = stitched.last else { return nil }
        return (stitched, last.t)
    }

    private func makeAggregateWorkoutCandidate(source: String,
                                               day: Date,
                                               ordered: [SavedSession],
                                               labels: [String],
                                               label: String,
                                               start: Date,
                                               end: Date,
                                               points: [SavedSession.Point],
                                               rest: Int,
                                               maxHR: Int,
                                               thresholdFraction: Double) -> AggregateWorkoutCandidate? {
        guard points.count >= 2, end > start else { return nil }
        let aggregate = SavedSession(id: ordered.first?.id ?? UUID(),
                                     start: start,
                                     end: end,
                                     label: label,
                                     points: points,
                                     hrv: nil,
                                     rrPoints: nil,
                                     hrvReferenceValidated: false,
                                     motionHintCount: ordered.reduce(0) { $0 + $1.motionHintCountValue },
                                     motionHintKinds: motionHintKindsSummary(for: ordered),
                                     motionEvidenceSource: ordered.contains { $0.motionHintCountValue > 0 } ? "diagnostic_observe_only" : "unavailable",
                                     motionEvidenceValidated: false,
                                     motionShortCount: nil,
                                     motionShortMean: nil,
                                     motionShortMin: nil,
                                     motionShortMax: nil,
                                     motionShortOverOneCount: nil,
                                     phoneStepSource: ordered.contains { $0.phoneStepCountValue > 0 } ? "phone_coremotion_pedometer" : "unavailable",
                                     phoneStepValidated: false,
                                     phoneStepCount: ordered.reduce(0) { $0 + $1.phoneStepCountValue },
                                     phoneStepDistanceMeters: ordered
                                         .compactMap(\.phoneStepDistanceMeters)
                                         .reduce(0, +),
                                     phoneStepFloorsAscended: ordered
                                         .compactMap(\.phoneStepFloorsAscended)
                                         .reduce(0, +),
                                     phoneStepFloorsDescended: ordered
                                         .compactMap(\.phoneStepFloorsDescended)
                                         .reduce(0, +),
                                     hrRaw2A37: ordered.reduce(0) { $0 + $1.hrRaw2A37Value },
                                     hrAccepted: ordered.reduce(0) { $0 + $1.hrAcceptedValue },
                                     hrZero: ordered.reduce(0) { $0 + $1.hrZeroValue },
                                     hrArtifactHeld: ordered.reduce(0) { $0 + $1.hrArtifactHeldValue },
                                     hrArtifactDropped: ordered.reduce(0) { $0 + $1.hrArtifactDroppedValue },
                                     hrRawGaps: ordered.reduce(0) { $0 + $1.hrRawGapsValue },
                                     hrAcceptedGaps: ordered.reduce(0) { $0 + $1.hrAcceptedGapsValue },
                                     hrMaxRawGap: ordered.map(\.hrMaxRawGapValue).max() ?? 0,
                                     hrMaxAcceptedGap: ordered.map(\.hrMaxAcceptedGapValue).max() ?? 0)
        let readiness = aggregate.workoutReadiness(rest: rest, maxHR: maxHR, thresholdFraction: thresholdFraction)
        return AggregateWorkoutCandidate(id: aggregate.id,
                                         source: source,
                                         day: day,
                                         sessions: ordered.count,
                                         labels: labels,
                                         label: label,
                                         start: start,
                                         end: end,
                                         duration: aggregate.duration,
                                         span: end.timeIntervalSince(start),
                                         samples: points.count,
                                         avgHR: aggregate.avg,
                                         peakHR: aggregate.peak,
                                         hrRaw2A37: aggregate.hrRaw2A37Value,
                                         hrAccepted: aggregate.hrAcceptedValue,
                                         hrZero: aggregate.hrZeroValue,
                                         hrArtifactHeld: aggregate.hrArtifactHeldValue,
                                         hrArtifactDropped: aggregate.hrArtifactDroppedValue,
                                         hrRawGaps: aggregate.hrRawGapsValue,
                                         hrAcceptedGaps: aggregate.hrAcceptedGapsValue,
                                         hrMaxRawGap: aggregate.hrMaxRawGapValue,
                                         hrMaxAcceptedGap: aggregate.hrMaxAcceptedGapValue,
                                         readiness: readiness)
    }

    private func windowedWorkoutCandidates(day: Date,
                                           ordered: [SavedSession],
                                           labels: [String],
                                           clusterLabel: String,
                                           rest: Int,
                                           maxHR: Int,
                                           thresholdFraction: Double) -> [AggregateWorkoutCandidate] {
        let absolutePoints = ordered.flatMap { session in
            session.points.map { point in
                (date: session.start.addingTimeInterval(point.t), bpm: point.bpm)
            }
        }
        .sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.bpm < rhs.bpm
        }
        guard let clusterStart = absolutePoints.first?.date,
              let clusterEnd = absolutePoints.last?.date,
              clusterEnd.timeIntervalSince(clusterStart) >= 10 * 60 else { return [] }

        let durations: [TimeInterval] = [10, 20, 30, 45, 60, 90].map { $0 * 60 }
        let step: TimeInterval = 5 * 60
        var candidates: [AggregateWorkoutCandidate] = []
        var seenActual = Set<String>()
        let absoluteDates = absolutePoints.map(\.date)
        let startIndices = workoutWindowStartIndices(from: absoluteDates, step: step)
        for startIndex in startIndices {
            let nominalStart = absoluteDates[startIndex]
            for duration in durations where duration <= clusterEnd.timeIntervalSince(clusterStart) {
                let nominalEnd = nominalStart.addingTimeInterval(duration)
                if nominalEnd > clusterEnd { break }
                guard let endIndex = firstWorkoutWindowIndex(atOrAfter: nominalEnd,
                                                             in: absoluteDates,
                                                             lowerBound: startIndex + 1) else { break }
                let actualStart = absolutePoints[startIndex].date
                let actualEnd = absolutePoints[endIndex].date
                let span = actualEnd.timeIntervalSince(actualStart)
                if span < 10 * 60 { continue }
                if span > durations.last ?? duration { break }
                let key = "\(Int(actualStart.timeIntervalSince1970.rounded())):\(Int(actualEnd.timeIntervalSince1970.rounded()))"
                guard seenActual.insert(key).inserted else { continue }
                let points = absolutePoints[startIndex...endIndex].map {
                    SavedSession.Point(t: $0.date.timeIntervalSince(actualStart), bpm: $0.bpm)
                }
                let windowSessions = ordered.filter { session in
                    session.end >= actualStart && session.start <= actualEnd
                }
                let windowLabel = "\(clusterLabel) window"
                if let candidate = makeAggregateWorkoutCandidate(source: "windowed_workout",
                                                                 day: day,
                                                                 ordered: windowSessions.isEmpty ? ordered : windowSessions,
                                                                 labels: labels,
                                                                 label: windowLabel,
                                                                 start: actualStart,
                                                                 end: actualEnd,
                                                                 points: points,
                                                                 rest: rest,
                                                                 maxHR: maxHR,
                                                                 thresholdFraction: thresholdFraction) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    private func workoutWindowStartIndices(from dates: [Date], step: TimeInterval) -> [Int] {
        guard let first = dates.first else { return [] }
        var indices: [Int] = []
        var nextStart = first
        for (index, date) in dates.enumerated() {
            if date >= nextStart {
                indices.append(index)
                nextStart = date.addingTimeInterval(step)
            }
        }
        return indices
    }

    private func firstWorkoutWindowIndex(atOrAfter target: Date,
                                         in dates: [Date],
                                         lowerBound: Int) -> Int? {
        var left = max(0, lowerBound)
        var right = dates.count
        while left < right {
            let middle = (left + right) / 2
            if dates[middle] < target {
                left = middle + 1
            } else {
                right = middle
            }
        }
        return left < dates.count ? left : nil
    }

    func aggregateSleepCandidates(rest: Int, calendar: Calendar = .current) -> [AggregateSleepCandidate] {
        aggregateSleepCandidates(in: canonicalSessions(), rest: rest, maxHR: profile.maxHR, calendar: calendar)
    }

    private func aggregateSleepCandidates(in sourceSessions: [SavedSession],
                                          rest: Int,
                                          maxHR: Int,
                                          calendar: Calendar = .current) -> [AggregateSleepCandidate] {
        let eligible = sourceSessions.filter { session in
            guard session.duration >= 20 * 60, !session.points.isEmpty else { return false }
            let startHour = calendar.component(.hour, from: session.start)
            let endHour = calendar.component(.hour, from: session.end)
            let overnight = startHour >= 20 || startHour <= 5 || endHour <= 11
            let lowHR = session.avg <= rest + 18 && session.peak <= rest + 55
            let notWorkout = !session.workoutReadiness(rest: rest, maxHR: maxHR).ready
            return overnight && lowHR && notWorkout
        }
        let grouped = Dictionary(grouping: eligible) { session in
            aggregateSleepDay(for: session, calendar: calendar)
        }
        let candidates: [AggregateSleepCandidate] = grouped.flatMap { day, daySessions in
            let ordered = daySessions.sorted { $0.start < $1.start }
            let clusters = sleepClusters(from: ordered, maxGap: 2 * 60 * 60)
            return clusters.compactMap { cluster -> AggregateSleepCandidate? in
                let totalDuration = cluster.reduce(0) { $0 + $1.duration }
                let gaps = zip(cluster, cluster.dropFirst()).map { previous, next in
                    max(0, next.start.timeIntervalSince(previous.end))
                }
                let maxGap = gaps.max() ?? 0

                let allHR = cluster.flatMap(\.bpms)
                guard !allHR.isEmpty, let start = cluster.first?.start, let end = cluster.last?.end else { return nil }
                let span = end.timeIntervalSince(start)
                let strictDurationReady = totalDuration >= AggregateSleepCandidate.strictMinimumDuration
                let fragmentedFallbackReady = cluster.count > 1
                    && span >= AggregateSleepCandidate.fragmentedMinimumSpan
                    && totalDuration >= AggregateSleepCandidate.fragmentedMinimumDuration
                    && maxGap <= 2 * 60 * 60
                guard strictDurationReady || fragmentedFallbackReady else { return nil }
                let avg = allHR.reduce(0, +) / allHR.count
                let peak = allHR.max() ?? 0
                let resting = percentileHR(0.05, values: allHR)
                let motionHintCount = cluster.reduce(0) { $0 + $1.motionHintCountValue }
                let motionHintKinds = motionHintKindsSummary(for: cluster)
                let historicalMotion = HistoricalArchive.motionWindowDiagnostics(start: start, end: end)
                let motionSource = historicalMotion.lowMotionReady
                    ? "historical_gravity"
                    : (motionHintCount > 0 ? "diagnostic_observe_only" : "unavailable")
                let motionValidated = historicalMotion.lowMotionReady || cluster.contains { $0.motionEvidenceValidatedValue }
                let motionStats = motionShortSummary(for: cluster)
                let motionClause = motionHintCount > 0
                    ? "diagnostic motion observed unvalidated"
                    : "motion not decoded"
                let confidence: ActivityDetection.Confidence = historicalMotion.lowMotionReady ? .medium : .low
                let motionReason = historicalMotion.lowMotionReady
                    ? "historical gravity low-motion validated"
                    : "\(motionClause); historical gravity \(historicalMotion.reason)"
                let reason: String
                if fragmentedFallbackReady && !strictDurationReady {
                    reason = "HR-only interrupted overnight low-HR aggregate; below strict 3h low-HR total but span supports broken sleep fallback; \(motionReason)"
                } else if cluster.count > 1 {
                    reason = "HR-only broken overnight low-HR aggregate; \(motionReason)"
                } else {
                    reason = "HR-only overnight low-HR window; \(motionReason)"
                }
                return AggregateSleepCandidate(day: day,
                                               sessions: cluster.count,
                                               start: start,
                                               end: end,
                                               duration: totalDuration,
                                               span: span,
                                               maxGap: maxGap,
                                               samples: cluster.reduce(0) { $0 + $1.points.count },
                                               avgHR: avg,
                                               peakHR: peak,
                                               restingHR: resting,
                                               confidence: confidence,
                                               reason: reason,
                                               motionHintCount: motionHintCount,
                                               motionHintKinds: motionHintKinds,
                                               motionEvidenceSource: motionSource,
                                               motionEvidenceValidated: motionValidated,
                                               motionShortCount: motionStats.count,
                                               motionShortMean: motionStats.mean,
                                               motionShortMin: motionStats.min,
                                               motionShortMax: motionStats.max,
                                               motionShortOverOneCount: motionStats.overOne,
                                               historicalMotionStatus: historicalMotion.status,
                                               historicalMotionReason: historicalMotion.reason,
                                               historicalMotionRows: historicalMotion.rows,
                                               historicalMotionValidatedRows: historicalMotion.validatedRows,
                                               historicalMotionCoverageSeconds: historicalMotion.coverageSeconds,
                                               historicalMotionMeanVectorDelta: historicalMotion.meanVectorDelta,
                                               historicalMotionP95VectorDelta: historicalMotion.p95VectorDelta,
                                               historicalMotionMagnitudeStdDev: historicalMotion.magnitudeStdDev,
                                               historicalMotionArchiveFirstUnix: historicalMotion.archiveFirstUnix,
                                               historicalMotionArchiveLastUnix: historicalMotion.archiveLastUnix,
                                               historicalMotionNearestSeparationSeconds: historicalMotion.nearestSeparationSeconds,
                                               historicalMotionValidated: historicalMotion.lowMotionReady)
            }
        }
        return candidates
        .sorted { $0.day > $1.day }
    }

    func sleepEvidenceStatusFast(rest: Int,
                                 calendar: Calendar = .current,
                                 windowDays: Int = 45,
                                 limitSessions: Int = 48) -> SleepEvidenceStatus {
        let recent = recentCanonicalSessions(windowDays: windowDays, limitSessions: limitSessions)
        let candidates = aggregateSleepCandidates(in: recent,
                                                  rest: rest,
                                                  maxHR: profile.maxHR,
                                                  calendar: calendar)
        let ready = candidates.filter { candidate in
            candidate.motionEvidenceValidated && candidate.confidence != .low
        }
        if let best = ready.first {
            return SleepEvidenceStatus(ready: true,
                                       state: "ready",
                                       blocker: "none",
                                       confidence: best.confidence.rawValue,
                                       candidates: candidates.count,
                                       readyCandidates: ready.count,
                                       motionSource: best.motionEvidenceSource,
                                       motionValidated: true,
                                       fallbackAvailable: false,
                                       fallbackSource: "none",
                                       fallbackReason: "none",
                                       fallbackDuration: 0,
                                       fallbackSpan: 0,
                                       fallbackSessions: 0)
        }

        if let best = candidates.first {
            return SleepEvidenceStatus(ready: false,
                                       state: "low_confidence",
                                       blocker: sleepEvidenceBlocker(for: best),
                                       confidence: best.confidence.rawValue,
                                       candidates: candidates.count,
                                       readyCandidates: 0,
                                       motionSource: best.motionEvidenceSource,
                                       motionValidated: best.motionEvidenceValidated,
                                       fallbackAvailable: true,
                                       fallbackSource: best.sessions > 1 ? "hr_only_fragmented_sleep" : "hr_only_sleep",
                                       fallbackReason: best.reason,
                                       fallbackDuration: best.duration,
                                       fallbackSpan: best.span,
                                       fallbackSessions: best.sessions)
        }

        let observedSleepDays = Set(recent.map { calendar.startOfDay(for: $0.start) }).count
        return SleepEvidenceStatus(ready: false,
                                   state: observedSleepDays > 0 ? "low_confidence" : "learning",
                                   blocker: observedSleepDays > 0 ? "sleep_low_confidence" : "sleep_learning",
                                   confidence: observedSleepDays > 0 ? "low" : "none",
                                   candidates: 0,
                                   readyCandidates: 0,
                                   motionSource: "unavailable",
                                   motionValidated: false,
                                   fallbackAvailable: false,
                                   fallbackSource: "none",
                                   fallbackReason: "none",
                                   fallbackDuration: 0,
                                   fallbackSpan: 0,
                                   fallbackSessions: 0)
    }

    func sleepEvidenceStatus(rest: Int,
                             calendar: Calendar = .current,
                             sleepDays: Int? = nil) -> SleepEvidenceStatus {
        let candidates = aggregateSleepCandidates(rest: rest, calendar: calendar)
        let ready = candidates.filter { candidate in
            candidate.motionEvidenceValidated && candidate.confidence != .low
        }
        if let best = ready.first {
            return SleepEvidenceStatus(ready: true,
                                       state: "ready",
                                       blocker: "none",
                                       confidence: best.confidence.rawValue,
                                       candidates: candidates.count,
                                       readyCandidates: ready.count,
                                       motionSource: best.motionEvidenceSource,
                                       motionValidated: true,
                                       fallbackAvailable: false,
                                       fallbackSource: "none",
                                       fallbackReason: "none",
                                       fallbackDuration: 0,
                                       fallbackSpan: 0,
                                       fallbackSessions: 0)
        }

        let observedSleepDays = sleepDays ?? (candidates.isEmpty ? 0 : candidates.count)
        if let best = candidates.first {
            return SleepEvidenceStatus(ready: false,
                                       state: "low_confidence",
                                       blocker: sleepEvidenceBlocker(for: best),
                                       confidence: best.confidence.rawValue,
                                       candidates: candidates.count,
                                       readyCandidates: 0,
                                       motionSource: best.motionEvidenceSource,
                                       motionValidated: best.motionEvidenceValidated,
                                       fallbackAvailable: true,
                                       fallbackSource: best.sessions > 1 ? "hr_only_fragmented_sleep" : "hr_only_sleep",
                                       fallbackReason: best.reason,
                                       fallbackDuration: best.duration,
                                       fallbackSpan: best.span,
                                       fallbackSessions: best.sessions)
        }

        return SleepEvidenceStatus(ready: false,
                                   state: observedSleepDays > 0 ? "low_confidence" : "learning",
                                   blocker: observedSleepDays > 0 ? "sleep_low_confidence" : "sleep_learning",
                                   confidence: observedSleepDays > 0 ? "low" : "none",
                                   candidates: 0,
                                   readyCandidates: 0,
                                   motionSource: "unavailable",
                                   motionValidated: false,
                                   fallbackAvailable: false,
                                   fallbackSource: "none",
                                   fallbackReason: "none",
                                   fallbackDuration: 0,
                                   fallbackSpan: 0,
                                   fallbackSessions: 0)
    }

    private func sleepEvidenceBlocker(for candidate: AggregateSleepCandidate) -> String {
        if candidate.motionEvidenceValidated && candidate.confidence == .low {
            return "sleep_low_confidence_threshold"
        }
        if !candidate.motionEvidenceValidated {
            switch candidate.historicalMotionReason {
            case "no_historical_gravity":
                return "sleep_motion_unvalidated_no_historical_gravity"
            case "no_timestamp_overlap":
                return "sleep_motion_unvalidated_no_historical_overlap"
            case "historical_archive_stale":
                return "sleep_motion_unvalidated_historical_stale"
            case "historical_archive_future_or_misaligned":
                return "sleep_motion_unvalidated_historical_misaligned"
            case "insufficient_validated_gravity":
                return "sleep_motion_unvalidated_insufficient_gravity"
            case "insufficient_overlap_coverage":
                return "sleep_motion_unvalidated_insufficient_coverage"
            case "vector_delta_high":
                return "sleep_motion_unvalidated_motion_too_high"
            case "magnitude_variance_high":
                return "sleep_motion_unvalidated_variance_too_high"
            default:
                return candidate.motionHintCount > 0
                    ? "sleep_motion_hint_observe_only"
                    : "sleep_motion_unvalidated"
            }
        }
        return "sleep_low_confidence"
    }

    func aggregateSleepDiagnostics(rest: Int, calendar: Calendar = .current) -> (evaluated: Int, eligible: Int, tooShort: Int, notOvernight: Int, hrTooHigh: Int, workoutLike: Int, candidates: Int) {
        var evaluated = 0
        var eligible = 0
        var tooShort = 0
        var notOvernight = 0
        var hrTooHigh = 0
        var workoutLike = 0
        for session in sessions {
            guard !session.points.isEmpty else { continue }
            evaluated += 1
            if session.duration < 20 * 60 {
                tooShort += 1
                continue
            }
            let startHour = calendar.component(.hour, from: session.start)
            let endHour = calendar.component(.hour, from: session.end)
            let overnight = startHour >= 20 || startHour <= 5 || endHour <= 11
            if !overnight {
                notOvernight += 1
                continue
            }
            let lowHR = session.avg <= rest + 18 && session.peak <= rest + 55
            if !lowHR {
                hrTooHigh += 1
                continue
            }
            if session.workoutReadiness(rest: rest, maxHR: profile.maxHR).ready {
                workoutLike += 1
                continue
            }
            eligible += 1
        }
        let candidates = aggregateSleepCandidates(rest: rest, calendar: calendar).count
        return (evaluated, eligible, tooShort, notOvernight, hrTooHigh, workoutLike, candidates)
    }

    private func motionHintKindsSummary(for sessions: [SavedSession]) -> String {
        let kinds = sessions
            .map(\.motionHintKindsValue)
            .filter { $0 != "none" }
        return kinds.isEmpty ? "none" : kinds.joined(separator: "+")
    }

    private func motionShortSummary(for sessions: [SavedSession]) -> (count: Int, mean: Double?, min: Double?, max: Double?, overOne: Int) {
        let count = sessions.reduce(0) { $0 + $1.motionShortCountValue }
        guard count > 0 else { return (0, nil, nil, nil, 0) }
        let weightedSum = sessions.reduce(0.0) { total, session in
            total + ((session.motionShortMeanValue ?? 0) * Double(session.motionShortCountValue))
        }
        let valuesWithMin = sessions.compactMap(\.motionShortMinValue)
        let valuesWithMax = sessions.compactMap(\.motionShortMaxValue)
        let overOne = sessions.reduce(0) { $0 + $1.motionShortOverOneCountValue }
        return (count,
                weightedSum / Double(count),
                valuesWithMin.min(),
                valuesWithMax.max(),
                overOne)
    }

    func trendSummaries(rest: Int, maxHR: Int) -> [TrendSummary] {
        let now = Date()
        let rollups = dailyRollups(rest: rest, maxHR: maxHR)
        return TrendSummary.Window.allCases.map { window in
            let cutoff = now.addingTimeInterval(-Double(window.rawValue) * 24 * 60 * 60)
            let recent = sessions.filter { $0.start >= cutoff }
            let recentRollups = rollups.filter { $0.day >= Calendar.current.startOfDay(for: cutoff) }
            let coverageDays = Set(recent.map { Calendar.current.startOfDay(for: $0.start) }).count
            let requiredCoverageDays = trendRequiredCoverageDays(windowDays: window.rawValue)
            let coveragePercent = Int((Double(coverageDays) / Double(window.rawValue) * 100).rounded())
            let confidence = trendConfidence(coverageDays: coverageDays, windowDays: window.rawValue)
            let rhrs = recent.compactMap { session -> Int? in
                let evidence = session.baselineLearningEvidence(rest: rest, maxHR: maxHR)
                return evidence.accepted ? evidence.value : nil
            }
            let strains = recent.map { Metrics.strain(fromTRIMP: $0.trimp(rest: rest, max: maxHR)) }
            let hrvs = recent.compactMap(\.localRMSSD).filter { $0 > 0 }
            let respiratoryRates = recent.compactMap(\.respiratoryRate).filter { $0 > 0 }
            let recoveries = recent.compactMap {
                let recovery = Metrics.recoveryV2(hrvSnapshot: nil,
                                                  fallbackRMSSD: $0.localRMSSD,
                                                  restingNow: $0.restingStable,
                                                  baseline: baseline,
                                                  hrvReferenceValidated: $0.hrvReferenceValidated == true)
                return recovery.percent
            }

            let anomalies = trendAnomalies(rollups: recentRollups)
            let validatedHRVs = recent.compactMap(\.referenceValidatedHRV).filter { $0 > 0 }
            let hrvState = hrvs.isEmpty
                ? "learning"
                : (validatedHRVs.count == hrvs.count
                   ? "validated_samples_\(hrvs.count)"
                   : "personal_baseline_samples_\(hrvs.count)")
            let avgRecovery = averageInt(recoveries)
            let avgHRV = averageInt(hrvs)
            let detail = trendDetail(coverageDays: coverageDays,
                                     windowDays: window.rawValue,
                                     hrvState: hrvState,
                                     rhrSamples: rhrs.count,
                                     strainSamples: strains.count,
                                     anomalySource: "daily_rollups",
                                     anomalySampleDays: recentRollups.count,
                                     anomalies: anomalies)
            let blockers = trendSummaryBlockers(coverageDays: coverageDays,
                                                requiredCoverageDays: requiredCoverageDays,
                                                avgRecovery: avgRecovery,
                                                avgHRV: avgHRV,
                                                hrvState: hrvState)
            return TrendSummary(id: window.rawValue,
                                days: window.rawValue,
                                sessions: recent.count,
                                coverageDays: coverageDays,
                                requiredCoverageDays: requiredCoverageDays,
                                coveragePercent: coveragePercent,
                                confidence: confidence,
                                avgRecovery: avgRecovery,
                                avgHRV: avgHRV,
                                avgRHR: averageInt(rhrs),
                                avgStrain: averageDouble(strains),
                                avgRespiratoryRate: averageDouble(respiratoryRates),
                                anomalies: anomalies,
                                anomalySource: "daily_rollups",
                                anomalySampleDays: recentRollups.count,
                                hrvState: hrvState,
                                detail: detail,
                                blockers: blockers)
        }
    }

    func trainingLoadSummary(rest: Int, maxHR: Int) -> TrainingLoadSummary {
        let rollups = dailyRollups(rest: rest, maxHR: maxHR)
        let acuteRollups = Array(rollups.prefix(7))
        let chronicRollups = Array(rollups.prefix(28))
        let acute = averageDouble(acuteRollups.map(\.strain)) ?? 0
        let chronic = averageDouble(chronicRollups.map(\.strain)) ?? 0
        let ratio = chronic > 0 ? acute / chronic : nil
        let enoughAcute = acuteRollups.count >= 3
        let enoughChronic = chronicRollups.count >= 14
        let confidence: String
        if enoughChronic {
            confidence = "local"
        } else if enoughAcute {
            confidence = "partial"
        } else {
            confidence = "learning"
        }
        let targetBand: ClosedRange<Double>? = {
            guard enoughAcute else { return nil }
            if let ratio {
                if ratio > 1.30 {
                    return max(0, acute - 4)...max(0, acute - 1)
                }
                if ratio < 0.80 {
                    return acute...(min(21, acute + 3))
                }
            }
            return max(0, acute - 1.5)...min(21, acute + 1.5)
        }()
        let detail: String
        if let ratio {
            if ratio > 1.30 {
                detail = "Acute load is running ahead of your 28-day base."
            } else if ratio < 0.80 {
                detail = "Recent strain is below your longer baseline."
            } else {
                detail = "Recent strain is aligned with your longer baseline."
            }
        } else {
            detail = "Atria needs more local strain history for load ratio."
        }
        return TrainingLoadSummary(acuteLoad: acute,
                                   chronicLoad: chronic,
                                   ratio: ratio,
                                   confidence: confidence,
                                   targetBand: targetBand,
                                   detail: detail)
    }

    func vo2MaxEstimateSummary(rest: Int, maxHR: Int) -> VO2MaxEstimateSummary {
        let restingSamples = baseline.restingSampleCount
        guard rest > 0, maxHR > rest, restingSamples >= 3 else {
            return VO2MaxEstimateSummary(value: nil,
                                         confidence: "learning",
                                         detail: "\(restingSamples)/3 RHR",
                                         narrative: "Atria needs a few local resting baselines before estimating VO2max.")
        }

        let rawEstimate = 15.3 * Double(maxHR) / Double(rest)
        let boundedEstimate = min(max(rawEstimate, 20), 80)
        let confidence: String
        if restingSamples >= 7 && profile.maxHRSource == .measured {
            confidence = "rough estimate"
        } else {
            confidence = "learning"
        }
        let detail = "\(confidence) · RHR \(rest) · HRmax \(maxHR)"
        let narrative = restingSamples >= 7 && profile.maxHRSource == .measured
            ? "Rough estimate from measured max HR and resting baseline."
            : "Needs measured HRmax and 7 resting nights."
        return VO2MaxEstimateSummary(value: boundedEstimate,
                                     confidence: confidence,
                                     detail: detail,
                                     narrative: narrative)
    }

    func trendSummaryFast(rest: Int,
                          maxHR: Int,
                          days: Int = 90,
                          limitSessions: Int = 120,
                          now: Date = Date()) -> TrendSummary {
        let recent = recentCanonicalSessions(windowDays: days,
                                             limitSessions: limitSessions,
                                             now: now)
        let coverageDays = Set(recent.map { Calendar.current.startOfDay(for: $0.start) }).count
        let requiredCoverageDays = trendRequiredCoverageDays(windowDays: days)
        let coveragePercent = Int((Double(coverageDays) / Double(days) * 100).rounded())
        let confidence = trendConfidence(coverageDays: coverageDays, windowDays: days)
        let rhrs = recent.compactMap { session -> Int? in
            let evidence = session.baselineLearningEvidence(rest: rest, maxHR: maxHR)
            return evidence.accepted ? evidence.value : nil
        }
        let strains = recent.map { Metrics.strain(fromTRIMP: $0.trimp(rest: rest, max: maxHR)) }
        let hrvs = recent.compactMap(\.localRMSSD).filter { $0 > 0 }
        let respiratoryRates = recent.compactMap(\.respiratoryRate).filter { $0 > 0 }
        let recoveries = recent.compactMap {
            let recovery = Metrics.recoveryV2(hrvSnapshot: nil,
                                              fallbackRMSSD: $0.localRMSSD,
                                              restingNow: $0.restingStable,
                                              baseline: baseline,
                                              hrvReferenceValidated: $0.hrvReferenceValidated == true)
            return recovery.percent
        }
        let validatedHRVs = recent.compactMap(\.referenceValidatedHRV).filter { $0 > 0 }
        let hrvState = hrvs.isEmpty
            ? "learning"
            : (validatedHRVs.count == hrvs.count
               ? "validated_samples_\(hrvs.count)"
               : "personal_baseline_samples_\(hrvs.count)")
        let avgRecovery = averageInt(recoveries)
        let avgHRV = averageInt(hrvs)
        let detail = trendDetail(coverageDays: coverageDays,
                                 windowDays: days,
                                 hrvState: hrvState,
                                 rhrSamples: rhrs.count,
                                 strainSamples: strains.count,
                                 anomalySource: "bounded_recent_sessions",
                                 anomalySampleDays: coverageDays,
                                 anomalies: [])
        let blockers = trendSummaryBlockers(coverageDays: coverageDays,
                                            requiredCoverageDays: requiredCoverageDays,
                                            avgRecovery: avgRecovery,
                                            avgHRV: avgHRV,
                                            hrvState: hrvState)
        return TrendSummary(id: days,
                            days: days,
                            sessions: recent.count,
                            coverageDays: coverageDays,
                            requiredCoverageDays: requiredCoverageDays,
                            coveragePercent: coveragePercent,
                            confidence: confidence,
                            avgRecovery: avgRecovery,
                            avgHRV: avgHRV,
                            avgRHR: averageInt(rhrs),
                            avgStrain: averageDouble(strains),
                            avgRespiratoryRate: averageDouble(respiratoryRates),
                            anomalies: [],
                            anomalySource: "bounded_recent_sessions",
                            anomalySampleDays: coverageDays,
                            hrvState: hrvState,
                            detail: detail,
                            blockers: blockers)
    }

    func logTrendSummariesFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-log-trends") else { return }
        let rest = baseline.restingInt ?? 60
        let summaries = trendSummaries(rest: rest, maxHR: profile.maxHR)
        WHOOPDebugLog("WHOOPDBG trend_summary sessions=%d rest_hr=%d max_hr=%d windows=%d",
              sessions.count, rest, profile.maxHR, summaries.count)
        for summary in summaries {
            let anomalyFlags = trendAnomalyFlags(summary.anomalies)
            let detail = summary.detail.replacingOccurrences(of: " ", with: "_")
            WHOOPDebugLog("WHOOPDBG trend_window days=%d sessions=%d coverage_days=%d required_coverage_days=%d required_coverage_percent=70 coverage_percent=%d confidence=%@ recovery=%@ hrv=%@ hrv_state=%@ rhr=%@ strain=%@ respiratory_rate=%@ anomalies=%d anomaly_flags=%@ anomaly_source=%@ anomaly_days=%d detail=%@ blockers=%@",
                  summary.days,
                  summary.sessions,
                  summary.coverageDays,
                  summary.requiredCoverageDays,
                  summary.coveragePercent,
                  summary.confidence,
                  formatInt(summary.avgRecovery),
                  formatInt(summary.avgHRV),
                  summary.hrvState,
                  formatInt(summary.avgRHR),
                  formatDouble(summary.avgStrain),
                  formatDouble(summary.avgRespiratoryRate),
                  summary.anomalies.count,
                  anomalyFlags,
                  summary.anomalySource,
                  summary.anomalySampleDays,
                  detail,
                  summary.blockers)
        }
    }

    func logDailyRollupsFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-log-daily-rollups") else { return }
        let rest = baseline.restingInt ?? 60
        let rollups = dailyRollups(rest: rest, maxHR: profile.maxHR)
        let sleepReadyDays = rollups.filter { $0.sleepReady > 0 }.count
        let sleepCandidateDays = rollups.filter { $0.sleepCandidates > 0 }.count
        let workoutDays = rollups.filter { $0.workouts > 0 }.count
        let confirmedWorkoutDays = rollups.filter { $0.confirmedWorkouts > 0 }.count
        let confirmedWorkoutCount = rollups.reduce(0) { $0 + $1.confirmedWorkouts }
        let restCandidateDays = rollups.filter { $0.restCandidates > 0 }.count
        let restCandidateCount = rollups.reduce(0) { $0 + $1.restCandidates }
        WHOOPDebugLog("WHOOPDBG daily_rollup_summary sessions=%d days=%d sleep_ready_days=%d sleep_candidate_days=%d rest_candidate_days=%d rest_candidates=%d workout_days=%d confirmed_workout_days=%d confirmed_workouts=%d rest_hr=%d max_hr=%d",
              sessions.count, rollups.count, sleepReadyDays, sleepCandidateDays, restCandidateDays, restCandidateCount, workoutDays, confirmedWorkoutDays, confirmedWorkoutCount, rest, profile.maxHR)
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        for rollup in rollups.prefix(14) {
            WHOOPDebugLog("WHOOPDBG daily_rollup day=%@ sessions=%d activity_candidates=%d workouts=%d confirmed_workouts=%d rest_candidates=%d sleep_ready=%d sleep_candidates=%d duration_s=%.0f strain=%.2f hrv=%@ rhr=%@ respiratory_rate=%@ workout_gate_strict=1 sleep_gate_strict=1 rest_diagnostic_only=1",
                  formatter.string(from: rollup.day),
                  rollup.sessions,
                  rollup.activityCandidates,
                  rollup.workouts,
                  rollup.confirmedWorkouts,
                  rollup.restCandidates,
                  rollup.sleepReady,
                  rollup.sleepCandidates,
                  rollup.duration,
                  rollup.strain,
                  formatInt(rollup.avgHRV),
                  formatInt(rollup.restingHR),
                  formatDouble(rollup.avgRespiratoryRate))
        }
        let aggregateWorkouts = aggregateWorkoutCandidates(rest: rest, maxHR: profile.maxHR, calendar: Calendar.current)
        let readyAggregateWorkouts = aggregateWorkouts.filter { $0.readiness.ready }.count
        let bestAggregateWorkout = aggregateWorkouts.first
        WHOOPDebugLog("WHOOPDBG aggregate_workout_summary candidates=%d ready=%d best_source=%@ best_status=%@ best_reason=%@ best_blocker=%@ best_strength_candidate=%d best_strength_candidate_reason=%@ strength_diagnostic_only=1 best_next_action=%@ best_stream_coverage_percent=%d best_chunks=%d best_duration_s=%.0f best_observed_duration_s=%.0f best_dropped_gap_s=%.0f best_max_gap_s=%.1f best_p90_hr=%d best_p95_hr=%d best_p99_hr=%d best_threshold_gap_bpm=%d best_samples_above_threshold=%d best_samples_above_borderline=%d best_elevated_s=%.0f best_required_elevated_s=%.0f best_longest_bout_s=%.0f best_required_bout_s=%.0f best_borderline_threshold_hr=%d best_borderline_elevated_s=%.0f best_borderline_longest_bout_s=%.0f borderline_diagnostic_only=1 best_hr_raw_2a37=%d best_hr_accepted=%d best_hr_zero=%d best_hr_artifact_held=%d best_hr_artifact_dropped=%d best_hr_raw_gaps=%d best_hr_accepted_gaps=%d best_hr_max_raw_gap_s=%.1f best_hr_max_accepted_gap_s=%.1f cluster_gap_limit_s=1800 window_min_s=600 window_max_s=5400 sample_gap_limit_s=5 source=saved_session_chunks",
              aggregateWorkouts.count,
              readyAggregateWorkouts,
              bestAggregateWorkout?.source ?? "none",
              bestAggregateWorkout?.readiness.status ?? "learning",
              bestAggregateWorkout?.readiness.reason ?? "no_aggregate_candidate",
              bestAggregateWorkout?.readiness.primaryBlocker ?? "no_aggregate_candidate",
              bestAggregateWorkout?.readiness.strengthCandidate == true ? 1 : 0,
              bestAggregateWorkout?.readiness.strengthCandidateReason ?? "none",
              bestAggregateWorkout?.readiness.nextAction ?? "none",
              bestAggregateWorkout?.readiness.streamCoveragePercent ?? 0,
              bestAggregateWorkout?.sessions ?? 0,
              bestAggregateWorkout?.duration ?? 0,
              bestAggregateWorkout?.readiness.observedDuration ?? 0,
              bestAggregateWorkout?.readiness.droppedGapSeconds ?? 0,
              bestAggregateWorkout?.readiness.maxSampleGap ?? 0,
              bestAggregateWorkout?.readiness.p90HR ?? 0,
              bestAggregateWorkout?.readiness.p95HR ?? 0,
              bestAggregateWorkout?.readiness.p99HR ?? 0,
              bestAggregateWorkout?.readiness.thresholdGapBPM ?? 0,
              bestAggregateWorkout?.readiness.samplesAboveThreshold ?? 0,
              bestAggregateWorkout?.readiness.samplesAboveBorderline ?? 0,
              bestAggregateWorkout?.readiness.elevatedSeconds ?? 0,
              bestAggregateWorkout?.readiness.requiredElevatedSeconds ?? 0,
              bestAggregateWorkout?.readiness.longestElevatedBout ?? 0,
              bestAggregateWorkout?.readiness.requiredElevatedBout ?? 0,
              bestAggregateWorkout?.readiness.borderlineThresholdHR ?? 0,
              bestAggregateWorkout?.readiness.borderlineElevatedSeconds ?? 0,
              bestAggregateWorkout?.readiness.borderlineLongestBout ?? 0,
              bestAggregateWorkout?.hrRaw2A37 ?? 0,
              bestAggregateWorkout?.hrAccepted ?? 0,
              bestAggregateWorkout?.hrZero ?? 0,
              bestAggregateWorkout?.hrArtifactHeld ?? 0,
              bestAggregateWorkout?.hrArtifactDropped ?? 0,
              bestAggregateWorkout?.hrRawGaps ?? 0,
              bestAggregateWorkout?.hrAcceptedGaps ?? 0,
              bestAggregateWorkout?.hrMaxRawGap ?? 0,
              bestAggregateWorkout?.hrMaxAcceptedGap ?? 0)
        for aggregate in aggregateWorkouts.prefix(7) {
            let readiness = aggregate.readiness
            WHOOPDebugLog("WHOOPDBG aggregate_workout_candidate day=%@ source=%@ status=%@ reason=%@ primary_blocker=%@ strength_candidate=%d strength_candidate_reason=%@ strength_diagnostic_only=1 hr_distribution_below_workout_band=%d next_action=%@ stream_coverage_percent=%d chunks=%d duration_s=%.0f span_s=%.0f observed_duration_s=%.0f dropped_gap_s=%.0f max_gap_s=%.1f gap_count=%d samples=%d avg_hr=%d peak_hr=%d p90_hr=%d p95_hr=%d p99_hr=%d threshold_hr=%d threshold_gap_bpm=%d samples_above_threshold=%d samples_above_borderline=%d elevated_s=%.0f required_elevated_s=%.0f longest_bout_s=%.0f required_bout_s=%.0f borderline_threshold_hr=%d borderline_elevated_s=%.0f borderline_longest_bout_s=%.0f borderline_diagnostic_only=1 hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f labels=%@",
                  formatter.string(from: aggregate.day),
                  aggregate.source,
                  readiness.status,
                  readiness.reason,
                  readiness.primaryBlocker,
                  readiness.strengthCandidate ? 1 : 0,
                  readiness.strengthCandidateReason,
                  readiness.hrDistributionBelowWorkoutBand ? 1 : 0,
                  readiness.nextAction,
                  readiness.streamCoveragePercent,
                  aggregate.sessions,
                  aggregate.duration,
                  aggregate.span,
                  readiness.observedDuration,
                  readiness.droppedGapSeconds,
                  readiness.maxSampleGap,
                  readiness.gapCount,
                  aggregate.samples,
                  aggregate.avgHR,
                  aggregate.peakHR,
                  readiness.p90HR,
                  readiness.p95HR,
                  readiness.p99HR,
                  readiness.thresholdHR,
                  readiness.thresholdGapBPM,
                  readiness.samplesAboveThreshold,
                  readiness.samplesAboveBorderline,
                  readiness.elevatedSeconds,
                  readiness.requiredElevatedSeconds,
                  readiness.longestElevatedBout,
                  readiness.requiredElevatedBout,
                  readiness.borderlineThresholdHR,
                  readiness.borderlineElevatedSeconds,
                  readiness.borderlineLongestBout,
                  aggregate.hrRaw2A37,
                  aggregate.hrAccepted,
                  aggregate.hrZero,
                  aggregate.hrArtifactHeld,
                  aggregate.hrArtifactDropped,
                  aggregate.hrRawGaps,
                  aggregate.hrAcceptedGaps,
                  aggregate.hrMaxRawGap,
                  aggregate.hrMaxAcceptedGap,
                  aggregate.labels.joined(separator: "|"))
        }
        let aggregateDiagnostics = aggregateSleepDiagnostics(rest: rest, calendar: Calendar.current)
        let motionHintTotal = sessions.reduce(0) { $0 + $1.motionHintCountValue }
        let motionHintSessions = sessions.filter { $0.motionHintCountValue > 0 }.count
        let motionSource = motionHintTotal > 0 ? "diagnostic_observe_only" : "unavailable"
        let motionShortStats = motionShortSummary(for: sessions)
        WHOOPDebugLog("WHOOPDBG broken_sleep_summary candidates=%d eligible_sessions=%d evaluated_sessions=%d rejected_too_short=%d rejected_not_overnight=%d rejected_hr_too_high=%d rejected_workout_like=%d min_total_s=10800 fragmented_min_total_s=9000 fragmented_min_span_s=10800 max_gap_s=7200 confidence=low motion_source=%@ motion_hint_sessions=%d motion_hints=%d motion_validated=0 motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0 historical_motion_policy=window_overlap_required",
              aggregateDiagnostics.candidates,
              aggregateDiagnostics.eligible,
              aggregateDiagnostics.evaluated,
              aggregateDiagnostics.tooShort,
              aggregateDiagnostics.notOvernight,
              aggregateDiagnostics.hrTooHigh,
              aggregateDiagnostics.workoutLike,
              motionSource,
              motionHintSessions,
              motionHintTotal,
              motionShortStats.count,
              formatDouble(motionShortStats.mean),
              formatDouble(motionShortStats.min),
              formatDouble(motionShortStats.max),
              motionShortStats.overOne)
        for aggregate in aggregateSleepCandidates(rest: rest, calendar: Calendar.current).prefix(7) {
            WHOOPDebugLog("WHOOPDBG broken_sleep_candidate day=%@ sessions=%d duration_s=%.0f span_s=%.0f max_gap_s=%.0f avg_hr=%d peak_hr=%d rest_hr=%d confidence=%@ reason=%@ motion_source=%@ motion_hints=%d motion_hint_kinds=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0 historical_motion_status=%@ historical_motion_reason=%@ historical_motion_rows=%d historical_motion_validated_rows=%d historical_motion_coverage_s=%d historical_motion_archive_first_unix=%d historical_motion_archive_last_unix=%d historical_motion_nearest_separation_s=%d historical_motion_mean_delta=%@ historical_motion_p95_delta=%@ historical_motion_mag_stddev=%@ historical_motion_validated=%d",
                  formatter.string(from: aggregate.day),
                  aggregate.sessions,
                  aggregate.duration,
                  aggregate.span,
                  aggregate.maxGap,
                  aggregate.avgHR,
                  aggregate.peakHR,
                  aggregate.restingHR,
                  aggregate.confidence.rawValue,
                  aggregate.reason,
                  aggregate.motionEvidenceSource,
                  aggregate.motionHintCount,
                  aggregate.motionHintKinds,
                  aggregate.motionEvidenceValidated ? 1 : 0,
                  aggregate.motionShortCount,
                  formatDouble(aggregate.motionShortMean),
                  formatDouble(aggregate.motionShortMin),
                  formatDouble(aggregate.motionShortMax),
                  aggregate.motionShortOverOneCount,
                  aggregate.historicalMotionStatus,
                  aggregate.historicalMotionReason,
                  aggregate.historicalMotionRows,
                  aggregate.historicalMotionValidatedRows,
                  aggregate.historicalMotionCoverageSeconds,
                  aggregate.historicalMotionArchiveFirstUnix,
                  aggregate.historicalMotionArchiveLastUnix,
                  aggregate.historicalMotionNearestSeparationSeconds,
                  formatDouble(aggregate.historicalMotionMeanVectorDelta),
                  formatDouble(aggregate.historicalMotionP95VectorDelta),
                  formatDouble(aggregate.historicalMotionMagnitudeStdDev),
                  aggregate.historicalMotionValidated ? 1 : 0)
        }
        for session in sessions.prefix(10) {
            let restingEvidence = session.restingHRForBaseline(rest: rest, maxHR: profile.maxHR)
            WHOOPDebugLog("WHOOPDBG resting_source label=%@ value=%d source=%@ stable_10th=%d sleep_5th=%d motion_source=%@ motion_hints=%d motion_hint_kinds=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0",
                  session.label,
                  restingEvidence.value,
                  restingEvidence.source,
                  session.restingStable,
                  session.sleepCandidateRestingHR,
                  session.motionEvidenceSourceValue,
                  session.motionHintCountValue,
                  session.motionHintKindsValue,
                  session.motionEvidenceValidatedValue ? 1 : 0,
                  session.motionShortCountValue,
                  formatDouble(session.motionShortMeanValue),
                  formatDouble(session.motionShortMinValue),
                  formatDouble(session.motionShortMaxValue),
                  session.motionShortOverOneCountValue)
        }
        for session in sessions.prefix(10) {
            let readiness = session.workoutReadiness(rest: rest, maxHR: profile.maxHR)
            WHOOPDebugLog("WHOOPDBG workout_readiness label=%@ status=%@ reason=%@ ready=%d duration_s=%.0f observed_duration_s=%.0f dropped_gap_s=%.0f max_gap_s=%.1f gap_count=%d avg_hr=%d peak_hr=%d p90_hr=%d p95_hr=%d p99_hr=%d threshold_hr=%d threshold_gap_bpm=%d samples_above_threshold=%d samples_above_borderline=%d avg_over_rest=%d peak_over_rest=%d elevated_s=%.0f elevated_fraction=%.2f required_elevated_s=%.0f hr_distribution_below_workout_band=%d next_action=%@ hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f",
                  session.label,
                  readiness.status,
                  readiness.reason,
                  readiness.ready ? 1 : 0,
                  readiness.duration,
                  readiness.observedDuration,
                  readiness.droppedGapSeconds,
                  readiness.maxSampleGap,
                  readiness.gapCount,
                  readiness.avgHR,
                  readiness.peakHR,
                  readiness.p90HR,
                  readiness.p95HR,
                  readiness.p99HR,
                  readiness.thresholdHR,
                  readiness.thresholdGapBPM,
                  readiness.samplesAboveThreshold,
                  readiness.samplesAboveBorderline,
                  readiness.avgOverRest,
                  readiness.peakOverRest,
                  readiness.elevatedSeconds,
                  readiness.elevatedFraction,
                  readiness.requiredElevatedSeconds,
                  readiness.hrDistributionBelowWorkoutBand ? 1 : 0,
                  readiness.nextAction,
                  session.hrRaw2A37Value,
                  session.hrAcceptedValue,
                  session.hrZeroValue,
                  session.hrArtifactHeldValue,
                  session.hrArtifactDroppedValue,
                  session.hrRawGapsValue,
                  session.hrAcceptedGapsValue,
                  session.hrMaxRawGapValue,
                  session.hrMaxAcceptedGapValue)
            WHOOPDebugLog("WHOOPDBG workout_sustained label=%@ longest_bout_s=%.0f required_bout_s=%.0f elevated_s=%.0f required_elevated_s=%.0f observed_duration_s=%.0f dropped_gap_s=%.0f max_gap_s=%.1f gap_count=%d decision=%@ reason=%@",
                  session.label,
                  readiness.longestElevatedBout,
                  readiness.requiredElevatedBout,
                  readiness.elevatedSeconds,
                  readiness.requiredElevatedSeconds,
                  readiness.observedDuration,
                  readiness.droppedGapSeconds,
                  readiness.maxSampleGap,
                  readiness.gapCount,
                  readiness.status,
                  readiness.reason)
        }
    }

    func scheduleSleepValidationFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-verify-sleep") else { return }
        let label = value(after: "--whoop-verify-sleep-label", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let delay = doubleValue(after: "--whoop-verify-sleep-after",
                                in: arguments,
                                default: 0,
                                range: 0...86_400)
        WHOOPDebugLog("WHOOPDBG sleep_validation schedule delay_s=%.1f label=%@", delay, label ?? "latest")
        Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            logSleepValidation(label: label?.isEmpty == false ? label : nil)
        }
    }

    private func logSleepValidation(label: String?) {
        let rest = baseline.restingInt ?? 60
        let calendar = Calendar.current
        if label == nil,
           let aggregate = aggregateSleepCandidates(rest: rest, calendar: calendar).first {
            let startHour = calendar.component(.hour, from: aggregate.start)
            let endHour = calendar.component(.hour, from: aggregate.end)
            let matchedLabel = aggregate.sessions > 1
                ? "aggregate_sleep_\(aggregate.sessions)_chunks"
                : "aggregate_sleep_single_chunk"
            let validationReady = aggregate.motionEvidenceValidated && aggregate.confidence != .low
            let validationReason = validationReady
                ? "aggregate_overnight_low_hr_window"
                : sleepEvidenceBlocker(for: aggregate)
            WHOOPDebugLog("WHOOPDBG sleep_validation status=%@ reason=%@ label=%@ matched_label=%@ source=aggregate_sleep duration_s=%.0f span_s=%.0f max_gap_s=%.0f samples=%d avg_hr=%d peak_hr=%d rest_hr=%d sleep_rhr=%d start_hour=%d end_hour=%d overnight=1 low_hr=1 sleep_candidates_matching=%d confidence=%@ fallback_available=1 fallback_source=%@ fallback_duration_s=%.0f fallback_span_s=%.0f fallback_chunks=%d fallback_diagnostic_only=1 motion_source=%@ motion_hints=%d motion_hint_kinds=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0 historical_motion_status=%@ historical_motion_reason=%@ historical_motion_rows=%d historical_motion_validated_rows=%d historical_motion_coverage_s=%d historical_motion_archive_first_unix=%d historical_motion_archive_last_unix=%d historical_motion_nearest_separation_s=%d historical_motion_mean_delta=%@ historical_motion_p95_delta=%@ historical_motion_mag_stddev=%@ historical_motion_validated=%d detail=%@",
                  validationReady ? "ready" : "learning",
                  validationReason,
                  "latest",
                  matchedLabel,
                  aggregate.duration,
                  aggregate.span,
                  aggregate.maxGap,
                  aggregate.samples,
                  aggregate.avgHR,
                  aggregate.peakHR,
                  rest,
                  aggregate.restingHR,
                  startHour,
                  endHour,
                  aggregateSleepCandidates(rest: rest, calendar: calendar).count,
                  aggregate.confidence.rawValue,
                  aggregate.sessions > 1 ? "hr_only_fragmented_sleep" : "hr_only_sleep",
                  aggregate.duration,
                  aggregate.span,
                  aggregate.sessions,
                  aggregate.motionEvidenceSource,
                  aggregate.motionHintCount,
                  aggregate.motionHintKinds,
                  aggregate.motionEvidenceValidated ? 1 : 0,
                  aggregate.motionShortCount,
                  formatDouble(aggregate.motionShortMean),
                  formatDouble(aggregate.motionShortMin),
                  formatDouble(aggregate.motionShortMax),
                  aggregate.motionShortOverOneCount,
                  aggregate.historicalMotionStatus,
                  aggregate.historicalMotionReason,
                  aggregate.historicalMotionRows,
                  aggregate.historicalMotionValidatedRows,
                  aggregate.historicalMotionCoverageSeconds,
                  aggregate.historicalMotionArchiveFirstUnix,
                  aggregate.historicalMotionArchiveLastUnix,
                  aggregate.historicalMotionNearestSeparationSeconds,
                  formatDouble(aggregate.historicalMotionMeanVectorDelta),
                  formatDouble(aggregate.historicalMotionP95VectorDelta),
                  formatDouble(aggregate.historicalMotionMagnitudeStdDev),
                  aggregate.historicalMotionValidated ? 1 : 0,
                  aggregate.reason)
            return
        }
        let matching = sessions
            .filter { session in
                guard let label, !label.isEmpty else { return true }
                return session.label == label || session.label.hasPrefix("\(label) ")
            }
            .sorted {
                if abs($0.duration - $1.duration) > 60 {
                    return $0.duration > $1.duration
                }
                return $0.start > $1.start
            }
        guard let session = matching.first else {
            WHOOPDebugLog("WHOOPDBG sleep_validation status=learning reason=no_saved_session label=%@ sessions=%d rest_hr=%d max_hr=%d",
                  label ?? "latest", sessions.count, rest, profile.maxHR)
            return
        }
        let startHour = calendar.component(.hour, from: session.start)
        let endHour = calendar.component(.hour, from: session.end)
        let overnight = startHour >= 20 || startHour <= 3 || endHour <= 10
        let lowHR = session.avg <= rest + 15 && session.peak <= rest + 35
        let durationOK = session.duration >= 3 * 60 * 60
        let detection = session.detectedActivity(rest: rest, maxHR: profile.maxHR, calendar: calendar)
        let isSleep = detection?.kind == .sleepCandidate
        let motionReady = session.motionEvidenceValidatedValue && detection?.confidence != .low
        let status = isSleep && motionReady ? "ready" : "learning"
        let reason: String
        if !durationOK {
            reason = "duration_below_3h"
        } else if !overnight {
            reason = "not_overnight"
        } else if !lowHR {
            reason = "hr_not_low"
        } else if !isSleep {
            reason = "detector_not_sleep"
        } else if !motionReady {
            reason = "sleep_low_confidence_motion_unvalidated"
        } else {
            reason = "overnight_low_hr_window"
        }
        WHOOPDebugLog("WHOOPDBG sleep_validation status=%@ reason=%@ label=%@ matched_label=%@ duration_s=%.0f samples=%d avg_hr=%d peak_hr=%d rest_hr=%d sleep_rhr=%d start_hour=%d end_hour=%d overnight=%d low_hr=%d sleep_candidates_matching=%d confidence=%@ motion_source=%@ motion_hints=%d motion_hint_kinds=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0",
              status,
              reason,
              label ?? "latest",
              session.label,
              session.duration,
              session.points.count,
              session.avg,
              session.peak,
              rest,
              session.sleepCandidateRestingHR,
              startHour,
              endHour,
              overnight ? 1 : 0,
              lowHR ? 1 : 0,
              matching.filter {
                  $0.detectedActivity(rest: rest, maxHR: profile.maxHR, calendar: calendar)?.kind == .sleepCandidate
              }.count,
              detection?.confidence.rawValue ?? "none",
              session.motionEvidenceSourceValue,
              session.motionHintCountValue,
              session.motionHintKindsValue,
              session.motionEvidenceValidatedValue ? 1 : 0,
              session.motionShortCountValue,
              formatDouble(session.motionShortMeanValue),
              formatDouble(session.motionShortMinValue),
              formatDouble(session.motionShortMaxValue),
              session.motionShortOverOneCountValue)
    }

    func scheduleWorkoutValidationFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let label = value(after: "--whoop-verify-workout-label", in: arguments),
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let delay = doubleValue(after: "--whoop-verify-workout-after",
                                in: arguments,
                                default: 0,
                                range: 0...86_400)
        WHOOPDebugLog("WHOOPDBG workout_validation schedule delay_s=%.1f label=%@", delay, label)
        Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            logWorkoutValidation(label: label)
        }
    }

    private func logWorkoutValidation(label: String) {
        let rest = baseline.restingInt ?? 60
        let requestedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = sessions
            .filter { labelMatches($0.label, requested: requestedLabel) }
            .sorted { $0.duration > $1.duration }
        let aggregateMatching = aggregateWorkoutCandidates(rest: rest, maxHR: profile.maxHR, calendar: Calendar.current)
            .filter { aggregate in
                aggregate.labels.contains { labelMatches($0, requested: requestedLabel) }
                    || labelMatches(aggregate.label, requested: requestedLabel)
            }
        let singleCandidates = matching.map { session in
            (source: "single_session",
             chunks: 1,
             span: session.duration,
             label: session.label,
             duration: session.duration,
             samples: session.points.count,
             avgHR: session.avg,
             peakHR: session.peak,
             readiness: session.workoutReadiness(rest: rest, maxHR: profile.maxHR))
        }
        let aggregateCandidates = aggregateMatching.map { aggregate in
            (source: "aggregate_chunks",
             chunks: aggregate.sessions,
             span: aggregate.span,
             label: aggregate.label,
             duration: aggregate.duration,
             samples: aggregate.samples,
             avgHR: aggregate.avgHR,
             peakHR: aggregate.peakHR,
             readiness: aggregate.readiness)
        }
        let candidates = singleCandidates + aggregateCandidates
        guard let best = candidates.sorted(by: { lhs, rhs in
            if lhs.readiness.ready != rhs.readiness.ready { return lhs.readiness.ready }
            let lhsHasElevatedEvidence = lhs.readiness.elevatedSeconds > 0 || lhs.peakHR >= lhs.readiness.thresholdHR
            let rhsHasElevatedEvidence = rhs.readiness.elevatedSeconds > 0 || rhs.peakHR >= rhs.readiness.thresholdHR
            if lhsHasElevatedEvidence != rhsHasElevatedEvidence { return lhsHasElevatedEvidence }
            if lhs.readiness.longestElevatedBout != rhs.readiness.longestElevatedBout {
                return lhs.readiness.longestElevatedBout > rhs.readiness.longestElevatedBout
            }
            if lhs.readiness.elevatedSeconds != rhs.readiness.elevatedSeconds {
                return lhs.readiness.elevatedSeconds > rhs.readiness.elevatedSeconds
            }
            if lhs.peakHR != rhs.peakHR {
                return lhs.peakHR > rhs.peakHR
            }
            if lhs.readiness.observedDuration != rhs.readiness.observedDuration {
                return lhs.readiness.observedDuration > rhs.readiness.observedDuration
            }
            return lhs.readiness.maxSampleGap < rhs.readiness.maxSampleGap
        }).first else {
            WHOOPDebugLog("WHOOPDBG workout_validation status=learning reason=no_saved_session label=%@ sessions=%d rest_hr=%d max_hr=%d",
                  requestedLabel, sessions.count, rest, profile.maxHR)
            return
        }
        let readiness = best.readiness
        let status = readiness.ready ? "ready" : "learning"
        let reason = status == "ready" ? "sustained_elevated_hr" : readiness.reason
        let readyMatches = candidates.filter { $0.readiness.ready }.count
        WHOOPDebugLog("WHOOPDBG workout_validation status=%@ reason=%@ primary_blocker=%@ near_miss=%d near_miss_reason=%@ strength_candidate=%d strength_candidate_reason=%@ strength_diagnostic_only=1 next_action=%@ stream_coverage_percent=%d label=%@ matched_label=%@ source=%@ chunks=%d span_s=%.0f duration_s=%.0f observed_duration_s=%.0f dropped_gap_s=%.0f max_gap_s=%.1f gap_count=%d samples=%d avg_hr=%d peak_hr=%d p90_hr=%d p95_hr=%d p99_hr=%d rest_hr=%d max_hr=%d threshold_hr=%d threshold_gap_bpm=%d samples_above_threshold=%d samples_above_borderline=%d elevated_s=%.0f required_elevated_s=%.0f longest_bout_s=%.0f required_bout_s=%.0f borderline_threshold_hr=%d borderline_elevated_s=%.0f borderline_longest_bout_s=%.0f borderline_diagnostic_only=1 workouts_matching=%d aggregate_candidates=%d",
              status,
              reason,
              readiness.primaryBlocker,
              readiness.nearMiss ? 1 : 0,
              readiness.nearMissReason,
              readiness.strengthCandidate ? 1 : 0,
              readiness.strengthCandidateReason,
              readiness.nextAction,
              readiness.streamCoveragePercent,
              requestedLabel,
              best.label,
              best.source,
              best.chunks,
              best.span,
              best.duration,
              readiness.observedDuration,
              readiness.droppedGapSeconds,
              readiness.maxSampleGap,
              readiness.gapCount,
              best.samples,
              best.avgHR,
              best.peakHR,
              readiness.p90HR,
              readiness.p95HR,
              readiness.p99HR,
              rest,
              profile.maxHR,
              readiness.thresholdHR,
              readiness.thresholdGapBPM,
              readiness.samplesAboveThreshold,
              readiness.samplesAboveBorderline,
              readiness.elevatedSeconds,
              readiness.requiredElevatedSeconds,
              readiness.longestElevatedBout,
              readiness.requiredElevatedBout,
              readiness.borderlineThresholdHR,
              readiness.borderlineElevatedSeconds,
              readiness.borderlineLongestBout,
              readyMatches,
              aggregateMatching.count)
    }

    private func labelMatches(_ candidate: String, requested: String) -> Bool {
        candidate == requested || candidate.hasPrefix("\(requested) ")
    }

    @discardableResult
    func writeSessionBackup(label: String = "manual") -> URL? {
        let envelope = SessionBackupEnvelope(schema: 1,
                                             createdAt: Date(),
                                             app: "Atria.local",
                                             sessions: sessions,
                                             baseline: baseline,
                                             profile: profile)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(envelope)
            let backupDir = sessionBackupDirectory()
            try FileManager.default.createDirectory(at: backupDir,
                                                    withIntermediateDirectories: true)
            let safeLabel = label.replacingOccurrences(of: "[^A-Za-z0-9_-]",
                                                       with: "-",
                                                       options: .regularExpression)
            let timestamp = SessionStore.backupTimestamp()
            let filename = "atria-sessions-\(timestamp)-\(safeLabel).json"
            let backupURL = backupDir.appendingPathComponent(filename)
            try data.write(to: backupURL, options: .atomic)
            let digest = backupContentDigest(sessions: sessions,
                                             baseline: baseline,
                                             profile: profile) ?? "error"
            WHOOPDebugLog("WHOOPDBG session_backup path=%@ sessions=%d rr_samples=%d motion_short_samples=%d hr_raw_2a37=%d hr_accepted=%d hr_raw_gaps=%d hr_accepted_gaps=%d bytes=%d schema=%d digest=%@",
                  backupRelativePath(for: backupURL),
                  sessions.count,
                  totalRRSamples(in: sessions),
                  totalMotionShortSamples(in: sessions),
                  totalHRRaw2A37(in: sessions),
                  totalHRAccepted(in: sessions),
                  totalHRRawGaps(in: sessions),
                  totalHRAcceptedGaps(in: sessions),
                  data.count,
                  envelope.schema,
                  digest)
            pruneAutomaticBackups(in: backupDir, keep: 24)
            return backupURL
        } catch {
            WHOOPDebugLog("WHOOPDBG session_backup_error error=%@", String(describing: error))
            return nil
        }
    }

    func writeSessionBackupFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-backup-sessions") else { return }
        _ = writeSessionBackup(label: "debug")
    }

    func clearReferenceInputsFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-clear-reference-inputs") else { return }
        let referenceDir = url.deletingLastPathComponent().appendingPathComponent("atria-reference")
        let targets = [
            referenceDir.appendingPathComponent("rr-reference.csv"),
            referenceDir.appendingPathComponent("hr-reference.csv")
        ]
        var removed = 0
        var missing = 0
        var failures: [String] = []
        for target in targets {
            guard FileManager.default.fileExists(atPath: target.path) else {
                missing += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: target)
                removed += 1
            } catch {
                failures.append("\(target.lastPathComponent):\(String(describing: error))")
            }
        }
        clearHRReferenceValidation(reason: "reference_inputs_cleared")
        WHOOPDebugLog("WHOOPDBG reference_inputs_clear status=%@ removed=%d missing=%d failed=%d paths=rr-reference.csv,hr-reference.csv error=%@",
              failures.isEmpty ? "ok" : "partial",
              removed,
              missing,
              failures.count,
              failures.isEmpty ? "none" : failures.joined(separator: "|"))
    }

    func exportRRReferencePackageFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-export-rr-reference-package") else { return }
        WHOOPDebugLog("WHOOPDBG rr_reference_package status=started sessions=%d rr_samples=%d external_reference_required=1 reference_validated=0",
              sessions.count,
              totalRRSamples(in: sessions))
        _ = exportRRReferencePackage()
    }

    func validateRRReferenceFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-validate-rr-reference") else { return }
        WHOOPDebugLog("WHOOPDBG rr_reference_validation status=started sessions=%d rr_samples=%d expected_reference=Documents/atria-reference/rr-reference.csv tolerance_ms=5 external_reference_required=1",
              sessions.count,
              totalRRSamples(in: sessions))
        _ = validateRRReferenceFromDocuments()
    }

    func exportRRReferencePackageForUI() -> URL? {
        WHOOPDebugLog("WHOOPDBG rr_reference_export_ui status=started source=dashboard external_reference_required=1 tolerance_ms=5")
        guard let exported = exportRRReferencePackage() else {
            WHOOPDebugLog("WHOOPDBG rr_reference_export_ui status=learning reason=no_exportable_rr_reference source=dashboard")
            return nil
        }
        WHOOPDebugLog("WHOOPDBG rr_reference_export_ui status=ok csv=%@ manifest=%@ share=csv source=dashboard",
              "Documents/atria-rr-reference-packages/\(exported.csv.lastPathComponent)",
              "Documents/atria-rr-reference-packages/\(exported.manifest.lastPathComponent)")
        return exported.csv
    }

    @discardableResult
    func importRRReferenceCSVForUI(from sourceURL: URL) -> Bool {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let referenceDir = url.deletingLastPathComponent().appendingPathComponent("atria-reference")
        let targetURL = referenceDir.appendingPathComponent("rr-reference.csv")
        do {
            try FileManager.default.createDirectory(at: referenceDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber)?.intValue ?? 0
            WHOOPDebugLog("WHOOPDBG rr_reference_import status=ok source=dashboard filename=%@ path=Documents/atria-reference/rr-reference.csv bytes=%d validation_triggered=1 external_reference_required=1 tolerance_ms=5",
                  sourceURL.lastPathComponent,
                  bytes)
            return validateRRReferenceFromDocuments()
        } catch {
            WHOOPDebugLog("WHOOPDBG rr_reference_import status=error source=dashboard filename=%@ path=Documents/atria-reference/rr-reference.csv validation_triggered=0 error=%@",
                  sourceURL.lastPathComponent,
                  String(describing: error))
            return false
        }
    }

    func exportHRReferencePackageFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-export-hr-reference-package") else { return }
        let hrSamples = sessions.reduce(0) { $0 + $1.points.count }
        WHOOPDebugLog("WHOOPDBG hr_reference_package status=started sessions=%d hr_samples=%d external_reference_required=1 reference_validated=0 gate_d_pass=0",
              sessions.count,
              hrSamples)
        _ = exportHRReferencePackage()
    }

    func validateHRReferenceFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-validate-hr-reference") else { return }
        let hrSamples = sessions.reduce(0) { $0 + $1.points.count }
        WHOOPDebugLog("WHOOPDBG hr_reference_validation status=started sessions=%d hr_samples=%d expected_reference=Documents/atria-reference/hr-reference.csv tolerance_bpm=2 max_pair_age_s=5 external_reference_required=1",
              sessions.count,
              hrSamples)
        _ = validateHRReferenceFromDocuments()
    }

    func exportHRReferencePackageForUI() -> URL? {
        WHOOPDebugLog("WHOOPDBG hr_reference_export_ui status=started source=dashboard external_reference_required=1")
        guard let exported = exportHRReferencePackage() else {
            WHOOPDebugLog("WHOOPDBG hr_reference_export_ui status=learning reason=no_exportable_hr_reference source=dashboard")
            return nil
        }
        WHOOPDebugLog("WHOOPDBG hr_reference_export_ui status=ok csv=%@ manifest=%@ share=csv source=dashboard",
              "Documents/atria-hr-reference-packages/\(exported.csv.lastPathComponent)",
              "Documents/atria-hr-reference-packages/\(exported.manifest.lastPathComponent)")
        return exported.csv
    }

    @discardableResult
    func importHRReferenceCSVForUI(from sourceURL: URL) -> Bool {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let referenceDir = url.deletingLastPathComponent().appendingPathComponent("atria-reference")
        let targetURL = referenceDir.appendingPathComponent("hr-reference.csv")
        do {
            try FileManager.default.createDirectory(at: referenceDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber)?.intValue ?? 0
            WHOOPDebugLog("WHOOPDBG hr_reference_import status=ok source=dashboard filename=%@ path=Documents/atria-reference/hr-reference.csv bytes=%d validation_triggered=1 external_reference_required=1",
                  sourceURL.lastPathComponent,
                  bytes)
            return validateHRReferenceFromDocuments()
        } catch {
            WHOOPDebugLog("WHOOPDBG hr_reference_import status=error source=dashboard filename=%@ path=Documents/atria-reference/hr-reference.csv validation_triggered=0 error=%@",
                  sourceURL.lastPathComponent,
                  String(describing: error))
            return false
        }
    }

    @discardableResult
    private func exportRRReferencePackage() -> (csv: URL, manifest: URL)? {
        let rrSamples = totalRRSamples(in: sessions)
        guard let best = bestSavedRRReferenceWindow() else {
            let reason = rrSamples > 0 ? "no_300s_window" : "no_saved_rr"
            WHOOPDebugLog("WHOOPDBG rr_reference_package status=learning reason=%@ sessions=%d rr_samples=%d external_reference_required=1 reference_validated=0",
                  reason,
                  sessions.count,
                  rrSamples)
            return nil
        }

        guard best.ready else {
            WHOOPDebugLog("WHOOPDBG rr_reference_package status=learning reason=%@ session_label=%@ raw=%d kept=%d conf=%d window_s=300 max_rr_gap_s=%.1f external_reference_required=1 reference_validated=0",
                  best.reason,
                  best.session.label,
                  best.snapshot.raw,
                  best.snapshot.kept,
                  best.snapshot.confidencePercent,
                  best.strictGap)
            return nil
        }

        let relativeDir = "Documents/atria-rr-reference-packages"
        let exportDir = url.deletingLastPathComponent().appendingPathComponent("atria-rr-reference-packages")
        let timestamp = SessionStore.backupTimestamp()
        let safeLabel = safeFileStem(best.session.label)
        let base = "atria-rr-reference-\(timestamp)-\(safeLabel)"
        let csvURL = exportDir.appendingPathComponent("\(base).csv")
        let manifestURL = exportDir.appendingPathComponent("\(base)-manifest.json")
        let iso = ISO8601DateFormatter()

        do {
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            let csv = rrReferenceCSV(for: best, isoFormatter: iso)
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)

            let validationContract: [String: Any] = [
                "externalReferencePath": "Documents/atria-reference/rr-reference.csv",
                "externalReferenceRequired": true,
                "mustBeIndependent": true,
                "selfComparisonRejected": true,
                "acceptedRRColumns": ["rr_ms", "rr", "ibi_ms", "ibi", "interval_ms", "interval", "nn_ms", "nn", "value"],
                "acceptedTimeColumns": ["elapsed_ms", "time_ms", "timestamp_ms", "t_ms", "seconds", "time_s", "timestamp", "t"],
                "timeColumnUnits": "columns containing ms are milliseconds; seconds/time_s/timestamp/t are seconds",
                "missingTimeColumnPolicy": "cumulative_rr_ms",
                "windowAlignment": "reference file must cover the same uninterrupted 300-second physiological window as windowStart/windowEnd",
                "windowSeconds": 300,
                "minCorrectedBeats": 240,
                "minConfidencePercent": 75,
                "maxRRGapSeconds": HRVSnapshot.maxReadyRRGapSeconds,
                "rrMinMs": 300,
                "rrMaxMs": 2000,
                "maxDeltaRRPercent": 20,
                "rmssdToleranceMs": 5.0,
                "validationCommand": "./reference_validate.sh <label> --rr <independent-rr.csv> --require-rr-pass"
            ]

            let manifest: [String: Any] = [
                "schema": 2,
                "createdAt": iso.string(from: Date()),
                "source": "saved_rr_points",
                "csv": "\(relativeDir)/\(csvURL.lastPathComponent)",
                "sessionLabel": best.session.label,
                "sessionStart": iso.string(from: best.session.start),
                "sessionEnd": iso.string(from: best.session.end),
                "windowStart": iso.string(from: best.windowStart),
                "windowEnd": iso.string(from: best.windowEnd),
                "windowSeconds": 300,
                "raw": best.snapshot.raw,
                "kept": best.snapshot.kept,
                "confidencePercent": best.snapshot.confidencePercent,
                "maxRRGapSeconds": best.strictGap,
                "rejectedOutOfRange": best.snapshot.rejectedOutOfRange,
                "rejectedDeltaOver20Percent": best.snapshot.rejectedDeltaOver20Percent,
                "interpolated": best.snapshot.interpolated,
                "rmssdMs": best.snapshot.rmssd,
                "sdnnMs": best.snapshot.sdnn,
                "pnn50Percent": best.snapshot.pnn50,
                "lnRmssd": best.snapshot.lnRMSSD,
                "respiratoryRateBPM": best.snapshot.respiratoryRate ?? NSNull(),
                "externalReferenceRequired": true,
                "referenceValidated": false,
                "readyForExternalReference": true,
                "gateBPassed": false,
                "validation": validationContract
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: manifestURL, options: .atomic)

            WHOOPDebugLog("WHOOPDBG rr_reference_package status=ok csv=%@ manifest=%@ session_label=%@ raw=%d kept=%d conf=%d window_s=300 max_rr_gap_s=%.1f rmssd=%.1f sdnn=%.1f pnn50=%.1f lnrmssd=%.2f external_reference_required=1 reference_validated=0 reference_path=Documents/atria-reference/rr-reference.csv tolerance_ms=5 self_compare_rejected=1 schema=2",
                  "\(relativeDir)/\(csvURL.lastPathComponent)",
                  "\(relativeDir)/\(manifestURL.lastPathComponent)",
                  best.session.label,
                  best.snapshot.raw,
                  best.snapshot.kept,
                  best.snapshot.confidencePercent,
                  best.strictGap,
                  best.snapshot.rmssd,
                  best.snapshot.sdnn,
                  best.snapshot.pnn50,
                  best.snapshot.lnRMSSD)
            return (csvURL, manifestURL)
        } catch {
            WHOOPDebugLog("WHOOPDBG rr_reference_package status=error reason=write_failed error=%@", String(describing: error))
            return nil
        }
    }

    @discardableResult
    private func validateRRReferenceFromDocuments() -> Bool {
        guard let best = bestSavedRRReferenceWindow(), best.ready else {
            let reason = totalRRSamples(in: sessions) > 0 ? "no_ready_whoop_rr_window" : "no_saved_rr"
            WHOOPDebugLog("WHOOPDBG rr_reference_validation status=learning reason=%@ gate_b_pass=0 external_reference=0 reference_validated=0",
                  reason)
            return false
        }

        let reference = resolveReferenceCSV(kind: "rr", preferredFileName: "rr-reference.csv")
        guard let referenceURL = reference.url else {
            WHOOPDebugLog("WHOOPDBG rr_reference_validation status=missing reason=%@ path=Documents/atria-reference/rr-reference.csv candidate_count=%d candidates=%@ whoop_ready=1 whoop_raw=%d whoop_kept=%d whoop_conf=%d whoop_rmssd=%.1f gate_b_pass=0 external_reference=0 reference_validated=0 action=place_exactly_one_independent_rr_csv_in_Documents/atria-reference_or_push_rr-reference.csv",
                  reference.reason,
                  reference.candidateCount,
                  reference.candidates.isEmpty ? "none" : reference.candidates.joined(separator: "|"),
                  best.snapshot.raw,
                  best.snapshot.kept,
                  best.snapshot.confidencePercent,
                  best.snapshot.rmssd)
            return false
        }
        if reference.autoSelected {
            WHOOPDebugLog("WHOOPDBG rr_reference_validation_reference status=auto_selected preferred=rr-reference.csv selected=%@ candidate_count=%d external_reference_required=1",
                  referenceURL.lastPathComponent,
                  reference.candidateCount)
        }

        do {
            let referenceText = try String(contentsOf: referenceURL, encoding: .utf8)
            let selfCSV = rrReferenceCSV(for: best, isoFormatter: ISO8601DateFormatter())
            if normalizeReferenceCSV(referenceText) == normalizeReferenceCSV(selfCSV) {
                WHOOPDebugLog("WHOOPDBG rr_reference_validation status=fail reason=same_content_not_external_reference source=Documents/atria-reference/%@ gate_b_pass=0 external_reference=0 reference_validated=0 action=provide_independent_rr_ibi_recording",
                      referenceURL.lastPathComponent)
                return false
            }
            let reference = try parseExternalRRReferenceCSV(at: referenceURL)
            let referenceScore = scoreExternalRR(reference, windowSeconds: 300)
            let delta = referenceScore.rmssd.map { abs(best.snapshot.rmssd - $0) }
            let metricPassed = best.ready
                && referenceScore.ready
                && delta.map { $0 <= 5.0 } == true
            WHOOPDebugLog("WHOOPDBG rr_reference_validation status=%@ reason=%@ whoop_ready=%d whoop_raw=%d whoop_kept=%d whoop_conf=%d whoop_gap_s=%.1f whoop_rmssd=%.1f reference_ready=%d reference_raw=%d reference_kept=%d reference_conf=%d reference_gap_s=%.1f reference_rmssd=%.1f rmssd_delta_ms=%.1f tolerance_ms=5 gate_b_pass=%d external_reference=1 reference_validated=%d source=Documents/atria-reference/%@",
                  metricPassed ? "pass" : "fail",
                  metricPassed ? "ready" : rrReferenceFailureReason(whoop: best, reference: referenceScore, delta: delta),
                  best.ready ? 1 : 0,
                  best.snapshot.raw,
                  best.snapshot.kept,
                  best.snapshot.confidencePercent,
                  best.strictGap,
                  best.snapshot.rmssd,
                  referenceScore.ready ? 1 : 0,
                  referenceScore.raw,
                  referenceScore.kept,
                  referenceScore.confidencePercent,
                  referenceScore.maxGap,
                  referenceScore.rmssd ?? 0,
                  delta ?? -1,
                  metricPassed ? 1 : 0,
                  metricPassed ? 1 : 0,
                  referenceURL.lastPathComponent)
            if metricPassed {
                persistRRReferenceValidation(for: best.session,
                                             rmssd: best.snapshot.rmssd,
                                             sdnn: best.snapshot.sdnn,
                                             delta: delta ?? 0)
            }
            return metricPassed
        } catch {
            WHOOPDebugLog("WHOOPDBG rr_reference_validation status=error reason=parse_failed error=%@ gate_b_pass=0 external_reference=1 reference_validated=0",
                  String(describing: error))
            return false
        }
    }

    @discardableResult
    private func validateHRReferenceFromDocuments() -> Bool {
        let hrSamples = sessions.reduce(0) { $0 + $1.points.count }
        guard let best = bestSavedHRReferenceSession() else {
            let reason = hrSamples > 0 ? "no_60s_saved_hr_window" : "no_saved_hr"
            recordHRReferenceAttempt(status: "learning",
                                     reason: reason,
                                     source: "missing",
                                     referenceSamples: 0,
                                     comparison: nil,
                                     session: nil,
                                     invalidateExistingValidation: false)
            WHOOPDebugLog("WHOOPDBG hr_reference_validation status=learning reason=%@ gate_d_pass=0 external_reference=0 reference_validated=0",
                  reason)
            return false
        }

        let bpms = best.samples.map(\.bpm)
        let avg = bpms.isEmpty ? 0 : Double(bpms.reduce(0, +)) / Double(bpms.count)
        let peak = bpms.max() ?? 0
        let resting = bpms.min() ?? 0
        let reference = resolveReferenceCSV(kind: "hr", preferredFileName: "hr-reference.csv")
        guard let referenceURL = reference.url else {
            recordHRReferenceAttempt(status: "missing",
                                     reason: reference.reason,
                                     source: "missing",
                                     referenceSamples: 0,
                                     comparison: nil,
                                     session: best.session,
                                     invalidateExistingValidation: false)
            WHOOPDebugLog("WHOOPDBG hr_reference_validation status=missing reason=%@ path=Documents/atria-reference/hr-reference.csv candidate_count=%d candidates=%@ whoop_ready=1 whoop_samples=%d whoop_duration_s=%.0f whoop_avg_hr=%.1f whoop_peak_hr=%d whoop_resting_hr=%d tolerance_bpm=2 gate_d_pass=0 external_reference=0 reference_validated=0 action=place_exactly_one_independent_hr_csv_in_Documents/atria-reference_or_push_hr-reference.csv",
                  reference.reason,
                  reference.candidateCount,
                  reference.candidates.isEmpty ? "none" : reference.candidates.joined(separator: "|"),
                  best.samples.count,
                  best.session.duration,
                  avg,
                  peak,
                  resting)
            return false
        }
        if reference.autoSelected {
            WHOOPDebugLog("WHOOPDBG hr_reference_validation_reference status=auto_selected preferred=hr-reference.csv selected=%@ candidate_count=%d external_reference_required=1",
                  referenceURL.lastPathComponent,
                  reference.candidateCount)
        }

        do {
            let referenceText = try String(contentsOf: referenceURL, encoding: .utf8)
            let selfCSV = hrReferenceCSV(for: best, isoFormatter: ISO8601DateFormatter())
            if normalizeReferenceCSV(referenceText) == normalizeReferenceCSV(selfCSV) {
                recordHRReferenceAttempt(status: "fail",
                                         reason: "same_content_not_external_reference",
                                         source: "self_compare_rejected",
                                         referenceSamples: 0,
                                         comparison: nil,
                                         session: best.session,
                                         invalidateExistingValidation: true)
                WHOOPDebugLog("WHOOPDBG hr_reference_validation status=fail reason=same_content_not_external_reference source=Documents/atria-reference/%@ gate_d_pass=0 external_reference=0 reference_validated=0 action=provide_independent_chest_strap_hr_recording",
                      referenceURL.lastPathComponent)
                return false
            }
            let reference = try parseExternalHRReferenceCSV(at: referenceURL)
            let whoop = best.samples.sorted { $0.t < $1.t }.map { ExternalHRSample(t: $0.t, bpm: Double($0.bpm)) }
            let comparison = compareHRReference(whoop: whoop,
                                                reference: reference,
                                                toleranceBPM: 2,
                                                maxPairAge: 5)
            recordHRReferenceAttempt(status: comparison.ready ? "pass" : "fail",
                                     reason: comparison.reason,
                                     source: "csv",
                                     referenceSamples: reference.count,
                                     comparison: comparison,
                                     session: best.session,
                                     invalidateExistingValidation: !comparison.ready)
            WHOOPDebugLog("WHOOPDBG hr_reference_validation status=%@ reason=%@ whoop_samples=%d reference_samples=%d pairs=%d duration_s=%.0f mean_delta_bpm=%.2f median_delta_bpm=%.2f max_delta_bpm=%.2f within_tolerance_percent=%d tolerance_bpm=2 max_pair_age_s=5 gate_d_pass=%d external_reference=1 reference_validated=%d source=Documents/atria-reference/%@",
                  comparison.ready ? "pass" : "fail",
                  comparison.reason,
                  whoop.count,
                  reference.count,
                  comparison.pairs,
                  comparison.duration,
                  comparison.meanDelta ?? -1,
                  comparison.medianDelta ?? -1,
                  comparison.maxDelta ?? -1,
                  comparison.withinTolerancePercent,
                  comparison.ready ? 1 : 0,
                  comparison.ready ? 1 : 0,
                  referenceURL.lastPathComponent)
            if comparison.ready {
                persistHRReferenceValidation(session: best.session,
                                             pairs: comparison.pairs,
                                             meanDelta: comparison.meanDelta,
                                             maxDelta: comparison.maxDelta)
            }
            return comparison.ready
        } catch {
            recordHRReferenceAttempt(status: "error",
                                     reason: "parse_failed",
                                     source: "csv",
                                     referenceSamples: 0,
                                     comparison: nil,
                                     session: best.session,
                                     invalidateExistingValidation: true)
            WHOOPDebugLog("WHOOPDBG hr_reference_validation status=error reason=parse_failed error=%@ gate_d_pass=0 external_reference=1 reference_validated=0",
                  String(describing: error))
            return false
        }
    }

    private struct ReferenceCSVResolution {
        let url: URL?
        let reason: String
        let candidateCount: Int
        let candidates: [String]
        let autoSelected: Bool
    }

    private func resolveReferenceCSV(kind: String, preferredFileName: String) -> ReferenceCSVResolution {
        let referenceDir = url.deletingLastPathComponent().appendingPathComponent("atria-reference")
        let preferred = referenceDir.appendingPathComponent(preferredFileName)
        if FileManager.default.fileExists(atPath: preferred.path) {
            return ReferenceCSVResolution(url: preferred,
                                          reason: "preferred_file",
                                          candidateCount: 1,
                                          candidates: [preferred.lastPathComponent],
                                          autoSelected: false)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(at: referenceDir,
                                                                     includingPropertiesForKeys: [.isRegularFileKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        let candidates = contents
            .filter { $0.pathExtension.lowercased() == "csv" }
            .filter { isPlausibleReferenceCSVFileName($0.lastPathComponent, kind: kind) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if candidates.count == 1, let candidate = candidates.first {
            return ReferenceCSVResolution(url: candidate,
                                          reason: "auto_selected_single_candidate",
                                          candidateCount: 1,
                                          candidates: [candidate.lastPathComponent],
                                          autoSelected: true)
        }
        return ReferenceCSVResolution(url: nil,
                                      reason: candidates.isEmpty ? "missing_external_reference_file" : "ambiguous_external_reference_files",
                                      candidateCount: candidates.count,
                                      candidates: candidates.map(\.lastPathComponent),
                                      autoSelected: false)
    }

    private func isPlausibleReferenceCSVFileName(_ name: String, kind: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".csv") else { return false }
        if kind == "rr" {
            return lower.contains("rr")
                || lower.contains("ibi")
                || lower.contains("interval")
                || lower.contains("nn")
        }
        return lower.contains("hr")
            || lower.contains("heart")
            || lower.contains("bpm")
    }

    private func persistRRReferenceValidation(for session: SavedSession,
                                              rmssd: Double,
                                              sdnn: Double,
                                              delta: Double) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            WHOOPDebugLog("WHOOPDBG rr_reference_validation_persist status=failed reason=session_not_found session_id=%@ reference_validated=0",
                  session.id.uuidString)
            return
        }
        sessions[index].hrv = Int(rmssd.rounded())
        sessions[index].hrvSDNN = sdnn
        sessions[index].hrvReferenceValidated = true
        guard save() else {
            WHOOPDebugLog("WHOOPDBG rr_reference_validation_persist status=failed reason=session_store_save session_id=%@ reference_validated=0",
                  session.id.uuidString)
            return
        }
        rebuildBaselineFromEligibleSessions(reason: "rr-reference-validation")
        refreshSessionDerivedCaches()
        refreshHomeDashboardDiagnosticsCache()
        publishDashboardRevision()
        WHOOPDebugLog("WHOOPDBG rr_reference_validation_persist status=ok session_id=%@ label=%@ rmssd=%d sdnn=%.1f rmssd_delta_ms=%.1f reference_validated=1",
              session.id.uuidString,
              session.label,
              sessions[index].referenceValidatedHRV ?? 0,
              sessions[index].referenceValidatedSDNN ?? 0,
              delta)
    }

    private func persistHRReferenceValidation(session: SavedSession,
                                              pairs: Int,
                                              meanDelta: Double?,
                                              maxDelta: Double?) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: ExternalReferenceDefaults.hrValidated)
        defaults.set(Date(), forKey: ExternalReferenceDefaults.hrValidatedAt)
        defaults.set("csv", forKey: ExternalReferenceDefaults.hrSource)
        defaults.set(pairs, forKey: ExternalReferenceDefaults.hrPairs)
        defaults.set(meanDelta ?? -1, forKey: ExternalReferenceDefaults.hrMeanDelta)
        defaults.set(maxDelta ?? -1, forKey: ExternalReferenceDefaults.hrMaxDelta)
        defaults.set(session.id.uuidString, forKey: ExternalReferenceDefaults.hrSessionID)
        defaults.set(session.label, forKey: ExternalReferenceDefaults.hrSessionLabel)
        refreshHomeDashboardDiagnosticsCache()
        publishDashboardRevision()
        WHOOPDebugLog("WHOOPDBG hr_reference_validation_persist status=ok session_id=%@ label=%@ source=csv pairs=%d mean_delta_bpm=%.2f max_delta_bpm=%.2f reference_validated=1",
              session.id.uuidString,
              session.label,
              pairs,
              meanDelta ?? -1,
              maxDelta ?? -1)
    }

    private func recordHRReferenceAttempt(status: String,
                                          reason: String,
                                          source: String,
                                          referenceSamples: Int,
                                          comparison: HRReferenceComparison?,
                                          session: SavedSession?,
                                          invalidateExistingValidation: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(status, forKey: ExternalReferenceDefaults.hrStatus)
        defaults.set(reason, forKey: ExternalReferenceDefaults.hrReason)
        if status == "pass" || invalidateExistingValidation {
            defaults.set(source, forKey: ExternalReferenceDefaults.hrSource)
        }
        defaults.set(referenceSamples, forKey: ExternalReferenceDefaults.hrReferenceSamples)
        defaults.set(comparison?.pairs ?? 0, forKey: ExternalReferenceDefaults.hrPairs)
        defaults.set(comparison?.duration ?? 0, forKey: ExternalReferenceDefaults.hrDuration)
        defaults.set(comparison?.meanDelta ?? -1, forKey: ExternalReferenceDefaults.hrMeanDelta)
        defaults.set(comparison?.medianDelta ?? -1, forKey: ExternalReferenceDefaults.hrMedianDelta)
        defaults.set(comparison?.maxDelta ?? -1, forKey: ExternalReferenceDefaults.hrMaxDelta)
        defaults.set(comparison?.withinTolerancePercent ?? 0, forKey: ExternalReferenceDefaults.hrWithinTolerancePercent)
        if let session {
            defaults.set(session.id.uuidString, forKey: ExternalReferenceDefaults.hrSessionID)
            defaults.set(session.label, forKey: ExternalReferenceDefaults.hrSessionLabel)
        }
        if status == "pass" {
            defaults.set(true, forKey: ExternalReferenceDefaults.hrValidated)
            defaults.set(Date(), forKey: ExternalReferenceDefaults.hrValidatedAt)
        } else if invalidateExistingValidation {
            defaults.set(false, forKey: ExternalReferenceDefaults.hrValidated)
        }
        refreshHomeDashboardDiagnosticsCache()
        publishDashboardRevision()
        WHOOPDebugLog("WHOOPDBG hr_reference_validation_record status=%@ reason=%@ source=%@ reference_samples=%d pairs=%d duration_s=%.0f mean_delta_bpm=%.2f median_delta_bpm=%.2f max_delta_bpm=%.2f within_tolerance_percent=%d reference_validated=%d invalidated=%d",
              status,
              reason,
              source,
              referenceSamples,
              comparison?.pairs ?? 0,
              comparison?.duration ?? 0,
              comparison?.meanDelta ?? -1,
              comparison?.medianDelta ?? -1,
              comparison?.maxDelta ?? -1,
              comparison?.withinTolerancePercent ?? 0,
              defaults.bool(forKey: ExternalReferenceDefaults.hrValidated) ? 1 : 0,
              invalidateExistingValidation ? 1 : 0)
    }

    private func clearHRReferenceValidation(reason: String) {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: ExternalReferenceDefaults.hrValidated)
        defaults.set("cleared", forKey: ExternalReferenceDefaults.hrStatus)
        defaults.set(reason, forKey: ExternalReferenceDefaults.hrReason)
        defaults.set("missing", forKey: ExternalReferenceDefaults.hrSource)
        defaults.set(0, forKey: ExternalReferenceDefaults.hrPairs)
        defaults.set(0, forKey: ExternalReferenceDefaults.hrReferenceSamples)
        defaults.set(0, forKey: ExternalReferenceDefaults.hrDuration)
        defaults.set(-1, forKey: ExternalReferenceDefaults.hrMeanDelta)
        defaults.set(-1, forKey: ExternalReferenceDefaults.hrMedianDelta)
        defaults.set(-1, forKey: ExternalReferenceDefaults.hrMaxDelta)
        defaults.set(0, forKey: ExternalReferenceDefaults.hrWithinTolerancePercent)
        refreshHomeDashboardDiagnosticsCache()
        publishDashboardRevision()
        WHOOPDebugLog("WHOOPDBG hr_reference_validation_clear status=ok reason=%@ reference_validated=0",
              reason)
    }

    @discardableResult
    private func exportHRReferencePackage() -> (csv: URL, manifest: URL)? {
        let hrSamples = sessions.reduce(0) { $0 + $1.points.count }
        guard let best = bestSavedHRReferenceSession() else {
            let reason = hrSamples > 0 ? "no_60s_saved_hr_window" : "no_saved_hr"
            WHOOPDebugLog("WHOOPDBG hr_reference_package status=learning reason=%@ sessions=%d hr_samples=%d external_reference_required=1 reference_validated=0 gate_d_pass=0",
                  reason,
                  sessions.count,
                  hrSamples)
            return nil
        }

        let relativeDir = "Documents/atria-hr-reference-packages"
        let exportDir = url.deletingLastPathComponent().appendingPathComponent("atria-hr-reference-packages")
        let timestamp = SessionStore.backupTimestamp()
        let safeLabel = safeFileStem(best.session.label)
        let base = "atria-hr-reference-\(timestamp)-\(safeLabel)"
        let csvURL = exportDir.appendingPathComponent("\(base).csv")
        let manifestURL = exportDir.appendingPathComponent("\(base)-manifest.json")
        let iso = ISO8601DateFormatter()
        let bpms = best.samples.map(\.bpm)
        let avg = bpms.isEmpty ? 0 : Double(bpms.reduce(0, +)) / Double(bpms.count)
        let peak = bpms.max() ?? 0
        let resting = bpms.min() ?? 0
        let duration = best.session.duration
        let observed = observedHRSeconds(best.samples)
        let coverage = duration > 0 ? min(1.0, observed / duration) : 0.0

        do {
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            let csv = hrReferenceCSV(for: best, isoFormatter: iso)
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)

            let manifest: [String: Any] = [
                "schema": 1,
                "createdAt": iso.string(from: Date()),
                "source": "saved_2a37_hr_points",
                "csv": "\(relativeDir)/\(csvURL.lastPathComponent)",
                "sessionLabel": best.session.label,
                "sessionStart": iso.string(from: best.session.start),
                "sessionEnd": iso.string(from: best.session.end),
                "durationSeconds": duration,
                "observedSeconds": observed,
                "streamCoveragePercent": Int((coverage * 100).rounded()),
                "hrSamples": best.samples.count,
                "avgHR": avg,
                "peakHR": peak,
                "restingHR": resting,
                "raw2A37Notifications": best.session.hrRaw2A37Value,
                "acceptedHRSamples": best.session.hrAcceptedValue,
                "acceptedHRGaps": best.session.hrAcceptedGapsValue,
                "maxAcceptedHRGapSeconds": best.session.hrMaxAcceptedGapValue,
                "externalReferenceRequired": true,
                "referenceValidated": false,
                "readyForExternalReference": true,
                "gateDPassed": false
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: manifestURL, options: .atomic)

            WHOOPDebugLog("WHOOPDBG hr_reference_package status=ok csv=%@ manifest=%@ session_label=%@ samples=%d duration_s=%.0f observed_s=%.0f coverage_percent=%d avg_hr=%.1f peak_hr=%d resting_hr=%d source=2a37 external_reference_required=1 reference_validated=0 gate_d_pass=0",
                  "\(relativeDir)/\(csvURL.lastPathComponent)",
                  "\(relativeDir)/\(manifestURL.lastPathComponent)",
                  best.session.label,
                  best.samples.count,
                  duration,
                  observed,
                  Int((coverage * 100).rounded()),
                  avg,
                  peak,
                  resting)
            return (csvURL, manifestURL)
        } catch {
            WHOOPDebugLog("WHOOPDBG hr_reference_package status=error reason=write_failed error=%@", String(describing: error))
            return nil
        }
    }

    private func rrReferenceCSV(for window: RRSavedReferenceWindow, isoFormatter: ISO8601DateFormatter) -> String {
        var rows = ["elapsed_ms,kind,value,source,iso_time,session_label"]
        for sample in window.samples.sorted(by: { $0.t < $1.t }) {
            let elapsedMs = Int((sample.t.timeIntervalSince(window.windowStart) * 1000).rounded())
            let value = Int(sample.ms.rounded())
            rows.append("\(elapsedMs),rr,\(value),saved_rr_points,\(csvEscape(isoFormatter.string(from: sample.t))),\(csvEscape(window.session.label))")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func parseExternalRRReferenceCSV(at referenceURL: URL) throws -> [ExternalRRPoint] {
        let text = try String(contentsOf: referenceURL, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first else { return [] }
        let headers = csvFields(header).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let rrIndex = firstHeaderIndex(in: headers,
                                       names: ["rr_ms", "rr", "ibi_ms", "ibi", "interval_ms", "interval", "nn_ms", "nn", "value"])
        let timeIndex = firstHeaderIndex(in: headers,
                                         names: ["elapsed_ms", "time_ms", "timestamp_ms", "t_ms", "seconds", "time_s", "timestamp", "t"])
        var points: [ExternalRRPoint] = []
        var elapsed: TimeInterval = 0
        for line in lines.dropFirst() {
            let fields = csvFields(line)
            guard let rrIndex, rrIndex < fields.count,
                  let ms = Double(fields[rrIndex].trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            let t: TimeInterval
            if let timeIndex, timeIndex < fields.count,
               let parsedTime = Double(fields[timeIndex].trimmingCharacters(in: .whitespacesAndNewlines)) {
                t = headers[timeIndex].contains("ms") ? parsedTime / 1000.0 : parsedTime
            } else {
                elapsed += ms / 1000.0
                t = elapsed
            }
            points.append(ExternalRRPoint(t: t, ms: ms))
        }
        return points
    }

    private func parseExternalHRReferenceCSV(at referenceURL: URL) throws -> [ExternalHRSample] {
        let text = try String(contentsOf: referenceURL, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first else { return [] }
        let headers = csvFields(header).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hrIndex = firstHeaderIndex(in: headers,
                                       names: ["hr", "heart_rate", "bpm", "value"])
        let timeIndex = firstHeaderIndex(in: headers,
                                         names: ["elapsed_ms", "time_ms", "timestamp_ms", "t_ms", "seconds", "time_s", "timestamp", "t"])
        var points: [ExternalHRSample] = []
        var elapsed: TimeInterval = 0
        for line in lines.dropFirst() {
            let fields = csvFields(line)
            guard let hrIndex, hrIndex < fields.count,
                  let bpm = Double(fields[hrIndex].trimmingCharacters(in: .whitespacesAndNewlines)),
                  bpm > 0 else { continue }
            let t: TimeInterval
            if let timeIndex, timeIndex < fields.count,
               let parsedTime = Double(fields[timeIndex].trimmingCharacters(in: .whitespacesAndNewlines)) {
                t = headers[timeIndex].contains("ms") ? parsedTime / 1000.0 : parsedTime
            } else {
                t = elapsed
                elapsed += 1
            }
            points.append(ExternalHRSample(t: t, bpm: bpm))
        }
        return points
    }

    private func normalizeReferenceCSV(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func firstHeaderIndex(in headers: [String], names: [String]) -> Int? {
        for name in names {
            if let index = headers.firstIndex(of: name) { return index }
        }
        return nil
    }

    private func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        for char in line {
            if char == "\"" {
                quoted.toggle()
            } else if char == "," && !quoted {
                fields.append(current)
                current.removeAll()
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }

    private func scoreExternalRR(_ points: [ExternalRRPoint], windowSeconds: TimeInterval) -> RRReferenceScore {
        let ordered = points.sorted { $0.t < $1.t }
        guard let first = ordered.first else {
            return RRReferenceScore(raw: 0, kept: 0, confidencePercent: 0,
                                    duration: 0, maxGap: 0, rmssd: nil,
                                    ready: false, reason: "reference_empty")
        }
        let end = first.t + windowSeconds
        let window = ordered.filter { $0.t >= first.t && $0.t <= end }
        var kept: [Double] = []
        var rejectedRange = 0
        var rejectedDelta = 0
        for point in window {
            guard 300...2000 ~= point.ms else {
                rejectedRange += 1
                continue
            }
            if let previous = kept.last, abs(point.ms - previous) / previous > 0.20 {
                rejectedDelta += 1
                continue
            }
            kept.append(point.ms)
        }
        let duration = (window.last?.t ?? first.t) - first.t
        let maxGap = zip(window, window.dropFirst()).map { $1.t - $0.t }.max() ?? 0
        let confidence = window.isEmpty ? 0 : Int((Double(kept.count) / Double(window.count) * 100).rounded())
        let rmssdValue = rmssd(kept)
        let ready = duration >= windowSeconds - 1
            && maxGap <= HRVSnapshot.maxReadyRRGapSeconds
            && kept.count >= 240
            && confidence >= 75
            && rmssdValue != nil
        let reason: String
        if duration < windowSeconds - 1 { reason = "reference_window" }
        else if maxGap > HRVSnapshot.maxReadyRRGapSeconds { reason = "reference_gap" }
        else if kept.count < 240 { reason = "reference_beats" }
        else if confidence < 75 { reason = "reference_confidence" }
        else if rmssdValue == nil { reason = "reference_metrics" }
        else { reason = "ready" }

        _ = rejectedRange
        _ = rejectedDelta
        return RRReferenceScore(raw: window.count,
                                kept: kept.count,
                                confidencePercent: confidence,
                                duration: duration,
                                maxGap: maxGap,
                                rmssd: rmssdValue,
                                ready: ready,
                                reason: reason)
    }

    private func rrReferenceFailureReason(whoop: RRSavedReferenceWindow,
                                          reference: RRReferenceScore,
                                          delta: Double?) -> String {
        if !whoop.ready { return "whoop_\(whoop.reason)" }
        if !reference.ready { return reference.reason }
        guard let delta else { return "missing_rmssd" }
        if delta > 5 { return "rmssd_delta_over_tolerance" }
        return "unknown"
    }

    private func compareHRReference(whoop: [ExternalHRSample],
                                    reference: [ExternalHRSample],
                                    toleranceBPM: Double,
                                    maxPairAge: TimeInterval) -> HRReferenceComparison {
        let paired = pairHRSamples(whoop: whoop, reference: reference, maxAge: maxPairAge)
        let deltas = paired.map { abs($0.whoop.bpm - $0.reference.bpm) }
        let duration = pairedDuration(paired)
        let meanDelta = deltas.isEmpty ? nil : deltas.reduce(0, +) / Double(deltas.count)
        let medianDelta = median(deltas)
        let maxDelta = deltas.max()
        let withinTolerance = deltas.filter { $0 <= toleranceBPM }.count
        let withinPercent = deltas.isEmpty ? 0 : Int((Double(withinTolerance) / Double(deltas.count) * 100).rounded())
        let ready = paired.count >= 30
            && duration >= 60
            && meanDelta.map { $0 <= toleranceBPM } == true
            && maxDelta.map { $0 <= toleranceBPM } == true
        let reason: String
        if paired.count < 30 { reason = "insufficient_pairs" }
        else if duration < 60 { reason = "window_too_short" }
        else if meanDelta == nil || maxDelta == nil { reason = "missing_metrics" }
        else if meanDelta! > toleranceBPM { reason = "mean_delta_over_tolerance" }
        else if maxDelta! > toleranceBPM { reason = "max_delta_over_tolerance" }
        else { reason = "ready" }
        return HRReferenceComparison(pairs: paired.count,
                                     duration: duration,
                                     meanDelta: meanDelta,
                                     medianDelta: medianDelta,
                                     maxDelta: maxDelta,
                                     withinTolerancePercent: withinPercent,
                                     ready: ready,
                                     reason: reason)
    }

    private func pairHRSamples(whoop: [ExternalHRSample],
                               reference: [ExternalHRSample],
                               maxAge: TimeInterval) -> [(whoop: ExternalHRSample, reference: ExternalHRSample)] {
        let refs = reference.sorted { $0.t < $1.t }
        guard !refs.isEmpty else { return [] }
        return whoop.sorted { $0.t < $1.t }.compactMap { sample in
            var best: ExternalHRSample?
            var bestDelta = maxAge
            for candidate in refs {
                let delta = abs(candidate.t - sample.t)
                if delta <= bestDelta {
                    best = candidate
                    bestDelta = delta
                } else if candidate.t > sample.t && delta > bestDelta {
                    break
                }
            }
            guard let best else { return nil }
            return (sample, best)
        }
    }

    private func pairedDuration(_ pairs: [(whoop: ExternalHRSample, reference: ExternalHRSample)]) -> TimeInterval {
        guard let first = pairs.first?.whoop.t,
              let last = pairs.last?.whoop.t else { return 0 }
        return max(0, last - first)
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        let middle = ordered.count / 2
        if ordered.count.isMultiple(of: 2) {
            return (ordered[middle - 1] + ordered[middle]) / 2.0
        }
        return ordered[middle]
    }

    private func rmssd(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let diffs = zip(values, values.dropFirst()).map { $1 - $0 }
        let meanSquare = diffs.reduce(0) { $0 + ($1 * $1) } / Double(diffs.count)
        return sqrt(meanSquare)
    }

    private func hrReferenceCSV(for reference: HRSavedReferenceSession, isoFormatter: ISO8601DateFormatter) -> String {
        var rows = ["elapsed_ms,kind,source,opcode,len,label,value,iso_time,session_label"]
        for sample in reference.samples.sorted(by: { $0.t < $1.t }) {
            let elapsedMs = Int((sample.t * 1000).rounded())
            let sampleTime = reference.session.start.addingTimeInterval(sample.t)
            rows.append("\(elapsedMs),hr,0x2A37,,,hr,\(sample.bpm),\(csvEscape(isoFormatter.string(from: sampleTime))),\(csvEscape(reference.session.label))")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func bestSavedHRReferenceSession() -> HRSavedReferenceSession? {
        let candidates = canonicalSessions().compactMap { session -> HRSavedReferenceSession? in
            let samples = session.points.filter { $0.bpm > 0 }.sorted { $0.t < $1.t }
            guard samples.count >= 30, session.duration >= 60 else { return nil }
            return HRSavedReferenceSession(session: session, samples: samples)
        }
        return candidates.max { lhs, rhs in
            let lhsScore = hrReferenceScore(lhs)
            let rhsScore = hrReferenceScore(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs.session.end < rhs.session.end
        }
    }

    private func hrReferenceScore(_ reference: HRSavedReferenceSession) -> Double {
        let coverage = reference.session.duration > 0
            ? min(1.0, observedHRSeconds(reference.samples) / reference.session.duration)
            : 0.0
        return Double(reference.samples.count) + min(reference.session.duration, 3600) + (coverage * 1000)
    }

    private func observedHRSeconds(_ points: [SavedSession.Point]) -> TimeInterval {
        guard points.count > 1 else { return 0 }
        let sorted = points.sorted { $0.t < $1.t }
        var total: TimeInterval = 0
        for index in 1..<sorted.count {
            total += min(max(0, sorted[index].t - sorted[index - 1].t), SavedSession.workoutContinuityGapLimit)
        }
        return total
    }

    private func safeFileStem(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "session" : trimmed
        let safe = source.replacingOccurrences(of: "[^A-Za-z0-9_-]",
                                               with: "-",
                                               options: .regularExpression)
        return String(safe.prefix(80))
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private func writeAutomaticSessionBackup(reason: String) {
        let backupURL = writeSessionBackup(label: "auto-\(reason)")
        refreshBackupStatusCache()
        refreshHomeDashboardDiagnosticsCache()
        publishDashboardRevision()
        WHOOPDebugLog("WHOOPDBG session_backup_auto status=%@ reason=%@ path=%@ sessions=%d",
              backupURL == nil ? "error" : "ok",
              reason,
              backupURL.map { backupRelativePath(for: $0) } ?? "none",
              sessions.count)
    }

    func verifyLatestSessionBackupFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-verify-backup") else { return }
        verifyLatestSessionBackup()
    }

    func verifyLatestSessionBackup() {
        guard let latest = latestSessionBackupURL() else {
            WHOOPDebugLog("WHOOPDBG session_backup_verify status=missing reason=no_backup_files")
            return
        }
        verifySessionBackup(at: latest)
    }

    func restoreLatestSessionBackupFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-restore-backup") else { return }
        restoreLatestSessionBackup()
    }

    func restoreLatestSessionBackup() {
        guard let latest = latestRestorableSessionBackupURL() else {
            WHOOPDebugLog("WHOOPDBG session_backup_restore status=missing reason=no_backup_files")
            return
        }

        let safetyURL = writeSessionBackup(label: "pre-restore")
        do {
            let data = try Data(contentsOf: latest)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(SessionBackupEnvelope.self, from: data)
            guard envelope.schema == 1 else {
                WHOOPDebugLog("WHOOPDBG session_backup_restore status=error reason=unsupported_schema schema=%d", envelope.schema)
                return
            }

            sessions = envelope.sessions
            profile = envelope.profile
            refreshSessionDerivedCaches()
            guard save() else {
                WHOOPDebugLog("WHOOPDBG session_backup_restore status=error reason=store_save_failed")
                return
            }
            rebuildBaselineFromEligibleSessions(reason: "restore-backup")
            profile.save()
            refreshBackupStatusCache()
            refreshHomeDashboardDiagnosticsCache()
            publishDashboardRevision()
            let digest = backupContentDigest(sessions: sessions,
                                             baseline: baseline,
                                             profile: profile) ?? "error"
            WHOOPDebugLog("WHOOPDBG session_backup_restore status=ok path=%@ safety=%@ schema=%d sessions=%d baseline_samples=%d profile_max_hr=%d digest=%@",
                  backupRelativePath(for: latest),
                  safetyURL.map { backupRelativePath(for: $0) } ?? "none",
                  envelope.schema,
                  sessions.count,
                  baseline.sessions,
                  profile.maxHR,
                  digest)
        } catch {
            WHOOPDebugLog("WHOOPDBG session_backup_restore status=error error=%@", String(describing: error))
        }
    }

    private func latestSessionBackupURL() -> URL? {
        latestSessionBackupURL(includeSafetyBackups: false)
    }

    private func latestRestorableSessionBackupURL() -> URL? {
        latestSessionBackupURL(includeSafetyBackups: false)
    }

    private func latestSessionBackupURL(includeSafetyBackups: Bool) -> URL? {
        var allFiles: [URL] = []
        for backupDir in sessionBackupDirectoriesForReading() {
            guard let files = try? FileManager.default.contentsOfDirectory(at: backupDir,
                                                                           includingPropertiesForKeys: nil,
                                                                           options: [.skipsHiddenFiles])
                .filter({
                    $0.pathExtension == "json"
                        && (includeSafetyBackups || !$0.deletingPathExtension().lastPathComponent.hasSuffix("-pre-restore"))
                }) else {
                continue
            }
            allFiles.append(contentsOf: files)
        }
        return allFiles.max { backupSortDate($0) < backupSortDate($1) }
    }

    private func sessionBackupDirectory() -> URL {
        url.deletingLastPathComponent().appendingPathComponent("atria-backups")
    }

    private func legacySessionBackupDirectory() -> URL {
        url.deletingLastPathComponent().appendingPathComponent("whoop-backups")
    }

    private func sessionBackupDirectoriesForReading() -> [URL] {
        [sessionBackupDirectory(), legacySessionBackupDirectory()]
    }

    private func backupRelativePath(for backupURL: URL) -> String {
        let directory = backupURL.deletingLastPathComponent().lastPathComponent
        return "Documents/\(directory)/\(backupURL.lastPathComponent)"
    }

    private func backupSortDate(_ backupURL: URL) -> Date {
        if let date = (try? FileManager.default.attributesOfItem(atPath: backupURL.path)[.modificationDate]) as? Date {
            return date
        }
        return .distantPast
    }

    private func pruneAutomaticBackups(in backupDir: URL, keep: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: backupDir,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles])
            .filter({ $0.pathExtension == "json" }) else {
            WHOOPDebugLog("WHOOPDBG session_backup_prune status=missing_dir keep=%d deleted=0 total_json=0 auto_json=0",
                  keep)
            return
        }

        let automatic = files
            .filter { $0.deletingPathExtension().lastPathComponent.contains("-auto-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        let expired = automatic.dropFirst(max(0, keep))
        var deleted = 0
        for file in expired {
            do {
                try FileManager.default.removeItem(at: file)
                deleted += 1
            } catch {
                WHOOPDebugLog("WHOOPDBG session_backup_prune_error file=%@ error=%@",
                      file.lastPathComponent,
                      String(describing: error))
            }
        }
        WHOOPDebugLog("WHOOPDBG session_backup_prune status=ok keep=%d kept_auto=%d deleted=%d total_json=%d auto_json=%d",
              keep,
              min(automatic.count, keep),
              deleted,
              files.count,
              automatic.count)
    }

    private func verifySessionBackup(at latest: URL) {
        do {
            let data = try Data(contentsOf: latest)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(SessionBackupEnvelope.self, from: data)
            let countMatches = envelope.sessions.count == sessions.count
            let schemaOK = envelope.schema == 1
            let backupDigest = backupContentDigest(sessions: envelope.sessions,
                                                   baseline: envelope.baseline,
                                                   profile: envelope.profile)
            let currentDigest = backupContentDigest(sessions: sessions,
                                                    baseline: baseline,
                                                    profile: profile)
            let digestMatches = backupDigest != nil && backupDigest == currentDigest
            let status = countMatches && schemaOK && digestMatches ? "ok" : "mismatch"
            WHOOPDebugLog("WHOOPDBG session_backup_verify status=%@ path=%@ schema=%d sessions=%d current_sessions=%d rr_samples=%d current_rr_samples=%d motion_hints=%d current_motion_hints=%d motion_short_samples=%d current_motion_short_samples=%d hr_raw_2a37=%d current_hr_raw_2a37=%d hr_accepted=%d current_hr_accepted=%d hr_raw_gaps=%d current_hr_raw_gaps=%d hr_accepted_gaps=%d current_hr_accepted_gaps=%d bytes=%d profile_max_hr=%d baseline_samples=%d digest=%@ current_digest=%@ digest_match=%d",
                  status,
                  backupRelativePath(for: latest),
                  envelope.schema,
                  envelope.sessions.count,
                  sessions.count,
                  totalRRSamples(in: envelope.sessions),
                  totalRRSamples(in: sessions),
                  totalMotionHints(in: envelope.sessions),
                  totalMotionHints(in: sessions),
                  totalMotionShortSamples(in: envelope.sessions),
                  totalMotionShortSamples(in: sessions),
                  totalHRRaw2A37(in: envelope.sessions),
                  totalHRRaw2A37(in: sessions),
                  totalHRAccepted(in: envelope.sessions),
                  totalHRAccepted(in: sessions),
                  totalHRRawGaps(in: envelope.sessions),
                  totalHRRawGaps(in: sessions),
                  totalHRAcceptedGaps(in: envelope.sessions),
                  totalHRAcceptedGaps(in: sessions),
                  data.count,
                  envelope.profile.maxHR,
                  envelope.baseline.sessions,
                  backupDigest ?? "error",
                  currentDigest ?? "error",
                  digestMatches ? 1 : 0)
        } catch {
            WHOOPDebugLog("WHOOPDBG session_backup_verify status=error error=%@", String(describing: error))
        }
    }

    private func backupContentDigest(sessions: [SavedSession],
                                     baseline: PersonalBaseline,
                                     profile: AthleteProfile) -> String? {
        Self.makeBackupContentDigest(sessions: sessions,
                                     baseline: baseline,
                                     profile: profile)
    }

    private nonisolated static func makeBackupContentDigest(sessions: [SavedSession],
                                                            baseline: PersonalBaseline,
                                                            profile: AthleteProfile) -> String? {
        let content = SessionBackupContentFingerprint(schema: 1,
                                                      app: "Atria.local",
                                                      sessions: sessions,
                                                      baseline: baseline,
                                                      profile: profile)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(content) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func exportHealthKitFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--whoop-healthkit-export") else { return }
        let rest = baseline.restingInt ?? 60
        healthKitExporter.export(sessions: sessions,
                                 rest: rest,
                                 maxHR: profile.maxHR,
                                 profile: profile,
                                 restingBaselineSamples: baseline.restingSampleCount,
                                 confirmedWorkouts: confirmedWorkouts,
                                 confirmedSleeps: confirmedSleeps)
    }

    /// User-triggered Apple Health export (from Settings). The export is
    /// idempotent and incremental, so repeated taps only write new samples.
    func exportToHealthKit() {
        let rest = baseline.restingInt ?? 60
        healthKitExporter.export(sessions: sessions,
                                 rest: rest,
                                 maxHR: profile.maxHR,
                                 profile: profile,
                                 restingBaselineSamples: baseline.restingSampleCount,
                                 confirmedWorkouts: confirmedWorkouts,
                                 confirmedSleeps: confirmedSleeps)
    }

    func resetAndRebuildHealthKitHeartRateFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let rest = baseline.restingInt ?? 60
        healthKitExporter.resetAndRebuildAtriaHeartRateFromLaunchIfRequested(arguments: arguments,
                                                                             sessions: sessions,
                                                                             rest: rest,
                                                                             maxHR: profile.maxHR)
    }

    func auditHealthKitHRReferenceFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        healthKitExporter.auditHeartRateReferenceFromLaunchIfRequested(arguments: arguments,
                                                                       sessions: sessions)
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    private func trendAnomalies(rollups recent: [DailyRollup]) -> [String] {
        let ordered = recent.sorted { $0.day < $1.day }
        guard let latest = ordered.last else { return [] }
        let rhrs = ordered.compactMap(\.restingHR).filter { $0 > 0 }
        let strains = ordered.map(\.strain).filter { $0 > 0 }
        var out: [String] = []
        if let latestRHR = latest.restingHR,
           isHighOutlier(Double(latestRHR), in: rhrs.map(Double.init)) {
            out.append("RHR elevated")
        }
        if latest.strain > 0,
           isHighOutlier(latest.strain, in: strains) {
            out.append("Strain spike")
        }
        return out
    }

    private func trendConfidence(coverageDays: Int, windowDays: Int) -> String {
        guard coverageDays > 0 else { return "learning" }
        if coverageDays >= trendRequiredCoverageDays(windowDays: windowDays) { return "high" }
        let coverage = Double(coverageDays) / Double(windowDays)
        if coverage >= 0.25 || coverageDays >= 7 { return "partial" }
        return "learning"
    }

    private func trendRequiredCoverageDays(windowDays: Int) -> Int {
        max(1, Int((Double(windowDays) * 0.70).rounded(.up)))
    }

    private func trendDetail(coverageDays: Int,
                             windowDays: Int,
                             hrvState: String,
                             rhrSamples: Int,
                             strainSamples: Int,
                             anomalySource: String,
                             anomalySampleDays: Int,
                             anomalies: [String]) -> String {
        var parts: [String] = []
        if coverageDays == 0 {
            parts.append("no saved history")
        } else if Double(coverageDays) / Double(windowDays) >= 0.70 {
            parts.append("coverage high")
        } else {
            parts.append("coverage sparse")
        }
        parts.append(hrvState == "learning" ? "HRV learning" : "HRV \(hrvState)")
        parts.append(rhrSamples > 0 ? "RHR accepted evidence \(rhrSamples)" : "RHR learning")
        parts.append(strainSamples > 0 ? "strain saved TRIMP \(strainSamples)" : "strain learning")
        parts.append("anomaly source \(anomalySource) days \(anomalySampleDays)")
        if !anomalies.isEmpty {
            parts.append("flags \(anomalies.joined(separator: ","))")
        }
        return parts.joined(separator: " · ")
    }

    private func trendSummaryBlockers(coverageDays: Int,
                                      requiredCoverageDays: Int,
                                      avgRecovery: Int?,
                                      avgHRV: Int?,
                                      hrvState: String) -> String {
        var blockers: [String] = []
        if coverageDays <= 0 {
            blockers.append("no_saved_history")
        } else if coverageDays < requiredCoverageDays {
            blockers.append("coverage_below_70pct")
        }
        if hrvState == "learning" {
            blockers.append("hrv_learning")
        }
        if avgRecovery == nil {
            blockers.append("recovery_points_missing")
        }
        if avgHRV == nil {
            blockers.append("hrv_points_missing")
        }
        return blockers.isEmpty ? "none" : blockers.joined(separator: "+")
    }

    private func trendBlockers(summary: TrendSummary?, hrvValidated _: Int) -> String {
        guard let summary else { return "no_trend_summary" }
        var blockers: [String] = []
        if summary.coverageDays <= 0 {
            blockers.append("no_saved_history")
        } else if summary.confidence != "high" {
            blockers.append("coverage_below_70pct")
        }
        if summary.hrvState == "learning" {
            blockers.append("hrv_learning")
        }
        if summary.avgRecovery == nil {
            blockers.append("recovery_points_missing")
        }
        if summary.avgHRV == nil {
            blockers.append("hrv_points_missing")
        }
        return blockers.isEmpty ? "none" : blockers.joined(separator: "+")
    }

    private func gateFStatus(summary: TrendSummary?, hrvValidated: Int) -> String {
        guard let summary else { return "learning" }
        let hasLocalNonHRVTrend = summary.avgRHR != nil || summary.avgStrain != nil
        let completeCoverage = summary.confidence == "high"
        let completeValidatedMetrics = hrvValidated > 0
            && summary.avgRecovery != nil
            && summary.avgHRV != nil
            && summary.avgRHR != nil
            && summary.avgStrain != nil
        if completeCoverage && completeValidatedMetrics {
            return "ready"
        }
        return hasLocalNonHRVTrend ? "partial" : "learning"
    }

    private func trendAnomalyFlags(_ anomalies: [String]) -> String {
        guard !anomalies.isEmpty else { return "none" }
        return anomalies.map { $0.replacingOccurrences(of: " ", with: "_") }.joined(separator: ",")
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard arguments.indices.contains(next) else { return nil }
        return arguments[next]
    }

    private func doubleValue(after flag: String, in arguments: [String], default defaultValue: Double, range: ClosedRange<Double>) -> Double {
        guard let raw = value(after: flag, in: arguments), let value = Double(raw) else {
            return defaultValue
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func isHighOutlier(_ value: Double, in values: [Double]) -> Bool {
        guard values.count >= 3 else { return false }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let sd = sqrt(variance)
        return sd > 0.1 && value > mean + 2 * sd
    }

    private func averageInt(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    private func averageDouble(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func aggregateSleepDay(for session: SavedSession, calendar: Calendar) -> Date {
        let endHour = calendar.component(.hour, from: session.end)
        if endHour <= 11 {
            return calendar.startOfDay(for: session.end)
        }
        return calendar.startOfDay(for: session.start)
    }

    private func sleepClusters(from sessions: [SavedSession], maxGap: TimeInterval) -> [[SavedSession]] {
        var clusters: [[SavedSession]] = []
        for session in sessions.sorted(by: { $0.start < $1.start }) {
            guard var current = clusters.popLast() else {
                clusters.append([session])
                continue
            }
            let gap = max(0, session.start.timeIntervalSince(current.last?.end ?? session.start))
            if gap <= maxGap {
                current.append(session)
                clusters.append(current)
            } else {
                clusters.append(current)
                clusters.append([session])
            }
        }
        return clusters
    }

    private func workoutClusters(from sessions: [SavedSession], maxGap: TimeInterval) -> [[SavedSession]] {
        var clusters: [[SavedSession]] = []
        for session in sessions.sorted(by: { $0.start < $1.start }) {
            guard var current = clusters.popLast() else {
                clusters.append([session])
                continue
            }
            let gap = max(0, session.start.timeIntervalSince(current.last?.end ?? session.start))
            if gap <= maxGap {
                current.append(session)
                clusters.append(current)
            } else {
                clusters.append(current)
                clusters.append([session])
            }
        }
        return clusters
    }

    private func percentileHR(_ percentile: Double, values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * clamped).rounded(.down))))
        return sorted[index]
    }

    private func formatInt(_ value: Int?) -> String {
        value.map(String.init) ?? "learning"
    }

    private func formatDouble(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "learning"
    }

    private func loadPersistedSessionsDeferred() {
        let sourceURL = url
        let currentBaseline = baseline
        let currentProfile = profile
        Task.detached(priority: .utility) { [sourceURL, currentBaseline, currentProfile] in
            let startedAt = CFAbsoluteTimeGetCurrent()
            guard let data = try? Data(contentsOf: sourceURL),
                  let decoded = try? JSONDecoder().decode([SavedSession].self, from: data) else {
                await MainActor.run {
                    WHOOPDebugLog("WHOOPDBG session_store_load status=empty")
                }
                return
            }

            let preparation = Self.prepareDeferredLoad(decoded: decoded,
                                                       baseline: currentBaseline,
                                                       profile: currentProfile,
                                                       sessionFileURL: sourceURL)
            let elapsedMS = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())
            await MainActor.run {
                self.finishDeferredLoad(decoded, preparation: preparation, elapsedMS: elapsedMS)
            }
        }
    }

    private func finishDeferredLoad(_ decoded: [SavedSession],
                                    preparation: DeferredLoadPreparation,
                                    elapsedMS: Int) {
        sessions = decoded
        cachedLatestReferenceValidatedHRV = preparation.latestReferenceValidatedHRV
        cachedCanonicalSessions = preparation.canonicalSessions
        cachedHomeSavedAggregate = nil
        cachedCurrentCollectionStatus = nil
        cachedSessionBackupStatus = preparation.backupStatus

        if preparation.didRebuildBaseline {
            baseline = preparation.baseline
            let preparedBaseline = preparation.baseline
            Task.detached(priority: .utility) {
                preparedBaseline.save()
            }
        }
        cachedHomeDashboardDiagnostics = nil
        publishDashboardRevision()

        WHOOPDebugLog("WHOOPDBG session_store_load status=ok sessions=%d baseline_rebuilt=%d elapsed_ms=%d",
              decoded.count,
              preparation.didRebuildBaseline ? 1 : 0,
              elapsedMS)
    }

    private nonisolated static func prepareDeferredLoad(decoded: [SavedSession],
                                                        baseline: PersonalBaseline,
                                                        profile: AthleteProfile,
                                                        sessionFileURL: URL) -> DeferredLoadPreparation {
        let shouldRebuildBaseline = shouldRebuildBaselineAfterLoading(decoded, baseline: baseline)
        let preparedBaseline = shouldRebuildBaseline
            ? rebuildBaseline(from: decoded, previousBaseline: baseline, profile: profile)
            : baseline
        return DeferredLoadPreparation(
            latestReferenceValidatedHRV: decoded.first(where: { $0.referenceValidatedHRV != nil })?.referenceValidatedHRV,
            canonicalSessions: makeCanonicalSessions(from: decoded),
            baseline: preparedBaseline,
            didRebuildBaseline: shouldRebuildBaseline,
            backupStatus: computeSessionBackupStatus(currentSessions: decoded,
                                                     baseline: preparedBaseline,
                                                     profile: profile,
                                                     sessionFileURL: sessionFileURL)
        )
    }

    private nonisolated static func shouldRebuildBaselineAfterLoading(_ decoded: [SavedSession],
                                                                      baseline: PersonalBaseline) -> Bool {
        guard !decoded.isEmpty else { return false }
        if baseline.updated == nil || baseline.restingSampleCount == 0 {
            return true
        }
        let hasLocalHRVInSessions = decoded.contains { $0.localRMSSD != nil }
        if baseline.hrvSampleCount == 0 && hasLocalHRVInSessions {
            return true
        }
        return false
    }

    private nonisolated static func rebuildBaseline(from sessions: [SavedSession],
                                                    previousBaseline: PersonalBaseline,
                                                    profile: AthleteProfile) -> PersonalBaseline {
        let previousRest = previousBaseline.restingInt
        var rebuilt = PersonalBaseline()
        for session in sessions.sorted(by: { $0.start < $1.start }) {
            let rest = rebuilt.restingInt ?? previousRest ?? session.restingStable
            let evidence = session.baselineLearningEvidence(rest: rest, maxHR: profile.maxHR)
            guard evidence.accepted else { continue }
            rebuilt.learn(fromResting: evidence.value,
                          hrv: session.localRMSSD ?? 0,
                          at: session.end)
        }
        return rebuilt
    }

    private func save() -> Bool {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            WHOOPDebugLog("WHOOPDBG session_store_save status=failed error=%@", error.localizedDescription)
            return false
        }
    }
}

// MARK: - History UI

struct HistoryView: View {
    @ObservedObject var store: SessionStore
    @State private var snapshot: HistorySnapshot

    init(store: SessionStore) {
        _store = ObservedObject(wrappedValue: store)
        _snapshot = State(initialValue: HistorySnapshot(store: store))
    }

    var body: some View {
        ZStack {
            AtriaDashboardBackdrop()
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    historyHeroCard

                    if snapshot.sessions.isEmpty {
                        ContentUnavailableView("No sessions yet",
                                               systemImage: "heart.text.square",
                                               description: Text("Finish a session to save it here."))
                            .frame(maxWidth: .infinity)
                            .padding(20)
                            .atriaCard(cornerRadius: 22, emphasis: .soft)
                    } else {
                        historySection(title: "Trends", subtitle: "Saved readiness over time") {
                            TrendSummaryView(summaries: snapshot.trends)
                        }

                        historySection(title: "Daily rollups", subtitle: "Recent saved evidence") {
                            LazyVStack(spacing: 12) {
                                ForEach(snapshot.rollups.prefix(14), id: \.day) { rollup in
                                    DailyRollupRow(rollup: rollup)
                                }
                            }
                        }

                        if !snapshot.detections.isEmpty {
                            historySection(title: "Detected", subtitle: "Local-only activity findings") {
                                LazyVStack(spacing: 12) {
                                    ForEach(snapshot.detections.prefix(5)) { detection in
                                        DetectionRow(detection: detection)
                                    }
                                }
                            }
                        }

                        if snapshot.sessions.count >= 2 {
                            historySection(title: "Resting trend", subtitle: "Saved resting HR over time") {
                                RestingTrendChart(sessions: snapshot.sessions,
                                                  baseline: store.baseline.restingInt)
                            }
                        }

                        historySection(title: "Saved sessions", subtitle: "Open any session for detail") {
                            LazyVStack(spacing: 12) {
                                ForEach(snapshot.sessions) { session in
                                    NavigationLink {
                                        SessionDetail(session: session)
                                    } label: {
                                        historySessionRow(session)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            store.deleteSession(id: session.id)
                                        } label: {
                                            Label("Delete session", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 36)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshSnapshot)
        .onChange(of: store.dashboardRevision) { _, _ in
            refreshSnapshot()
        }
        .onChange(of: store.profile) { _, _ in
            refreshSnapshot()
        }
    }

    private var historyHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text(snapshot.sessions.isEmpty
                         ? "Saved trends and session detail appear here once you finish a session."
                         : "A lighter archive for saved sessions, trends, and local activity evidence.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text("\(snapshot.sessions.count)")
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
            }

            HStack(spacing: 12) {
                HistoryQuickStat(label: "Sessions", value: "\(snapshot.sessions.count)")
                HistoryQuickStat(label: "Detected", value: "\(snapshot.detections.count)")
                HistoryQuickStat(label: "Baseline", value: "\(store.baseline.hrvSampleCount)/7")
            }
        }
        .padding(18)
        .atriaCard(cornerRadius: 22, emphasis: .soft)
    }

    private func historySection<Content: View>(title: String,
                                               subtitle: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            content()
        }
        .padding(18)
        .atriaCard(cornerRadius: 22, emphasis: .soft)
    }

    private func historySessionRow(_ session: SavedSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.label.isEmpty ? "Session" : session.label)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 12)
                Text(session.start, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(session.durationText) · avg \(session.avg) · peak \(session.peak) · rest \(session.resting)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                historySessionPill("HRV", value: session.hrv.map(String.init) ?? "Learning", tint: .purple)
                historySessionPill("Samples", value: "\(session.points.count)", tint: .cyan)
                historySessionPill("TRIMP",
                                   value: String(format: "%.1f",
                                                 session.trimp(rest: session.restingStable,
                                                               max: max(store.profile.maxHR, session.restingStable + 1))),
                                   tint: .orange)
            }
        }
        .padding(16)
        .atriaInsetCard(cornerRadius: 22, tint: .white)
    }

    private func historySessionPill(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HistoryPillBackground(tint: tint))
    }

    private func refreshSnapshot() {
        snapshot = HistorySnapshot(store: store)
    }
}

@MainActor
private struct HistorySnapshot {
    let sessions: [SavedSession]
    let detections: [ActivityDetection]
    let trends: [TrendSummary]
    let rollups: [DailyRollup]

    init(store: SessionStore) {
        let rest = store.baseline.restingInt ?? 60
        let maxHR = store.profile.maxHR
        self.sessions = store.sessions
        self.detections = store.detectedActivities(rest: rest, maxHR: maxHR)
        self.trends = store.trendSummaries(rest: rest, maxHR: maxHR)
        self.rollups = store.dailyRollups(rest: rest, maxHR: maxHR)
    }
}

private struct HistoryQuickStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .atriaInsetCard(cornerRadius: 22, tint: .white)
    }
}

private struct HistoryPillBackground: View {
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(colorScheme == .dark ? tint.opacity(0.10) : tint.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.20), lineWidth: 1)
            }
    }
}

private struct DailyRollupRow: View {
    let rollup: DailyRollup

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: rollup.workouts > 0 ? "figure.run" : (rollup.activityCandidates > 0 ? "figure.strengthtraining.traditional" : "calendar"))
                .foregroundStyle(rollup.workouts > 0 ? .green : (rollup.activityCandidates > 0 ? .orange : .secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rollup.day, style: .date)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(String(format: "strain %.1f", rollup.strain))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("\(rollup.sessions) sessions · \(formatMinutes(rollup.duration)) saved · \(rollup.activityCandidates) activity · \(rollup.restCandidates) rest · \(rollup.workouts) auto workout · \(rollup.confirmedWorkouts) confirmed · \(rollup.sleepReady) sleep ready · \(rollup.sleepCandidates) candidate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                if rollup.activityCandidates > 0 && rollup.workouts == 0 {
                    Text("Activity candidates are local evidence only; workout export stays gated.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                if rollup.restCandidates > 0 {
                    Text("Rest candidates are recovery context only; they do not count as sleep.")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}

struct TrendSummaryView: View {
    let summaries: [TrendSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrendChartOverview(summaries: summaries)
            ForEach(summaries) { summary in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(summary.days)d")
                            .font(.headline.monospacedDigit())
                        Spacer()
                        Text("\(summary.coverageDays)/\(summary.requiredCoverageDays)d required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(summary.confidence)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(summary.confidence == "high" ? .green : .orange)
                        Text("\(summary.coveragePercent)% coverage · \(summary.sessions) sessions")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        trendMetric("Rec", value: summary.avgRecovery.map { "\($0)%" })
                        trendMetric("HRV", value: summary.avgHRV.map { "\($0)" })
                        trendMetric("RHR", value: summary.avgRHR.map { "\($0)" })
                        trendMetric("Resp", value: summary.avgRespiratoryRate.map { String(format: "%.1f", $0) })
                        trendMetric("Strain", value: summary.avgStrain.map { String(format: "%.1f", $0) })
                    }
                    Text(summary.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if summary.blockers != "none" {
                        Text("Blocked: \(summary.blockers.replacingOccurrences(of: "+", with: " · "))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }
                    if !summary.anomalies.isEmpty {
                        Text(summary.anomalies.joined(separator: " · "))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
                if summary.id != summaries.last?.id {
                    Divider()
                }
            }
        }
        .onAppear { logTrendChartUI() }
    }

    private func trendMetric(_ label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "learning")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func logTrendChartUI() {
        let recoveryPoints = summaries.filter { $0.avgRecovery != nil }.count
        let hrvPoints = summaries.filter { $0.avgHRV != nil }.count
        let rhrPoints = summaries.filter { $0.avgRHR != nil }.count
        let strainPoints = summaries.filter { $0.avgStrain != nil }.count
        let respiratoryRatePoints = summaries.filter { $0.avgRespiratoryRate != nil }.count
        let coverageMin = summaries.map(\.coveragePercent).min() ?? 0
        let confidence = summaries.map(\.confidence).joined(separator: ",")
        let windows = summaries.map { "\($0.days)d" }.joined(separator: ",")
        let anomalyFlags = summaries.map { chartAnomalyFlags($0.anomalies) }.joined(separator: ",")
        let requiredCoverageDays = summaries.map { "\($0.days)d:\($0.requiredCoverageDays)" }.joined(separator: ",")
        let windowBlockers = summaries.map { "\($0.days)d:\($0.blockers)" }.joined(separator: ",")
        let blockers = chartBlockers(recoveryPoints: recoveryPoints,
                                     hrvPoints: hrvPoints,
                                     coverageMin: coverageMin,
                                     hrvStates: summaries.map(\.hrvState),
                                     confidence: summaries.map(\.confidence))
        WHOOPDebugLog("WHOOPDBG trend_chart_ui windows=%@ recovery_points=%d hrv_points=%d rhr_points=%d strain_points=%d respiratory_rate_points=%d coverage_min=%d required_coverage_days=%@ confidence=%@ hrv_state=%@ anomaly_flags=%@ window_blockers=%@ blockers=%@",
              windows,
              recoveryPoints,
              hrvPoints,
              rhrPoints,
              strainPoints,
              respiratoryRatePoints,
              coverageMin,
              requiredCoverageDays,
              confidence,
              summaries.map(\.hrvState).joined(separator: ","),
              anomalyFlags,
              windowBlockers,
              blockers)
    }

    private func chartAnomalyFlags(_ anomalies: [String]) -> String {
        guard !anomalies.isEmpty else { return "none" }
        return anomalies.map { $0.replacingOccurrences(of: " ", with: "_") }.joined(separator: ",")
    }

    private func chartBlockers(recoveryPoints: Int,
                               hrvPoints: Int,
                               coverageMin: Int,
                               hrvStates: [String],
                               confidence: [String]) -> String {
        var blockers: [String] = []
        if confidence.contains("learning") || coverageMin < 70 {
            blockers.append("coverage_below_70pct")
        }
        if hrvStates.contains("learning") {
            blockers.append("hrv_learning")
        }
        if recoveryPoints == 0 {
            blockers.append("recovery_points_missing")
        }
        if hrvPoints == 0 {
            blockers.append("hrv_points_missing")
        }
        return blockers.isEmpty ? "none" : blockers.joined(separator: "+")
    }
}

private struct TrendChartOverview: View {
    let summaries: [TrendSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrendCoverageChart(summaries: summaries)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                TrendMetricChart(title: "Recovery",
                                 unit: "%",
                                 color: .green,
                                 values: summaries.map { TrendMetricPoint(days: $0.days, value: $0.avgRecovery.map(Double.init)) })
                TrendMetricChart(title: "HRV",
                                 unit: "ms",
                                 color: .purple,
                                 values: summaries.map { TrendMetricPoint(days: $0.days, value: $0.avgHRV.map(Double.init)) })
                TrendMetricChart(title: "RHR",
                                 unit: "bpm",
                                 color: .teal,
                                 values: summaries.map { TrendMetricPoint(days: $0.days, value: $0.avgRHR.map(Double.init)) })
                TrendMetricChart(title: "Resp",
                                 unit: "/min",
                                 color: .cyan,
                                 values: summaries.map { TrendMetricPoint(days: $0.days, value: $0.avgRespiratoryRate) })
                TrendMetricChart(title: "Strain",
                                 unit: "",
                                 color: .orange,
                                 values: summaries.map { TrendMetricPoint(days: $0.days, value: $0.avgStrain) })
            }
        }
    }
}

private struct TrendMetricPoint: Identifiable {
    let days: Int
    let value: Double?

    var id: Int { days }
    var label: String { "\(days)d" }
}

private struct TrendCoverageChart: View {
    let summaries: [TrendSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Coverage")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(summaries.map { "\($0.days)d \($0.coverageDays)/\($0.requiredCoverageDays)" }.joined(separator: " · "))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Chart(summaries) { summary in
                BarMark(x: .value("Window", "\(summary.days)d"),
                        y: .value("Coverage", summary.coveragePercent))
                    .foregroundStyle(summary.confidence == "high" ? Color.green : Color.orange)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis(.hidden)
            .frame(height: 72)
        }
    }
}

private struct TrendMetricChart: View {
    let title: String
    let unit: String
    let color: Color
    let values: [TrendMetricPoint]

    private var plotted: [TrendMetricPoint] {
        values.filter { $0.value != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(latestText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(plotted.isEmpty ? .secondary : color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if plotted.isEmpty {
                Text("learning")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
                    .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Chart(plotted) { point in
                    LineMark(x: .value("Window", point.label),
                             y: .value(title, point.value ?? 0))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(color)
                    PointMark(x: .value("Window", point.label),
                              y: .value(title, point.value ?? 0))
                        .foregroundStyle(color)
                }
                .chartYAxis(.hidden)
                .frame(height: 54)
            }
        }
        .frame(minHeight: 82, alignment: .top)
    }

    private var latestText: String {
        guard let value = plotted.last?.value else { return "learning" }
        if title == "Strain" {
            return String(format: "%.1f%@", value, unit)
        }
        return "\(Int(value.rounded()))\(unit)"
    }
}

struct DetectionRow: View {
    let detection: ActivityDetection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(detection.kind.rawValue, systemImage: icon)
                    .font(.headline)
                Spacer()
                Text(detection.confidence.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(confidenceColor)
            }
            Text("\(detection.start, style: .time)-\(detection.end, style: .time) · \(durationText) · avg \(detection.avgHR) · peak \(detection.peakHR)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(detection.reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch detection.kind {
        case .activityCandidate: return "figure.walk.motion"
        case .workout: return "figure.run"
        case .sleepCandidate: return "bed.double"
        case .restCandidate: return "chair.lounge"
        }
    }

    private var confidenceColor: Color {
        switch detection.confidence {
        case .low: return .orange
        case .medium: return .teal
        case .high: return .green
        }
    }

    private var durationText: String {
        let s = Int(detection.duration)
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 60)m"
    }
}

struct SessionDetail: View {
    let session: SavedSession
    private var maxHR: Int { AthleteProfile.load().maxHR }
    private var displayedPoints: [SavedSession.Point] {
        downsampledPoints(session.points)
    }

    var body: some View {
        ZStack {
            AtriaDashboardBackdrop()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    Chart(Array(displayedPoints.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("t", p.t), y: .value("bpm", p.bpm))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(.red.gradient)
                    }
                    .frame(height: 220)
                    .padding()
                    .atriaCard(cornerRadius: 22, emphasis: .soft)

                    HStack(spacing: 0) {
                        stat("Resting", session.resting)
                        stat("Average", session.avg)
                        stat("Peak", session.peak)
                        VStack(spacing: 2) {
                            Text(String(format: "%.1f",
                                Metrics.strain(fromTRIMP: session.trimp(rest: session.restingStable, max: maxHR))))
                                .font(.title2.weight(.semibold).monospacedDigit())
                            Text("Strain").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .atriaCard(cornerRadius: 22, emphasis: .soft)

                    TimeInZoneView(session: session, maxHR: maxHR)
                        .padding()
                        .atriaCard(cornerRadius: 22, emphasis: .soft)
                }
                .padding()
            }
        }
        .navigationTitle(session.label.isEmpty ? "Session" : session.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func downsampledPoints(_ points: [SavedSession.Point], targetCount: Int = 320) -> [SavedSession.Point] {
        guard points.count > targetCount, targetCount > 1 else { return points }
        let maxIndex = points.count - 1
        let step = Double(maxIndex) / Double(targetCount - 1)
        return (0..<targetCount).map { sample in
            let index = min(maxIndex, Int((Double(sample) * step).rounded()))
            return points[index]
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
