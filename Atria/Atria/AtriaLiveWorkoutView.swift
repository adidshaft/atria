import SwiftUI
import UIKit
import MapKit

/// Immutable physiology inputs captured when Start succeeds. A workout is one
/// calculation epoch: editing age, weight, sex, HR max, or baseline while it is
/// running must not splice two incompatible TRIMP/calorie models together.
struct AtriaWorkoutCalculationContext: Codable, Equatable {
    let restingHeartRate: Int
    let profile: AthleteProfile

    var maximumHeartRate: Int { profile.maxHR }

    init(restingHeartRate: Int, profile: AthleteProfile) {
        self.restingHeartRate = max(1, restingHeartRate)
        self.profile = profile
    }
}

/// Identifiable wrapper so a live workout can drive `.fullScreenCover(item:)`.
struct AtriaWorkoutSession: Identifiable {
    let id = UUID()
    let start: Date
    /// User-picked workout target. These optional fields keep older call sites
    /// source-compatible while making the session—not a presented SwiftUI
    /// surface—the canonical owner across minimize, restoration and ActivityKit.
    var targetStrain: Double? = nil
    var targetZone: Int? = nil
    var lowerTargetZone: Int? = nil
    var upperTargetZone: Int? = nil
    var activityType: AtriaWorkoutActivityType = .other
    /// Immutable detector coordinate selected when Start commits. Activity
    /// edits change presentation/route behavior, never step accounting.
    let stepSourceVersion: AtriaWorkoutStepSourceVersion
    var startingStepCount: Int = 0
    /// Strap steps accumulated during completed pause windows. These are
    /// removed from workout-only steps while the day total remains monotonic.
    var pausedStepCount: Int = 0
    /// Day-total anchor captured exactly when the current pause began.
    var pauseStartedStepCount: Int? = nil
    /// False once a pause/resume boundary could not be paired with a fresh,
    /// action-time strap coordinate. Time and route state may still be exact,
    /// but workout-only steps must then remain unavailable instead of folding
    /// stale/replayed movement into the total.
    var stepAccountingIsComplete: Bool = true
    var startingDayStrain: Double = 0
    /// Nil only for legacy in-memory/restored sessions created before this
    /// field existed; those use a one-time current-profile fallback.
    var calculationContext: AtriaWorkoutCalculationContext? = nil

    init(start: Date,
         targetStrain: Double? = nil,
         targetZone: Int? = nil,
         lowerTargetZone: Int? = nil,
         upperTargetZone: Int? = nil,
         activityType: AtriaWorkoutActivityType = .other,
         stepSourceVersion: AtriaWorkoutStepSourceVersion = .strapAccelerometerV1,
         startingStepCount: Int = 0,
         pausedStepCount: Int = 0,
         pauseStartedStepCount: Int? = nil,
         stepAccountingIsComplete: Bool = true,
         startingDayStrain: Double = 0,
         calculationContext: AtriaWorkoutCalculationContext? = nil) {
        self.start = start
        self.targetStrain = targetStrain
        self.targetZone = targetZone
        self.lowerTargetZone = lowerTargetZone
        self.upperTargetZone = upperTargetZone
        self.activityType = activityType
        self.stepSourceVersion = stepSourceVersion
        self.startingStepCount = startingStepCount
        self.pausedStepCount = pausedStepCount
        self.pauseStartedStepCount = pauseStartedStepCount
        self.stepAccountingIsComplete = stepAccountingIsComplete
        self.startingDayStrain = startingDayStrain
        self.calculationContext = calculationContext
    }

    /// The user's target choice re-derived from the persisted fields, if any.
    var targetChoice: AtriaWorkoutTargetChoice? {
        if let targetStrain { return .strain(targetStrain) }
        if let targetZone { return .zone(targetZone) }
        return nil
    }

    /// Commits the mutually-exclusive target override into the session that
    /// owns the workout. Keeping this state here (instead of in the presented
    /// HUD) means minimizing or rebuilding that view cannot reset the choice.
    mutating func setTargetChoice(_ choice: AtriaWorkoutTargetChoice?) {
        switch choice {
        case .strain(let value):
            targetStrain = value
            targetZone = nil
        case .zone(let rawZone):
            targetStrain = nil
            targetZone = rawZone
        case nil:
            targetStrain = nil
            targetZone = nil
        }
    }
}

struct AtriaLiveWorkoutSensorMetrics: Equatable {
    var trimp: Double = 0
    var activeCalories: Double?
    /// True only after at least one bounded, non-paused HR interval was
    /// integrated. A lone sample is not enough evidence for load or energy.
    var hasEvidence = false
    /// False when a late pause/exclusion reaches into a journal prefix that has
    /// already rolled out of memory. The retained number is internal context,
    /// not a precise total that may be shown or shared.
    var isComplete = true
}

struct AtriaLiveWorkoutStepProjection: Equatable {
    typealias Availability = AtriaLiveSensorAvailability

    /// Keep the in-workout HUD on the same source clock as the Lock Screen and
    /// widgets. R10 motion normally publishes about once per second; after 15
    /// seconds without a valid frame the last count is context, not live data.
    static let freshnessInterval: TimeInterval = 15
    static let futureTolerance: TimeInterval = 5

    let count: Int?
    let isEstimated: Bool
    let capturedAt: Date?
    let availability: Availability

    static let unavailable = AtriaLiveWorkoutStepProjection(count: nil,
                                                             isEstimated: false,
                                                             capturedAt: nil,
                                                             availability: .unavailable)

    static func make(totalCount: Int,
                     startingCount: Int,
                     pausedCount: Int = 0,
                     pauseStartedCount: Int? = nil,
                     hasStepEvidence: Bool,
                     isValidated: Bool,
                     capturedAt: Date?,
                     isReconnecting: Bool,
                     now: Date = Date()) -> Self {
        let openPauseCount = pauseStartedCount.map { max(0, totalCount - $0) } ?? 0
        let count = hasStepEvidence
            ? max(0, totalCount - startingCount - max(0, pausedCount) - openPauseCount)
            : nil
        let fresh = capturedAt.map {
            $0 <= now.addingTimeInterval(futureTolerance)
                && now.timeIntervalSince($0) <= freshnessInterval
        } ?? false
        let availability: Availability
        if count != nil, fresh {
            availability = .live
        } else if isReconnecting {
            availability = .reconnecting
        } else if count != nil || capturedAt != nil {
            availability = .stale
        } else {
            availability = .unavailable
        }
        return Self(count: count,
                    isEstimated: count != nil && !isValidated,
                    capturedAt: capturedAt,
                    availability: availability)
    }

    var liveCount: Int? { availability == .live ? count : nil }
    var liveCapturedAt: Date? { availability == .live ? capturedAt : nil }
    var hudText: String {
        switch availability {
        case .live:
            guard let count else { return "--" }
            return isEstimated ? "~\(count)" : "\(count)"
        // "syncing" matches the Live Activity's steps copy and, unlike
        // "reconnecting", fits the third-width HUD chip at XXXL Dynamic Type.
        case .reconnecting: return "syncing"
        case .stale: return "stale"
        case .unavailable: return "--"
        }
    }
    var accessibilityText: String {
        switch availability {
        case .live:
            guard let count else { return "Steps unavailable" }
            return isEstimated ? "Approximately \(count) workout steps" : "\(count) workout steps"
        case .reconnecting: return "Workout steps reconnecting"
        case .stale: return "Workout step signal stale"
        case .unavailable: return "Workout steps unavailable"
        }
    }
}

/// Presentation-only freshness for the CRC-valid strap motion stream. This is
/// intentionally independent from step detection: a detector may need several
/// frames before its count changes, while the UI can still truthfully say that
/// raw motion is arriving.
struct AtriaLiveWorkoutMotionProjection: Equatable {
    static let freshnessInterval: TimeInterval = 15
    static let futureTolerance: TimeInterval = 5

    let capturedAt: Date?
    let availability: AtriaLiveSensorAvailability
    let ageSeconds: Int?
    /// A fresh individual frame is not enough to call workout-step motion
    /// ready. The workout lease supplies this only after its dense R10 proof.
    let hasContinuousValidatedMotion: Bool

    static let unavailable = AtriaLiveWorkoutMotionProjection(capturedAt: nil,
                                                               availability: .unavailable,
                                                               ageSeconds: nil,
                                                               hasContinuousValidatedMotion: false)

    static func make(capturedAt: Date?,
                     hasContinuousValidatedMotion: Bool = true,
                     isReconnecting: Bool,
                     now: Date = Date()) -> Self {
        let age = capturedAt.map { max(0, now.timeIntervalSince($0)) }
        let isFresh = capturedAt.map {
            $0 <= now.addingTimeInterval(futureTolerance)
                && now.timeIntervalSince($0) <= freshnessInterval
        } ?? false
        let availability: AtriaLiveSensorAvailability
        if isFresh && hasContinuousValidatedMotion {
            availability = .live
        } else if isReconnecting {
            availability = .reconnecting
        } else if isFresh {
            // A new frame arrived, but the 12-of-15-second proof has not
            // completed. Keep steps unavailable rather than implying a count
            // can already be trusted.
            availability = .unavailable
        } else if capturedAt != nil {
            availability = .stale
        } else {
            availability = .unavailable
        }
        return Self(capturedAt: capturedAt,
                    availability: availability,
                    ageSeconds: age.map { Int($0.rounded(.down)) },
                    hasContinuousValidatedMotion: hasContinuousValidatedMotion)
    }

    var compactLabel: String {
        switch availability {
        case .live: return "Motion live"
        case .reconnecting: return "Motion syncing"
        case .stale:
            return ageSeconds.map { "Motion gap · \($0)s" } ?? "Motion gap"
        case .unavailable:
            return capturedAt == nil ? "Motion pending" : "Motion qualifying"
        }
    }

    var accessibilityText: String {
        guard let ageSeconds else { return compactLabel }
        return "\(compactLabel), last strap motion \(ageSeconds) seconds ago"
    }
}

/// One pause-aware elapsed-time definition shared by the foreground workout
/// clock and ActivityKit. Keeping this pure also makes relaunch projections
/// deterministic from the durable pending intent.
enum AtriaWorkoutMovingDuration {
    static func project(startedAt: Date,
                        excludedIntervals: [ExcludedInterval],
                        pauseStartedAt: Date?,
                        now: Date) -> TimeInterval {
        guard now > startedAt else { return 0 }
        let completed = excludedIntervals.reduce(0.0) { total, interval in
            let clampedStart = max(interval.start, startedAt)
            let clampedEnd = min(interval.end, now)
            return total + max(0, clampedEnd.timeIntervalSince(clampedStart))
        }
        let openPause = pauseStartedAt.map {
            max(0, now.timeIntervalSince(max($0, startedAt)))
        } ?? 0
        return max(0, now.timeIntervalSince(startedAt) - completed - openPause)
    }
}

struct AtriaLiveWorkoutMetricProjection: Equatable {
    var strain: Double = 0
    var activeCalories: Double?
    var steps: AtriaLiveWorkoutStepProjection = .unavailable
    var motion: AtriaLiveWorkoutMotionProjection = .unavailable
    var sensorAvailability: AtriaLiveSensorAvailability = .unavailable
    var sensorCapturedAt: Date?
    var hasSensorEvidence = false
    var loadIsComplete = true

    static let empty = AtriaLiveWorkoutMetricProjection()

    var coachingIsLive: Bool {
        hasSensorEvidence && loadIsComplete && sensorAvailability == .live
    }

    var strainHUDText: String {
        hasSensorEvidence && loadIsComplete ? String(format: "%.1f", strain) : "--"
    }

    var activeCaloriesHUDText: String {
        guard hasSensorEvidence, loadIsComplete, let activeCalories else { return "--" }
        return "≈ \(Int(activeCalories.rounded())) kcal"
    }

    var strainHUDTitle: String {
        hasSensorEvidence && sensorAvailability != .live ? "Last strain" : "Strain"
    }

    var activeCaloriesHUDTitle: String {
        hasSensorEvidence && sensorAvailability != .live ? "Last active" : "Active"
    }

    var sensorStatusTitle: String? {
        if !loadIsComplete { return "Load incomplete" }
        guard hasSensorEvidence else { return "Waiting for strap" }
        switch sensorAvailability {
        case .live: return nil
        case .reconnecting: return "Reconnecting"
        case .stale: return "Signal paused"
        case .unavailable: return "Signal unavailable"
        }
    }

    var sensorStatusDetail: String? {
        if !loadIsComplete {
            return "A late pause overlaps finalized sensor history, so no precise total is shown."
        }
        guard hasSensorEvidence else { return "Strain and calories begin with continuous heart rate." }
        switch sensorAvailability {
        case .live: return nil
        case .reconnecting: return "Holding the last recorded totals."
        case .stale, .unavailable: return "Showing the last recorded totals."
        }
    }
}

/// Narrow publication owner for the rapidly changing workout metrics. Home
/// retains this object by identity without observing it; only the presented
/// workout HUD subscribes. Keeping the value out of `AtriaHomeView`'s own
/// `@State` prevents every 750 ms strain/calorie/step refresh from rebuilding
/// the complete tab shell behind the full-screen workout.
@MainActor
final class AtriaLiveWorkoutMetricStore: ObservableObject {
    @Published private(set) var state: AtriaLiveWorkoutMetricProjection

    init(state: AtriaLiveWorkoutMetricProjection = .empty) {
        self.state = state
    }

    func publishIfChanged(_ next: AtriaLiveWorkoutMetricProjection) {
        guard next != state else { return }
        state = next
    }
}

/// Incremental, pause-aware Banister load and active energy owned by one
/// explicit workout. Keeping these separate from day totals avoids subtracting
/// two nonlinear 0...21 scores and prevents a visible jump at finalization.
struct AtriaLiveWorkoutTRIMPAccumulator {
    private var startedAt: Date?
    /// First timestamp of the currently replayable BLE buffer. Load already
    /// integrated before this buffer is immutable once the bounded journal
    /// rolls forward and is retained in the completed-prefix fields below.
    private var segmentStartTimestamp: Date?
    /// Earliest previous-sample timestamp whose following pair belongs to the
    /// current segment rather than the frozen predecessor. This can be later
    /// than `segmentStartTimestamp` for an overlapping forward replacement.
    private var segmentIntegrationFloor: Date?
    private var sampleCount = 0
    private var lastTimestamp: Date?
    private var rest = 0
    private var maxHR = 0
    private var sex: AthleteProfile.BiologicalSex = .unspecified
    private var profile: AthleteProfile?
    private var excludedIntervals: [ExcludedInterval] = []
    private var value = 0.0
    private var activeCalories: Double?
    private var hasEvidence = false
    private var completedPrefixValue = 0.0
    private var completedPrefixCalories: Double?
    private var completedPrefixHasEvidence = false
    private var completedPrefixEndTimestamp: Date?
    private var loadIsComplete = true

    mutating func trimp(samples: [HRSample],
                        startedAt: Date,
                        rest: Int,
                        maxHR: Int,
                        sex: AthleteProfile.BiologicalSex,
                        excludedIntervals: [ExcludedInterval]) -> Double {
        metrics(samples: samples,
                startedAt: startedAt,
                rest: rest,
                maxHR: maxHR,
                sex: sex,
                profile: nil,
                excludedIntervals: excludedIntervals).trimp
    }

    mutating func metrics(samples: [HRSample],
                          startedAt: Date,
                          rest: Int,
                          maxHR: Int,
                          profile: AthleteProfile,
                          excludedIntervals: [ExcludedInterval]) -> AtriaLiveWorkoutSensorMetrics {
        metrics(samples: samples,
                startedAt: startedAt,
                rest: rest,
                maxHR: maxHR,
                sex: profile.biologicalSex,
                profile: profile,
                excludedIntervals: excludedIntervals)
    }

