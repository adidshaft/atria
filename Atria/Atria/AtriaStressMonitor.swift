import SwiftUI

/// WHOOP-style live 0-3 stress score, built entirely from signals this codebase
/// already publishes: live HR (`ble.heartRate` / `PulseLiveState.heartRate`),
/// rolling RR beats (`recentRRSamples`) for a fast short-window RMSSD, the
/// slower 5-minute `HRVSnapshot`, and the wearer's own personal baseline
/// (`PersonalBaseline`) with its trust tiers. No IMU is used — elevated HR
/// during a workout is recognized and suppressed, not scored as "stress".
///
/// Honesty first: until a personal resting-HR baseline is trusted (14 distinct
/// fresh days), no numeric level is shown at all — only "Calibrating (n/14)".
/// Until the HRV baseline is *also* trusted, the score runs HR-only and is
/// capped at Medium (2): elevated HR alone can never be reported as "High"
/// without HRV corroboration.
enum AtriaStressLevel: Int, Equatable, CaseIterable {
    case calm = 0
    case low = 1
    case medium = 2
    case high = 3

    var title: String {
        switch self {
        case .calm: return "Calm"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// Calm→Low→Medium→High electric ramp. Calm reuses the same electric
    /// green as "in the green" readiness; High reuses the electric red used
    /// elsewhere for out-of-range readings.
    var tint: Color {
        switch self {
        case .calm: return Metrics.electricGreen
        case .low: return Metrics.electricYellow
        case .medium: return .orange
        case .high: return Metrics.electricRed
        }
    }
}

/// Emitted state for the live stress monitor. `level` is nil for every
/// non-scored `kind` (no numeric claim is made while suppressed or learning).
struct AtriaStressState: Equatable {
    enum Kind: Equatable {
        case scored
        case calibrating
        case warmingUp
        case active
        case asleep
        case noSignal
    }

    let level: AtriaStressLevel?
    let label: String
    let detail: String
    let kind: Kind
    /// Data-quality confidence in [0, 1]; 0 for every non-scored kind.
    let confidence: Double
    /// Instantaneous 0...1 activation this state was derived from (0 for
    /// non-scored states). Internal bookkeeping the store uses for EMA
    /// smoothing + hysteresis; not shown to the user directly.
    let rawActivation: Double
    /// True when the HRV term corroborated this reading (full HR+HRV mode).
    /// False in every non-scored state and in the HR-only fallback mode,
    /// where the emitted level is capped at `.medium`.
    let hrvAvailable: Bool

    static let noSignal = AtriaStressState(level: nil, label: "No signal", detail: "",
                                           kind: .noSignal, confidence: 0,
                                           rawActivation: 0, hrvAvailable: false)
}

/// Pure, testable scoring core (mirrors the `AtriaSleepBudget` / `AtriaNapRecovery`
/// style: static functions, no I/O, all thresholds are named constants).
enum AtriaStressMonitor {

    // MARK: Tunable thresholds (kept static + named so behavior stays auditable)

    /// First N seconds of live contact are "Warming up" — too little data for
    /// even an HR-only read.
    static let warmUpSeconds: TimeInterval = 120
    /// Post-workout cooldown: elevated HR right after a session is recovery
    /// tachogram, not stress, so scoring stays suppressed for this long after
    /// the last workout ends.
    static let postWorkoutCooldownSeconds: TimeInterval = 10 * 60
    /// Sustained-elevation workout heuristic when no explicit recording/zone
    /// signal is present.
    static let sustainedWorkoutHRDelta = 40
    /// Minimum coverage (in the RR window) before a short-window RMSSD is
    /// considered trustworthy enough to feed the HRV term.
    static let minimumHRVWindowSeconds: TimeInterval = 90

    static let hrActivationFloorSD = 3.0
    static let hrvActivationFloorSD = 0.15
    static let hrActivationWeight = 0.6
    static let hrvActivationWeight = 0.4

    static let calmUpperBound = 0.20
    static let lowUpperBound = 0.45
    static let mediumUpperBound = 0.72

    /// PURE scoring function: same inputs always produce the same output, no
    /// hidden state, no I/O. Temporal smoothing / hysteresis across calls is
    /// the store's job (see `AtriaStressMonitorStore`), not this function's.
    static func score(hrNow: Int,
                      hrWindow: [Int],
                      rrWindowMs: [Int],
                      hrvFallbackRMSSD: Double?,
                      baseline: PersonalBaseline,
                      restingMaxHR: (rest: Int, max: Int),
                      workoutActive: Bool,
                      zoneIndex: Int?,
                      inSleepWindow: Bool,
                      hasContact: Bool,
                      contactAgeSeconds: TimeInterval,
                      now: Date = Date()) -> AtriaStressState {

        // MARK: Suppression, checked in order.

        guard hasContact, hrNow > 0 else {
            return AtriaStressState(level: nil, label: "No signal", detail: "",
                                    kind: .noSignal, confidence: 0,
                                    rawActivation: 0, hrvAvailable: false)
        }

        if inSleepWindow {
            return AtriaStressState(level: nil, label: "Asleep",
                                    detail: "Stress monitoring pauses during sleep",
                                    kind: .asleep, confidence: 0,
                                    rawActivation: 0, hrvAvailable: false)
        }

        let sustainedElevated = hrNow > restingMaxHR.rest + sustainedWorkoutHRDelta
        if workoutActive || (zoneIndex ?? 0) >= 2 || sustainedElevated {
            return AtriaStressState(level: nil, label: "Active", detail: "During workout",
                                    kind: .active, confidence: 0,
                                    rawActivation: 0, hrvAvailable: false)
        }

        if contactAgeSeconds < warmUpSeconds {
            return AtriaStressState(level: nil, label: "Warming up",
                                    detail: "Building a live read",
                                    kind: .warmingUp, confidence: 0,
                                    rawActivation: 0, hrvAvailable: false)
        }

        guard baseline.hasTrustedRestingBaseline(now: now) else {
            let n = min(baseline.freshRestingSampleCount(now: now), PersonalBaseline.trustedMinimumSamples)
            return AtriaStressState(level: nil,
                                    label: "Calibrating (\(n)/\(PersonalBaseline.trustedMinimumSamples))",
                                    detail: "Building your personal HR baseline",
                                    kind: .calibrating, confidence: 0,
                                    rawActivation: 0, hrvAvailable: false)
        }

        // MARK: Scoring — normalize vs personal baseline (z-scores).

        let hrActivation = hrActivationFraction(hrNow: hrNow, baseline: baseline, restingMaxHR: restingMaxHR, now: now)

        let hrvTrusted = baseline.hasTrustedHRVBaseline(now: now)
        var hrvActivation: Double?
        if hrvTrusted,
           let lnStats = baseline.lnRMSSDStats(now: now), lnStats.count > 1,
           let rmssdNow = shortWindowRMSSD(rrWindowMs) ?? hrvFallbackRMSSD,
           rmssdNow > 0 {
            let lnNow = log(rmssdNow)
            let sd = max(lnStats.sd, hrvActivationFloorSD)
            let hrvZ = (lnStats.mean - lnNow) / sd
            hrvActivation = clamp01(max(hrvZ, 0) / 3)
        }

        let activation: Double
        let hrvAvailable: Bool
        if let hrvActivation {
            activation = hrActivationWeight * hrActivation + hrvActivationWeight * hrvActivation
            hrvAvailable = true
        } else {
            activation = hrActivation
            hrvAvailable = false
        }

        let rawBand = band(activation)
        // HR-only mode (HRV not trusted yet) can never claim "High" without
        // HRV corroboration — cap at Medium.
        let cappedBand = hrvAvailable ? rawBand : min(rawBand, AtriaStressLevel.medium.rawValue)
        let level = AtriaStressLevel(rawValue: cappedBand) ?? .calm
        let detail = hrvAvailable ? "HR + HRV vs your baseline" : "HR-only"
        let confidence = hrvAvailable ? 0.85 : 0.55

        return AtriaStressState(level: level, label: level.title, detail: detail,
                                kind: .scored, confidence: confidence,
                                rawActivation: activation, hrvAvailable: hrvAvailable)
    }

    /// Band index for a 0...1 activation using the static thresholds above.
    static func band(_ activation: Double) -> Int {
        if activation < calmUpperBound { return 0 }
        if activation < lowUpperBound { return 1 }
        if activation < mediumUpperBound { return 2 }
        return 3
    }

    /// Distance-to-nearest-boundary helper used by the store's hysteresis.
    static func distanceToNearestBoundary(_ activation: Double) -> Double {
        [calmUpperBound, lowUpperBound, mediumUpperBound]
            .map { abs($0 - activation) }
            .min() ?? calmUpperBound
    }

    private static func hrActivationFraction(hrNow: Int,
                                             baseline: PersonalBaseline,
                                             restingMaxHR: (rest: Int, max: Int),
                                             now: Date) -> Double {
        if let restingStats = baseline.restingStats(now: now), restingStats.count > 1 {
            let sd = max(restingStats.sd, hrActivationFloorSD)
            let hrZ = (Double(hrNow) - restingStats.mean) / sd
            return clamp01(max(hrZ, 0) / 3)
        }
        // Soft ramp fallback when per-sample stats aren't available yet: 0 at
        // <=5 bpm above baseline, 1.0 at >=25 bpm above baseline.
        let restBaseline = baseline.restingInt ?? restingMaxHR.rest
        let delta = Double(hrNow - restBaseline)
        return clamp01((delta - 5) / 20)
    }

    /// Short-window RMSSD from consecutive RR (ms) beats, only trusted once the
    /// window covers at least `minimumHRVWindowSeconds` of real beats (the sum
    /// of the RR intervals approximates the covered time span).
    private static func shortWindowRMSSD(_ rrMs: [Int]) -> Double? {
        guard rrMs.count >= 2 else { return nil }
        let totalMs = rrMs.reduce(0, +)
        guard Double(totalMs) >= minimumHRVWindowSeconds * 1000 else { return nil }
        var sumSquares = 0.0
        for index in 1..<rrMs.count {
            let diff = Double(rrMs[index] - rrMs[index - 1])
            sumSquares += diff * diff
        }
        return sqrt(sumSquares / Double(rrMs.count - 1))
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

struct AtriaStressDistribution: Codable, Equatable {
    var calmSamples: Int
    var mediumSamples: Int
    var highSamples: Int

    static let empty = AtriaStressDistribution(calmSamples: 0,
                                                mediumSamples: 0,
                                                highSamples: 0)

    var sampleCount: Int { calmSamples + mediumSamples + highSamples }

    var fractions: (calm: Double, medium: Double, high: Double)? {
        guard sampleCount > 0 else { return nil }
        let total = Double(sampleCount)
        return (Double(calmSamples) / total,
                Double(mediumSamples) / total,
                Double(highSamples) / total)
    }

    mutating func record(_ level: AtriaStressLevel) {
        switch level {
        case .calm, .low: calmSamples += 1
        case .medium: mediumSamples += 1
        case .high: highSamples += 1
        }
    }

    mutating func add(_ other: AtriaStressDistribution) {
        calmSamples += other.calmSamples
        mediumSamples += other.mediumSamples
        highSamples += other.highSamples
    }
}

struct AtriaStressDistributionComparison: Equatable {
    let today: AtriaStressDistribution
    /// Nil until at least three matching weekday/weekend days contain enough
    /// measured samples. The UI must not render a "typical" bar before then.
    let typical: AtriaStressDistribution?
    let comparisonDayCount: Int
}

struct AtriaStressDistributionArchive: Codable, Equatable {
    struct Day: Codable, Equatable {
        var day: Date
        var distribution: AtriaStressDistribution
        var lastSampleAt: Date
    }

    private(set) var days: [Day]

    private static let defaultsKey = "atria.stress.distribution.v1"
    private static let retentionDays = 35
    private static let minimumSamplesPerDay = 10
    private static let minimumTypicalDays = 3

    init(days: [Day] = []) {
        self.days = days.sorted { $0.day < $1.day }
    }

    @discardableResult
    mutating func record(level: AtriaStressLevel,
                         at date: Date,
                         calendar: Calendar = .current) -> Bool {
        let normalizedDay = calendar.startOfDay(for: date)
        if let index = days.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: normalizedDay) }) {
            // Guards restoration/replay from counting a sample that was already
            // summarized before this store instance was rebuilt.
            guard date > days[index].lastSampleAt else { return false }
            days[index].distribution.record(level)
            days[index].lastSampleAt = date
        } else {
            var distribution = AtriaStressDistribution.empty
            distribution.record(level)
            days.append(Day(day: normalizedDay,
                            distribution: distribution,
                            lastSampleAt: date))
        }

        let cutoff = calendar.date(byAdding: .day,
                                   value: -Self.retentionDays,
                                   to: normalizedDay) ?? normalizedDay
        days.removeAll { $0.day < cutoff }
        days.sort { $0.day < $1.day }
        return true
    }

    func comparison(at date: Date,
                    calendar: Calendar = .current) -> AtriaStressDistributionComparison? {
        let today = calendar.startOfDay(for: date)
        guard let current = days.first(where: { calendar.isDate($0.day, inSameDayAs: today) }),
              current.distribution.sampleCount > 0 else { return nil }

        let todayIsWeekend = calendar.isDateInWeekend(today)
        let comparable = days.filter {
            $0.day < today
                && calendar.isDateInWeekend($0.day) == todayIsWeekend
                && $0.distribution.sampleCount >= Self.minimumSamplesPerDay
        }
        let typical: AtriaStressDistribution?
        if comparable.count >= Self.minimumTypicalDays {
            typical = comparable.reduce(into: .empty) { result, day in
                result.add(day.distribution)
            }
        } else {
            typical = nil
        }
        return AtriaStressDistributionComparison(today: current.distribution,
                                                 typical: typical,
                                                 comparisonDayCount: comparable.count)
    }

    static func load(defaults: UserDefaults = .standard) -> AtriaStressDistributionArchive {
        guard let data = defaults.data(forKey: defaultsKey),
              let archive = try? JSONDecoder().decode(AtriaStressDistributionArchive.self, from: data) else {
            return AtriaStressDistributionArchive()
        }
        return archive
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Thin store that owns the rolling buffers, activation EMA, hysteresis, and
/// post-workout cooldown; recomputes `AtriaStressMonitor.score(...)` on each
/// pulse update. All the actual scoring logic lives in the pure function above
/// — this class is I/O-shaped plumbing only.
@MainActor
final class AtriaStressMonitorStore: ObservableObject {
    @Published private(set) var state: AtriaStressState = .noSignal
    /// Scored readings from this app session (thinned to ~1 per 30s, capped
    /// at 12h). In-memory only — the history chart shows real gaps for any
    /// stretch the strap wasn't read, never interpolation.
    private(set) var history: [StressHistoryPoint] = []
    /// Cheap change token for SwiftUI observers. The Health screen reads
    /// `history` for data, but watches this integer so live updates never
    /// compare the full rolling array.
    @Published private(set) var historyRevision = 0
    /// Persisted, measured stress-band counts. This is deliberately a compact
    /// aggregate rather than a second high-frequency sample archive: it can
    /// answer "today versus a typical weekday" without inventing values across
    /// gaps or turning a 30-second live signal into an unbounded disk stream.
    private var distributionArchive = AtriaStressDistributionArchive.load()
    @Published private(set) var distributionRevision = 0

    struct StressHistoryPoint: Identifiable, Equatable {
        let t: Date
        /// Continuous activation 0-1 behind the discrete level.
        let activation: Double
        let level: AtriaStressLevel

        var id: TimeInterval { t.timeIntervalSinceReferenceDate }
    }

    private var hrBuffer: [(t: Date, bpm: Int)] = []
    private var contactStartedAt: Date?
    private var wasRecording = false
    private var lastWorkoutEndAt: Date?

    private var smoothedActivation: Double?
    private var lastEmittedLevel: AtriaStressLevel?
    private var candidateLevel: AtriaStressLevel?
    private var candidateStreak = 0
    private var unsavedDistributionSamples = 0

    private static let hrWindowSeconds: TimeInterval = 60
    private static let rrWindowSeconds: TimeInterval = 180
    private static let activationEMAAlpha = 0.2
    private static let hysteresisMargin = 0.05
    private static let hysteresisHoldTicks = 2
    nonisolated static let unchangedInputEvaluationInterval: TimeInterval = 30

    nonisolated static func shouldEvaluateStressInput(force: Bool,
                                                       inputChanged: Bool,
                                                       isNoSignal: Bool,
                                                       lastEvaluatedAt: Date?,
                                                       now: Date,
                                                       minimumInterval: TimeInterval = unchangedInputEvaluationInterval) -> Bool {
        if force || inputChanged { return true }
        guard let lastEvaluatedAt else { return true }
        if isNoSignal { return false }
        return now.timeIntervalSince(lastEvaluatedAt) >= minimumInterval
    }

    private func recordHistory(now: Date) {
        guard case .scored = state.kind, let level = state.level,
              let activation = smoothedActivation else { return }
        if let last = history.last, now.timeIntervalSince(last.t) < 30 { return }
        history.append(StressHistoryPoint(t: now, activation: activation, level: level))
        history.removeAll { now.timeIntervalSince($0.t) > 12 * 3600 }
        historyRevision &+= 1

        if distributionArchive.record(level: level, at: now) {
            distributionRevision &+= 1
            unsavedDistributionSamples += 1
            // At the 30-second history cadence this writes at most every five
            // minutes. A process interruption can lose only the small pending
            // tail; previously persisted evidence is never reconstructed.
            if unsavedDistributionSamples >= 10 {
                distributionArchive.save()
                unsavedDistributionSamples = 0
            }
        }
    }

    func distributionComparison(now: Date = Date(),
                                calendar: Calendar = .current) -> AtriaStressDistributionComparison? {
        distributionArchive.comparison(at: now, calendar: calendar)
    }

    /// Feed one pulse tick in. Safe to call as often as ~every 5s (or on every
    /// HR/RR update); the buffers + EMA absorb the exact cadence.
    func update(heartRate: Int,
                hasContact: Bool,
                recentRRSamples: [AtriaBreathworkSession.RRSample],
                isRecording: Bool,
                zoneIndex: Int?,
                hrvSnapshot: HRVSnapshot?,
                baseline: PersonalBaseline,
                restingMaxHR: (rest: Int, max: Int),
                hasActiveSleepEvidence: Bool = false,
                now: Date = Date()) {

        if !hasContact {
            contactStartedAt = nil
        } else if contactStartedAt == nil {
            contactStartedAt = now
        }

        if wasRecording, !isRecording {
            lastWorkoutEndAt = now
        }
        wasRecording = isRecording

        if hasContact, heartRate > 0 {
            hrBuffer.append((t: now, bpm: heartRate))
        }
        hrBuffer.removeAll { now.timeIntervalSince($0.t) > Self.hrWindowSeconds }

        let rrWindow = recentRRSamples
            .filter {
                let age = now.timeIntervalSince($0.date)
                return age >= -5 && age <= Self.rrWindowSeconds
            }
        let validatedShortWindowRMSSD = AtriaShortWindowRMSSD.value(
            samples: rrWindow.map { (date: $0.date, ms: Double($0.ms)) },
            minimumCoverageSeconds: AtriaStressMonitor.minimumHRVWindowSeconds
        )

        let smoothedHR: Int
        if hrBuffer.isEmpty {
            smoothedHR = heartRate
        } else {
            let total = hrBuffer.reduce(0) { $0 + $1.bpm }
            smoothedHR = Int((Double(total) / Double(hrBuffer.count)).rounded())
        }

        let contactAge = contactStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let cooldownActive = lastWorkoutEndAt.map { now.timeIntervalSince($0) < AtriaStressMonitor.postWorkoutCooldownSeconds } ?? false
        let hrvFallback: Double? = validatedShortWindowRMSSD
            ?? ((hrvSnapshot?.isLiveStressEligible(on: now) == true) ? hrvSnapshot?.rmssd : nil)

        let raw = AtriaStressMonitor.score(hrNow: smoothedHR,
                                           hrWindow: hrBuffer.map(\.bpm),
                                           // The timestamped path above is authoritative in
                                           // production. An empty raw array prevents the pure
                                           // compatibility scorer from bridging disconnected
                                           // RR islands when strict evidence is unavailable.
                                           rrWindowMs: [],
                                           hrvFallbackRMSSD: hrvFallback,
                                           baseline: baseline,
                                           restingMaxHR: restingMaxHR,
                                           workoutActive: isRecording || cooldownActive,
                                           zoneIndex: zoneIndex,
                                           // The learned duty-cycle window is a
                                           // radio/upload schedule, not proof that
                                           // the wearer is asleep. Only an actual
                                           // active-sleep authority may suppress
                                           // the live stress reading.
                                           inSleepWindow: hasActiveSleepEvidence,
                                           hasContact: hasContact,
                                           contactAgeSeconds: contactAge,
                                           now: now)

        guard raw.kind == .scored, let rawLevel = raw.level else {
            smoothedActivation = nil
            lastEmittedLevel = nil
            candidateLevel = nil
            candidateStreak = 0
            if raw != state { state = raw }
            return
        }

        let ema = smoothedActivation.map { $0 + Self.activationEMAAlpha * (raw.rawActivation - $0) } ?? raw.rawActivation
        smoothedActivation = ema

        let smoothedBand = AtriaStressMonitor.band(ema)
        let cappedBand = raw.hrvAvailable ? smoothedBand : min(smoothedBand, AtriaStressLevel.medium.rawValue)
        let smoothedLevel = AtriaStressLevel(rawValue: cappedBand) ?? rawLevel

        let emittedLevel: AtriaStressLevel
        if let lastEmittedLevel {
            if smoothedLevel == lastEmittedLevel {
                candidateLevel = nil
                candidateStreak = 0
                emittedLevel = lastEmittedLevel
            } else {
                if candidateLevel == smoothedLevel {
                    candidateStreak += 1
                } else {
                    candidateLevel = smoothedLevel
                    candidateStreak = 1
                }
                let boundaryDistance = AtriaStressMonitor.distanceToNearestBoundary(ema)
                if boundaryDistance >= Self.hysteresisMargin || candidateStreak >= Self.hysteresisHoldTicks {
                    emittedLevel = smoothedLevel
                    self.lastEmittedLevel = smoothedLevel
                    candidateLevel = nil
                    candidateStreak = 0
                } else {
                    emittedLevel = lastEmittedLevel
                }
            }
        } else {
            emittedLevel = smoothedLevel
            lastEmittedLevel = smoothedLevel
        }

        let finalState = AtriaStressState(level: emittedLevel, label: emittedLevel.title,
                                          detail: raw.detail, kind: .scored,
                                          confidence: raw.confidence,
                                          rawActivation: ema, hrvAvailable: raw.hrvAvailable)
        if finalState != state {
            state = finalState
        }
        recordHistory(now: now)
    }
}
