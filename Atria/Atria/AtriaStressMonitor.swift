import SwiftUI

/// WHOOP-style live 0-3 stress score, built entirely from signals this codebase
/// already publishes: live HR (`ble.heartRate` / `PulseLiveState.heartRate`),
/// rolling RR beats (`recentRRSamples`) for a fast short-window RMSSD, the
/// slower 5-minute `HRVSnapshot`, and the wearer's own personal baseline
/// (`PersonalBaseline`) with its trust tiers. No IMU is used — elevated HR
/// during a workout is recognized and suppressed, not scored as "stress".
///
/// The HR term is z-scored against the wearer's own recent AWAKE heart rate
/// (learned median, or resting + a default offset until learned) — NOT their
/// resting/sleep baseline, which made ordinary wakefulness read as stress. The
/// HRV term is z-scored against the overnight HRV baseline. Either signal alone
/// tops out at Medium; only elevated HR AND suppressed HRV together reach High.
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

/// One presentation policy shared by Home, Today, and Health. Keeping this
/// projection beside the scorer prevents individual screens from inventing a
/// second stress algorithm or presenting a numeric value while the canonical
/// monitor is calibrating, warming up, asleep, active, or disconnected.
struct AtriaStressPresentation: Equatable {
    let level: AtriaStressLevel?
    let value: String
    let detail: String
    let narrative: String

    static func make(state: AtriaStressState) -> Self {
        let detail: String
        let narrative: String
        switch state.kind {
        case .scored:
            detail = state.detail.isEmpty ? "Live strap reading" : state.detail
            narrative = state.hrvAvailable
                ? "Measured from live HR (vs your typical awake heart rate) and HRV (vs your overnight baseline). Either signal alone reads at most Medium; High needs both."
                : "Measured from live HR vs your typical awake heart rate; without a trusted HRV baseline it is capped at Medium — High needs HRV corroboration."
        case .calibrating:
            detail = state.detail.isEmpty ? "Building your personal HR baseline" : state.detail
            // Real-time confusion fix (2026-08-05, user report): live HR was
            // streaming beside a "--" stress value with no explanation of the
            // gate. Name the mechanism: HR is live now; scoring needs a
            // trusted baseline of qualified rest days (one per day, so this
            // takes days by design, not by lag).
            narrative = "Live heart rate is streaming now. Stress scoring turns on once \(PersonalBaseline.trustedMinimumSamples) qualified rest days (about two weeks of overnight wear) build your personal baseline."
        case .warmingUp:
            detail = "2 min of live signal"
            narrative = "Stress is waiting for enough continuous live signal to make a reliable reading."
        case .active:
            detail = "Paused during activity"
            narrative = "Stress monitoring pauses during activity and the post-workout recovery window."
        case .asleep:
            detail = "Paused during detected sleep"
            narrative = "Stress monitoring pauses while sleep is actively detected."
        case .noSignal:
            // No signal can mean a connected strap whose next qualified frame
            // has not arrived yet. Do not prescribe reconnecting unless the
            // connection authority independently proves a link failure.
            detail = "Waiting for a fresh strap signal"
            narrative = "Stress resumes after a fresh qualified strap reading."
        }
        return Self(level: state.level,
                    // Value lines carry a real scored band or the one canonical
                    // no-value token. The specific unscored state remains in
                    // `detail`, where it cannot masquerade as a measurement.
                    value: state.level?.title
                        ?? AtriaCompactMetricPresentation.noValue,
                    detail: detail,
                    narrative: narrative)
    }
}