    private mutating func metrics(samples: [HRSample],
                                  startedAt: Date,
                                  rest: Int,
                                  maxHR: Int,
                                  sex: AthleteProfile.BiologicalSex,
                                  profile: AthleteProfile?,
                                  excludedIntervals: [ExcludedInterval]) -> AtriaLiveWorkoutSensorMetrics {
        let normalized = Self.normalized(excludedIntervals)
        if self.startedAt == startedAt,
           loadIsComplete,
           completedPrefixHasEvidence,
           let completedPrefixEndTimestamp,
           Self.exclusionsAddCoverage(
                normalized,
                comparedTo: self.excludedIntervals,
                from: startedAt,
                through: completedPrefixEndTimestamp
           ) {
            // The discarded prefix cannot be replayed with this newly arrived
            // exclusion. Retain its internal accumulator only for monotonic
            // continuity, but permanently fail the user-facing precision gate.
            loadIsComplete = false
        }
        let configurationMatches = self.startedAt == startedAt
            && self.rest == rest
            && self.maxHR == maxHR
            && self.sex == sex
            && self.profile == profile
            && self.excludedIntervals == normalized
        let samplePrefixMatches = sampleCount > 0
            && sampleCount <= samples.count
            && lastTimestamp == samples[sampleCount - 1].t
        let sameReplayableSegment = segmentStartTimestamp != nil
            && segmentStartTimestamp == samples.first?.t
        guard maxHR > rest else {
            reset(startedAt: startedAt,
                  samples: samples,
                  rest: rest,
                  maxHR: maxHR,
                  sex: sex,
                  profile: profile,
                  excludedIntervals: excludedIntervals)
            return AtriaLiveWorkoutSensorMetrics(activeCalories: profile?.hasEnergyProfile == true ? 0 : nil,
                                                  hasEvidence: false)
        }
        // A bounded BLE journal can roll to a new, strictly-forward segment
        // containing only its first sample. That is not evidence that the
        // workout's already-integrated load vanished. Preserve the completed
        // prefix and seed the new segment so its next sample can extend it.
        if samples.count <= 1, lastTimestamp != nil {
            if let only = samples.first, only.t > (lastTimestamp ?? .distantFuture) {
                freezeCompletedPrefix()
                segmentStartTimestamp = only.t
                segmentIntegrationFloor = only.t
                sampleCount = 1
                lastTimestamp = only.t
            }
            self.startedAt = startedAt
            self.rest = rest
            self.maxHR = maxHR
            self.sex = sex
            self.profile = profile
            self.excludedIntervals = normalized
            return AtriaLiveWorkoutSensorMetrics(trimp: value,
                                                  activeCalories: activeCalories,
                                                  hasEvidence: hasEvidence,
                                                  isComplete: loadIsComplete)
        }
        guard samples.count > 1 else {
            reset(startedAt: startedAt,
                  samples: samples,
                  rest: rest,
                  maxHR: maxHR,
                  sex: sex,
                  profile: profile,
                  excludedIntervals: excludedIntervals)
            return AtriaLiveWorkoutSensorMetrics(activeCalories: profile?.hasEnergyProfile == true ? 0 : nil,
                                                  hasEvidence: false)
        }
        let canExtend = configurationMatches && samplePrefixMatches
        let continuationIndex: Int? = {
            guard !samplePrefixMatches,
                  let lastTimestamp,
                  let newest = samples.last?.t,
                  newest > lastTimestamp else { return nil }
            if let exactBoundary = samples.lastIndex(where: { $0.t == lastTimestamp }),
               exactBoundary + 1 < samples.count {
                return exactBoundary + 1
            }
            if let first = samples.first?.t, first > lastTimestamp {
                // A true segment roll has no pair spanning the transport gap.
                // Start at the first complete pair inside the new segment.
                return 1
            }
            // Overlapping replacement without the exact boundary: skip the
            // straddling pair rather than double-counting part of the prefix.
            return samples.indices.dropFirst().first {
                samples[$0 - 1].t >= lastTimestamp
            }
        }()
        if !samplePrefixMatches,
           continuationIndex == nil,
           hasEvidence,
           let lastTimestamp,
           let newest = samples.last?.t,
           newest <= lastTimestamp {
            // A delayed callback from an older segment cannot roll live strain
            // or energy backward.
            return AtriaLiveWorkoutSensorMetrics(trimp: value,
                                                  activeCalories: activeCalories,
                                                  hasEvidence: hasEvidence,
                                                  isComplete: loadIsComplete)
        }
        let startsNewReplayableSegment = !samplePrefixMatches
            && !sameReplayableSegment
            && continuationIndex != nil
        if startsNewReplayableSegment {
            // Once a bounded journal advances, neither a later pause interval
            // nor a profile edit can replay the discarded samples. Freeze the
            // exact completed prefix once and recompute only the current
            // replayable segment when its configuration changes.
            freezeCompletedPrefix()
            segmentStartTimestamp = samples.first?.t
            if let continuationIndex {
                segmentIntegrationFloor = samples[max(0, continuationIndex - 1)].t
            }
        }
        var total = canExtend ? value : completedPrefixValue
        var calories: Double? = canExtend ? activeCalories : completedPrefixCalories
        if calories == nil,
           !completedPrefixHasEvidence,
           profile?.hasEnergyProfile == true {
            calories = 0
        }
        var integratedEvidence = canExtend ? hasEvidence : completedPrefixHasEvidence
        // The BLE session is an all-day, bounded continuity buffer. A workout
        // can begin near its tail, so replaying from index 1 after a target,
        // profile or pause change needlessly walks hours of pre-workout HR on
        // the main actor. Binary-search directly to the first pair fully inside
        // this workout; subsequent updates remain append-only via `sampleCount`.
        var index: Int
        if canExtend {
            index = sampleCount
        } else if startsNewReplayableSegment {
            index = continuationIndex ?? 1
        } else if sameReplayableSegment {
            index = Self.firstIntegrationIndex(
                samples: samples,
                startedAt: max(startedAt, segmentIntegrationFloor ?? startedAt)
            )
        } else {
            index = continuationIndex
                ?? Self.firstIntegrationIndex(samples: samples, startedAt: startedAt)
        }
        let strainParameters = AtriaAnalytics.Strain.banisterParameters(for: sex)
        let strainConfiguration = AtriaStrainLoadModel.Configuration(
            restingBPM: Double(rest),
            maximumBPM: Double(maxHR),
            intensityMultiplier: strainParameters.multiplier,
            intensityCoefficient: strainParameters.coefficient,
            mode: .workout,
            maximumGap: AtriaAnalytics.Strain.maximumLoadEvidenceGap
        )
        while index < samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            let excluded = normalized.contains { interval in
                previous.t <= interval.end && current.t >= interval.start
            }
            if previous.t >= startedAt,
               current.t >= startedAt,
               !excluded {
                let evaluation = AtriaStrainLoadModel.evaluateInterval(
                    from: AtriaStrainLoadModel.Sample(
                        timestamp: previous.t.timeIntervalSinceReferenceDate,
                        bpm: Double(previous.bpm)
                    ),
                    to: AtriaStrainLoadModel.Sample(
                        timestamp: current.t.timeIntervalSinceReferenceDate,
                        bpm: Double(current.bpm)
                    ),
                    configuration: strainConfiguration
                )
                if evaluation.isAccepted {
                    integratedEvidence = true
                    total += evaluation.load
                    if let profile, profile.hasEnergyProfile {
                        let delta = Metrics.dayCalories([
                            Metrics.HeartRateEnergySample(t: previous.t, bpm: previous.bpm),
                            Metrics.HeartRateEnergySample(t: current.t, bpm: current.bpm),
                        ], rest: rest, profile: profile) ?? 0
                        if calories != nil {
                            calories = (calories ?? 0) + delta
                        }
                    }
                }
            }
            index += 1
        }
        self.startedAt = startedAt
        if segmentStartTimestamp == nil {
            segmentStartTimestamp = samples.first?.t
            segmentIntegrationFloor = startedAt
        }
        sampleCount = samples.count
        lastTimestamp = samples.last?.t
        self.rest = rest
        self.maxHR = maxHR
        self.sex = sex
        self.profile = profile
        self.excludedIntervals = normalized
        value = total
        activeCalories = calories
        hasEvidence = integratedEvidence
        return AtriaLiveWorkoutSensorMetrics(trimp: total,
                                              activeCalories: activeCalories,
                                              hasEvidence: integratedEvidence,
                                              isComplete: loadIsComplete)
    }

    mutating func clear() {
        startedAt = nil
        segmentStartTimestamp = nil
        segmentIntegrationFloor = nil
        sampleCount = 0
        lastTimestamp = nil
        value = 0
        activeCalories = nil
        hasEvidence = false
        completedPrefixValue = 0
        completedPrefixCalories = nil
        completedPrefixHasEvidence = false
        completedPrefixEndTimestamp = nil
        loadIsComplete = true
        profile = nil
        excludedIntervals = []
    }

    private mutating func reset(startedAt: Date,
                                samples: [HRSample],
                                rest: Int,
                                maxHR: Int,
                                sex: AthleteProfile.BiologicalSex,
                                profile: AthleteProfile?,
                                excludedIntervals: [ExcludedInterval]) {
        self.startedAt = startedAt
        segmentStartTimestamp = samples.first?.t
        segmentIntegrationFloor = startedAt
        sampleCount = samples.count
        lastTimestamp = samples.last?.t
        self.rest = rest
        self.maxHR = maxHR
        self.sex = sex
        self.profile = profile
        self.excludedIntervals = Self.normalized(excludedIntervals)
        value = 0
        activeCalories = profile?.hasEnergyProfile == true ? 0 : nil
        hasEvidence = false
        completedPrefixValue = 0
        completedPrefixCalories = nil
        completedPrefixHasEvidence = false
        completedPrefixEndTimestamp = nil
        loadIsComplete = true
    }

    /// Commits the current total exactly once as the immutable predecessor of
    /// the next replayable BLE segment. Assigning rather than adding prevents
    /// overlapping forward replacements from double-counting an older prefix.
    private mutating func freezeCompletedPrefix() {
        completedPrefixValue = value
        completedPrefixCalories = activeCalories
        completedPrefixHasEvidence = hasEvidence
        completedPrefixEndTimestamp = lastTimestamp
    }

    /// Returns true when the new exclusion union covers any point in the frozen
    /// prefix that the prior exclusion union did not. Exact boundary contact is
    /// conservative because the integration rule excludes a pair touching it.
    private static func exclusionsAddCoverage(_ next: [ExcludedInterval],
                                              comparedTo previous: [ExcludedInterval],
                                              from lowerBound: Date,
                                              through upperBound: Date) -> Bool {
        guard upperBound >= lowerBound else { return false }
        let old = normalized(previous)
        for interval in normalized(next) {
            let start = max(lowerBound, interval.start)
            let end = min(upperBound, interval.end)
            guard end >= start else { continue }
            if end == start {
                if !old.contains(where: { $0.start <= start && $0.end >= end }) {
                    return true
                }
                continue
            }
            var cursor = start
            for prior in old where prior.end >= cursor && prior.start <= end {
                if prior.start > cursor { return true }
                cursor = max(cursor, prior.end)
                if cursor >= end { break }
            }
            if cursor < end { return true }
        }
        return false
    }

    private static func normalized(_ intervals: [ExcludedInterval]) -> [ExcludedInterval] {
        intervals.filter { $0.end > $0.start }.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }
    }

    /// Returns the first current-sample index whose previous/current pair can
    /// both belong to this workout. Samples are chronologically ordered by the
    /// BLE pipeline, allowing a logarithmic prefix skip instead of an O(day)
    /// scan whenever the incremental cache must be rebuilt.
    nonisolated static func firstIntegrationIndex(samples: [HRSample],
                                                  startedAt: Date) -> Int {
        var lowerBound = 0
        var upperBound = samples.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if samples[middle].t < startedAt {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound < samples.count else { return samples.count }
        return min(samples.count, max(1, lowerBound + 1))
    }

    /// A live pause is semantically open-ended until Resume. Representing it
    /// with `Date()` made its value different on every 750 ms UI publication,
    /// which invalidated this accumulator and replayed the workout repeatedly.
    /// A stable distant-future end excludes the same live samples without
    /// changing identity; Resume replaces it with one real closed interval.
    nonisolated static func effectiveExcludedIntervals(
        closedIntervals: [ExcludedInterval],
        openPauseStartedAt: Date?
    ) -> [ExcludedInterval] {
        guard let openPauseStartedAt else { return closedIntervals }
        return closedIntervals + [ExcludedInterval(start: openPauseStartedAt,
                                                    end: .distantFuture)]
    }
}

/// Small, durable description of a user-started workout. Heart-rate samples
/// remain in the session journal; this record preserves the user's intent and
/// editing state until a confirmed workout has been written. It deliberately
/// survives an app termination or a sparse-background-data save failure.
struct AtriaPendingWorkoutIntent: Codable, Equatable {
    static let defaultsKey = "atria.pendingWorkoutIntent.v1"
    /// BLE continuity protection is intentionally bounded. An abandoned intent
    /// must not keep reconnect/backfill policy in workout mode forever, while a
    /// legitimate long event still needs to survive ordinary backgrounding and
    /// process termination.
    static let bleContinuityMaxAge: TimeInterval = 24 * 60 * 60
    static let bleContinuityFutureTolerance: TimeInterval = 5 * 60

    let startedAt: Date
    var endedAt: Date?
    var activityType: String
    var strengthSets: [LoggedSet]
    var excludedIntervals: [ExcludedInterval]
    var pauseStartedAt: Date? = nil
    var targetStrain: Double? = nil
    var targetZone: Int? = nil
    var lowerTargetZone: Int? = nil
    var upperTargetZone: Int? = nil
    let startingStepCount: Int
    /// Frozen at Start. Missing legacy values decode to the coordinate those
    /// builds actually used, so an upgrade cannot reinterpret their anchors.
    let stepSourceVersion: AtriaWorkoutStepSourceVersion
    var pausedStepCount: Int = 0
    var pauseStartedStepCount: Int? = nil
    var stepAccountingIsComplete: Bool = true
    var completedStepCount: Int? = nil
    var completedStepsAreEstimated: Bool? = nil
    var completedStepsCapturedAt: Date? = nil
    let startingDayStrain: Double
    var calculationContext: AtriaWorkoutCalculationContext? = nil
    /// Monotonic per-workout checkpoint order. It prevents an older detached
    /// UI checkpoint from reverting newer sets, pauses or targets.
    var persistenceRevision: UInt64 = 0

    private enum CodingKeys: String, CodingKey {
        case startedAt
        case endedAt
        case activityType
        case strengthSets
        case excludedIntervals
        case pauseStartedAt
        case targetStrain
        case targetZone
        case lowerTargetZone
        case upperTargetZone
        case startingStepCount
        case stepSourceVersion
        case pausedStepCount
        case pauseStartedStepCount
        case stepAccountingIsComplete
        case completedStepCount
        case completedStepsAreEstimated
        case completedStepsCapturedAt
        case startingDayStrain
        case calculationContext
        case persistenceRevision
    }

