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
    @Published private(set) var history: [StressHistoryPoint] = []

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

    private static let hrWindowSeconds: TimeInterval = 60
    private static let rrWindowSeconds: TimeInterval = 180
    private static let activationEMAAlpha = 0.2
    private static let hysteresisMargin = 0.05
    private static let hysteresisHoldTicks = 2

    private func recordHistory(now: Date) {
        guard case .scored = state.kind, let level = state.level,
              let activation = smoothedActivation else { return }
        if let last = history.last, now.timeIntervalSince(last.t) < 30 { return }
        history.append(StressHistoryPoint(t: now, activation: activation, level: level))
        history.removeAll { now.timeIntervalSince($0.t) > 12 * 3600 }
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
            .filter { now.timeIntervalSince($0.date) <= Self.rrWindowSeconds }
            .map(\.ms)

        let smoothedHR: Int
        if hrBuffer.isEmpty {
            smoothedHR = heartRate
        } else {
            let total = hrBuffer.reduce(0) { $0 + $1.bpm }
            smoothedHR = Int((Double(total) / Double(hrBuffer.count)).rounded())
        }

        let contactAge = contactStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let cooldownActive = lastWorkoutEndAt.map { now.timeIntervalSince($0) < AtriaStressMonitor.postWorkoutCooldownSeconds } ?? false
        let hrvFallback: Double? = (hrvSnapshot?.isReady == true) ? hrvSnapshot?.rmssd : nil

        let raw = AtriaStressMonitor.score(hrNow: smoothedHR,
                                           hrWindow: hrBuffer.map(\.bpm),
                                           rrWindowMs: rrWindow,
                                           hrvFallbackRMSSD: hrvFallback,
                                           baseline: baseline,
                                           restingMaxHR: restingMaxHR,
                                           workoutActive: isRecording || cooldownActive,
                                           zoneIndex: zoneIndex,
                                           inSleepWindow: AtriaResearchUploadQueue.isWithinSleepWindow(now: now),
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
