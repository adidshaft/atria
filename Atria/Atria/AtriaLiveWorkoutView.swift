import SwiftUI
import UIKit
import MapKit

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
    var startingStepCount: Int = 0
    /// Strap steps accumulated during completed pause windows. These are
    /// removed from workout-only steps while the day total remains monotonic.
    var pausedStepCount: Int = 0
    /// Day-total anchor captured exactly when the current pause began.
    var pauseStartedStepCount: Int? = nil
    var startingDayStrain: Double = 0

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
        case .reconnecting: return "reconnecting"
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
    var sensorAvailability: AtriaLiveSensorAvailability = .unavailable
    var sensorCapturedAt: Date?
    var hasSensorEvidence = false

    static let empty = AtriaLiveWorkoutMetricProjection()

    var coachingIsLive: Bool {
        hasSensorEvidence && sensorAvailability == .live
    }

    var strainHUDText: String {
        hasSensorEvidence ? String(format: "%.1f", strain) : "--"
    }

    var activeCaloriesHUDText: String {
        guard hasSensorEvidence, let activeCalories else { return "--" }
        return "≈ \(Int(activeCalories.rounded())) kcal"
    }

    var strainHUDTitle: String {
        hasSensorEvidence && sensorAvailability != .live ? "Last strain" : "Strain"
    }

    var activeCaloriesHUDTitle: String {
        hasSensorEvidence && sensorAvailability != .live ? "Last active" : "Active"
    }

    var sensorStatusTitle: String? {
        guard hasSensorEvidence else { return "Waiting for strap" }
        switch sensorAvailability {
        case .live: return nil
        case .reconnecting: return "Reconnecting"
        case .stale: return "Signal paused"
        case .unavailable: return "Signal unavailable"
        }
    }

    var sensorStatusDetail: String? {
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
        guard maxHR > rest, samples.count > 1 else {
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
        let normalized = Self.normalized(excludedIntervals)
        let canExtend = self.startedAt == startedAt
            && self.rest == rest
            && self.maxHR == maxHR
            && self.sex == sex
            && self.profile == profile
            && self.excludedIntervals == normalized
            && sampleCount > 0
            && sampleCount <= samples.count
            && lastTimestamp == samples[sampleCount - 1].t
        var total = canExtend ? value : 0
        var calories = canExtend ? (activeCalories ?? 0) : 0
        var integratedEvidence = canExtend ? hasEvidence : false
        // The BLE session is an all-day, bounded continuity buffer. A workout
        // can begin near its tail, so replaying from index 1 after a target,
        // profile or pause change needlessly walks hours of pre-workout HR on
        // the main actor. Binary-search directly to the first pair fully inside
        // this workout; subsequent updates remain append-only via `sampleCount`.
        var index = canExtend
            ? sampleCount
            : Self.firstIntegrationIndex(samples: samples, startedAt: startedAt)
        let reserve = Double(maxHR - rest)
        let coefficient = AtriaAnalytics.Strain.banisterCoefficient(for: sex)
        while index < samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            let dt = current.t.timeIntervalSince(previous.t)
            let excluded = normalized.contains { interval in
                previous.t <= interval.end && current.t >= interval.start
            }
            if previous.t >= startedAt,
               current.t >= startedAt,
               dt > 0,
               dt <= AtriaAnalytics.Strain.maximumLoadEvidenceGap,
               !excluded {
                integratedEvidence = true
                let meanBPM = (Double(previous.bpm) + Double(current.bpm)) / 2
                let hrr = min(max((meanBPM - Double(rest)) / reserve, 0), 1)
                total += (dt / 60) * hrr * 0.64 * exp(coefficient * hrr)
                if let profile, profile.hasEnergyProfile {
                    calories += Metrics.dayCalories([
                        Metrics.HeartRateEnergySample(t: previous.t, bpm: previous.bpm),
                        Metrics.HeartRateEnergySample(t: current.t, bpm: current.bpm),
                    ], rest: rest, profile: profile) ?? 0
                }
            }
            index += 1
        }
        self.startedAt = startedAt
        sampleCount = samples.count
        lastTimestamp = samples.last?.t
        self.rest = rest
        self.maxHR = maxHR
        self.sex = sex
        self.profile = profile
        self.excludedIntervals = normalized
        value = total
        activeCalories = profile?.hasEnergyProfile == true ? calories : nil
        hasEvidence = integratedEvidence
        return AtriaLiveWorkoutSensorMetrics(trimp: total,
                                              activeCalories: activeCalories,
                                              hasEvidence: integratedEvidence)
    }

    mutating func clear() {
        startedAt = nil
        sampleCount = 0
        lastTimestamp = nil
        value = 0
        activeCalories = nil
        hasEvidence = false
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
    var pausedStepCount: Int = 0
    var pauseStartedStepCount: Int? = nil
    var completedStepCount: Int? = nil
    var completedStepsAreEstimated: Bool? = nil
    var completedStepsCapturedAt: Date? = nil
    let startingDayStrain: Double

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
        case pausedStepCount
        case pauseStartedStepCount
        case completedStepCount
        case completedStepsAreEstimated
        case completedStepsCapturedAt
        case startingDayStrain
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
        pausedStepCount = try values.decodeIfPresent(Int.self, forKey: .pausedStepCount) ?? 0
        pauseStartedStepCount = try values.decodeIfPresent(Int.self,
                                                            forKey: .pauseStartedStepCount)
        completedStepCount = try values.decodeIfPresent(Int.self, forKey: .completedStepCount)
        completedStepsAreEstimated = try values.decodeIfPresent(Bool.self,
                                                                 forKey: .completedStepsAreEstimated)
        completedStepsCapturedAt = try values.decodeIfPresent(Date.self,
                                                               forKey: .completedStepsCapturedAt)
        startingDayStrain = try values.decodeIfPresent(Double.self, forKey: .startingDayStrain) ?? 0
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
         pausedStepCount: Int = 0,
         pauseStartedStepCount: Int? = nil,
         completedStepCount: Int? = nil,
         completedStepsAreEstimated: Bool? = nil,
         completedStepsCapturedAt: Date? = nil,
         startingDayStrain: Double) {
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
        self.pausedStepCount = max(0, pausedStepCount)
        self.pauseStartedStepCount = pauseStartedStepCount
        self.completedStepCount = completedStepCount.map { max(0, $0) }
        self.completedStepsAreEstimated = completedStepCount == nil ? nil : completedStepsAreEstimated
        self.completedStepsCapturedAt = completedStepCount == nil ? nil : completedStepsCapturedAt
        self.startingDayStrain = startingDayStrain
    }

    var resolvedActivityType: AtriaWorkoutActivityType {
        AtriaWorkoutActivityType(rawValue: activityType) ?? .other
    }

    var targetChoice: AtriaWorkoutTargetChoice? {
        if let targetStrain { return .strain(targetStrain) }
        if let targetZone { return .zone(targetZone) }
        return nil
    }

    static func load(defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    @discardableResult
    func save(defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.defaultsKey)
        return true
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Completion work is asynchronous. Never let an older route/session
    /// callback clear a newer workout that replaced the singleton intent while
    /// evidence was being prepared or persisted.
    @discardableResult
    static func clearIfUnchanged(_ expected: Self,
                                 defaults: UserDefaults = .standard) -> Bool {
        guard load(defaults: defaults) == expected else { return false }
        clear(defaults: defaults)
        return true
    }

    static func isActiveForBLEContinuity(defaults: UserDefaults = .standard,
                                         now: Date = Date(),
                                         maxAge: TimeInterval = bleContinuityMaxAge) -> Bool {
        guard let intent = load(defaults: defaults), intent.endedAt == nil else { return false }
        let age = now.timeIntervalSince(intent.startedAt)
        return age >= -bleContinuityFutureTolerance && age <= maxAge
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
}

struct AtriaWorkoutStartConfiguration: Equatable {
    var activityType: AtriaWorkoutActivityType = .other
    var lowerTargetZone: Int = HRZone.fatBurn.rawValue
    var upperTargetZone: Int = HRZone.aerobic.rawValue

    var normalizedZoneRange: ClosedRange<Int> {
        min(lowerTargetZone, upperTargetZone)...max(lowerTargetZone, upperTargetZone)
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

        init?(workoutStartedAt: Date,
              lowerTargetZone: Int,
              upperTargetZone: Int,
              maxHR: Int) {
            guard maxHR > 0 else { return nil }
            let lowerRaw = min(lowerTargetZone, upperTargetZone)
            let upperRaw = max(lowerTargetZone, upperTargetZone)
            guard let lowerZone = HRZone(rawValue: lowerRaw),
                  let upperZone = HRZone(rawValue: upperRaw) else { return nil }
            self.workoutStartedAt = workoutStartedAt
            self.lowerZone = lowerZone
            self.upperZone = upperZone
            self.maxHR = maxHR
        }

        var lowerBPM: Int {
            Int((Double(maxHR) * lowerZone.lowerFraction).rounded(.up))
        }

        var upperBPM: Int {
            guard let nextZone = HRZone(rawValue: upperZone.rawValue + 1) else {
                return maxHR
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
                            isPaused: Bool) {
        guard let workoutStartedAt,
              let lowerTargetZone,
              let upperTargetZone,
              let next = Configuration(workoutStartedAt: workoutStartedAt,
                                       lowerTargetZone: lowerTargetZone,
                                       upperTargetZone: upperTargetZone,
                                       maxHR: maxHR) else {
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
    let onStart: (AtriaWorkoutStartConfiguration) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: AtriaWorkoutStartConfiguration
    @State private var showAllActivityTypes = false
    @State private var activitySearch = ""

    init(initial: AtriaWorkoutStartConfiguration = .init(),
         onStart: @escaping (AtriaWorkoutStartConfiguration) -> Void) {
        var resolvedInitial = initial
        if resolvedInitial.activityType == .other {
            let recent = UserDefaults.standard
                .stringArray(forKey: "atria.workout.recentActivityTypes")?
                .compactMap(AtriaWorkoutActivityType.init(rawValue:))
                .first
            resolvedInitial.activityType = recent ?? .walking
        }
        self.initial = resolvedInitial
        self.onStart = onStart
        _configuration = State(initialValue: resolvedInitial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Activity")
                        .font(.title2.weight(.bold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(compactActivityTypes) { type in
                                activityButton(type)
                                    .frame(width: 104)
                            }
                            Button {
                                showAllActivityTypes = true
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "magnifyingglass").font(.callout.weight(.bold))
                                    Text("More").font(.caption.weight(.bold)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 58)
                            }
                            .buttonStyle(.glass)
                            .frame(width: 92)
                        }
                    }

                    HStack(spacing: 10) {
                        Text("Heart-rate target")
                            .font(.title2.weight(.bold))
                        Spacer(minLength: 8)
                        Label(selectedZoneRangeText, systemImage: "scope")
                            .font(.caption.weight(.black).monospacedDigit())
                            .foregroundStyle(.cyan)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .background(.cyan.opacity(0.12), in: Capsule())
                            .accessibilityLabel("Target heart rate \(selectedZoneRangeText)")
                    }
                    GlassEffectContainer(spacing: 10) {
                        VStack(spacing: 12) {
                            zoneSelector(title: "Target lower zone", selection: $configuration.lowerTargetZone)
                            zoneSelector(title: "Target upper zone", selection: $configuration.upperTargetZone)
                        }
                    }
                    .accessibilityHint("One pulse at the lower boundary, three above the upper boundary, and two when returning from above.")
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
                            .frame(minHeight: 44)
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
                    onStart(value)
                    dismiss()
                } label: {
                    Label("Start \(configuration.activityType.rawValue)", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glassProminent)
                .tint(.cyan)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .onChange(of: configuration.lowerTargetZone) { _, lower in
                // Keep the visible range valid as it is edited. Normalizing only
                // after Start made a temporary Z5–Z2 target look accepted even
                // though the persisted workout would silently reverse it.
                if configuration.upperTargetZone < lower {
                    configuration.upperTargetZone = lower
                }
            }
            .onChange(of: configuration.upperTargetZone) { _, upper in
                if configuration.lowerTargetZone > upper {
                    configuration.lowerTargetZone = upper
                }
            }
        }
    }

    private var selectedZoneRangeText: String {
        let range = configuration.normalizedZoneRange
        return range.lowerBound == range.upperBound
            ? "Z\(range.lowerBound)"
            : "Z\(range.lowerBound)–Z\(range.upperBound)"
    }

    private var compactActivityTypes: [AtriaWorkoutActivityType] {
        let stored = UserDefaults.standard.stringArray(forKey: "atria.workout.recentActivityTypes") ?? []
        let recent = stored.compactMap(AtriaWorkoutActivityType.init(rawValue:))
        let preferred: [AtriaWorkoutActivityType] = [configuration.activityType, .strength, .walking, .running, .cycling, .cardio]
        var seen = Set<AtriaWorkoutActivityType>()
        return ([configuration.activityType] + recent + preferred)
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

    private func activityButton(_ type: AtriaWorkoutActivityType) -> some View {
        Button { selectActivity(type) } label: {
            HStack(spacing: 7) {
                Image(systemName: type.icon).font(.callout.weight(.bold))
                Text(type.rawValue).font(.caption.weight(.bold)).lineLimit(1)
            }
            .foregroundStyle(configuration.activityType == type ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.glass)
        .tint(configuration.activityType == type ? .cyan : .primary.opacity(0.08))
    }

    private func selectActivity(_ type: AtriaWorkoutActivityType) {
        configuration.activityType = type
        let key = "atria.workout.recentActivityTypes"
        let existing = UserDefaults.standard.stringArray(forKey: key) ?? []
        UserDefaults.standard.set(([type.rawValue] + existing.filter { $0 != type.rawValue }).prefix(6).map { $0 },
                                  forKey: key)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func zoneSelector(title: String, selection: Binding<Int>) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(HRZone.allCases.filter { $0 != .rest }, id: \.rawValue) { zone in
                    Text("Z\(zone.rawValue) · \(zone.name)").tag(zone.rawValue)
                }
            }
            .pickerStyle(.menu)
            .buttonStyle(.glass)
        }
        .frame(minHeight: 52)
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

/// Route geometry changes at most once per location publication, while the
/// parent workout HUD refreshes for heart rate and timers. This Equatable leaf
/// prevents rebuilding and remapping the entire polyline on every pulse tick.
private struct AtriaLiveWorkoutRouteMap: View, Equatable {
    let segments: [[CLLocationCoordinate2D]]
    @State private var cameraPosition: MapCameraPosition = .userLocation(
        followsHeading: false,
        fallback: .automatic
    )

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.segments.count == rhs.segments.count,
              lhs.segments.reduce(0, { $0 + $1.count })
                == rhs.segments.reduce(0, { $0 + $1.count }) else { return false }
        guard let lhsLast = lhs.segments.last?.last,
              let rhsLast = rhs.segments.last?.last else {
            return lhs.segments.isEmpty && rhs.segments.isEmpty
        }
        return lhsLast.latitude == rhsLast.latitude && lhsLast.longitude == rhsLast.longitude
    }

    var body: some View {
        Map(position: $cameraPosition) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, coordinates in
                MapPolyline(coordinates: coordinates)
                    .stroke(.cyan,
                            style: StrokeStyle(lineWidth: 5,
                                               lineCap: .round,
                                               lineJoin: .round))
            }
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
    }
}

/// The sole observer of route snapshots. GPS updates redraw this map-first
/// leaf without re-evaluating the full live-workout hierarchy.
private struct AtriaLiveWorkoutRouteCard: View {
    @ObservedObject var routeRecorder: AtriaWorkoutRouteRecorder

    var body: some View {
        let route = routeRecorder.snapshot
        ZStack(alignment: .topLeading) {
            AtriaLiveWorkoutRouteMap(segments: route.previewSegments)
                .equatable()

            routeStatus(route)
                .padding(.horizontal, 16)
                .padding(.top, 70)
                .safeAreaPadding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.pointCount >= 2
                            ? "Workout route, \(distanceText(route.distanceMeters)), pace \(paceText(distance: route.distanceMeters, movingDuration: routeRecorder.movingDuration()))."
                            : (route.lastError ?? "Finding your current route"))
    }

    @ViewBuilder
    private func routeStatus(_ route: AtriaWorkoutRouteRecorder.Snapshot) -> some View {
        if route.pointCount >= 2 {
            HStack(spacing: 12) {
                Label(distanceText(route.distanceMeters), systemImage: "location.fill")
                Label(paceText(distance: route.distanceMeters,
                               movingDuration: routeRecorder.movingDuration()),
                      systemImage: "speedometer")
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
}

/// Live workout HUD: a full-screen, glanceable real-time view shown while a
/// workout is active — big live HR + zone, a zone bar, live strain building
/// toward a target, active calories, and elapsed time. All values come from the
/// existing live stores (no new pipeline); the strap is already recording.
struct AtriaLiveWorkoutView: View {
    let pulseStore: AtriaHomeModel.PulseLiveStore
    /// The workout surface is the sole observer. This intentionally must not
    /// move back to a value read at the Home root or rapid sensor updates will
    /// invalidate the whole app shell while this cover is presented.
    @ObservedObject var metricStore: AtriaLiveWorkoutMetricStore
    // The route map owns the 1 Hz observation. Keeping this reference plain
    // prevents GPS publishes from invalidating HR, zones, strain and set logging.
    let routeRecorder: AtriaWorkoutRouteRecorder
    let maxHR: Int
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
    let onStop: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSetLogger = false
    @State private var showTargetPicker = false
    @State private var selectedExercise = "Barbell bench press"
    @State private var loggerWeightKg = 60.0
    @State private var loggerReps = 8
    @State private var loggerRestSeconds: TimeInterval = 120
    @State private var restTimerEndsAt: Date?
    @State private var editingSetID: UUID?
    @State private var latestPRSetID: UUID?

    private var metricProjection: AtriaLiveWorkoutMetricProjection {
        metricStore.state
    }

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
                .presentationDetents([.height(390), .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showTargetPicker) {
            AtriaWorkoutTargetPicker(currentZone: HRZone.zone(for: pulseStore.state.heartRate, maxHR: maxHR),
                                     guidanceTarget: strainTarget,
                                     choice: $targetChoice)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
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
            AtriaLiveWorkoutRouteCard(routeRecorder: routeRecorder)
                .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.52), .clear, .black.opacity(0.78)],
                           startPoint: .top,
                           endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 10) {
                header
                Spacer(minLength: 24)
                AtriaLiveWorkoutRouteMetricsHUD(pulseStore: pulseStore,
                                                metricProjection: metricProjection,
                                                maxHR: maxHR,
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
            AtriaLiveWorkoutBackdrop(pulseStore: pulseStore, maxHR: maxHR)

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        header
                        AtriaLiveWorkoutHeartBlock(pulseStore: pulseStore,
                                                   maxHR: maxHR,
                                                   lowerTargetZone: lowerTargetZone,
                                                   upperTargetZone: upperTargetZone)
                            .padding(.top, 2)
                        AtriaLiveWorkoutStrainGuidance(metricProjection: metricProjection,
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
                    Label("End", systemImage: "stop.fill")
                        .font(.headline.weight(.black))
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
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
                Label(activityType == .other ? "Workout" : activityType.rawValue,
                      systemImage: activityType.icon)
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

                loggerStepperRow(title: "Weight",
                                 value: "\(Int(loggerWeightKg.rounded())) kg",
                                 decrement: { loggerWeightKg = max(0, loggerWeightKg - 2.5) },
                                 increment: { loggerWeightKg += 2.5 })
                loggerStepperRow(title: "Reps",
                                 value: "\(loggerReps)",
                                 decrement: { loggerReps = max(1, loggerReps - 1) },
                                 increment: { loggerReps = min(99, loggerReps + 1) })
                loggerStepperRow(title: "Rest",
                                 value: restOverrideText(loggerRestSeconds),
                                 decrement: { updateRestOverride(max(30, loggerRestSeconds - 15)) },
                                 increment: { updateRestOverride(min(600, loggerRestSeconds + 15)) })

                exerciseHistoryPanel

                Button {
                    saveLoggedSet()
                } label: {
                    Label(editingSetID == nil ? "Save set" : "Update set", systemImage: "checkmark.circle.fill")
                        .font(.headline.weight(.black))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.glassProminent)
                .tint(.mint)
            }
            .padding(18)
        }
    }

    private func loggerStepperRow(title: String,
                                  value: String,
                                  decrement: @escaping () -> Void,
                                  increment: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.bold))
            Spacer()
            Button(action: decrement) {
                Image(systemName: "minus.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Text(value)
                .font(.title3.weight(.black).monospacedDigit())
                .frame(minWidth: 86)
            Button(action: increment) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            return
        }
        selectedExercise = exercise
        loggerWeightKg = last.weightKg ?? loggerWeightKg
        loggerReps = last.reps ?? loggerReps
    }

    private func saveLoggedSet() {
        let set = LoggedSet(exercise: selectedExercise,
                            weightKg: loggerWeightKg > 0 ? loggerWeightKg : nil,
                            reps: loggerReps,
                            rpe: nil,
                            t: Date())
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

    private func editLoggedSet(_ set: LoggedSet) {
        editingSetID = set.id
        selectedExercise = set.exercise
        loggerRestSeconds = AtriaStrengthLog.restSeconds(for: set.exercise)
        loggerWeightKg = set.weightKg ?? loggerWeightKg
        loggerReps = set.reps ?? loggerReps
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
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("History", systemImage: "chart.xyaxis.line")
                    .font(.caption.weight(.black))
                Spacer()
                Text(history.isEmpty ? "No sets yet" : "\(history.count) days")
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
            Label("End workout", systemImage: "stop.fill")
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .atriaCardAction(tint: .red)
    }

    private func endWorkout() {
        finalizePauseIfNeeded()
        onStop()
        dismiss()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let zone = HRZone.zone(for: pulseStore.state.heartRate, maxHR: maxHR)
        LinearGradient(colors: [zone.color.opacity(0.45), .black],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: zone)
    }
}

/// One compact, pulse-driven overlay for outdoor workouts. Keeping HR here
/// isolates rapid strap publications from the map and pinned action controls.
private struct AtriaLiveWorkoutRouteMetricsHUD: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    let metricProjection: AtriaLiveWorkoutMetricProjection
    let maxHR: Int
    let lowerTargetZone: Int?
    let upperTargetZone: Int?
    let onEditTarget: () -> Void

    private var heartRate: Int { pulseStore.state.heartRate }
    private var zone: HRZone { HRZone.zone(for: heartRate, maxHR: maxHR) }
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
                Image(systemName: "heart.fill")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.red)

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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Heart rate \(heartRate) beats per minute")

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(zoneText)
                        .font(.caption.weight(.black))
                        .foregroundStyle(zone.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
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
    let maxHR: Int
    let lowerTargetZone: Int?
    let upperTargetZone: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let heartRate = pulseStore.state.heartRate
        let zone = HRZone.zone(for: heartRate, maxHR: maxHR)
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

                Spacer(minLength: 6)

                Text(zone.rawValue == 0 ? "Below Z1" : "Z\(zone.rawValue) · \(zone.name)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(zone.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
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
                            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: zone)
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
        let icon = Image(systemName: "heart.fill")
            .font(.title2)
            .foregroundStyle(.red)
        if reduceMotion {
            icon
        } else {
            icon.symbolEffect(.pulse, options: .repeating)
        }
    }

    private func zoneBandText(_ zone: HRZone) -> String {
        let lower = Int((Double(maxHR) * zone.lowerFraction).rounded())
        guard let upperZone = HRZone(rawValue: zone.rawValue + 1) else { return "\(lower)+" }
        let upper = max(lower, Int((Double(maxHR) * upperZone.lowerFraction).rounded()) - 1)
        return "\(lower)-\(upper)"
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

            HStack(spacing: 8) {
                compactMetric(title: metricProjection.strainHUDTitle,
                              value: metricProjection.strainHUDText,
                              systemImage: "bolt.heart.fill",
                              tint: metricProjection.coachingIsLive ? Metrics.electricStrain : .orange)
                compactMetric(title: metricProjection.activeCaloriesHUDTitle,
                              value: metricProjection.activeCaloriesHUDText,
                              systemImage: "flame.fill",
                              tint: metricProjection.coachingIsLive ? .pink : .orange)
                compactMetric(title: "Steps",
                              value: metricProjection.steps.hudText,
                              systemImage: "figure.walk",
                              tint: metricProjection.steps.availability == .live ? .mint : .orange,
                              accessibilityText: metricProjection.steps.accessibilityText)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    if metricProjection.hasSensorEvidence {
                        Capsule()
                            .fill((metricProjection.coachingIsLive ? Metrics.electricStrain : Color.orange).opacity(0.78))
                            .frame(width: max(10, max(proxy.size.width, 1) * progress))
                    }
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)
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

    init(currentZone: HRZone, guidanceTarget: Double?, choice: Binding<AtriaWorkoutTargetChoice?>) {
        self.currentZone = currentZone
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
        .accessibilityHint("Choose a heart-rate zone; Atria maps it to the displayed strain band.")
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
                    Text(String(format: "%.1f\u{2013}%.1f strain", band.lowerBound, band.upperBound))
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
        .accessibilityLabel("Zone \(zoneOption.rawValue), \(zoneOption.name), \(String(format: "%.1f to %.1f strain", band.lowerBound, band.upperBound))\(isSelected ? ", selected" : "").")
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