    /// Workout recovery records can outlive the build that created them. New
    /// fields therefore decode with conservative defaults instead of making an
    /// otherwise valid in-progress workout unreadable after an app update.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        activityType = try values.decodeIfPresent(String.self, forKey: .activityType)
            ?? AtriaWorkoutActivityType.other.rawValue
        strengthSets = try values.decodeIfPresent([LoggedSet].self, forKey: .strengthSets) ?? []
        excludedIntervals = try values.decodeIfPresent([ExcludedInterval].self,
                                                        forKey: .excludedIntervals) ?? []
        pauseStartedAt = try values.decodeIfPresent(Date.self, forKey: .pauseStartedAt)
        targetStrain = try values.decodeIfPresent(Double.self, forKey: .targetStrain)
        targetZone = try values.decodeIfPresent(Int.self, forKey: .targetZone)
        lowerTargetZone = try values.decodeIfPresent(Int.self, forKey: .lowerTargetZone)
        upperTargetZone = try values.decodeIfPresent(Int.self, forKey: .upperTargetZone)
        startingStepCount = try values.decodeIfPresent(Int.self, forKey: .startingStepCount) ?? 0
        stepSourceVersion = try values.decodeIfPresent(
            AtriaWorkoutStepSourceVersion.self,
            forKey: .stepSourceVersion
        ) ?? .strapAccelerometerV1
        pausedStepCount = try values.decodeIfPresent(Int.self, forKey: .pausedStepCount) ?? 0
        pauseStartedStepCount = try values.decodeIfPresent(Int.self,
                                                            forKey: .pauseStartedStepCount)
        stepAccountingIsComplete = try values.decodeIfPresent(
            Bool.self,
            forKey: .stepAccountingIsComplete
        ) ?? true
        completedStepCount = try values.decodeIfPresent(Int.self, forKey: .completedStepCount)
        completedStepsAreEstimated = try values.decodeIfPresent(Bool.self,
                                                                 forKey: .completedStepsAreEstimated)
        completedStepsCapturedAt = try values.decodeIfPresent(Date.self,
                                                               forKey: .completedStepsCapturedAt)
        startingDayStrain = try values.decodeIfPresent(Double.self, forKey: .startingDayStrain) ?? 0
        calculationContext = try values.decodeIfPresent(
            AtriaWorkoutCalculationContext.self,
            forKey: .calculationContext
        )
        persistenceRevision = try values.decodeIfPresent(UInt64.self,
                                                          forKey: .persistenceRevision) ?? 0
    }

    init(startedAt: Date,
         endedAt: Date?,
         activityType: String,
         strengthSets: [LoggedSet],
         excludedIntervals: [ExcludedInterval],
         pauseStartedAt: Date? = nil,
         targetStrain: Double? = nil,
         targetZone: Int? = nil,
         lowerTargetZone: Int? = nil,
         upperTargetZone: Int? = nil,
         startingStepCount: Int,
         stepSourceVersion: AtriaWorkoutStepSourceVersion = .strapAccelerometerV1,
         pausedStepCount: Int = 0,
         pauseStartedStepCount: Int? = nil,
         stepAccountingIsComplete: Bool = true,
         completedStepCount: Int? = nil,
         completedStepsAreEstimated: Bool? = nil,
         completedStepsCapturedAt: Date? = nil,
         startingDayStrain: Double,
         calculationContext: AtriaWorkoutCalculationContext? = nil,
         persistenceRevision: UInt64 = 0) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activityType = activityType
        self.strengthSets = strengthSets
        self.excludedIntervals = excludedIntervals
        self.pauseStartedAt = pauseStartedAt
        self.targetStrain = targetStrain
        self.targetZone = targetZone
        self.lowerTargetZone = lowerTargetZone
        self.upperTargetZone = upperTargetZone
        self.startingStepCount = startingStepCount
        self.stepSourceVersion = stepSourceVersion
        self.pausedStepCount = max(0, pausedStepCount)
        self.pauseStartedStepCount = pauseStartedStepCount
        self.stepAccountingIsComplete = stepAccountingIsComplete
        self.completedStepCount = completedStepCount.map { max(0, $0) }
        self.completedStepsAreEstimated = completedStepCount == nil ? nil : completedStepsAreEstimated
        self.completedStepsCapturedAt = completedStepCount == nil ? nil : completedStepsCapturedAt
        self.startingDayStrain = startingDayStrain
        self.calculationContext = calculationContext
        self.persistenceRevision = persistenceRevision
    }

    var resolvedActivityType: AtriaWorkoutActivityType {
        AtriaWorkoutActivityType(rawValue: activityType) ?? .other
    }

    var targetChoice: AtriaWorkoutTargetChoice? {
        if let targetStrain { return .strain(targetStrain) }
        if let targetZone { return .zone(targetZone) }
        return nil
    }

    static func load(defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    @discardableResult
    func save(defaults: UserDefaults) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.defaultsKey)
        // Starting or ending a workout must not become visible until its exact
        // crash-recovery payload is readable from the persistence authority.
        // `set` has no failure result, so verify both the stored bytes and the
        // decoded value before allowing the UI transaction to continue.
        guard defaults.data(forKey: Self.defaultsKey) == data,
              Self.load(defaults: defaults) == self else { return false }
        // `synchronize()` is deprecated, can block the main actor during every
        // workout checkpoint, and its Boolean is not a persistence-authority
        // result. Exact byte + decode readback is the immediate contract; the
        // defaults daemon performs the durable flush without stalling workout
        // controls, background transitions, or Lock Screen actions.
        return true
    }

    static func clear(defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Completion work is asynchronous. Never let an older route/session
    /// callback clear a newer workout that replaced the singleton intent while
    /// evidence was being prepared or persisted.
    @discardableResult
    static func clearIfUnchanged(_ expected: Self,
                                 defaults: UserDefaults) -> Bool {
        guard load(defaults: defaults) == expected else { return false }
        clear(defaults: defaults)
        return true
    }

    static func isActiveForBLEContinuity(defaults: UserDefaults,
                                         now: Date = Date(),
                                         maxAge: TimeInterval = bleContinuityMaxAge) -> Bool {
        guard let intent = load(defaults: defaults), intent.endedAt == nil else { return false }
        let age = now.timeIntervalSince(intent.startedAt)
        return age >= -bleContinuityFutureTolerance && age <= maxAge
    }

    /// Honest end for an abandoned (never-ended) workout intent. The 24 h
    /// continuity bound already stops transport ownership, but nothing
    /// terminalized the intent itself, so a forgotten workout ran a live
    /// timer forever (a 134 h elapsed chip was observed on 2026-07-17).
    /// The recovery end is capped at the continuity bound: the saved
    /// workout's stats come from the actual samples in that window, and its
    /// coverage percentage discloses how much of it was really worn.
    /// Returns nil while the intent is fresh, already ended, or absent.
    static func abandonedRecoveryEndDate(
        intent: Self?,
        now: Date = Date(),
        maxAge: TimeInterval = bleContinuityMaxAge
    ) -> Date? {
        guard let intent, intent.endedAt == nil else { return nil }
        guard now.timeIntervalSince(intent.startedAt) > maxAge else { return nil }
        return intent.startedAt.addingTimeInterval(maxAge)
    }

    /// Produces the pause exclusions that belong to a completed workout. The
    /// visible End button normally resumes first, but Lock Screen actions,
    /// process recovery and suspension can all finalize without that view
    /// callback. Completion must therefore close an open pause itself.
    func finalizedExcludedIntervals() -> [ExcludedInterval] {
        guard let endedAt, let pauseStartedAt else { return excludedIntervals }
        let start = max(startedAt, pauseStartedAt)
        guard endedAt > start else { return excludedIntervals }
        return excludedIntervals + [ExcludedInterval(start: start, end: endedAt)]
    }

    // Production persistence is file-backed. The explicit UserDefaults
    // overloads above remain only for decoding old records and isolated tests.
    static func load() -> Self? {
        AtriaPendingWorkoutIntentStore.shared.snapshot
    }

    static func preparePersistence() async -> Bool {
        await AtriaPendingWorkoutIntentStore.shared.prepare()
    }

    func createPersisted() async -> Bool {
        await AtriaPendingWorkoutIntentStore.shared.createIfAbsent(self)
    }

    func replacePersisted(expected: Self) async -> Bool {
        await AtriaPendingWorkoutIntentStore.shared.replace(expected: expected, with: self)
    }

    func persistProgress() async -> Bool {
        await AtriaPendingWorkoutIntentStore.shared.persistProgress(self)
    }

    func persistTerminal() async -> AtriaPendingWorkoutIntent? {
        await AtriaPendingWorkoutIntentStore.shared.persistTerminal(self)
    }

    static func clearIfUnchanged(_ expected: Self) async -> Bool {
        await AtriaPendingWorkoutIntentStore.shared.clearIfUnchanged(expected)
    }

    static func isActiveForBLEContinuity(now: Date = Date(),
                                         maxAge: TimeInterval = bleContinuityMaxAge) -> Bool {
        AtriaPendingWorkoutIntentStore.shared.isActiveForBLEContinuity(now: now,
                                                                       maxAge: maxAge)
    }
}

/// Crash-recovery authority for the one explicit workout that can be active at
/// a time. All disk access is serialized off-main; hot BLE continuity reads use
/// only the lock-protected snapshot populated after a verified atomic commit.
final class AtriaPendingWorkoutIntentStore: @unchecked Sendable {
    static let shared = AtriaPendingWorkoutIntentStore()

    private enum PreparedState {
        case unprepared
        case ready(AtriaPendingWorkoutIntent?)
        case corrupt
    }

    private let directoryURL: URL
    private let fileURL: URL
    private let legacyDefaults: UserDefaults?
    private let ioQueue: DispatchQueue
    private let stateLock = NSLock()
    /// Progress checkpoints are valuable crash-recovery detail, but they are
    /// never allowed to form an unbounded FIFO in front of the user's End
    /// intent.  The token is protected separately from `stateLock` because it
    /// governs queue admission, not the durable authority itself.
    private let progressSchedulingLock = NSLock()
    private var queuedProgressID: UUID?
    private var cancelledProgressIDs = Set<UUID>()
    private var state: PreparedState = .unprepared
    private var persistenceWasOnMainThread = false

    var lastPersistenceWasOnMainThread: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return persistenceWasOnMainThread
    }

    init(directoryURL: URL? = nil,
         legacyDefaults: UserDefaults? = .standard,
         queueLabel: String = "com.atria.pending-workout-intent") {
        let root = directoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first!
                .appendingPathComponent("Atria", isDirectory: true)
        self.directoryURL = root
        self.fileURL = root.appendingPathComponent("pending-workout-intent-v1.json")
        self.legacyDefaults = legacyDefaults
        // Start/End is a direct user action. This tiny atomic intent is the
        // crash-recovery authority for a workout, so do not leave it behind
        // broad utility work while the UI is waiting for acknowledgement.
        self.ioQueue = DispatchQueue(label: queueLabel, qos: .userInitiated)
    }

    var snapshot: AtriaPendingWorkoutIntent? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .ready(let intent) = state else { return nil }
        return intent
    }

    /// Read-only launch credential for radio policy. Unlike
    /// `isActiveForBLEContinuity`, an unprepared/corrupt store is not treated
    /// as proof that a workout exists. The file is tiny and this path performs
    /// no migration or write; it is used before the async store hydration has
    /// completed.
    func launchSnapshot() -> AtriaPendingWorkoutIntent? {
        if let snapshot { return snapshot }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AtriaPendingWorkoutIntent.self,
                                         from: data)
    }

    var isPrepared: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if case .unprepared = state { return false }
        return true
    }

    /// Cold hydration is a third state, not proof that no workout exists.
    /// Conservatively retain workout-grade BLE continuity for this very short
    /// window; once hydration completes, ordinary age/terminal rules apply.
    func isActiveForBLEContinuity(
        now: Date = Date(),
        maxAge: TimeInterval = AtriaPendingWorkoutIntent.bleContinuityMaxAge
    ) -> Bool {
        stateLock.lock()
        let localState = state
        stateLock.unlock()
        switch localState {
        case .unprepared:
            beginPreparing()
            return true
        case .corrupt:
            // Corruption is fail-closed for mutation but must not downgrade the
            // radio and destroy evidence that may still recover from the strap.
            return true
        case .ready(let intent):
            guard let intent, intent.endedAt == nil else { return false }
            let age = now.timeIntervalSince(intent.startedAt)
            return age >= -AtriaPendingWorkoutIntent.bleContinuityFutureTolerance
                && age <= maxAge
        }
    }

    @discardableResult
    func prepare() async -> Bool {
        await performIO { self.prepareLocked() }
    }

    func createIfAbsent(_ intent: AtriaPendingWorkoutIntent) async -> Bool {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        return await performIO {
            let beganAt = ProcessInfo.processInfo.systemUptime
            let saved: Bool
            if self.prepareLocked(), self.currentLocked() == nil {
                saved = self.commitLocked(intent)
            } else {
                saved = false
            }
            AtriaDebugLog("ATRIADBG workout_intent_write operation=create queue_wait_ms=%d write_ms=%d revision=%llu saved=%d",
                          Int(((beganAt - requestedAt) * 1_000).rounded()),
                          Int(((ProcessInfo.processInfo.systemUptime - beganAt) * 1_000).rounded()),
                          intent.persistenceRevision,
                          saved ? 1 : 0)
            return saved
        }
    }

    func replace(expected: AtriaPendingWorkoutIntent,
                 with replacement: AtriaPendingWorkoutIntent) async -> Bool {
        await performIO {
            guard self.prepareLocked(), self.currentLocked() == expected else { return false }
            guard expected.endedAt == nil || replacement == expected else { return false }
            guard replacement == expected
                    || replacement.persistenceRevision > expected.persistenceRevision else { return false }
            return self.commitLocked(replacement)
        }
    }

    /// Coalescible UI checkpoints may arrive after End. Match the workout token
    /// and reject a terminal authority so late sets/pause bindings cannot reopen
    /// a workout whose exact end has already committed.
    func persistProgress(_ intent: AtriaPendingWorkoutIntent) async -> Bool {
        await withCheckedContinuation { continuation in
            enqueueProgress(intent) { saved in
                continuation.resume(returning: saved)
            }
        }
    }

    /// Queues an intermediate checkpoint in call order without creating an
    /// unstructured Task whose scheduler order could differ from UI order.
    func enqueueProgress(
        _ intent: AtriaPendingWorkoutIntent,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let id = UUID()
        let queuedAt = ProcessInfo.processInfo.systemUptime
        progressSchedulingLock.lock()
        if let previous = queuedProgressID {
            // Its closure may already be present in the serial queue, but has
            // not begun an atomic write.  Mark it cancelled rather than making
            // End wait for stale sets/pause state.
            cancelledProgressIDs.insert(previous)
        }
        queuedProgressID = id
        progressSchedulingLock.unlock()
        ioQueue.async {
            self.progressSchedulingLock.lock()
            let cancelled = self.cancelledProgressIDs.remove(id) != nil
            if self.queuedProgressID == id {
                self.queuedProgressID = nil
            }
            guard !cancelled else {
                self.progressSchedulingLock.unlock()
                Task { @MainActor in completion(false) }
                return
            }
            // From this point the write is the single current atomic operation
            // and must finish; a terminal write will be placed immediately
            // behind it rather than risking a torn authority.
            self.progressSchedulingLock.unlock()
            let beganAt = ProcessInfo.processInfo.systemUptime
            let saved = self.persistProgressLocked(intent)
            AtriaDebugLog("ATRIADBG workout_intent_write operation=progress queue_wait_ms=%d write_ms=%d revision=%llu saved=%d",
                          Int(((beganAt - queuedAt) * 1_000).rounded()),
                          Int(((ProcessInfo.processInfo.systemUptime - beganAt) * 1_000).rounded()),
                          intent.persistenceRevision,
                          saved ? 1 : 0)
            Task { @MainActor in completion(saved) }
        }
    }

    func persistTerminal(_ requested: AtriaPendingWorkoutIntent) async -> AtriaPendingWorkoutIntent? {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        // Cancel only work that has not begun.  An in-flight atomic progress
        // write remains valid recovery evidence and is allowed to complete;
        // terminal is the very next meaningful write after it.
        progressSchedulingLock.withLock {
            if let queued = queuedProgressID {
                cancelledProgressIDs.insert(queued)
                queuedProgressID = nil
            }
        }
        return await performIO {
            let beganAt = ProcessInfo.processInfo.systemUptime
            let result = self.persistTerminalLocked(requested)
            AtriaDebugLog("ATRIADBG workout_intent_write operation=terminal queue_wait_ms=%d write_ms=%d terminal_saved=%d",
                          Int(((beganAt - requestedAt) * 1_000).rounded()),
                          Int(((ProcessInfo.processInfo.systemUptime - beganAt) * 1_000).rounded()),
                          result == nil ? 0 : 1)
            return result
        }
    }

    /// Must run only on ioQueue. The final write includes the same atomic
    /// write/readback/decode proof as every other intent mutation.
    private func persistTerminalLocked(_ requested: AtriaPendingWorkoutIntent) -> AtriaPendingWorkoutIntent? {
        guard prepareLocked(),
              requested.endedAt != nil,
              let current = currentLocked(),
              current.startedAt == requested.startedAt,
              current.endedAt == nil else { return nil }
            // The serial queue may have committed a newer Lock Screen pause or
            // resume immediately before End. Preserve that canonical metadata
            // and apply only terminal evidence from the End tap.
            var terminal = requested
            let completionUsesCanonicalPauseAndSteps =
                current.excludedIntervals == requested.excludedIntervals
                && current.pauseStartedAt == requested.pauseStartedAt
                && current.startingStepCount == requested.startingStepCount
                && current.pausedStepCount == requested.pausedStepCount
                && current.pauseStartedStepCount == requested.pauseStartedStepCount
                && current.stepAccountingIsComplete == requested.stepAccountingIsComplete
            // Lock Screen and Home can each close a different pause just before
            // End. Keep both exact intervals without duplicating either one.
            for interval in current.excludedIntervals
                where !terminal.excludedIntervals.contains(interval) {
                terminal.excludedIntervals.append(interval)
            }
            terminal.excludedIntervals.sort { lhs, rhs in
                lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
            }
            if let currentPause = current.pauseStartedAt {
                let homeAlreadyClosedCurrentPause = requested.excludedIntervals.contains {
                    $0.start == currentPause && $0.end >= currentPause
                }
                if !homeAlreadyClosedCurrentPause {
                    terminal.pauseStartedAt = currentPause
                    terminal.pauseStartedStepCount = current.pauseStartedStepCount
                }
            }
            terminal.pausedStepCount = max(current.pausedStepCount,
                                           requested.pausedStepCount)
            terminal.stepAccountingIsComplete = current.stepAccountingIsComplete
                && requested.stepAccountingIsComplete
                && completionUsesCanonicalPauseAndSteps
            if !terminal.stepAccountingIsComplete {
                terminal.completedStepCount = nil
                terminal.completedStepsAreEstimated = nil
                terminal.completedStepsCapturedAt = nil
            }
            terminal.persistenceRevision = .max
            return self.commitLocked(terminal) ? terminal : nil
    }

    func clearIfUnchanged(_ expected: AtriaPendingWorkoutIntent) async -> Bool {
        await performIO {
            guard self.prepareLocked(), self.currentLocked() == expected else { return false }
            do {
                if FileManager.default.fileExists(atPath: self.fileURL.path) {
                    try FileManager.default.removeItem(at: self.fileURL)
                }
                self.publish(.ready(nil))
                return true
            } catch {
                return false
            }
        }
    }

    private func performIO<T: Sendable>(_ operation: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: operation()) }
        }
    }

    /// Starts cold hydration before CoreBluetooth can make continuity-policy
    /// decisions. It never performs file I/O on the caller.
    func beginPreparing() {
        ioQueue.async { _ = self.prepareLocked() }
    }

    private func persistProgressLocked(_ intent: AtriaPendingWorkoutIntent) -> Bool {
        guard prepareLocked(),
              intent.endedAt == nil,
              let current = currentLocked(),
              current.startedAt == intent.startedAt,
              current.endedAt == nil,
              intent.persistenceRevision > current.persistenceRevision else { return false }
        return commitLocked(intent)
    }

    /// Must run only on ioQueue.
    private func prepareLocked() -> Bool {
        stateLock.lock()
        let alreadyPrepared: Bool
        switch state {
        case .unprepared: alreadyPrepared = false
        case .ready: alreadyPrepared = true
        case .corrupt:
            stateLock.unlock()
            return false
        }
        stateLock.unlock()
        if alreadyPrepared { return true }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL),
                  let intent = try? JSONDecoder().decode(AtriaPendingWorkoutIntent.self,
                                                         from: data) else {
                publish(.corrupt)
                return false
            }
            publish(.ready(intent))
            legacyDefaults?.removeObject(forKey: AtriaPendingWorkoutIntent.defaultsKey)
            return true
        }

        if let legacyDefaults,
           let data = legacyDefaults.data(forKey: AtriaPendingWorkoutIntent.defaultsKey) {
            guard let legacy = try? JSONDecoder().decode(AtriaPendingWorkoutIntent.self,
                                                         from: data) else {
                publish(.corrupt)
                return false
            }
            guard commitLocked(legacy) else { return false }
            legacyDefaults.removeObject(forKey: AtriaPendingWorkoutIntent.defaultsKey)
            return true
        }
        publish(.ready(nil))
        return true
    }

    private func currentLocked() -> AtriaPendingWorkoutIntent? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .ready(let intent) = state else { return nil }
        return intent
    }

    private func commitLocked(_ intent: AtriaPendingWorkoutIntent) -> Bool {
        guard let data = try? JSONEncoder().encode(intent) else { return false }
        do {
            stateLock.lock()
            persistenceWasOnMainThread = Thread.isMainThread
            stateLock.unlock()
            try FileManager.default.createDirectory(at: directoryURL,
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL,
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let readback = try Data(contentsOf: fileURL)
            guard readback == data,
                  try JSONDecoder().decode(AtriaPendingWorkoutIntent.self,
                                           from: readback) == intent else { return false }
            publish(.ready(intent))
            return true
        } catch {
            return false
        }
    }

    private func publish(_ newState: PreparedState) {
        stateLock.lock()
        state = newState
        stateLock.unlock()
    }
}