/// Pure, testable scoring core (mirrors the `AtriaSleepBudget`
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

    static let hrvActivationFloorSD = 0.15
    /// Corroboration weight for the HR+HRV combination. Each term is multiplied
    /// by this, so a single term alone tops out at 0.6 — inside the Medium band
    /// (< the 0.72 High threshold) — and only genuine HR elevation AND HRV
    /// suppression together clear into High. This keeps the stated contract
    /// ("elevated HR alone is never High without HRV corroboration"), extends
    /// the same guarantee symmetrically to a lone HRV drop (which is nonspecific
    /// — illness/alcohol/dehydration), and avoids the noisy-OR's over-firing
    /// where two merely-moderate signals combined to High (adversarial review
    /// 2026-08-08).
    static let stressCorroborationWeight = 0.6

    // Awake HR reference (2026-08-08 rescoring). Live awake HR was z-scored
    // against the RESTING/sleep baseline, so ordinary wakefulness saturated
    // activation to 1.0 — validated on 4 real days of this wearer's HR, the old
    // math pinned 90-98% of every waking day to "Medium". Awake HR sits ~15 bpm
    // above resting (measured median 69-79 vs resting 56.5), so the HR term is
    // now referenced to the wearer's own recent AWAKE HR when known, else a
    // physiological default of resting + offset. Divisor/thresholds unchanged,
    // which reproduces a sensible ~65% Calm / ~20% Medium day on the real data.
    static let defaultAwakeOffsetBPM = 15.0
    // Widened 12 -> 14 (2026-08-08) after pulling 178k real awake-HR samples
    // from the device: quiet-awake HR spans ~69-92 (p10-p90) around a ~78
    // median, so a 12 bpm default spread flagged ordinary up-and-about HR (85+)
    // as Medium during the cold-start window BEFORE the personal reference
    // warms. Widening the spread (center unchanged, so genuinely-calm wearers
    // are not under-read) moves typical active-awake HR back to Low; the learned
    // reference still supersedes this default the moment it warms.
    static let defaultAwakeSpreadBPM = 14.0
    static let awakeActivationFloorSD = 5.0
    static let awakeActivationDivisor = 2.0

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
                      awakeReference: (center: Double, spread: Double)? = nil,
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
            // Progress in the detail line (2026-08-05): the card surfaces
            // `detail`, not `label`, so the count was invisible — a user
            // watching live HR stream had no way to tell how far calibration
            // was or that it advances one qualified rest day at a time.
            return AtriaStressState(level: nil,
                                    label: "Calibrating (\(n)/\(PersonalBaseline.trustedMinimumSamples))",
                                    detail: "Baseline \(n) of \(PersonalBaseline.trustedMinimumSamples) rest days",
                                    kind: .calibrating, confidence: 0,
                                    rawActivation: 0, hrvAvailable: false)
        }

        // MARK: Scoring — normalize vs personal baseline (z-scores).

        let hrActivation = hrActivationFraction(hrNow: hrNow, baseline: baseline, restingMaxHR: restingMaxHR, awakeReference: awakeReference, now: now)

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
            // Corroboration model (adversarial review 2026-08-08): each term is
            // weighted by `stressCorroborationWeight` (0.6), so a single elevated
            // signal — HR alone OR HRV alone — tops out at 0.6, inside Medium and
            // below the 0.72 High threshold; only genuine HR elevation AND HRV
            // suppression together clear into High. This keeps the stated
            // contract (elevated HR alone is never High), extends it symmetric-
            // ally to a lone (nonspecific) HRV drop, and avoids the noisy-OR that
            // escalated two merely-moderate signals to High by double-counting
            // the same arousal.
            activation = clamp01(stressCorroborationWeight * (hrActivation + hrvActivation))
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
        let detail = hrvAvailable ? "HR + HRV" : "HR-only"
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

    /// HR contribution to stress activation, z-scored against the wearer's
    /// AWAKE heart-rate reference — never their resting/sleep baseline. Uses the
    /// person's own observed recent awake HR (`awakeReference`) when the store
    /// has learned it, otherwise a physiological default of
    /// `restingMean + defaultAwakeOffsetBPM`. Being at one's typical awake HR
    /// yields ~0 activation (Calm); only genuine elevation above it climbs.
    private static func hrActivationFraction(hrNow: Int,
                                             baseline: PersonalBaseline,
                                             restingMaxHR: (rest: Int, max: Int),
                                             awakeReference: (center: Double, spread: Double)?,
                                             now: Date) -> Double {
        let center: Double
        let spread: Double
        if let awakeReference {
            center = awakeReference.center
            spread = max(awakeReference.spread, awakeActivationFloorSD)
        } else {
            let restMean = baseline.restingStats(now: now)?.mean
                ?? Double(baseline.restingInt ?? restingMaxHR.rest)
            center = restMean + defaultAwakeOffsetBPM
            spread = defaultAwakeSpreadBPM
        }
        let z = (Double(hrNow) - center) / spread
        return clamp01(max(z, 0) / awakeActivationDivisor)
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

    /// Days with enough measured samples to appear in the daily stress trend —
    /// the same ≥10-sample floor the "typical" comparison uses, so a day can
    /// never chart with less evidence than it needs to count as comparable.
    func measuredTrendDays() -> [Day] {
        days.filter { $0.distribution.sampleCount >= Self.minimumSamplesPerDay }
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

/// A learned awake-HR reference persisted across launches. The live buffer takes
/// ~8 min of quiet-awake wear to warm up; without this, every cold start throws
/// the reference away and the first stress readings fall back to the fixed
/// physiological default (resting + offset). Seeding from the last learned
/// reference makes the first scored reading reflect the wearer's own awake HR,
/// and the live buffer supersedes it as soon as it warms up.
struct AtriaAwakeReferenceSnapshot: Codable, Equatable {
    var center: Double
    var spread: Double
    var updatedAt: Date
}

/// A slow, multi-day awake-HR baseline that resists a single stressful stretch.
///
/// The 45-min `awakeReference` is responsive but absorbs sustained stress: an
/// hours-long stressor fills the trailing window with elevated HR, the median
/// rises, and the reading drifts back to Calm (audit B3). This archive keeps a
/// per-day histogram of quiet-awake HR and exposes the MEDIAN OF DAILY MEDIANS,
/// so one elevated day cannot move the baseline — a whole stressed day is scored
/// against the wearer's calm-day norm, while a genuine multi-week fitness drift
/// is followed because it moves most days' medians together.
///
/// Recording-only for now: the store accumulates into it, but scoring does NOT
/// yet consume it (that wire-in is gated on validation against real strap HR).
/// Kept deliberately compact (an integer-bpm histogram per retained day) rather
/// than a second high-frequency sample stream, mirroring the distribution
/// archive's philosophy.
struct AtriaAwakeBaselineArchive: Codable, Equatable {
    struct Day: Codable, Equatable {
        var day: Date
        /// bpm → count of admitted quiet-awake samples that day.
        var histogram: [Int: Int]
        var lastSampleAt: Date

        var sampleCount: Int { histogram.values.reduce(0, +) }

        /// The day's median bpm from the cumulative histogram, or nil if empty.
        var median: Double? {
            let total = sampleCount
            guard total > 0 else { return nil }
            let sortedBPM = histogram.keys.sorted()
            // Lower and upper median positions (1-indexed) for an even/odd count.
            let lowerTarget = (total + 1) / 2
            let upperTarget = total / 2 + 1
            var cumulative = 0
            var lower: Int?
            var upper: Int?
            for bpm in sortedBPM {
                cumulative += histogram[bpm] ?? 0
                if lower == nil, cumulative >= lowerTarget { lower = bpm }
                if upper == nil, cumulative >= upperTarget { upper = bpm }
                if lower != nil, upper != nil { break }
            }
            guard let lower, let upper else { return nil }
            return (Double(lower) + Double(upper)) / 2
        }
    }

    private(set) var days: [Day]

    private static let defaultsKey = "atria.stress.awakeBaseline.v1"
    private static let retentionDays = 30
    /// A day needs at least this many admitted quiet-awake samples before its
    /// median is trustworthy enough to contribute to the multi-day center.
    static let minimumSamplesPerDay = 30
    /// The multi-day center is withheld until this many qualifying days exist.
    static let minimumQualifyingDays = 3

    init(days: [Day] = []) {
        self.days = days.sorted { $0.day < $1.day }
    }

    @discardableResult
    mutating func record(bpm: Int,
                         at date: Date,
                         calendar: Calendar = .current) -> Bool {
        guard bpm > 0 else { return false }
        let normalizedDay = calendar.startOfDay(for: date)
        if let index = days.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: normalizedDay) }) {
            // Guards restoration/replay from re-counting an already-summarized
            // sample after this store instance is rebuilt.
            guard date > days[index].lastSampleAt else { return false }
            days[index].histogram[bpm, default: 0] += 1
            days[index].lastSampleAt = date
        } else {
            days.append(Day(day: normalizedDay,
                            histogram: [bpm: 1],
                            lastSampleAt: date))
        }
        let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: normalizedDay) ?? normalizedDay
        days.removeAll { $0.day < cutoff }
        days.sort { $0.day < $1.day }
        return true
    }

    /// Number of retained days with enough samples to contribute a daily median.
    var qualifyingDayCount: Int {
        days.filter { $0.sampleCount >= Self.minimumSamplesPerDay }.count
    }

    /// Robust multi-day center: the median of the qualifying days' daily medians,
    /// or nil until `minimumQualifyingDays` exist. One stressed day is one
    /// outlier among the daily medians and cannot move it.
    func multiDayCenter() -> Double? {
        let dailyMedians = days
            .filter { $0.sampleCount >= Self.minimumSamplesPerDay }
            .compactMap { $0.median }
            .sorted()
        guard dailyMedians.count >= Self.minimumQualifyingDays else { return nil }
        let mid = dailyMedians.count / 2
        return dailyMedians.count.isMultiple(of: 2)
            ? (dailyMedians[mid - 1] + dailyMedians[mid]) / 2
            : dailyMedians[mid]
    }

    static func load(defaults: UserDefaults = .standard) -> AtriaAwakeBaselineArchive {
        guard let data = defaults.data(forKey: defaultsKey),
              let archive = try? JSONDecoder().decode(AtriaAwakeBaselineArchive.self, from: data) else {
            return AtriaAwakeBaselineArchive()
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
    /// Most recent contact-backed live heart rate fed into the monitor, for
    /// surfaces that pair a heart readout with the stress read (the Activity
    /// "heart & stress" card). Publishes only on bpm change; cleared on lost
    /// contact. Render-side must gate on `at` freshness — a stored reading is
    /// not a claim the strap is still delivering.
    @Published private(set) var liveHeartRate: LiveHeartRateReading?

    struct LiveHeartRateReading: Equatable {
        let bpm: Int
        let at: Date

        func isFresh(now: Date = Date(),
                     window: TimeInterval = AtriaStressReadingFreshness.liveWindow) -> Bool {
            now.timeIntervalSince(at) <= window
        }
    }
    /// Clock of the most recent scored evaluation. Presentation surfaces use
    /// this source clock; merely opening a screen must never renew freshness.
    @Published private(set) var lastMeasuredAt: Date?
    /// Scored readings from this app session (thinned to ~1 per 30s, capped
    /// at 24h so the expanded detail can show a full day). In-memory only — the
    /// history chart shows real gaps for any stretch the strap wasn't read,
    /// never interpolation. ~2,880 points × 24 B ≈ 68 KB at the cap.
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
    /// Longer trailing buffer of AWAKE, non-workout HR, from which a robust
    /// awake reference (median + spread) is learned so the HR term is scored
    /// against the wearer's own typical awake HR rather than a fixed default
    /// (2026-08-08 rescoring). Separate from the 60 s smoothing `hrBuffer`.
    private var awakeHRBuffer: [(t: Date, bpm: Int)] = []
    private static let awakeReferenceWindowSeconds: TimeInterval = 45 * 60
    /// Minimum awake samples and time span before the learned reference is
    /// trusted; until then the scorer uses its physiological default.
    nonisolated private static let awakeReferenceMinSamples = 60
    nonisolated private static let awakeReferenceMinSpanSeconds: TimeInterval = 8 * 60
    /// Only HR at least this far above resting is admitted to the awake buffer,
    /// so sleeping/resting HR can't collapse the learned reference (bug #9 makes
    /// the sleep guard inert; this floor is the robust proxy).
    private static let awakeReferenceMinDeltaAboveRest = 8
    /// Last learned awake reference, restored at launch so scoring starts from
    /// the wearer's own awake HR instead of the fixed default while the live
    /// buffer warms up. Superseded in memory the moment the live buffer is warm.
    private var persistedAwakeReference: AtriaAwakeReferenceSnapshot?
    private var lastAwakeReferencePersistAt: Date?
    /// UserDefaults suite backing the awake-reference seed. Injectable so tests
    /// can exercise persistence without touching the shared standard suite.
    private let awakeReferenceDefaults: UserDefaults
    /// Slow multi-day awake-HR baseline (audit B3). Recording-only for now: the
    /// store accumulates admitted quiet-awake samples into it, but scoring does
    /// not yet consume `multiDayAwakeCenter()` — that wire-in is gated on
    /// validation against real strap HR. Loaded from the same injected suite.
    private var awakeBaselineArchive: AtriaAwakeBaselineArchive
    private var unsavedAwakeBaselineSamples = 0
    /// Flush the baseline archive to disk at most once per this many admitted
    /// samples; a process interruption loses only the small pending tail.
    private static let awakeBaselinePersistEverySamples = 20

    init(defaults: UserDefaults = .standard) {
        self.awakeReferenceDefaults = defaults
        self.persistedAwakeReference = Self.loadPersistedAwakeReference(defaults: defaults)
        self.awakeBaselineArchive = AtriaAwakeBaselineArchive.load(defaults: defaults)
    }

    private static let awakeReferenceDefaultsKey = "atria.stress.awakeReference.v1"
    /// A persisted reference older than this is discarded: awake HR drifts with
    /// fitness, illness, and season, so a stale seed is worse than the default.
    private static let awakeReferenceSeedMaxAge: TimeInterval = 14 * 24 * 3600
    /// Throttle disk writes; the reference changes slowly and is re-derived every
    /// tick, so persisting more often buys nothing.
    private static let awakeReferencePersistInterval: TimeInterval = 5 * 60
    private var contactStartedAt: Date?
    /// Clock of the last tick that carried live contact. Used to distinguish a
    /// brief flicker (single zero-contact sample, one missed ~6s freshness
    /// window) from a sustained loss of signal.
    private var lastContactAt: Date?
    private var wasRecording = false
    private var lastWorkoutEndAt: Date?

    private var smoothedActivation: Double?
    private var lastEmittedLevel: AtriaStressLevel?
    private var candidateLevel: AtriaStressLevel?
    private var candidateStreak = 0
    private var unsavedDistributionSamples = 0

    private static let hrWindowSeconds: TimeInterval = 60
    private static let rrWindowSeconds: TimeInterval = 180
    /// Warm-up continuity grace (2026-07-31 device review): the tile sat at
    /// "collecting 2 min of live signal" indefinitely because ANY single tick
    /// without contact — one zero-HR skin-contact flicker, or one HR sample
    /// aging past the 6s live-freshness window between throttled updates —
    /// nilled `contactStartedAt` and restarted the full 2-minute clock. Warm-up
    /// is now anchored to accepted-HR continuity: only a sustained gap longer
    /// than this restarts it. Must stay comfortably above
    /// `unchangedInputEvaluationInterval` (30s): with unchanged inputs, ticks
    /// legitimately arrive ~30s apart, and a grace at or below that cadence
    /// would restart warm-up on every quiet tick — the exact stall this fixes.
    private static let warmUpContactGraceSeconds: TimeInterval = 60
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

    /// Robust awake HR reference (median + MAD-derived spread) from the trailing
    /// awake buffer, or nil until it has enough samples over enough time — the
    /// scorer then falls back to its physiological default. Median/MAD (not
    /// mean/SD) so a brief spike or a stray beat can't drag the reference.
    nonisolated static func awakeReference(from buffer: [(t: Date, bpm: Int)],
                               now: Date) -> (center: Double, spread: Double)? {
        guard buffer.count >= awakeReferenceMinSamples,
              let first = buffer.first?.t, let last = buffer.last?.t,
              last.timeIntervalSince(first) >= awakeReferenceMinSpanSeconds else {
            return nil
        }
        let sorted = buffer.map { Double($0.bpm) }.sorted()
        let median = Self.median(of: sorted)
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let mad = Self.median(of: deviations)
        // 1.4826 makes MAD a consistent estimator of SD for normal data.
        return (center: median, spread: mad * 1.4826)
    }

    nonisolated private static func median(of sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let mid = sortedValues.count / 2
        return sortedValues.count.isMultiple(of: 2)
            ? (sortedValues[mid - 1] + sortedValues[mid]) / 2
            : sortedValues[mid]
    }

    /// One-shot, tiny (three-field) decode at launch — deliberately not on the
    /// high-frequency `Record` path that the JSONDecoder retention issue touched.
    static func loadPersistedAwakeReference(defaults: UserDefaults = .standard) -> AtriaAwakeReferenceSnapshot? {
        guard let data = defaults.data(forKey: awakeReferenceDefaultsKey),
              let snapshot = try? JSONDecoder().decode(AtriaAwakeReferenceSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    private func persistAwakeReference(_ snapshot: AtriaAwakeReferenceSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        awakeReferenceDefaults.set(data, forKey: Self.awakeReferenceDefaultsKey)
    }

    private func recordHistory(now: Date) {
        // Record the PUBLISHED (Medium-capped in HR-only mode) activation, not
        // the raw EMA, so the timeline can never plot above the emitted level
        // (audit §1 #7). `smoothedActivation` still gates recording to warm,
        // scored ticks.
        guard case .scored = state.kind, let level = state.level,
              smoothedActivation != nil else { return }
        if let last = history.last, now.timeIntervalSince(last.t) < 30 { return }
        history.append(StressHistoryPoint(t: now, activation: state.rawActivation, level: level))
        history.removeAll { now.timeIntervalSince($0.t) > 24 * 3600 }
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

    /// Measured days for the daily stress trend (§3.3). Read-only projection of
    /// the persisted distribution archive — no second sample stream exists.
    func dailyTrendDays() -> [AtriaStressDistributionArchive.Day] {
        distributionArchive.measuredTrendDays()
    }

    /// Slow multi-day awake-HR center (audit B3), or nil until enough qualifying
    /// days have accumulated. Read-only: scoring does not yet consume this — it
    /// exists so the accumulated baseline can be validated against real strap HR
    /// before the scorer is switched to anchor on it.
    func slowAwakeBaselineCenter() -> Double? {
        awakeBaselineArchive.multiDayCenter()
    }

    var slowAwakeBaselineQualifyingDayCount: Int {
        awakeBaselineArchive.qualifyingDayCount
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

        if hasContact, heartRate > 0 {
            if liveHeartRate?.bpm != heartRate {
                liveHeartRate = LiveHeartRateReading(bpm: heartRate, at: now)
            } else if let current = liveHeartRate, now.timeIntervalSince(current.at) > 30 {
                // Same bpm for a while: refresh the stamp so freshness gating
                // doesn't hide a steadily-delivering strap.
                liveHeartRate = LiveHeartRateReading(bpm: heartRate, at: now)
            }
        } else {
            liveHeartRate = nil
        }

        if hasContact {
            if let lastContactAt,
               now.timeIntervalSince(lastContactAt) > Self.warmUpContactGraceSeconds {
                // Sustained outage: this is genuinely fresh contact, so the
                // warm-up clock restarts honestly from here.
                contactStartedAt = now
            } else if contactStartedAt == nil {
                contactStartedAt = now
            }
            lastContactAt = now
        } else if let lastContactAt,
                  now.timeIntervalSince(lastContactAt) > Self.warmUpContactGraceSeconds {
            // Only a sustained loss resets warm-up; brief flickers (single
            // zero-contact sample, one missed freshness window) keep the
            // accepted-HR continuity anchor. Scoring itself still suppresses
            // to "No signal" on every tick without contact.
            contactStartedAt = nil
            self.lastContactAt = nil
        }

        if wasRecording, !isRecording {
            lastWorkoutEndAt = now
        }
        wasRecording = isRecording

        if hasContact, heartRate > 0 {
            hrBuffer.append((t: now, bpm: heartRate))
        }
        hrBuffer.removeAll { now.timeIntervalSince($0.t) > Self.hrWindowSeconds }

        // Learn the wearer's awake HR reference from QUIET-AWAKE wear only. The
        // buffer must mirror the scorer's own exclusions and, critically, reject
        // sleeping HR: `hasActiveSleepEvidence` is currently hardcoded false at
        // both callers (bug #9), so without an explicit floor the 45-min buffer
        // fills with overnight ~56 bpm, the median collapses, and every morning's
        // awake HR reads a false Medium (adversarial review 2026-08-08, B2).
        // Bracket the accepted band: strictly above resting (excludes sleep/rest)
        // and at/below the activity threshold (excludes exertion the scorer
        // suppresses anyway, B4).
        let cooldownForReference = lastWorkoutEndAt
            .map { now.timeIntervalSince($0) < AtriaStressMonitor.postWorkoutCooldownSeconds } ?? false
        let awakeLowerBound = restingMaxHR.rest + Self.awakeReferenceMinDeltaAboveRest
        let activityUpperBound = restingMaxHR.rest + AtriaStressMonitor.sustainedWorkoutHRDelta
        if hasContact, heartRate > 0,
           !isRecording, !cooldownForReference, !hasActiveSleepEvidence,
           (zoneIndex ?? 0) < 2,
           heartRate > awakeLowerBound, heartRate <= activityUpperBound {
            awakeHRBuffer.append((t: now, bpm: heartRate))
            // Feed the same admitted quiet-awake sample into the slow multi-day
            // baseline (audit B3, recording-only). This runs even before the
            // baseline is consumed by scoring, so real per-day medians accumulate
            // and are ready to validate the eventual wire-in.
            if awakeBaselineArchive.record(bpm: heartRate, at: now) {
                unsavedAwakeBaselineSamples += 1
                if unsavedAwakeBaselineSamples >= Self.awakeBaselinePersistEverySamples {
                    awakeBaselineArchive.save(defaults: awakeReferenceDefaults)
                    unsavedAwakeBaselineSamples = 0
                }
            }
        }
        awakeHRBuffer.removeAll { now.timeIntervalSince($0.t) > Self.awakeReferenceWindowSeconds }
        let liveAwakeReference = Self.awakeReference(from: awakeHRBuffer, now: now)
        // A freshly learned reference is authoritative and gets persisted (write
        // throttled) so the next launch can seed from it. Until the live buffer
        // warms up, fall back to a recently persisted reference; only if that is
        // missing or stale does the scorer drop to its physiological default.
        let awakeReference: (center: Double, spread: Double)?
        if let liveAwakeReference {
            let snapshot = AtriaAwakeReferenceSnapshot(center: liveAwakeReference.center,
                                                       spread: liveAwakeReference.spread,
                                                       updatedAt: now)
            persistedAwakeReference = snapshot
            if lastAwakeReferencePersistAt.map({ now.timeIntervalSince($0) >= Self.awakeReferencePersistInterval }) ?? true {
                persistAwakeReference(snapshot)
                lastAwakeReferencePersistAt = now
            }
            awakeReference = liveAwakeReference
        } else if let seed = persistedAwakeReference,
                  now.timeIntervalSince(seed.updatedAt) <= Self.awakeReferenceSeedMaxAge {
            awakeReference = (center: seed.center, spread: seed.spread)
        } else {
            awakeReference = nil
        }

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
                                           awakeReference: awakeReference,
                                           now: now)

        guard raw.kind == .scored, let rawLevel = raw.level else {
            smoothedActivation = nil
            lastEmittedLevel = nil
            candidateLevel = nil
            candidateStreak = 0
            lastMeasuredAt = nil
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

        // HR-only mode caps the emitted level at Medium (see `cappedBand`
        // above). The published activation drives the detail gauge and the
        // history timeline (both render score = activation × 3), so it must be
        // capped to the same Medium ceiling — otherwise the gauge/timeline can
        // render "High" while the label reads "Medium" (audit §1 #7). The
        // internal `smoothedActivation` keeps the true, uncapped EMA so band
        // continuity and hysteresis are unaffected.
        let displayActivation = raw.hrvAvailable
            ? ema
            : min(ema, AtriaStressMonitor.mediumUpperBound)
        let finalState = AtriaStressState(level: emittedLevel, label: emittedLevel.title,
                                          detail: raw.detail, kind: .scored,
                                          confidence: raw.confidence,
                                          rawActivation: displayActivation,
                                          hrvAvailable: raw.hrvAvailable)
        if finalState != state {
            state = finalState
        }
        lastMeasuredAt = now
        recordHistory(now: now)
    }
}