struct AtriaWorkoutStartConfiguration: Equatable {
    var activityType: AtriaWorkoutActivityType = .other
    /// An optional, wearer-chosen finish-line for this workout. This is kept
    /// independent from the heart-rate range below: a zone coaches intensity
    /// moment-to-moment, while strain answers when the session is complete.
    var targetStrain: Double? = nil
    /// A presentation-only snapshot used to disclose the actual BPM bounds of
    /// the selected zones before a workout begins. The session still captures
    /// its immutable calculation profile at Start.
    var maxHeartRate: Int? = nil
    var lowerTargetZone: Int = HRZone.fatBurn.rawValue
    var upperTargetZone: Int = HRZone.aerobic.rawValue

    var normalizedZoneRange: ClosedRange<Int> {
        min(lowerTargetZone, upperTargetZone)...max(lowerTargetZone, upperTargetZone)
    }
}

enum AtriaWorkoutRecentActivityStore {
    static let key = "atria.workout.recentActivityTypes"
    static let maximumCount = 6

    static func activities(defaults: UserDefaults = .standard) -> [AtriaWorkoutActivityType] {
        (defaults.stringArray(forKey: key) ?? [])
            .compactMap(AtriaWorkoutActivityType.init(rawValue:))
    }

    /// A type becomes recent only after the primary Start action has handed the
    /// normalized configuration to the workout owner. Merely browsing the rail,
    /// opening More, or cancelling the sheet must not rewrite workout history.
    static func recordStarted(_ type: AtriaWorkoutActivityType,
                              defaults: UserDefaults = .standard) {
        let existing = defaults.stringArray(forKey: key) ?? []
        defaults.set(([type.rawValue] + existing.filter { $0 != type.rawValue })
            .prefix(maximumCount)
            .map { $0 },
                     forKey: key)
    }
}

enum AtriaWorkoutHeartRateBand: Equatable {
    case below, inRange, above
}

/// Stateful edge detector for strap haptics. The initial reading is silent;
/// only a real boundary transition produces a pulse pattern. A small 2 BPM
/// hysteresis prevents vibration chatter while HR sits on a boundary.
struct AtriaWorkoutZoneHapticTransition: Equatable {
    private(set) var band: AtriaWorkoutHeartRateBand?

    mutating func accept(bpm: Int, lowerBPM: Int, upperBPM: Int) -> Int? {
        guard bpm > 0, lowerBPM < upperBPM else { return nil }
        let next: AtriaWorkoutHeartRateBand
        switch band {
        case .below:
            next = bpm >= upperBPM + 2 ? .above : (bpm >= lowerBPM ? .inRange : .below)
        case .inRange:
            next = bpm < lowerBPM - 2 ? .below : (bpm > upperBPM + 2 ? .above : .inRange)
        case .above:
            next = bpm < lowerBPM - 2 ? .below : (bpm <= upperBPM ? .inRange : .above)
        case nil:
            next = bpm < lowerBPM ? .below : (bpm > upperBPM ? .above : .inRange)
        }
        let previous = band
        band = next
        guard let previous, previous != next else { return nil }
        switch (previous, next) {
        case (_, .above): return 3
        case (.above, .inRange): return 2
        case (_, .below), (.below, .inRange): return 1
        default: return nil
        }
    }
}

/// Owns zone-boundary state for the lifetime of an explicit workout, rather
/// than for the lifetime of whichever SwiftUI workout surface is visible.
/// `AtriaBLEManager` feeds this only accepted strap samples, so minimizing the
/// workout, locking the phone, or rebuilding its full-screen view cannot stop
/// coaching or create a second observer with a duplicate pulse.
struct AtriaWorkoutZoneHapticLifecycle: Equatable {
    struct Configuration: Equatable {
        let workoutStartedAt: Date
        let lowerZone: HRZone
        let upperZone: HRZone
        let maxHR: Int
        let restingHR: Int

        init?(workoutStartedAt: Date,
              lowerTargetZone: Int,
              upperTargetZone: Int,
              maxHR: Int,
              restingHR: Int = 0) {
            guard maxHR > 0 else { return nil }
            let lowerRaw = min(lowerTargetZone, upperTargetZone)
            let upperRaw = max(lowerTargetZone, upperTargetZone)
            guard let lowerZone = HRZone(rawValue: lowerRaw),
                  let upperZone = HRZone(rawValue: upperRaw) else { return nil }
            self.workoutStartedAt = workoutStartedAt
            self.lowerZone = lowerZone
            self.upperZone = upperZone
            self.maxHR = maxHR
            // A resting value only counts when it forms a valid HR-reserve
            // domain (0 < rest < max). Otherwise boundaries fall back to
            // percent-of-max so a caller without a resting baseline still coaches.
            self.restingHR = (restingHR > 0 && restingHR < maxHR) ? restingHR : 0
        }

        /// The SAME frozen HR-reserve (Karvonen) boundaries the live zone bar and
        /// the completed-workout distribution display, so the target haptic fires
        /// at the exact BPM the user is shown rather than a divergent
        /// percent-of-max value (GAP-03). Nil only when no valid resting baseline
        /// is available, in which case the boundaries degrade to percent-of-max.
        private var reserveBoundaries: AtriaHRRZoneBoundaries? {
            AtriaHRRZoneBoundaries(restingHR: restingHR, maxHR: maxHR)
        }

        var lowerBPM: Int {
            if let reserveBoundaries {
                return reserveBoundaries.lowerBPM(for: lowerZone)
            }
            return Int((Double(maxHR) * lowerZone.lowerFraction).rounded(.up))
        }

        var upperBPM: Int {
            guard let nextZone = HRZone(rawValue: upperZone.rawValue + 1) else {
                return maxHR
            }
            if let reserveBoundaries {
                return reserveBoundaries.lowerBPM(for: nextZone) - 1
            }
            return Int((Double(maxHR) * nextZone.lowerFraction).rounded(.up)) - 1
        }
    }

    private(set) var configuration: Configuration?
    private(set) var isPaused = false
    private var transition = AtriaWorkoutZoneHapticTransition()

    mutating func configure(workoutStartedAt: Date?,
                            lowerTargetZone: Int?,
                            upperTargetZone: Int?,
                            maxHR: Int,
                            restingHR: Int = 0,
                            isPaused: Bool) {
        guard let workoutStartedAt,
              let lowerTargetZone,
              let upperTargetZone,
              let next = Configuration(workoutStartedAt: workoutStartedAt,
                                       lowerTargetZone: lowerTargetZone,
                                       upperTargetZone: upperTargetZone,
                                       maxHR: maxHR,
                                       restingHR: restingHR) else {
            reset()
            return
        }
        if configuration != next || self.isPaused != isPaused {
            // A new workout/target or pause boundary establishes a fresh,
            // silent baseline. It must never vibrate merely because a view was
            // restored or because coaching resumed after an intentional pause.
            transition = AtriaWorkoutZoneHapticTransition()
        }
        configuration = next
        self.isPaused = isPaused
    }

    mutating func accept(bpm: Int) -> Int? {
        guard !isPaused, let configuration else { return nil }
        return transition.accept(bpm: bpm,
                                 lowerBPM: configuration.lowerBPM,
                                 upperBPM: configuration.upperBPM)
    }

    mutating func reset() {
        configuration = nil
        isPaused = false
        transition = AtriaWorkoutZoneHapticTransition()
    }
}

struct AtriaWorkoutStartSheet: View {
    let initial: AtriaWorkoutStartConfiguration
    let onPrepare: () async -> Void
    let onStart: (AtriaWorkoutStartConfiguration) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var configuration: AtriaWorkoutStartConfiguration
    @State private var showAllActivityTypes = false
    @State private var activitySearch = ""
    @State private var isStarting = false
    @State private var showStartError = false
    /// Rail order is frozen when the sheet opens (2026-08-01 gym-session
    /// review): tapping a chip must only mark the selection, never reorder the
    /// rail underneath the user's finger.
    @State private var compactActivityTypes: [AtriaWorkoutActivityType]

    init(initial: AtriaWorkoutStartConfiguration = .init(),
         onPrepare: @escaping () async -> Void = {},
         onStart: @escaping (AtriaWorkoutStartConfiguration) async -> Bool) {
        var resolvedInitial = initial
        if resolvedInitial.activityType == .other {
            let recent = AtriaWorkoutRecentActivityStore.activities().first
            resolvedInitial.activityType = recent ?? .walking
        }
        self.initial = resolvedInitial
        self.onPrepare = onPrepare
        self.onStart = onStart
        _configuration = State(initialValue: resolvedInitial)
        _compactActivityTypes = State(initialValue: Self.railActivityTypes(initial: resolvedInitial.activityType))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Activity")
                        .font(.title2.weight(.bold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            // Chips size to their content (2026-08-01
                            // gym-session review): the old fixed 96-point width
                            // cropped names like "Functional" to a scaled-down
                            // sliver. Full names always render.
                            ForEach(compactActivityTypes) { type in
                                activityButton(type)
                            }
                            Button {
                                showAllActivityTypes = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "magnifyingglass").font(.callout.weight(.bold))
                                    Text("More").font(.caption.weight(.bold)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: activityButtonHeight)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .frame(width: dynamicTypeSize.isAccessibilitySize ? 108 : 82)
                        }
                        .padding(.vertical, 8)
                    }
                    .contentMargins(.horizontal, 4, for: .scrollContent)
                    .scrollClipDisabled()
                    .transaction { transaction in
                        if accessibilityReduceMotion {
                            transaction.animation = nil
                        }
                    }

                    workoutTargetsHeader
                    strainTargetCard
                    heartRateTargetCard
                }
                .padding(20)
            }
            .navigationTitle("Start workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showAllActivityTypes) {
                NavigationStack {
                    List(filteredActivityTypes) { type in
                        Button {
                            selectActivity(type)
                            showAllActivityTypes = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: type.icon)
                                    .frame(width: 28, height: 28)
                                Text(type.rawValue)
                                Spacer()
                                if configuration.activityType == type {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.cyan)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .searchable(text: $activitySearch, prompt: "Search activities")
                    .navigationTitle("Activity")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showAllActivityTypes = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    var value = configuration
                    let range = value.normalizedZoneRange
                    value.lowerTargetZone = range.lowerBound
                    value.upperTargetZone = range.upperBound
                    isStarting = true
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    Task { @MainActor in
                        if await onStart(value) {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            AtriaWorkoutRecentActivityStore.recordStarted(value.activityType)
                            dismiss()
                        } else {
                            isStarting = false
                            showStartError = true
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                        }
                    }
                } label: {
                    Group {
                        if isStarting {
                            HStack(spacing: 10) {
                                startingActivityGlyph
                                Text("Starting \(configuration.activityType.rawValue)…")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                        } else {
                            Label("Start \(configuration.activityType.rawValue)", systemImage: "play.fill")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glassProminent)
                .tint(.cyan)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .disabled(isStarting)
            }
            .alert("Workout couldn't start", isPresented: $showStartError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Atria couldn't secure the workout on this iPhone. Nothing was started or lost—try again.")
            }
            .onChange(of: configuration.lowerTargetZone) { _, lower in
                // Keep the visible range valid as it is edited. Normalizing only
                // after Start made a temporary Z5–Z2 target look accepted even
                // though the persisted workout would silently reverse it.
                if configuration.upperTargetZone < lower {
                    configuration.upperTargetZone = lower
                }
            }
            .task {
                // Picker time is free latency budget. Warm only read-only
                // authorities here; the Start tap remains the sole creator of
                // the durable workout intent.
                await onPrepare()
            }
            .onChange(of: configuration.upperTargetZone) { _, upper in
                if configuration.lowerTargetZone > upper {
                    configuration.lowerTargetZone = upper
                }
            }
        }
    }

    @ViewBuilder
    private var startingActivityGlyph: some View {
        let glyph = Image(systemName: configuration.activityType.icon)
            .font(.headline.weight(.black))
        if accessibilityReduceMotion {
            glyph
        } else {
            glyph.symbolEffect(.pulse, options: .repeating)
        }
    }

    private var selectedZoneRangeText: String {
        let range = configuration.normalizedZoneRange
        return range.lowerBound == range.upperBound
            ? "Z\(range.lowerBound)"
            : "Z\(range.lowerBound)–Z\(range.upperBound)"
    }

    @ViewBuilder
    private var workoutTargetsHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text("Workout targets")
                    .font(.title2.weight(.bold))
                Text("Choose a session finish line and an intensity range. They coach different parts of the workout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Workout targets")
                    .font(.title2.weight(.bold))
                Text("Set a session finish line and an intensity range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var strainTargetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Strain target")
                        .font(.title3.weight(.bold))
                    Text(configuration.targetStrain == nil
                         ? "Follow today's guidance until you set a goal."
                         : "Your session finish-line, separate from heart-rate zones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Set strain target", isOn: strainTargetEnabled)
                    .labelsHidden()
                    .accessibilityLabel("Set a strain target")
            }

            if let target = configuration.targetStrain {
                HStack(spacing: 12) {
                    Slider(value: strainTargetBinding, in: 1...AtriaWorkoutTargetMath.strainCeiling, step: 0.5)
                        .tint(.orange)
                        .accessibilityLabel("Workout strain target")
                        .accessibilityValue(String(format: "%.1f", target))
                    Text(String(format: "%.1f", target))
                        .font(.title3.weight(.black).monospacedDigit())
                        .foregroundStyle(.orange)
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var heartRateTargetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heart-rate target")
                        .font(.title3.weight(.bold))
                    Text("Your in-session intensity range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                targetRangeBadge
            }

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 12) {
                    zoneSelector(title: "Target lower zone", selection: $configuration.lowerTargetZone)
                    zoneSelector(title: "Target upper zone", selection: $configuration.upperTargetZone)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Label("Zone coaching", systemImage: "wave.3.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.cyan)
                Text("When connected, your strap uses distinct haptic pulses as your heart rate enters or leaves this target range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHint("One pulse at the lower boundary, three above the upper boundary, and two when returning from above.")
        }
        .padding(14)
        .background(.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var strainTargetEnabled: Binding<Bool> {
        Binding(
            get: { configuration.targetStrain != nil },
            set: { enabled in
                configuration.targetStrain = enabled ? (configuration.targetStrain ?? 10) : nil
            }
        )
    }

    private var strainTargetBinding: Binding<Double> {
        Binding(
            get: { configuration.targetStrain ?? 10 },
            set: { configuration.targetStrain = min(max($0, 1), AtriaWorkoutTargetMath.strainCeiling) }
        )
    }

    private var targetRangeBadge: some View {
        Label(selectedZoneRangeText, systemImage: "scope")
            .font(.caption.weight(.black).monospacedDigit())
            .foregroundStyle(.cyan)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(.cyan.opacity(0.12), in: Capsule())
            .accessibilityLabel("Target heart rate \(selectedZoneTargetText)")
    }

    private var selectedZoneTargetText: String {
        guard let rangeText = zoneBPMRangeText(for: configuration.normalizedZoneRange) else {
            return selectedZoneRangeText
        }
        return "\(selectedZoneRangeText) · \(rangeText)"
    }

    private func zoneBPMRangeText(for range: ClosedRange<Int>) -> String? {
        guard let maxHeartRate = configuration.maxHeartRate, maxHeartRate > 0,
              let lowerZone = HRZone(rawValue: range.lowerBound),
              let upperZone = HRZone(rawValue: range.upperBound) else {
            return nil
        }
        let lower = Int((Double(maxHeartRate) * lowerZone.lowerFraction).rounded(.up))
        let nextFraction = HRZone(rawValue: upperZone.rawValue + 1)?.lowerFraction ?? 1
        let upper = max(lower, Int((Double(maxHeartRate) * nextFraction).rounded(.up)) - 1)
        return "\(lower)–\(upper) bpm"
    }

    /// The rail computed once at sheet open: initial selection, then recents,
    /// then a preferred fallback set. It deliberately does NOT track the live
    /// selection — reordering on tap moved the tapped chip out from under the
    /// user's finger (2026-08-01 gym-session review). A type chosen from the
    /// searchable catalog that is not on the rail is appended by
    /// `selectActivity`, still without reshuffling existing chips.
    private static func railActivityTypes(initial: AtriaWorkoutActivityType) -> [AtriaWorkoutActivityType] {
        let recent = AtriaWorkoutRecentActivityStore.activities()
        let preferred: [AtriaWorkoutActivityType] = [initial, .strength, .walking, .running, .cycling, .cardio]
        var seen = Set<AtriaWorkoutActivityType>()
        return ([initial] + recent + preferred)
            .filter { seen.insert($0).inserted }
            .prefix(6)
            .map { $0 }
    }

    private var filteredActivityTypes: [AtriaWorkoutActivityType] {
        let query = activitySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return AtriaWorkoutActivityType.allCases }
        return AtriaWorkoutActivityType.allCases.filter {
            $0.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    private var activityButtonHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 52 : 48
    }

    @ViewBuilder
    private func activityButton(_ type: AtriaWorkoutActivityType) -> some View {
        let isSelected = configuration.activityType == type
        let label = HStack(spacing: 6) {
            Image(systemName: type.icon).font(.callout.weight(.bold))
            Text(type.rawValue)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.black))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 14)
        .frame(minHeight: activityButtonHeight)
        .contentShape(Capsule())

        // Selected must be PROMINENT glass: plain `.glass` keeps the capsule
        // translucent, so the white label sat on a near-white surface in
        // light mode (caught by the 2026-08-01 sheet render).
        if isSelected {
            Button { selectActivity(type) } label: { label }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(.cyan)
                .accessibilityLabel(type.rawValue)
                .accessibilityValue("Selected")
        } else {
            Button { selectActivity(type) } label: { label }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .tint(.primary.opacity(0.08))
                .accessibilityLabel(type.rawValue)
                .accessibilityValue("Not selected")
        }
    }

    private func selectActivity(_ type: AtriaWorkoutActivityType) {
        // Keep the rail order stable; only append a catalog pick that is not
        // already visible so the selection can be seen without reshuffling.
        if !compactActivityTypes.contains(type) {
            compactActivityTypes.append(type)
        }
        configuration.activityType = type
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @ViewBuilder
    private func zoneSelector(title: String, selection: Binding<Int>) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                zonePicker(title: title, selection: selection)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            }
        } else {
            HStack {
                Text(title).font(.headline)
                Spacer()
                zonePicker(title: title, selection: selection)
            }
            .frame(minHeight: 52)
        }
    }

    private func zonePicker(title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(HRZone.allCases.filter { $0 != .rest }, id: \.rawValue) { zone in
                Text(zonePickerLabel(for: zone)).tag(zone.rawValue)
            }
        }
        .pickerStyle(.menu)
        .buttonStyle(.glass)
    }

    private func zonePickerLabel(for zone: HRZone) -> String {
        let range = zone.rawValue...zone.rawValue
        guard let bpm = zoneBPMRangeText(for: range) else {
            return "Z\(zone.rawValue) · \(zone.name)"
        }
        return "Z\(zone.rawValue) · \(zone.name) · \(bpm)"
    }
}

/// A user's workout target override: either a heart-rate zone (mapped to its
/// equivalent strain band, see `AtriaWorkoutTargetMath`) or a direct numeric
/// strain goal. `nil` anywhere this type is optional means "follow the auto
/// guidance" -- never a fabricated default.
enum AtriaWorkoutTargetChoice: Equatable {
    case zone(Int)
    case strain(Double)
}

/// Pure math for the workout target picker: zone -> strain band mapping and
/// the ease/hold/build cue, both unit-testable without instantiating the
/// live SwiftUI view (which needs live, connected ObservableObject stores).
enum AtriaWorkoutTargetMath {
    /// Top of the 0...21 Whoop-like strain scale already used throughout the
    /// live workout HUD (see `strainTargetProgress`'s auto-guidance fallback).
    static let strainCeiling: Double = 21.0

    /// The strain band a heart-rate zone maps to, built from the same
    /// `lowerFraction` boundaries the zone bar/target lane already render --
    /// so a picked zone and the live zone bar always agree on where each zone
    /// starts and ends.
    static func strainBand(for zone: HRZone) -> ClosedRange<Double> {
        let lower = zone.lowerFraction * strainCeiling
        let upperFraction = HRZone(rawValue: zone.rawValue + 1)?.lowerFraction ?? 1.0
        let upper = max(lower, upperFraction * strainCeiling)
        return lower...upper
    }

    /// A single representative strain target for a zone: the midpoint of its band.
    static func strainTarget(for zone: HRZone) -> Double {
        let band = strainBand(for: zone)
        return ((band.lowerBound + band.upperBound) / 2 * 10).rounded() / 10
    }

    /// Resolves the live strain target: a user override wins, otherwise the
    /// auto guidance -- so leaving the picker untouched is always identical
    /// to this feature not existing.
    static func effectiveTarget(choice: AtriaWorkoutTargetChoice?, guidanceTarget: Double?) -> Double? {
        switch choice {
        case .zone(let rawZone):
            guard let zone = HRZone(rawValue: rawZone) else { return guidanceTarget }
            return strainTarget(for: zone)
        case .strain(let value):
            return value
        case nil:
            return guidanceTarget
        }
    }

    /// Same ease/hold/build thresholds the strain-target card has always
    /// used, extracted into a pure function so it can be driven directly in
    /// tests without a live view.
    static func cue(strain: Double, target: Double?) -> String {
        guard let target else { return "building" }
        if strain >= target + 1.0 { return "ease" }
        if strain >= target { return "hold" }
        return "build"
    }
}

/// Builds a non-interactive map image asynchronously. A cold SwiftUI `Map`
/// physically blocked the Start path, while `MKMapSnapshotter` keeps map work
/// outside the latency-sensitive presentation transaction.
@MainActor
private final class AtriaLiveWorkoutMapSnapshotStore: ObservableObject {
    private struct RenderInput: @unchecked Sendable {
        let snapshot: MKMapSnapshotter.Snapshot
        let segments: [[CLLocationCoordinate2D]]
    }

    private struct RenderOutput: @unchecked Sendable {
        let image: UIImage
    }

    /// A live map is rendered only for the phone display. The previous
    /// 780x1120-point image at 3x allocated ~31 MiB for the MapKit bitmap and
    /// another ~31 MiB for the route composite on every refresh.
    nonisolated static let liveSnapshotSize = CGSize(width: 390, height: 560)
    nonisolated static let liveSnapshotScale: CGFloat = 2
    nonisolated static let maximumLiveSnapshotPixelCount =
        Int(liveSnapshotSize.width * liveSnapshotScale)
        * Int(liveSnapshotSize.height * liveSnapshotScale)
    private nonisolated static let renderQueue = DispatchQueue(
        label: "com.adidshaft.atria.live-workout-map-render",
        qos: .userInitiated
    )

    @Published private(set) var image: UIImage?
    private var snapshotter: MKMapSnapshotter?
    private var renderGeneration: UInt = 0

    func refresh(segments: [[CLLocationCoordinate2D]],
                 size: CGSize = liveSnapshotSize) async {
        renderGeneration &+= 1
        let generation = renderGeneration
        snapshotter?.cancel()
        let coordinates = segments.flatMap { $0 }
        let options = MKMapSnapshotter.Options()
        // A route fix can legitimately take tens of seconds indoors. Render a
        // real neutral world map immediately instead of leaving a black
        // placeholder that looks broken, then recenter when coordinates land.
        options.region = Self.region(for: coordinates) ?? Self.locatingRegion
        options.size = size
        options.scale = Self.liveSnapshotScale
        options.mapType = .mutedStandard
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        let request = MKMapSnapshotter(options: options)
        snapshotter = request
        do {
            let snapshot = try await request.start()
            guard !Task.isCancelled,
                  generation == renderGeneration,
                  snapshotter === request else { return }
            let rendered = await Self.renderOffMain(
                RenderInput(snapshot: snapshot, segments: segments)
            )
            guard !Task.isCancelled,
                  generation == renderGeneration,
                  snapshotter === request else { return }
            snapshotter = nil
            image = rendered.image
        } catch {
            guard !Task.isCancelled,
                  generation == renderGeneration,
                  snapshotter === request else { return }
            snapshotter = nil
            image = nil
        }
    }

    nonisolated static func region(
        for coordinates: [CLLocationCoordinate2D]
    ) -> MKCoordinateRegion? {
        guard let first = coordinates.first,
              CLLocationCoordinate2DIsValid(first) else { return nil }
        var minimumLatitude = first.latitude
        var maximumLatitude = first.latitude
        var minimumLongitude = first.longitude
        var maximumLongitude = first.longitude
        for coordinate in coordinates.dropFirst()
            where CLLocationCoordinate2DIsValid(coordinate) {
            minimumLatitude = min(minimumLatitude, coordinate.latitude)
            maximumLatitude = max(maximumLatitude, coordinate.latitude)
            minimumLongitude = min(minimumLongitude, coordinate.longitude)
            maximumLongitude = max(maximumLongitude, coordinate.longitude)
        }
        let latitudeDelta = max(0.003,
                                (maximumLatitude - minimumLatitude) * 1.65)
        let longitudeDelta = max(0.003,
                                 (maximumLongitude - minimumLongitude) * 1.65)
        return MKCoordinateRegion(
            center: .init(
                latitude: (minimumLatitude + maximumLatitude) / 2,
                longitude: (minimumLongitude + maximumLongitude) / 2
            ),
            span: .init(latitudeDelta: min(latitudeDelta, 120),
                        longitudeDelta: min(longitudeDelta, 120))
        )
    }

    nonisolated private static let locatingRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 10),
        span: MKCoordinateSpan(latitudeDelta: 115, longitudeDelta: 155)
    )

    private nonisolated static func renderOffMain(
        _ input: RenderInput
    ) async -> RenderOutput {
        await withCheckedContinuation { continuation in
            renderQueue.async {
                continuation.resume(returning: autoreleasepool {
                    RenderOutput(image: render(snapshot: input.snapshot,
                                               segments: input.segments))
                })
            }
        }
    }

    private nonisolated static func render(
        snapshot: MKMapSnapshotter.Snapshot,
        segments: [[CLLocationCoordinate2D]]
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = liveSnapshotScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size,
                                               format: format)
        return renderer.image { context in
            snapshot.image.draw(at: .zero)
            let graphics = context.cgContext
            graphics.setLineCap(.round)
            graphics.setLineJoin(.round)
            graphics.setStrokeColor(UIColor.systemCyan.cgColor)
            graphics.setLineWidth(7)
            graphics.setShadow(offset: .zero,
                               blur: 5,
                               color: UIColor.black.withAlphaComponent(0.6).cgColor)
            for segment in segments where segment.count >= 2 {
                let path = UIBezierPath()
                path.move(to: snapshot.point(for: segment[0]))
                for coordinate in segment.dropFirst() {
                    path.addLine(to: snapshot.point(for: coordinate))
                }
                path.stroke()
            }
            graphics.setShadow(offset: .zero, blur: 0)
            if let start = segments.first?.first {
                marker(at: snapshot.point(for: start),
                       color: .systemGreen,
                       in: graphics)
            }
            if let end = segments.last?.last {
                marker(at: snapshot.point(for: end),
                       color: .systemCyan,
                       in: graphics)
            }
        }
    }

    private nonisolated static func marker(
        at point: CGPoint,
        color: UIColor,
        in context: CGContext
    ) {
        let rect = CGRect(x: point.x - 8, y: point.y - 8,
                          width: 16, height: 16)
        context.setFillColor(color.cgColor)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(3)
        context.fillEllipse(in: rect)
        context.strokeEllipse(in: rect)
    }
}

/// The sole observer of route snapshots. It renders a throttled asynchronous
/// snapshot rather than constructing a live SwiftUI Map during Start.
private struct AtriaLiveWorkoutRouteCard: View {
    @ObservedObject var routeRecorder: AtriaWorkoutRouteRecorder
    @StateObject private var mapSnapshotStore =
        AtriaLiveWorkoutMapSnapshotStore()

    var body: some View {
        let route = routeRecorder.snapshot
        ZStack {
            Color.black
                .overlay {
                    if let image = mapSnapshotStore.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else {
                        LinearGradient(colors: [.black, Color.cyan.opacity(0.12), .black],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    }
                }
                .clipped()
            routeStatus(route)
                .padding(.horizontal, 16)
                .padding(.top, 70)
                .safeAreaPadding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .task(id: mapSnapshotRevision(route)) {
            await mapSnapshotStore.refresh(segments: route.previewSegments)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.pointCount >= 2
                            ? "Workout route, \(distanceText(route.distanceMeters)), pace \(paceText(distance: route.distanceMeters, movingDuration: routeRecorder.movingDuration()))."
                            : (route.lastError ?? "Finding your current route"))
    }

    private func mapSnapshotRevision(
        _ route: AtriaWorkoutRouteRecorder.Snapshot
    ) -> Int {
        guard route.pointCount > 0 else { return 0 }
        return 1 + route.pointCount / 5
    }

    @ViewBuilder
    private func routeStatus(_ route: AtriaWorkoutRouteRecorder.Snapshot) -> some View {
        if route.pointCount >= 2 {
            HStack(spacing: 12) {
                Label(distanceText(route.distanceMeters), systemImage: "location.fill")
                Label(paceText(distance: route.distanceMeters,
                               movingDuration: routeRecorder.movingDuration()),
                      systemImage: "speedometer")
                if let speed = route.currentSpeedMetersPerSecond {
                    Label(speedText(speed), systemImage: "gauge.with.dots.needle.67percent")
                }
            }
            .font(.caption.weight(.black).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .atriaWorkoutGlassSurface(cornerRadius: 19, tint: .cyan)
        } else if route.lastError != nil {
            Label("Location unavailable", systemImage: "location.slash.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .atriaWorkoutGlassSurface(cornerRadius: 19, tint: .orange)
        } else {
            Label(route.isPaused ? "Route paused" : "Locating…",
                  systemImage: route.isPaused ? "pause.circle.fill" : "location.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .atriaWorkoutGlassSurface(cornerRadius: 19, tint: .cyan)
        }
    }

    private func distanceText(_ meters: Double) -> String {
        meters >= 1_000 ? String(format: "%.2f km", meters / 1_000) : "\(Int(meters.rounded())) m"
    }

    private func paceText(distance: Double, movingDuration: TimeInterval) -> String {
        guard distance >= 100 else { return "--/km" }
        let seconds = max(1, movingDuration) / (distance / 1_000)
        let minutes = Int(seconds) / 60
        return "\(minutes):\(String(format: "%02d", Int(seconds) % 60))/km"
    }

    private func speedText(_ metersPerSecond: Double) -> String {
        String(format: "%.1f km/h", max(0, metersPerSecond) * 3.6)
    }
}

/// Live workout HUD: a full-screen, glanceable real-time view shown while a
/// workout is active — big live HR + zone, a zone bar, live strain building
/// toward a target, active calories, and elapsed time. All values come from the
/// existing live stores (no new pipeline); the strap is already recording.
struct AtriaLiveWorkoutView: View {
    let pulseStore: AtriaHomeModel.PulseLiveStore
    let statusStore: AtriaHomeModel.StatusStore
    let coreLiveStore: AtriaHomeModel.CoreLiveStore
    /// Rapid metric publications are observed only by the two small metric
    /// hosts below. Keeping this reference plain prevents strain, calorie and
    /// step changes from invalidating workout controls, sheets and set logging.
    let metricStore: AtriaLiveWorkoutMetricStore
    // The route map owns the 1 Hz observation. Keeping this reference plain
    // prevents GPS publishes from invalidating HR, zones, strain and set logging.
    let routeRecorder: AtriaWorkoutRouteRecorder
    let maxHR: Int
    let restingHR: Int
    /// Frozen at workout start so body-weight set estimates do not change if
    /// profile data is edited while the workout is open.
    let strengthBodyMassKg: Double?
    let strainTarget: Double?
    let startDate: Date
    let lowerTargetZone: Int?
    let upperTargetZone: Int?
    @Binding var activityType: AtriaWorkoutActivityType
    @Binding var targetChoice: AtriaWorkoutTargetChoice?
    let strengthHistory: StrengthHistoryProjection
    @Binding var loggedSets: [LoggedSet]
    @Binding var excludedIntervals: [ExcludedInterval]
    @Binding var pauseStartedAt: Date?
    @Binding var heartRateBroadcastEnabled: Bool
    let broadcastPersistsAfterWorkout: Bool
    let onMinimize: () -> Void
    let onTogglePause: () -> Void
    let onStop: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSetLogger = false
    @State private var showTargetPicker = false
    @State private var selectedExercise = "Barbell bench press"
    @State private var loggerWeightKg = 60.0
    @State private var loggerReps = 8
    @State private var loggerRestSeconds: TimeInterval = 120
    // RPE is optional in `LoggedSet` and stays nil until the wearer enters
    // one; the set table renders "--" rather than assuming an effort.
    @State private var loggerRPE: Double?
    @State private var restTimerEndsAt: Date?
    @State private var showExerciseCatalog = false
    @State private var showStrengthProgress = false
    @State private var editingSetID: UUID?
    @State private var latestPRSetID: UUID?
    @State private var activeSuperset: StrengthSuperset?
    @State private var supersetMembers: [String] = []
    @State private var showsSupersetEditor = false
    @State private var showEndPersistenceError = false
    @State private var isEndingWorkout = false

    var body: some View {
        Group {
            if activityType.supportsRouteRecording {
                routeWorkoutContent
            } else {
                standardWorkoutContent
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSetLogger) {
            setLoggerSheet
                // A set log has four inputs plus a save action. Opening at
                // the large detent keeps RPE and the receipt-driving controls
                // reachable instead of hiding them below a compact card.
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showTargetPicker) {
            AtriaWorkoutTargetPicker(currentZone: HRZone.zone(for: pulseStore.state.heartRate,
                                                               maxHR: maxHR,
                                                               restingHR: restingHR),
                                     zoneBoundaries: AtriaHRRZoneBoundaries(restingHR: restingHR, maxHR: maxHR),
                                     guidanceTarget: strainTarget,
                                     choice: $targetChoice)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .alert("Workout still running", isPresented: $showEndPersistenceError) {
            Button("Try again", action: endWorkout)
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("Atria couldn't save the workout yet. Try ending it again.")
        }
        .onAppear {
            #if DEBUG
            applyDebugWorkoutFixtureIfNeeded(arguments: ProcessInfo.processInfo.arguments)
            if ProcessInfo.processInfo.arguments.contains("--atria-open-set-logger") {
                primeLoggerFromLastSet()
                showSetLogger = true
            }
            #endif
        }
    }

    /// Walking, running, hiking and cycling use the map as the primary live
    /// surface. The frequently changing metrics stay in one compact leaf and
    /// the two safety-critical controls remain pinned above the bottom inset.
    private var routeWorkoutContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AtriaLiveWorkoutRouteCard(routeRecorder: routeRecorder)
                .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.52), .clear, .black.opacity(0.78)],
                           startPoint: .top,
                           endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 10) {
                header
                AtriaLiveWorkoutMotionStatusHost(metricStore: metricStore)
                Spacer(minLength: 24)
                AtriaLiveWorkoutRouteMetricsHost(metricStore: metricStore,
                                                 pulseStore: pulseStore,
                                                 coreLiveStore: coreLiveStore,
                                                 maxHR: maxHR,
                                                 restingHR: restingHR,
                                                 lowerTargetZone: lowerTargetZone,
                                                 upperTargetZone: upperTargetZone,
                                                 onEditTarget: { showTargetPicker = true })
                routeWorkoutActions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .safeAreaPadding(.top)
            .safeAreaPadding(.bottom)
        }
    }

    /// Strength and stationary activities retain their full logging and
    /// coaching flow; the map-first composition is intentionally route-only.
    private var standardWorkoutContent: some View {
        ZStack {
            AtriaLiveWorkoutBackdrop(pulseStore: pulseStore,
                                      maxHR: maxHR,
                                      restingHR: restingHR)

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        header
                        AtriaLiveWorkoutMotionStatusHost(metricStore: metricStore)
                        AtriaLiveWorkoutHeartBlock(pulseStore: pulseStore,
                                                   coreLiveStore: coreLiveStore,
                                                   maxHR: maxHR,
                                                   restingHR: restingHR,
                                                   lowerTargetZone: lowerTargetZone,
                                                   upperTargetZone: upperTargetZone)
                            .padding(.top, 2)
                        AtriaLiveWorkoutStrainGuidanceHost(metricStore: metricStore,
                                                          guidanceTarget: strainTarget,
                                                          targetChoice: $targetChoice,
                                                          showTargetPicker: $showTargetPicker)
                        workoutActionsCard
                    }
                    .padding(22)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }

                stopButton
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
            }
        }
        .safeAreaPadding(.top)
        .safeAreaPadding(.bottom)
    }

    private var routeWorkoutActions: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: toggleWorkoutPause) {
                    Label(isPaused ? "Resume" : "Pause",
                          systemImage: isPaused ? "play.fill" : "pause.fill")
                        .font(.headline.weight(.black))
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .tint(isPaused ? .green : .orange)

                Button(role: .destructive, action: endWorkout) {
                    Group {
                        if isEndingWorkout {
                            Label("Saving…", systemImage: "clock")
                        } else {
                            Label("End", systemImage: "stop.fill")
                        }
                    }
                    .font(.headline.weight(.black))
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(isEndingWorkout)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workout controls. \(isPaused ? "Paused" : "Recording").")
    }

    private var header: some View {
        HStack {
            Button {
                onMinimize()
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.black))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Minimize workout")

            Menu {
                ForEach(AtriaWorkoutActivityType.allCases) { type in
                    Button {
                        activityType = type
                    } label: {
                        Label(type.rawValue, systemImage: type.icon)
                    }
                }
                Divider()
                Toggle(isOn: $heartRateBroadcastEnabled) {
                    Label("Broadcast HR", systemImage: "antenna.radiowaves.left.and.right")
                }
            } label: {
                HStack(spacing: 6) {
                    Label(activityType == .other ? "Workout" : activityType.rawValue,
                          systemImage: activityType.icon)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityHidden(true)
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityHint("Choose the workout activity type")
            Spacer()
            TimelineView(.periodic(from: startDate, by: 1)) { context in
                Text(elapsedText(context.date))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
    }

    /// The two frequent workout actions stay visible and glanceable without
    /// explanatory copy. Secondary state (recent sets, timers and HR broadcast)
    /// remains in the same compact surface.
    private var workoutActionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    if activityType.supportsExerciseSelection {
                        Button {
                            primeLoggerFromLastSet()
                            showSetLogger = true
                        } label: {
                            Label("Log set", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.black))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.mint)
                    }

                    Button(action: toggleWorkoutPause) {
                        Label(isPaused ? "Resume" : "Pause",
                              systemImage: isPaused ? "play.fill" : "pause.fill")
                            .font(.subheadline.weight(.black))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(isPaused ? .green : .orange)
                }
            }

            if (activityType.supportsExerciseSelection && restTimerEndsAt != nil)
                || pauseStartedAt != nil {
                HStack(spacing: 8) {
                    if activityType.supportsExerciseSelection, let restTimerEndsAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Label(restTimerText(now: context.date, end: restTimerEndsAt),
                                  systemImage: "timer")
                                .font(.caption.weight(.black).monospacedDigit())
                                .foregroundStyle(.mint)
                        }
                    }
                    if let pauseStartedAt {
                        TimelineView(.periodic(from: pauseStartedAt, by: 1)) { context in
                            Label(pauseElapsedText(context.date), systemImage: "pause.fill")
                                .font(.caption.weight(.black).monospacedDigit())
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            if activityType.supportsExerciseSelection, !loggedSets.isEmpty {
                VStack(spacing: 7) {
                    ForEach(loggedSets.suffix(1)) { set in
                        loggedSetRow(set)
                    }
                }
            }
        }
        .padding(12)
        .atriaWorkoutContentSurface(cornerRadius: 22, tint: isPaused ? .orange : .mint)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(activityType.supportsExerciseSelection
                            ? "Workout actions. \(loggedSets.count) sets logged. \(isPaused ? "Paused" : "Recording")."
                            : "Workout actions. \(isPaused ? "Paused" : "Recording").")
    }

    private func loggedSetRow(_ set: LoggedSet) -> some View {
        HStack(spacing: 10) {
            Button {
                editLoggedSet(set)
            } label: {
                HStack(spacing: 10) {
                    Text(set.exercise)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text(setSummary(set))
                        .font(.caption.weight(.black).monospacedDigit())
                        .foregroundStyle(.mint)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(set.exercise) set, \(setSummary(set))")

            Button(role: .destructive) {
                deleteLoggedSet(set)
            } label: {
                // Destructive control next to the edit row: full 44pt hit
                // area so a miss never deletes (UX audit 2026-07-07).
                Image(systemName: "trash.circle.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.red.opacity(0.92))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Delete \(set.exercise) set")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var setLoggerSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(editingSetID == nil ? "Log set" : "Edit set", systemImage: "dumbbell.fill")
                        .font(.headline.weight(.black))
                    Spacer()
                    Button("Close") { showSetLogger = false }
                        .font(.subheadline.weight(.bold))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }

                AtriaStrengthLoggingHeader(exercise: selectedExercise,
                                           setNumber: loggedSetsForSelectedExercise.count + 1,
                                           isRecording: !isPaused)

                AtriaStrengthRestHeartRateHost(pulseStore: pulseStore,
                                               exercise: selectedExercise,
                                               restEndsAt: restTimerEndsAt,
                                               targetSeconds: loggerRestSeconds,
                                               onSubtract15: { shortenRest(by: 15) },
                                               onSkip: { restTimerEndsAt = nil })

                AtriaStrengthSetTable(rows: strengthSetTableRows,
                                      pendingWeightText: AtriaStrengthSetTablePresentation.weightCell(loggerWeightKg),
                                      pendingRepsText: "\(loggerReps)",
                                      pendingRPEText: AtriaStrengthSetTablePresentation.rpeText(loggerRPE))

                Button {
                    showsSupersetEditor = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: activeSuperset == nil ? "link.badge.plus" : "link")
                        Text(activeSuperset.map { "Superset · \($0.exercises.joined(separator: " → "))" } ?? "Create superset")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(activeSuperset == nil ? Color.secondary : Color.mint)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 10)
                    .background((activeSuperset == nil ? Color.white : Color.mint).opacity(activeSuperset == nil ? 0.07 : 0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(loggerExerciseOptions, id: \.self) { exercise in
                            Button {
                                selectedExercise = exercise
                                primeLoggerFromLastSet(exercise: exercise)
                                loggerRestSeconds = AtriaStrengthLog.restSeconds(for: exercise)
                            } label: {
                                Text(exercise)
                                    .font(.caption.weight(.bold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 11)
                                    .frame(minHeight: 44)
                                    .background(selectedExercise == exercise ? Color.mint.opacity(0.26) : Color.white.opacity(0.08),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                loggerStepperRow(title: AtriaStrengthLog.isEstimatedBodyweightExercise(selectedExercise)
                                     ? "Added weight" : "Weight",
                                 value: AtriaStrengthSetTablePresentation.weightCell(loggerWeightKg),
                                 unit: "kg",
                                 decrement: { loggerWeightKg = max(0, loggerWeightKg - 2.5) },
                                 increment: { loggerWeightKg += 2.5 })
                if let effective = AtriaStrengthLog.effectiveLoadKg(
                    exercise: selectedExercise,
                    externalWeightKg: loggerWeightKg > 0 ? loggerWeightKg : nil,
                    bodyMassKg: strengthBodyMassKg
                ), effective.movementClass == .bodyweightEstimate {
                    Text("Estimated moved load \(Int(effective.loadKg.rounded())) kg · based on your body mass at workout start")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                loggerStepperRow(title: "Reps",
                                 value: "\(loggerReps)",
                                 decrement: { loggerReps = max(1, loggerReps - 1) },
                                 increment: { loggerReps = min(99, loggerReps + 1) })
                loggerStepperRow(title: "RPE",
                                 value: AtriaStrengthSetTablePresentation.rpeText(loggerRPE),
                                 decrement: { adjustRPE(by: -0.5) },
                                 increment: { adjustRPE(by: 0.5) })
                loggerStepperRow(title: "Rest",
                                 value: restOverrideText(loggerRestSeconds),
                                 decrement: { updateRestOverride(max(30, loggerRestSeconds - 15)) },
                                 increment: { updateRestOverride(min(600, loggerRestSeconds + 15)) })

                exerciseHistoryPanel
                strengthNavigationRow

            }
            .padding(18)
        }
        // The logger has enough real controls to scroll. Pinning its one
        // primary commit action prevents it falling below the fold on an
        // iPhone, while keeping the content itself free to grow for Dynamic
        // Type and a long exercise name.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            logSetAction
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showExerciseCatalog) {
            AtriaStrengthCatalogView(projection: strengthHistory) { exercise in
                selectedExercise = exercise
                primeLoggerFromLastSet(exercise: exercise)
                loggerRestSeconds = AtriaStrengthLog.restSeconds(for: exercise)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showsSupersetEditor) {
            supersetEditor
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showStrengthProgress) {
            // Saved history only, records included: the chart and the PR chips
            // must describe the same set of days. Sets from the workout in
            // progress are not saved yet, so they belong to the live table
            // above, not to this trend.
            AtriaStrengthProgressView(exercise: selectedExercise,
                                      history: strengthHistory.fullHistory(for: selectedExercise),
                                      records: personalRecords(for: selectedExercise))
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
    }

    private var logSetAction: some View {
        Button {
            saveLoggedSet()
        } label: {
            Label(editingSetID == nil ? "Log set \u{00B7} start rest" : "Update set",
                  systemImage: "checkmark.circle.fill")
                .font(.headline.weight(.black))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(.glassProminent)
        .tint(AtriaStrengthPalette.amber)
    }

    private var strengthNavigationRow: some View {
        HStack(spacing: 10) {
            Button {
                showStrengthProgress = true
            } label: {
                Label("e1RM progress", systemImage: "chart.xyaxis.line")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)
            .tint(AtriaStrengthPalette.amber)

            Button {
                showExerciseCatalog = true
            } label: {
                Label("Exercises", systemImage: "list.bullet")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)
            .tint(AtriaStrengthPalette.amber)
        }
    }

    private var loggedSetsForSelectedExercise: [LoggedSet] {
        let key = AtriaStrengthLog.normalized(selectedExercise)
        return loggedSets.filter { AtriaStrengthLog.normalized($0.exercise) == key }
    }

    private var strengthSetTableRows: [AtriaStrengthSetTablePresentation.Row] {
        AtriaStrengthSetTablePresentation.rows(sets: loggedSets,
                                               exercise: selectedExercise,
                                               records: personalRecords(for: selectedExercise),
                                               editingSetID: editingSetID)
    }

    private func loggerStepperRow(title: String,
                                  value: String,
                                  unit: String? = nil,
                                  decrement: @escaping () -> Void,
                                  increment: @escaping () -> Void) -> some View {
        AtriaStrengthStepper(title: title,
                             value: value,
                             unit: unit,
                             decrement: decrement,
                             increment: increment)
    }

    /// RPE walks 6…10 in half points and falls back to "no entry" below the
    /// bottom of the scale, because a set without a reported effort must not
    /// silently become a 6.
    private func adjustRPE(by delta: Double) {
        guard let current = loggerRPE else {
            loggerRPE = delta > 0 ? 7 : nil
            return
        }
        let next = current + delta
        if next < 6 {
            loggerRPE = nil
        } else {
            loggerRPE = min(10, next)
        }
    }

    private func shortenRest(by seconds: TimeInterval) {
        guard let restTimerEndsAt else { return }
        let shortened = restTimerEndsAt.addingTimeInterval(-seconds)
        self.restTimerEndsAt = shortened <= Date() ? nil : shortened
    }

    private var loggerExerciseOptions: [String] {
        let recents = loggedSets.reversed().map(\.exercise)
        let suggested = AtriaWorkoutExerciseCatalog.suggestedExercises(for: AtriaWorkoutActivityType.strength.rawValue)
        let fallback = Array(AtriaWorkoutExerciseCatalog.groups.flatMap(\.exercises).prefix(8))
        let options = (recents + suggested).reduce(into: [String]()) { result, exercise in
            guard !result.contains(where: { $0.localizedCaseInsensitiveCompare(exercise) == .orderedSame }) else { return }
            result.append(exercise)
        }
        return Array((options.isEmpty ? fallback : options).prefix(12))
    }

    private func primeLoggerFromLastSet() {
        editingSetID = nil
        primeLoggerFromLastSet(exercise: selectedExercise)
    }

    #if DEBUG
    private func applyDebugWorkoutFixtureIfNeeded(arguments: [String]) {
        guard let fixture = Self.debugLaunchFixtureValue(arguments: arguments) else { return }
        if fixture == "live-workout-set-saved" {
            selectedExercise = "Barbell bench press"
            loggerWeightKg = 85
            loggerReps = 5
            loggerRestSeconds = AtriaStrengthLog.restSeconds(for: selectedExercise)
            latestPRSetID = loggedSets.last?.id
            restTimerEndsAt = Date().addingTimeInterval(91)
        } else if fixture == "live-workout-paused" {
            pauseStartedAt = Date().addingTimeInterval(-74)
        }
    }

    private static func debugLaunchFixtureValue(arguments: [String]) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment["ATRIA_UI_FIXTURE"],
           !environmentValue.isEmpty {
            return environmentValue
        }
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
    #endif

    private func primeLoggerFromLastSet(exercise: String) {
        loggerRestSeconds = AtriaStrengthLog.restSeconds(for: exercise)
        guard let last = loggedSets.last(where: { $0.exercise.localizedCaseInsensitiveCompare(exercise) == .orderedSame }) else {
            selectedExercise = exercise
            if AtriaStrengthLog.isEstimatedBodyweightExercise(exercise) {
                loggerWeightKg = 0
            }
            return
        }
        selectedExercise = exercise
        loggerWeightKg = last.weightKg ?? loggerWeightKg
        loggerReps = last.reps ?? loggerReps
    }

    private func saveLoggedSet() {
        let editingOriginal = editingSetID.flatMap { id in
            loggedSets.first(where: { $0.id == id })
        }
        // GAP-08: an edit keeps the original set's identity and timestamp —
        // changing a weight or rep count must never re-stamp when the set
        // happened. It also keeps the original superset receipt unless the
        // movement itself changed; only then is the receipt re-derived (at the
        // original time, excluding the set being edited so it can never be its
        // own "previous member").
        let setTime = editingOriginal?.t ?? Date()
        let receipt: AtriaStrengthLog.SupersetReceipt
        if let editingOriginal,
           editingOriginal.exercise.localizedCaseInsensitiveCompare(selectedExercise) == .orderedSame {
            receipt = AtriaStrengthLog.SupersetReceipt(
                groupID: editingOriginal.supersetGroupID,
                order: editingOriginal.supersetOrder,
                transitionSeconds: editingOriginal.supersetTransitionSeconds)
        } else {
            receipt = AtriaStrengthLog.supersetReceipt(exercise: selectedExercise,
                                                       group: activeSuperset,
                                                       priorSets: loggedSets,
                                                       excludingSetID: editingOriginal?.id,
                                                       now: setTime)
        }
        var set = LoggedSet(exercise: selectedExercise,
                            weightKg: loggerWeightKg > 0 ? loggerWeightKg : nil,
                            reps: loggerReps,
                            rpe: loggerRPE,
                            t: setTime,
                            effectiveLoadKg: AtriaStrengthLog.effectiveLoadKg(
                                exercise: selectedExercise,
                                externalWeightKg: loggerWeightKg > 0 ? loggerWeightKg : nil,
                                bodyMassKg: strengthBodyMassKg
                            )?.loadKg,
                            supersetGroupID: receipt.groupID,
                            supersetOrder: receipt.order,
                            supersetTransitionSeconds: receipt.transitionSeconds)
        if let editingOriginal {
            set.id = editingOriginal.id
        }
        let isNewPR = AtriaStrengthLog.isPR(set, against: personalRecordsIncludingCurrentWorkout(for: selectedExercise))
        if let editingSetID,
           let index = loggedSets.firstIndex(where: { $0.id == editingSetID }) {
            loggedSets[index] = set
            self.editingSetID = nil
        } else {
            loggedSets.append(set)
        }
        latestPRSetID = isNewPR ? set.id : nil
        restTimerEndsAt = Date().addingTimeInterval(restSeconds(for: selectedExercise))
        mirrorLoggedSetsToActiveJournal()
        UIImpactFeedbackGenerator(style: isNewPR ? .heavy : .light).impactOccurred()
    }

    private var supersetEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Superset")
                .font(.title3.weight(.black))
            Text("Select two or more movements in order. Atria keeps each set intact and records the observed handoff separately from your between-round rest.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(loggerExerciseOptions, id: \.self) { exercise in
                    Button {
                        toggleSupersetMember(exercise)
                    } label: {
                        HStack {
                            Text(exercise)
                            Spacer()
                            Image(systemName: supersetMembers.contains(exercise) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(supersetMembers.contains(exercise) ? .mint : .secondary)
                        }
                    }
                }
            }
            HStack {
                Button("Ungroup") { activeSuperset = nil; supersetMembers.removeAll(); showsSupersetEditor = false }
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save group") {
                    guard supersetMembers.count >= 2 else { return }
                    // GAP-08: reordering or re-editing the members keeps the
                    // SAME group id — minting a new id would silently break
                    // transition-chain continuity with rounds already logged
                    // under the old id.
                    activeSuperset = StrengthSuperset(id: activeSuperset?.id ?? UUID().uuidString,
                                                      exercises: supersetMembers)
                    showsSupersetEditor = false
                }
                .disabled(supersetMembers.count < 2)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
        }
        .padding(18)
        .onAppear { if supersetMembers.isEmpty { supersetMembers = activeSuperset?.exercises ?? [selectedExercise] } }
    }

    private func toggleSupersetMember(_ exercise: String) {
        if let index = supersetMembers.firstIndex(of: exercise) {
            supersetMembers.remove(at: index)
        } else {
            supersetMembers.append(exercise)
        }
    }

    private func editLoggedSet(_ set: LoggedSet) {
        editingSetID = set.id
        selectedExercise = set.exercise
        loggerRestSeconds = AtriaStrengthLog.restSeconds(for: set.exercise)
        loggerWeightKg = set.weightKg ?? loggerWeightKg
        loggerReps = set.reps ?? loggerReps
        loggerRPE = set.rpe
        showSetLogger = true
    }

    private func deleteLoggedSet(_ set: LoggedSet) {
        loggedSets.removeAll { $0.id == set.id }
        mirrorLoggedSetsToActiveJournal()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    private func mirrorLoggedSetsToActiveJournal() {
        try? ActiveSessionJournal.mirrorStrengthState(strengthSets: loggedSets,
                                                      excludedIntervals: effectiveExcludedIntervals)
    }

    private var isPaused: Bool {
        pauseStartedAt != nil
    }

    private var effectiveExcludedIntervals: [ExcludedInterval] {
        guard let pauseStartedAt else { return excludedIntervals }
        return excludedIntervals + [ExcludedInterval(start: pauseStartedAt, end: Date())]
    }

    private func toggleWorkoutPause() {
        onTogglePause()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func finalizePauseIfNeeded() {
        guard isPaused else { return }
        onTogglePause()
    }

    private func pauseElapsedText(_ date: Date) -> String {
        guard let pauseStartedAt else { return "00:00" }
        let total = max(0, Int(date.timeIntervalSince(pauseStartedAt)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func restSeconds(for exercise: String) -> TimeInterval {
        AtriaStrengthLog.restSeconds(for: exercise)
    }

    private func updateRestOverride(_ seconds: TimeInterval) {
        loggerRestSeconds = seconds
        AtriaStrengthLog.setRestSeconds(seconds, for: selectedExercise)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func restOverrideText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func restTimerText(now: Date, end: Date) -> String {
        let remaining = max(0, Int(end.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private func setSummary(_ set: LoggedSet) -> String {
        let weight = set.weightKg.map { "\(Int($0.rounded())) kg" } ?? "--"
        let reps = set.reps.map { "\($0)" } ?? "--"
        let base = "\(weight) x \(reps)"
        return isPersonalRecord(set) ? "\(base) · PR" : base
    }

    private var exerciseHistoryPanel: some View {
        let summary = strengthHistorySummary(for: selectedExercise)
        let records = summary.records
        let history = summary.history
        let best = history.last?.best
        let daysText = history.count == 1 ? "1 day" : "\(history.count) days"
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("History", systemImage: "chart.xyaxis.line")
                    .font(.caption.weight(.black))
                Spacer()
                Text(history.isEmpty ? "No sets yet" : daysText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                historyMetric("Best", value: best.map(setSummaryPlain) ?? "--")
                historyMetric("e1RM", value: records.maxE1RM.map { "\(Int($0.rounded())) kg" } ?? "--")
                historyMetric("Max", value: records.maxWeightKg.map { "\(Int($0.rounded())) kg" } ?? "--")
            }

            if let latestPRSetID,
               loggedSets.contains(where: { $0.id == latestPRSetID }) {
                Label("New PR", systemImage: "sparkles")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func historyMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.black).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func personalRecords(for exercise: String) -> StrengthPersonalRecords {
        strengthHistory.records(for: exercise)
    }

    private func personalRecordsIncludingCurrentWorkout(for exercise: String) -> StrengthPersonalRecords {
        strengthHistory.records(for: exercise).including(loggedSets, exercise: exercise)
    }

    private func isPersonalRecord(_ set: LoggedSet) -> Bool {
        latestPRSetID == set.id || AtriaStrengthLog.isPR(set, against: personalRecords(for: set.exercise))
    }

    private func strengthHistorySummary(for exercise: String) -> AtriaLiveWorkoutStrengthHistorySummary {
        AtriaLiveWorkoutStrengthHistorySummary(records: strengthHistory.records(for: exercise),
                                               history: strengthHistory.history(for: exercise))
    }

    private func setSummaryPlain(_ set: LoggedSet) -> String {
        let weight = set.weightKg.map { "\(Int($0.rounded())) kg" } ?? "--"
        let reps = set.reps.map { "\($0)" } ?? "--"
        return "\(weight) x \(reps)"
    }

    private var stopButton: some View {
        Button(role: .destructive, action: endWorkout) {
            Group {
                if isEndingWorkout {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving workout…")
                    }
                } else {
                    Label("End workout", systemImage: "stop.fill")
                }
            }
            .font(.headline.weight(.bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .atriaCardAction(tint: .red)
        .disabled(isEndingWorkout)
    }

    private func endWorkout() {
        guard !isEndingWorkout else { return }
        // Commit acknowledgement in the same button transaction. In
        // particular, do this before requesting a paused-workout boundary:
        // that request is asynchronous and a second tap must not enqueue a
        // second pause transition while the terminal intent is being saved.
        isEndingWorkout = true
        finalizePauseIfNeeded()
        Task { @MainActor in
            if await onStop() {
                dismiss()
            } else {
                isEndingWorkout = false
                showEndPersistenceError = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func elapsedText(_ date: Date) -> String {
        let total = max(0, Int(AtriaWorkoutMovingDuration.project(
            startedAt: startDate,
            excludedIntervals: excludedIntervals,
            pauseStartedAt: pauseStartedAt,
            now: date
        )))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    private struct AtriaLiveWorkoutStrengthHistorySummary {
        let records: StrengthPersonalRecords
        let history: [StrengthHistoryDay]
    }
}

/// Pulse-driven leaves keep strap publications from invalidating workout-owned
/// controls, sheets, and strength-log state at the screen root.
private struct AtriaLiveWorkoutBackdrop: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    let maxHR: Int
    let restingHR: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let zone = HRZone.zone(for: pulseStore.state.heartRate,
                               maxHR: maxHR,
                               restingHR: restingHR)
        LinearGradient(colors: [zone.color.opacity(0.45), .black],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: zone)
    }
}

/// A narrow leaf for the raw strap-motion transport clock. Keeping it separate
/// from the step and strain cards makes the distinction explicit and prevents
/// one timestamp update from rebuilding workout controls or the route map.
private struct AtriaLiveWorkoutMotionStatusHost: View {
    @ObservedObject var metricStore: AtriaLiveWorkoutMetricStore

    var body: some View {
        AtriaLiveWorkoutMotionStatus(motion: metricStore.state.motion)
    }
}

private struct AtriaLiveWorkoutMotionStatus: View {
    let motion: AtriaLiveWorkoutMotionProjection

    private var tint: Color {
        switch motion.availability {
        case .live: return .mint
        case .reconnecting: return .orange
        case .stale: return .red
        case .unavailable: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(motion.compactLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(motion.accessibilityText)
    }
}

/// One compact, pulse-driven overlay for outdoor workouts. Keeping HR here
/// isolates rapid strap publications from the map and pinned action controls.
private struct AtriaLiveWorkoutRouteMetricsHost: View {
    @ObservedObject var metricStore: AtriaLiveWorkoutMetricStore
    let pulseStore: AtriaHomeModel.PulseLiveStore
    let coreLiveStore: AtriaHomeModel.CoreLiveStore
    let maxHR: Int
    let restingHR: Int
    let lowerTargetZone: Int?
    let upperTargetZone: Int?
    let onEditTarget: () -> Void

    var body: some View {
        AtriaLiveWorkoutRouteMetricsHUD(pulseStore: pulseStore,
                                        coreLiveStore: coreLiveStore,
                                        metricProjection: metricStore.state,
                                        maxHR: maxHR,
                                        restingHR: restingHR,
                                        lowerTargetZone: lowerTargetZone,
                                        upperTargetZone: upperTargetZone,
                                        onEditTarget: onEditTarget)
    }
}

private struct AtriaLiveWorkoutRouteMetricsHUD: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    let metricProjection: AtriaLiveWorkoutMetricProjection
    let maxHR: Int
    let restingHR: Int
    let lowerTargetZone: Int?
    let upperTargetZone: Int?
    let onEditTarget: () -> Void

    private var heartRate: Int { pulseStore.state.heartRate }
    private var zone: HRZone {
        HRZone.zone(for: heartRate, maxHR: maxHR, restingHR: restingHR)
    }
    private var zoneText: String {
        zone.rawValue == 0 ? "Below Z1" : "Z\(zone.rawValue) \(zone.name)"
    }
    private var targetRangeText: String? {
        guard let lowerTargetZone, let upperTargetZone else { return nil }
        return "Z\(lowerTargetZone)–Z\(upperTargetZone)"
    }
    private var caloriesValue: String {
        guard metricProjection.hasSensorEvidence,
              let calories = metricProjection.activeCalories else { return "--" }
        return "≈\(Int(calories.rounded()))"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                // Beats with the handoff's live-heart keyframe; the number
                // beside it stays the honest reading.
                AtriaPulsingHeart(font: .headline.weight(.black))

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(heartRate > 0 ? "\(heartRate)" : "--")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                        .allowsTightening(true)
                        .layoutPriority(3)
                        .contentTransition(.numericText())
                    Text("BPM")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .fixedSize()
                }
                // Same correction as the full heart block: the priority has to
                // be on the group to count against the zone stack and the
                // target button in this outer row.
                .layoutPriority(3)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Heart rate \(heartRate) beats per minute")

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(zoneText)
                        .font(.caption.weight(.black))
                        .foregroundStyle(zone.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.64)
                        .allowsTightening(true)
                    if let targetRangeText {
                        Text(targetRangeText)
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(targetRangeText.map { "Heart rate zone \(zone.rawValue), target \($0)" }
                                    ?? "Heart rate zone \(zone.rawValue)")

                AtriaLiveWorkoutBatteryBadge(coreLiveStore: coreLiveStore)

                Button(action: onEditTarget) {
                    Image(systemName: "scope")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change heart rate target")
            }

            HStack(spacing: 0) {
                metric(title: "Steps",
                       value: metricProjection.steps.hudText,
                       systemImage: "figure.walk",
                       tint: metricProjection.steps.availability == .live ? .mint : .orange,
                       accessibilityText: metricProjection.steps.accessibilityText)
                metricDivider
                metric(title: metricProjection.strainHUDTitle,
                       value: metricProjection.strainHUDText,
                       systemImage: "bolt.heart.fill",
                       tint: metricProjection.coachingIsLive ? Metrics.electricStrain : .orange)
                metricDivider
                metric(title: "Calories",
                       value: caloriesValue,
                       systemImage: "flame.fill",
                       tint: metricProjection.coachingIsLive ? .pink : .orange,
                       accessibilityText: "Active calories \(caloriesValue)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .atriaWorkoutGlassSurface(cornerRadius: 24, tint: zone.color)
        .accessibilityElement(children: .contain)
    }

    private func metric(title: String,
                        value: String,
                        systemImage: String,
                        tint: Color,
                        accessibilityText: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(value)
                .font(.headline.weight(.black).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? "\(title), \(value)")
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: 1, height: 34)
            .accessibilityHidden(true)
    }
}

private struct AtriaLiveWorkoutHeartBlock: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    let maxHR: Int
    let restingHR: Int
    let lowerTargetZone: Int?
    let upperTargetZone: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let heartRate = pulseStore.state.heartRate
        let zone = HRZone.zone(for: heartRate, maxHR: maxHR, restingHR: restingHR)
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                pulsingHeartIcon

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(heartRate > 0 ? "\(heartRate)" : "--")
                        .font(.system(size: 62, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.52)
                        .allowsTightening(true)
                        .layoutPriority(3)
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("BPM")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .fixedSize()
                }
                // The priority has to live HERE, on the group, not on the
                // number inside it. layoutPriority(3) on the Text only ranked
                // it against "BPM" within this inner HStack; against the zone
                // capsule in the OUTER row it counted for nothing. So a long
                // zone name ("Z2 · Fat burn") starved the heart rate, and 62pt
                // type with minimumScaleFactor(0.52) shrank and then truncated
                // -- a live workout rendering "1..." where the wearer's pulse
                // should be. It is the one number on this screen that must
                // never yield.
                .layoutPriority(3)

                Spacer(minLength: 6)

                AtriaLiveWorkoutBatteryBadge(coreLiveStore: coreLiveStore)

                Text(zone.rawValue == 0 ? "Below Z1" : "Z\(zone.rawValue) · \(zone.name)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(zone.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)
                    // Yields before the pulse does: the zone name can compress
                    // or abbreviate, a heart rate cannot.
                    .layoutPriority(0)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(zone.color.opacity(0.16), in: Capsule())
            }

            HStack(spacing: 4) {
                ForEach(HRZone.allCases, id: \.self) { candidate in
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(candidate == zone ? candidate.color : candidate.color.opacity(0.22))
                            .frame(height: candidate == zone ? 11 : 7)
                            .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.standard), value: zone)
                        Text("Z\(candidate.rawValue)")
                            .font(.system(size: 9,
                                          weight: candidate == zone ? .black : .bold,
                                          design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(candidate == zone
                                             ? candidate.color
                                             : .white.opacity(0.42))
                    }
                }
            }
            if let lowerTargetZone, let upperTargetZone {
                Label("Target Z\(lowerTargetZone)–Z\(upperTargetZone)", systemImage: "scope")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .atriaWorkoutContentSurface(cornerRadius: 22, tint: zone.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate \(heartRate) beats per minute. Zone \(zone.rawValue), \(zone.name), \(zoneBandText(zone)).")
    }

    @ViewBuilder
    private var pulsingHeartIcon: some View {
        // Was `.symbolEffect(.pulse)` — an opacity fade, which next to a live
        // BPM read as a signal-strength indicator. Shares the one heartbeat
        // keyframe with the compact hero so both live HR surfaces beat alike.
        AtriaPulsingHeart(font: .title2)
    }

    private func zoneBandText(_ zone: HRZone) -> String {
        AtriaHRRZoneBoundaries(restingHR: restingHR, maxHR: maxHR)?.rangeText(for: zone)
            ?? "Range unavailable"
    }

}

/// Workout chrome keeps battery state available without repeating the large
/// dashboard status pill. Motion freshness immediately above the metrics is the
/// authoritative recording indicator; this badge is intentionally battery-only.
private struct AtriaLiveWorkoutBatteryBadge: View {
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore

    var body: some View {
        let state = coreLiveStore.state
        HStack(spacing: 4) {
            Image(systemName: "battery.100percent")
            if state.batteryShowsPowered {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.yellow)
            }
            Text(state.batteryLevel >= 0 ? "\(state.batteryLevel)%" : "--")
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption2.weight(.black))
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(.black.opacity(0.32), in: Capsule())
        // Never let the heart-block row compress this badge -- a squeezed badge
        // wrapped "73%" into a vertical 7/3/% stack (real-device bug 2026-08-05).
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            state.batteryLevel >= 0
                ? "Strap battery \(state.batteryLevel) percent\(state.batteryShowsPowered ? ", charging" : "")"
                : "Strap battery unavailable"
        )
    }
}

private struct AtriaLiveWorkoutStrainGuidanceHost: View {
    @ObservedObject var metricStore: AtriaLiveWorkoutMetricStore
    let guidanceTarget: Double?
    @Binding var targetChoice: AtriaWorkoutTargetChoice?
    @Binding var showTargetPicker: Bool

    var body: some View {
        AtriaLiveWorkoutStrainGuidance(metricProjection: metricStore.state,
                                       guidanceTarget: guidanceTarget,
                                       targetChoice: $targetChoice,
                                       showTargetPicker: $showTargetPicker)
    }
}

enum AtriaLiveWorkoutLoadVisibility {
    static func isReadable(hasSensorEvidence: Bool, loadIsComplete: Bool) -> Bool {
        hasSensorEvidence && loadIsComplete
    }
}

private struct AtriaLiveWorkoutStrainGuidance: View {
    let metricProjection: AtriaLiveWorkoutMetricProjection
    let guidanceTarget: Double?
    @Binding var targetChoice: AtriaWorkoutTargetChoice?
    @Binding var showTargetPicker: Bool

    private var strain: Double { metricProjection.strain }
    private var target: Double? {
        AtriaWorkoutTargetMath.effectiveTarget(choice: targetChoice,
                                               guidanceTarget: guidanceTarget)
    }
    private var cue: String { AtriaWorkoutTargetMath.cue(strain: strain, target: target) }
    private var progress: Double {
        guard let target, target > 0 else { return min(max(strain / 21, 0), 1) }
        return min(max(strain / target, 0), 1)
    }
    private var targetText: String? { target.map { String(format: "%.1f", $0) } }
    private var sourceText: String {
        switch targetChoice {
        case .zone(let rawZone): return "Z\(rawZone) goal"
        case .strain: return "Your goal"
        case nil: return "Auto"
        }
    }
    private var cueTitle: String {
        if let status = metricProjection.sensorStatusTitle { return status }
        switch cue {
        case "ease": return "Ease down"
        case "hold": return "Hold here"
        default: return "Build gently"
        }
    }
    private var cueDetail: String {
        if let status = metricProjection.sensorStatusDetail { return status }
        switch cue {
        case "ease": return "Above target. Let HR settle."
        case "hold": return "Target matched. Keep this effort."
        default: return "Below target. Add effort when ready."
        }
    }
    private var cueSymbol: String {
        if !metricProjection.hasSensorEvidence { return "waveform.slash" }
        if metricProjection.sensorAvailability != .live { return "antenna.radiowaves.left.and.right.slash" }
        switch cue {
        case "ease": return "arrow.down.heart.fill"
        case "hold": return "equal.circle.fill"
        default: return "arrow.up.heart.fill"
        }
    }
    private var cueTint: Color {
        if !metricProjection.coachingIsLive { return .orange }
        switch cue {
        case "ease": return .orange
        case "hold": return .green
        default: return .cyan
        }
    }

    /// The single condition under which strain and active calories can carry a
    /// real number — the same one `strainHUDText`/`activeCaloriesHUDText` use
    /// to fall back to "--", and the same one that gated the progress fill.
    private var loadIsReadable: Bool {
        AtriaLiveWorkoutLoadVisibility.isReadable(
            hasSensorEvidence: metricProjection.hasSensorEvidence,
            loadIsComplete: metricProjection.loadIsComplete
        )
    }

    private var caloriesText: String {
        guard metricProjection.hasSensorEvidence else { return "--" }
        return metricProjection.activeCalories.map { "\(Int($0.rounded()))" } ?? "--"
    }
    private var accessibilityTargetClause: String {
        targetText.map { ", target \($0)" } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: cueSymbol)
                    .font(.headline.weight(.black))
                    .foregroundStyle(cueTint)
                    .frame(width: 32, height: 32)
                    .background(cueTint.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(cueTitle)
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(.white)
                    Text(metricProjection.coachingIsLive
                         ? targetText.map { "\(metricProjection.strainHUDText) strain · target \($0)" }
                            ?? "\(metricProjection.strainHUDText) strain"
                         : cueDetail)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.66))
                }
                Spacer(minLength: 6)

                Button {
                    showTargetPicker = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Set workout target. Currently \(sourceText).")
            }

            // Strain and calories are structurally incapable of a value until
            // load is readable — strainHUDText and activeCaloriesHUDText both
            // hard-return "--" on exactly this condition. Rendering them anyway
            // restated "no data yet" twice more directly beneath a headline
            // that already says it ("Waiting for strap · Strain and calories
            // begin with continuous heart rate"). Steps keeps its own tile
            // throughout: its availability is independent of heart rate, so
            // "syncing" there is a real state, not a placeholder.
            HStack(spacing: 8) {
                if loadIsReadable {
                    compactMetric(title: metricProjection.strainHUDTitle,
                                  value: metricProjection.strainHUDText,
                                  systemImage: "bolt.heart.fill",
                                  tint: metricProjection.coachingIsLive ? Metrics.electricStrain : .orange)
                    compactMetric(title: metricProjection.activeCaloriesHUDTitle,
                                  value: metricProjection.activeCaloriesHUDText,
                                  systemImage: "flame.fill",
                                  tint: metricProjection.coachingIsLive ? .pink : .orange)
                }
                compactMetric(title: "Steps",
                              value: metricProjection.steps.hudText,
                              systemImage: "figure.walk",
                              tint: metricProjection.steps.availability == .live ? .mint : .orange,
                              accessibilityText: metricProjection.steps.accessibilityText)
            }

            // The fill was already gated on this; the track was not, so an
            // empty capsule sat there as a seventh way of saying the same
            // thing. A progress bar with no progress is not information.
            if loadIsReadable {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.10))
                        Capsule()
                            .fill((metricProjection.coachingIsLive ? Metrics.electricStrain : Color.orange).opacity(0.78))
                            .frame(width: max(10, max(proxy.size.width, 1) * progress))
                    }
                }
                .frame(height: 12)
                .accessibilityHidden(true)
            }
        }
        .padding(12)
        .atriaWorkoutContentSurface(cornerRadius: 20, tint: cueTint)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workout cue. \(cueTitle). \(cueDetail). Strain \(metricProjection.strainHUDText)\(accessibilityTargetClause), \(caloriesText) active calories.")
    }

    private func compactMetric(title: String,
                               value: String,
                               systemImage: String,
                               tint: Color,
                               accessibilityText: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.black).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.64)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(.horizontal, 9)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? "\(title), \(value)")
    }
}

/// Pre-workout (or mid-workout) target picker: zone focus or a direct strain
/// goal, styled to match the live HUD's dark glass surfaces (gap spec c).
/// Presented from the target lane's edit affordance; commits through the
/// session-owned binding on Save, or clears it back to "Auto" (the existing
/// guidance default) -- never changes anything until the user confirms.
private struct AtriaWorkoutTargetPicker: View {
    let currentZone: HRZone
    let zoneBoundaries: AtriaHRRZoneBoundaries?
    let guidanceTarget: Double?
    @Binding var choice: AtriaWorkoutTargetChoice?
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case zone = "Zone"
        case strain = "Strain goal"
        var id: String { rawValue }
    }

    @State private var mode: Mode
    @State private var selectedZone: HRZone
    @State private var strainGoal: Double

    init(currentZone: HRZone,
         zoneBoundaries: AtriaHRRZoneBoundaries?,
         guidanceTarget: Double?,
         choice: Binding<AtriaWorkoutTargetChoice?>) {
        self.currentZone = currentZone
        self.zoneBoundaries = zoneBoundaries
        self.guidanceTarget = guidanceTarget
        self._choice = choice
        let fallbackGoal = guidanceTarget ?? AtriaWorkoutTargetMath.strainTarget(for: currentZone)
        switch choice.wrappedValue {
        case .zone(let rawZone):
            _mode = State(initialValue: .zone)
            _selectedZone = State(initialValue: HRZone(rawValue: rawZone) ?? currentZone)
            _strainGoal = State(initialValue: fallbackGoal)
        case .strain(let value):
            _mode = State(initialValue: .strain)
            _selectedZone = State(initialValue: currentZone)
            _strainGoal = State(initialValue: value)
        case nil:
            _mode = State(initialValue: .auto)
            _selectedZone = State(initialValue: currentZone)
            _strainGoal = State(initialValue: fallbackGoal)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Workout target", systemImage: "target")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Save") { commitAndDismiss() }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Metrics.electricStrain)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }

                modePicker

                Group {
                    switch mode {
                    case .auto: autoContent
                    case .zone: zoneContent
                    case .strain: strainContent
                    }
                }

                if mode == .zone {
                    hapticBoundaryNote
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black.ignoresSafeArea())
        }
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(Mode.allCases) { candidate in
                Button {
                    withAnimation(.snappy) { mode = candidate }
                } label: {
                    Text(candidate.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(mode == candidate ? Metrics.electricStrain.opacity(0.24) : Color.white.opacity(0.08),
                                    in: Capsule())
                        .overlay {
                            if mode == candidate {
                                Capsule().stroke(Metrics.electricStrain.opacity(0.6), lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var autoContent: some View {
        HStack(spacing: 10) {
            Label("Atria guidance", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 8)
            if let guidanceTarget {
                Text(String(format: "%.1f", guidanceTarget))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
        .padding(14)
        .atriaWorkoutContentSurface(cornerRadius: 18, tint: .white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(guidanceTarget.map { String(format: "Atria live strain guidance, currently %.1f.", $0) }
                            ?? "Atria is learning your live strain guidance target.")
    }

    private var zoneContent: some View {
        VStack(spacing: 8) {
            ForEach(HRZone.allCases, id: \.self) { zoneOption in
                zoneRow(zoneOption)
            }
        }
        .accessibilityHint("Choose a heart-rate zone using your current resting and maximum heart-rate settings.")
    }

    private func zoneRow(_ zoneOption: HRZone) -> some View {
        let band = AtriaWorkoutTargetMath.strainBand(for: zoneOption)
        let isSelected = selectedZone == zoneOption
        return Button {
            selectedZone = zoneOption
        } label: {
            HStack(spacing: 10) {
                Capsule()
                    .fill(zoneOption.color.opacity(isSelected ? 0.92 : 0.32))
                    .frame(width: 8, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Z\(zoneOption.rawValue) \u{00B7} \(zoneOption.name)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("\(zoneRangeText(zoneOption)) · \(String(format: "%.1f\u{2013}%.1f strain", band.lowerBound, band.upperBound))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(zoneOption.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .atriaWorkoutGlassSurface(cornerRadius: 16, tint: isSelected ? zoneOption.color : .white)
        .accessibilityLabel("Zone \(zoneOption.rawValue), \(zoneOption.name), \(zoneRangeText(zoneOption)), \(String(format: "%.1f to %.1f strain", band.lowerBound, band.upperBound))\(isSelected ? ", selected" : "").")
    }

    private var strainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button {
                    strainGoal = max(1.0, strainGoal - 0.5)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Decrease strain goal")
                Text(String(format: "%.1f", strainGoal))
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 90)
                Button {
                    strainGoal = min(AtriaWorkoutTargetMath.strainCeiling, strainGoal + 0.5)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Increase strain goal")
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Strain goal \(String(format: "%.1f", strainGoal))")
        }
        .padding(14)
        .atriaWorkoutContentSurface(cornerRadius: 18, tint: Metrics.electricStrain)
    }

    private var hapticBoundaryNote: some View {
        Label("Atria vibrates once as you enter or leave the selected zone. Alerts use these same heart-rate-reserve boundaries.",
              systemImage: "applewatch.radiowaves.left.and.right")
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    private func zoneRangeText(_ zone: HRZone) -> String {
        zoneBoundaries?.rangeText(for: zone) ?? "Range unavailable"
    }

    private func commitAndDismiss() {
        switch mode {
        case .auto:
            choice = nil
        case .zone:
            choice = .zone(selectedZone.rawValue)
        case .strain:
            choice = .strain((strainGoal * 10).rounded() / 10)
        }
        dismiss()
    }
}

private struct AtriaWorkoutGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .overlay {
                shape
                    .stroke(tint.opacity(0.28), lineWidth: 1)
            }
            .glassEffect(.regular.tint(tint.opacity(0.12)), in: shape)
    }
}

private struct AtriaWorkoutContentSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.white.opacity(0.08), in: shape)
            .overlay {
                shape
                    .stroke(tint.opacity(0.28), lineWidth: 1)
            }
    }
}

private extension View {
    func atriaWorkoutGlassSurface(cornerRadius: CGFloat, tint: Color) -> some View {
        modifier(AtriaWorkoutGlassSurfaceModifier(cornerRadius: cornerRadius, tint: tint))
    }

    func atriaWorkoutContentSurface(cornerRadius: CGFloat, tint: Color) -> some View {
        modifier(AtriaWorkoutContentSurfaceModifier(cornerRadius: cornerRadius, tint: tint))
    }
}
