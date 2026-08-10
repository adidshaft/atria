import Darwin
import Foundation
import SwiftUI

/// Live physiological-stress state from Atria's single versioned v3 kernel.
/// The five-minute minute-framed fact preserves qualified HR/RR provenance,
/// confidence, motion/sleep context and calibration version. Missing qualified
/// HR creates a gap; unavailable HRV yields an explicit lower-confidence
/// HR-only estimate rather than a fabricated autonomic measurement.
enum AtriaStressLevel: Int, Equatable, CaseIterable, Sendable {
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

/// The physiological evidence contract behind one scored monitor sample.
///
/// Version-3 facts share one continuous 0...3 coordinate. When qualified HRV
/// is unavailable, the numeric value remains an explicitly lower-confidence
/// HR-only estimate; it is never presented as a psychological diagnosis.
/// `cardiacArousal` remains only as a compatibility provenance for legacy,
/// non-versioned in-memory callers.
enum AtriaStressEvidenceMode: String, Equatable, Sendable {
    case physiologicalStress
    case cardiacArousal

    var metricTitle: String {
        "Physiological stress"
    }
}

/// Pure shared conversion from the monitor's canonical 0...1 activation into
/// its product-scale evidence. Consumers should use this projection instead of
/// multiplying activation by three themselves so v3 HR+HRV and explicitly
/// lower-confidence HR-only facts stay on one continuous coordinate.
struct AtriaStressEvidenceProjection: Equatable, Sendable {
    static let maximumDisplayValue = 3.0

    let mode: AtriaStressEvidenceMode
    let activation: Double

    init(activation: Double, mode: AtriaStressEvidenceMode) {
        self.mode = mode
        self.activation = activation.isFinite ? min(max(activation, 0), 1) : 0
    }

    /// A bounded 0...3 value in the evidence mode's own coordinate system.
    var displayValue: Double {
        activation * Self.maximumDisplayValue
    }

    /// Both evidence modes use Atria's continuous 0...3 scale. HR-only remains
    /// explicitly lower-confidence in its provenance and user-facing copy.
    var numericStressScore: Double? {
        displayValue
    }

    /// Legacy non-v3 callers remain separately queryable for compatibility.
    var cardiacArousalValue: Double? {
        mode == .cardiacArousal ? displayValue : nil
    }

    /// The bounded qualitative band in this evidence coordinate. Version 3
    /// uses Calm / Moderate / High at exact 1 and 2 boundaries.
    var qualitativeLevel: AtriaStressLevel {
        let rawBand = AtriaStressMonitor.band(activation)
        return AtriaStressLevel(rawValue: rawBand) ?? .calm
    }

    static var lowStartsAt: Double {
        AtriaStressMonitor.calmUpperBound * maximumDisplayValue
    }

    static var mediumStartsAt: Double {
        AtriaStressMonitor.lowUpperBound * maximumDisplayValue
    }

    static var highStartsAt: Double {
        AtriaStressMonitor.mediumUpperBound * maximumDisplayValue
    }
}

/// Emitted state for the live stress monitor. `level` is nil for every
/// non-scored compatibility `kind` (no numeric claim is made in those states).
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
    /// True when a fresh qualified HRV term was available for this reading.
    /// False in every non-scored state and in the lower-confidence HR-only
    /// fallback mode.
    let hrvAvailable: Bool
    /// Exact minute-level model fact behind the current live state. Legacy
    /// compatibility calls may leave this nil; production live scoring and
    /// persisted history use it as the single auditable source of truth.
    let minuteFact: AtriaPhysiologicalStressModel.MinuteFact?

    init(level: AtriaStressLevel?,
         label: String,
         detail: String,
         kind: Kind,
         confidence: Double,
         rawActivation: Double,
         hrvAvailable: Bool,
         minuteFact: AtriaPhysiologicalStressModel.MinuteFact? = nil) {
        self.level = level
        self.label = label
        self.detail = detail
        self.kind = kind
        self.confidence = confidence
        self.rawActivation = rawActivation
        self.hrvAvailable = hrvAvailable
        self.minuteFact = minuteFact
    }

    var evidenceMode: AtriaStressEvidenceMode? {
        guard kind == .scored, level != nil else { return nil }
        if minuteFact?.scoringVersion == AtriaPhysiologicalStressModel.scoringVersion {
            return .physiologicalStress
        }
        return hrvAvailable ? .physiologicalStress : .cardiacArousal
    }

    var evidenceProjection: AtriaStressEvidenceProjection? {
        guard let evidenceMode else { return nil }
        return AtriaStressEvidenceProjection(activation: rawActivation,
                                             mode: evidenceMode)
    }

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
    /// Nil for every unscored state. Scored version-3 HR-only estimates retain
    /// this provenance while using the same continuous numeric coordinate.
    let evidenceMode: AtriaStressEvidenceMode?
    let metricTitle: String
    /// A bounded 0...3 value for every complete version-3 fact.
    let numericScore: Double?

    init(level: AtriaStressLevel?,
         value: String,
         detail: String,
         narrative: String,
         evidenceMode: AtriaStressEvidenceMode? = nil,
         metricTitle: String = "Physiological stress",
         numericScore: Double? = nil) {
        self.level = level
        self.value = value
        self.detail = detail
        self.narrative = narrative
        self.evidenceMode = evidenceMode
        self.metricTitle = metricTitle
        self.numericScore = numericScore
    }

    static func make(state: AtriaStressState) -> Self {
        let detail: String
        let narrative: String
        let projection = state.evidenceProjection
        switch state.kind {
        case .scored:
            if state.hrvAvailable {
                let evidence = state.detail.isEmpty
                    ? "HR + HRV"
                    : state.detail
                detail = evidence.hasPrefix(state.label)
                    ? evidence
                    : "\(state.label) · \(evidence)"
                narrative = "Physiological stress estimated from a five-minute cardiac window, your personal resting heart rate and qualified HRV distribution. It is not a psychological diagnosis."
            } else {
                let evidence = state.detail.contains("HR-only estimate")
                    ? state.detail
                    : "HR-only estimate · lower confidence"
                detail = evidence.hasPrefix(state.label)
                    ? evidence
                    : "\(state.label) · \(evidence)"
                narrative = "Physiological stress estimated from heart rate only because qualified current HRV was unavailable. This lower-confidence estimate is not a psychological diagnosis."
            }
        case .calibrating:
            detail = state.detail.isEmpty ? "Learning your personal baseline" : state.detail
            narrative = "Atria uses a conservative personalized fallback while your baseline learns and labels complete estimates lower confidence."
        case .warmingUp:
            detail = "5 min of continuous signal"
            narrative = "Physiological stress is waiting for a complete five-minute live cardiac window."
        case .active:
            detail = "Activity context"
            narrative = "Independently qualified activity can attenuate exercise-driven elevation, but it never erases the physiological-stress estimate."
        case .asleep:
            detail = "Sleep context"
            narrative = "Qualified sleep is shown as timeline context; missing or inferred sleep never invents a calm estimate."
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
                    value: projection?.numericStressScore.map {
                        "\($0.formatted(.number.precision(.fractionLength(1)))) / 3"
                    } ?? AtriaCompactMetricPresentation.noValue,
                    detail: detail,
                    narrative: narrative,
                    evidenceMode: projection?.mode,
                    metricTitle: projection?.mode.metricTitle ?? "Physiological stress",
                    numericScore: projection?.numericStressScore)
    }
}

/// Pure, testable scoring core (mirrors the `AtriaSleepBudget`
/// style: static functions, no I/O, all thresholds are named constants).
enum AtriaStressMonitor {

    // MARK: Tunable thresholds (kept static + named so behavior stays auditable)

    /// Persisted with every derived timeline point. Bump whenever activation,
    /// banding, capping, or hysteresis semantics change so a later build never
    /// silently presents unlike scores as one continuous series.
    static let scoringVersion = AtriaPhysiologicalStressModel.scoringVersion

    /// A complete five-minute HR horizon is required before the first fact.
    static let warmUpSeconds = AtriaPhysiologicalStressModel.windowDuration
    /// Post-workout exclusion used only while learning the quiet-awake HR
    /// reference. V3 scoring attenuates qualified activity; it does not erase it.
    static let postWorkoutCooldownSeconds: TimeInterval = 10 * 60
    /// Upper admission bound for the quiet-awake reference learner.
    static let sustainedWorkoutHRDelta = 40
    static let calmUpperBound = 1.0 / 3.0
    /// Retained as a source-compatible alias. V3 has no separate Low zone.
    static let lowUpperBound = calmUpperBound
    static let mediumUpperBound = 2.0 / 3.0

    #if DEBUG
    /// Test-only compatibility adapter for older fixtures. Production live and
    /// historical paths call `AtriaPhysiologicalStressModel.evaluate` directly;
    /// keeping this adapter behind DEBUG prevents a second shipping scorer.
    /// Untimestamped `hrvFallbackRMSSD` cannot prove qualified RR succession and
    /// is therefore never admitted as current HRV.
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
        guard hasContact, hrNow > 0 else {
            return AtriaStressState(level: nil, label: "No signal", detail: "",
                                    kind: .noSignal, confidence: 0,
                                    rawActivation: 0, hrvAvailable: false)
        }
        if contactAgeSeconds < warmUpSeconds {
            return AtriaStressState(level: nil, label: "Warming up",
                                    detail: "Building a five-minute cardiac window",
                                    kind: .warmingUp, confidence: 0,
                                    rawActivation: 0, hrvAvailable: false)
        }
        let suppliedHeartRates = hrWindow.isEmpty ? [hrNow] : hrWindow
        let fixtureMinimumSampleCount = max(
            AtriaPhysiologicalStressModel.minimumQualifiedHRSamples,
            Int(ceil(
                AtriaPhysiologicalStressModel.windowDuration
                    / AtriaPhysiologicalStressModel.maximumRawHeartRateGap
            )) + 1
        )
        let fixtureHeartRates: [Int]
        if suppliedHeartRates.count >= fixtureMinimumSampleCount {
            fixtureHeartRates = suppliedHeartRates
        } else {
            // DEBUG compatibility only: older unit fixtures supplied three
            // untimestamped values. Expand those values across the requested
            // five-minute frame so the production kernel still enforces its
            // real sample-count/continuity contract. Six points are required
            // across 300 seconds when raw evidence may be at most 60 seconds
            // apart; the older five-point expansion created four 75-second gaps.
            fixtureHeartRates = (0..<fixtureMinimumSampleCount)
                .map { index in
                    let sourceIndex = min(
                        suppliedHeartRates.count - 1,
                        index * suppliedHeartRates.count
                            / fixtureMinimumSampleCount
                    )
                    return suppliedHeartRates[sourceIndex]
                }
        }
        let samples = fixtureHeartRates.enumerated().map {
            index, bpm in
            let denominator = max(1, fixtureHeartRates.count - 1)
            let offset = -AtriaPhysiologicalStressModel.windowDuration
                + Double(index) / Double(denominator)
                    * AtriaPhysiologicalStressModel.windowDuration
            return AtriaPhysiologicalStressModel.HeartRateSample(
                date: now.addingTimeInterval(offset),
                bpm: bpm
            )
        }
        var rrClock = now.addingTimeInterval(-AtriaPhysiologicalStressModel.windowDuration)
        let rrSamples = rrWindowMs.map { milliseconds -> AtriaPhysiologicalStressModel.RRSample in
            rrClock = rrClock.addingTimeInterval(Double(milliseconds) / 1_000)
            return .init(date: rrClock,
                         milliseconds: Double(milliseconds),
                         qualified: true)
        }
        let qualifiedLnRMSSD = baseline.freshSamples(now: now)
            .filter(\.isOvernightSample)
            .compactMap(\.lnRMSSD)
        let personalization = AtriaPhysiologicalStressModel.Personalization(
            restingHeartRate: baseline.restingHR ?? Double(restingMaxHR.rest),
            maximumHeartRate: Double(restingMaxHR.max),
            restingBaselineDayCount: baseline.freshRestingSampleCount(now: now),
            hrvBaseline: AtriaPhysiologicalStressModel.robustHRVBaseline(
                lnRMSSDValues: qualifiedLnRMSSD,
                qualifiedDayCount: baseline.freshHRVSampleCount(now: now)
            )
        )
        let motion: AtriaPhysiologicalStressModel.MotionContext = workoutActive
            ? .qualifiedActivity(intensity: 0.7)
            : .unavailable
        _ = zoneIndex
        _ = hrvFallbackRMSSD
        _ = awakeReference
        guard let fact = AtriaPhysiologicalStressModel.evaluate(
            .init(end: now,
                  heartRates: samples,
                  rrIntervals: rrSamples,
                  personalization: personalization,
                  motionContext: motion,
                  sleepContext: inSleepWindow ? .asleep : .unavailable)
        ) else {
            return .noSignal
        }
        let level: AtriaStressLevel
        switch fact.zone {
        case .calm: level = .calm
        case .moderate: level = .medium
        case .high: level = .high
        }
        let detail = fact.isHROnly
            ? "HR-only estimate · lower confidence"
            : "Physiological stress · HR + HRV"
        return AtriaStressState(
            level: level,
            label: fact.zone.rawValue,
            detail: detail,
            kind: .scored,
            confidence: fact.confidence.numericValue,
            rawActivation: fact.score / 3,
            hrvAvailable: !fact.isHROnly,
            minuteFact: fact
        )
    }
    #endif

    /// Band index for a 0...1 activation using the static thresholds above.
    static func band(_ activation: Double) -> Int {
        if activation < calmUpperBound { return 0 }
        if activation < mediumUpperBound { return 2 }
        return 3
    }

    /// Distance-to-nearest-boundary helper used by the store's hysteresis.
    static func distanceToNearestBoundary(_ activation: Double) -> Double {
        [calmUpperBound, mediumUpperBound]
            .map { abs($0 - activation) }
            .min() ?? calmUpperBound
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

    /// V3 is isolated from v2 categorical/calibration aggregates. Older keys
    /// are intentionally ignored rather than relabelled or mixed.
    static let defaultsKey = "atria.stress.distribution.v3"
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

/// Acquisition authority for an exact minute fact. A genuine live fact is
/// immutable against later recovered replay. Replay facts may be enriched by a
/// later independently-qualified context publication when cardiac evidence does
/// not regress. Missing provenance in an early v3 file resolves to live—the
/// conservative choice for already-recorded user data.
enum AtriaStressHistoryFactSource: String, Codable, Equatable, Sendable {
    case live
    case historicalReplay
}

/// Reproducible authority carried only by recovered replay facts. Cardiac input,
/// calibration, and confirmed context are versioned independently so a newer
/// context publication can remove or resize an overlay without treating a
/// confidence increase as permission to rewrite unrelated HR/RR evidence.
struct AtriaStressReplayAuthority: Codable, Equatable, Sendable {
    let cardiacInputRevision: String
    let calibrationRevision: String
    let contextRevision: String

    fileprivate var isStructurallyValid: Bool {
        Self.isRevision(cardiacInputRevision)
            && Self.isRevision(calibrationRevision)
            && Self.isRevision(contextRevision)
    }

    private static func isRevision(_ value: String) -> Bool {
        guard value.hasPrefix("v1:"), value.count == 19 else { return false }
        return value.dropFirst(3).allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character)
        }
    }
}

/// A compact, display-only checkpoint of real scored stress samples. This is
/// intentionally separate from the daily distribution and awake-HR baseline:
/// restoring it can repopulate a timeline after relaunch, but it never feeds
/// scoring, calibration, or aggregate insight math.
struct AtriaStressHistoryArchive: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        let t: Date
        let activation: Double
        let levelRawValue: Int
        let confidence: Double
        let hrvAvailable: Bool
        let scoringVersion: Int
        let minuteFact: AtriaPhysiologicalStressModel.MinuteFact?
        /// Optional only for decode compatibility with an early v3 archive.
        let factSource: AtriaStressHistoryFactSource?
        /// Optional for decode compatibility with replay points written before
        /// source/calibration/context authority became independently versioned.
        let replayAuthority: AtriaStressReplayAuthority?

        init(t: Date,
             activation: Double,
             level: AtriaStressLevel,
             confidence: Double,
             hrvAvailable: Bool,
             minuteFact: AtriaPhysiologicalStressModel.MinuteFact? = nil,
             factSource: AtriaStressHistoryFactSource = .live,
             replayAuthority: AtriaStressReplayAuthority? = nil,
             scoringVersion: Int = AtriaStressMonitor.scoringVersion) {
            self.t = t
            self.activation = activation
            self.levelRawValue = level.rawValue
            self.confidence = confidence
            self.hrvAvailable = hrvAvailable
            self.minuteFact = minuteFact
            self.factSource = factSource
            self.replayAuthority = replayAuthority
            self.scoringVersion = scoringVersion
        }

        var level: AtriaStressLevel? { AtriaStressLevel(rawValue: levelRawValue) }
        var resolvedFactSource: AtriaStressHistoryFactSource {
            factSource ?? .live
        }

        fileprivate var isValid: Bool {
            guard let minuteFact else { return false }
            let expectedLevelRawValue: Int
            switch minuteFact.zone {
            case .calm: expectedLevelRawValue = AtriaStressLevel.calm.rawValue
            case .moderate: expectedLevelRawValue = AtriaStressLevel.medium.rawValue
            case .high: expectedLevelRawValue = AtriaStressLevel.high.rawValue
            }
            return t.timeIntervalSinceReferenceDate.isFinite
                && minuteFact.isStructurallyValid
                && activation.isFinite
                && (0...1).contains(activation)
                && levelRawValue == expectedLevelRawValue
                && confidence.isFinite
                && (0...1).contains(confidence)
                && hrvAvailable == !minuteFact.isHROnly
                && abs(activation - minuteFact.score / 3) <= 1e-9
                && abs(confidence - minuteFact.confidence.numericValue) <= 1e-9
                && scoringVersion == AtriaStressMonitor.scoringVersion
                && minuteFact.date == t
                && minuteFact.scoringVersion == scoringVersion
                && (replayAuthority?.isStructurallyValid ?? true)
                && (resolvedFactSource == .historicalReplay
                    || replayAuthority == nil)
        }

        private enum CodingKeys: String, CodingKey {
            case t
            case activation = "a"
            case levelRawValue = "l"
            case confidence = "c"
            case hrvAvailable = "h"
            case scoringVersion = "s"
            case minuteFact = "f"
            case factSource = "o"
            case replayAuthority = "r"
        }
    }

    static let currentSchemaVersion = 3
    /// Two local days lets Activity restore today or yesterday without growing
    /// into long-term health storage. At the store's one-minute cadence this is
    /// bounded exactly by `maximumPointCount`.
    static let retentionWindow: TimeInterval = 48 * 60 * 60
    static let maximumPointCount = 2_880
    /// Local sample clocks should track wall time. A larger future jump signals
    /// a corrupt archive or clock discontinuity and is rejected rather than
    /// displayed as measured evidence.
    static let maximumFutureSkew: TimeInterval = 5 * 60

    let schemaVersion: Int
    private(set) var points: [Point]

    init(points: [Point] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.points = points
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "v"
        case points = "p"
    }

    /// Validates every persisted claim, rejects future-clock corruption, then
    /// prunes by exact sample timestamp. Sorting and exact timestamp de-duping
    /// preserve real gaps; no samples are synthesized between observations.
    func validatedAndPruned(now: Date) throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion,
              now.timeIntervalSinceReferenceDate.isFinite,
              points.allSatisfy(\.isValid),
              points.allSatisfy({ $0.t.timeIntervalSince(now) <= Self.maximumFutureSkew }) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let cutoff = now.addingTimeInterval(-Self.retentionWindow)
        let retained = points
            .filter { $0.t >= cutoff }
            .sorted { $0.t < $1.t }
        var unique: [Point] = []
        unique.reserveCapacity(min(retained.count, Self.maximumPointCount))
        for point in retained {
            if unique.last?.t == point.t {
                // A complete later record wins an exact-timestamp collision;
                // it never bridges a missing time range.
                unique[unique.count - 1] = point
            } else {
                unique.append(point)
            }
        }
        if unique.count > Self.maximumPointCount {
            unique.removeFirst(unique.count - Self.maximumPointCount)
        }
        return Self(points: unique)
    }
}

enum AtriaStressHistoryLoadState: Equatable, Sendable {
    /// Persistence is intentionally absent (the default for isolated stores and
    /// tests); only the app-wide production store opts in.
    case disabled
    case loading
    case loaded
    /// The archive existed but could not be read, decoded, or validated. UI can
    /// distinguish this from a successfully loaded archive with zero readings.
    case unavailable
}

/// Serial, protected Application Support persistence for the bounded archive.
/// Reads and JSON encoding/writes stay off MainActor. Hour shards bound routine
/// rewrite amplification: a live checkpoint atomically replaces only the
/// current and immediately previous hour (the latter closes rollover tails),
/// while load merges/prunes at most 48 hours of small files.
final class AtriaStressHistoryPersistence: @unchecked Sendable {
    enum LoadResult: Equatable, Sendable {
        case loaded(AtriaStressHistoryArchive)
        case unavailable
    }

    private struct Shard: Codable, Equatable, Sendable {
        static let schemaVersion = 3
        let version: Int
        let hour: Int64
        let points: [AtriaStressHistoryArchive.Point]

        init(hour: Int64, points: [AtriaStressHistoryArchive.Point]) {
            self.version = Self.schemaVersion
            self.hour = hour
            self.points = points
        }

        private enum CodingKeys: String, CodingKey {
            case version = "v"
            case hour = "b"
            case points = "p"
        }
    }

    /// One point per minute plus four slots for boundary/clock jitter.
    static let maximumPointsPerShard = 64
    /// Measured worst-field 128-point JSON is ~11 KB. A 16 KiB hard ceiling
    /// bounds both corruption exposure and write amplification to <=9 MiB/day
    /// at two shards per five-minute checkpoint (normally substantially less).
    static let maximumEncodedBytesPerShard = 64 * 1_024
    private static let secondsPerShard: TimeInterval = 60 * 60
    private static let maximumRelevantShardCount = 50
    static let filenamePrefix = "stress-minute-v3-"
    private static let filenameSuffix = ".json"
    static let productionDirectoryName = "Atria/stress-history-v3"
    private let directoryURL: URL
    private let fileManager: FileManager
    private let ioQueue = DispatchQueue(label: "com.adidshaft.atria.stress-history",
                                        qos: .utility)
    /// Utility-queue confined. A successful recovery checkpoint must clear all
    /// previously recognized shards before the store can leave `unavailable`.
    private var recoveryRebuildRequired = false

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    static func production(fileManager: FileManager = .default) -> AtriaStressHistoryPersistence {
        let support = fileManager.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask)[0]
        return AtriaStressHistoryPersistence(
            directoryURL: support.appendingPathComponent(productionDirectoryName,
                                                          isDirectory: true),
            fileManager: fileManager
        )
    }

    func load(now: Date = Date()) async -> LoadResult {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                continuation.resume(returning: loadSynchronously(now: now))
            }
        }
    }

    /// Fire-and-forget from the live store. Calls are already sample-throttled;
    /// this serial queue additionally guarantees checkpoint ordering. Success
    /// means every targeted shard reached a protected, synchronized atomic
    /// replacement; callers must not advance durability state before it.
    func enqueueCheckpoint(_ archive: AtriaStressHistoryArchive,
                           now: Date,
                           completion: @escaping @Sendable (Bool) -> Void) {
        ioQueue.async { [self] in
            do {
                try checkpointSynchronously(archive, now: now)
                completion(true)
            } catch {
                AtriaDebugLog("ATRIADBG stress_history_checkpoint status=failed error=%@",
                              String(describing: error))
                completion(false)
            }
        }
    }

    /// Test/support seam for pre-seeding a complete 48-hour relaunch fixture.
    /// Production routine checkpoints use `enqueueCheckpoint` and therefore
    /// rewrite only two hour shards.
    func save(_ archive: AtriaStressHistoryArchive, now: Date = Date()) async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    try saveAllSynchronously(archive, now: now)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Completes all checkpoints submitted before this call.
    func drainWrites() async {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume() }
        }
    }

    /// Exact test seam for constructing a corrupt hour file. Production callers
    /// do not need filesystem paths.
    func shardURL(containing date: Date) -> URL {
        shardURL(hour: Self.hourIndex(for: date))
    }

    private func loadSynchronously(now: Date) -> LoadResult {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return .loaded(AtriaStressHistoryArchive())
        }
        do {
            let files = try recognizedShardFiles()
            let oldestHour = Self.hourIndex(
                for: now.addingTimeInterval(-AtriaStressHistoryArchive.retentionWindow)
            )
            let latestAllowedHour = Self.hourIndex(
                for: now.addingTimeInterval(AtriaStressHistoryArchive.maximumFutureSkew)
            )
            let relevant = files.filter { $0.hour >= oldestHour }
            guard relevant.count <= Self.maximumRelevantShardCount,
                  relevant.allSatisfy({ $0.hour <= latestAllowedHour }) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            var points: [AtriaStressHistoryArchive.Point] = []
            points.reserveCapacity(relevant.count * 120)
            for file in relevant.sorted(by: { $0.hour < $1.hour }) {
                let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                guard data.count <= Self.maximumEncodedBytesPerShard else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let shard = try JSONDecoder().decode(Shard.self, from: data)
                guard shard.version == Shard.schemaVersion,
                      shard.hour == file.hour,
                      shard.points.count <= Self.maximumPointsPerShard,
                      shard.points.allSatisfy({ Self.hourIndex(for: $0.t) == shard.hour }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                points.append(contentsOf: shard.points)
            }
            let archive = try AtriaStressHistoryArchive(points: points)
                .validatedAndPruned(now: now)
            pruneExpiredShards(files, oldestHour: oldestHour)
            return .loaded(archive)
        } catch {
            recoveryRebuildRequired = true
            return .unavailable
        }
    }

    private func checkpointSynchronously(_ archive: AtriaStressHistoryArchive,
                                         now: Date) throws {
        let validated = try archive.validatedAndPruned(now: now)
        try prepareDirectory()
        guard let newestSubmittedPoint = validated.points.last else {
            if recoveryRebuildRequired {
                try clearRecognizedShards(excluding: [])
                recoveryRebuildRequired = false
            }
            return
        }
        let anchorHour = Self.hourIndex(for: newestSubmittedPoint.t)
        let targets = [anchorHour - 1, anchorHour]
        let grouped = Dictionary(grouping: validated.points,
                                 by: { Self.hourIndex(for: $0.t) })
        for hour in targets {
            let points = Array((grouped[hour] ?? []).suffix(Self.maximumPointsPerShard))
            if points.isEmpty {
                // An old current/previous shard with no corresponding point in
                // the canonical in-memory snapshot would otherwise resurrect.
                try removeShardIfPresent(hour: hour)
            } else {
                try writeShard(Shard(hour: hour, points: points))
            }
        }
        if recoveryRebuildRequired {
            // Target shards are now complete and durable. Clear every older
            // recognized shard (valid or corrupt) before reporting recovery;
            // otherwise a stale corrupt hour would poison the next launch.
            try clearRecognizedShards(excluding: Set(targets))
            recoveryRebuildRequired = false
        }
        let oldestHour = Self.hourIndex(
            for: now.addingTimeInterval(-AtriaStressHistoryArchive.retentionWindow)
        )
        pruneExpiredShards(try recognizedShardFiles(), oldestHour: oldestHour)
    }

    private func saveAllSynchronously(_ archive: AtriaStressHistoryArchive,
                                      now: Date) throws {
        let validated = try archive.validatedAndPruned(now: now)
        try prepareDirectory()
        let grouped = Dictionary(grouping: validated.points,
                                 by: { Self.hourIndex(for: $0.t) })
        for (hour, rawPoints) in grouped {
            let points = Array(rawPoints.suffix(Self.maximumPointsPerShard))
            try writeShard(Shard(hour: hour, points: points))
        }
        let retainedHours = Set(grouped.keys)
        for file in try recognizedShardFiles() where !retainedHours.contains(file.hour) {
            try fileManager.removeItem(at: file.url)
        }
        try synchronizeDirectory()
        recoveryRebuildRequired = false
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
    }

    private func writeShard(_ shard: Shard) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(shard)
        guard data.count <= Self.maximumEncodedBytesPerShard else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let destination = shardURL(hour: shard.hour)
        let temporary = directoryURL.appendingPathComponent(
            ".stress-hour-\(shard.hour)-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary,
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        // POSIX rename within one directory atomically replaces an existing
        // shard. On failure the old destination is unchanged and still valid.
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw Self.posixError()
        }
        try synchronizeDirectory()
    }

    private func removeShardIfPresent(hour: Int64) throws {
        let url = shardURL(hour: hour)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
        try synchronizeDirectory()
    }

    private func recognizedShardFiles() throws -> [(hour: Int64, url: URL)] {
        try fileManager.contentsOfDirectory(at: directoryURL,
                                            includingPropertiesForKeys: nil,
                                            options: [.skipsHiddenFiles])
            .compactMap { url in
                guard let hour = Self.hour(fromFilename: url.lastPathComponent) else {
                    return nil
                }
                return (hour: hour, url: url)
            }
    }

    private func pruneExpiredShards(_ files: [(hour: Int64, url: URL)],
                                    oldestHour: Int64) {
        var removed = false
        for file in files where file.hour < oldestHour {
            if (try? fileManager.removeItem(at: file.url)) != nil {
                removed = true
            }
        }
        if removed { try? synchronizeDirectory() }
    }

    private func clearRecognizedShards(excluding retainedHours: Set<Int64>) throws {
        var removed = false
        for file in try recognizedShardFiles() where !retainedHours.contains(file.hour) {
            try fileManager.removeItem(at: file.url)
            removed = true
        }
        if removed { try synchronizeDirectory() }
    }

    private func shardURL(hour: Int64) -> URL {
        directoryURL.appendingPathComponent(
            "\(Self.filenamePrefix)\(hour)\(Self.filenameSuffix)"
        )
    }

    private static func hourIndex(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / secondsPerShard))
    }

    private static func hour(fromFilename filename: String) -> Int64? {
        guard filename.hasPrefix(filenamePrefix), filename.hasSuffix(filenameSuffix) else {
            return nil
        }
        let start = filename.index(filename.startIndex, offsetBy: filenamePrefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -filenameSuffix.count)
        return Int64(filename[start..<end])
    }

    private func synchronizeDirectory() throws {
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw Self.posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
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

/// Immutable, bounded input copied from SessionStore only after its recovered
/// publication fence completes. The copy is deliberately scalar/Sendable so
/// five-minute framing, RR qualification, and v3 scoring never run on
/// MainActor or retain a mutable SessionStore graph.
enum AtriaHistoricalStressReplay {
    static let maximumSessionCount = 512
    static let maximumHeartRateRowCount = 250_000
    static let maximumRRRowCount = 250_000
    static let maximumContextSourceCount = 2_048
    static let maximumContextIntervalCount = 20_000
    static let maximumManagedRangeCount = 8

    /// Swift's `Hasher` is intentionally process-randomized. Replay authority
    /// survives relaunch, so use a tiny deterministic FNV-1a builder over only
    /// bounded scalar inputs instead of persisting a process-local hash value.
    private struct StableRevisionBuilder {
        private var value: UInt64 = 14_695_981_039_346_656_037

        mutating func combine(_ byte: UInt8) {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }

        mutating func combine(_ scalar: UInt64) {
            var remaining = scalar
            for _ in 0..<8 {
                combine(UInt8(truncatingIfNeeded: remaining))
                remaining >>= 8
            }
        }

        mutating func combine(_ scalar: Int) {
            combine(UInt64(bitPattern: Int64(scalar)))
        }

        mutating func combine(_ scalar: Double) {
            combine(scalar.bitPattern)
        }

        mutating func combine(_ date: Date) {
            combine(date.timeIntervalSinceReferenceDate)
        }

        mutating func combine(_ flag: Bool) {
            combine(flag ? UInt8(1) : UInt8(0))
        }

        mutating func combine(_ string: String) {
            combine(string.utf8.count)
            for byte in string.utf8 { combine(byte) }
        }

        var revision: String {
            let hex = String(value, radix: 16)
            return "v1:" + String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        }
    }

    struct HeartRateRow: Equatable, Sendable {
        let date: Date
        let bpm: Int
    }

    struct RRRow: Equatable, Sendable {
        let date: Date
        let milliseconds: Int
        let source: AtriaRRSourceProvenance?
    }

    struct Session: Equatable, Sendable {
        let id: UUID
        let start: Date
        let end: Date
        let heartRates: [HeartRateRow]
        let rrIntervals: [RRRow]
    }

    struct ActivityContextInterval: Equatable, Sendable {
        let start: Date
        let end: Date
        let intensity: Double
        let qualified: Bool

        init(start: Date,
             end: Date,
             intensity: Double,
             qualified: Bool = true) {
            self.start = start
            self.end = end
            self.intensity = intensity.isFinite ? min(max(intensity, 0), 1) : 0
            self.qualified = qualified
        }
    }

    struct SleepContextInterval: Equatable, Sendable {
        let start: Date
        let end: Date
        let qualified: Bool

        init(start: Date, end: Date, qualified: Bool = true) {
            self.start = start
            self.end = end
            self.qualified = qualified
        }
    }

    struct Snapshot: Equatable, Sendable {
        let sessions: [Session]
        let activityContexts: [ActivityContextInterval]
        let sleepContexts: [SleepContextInterval]
        let personalization: AtriaPhysiologicalStressModel.Personalization
        let now: Date

        init(sessions: [Session],
             activityContexts: [ActivityContextInterval] = [],
             sleepContexts: [SleepContextInterval] = [],
             personalization: AtriaPhysiologicalStressModel.Personalization,
             now: Date) {
            self.sessions = sessions
            self.activityContexts = activityContexts
            self.sleepContexts = sleepContexts
            self.personalization = personalization
            self.now = now
        }

        var heartRateRowCount: Int {
            var total = 0
            for session in sessions {
                guard session.heartRates.count
                        <= AtriaHistoricalStressReplay.maximumHeartRateRowCount - total else {
                    return AtriaHistoricalStressReplay.maximumHeartRateRowCount + 1
                }
                total += session.heartRates.count
            }
            return total
        }

        var rrRowCount: Int {
            var total = 0
            for session in sessions {
                guard session.rrIntervals.count
                        <= AtriaHistoricalStressReplay.maximumRRRowCount - total else {
                    return AtriaHistoricalStressReplay.maximumRRRowCount + 1
                }
                total += session.rrIntervals.count
            }
            return total
        }
    }

    /// A bounded COW snapshot of SessionStore-owned value storage. Copying this
    /// on MainActor retains the arrays' immutable backing storage; it does not
    /// materialize hundreds of thousands of scalar HR/RR rows. `SavedSession`
    /// and the confirmed-record types predate Sendable annotations, so this
    /// wrapper is the single audited transfer boundary. Mutation of SessionStore
    /// values triggers Array copy-on-write and cannot alter this captured value.
    struct StorageSnapshot: @unchecked Sendable {
        let sessions: [SavedSession]
        let confirmedWorkouts: [UserConfirmedWorkout]
        let confirmedSleeps: [UserConfirmedSleep]
        let personalization: AtriaPhysiologicalStressModel.Personalization
        let now: Date
    }

    struct HeartRatePoint: Equatable, Sendable {
        let date: Date
        let bpm: Int
    }

    /// A full replay owns replay-origin points only inside these bounded clock
    /// ranges. Candidate absence inside a managed range is authoritative (a
    /// session was deleted/shrunk or a telemetry gap appeared), while genuine
    /// live acquisition remains immutable. An empty range set preserves the
    /// additive legacy/test ingestion contract and can never erase history.
    struct ManagedRange: Equatable, Sendable {
        let start: Date
        let end: Date

        init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }

        fileprivate var isStructurallyValid: Bool {
            start.timeIntervalSinceReferenceDate.isFinite
                && end.timeIntervalSinceReferenceDate.isFinite
                && end >= start
        }

        fileprivate func contains(_ date: Date) -> Bool {
            date >= start && date <= end
        }
    }

    struct Result: Equatable, Sendable {
        let facts: [AtriaPhysiologicalStressModel.MinuteFact]
        let heartRates: [HeartRatePoint]
        /// Per-minute replay authority. Direct legacy/test ingestion may omit
        /// it and receives the conservative monotonic merge contract.
        let authorityByDate: [Date: AtriaStressReplayAuthority]
        /// Non-empty only for a successfully validated full-source replay.
        /// Failures/cancellation use `.empty` with no destructive authority.
        let managedRanges: [ManagedRange]

        init(facts: [AtriaPhysiologicalStressModel.MinuteFact],
             heartRates: [HeartRatePoint],
             authorityByDate: [Date: AtriaStressReplayAuthority] = [:],
             managedRanges: [ManagedRange] = []) {
            self.facts = facts
            self.heartRates = heartRates
            self.authorityByDate = authorityByDate
            self.managedRanges = managedRanges
        }

        static let empty = Result(facts: [],
                                  heartRates: [],
                                  authorityByDate: [:],
                                  managedRanges: [])
    }

    private static func calibrationRevision(
        _ personalization: AtriaPhysiologicalStressModel.Personalization
    ) -> String {
        var builder = StableRevisionBuilder()
        builder.combine("atria-stress-calibration-v1")
        builder.combine(personalization.restingHeartRate)
        builder.combine(personalization.maximumHeartRate)
        builder.combine(personalization.restingBaselineDayCount)
        if let baseline = personalization.hrvBaseline {
            builder.combine(true)
            builder.combine(baseline.medianLnRMSSD)
            builder.combine(baseline.robustScale)
            builder.combine(baseline.qualifiedDayCount)
        } else {
            builder.combine(false)
        }
        return builder.revision
    }

    private static func contextRevision(
        activity: [ActivityContextInterval],
        sleep: [SleepContextInterval]
    ) -> String {
        var builder = StableRevisionBuilder()
        builder.combine("atria-stress-context-v1")
        builder.combine(activity.count)
        for interval in activity {
            builder.combine(interval.start)
            builder.combine(interval.end)
            builder.combine(interval.intensity)
            builder.combine(interval.qualified)
        }
        builder.combine(sleep.count)
        for interval in sleep {
            builder.combine(interval.start)
            builder.combine(interval.end)
            builder.combine(interval.qualified)
        }
        return builder.revision
    }

    private static func cardiacInputRevision(
        heartRates: [AtriaPhysiologicalStressModel.HeartRateSample],
        rrIntervals: [AtriaPhysiologicalStressModel.RRSample],
        previousRevision: String?
    ) -> String {
        var builder = StableRevisionBuilder()
        builder.combine("atria-stress-cardiac-input-v1")
        if let previousRevision {
            builder.combine(true)
            builder.combine(previousRevision)
        } else {
            builder.combine(false)
        }
        builder.combine(heartRates.count)
        for sample in heartRates {
            builder.combine(sample.date)
            builder.combine(sample.bpm)
            builder.combine(sample.qualified)
        }
        builder.combine(rrIntervals.count)
        for sample in rrIntervals {
            builder.combine(sample.date)
            builder.combine(sample.milliseconds)
            builder.combine(sample.qualified)
        }
        return builder.revision
    }

    /// Cheap bounds seam used before allocating scalar row copies. A source
    /// that exceeds any cap fails closed instead of turning a recovery publish
    /// into unbounded foreground work.
    static func isWithinSnapshotBounds(sessionCount: Int,
                                       heartRateRowCount: Int,
                                       rrRowCount: Int) -> Bool {
        sessionCount >= 0 && sessionCount <= maximumSessionCount
            && heartRateRowCount >= 0
            && heartRateRowCount <= maximumHeartRateRowCount
            && rrRowCount >= 0
            && rrRowCount <= maximumRRRowCount
    }

    /// MainActor retains only bounded COW value-storage references and performs
    /// O(session/context count) bounds checks. It never walks or materializes the
    /// high-frequency HR/RR rows. Scalar detachment, context qualification,
    /// chronological normalization, window framing, and scoring all run in the
    /// detached `evaluate(_:)` worker.
    @MainActor
    static func snapshot(sessions: [SavedSession],
                         confirmedWorkouts: [UserConfirmedWorkout] = [],
                         confirmedSleeps: [UserConfirmedSleep] = [],
                         personalization: AtriaPhysiologicalStressModel.Personalization,
                         now: Date) -> StorageSnapshot? {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let sourceCutoff = now.addingTimeInterval(
            -AtriaStressHistoryArchive.retentionWindow
                - AtriaPhysiologicalStressModel.windowDuration
        )
        let futureLimit = now.addingTimeInterval(
            AtriaStressHistoryArchive.maximumFutureSkew
        )
        var recentSessions: [SavedSession] = []
        recentSessions.reserveCapacity(min(sessions.count, maximumSessionCount))
        var heartRateCount = 0
        var rrCount = 0
        var recoveredMotionEpochCount = 0
        for session in sessions {
            guard session.start.timeIntervalSinceReferenceDate.isFinite,
                  session.end.timeIntervalSinceReferenceDate.isFinite,
                  session.end >= sourceCutoff,
                  session.start <= futureLimit else { continue }
            guard recentSessions.count < maximumSessionCount,
                  session.points.count <= maximumHeartRateRowCount - heartRateCount,
                  (session.rrPoints?.count ?? 0) <= maximumRRRowCount - rrCount,
                  (session.recoveredMotionEpochs?.count ?? 0)
                    <= maximumContextIntervalCount - recoveredMotionEpochCount else {
                return nil
            }
            recentSessions.append(session)
            heartRateCount += session.points.count
            rrCount += session.rrPoints?.count ?? 0
            recoveredMotionEpochCount += session.recoveredMotionEpochs?.count ?? 0
        }
        var recentWorkouts: [UserConfirmedWorkout] = []
        recentWorkouts.reserveCapacity(min(confirmedWorkouts.count,
                                           maximumContextSourceCount))
        for workout in confirmedWorkouts where workout.end >= sourceCutoff
            && workout.start <= futureLimit {
            guard recentWorkouts.count < maximumContextSourceCount else { return nil }
            recentWorkouts.append(workout)
        }
        var recentSleeps: [UserConfirmedSleep] = []
        recentSleeps.reserveCapacity(min(confirmedSleeps.count,
                                         maximumContextSourceCount))
        for sleep in confirmedSleeps where sleep.end >= sourceCutoff
            && sleep.start <= futureLimit {
            guard recentSleeps.count < maximumContextSourceCount else { return nil }
            recentSleeps.append(sleep)
        }
        guard isWithinSnapshotBounds(sessionCount: recentSessions.count,
                                     heartRateRowCount: heartRateCount,
                                     rrRowCount: rrCount) else { return nil }
        return StorageSnapshot(sessions: recentSessions,
                               confirmedWorkouts: recentWorkouts,
                               confirmedSleeps: recentSleeps,
                               personalization: personalization,
                               now: now)
    }

    /// Performs the capped high-frequency copy off MainActor. Every context is
    /// admitted through an independent recovered-motion or explicit-confirmation
    /// gate; ambiguous hints remain unavailable and cannot attenuate a score.
    static func materialize(_ source: StorageSnapshot) -> Snapshot? {
        guard !Task.isCancelled,
              source.now.timeIntervalSinceReferenceDate.isFinite,
              source.sessions.count <= maximumSessionCount,
              source.confirmedWorkouts.count <= maximumContextSourceCount,
              source.confirmedSleeps.count <= maximumContextSourceCount else {
            return nil
        }
        let sourceCutoff = source.now.addingTimeInterval(
            -AtriaStressHistoryArchive.retentionWindow
                - AtriaPhysiologicalStressModel.windowDuration
        )
        let futureLimit = source.now.addingTimeInterval(
            AtriaStressHistoryArchive.maximumFutureSkew
        )
        var copied: [Session] = []
        copied.reserveCapacity(source.sessions.count)
        var activityContexts: [ActivityContextInterval] = []
        var heartRateCount = 0
        var rrCount = 0

        for session in source.sessions {
            guard !Task.isCancelled else { return nil }
            var heartRates: [HeartRateRow] = []
            var rrIntervals: [RRRow] = []
            heartRates.reserveCapacity(session.points.count)
            rrIntervals.reserveCapacity(session.rrPoints?.count ?? 0)
            for point in session.points {
                let date = session.start.addingTimeInterval(point.t)
                guard date.timeIntervalSinceReferenceDate.isFinite,
                      date >= sourceCutoff,
                      date <= futureLimit else { continue }
                guard heartRateCount < maximumHeartRateRowCount else { return nil }
                heartRateCount += 1
                heartRates.append(HeartRateRow(date: date, bpm: point.bpm))
            }
            for point in session.rrPoints ?? [] {
                let date = session.start.addingTimeInterval(point.t)
                guard date.timeIntervalSinceReferenceDate.isFinite,
                      date >= sourceCutoff,
                      date <= futureLimit else { continue }
                guard rrCount < maximumRRRowCount else { return nil }
                rrCount += 1
                rrIntervals.append(RRRow(date: date,
                                         milliseconds: point.ms,
                                         source: point.source))
            }
            for epoch in session.recoveredMotionEpochs ?? [] {
                guard epoch.measurementValidated,
                      !epoch.lowMotionQualified,
                      let intensity = epoch.movementIntensity,
                      intensity.isFinite,
                      (0...1).contains(intensity),
                      epoch.start.timeIntervalSinceReferenceDate.isFinite,
                      epoch.end.timeIntervalSinceReferenceDate.isFinite,
                      epoch.end > epoch.start,
                      epoch.end >= sourceCutoff,
                      epoch.start <= futureLimit else { continue }
                let independentMovement = epoch.stillnessRatio.flatMap { stillness
                    -> Double? in
                    guard stillness.isFinite, (0...1).contains(stillness) else {
                        return nil
                    }
                    return 1 - stillness
                }
                guard intensity >= 0.08 || (independentMovement ?? 0) >= 0.35 else {
                    // A measurement-valid epoch that is merely not qualified as
                    // sleep-still is not automatically activity authority.
                    continue
                }
                guard activityContexts.count < maximumContextIntervalCount else {
                    return nil
                }
                activityContexts.append(
                    ActivityContextInterval(start: max(epoch.start, sourceCutoff),
                                            end: min(epoch.end, futureLimit),
                                            intensity: max(intensity,
                                                           independentMovement ?? 0))
                )
            }
            copied.append(Session(id: session.id,
                                  start: session.start,
                                  end: session.end,
                                  heartRates: heartRates,
                                  rrIntervals: rrIntervals))
        }

        for workout in source.confirmedWorkouts {
            guard let contexts = qualifiedActivityContexts(
                for: workout,
                sourceCutoff: sourceCutoff,
                futureLimit: futureLimit
            ) else { continue }
            guard contexts.count <= maximumContextIntervalCount - activityContexts.count else {
                return nil
            }
            activityContexts.append(contentsOf: contexts)
        }
        var sleepContexts: [SleepContextInterval] = []
        sleepContexts.reserveCapacity(source.confirmedSleeps.count)
        for sleep in source.confirmedSleeps {
            guard isQualifiedHistoricalSleep(sleep),
                  sleep.start.timeIntervalSinceReferenceDate.isFinite,
                  sleep.end.timeIntervalSinceReferenceDate.isFinite,
                  sleep.end > sleep.start,
                  sleep.end >= sourceCutoff,
                  sleep.start <= futureLimit else { continue }
            guard sleepContexts.count < maximumContextIntervalCount else { return nil }
            sleepContexts.append(
                SleepContextInterval(start: max(sleep.start, sourceCutoff),
                                     end: min(sleep.end, futureLimit))
            )
        }

        activityContexts.sort {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        sleepContexts.sort {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        return Snapshot(sessions: copied,
                        activityContexts: activityContexts,
                        sleepContexts: sleepContexts,
                        personalization: source.personalization,
                        now: source.now)
    }

    static func evaluate(_ source: StorageSnapshot) -> Result {
        guard let snapshot = materialize(source) else { return .empty }
        return evaluate(snapshot)
    }

    /// Frames exact overlapping five-minute windows at one-minute boundaries
    /// and calls the same pure v3 kernel used by live scoring. The two sliding
    /// ranges make framing O(rows + minute windows), with at most five copies of
    /// a regular one-minute-cadence source row. A missing minute explicitly
    /// clears the EMA seed, so replay never bridges telemetry gaps.
    static func evaluate(_ snapshot: Snapshot) -> Result {
        guard !Task.isCancelled,
              snapshot.now.timeIntervalSinceReferenceDate.isFinite,
              isWithinSnapshotBounds(sessionCount: snapshot.sessions.count,
                                     heartRateRowCount: snapshot.heartRateRowCount,
                                     rrRowCount: snapshot.rrRowCount),
              snapshot.activityContexts.count <= maximumContextIntervalCount,
              snapshot.sleepContexts.count <= maximumContextIntervalCount,
              isChronological(snapshot.activityContexts, date: { $0.start }),
              isChronological(snapshot.sleepContexts, date: { $0.start }),
              snapshot.activityContexts.allSatisfy({
                  $0.start.timeIntervalSinceReferenceDate.isFinite
                    && $0.end.timeIntervalSinceReferenceDate.isFinite
                    && $0.end > $0.start
                    && $0.intensity.isFinite
                    && (0...1).contains($0.intensity)
              }),
              snapshot.sleepContexts.allSatisfy({
                  $0.start.timeIntervalSinceReferenceDate.isFinite
                    && $0.end.timeIntervalSinceReferenceDate.isFinite
                    && $0.end > $0.start
              }) else {
            return .empty
        }

        guard let orderedSessions = chronologicallyOrderedSessions(snapshot.sessions) else {
            return .empty
        }
        let managedRanges = [ManagedRange(
            start: snapshot.now.addingTimeInterval(
                -AtriaStressHistoryArchive.retentionWindow
            ),
            end: snapshot.now
        )]
        var heartRates: [HeartRateRow] = []
        heartRates.reserveCapacity(snapshot.heartRateRowCount)
        var taggedRR: [(sessionID: UUID, row: RRRow)] = []
        taggedRR.reserveCapacity(snapshot.rrRowCount)

        for session in orderedSessions {
            guard !Task.isCancelled else { return .empty }
            guard isChronological(session.heartRates, date: { $0.date }),
                  isChronological(session.rrIntervals, date: { $0.date }) else {
                // Managed-range absence is destructive authority. A malformed
                // session is therefore a replay failure, never evidence that
                // its previously verified minutes disappeared.
                return .empty
            }
            for row in session.heartRates {
                if let prior = heartRates.last {
                    if row.date < prior.date { continue }
                    if row.date == prior.date {
                        heartRates[heartRates.count - 1] = row
                        continue
                    }
                }
                heartRates.append(row)
            }
            for row in session.rrIntervals {
                if let prior = taggedRR.last {
                    if row.date < prior.row.date { continue }
                    if row.date == prior.row.date {
                        taggedRR[taggedRR.count - 1] = (session.id, row)
                        continue
                    }
                }
                taggedRR.append((session.id, row))
            }
        }

        guard let firstHeartRateDate = heartRates.first?.date,
              let lastHeartRateDate = heartRates.last?.date else {
            // A successfully validated empty full-source snapshot is
            // authoritative absence, not a replay failure. Its managed range
            // removes obsolete replay-owned points while preserving live facts.
            return Result(facts: [],
                          heartRates: [],
                          authorityByDate: [:],
                          managedRanges: managedRanges)
        }
        let retainedStart = snapshot.now.addingTimeInterval(
            -AtriaStressHistoryArchive.retentionWindow
        )
        let firstEnd = minuteCeiling(max(retainedStart, firstHeartRateDate))
        let lastEnd = minuteFloor(min(snapshot.now, lastHeartRateDate))
        guard firstEnd <= lastEnd else {
            return Result(facts: [],
                          heartRates: [],
                          authorityByDate: [:],
                          managedRanges: managedRanges)
        }

        var facts: [AtriaPhysiologicalStressModel.MinuteFact] = []
        facts.reserveCapacity(min(AtriaStressHistoryArchive.maximumPointCount,
                                  Int((lastEnd.timeIntervalSince(firstEnd) / 60) + 1)))
        var sampledHeartRates: [HeartRatePoint] = []
        sampledHeartRates.reserveCapacity(facts.capacity)
        var authorityByDate: [Date: AtriaStressReplayAuthority] = [:]
        authorityByDate.reserveCapacity(facts.capacity)
        let calibrationRevision = calibrationRevision(snapshot.personalization)
        let contextRevision = contextRevision(activity: snapshot.activityContexts,
                                              sleep: snapshot.sleepContexts)
        var previousFact: AtriaPhysiologicalStressModel.MinuteFact?
        var previousCardiacInputRevision: String?
        var heartRateLower = 0
        var heartRateUpper = 0
        var rrLower = 0
        var rrUpper = 0
        var activityContextLower = 0
        var sleepContextLower = 0
        var end = firstEnd

        while end <= lastEnd {
            guard !Task.isCancelled else { return .empty }
            let start = end.addingTimeInterval(
                -AtriaPhysiologicalStressModel.windowDuration
            )
            while heartRateUpper < heartRates.count,
                  heartRates[heartRateUpper].date <= end {
                heartRateUpper += 1
            }
            while heartRateLower < heartRateUpper,
                  heartRates[heartRateLower].date < start {
                heartRateLower += 1
            }
            while rrUpper < taggedRR.count,
                  taggedRR[rrUpper].row.date <= end {
                rrUpper += 1
            }
            while rrLower < rrUpper,
                  taggedRR[rrLower].row.date < start {
                rrLower += 1
            }

            let heartRateWindow = heartRates[heartRateLower..<heartRateUpper].map {
                AtriaPhysiologicalStressModel.HeartRateSample(
                    date: $0.date,
                    bpm: $0.bpm,
                    qualified: (30...240).contains($0.bpm)
                )
            }
            let rrWindow = Array(taggedRR[rrLower..<rrUpper])
            let qualifiedRR = qualifiedRRSamples(
                rrWindow,
                heartRates: heartRateWindow,
                start: start,
                end: end
            )
            let cardiacInputRevision = cardiacInputRevision(
                heartRates: heartRateWindow,
                rrIntervals: qualifiedRR,
                previousRevision: previousCardiacInputRevision
            )
            var motionContext = qualifiedMotionContext(
                snapshot.activityContexts,
                lowerIndex: &activityContextLower,
                windowStart: start,
                windowEnd: end
            )
            let sleepContext = qualifiedSleepContext(
                snapshot.sleepContexts,
                lowerIndex: &sleepContextLower,
                windowStart: start,
                windowEnd: end
            )
            if sleepContext == .asleep {
                // Conflicting activity/sleep records must never compound into a
                // stronger adjustment. Preserve the qualified sleep overlay and
                // fail motion attenuation closed for that window.
                motionContext = .unavailable
            }
            let input = AtriaPhysiologicalStressModel.WindowInput(
                end: end,
                heartRates: heartRateWindow,
                rrIntervals: qualifiedRR,
                personalization: snapshot.personalization,
                motionContext: motionContext,
                sleepContext: sleepContext
            )
            if let fact = AtriaPhysiologicalStressModel.evaluate(
                input,
                previous: previousFact
            ) {
                facts.append(fact)
                previousFact = fact
                previousCardiacInputRevision = cardiacInputRevision
                authorityByDate[fact.date] = AtriaStressReplayAuthority(
                    cardiacInputRevision: cardiacInputRevision,
                    calibrationRevision: calibrationRevision,
                    contextRevision: contextRevision
                )
                if let latest = heartRateWindow.last(where: { $0.qualified }),
                   latest.date >= retainedStart {
                    sampledHeartRates.append(
                        HeartRatePoint(date: latest.date, bpm: latest.bpm)
                    )
                }
            } else {
                previousFact = nil
                previousCardiacInputRevision = nil
            }
            end = end.addingTimeInterval(
                AtriaPhysiologicalStressModel.evaluationCadence
            )
        }

        return Result(facts: facts,
                      heartRates: sampledHeartRates,
                      authorityByDate: authorityByDate,
                      managedRanges: managedRanges)
    }

    private static func qualifiedRRSamples(
        _ tagged: [(sessionID: UUID, row: RRRow)],
        heartRates: [AtriaPhysiologicalStressModel.HeartRateSample],
        start: Date,
        end: Date
    ) -> [AtriaPhysiologicalStressModel.RRSample] {
        guard let sessionID = tagged.first?.sessionID,
              tagged.allSatisfy({ $0.sessionID == sessionID }) else {
            // Never concatenate a tachogram across a saved/reconnect boundary.
            return []
        }
        let source = tagged.map {
            AtriaBreathworkSession.RRSample(date: $0.row.date,
                                            ms: $0.row.milliseconds,
                                            source: $0.row.source)
        }
        let aligned = AtriaStressMonitorStore.timeAlignedRRIntervals(
            source,
            heartRates: heartRates.map { (t: $0.date, bpm: $0.bpm) },
            start: start,
            end: end
        )
        let (quality, corrected) = HRVAnalyzer.analyze(
            aligned,
            now: end,
            includeTachogram: true,
            provenance: .localRRWindow
        )
        // This existing gate accepts only standard 2A37 provenance. Verified
        // historical v24, mixed, and legacy nil RR therefore remain HR-only.
        guard quality?.isLiveStressEligible(on: end, maximumAge: 60) == true else {
            return []
        }
        return corrected.map {
            AtriaPhysiologicalStressModel.RRSample(
                date: $0.t,
                milliseconds: $0.ms,
                qualified: $0.corrected && !$0.interpolated
            )
        }
    }

    /// A confirmed record is independent activity authority only when the user
    /// explicitly confirmed it, or when its bounded recovered-gravity receipt is
    /// ready with qualified coverage. Detector labels and HR elevation alone do
    /// not become motion evidence.
    private static func qualifiedActivityContexts(
        for workout: UserConfirmedWorkout,
        sourceCutoff: Date,
        futureLimit: Date
    ) -> [ActivityContextInterval]? {
        guard workout.start.timeIntervalSinceReferenceDate.isFinite,
              workout.end.timeIntervalSinceReferenceDate.isFinite,
              workout.end > workout.start,
              workout.end >= sourceCutoff,
              workout.start <= futureLimit else { return nil }
        let userConfirmed = workout.confidence
            .localizedCaseInsensitiveContains("user_confirmed")
        let recoveredMotion = workout.activityCalibrationEvidence.flatMap { evidence
            -> Double? in
            guard evidence.status == "ready",
                  evidence.motion.provenance == AtriaRecoveredMotionEpoch.source,
                  evidence.motion.validatedCoverageFraction >= 0.80,
                  let intensity = evidence.motion.meanMovementIntensity,
                  intensity.isFinite,
                  (0...1).contains(intensity),
                  intensity >= 0.08 else { return nil }
            return min(max(intensity, 0.35), 1)
        }
        guard userConfirmed || recoveredMotion != nil else { return nil }
        let intensity = recoveredMotion ?? 0.65
        let start = max(workout.start, sourceCutoff)
        let end = min(workout.end, futureLimit)
        guard end > start else { return nil }

        var segments: [(start: Date, end: Date)] = [(start, end)]
        let exclusions = (workout.excludedIntervals ?? [])
            .filter {
                $0.start.timeIntervalSinceReferenceDate.isFinite
                    && $0.end.timeIntervalSinceReferenceDate.isFinite
                    && $0.end > $0.start
            }
            .sorted { $0.start < $1.start }
        for exclusion in exclusions {
            var next: [(start: Date, end: Date)] = []
            next.reserveCapacity(segments.count + 1)
            for segment in segments {
                guard exclusion.end > segment.start,
                      exclusion.start < segment.end else {
                    next.append(segment)
                    continue
                }
                if exclusion.start > segment.start {
                    next.append((segment.start, min(exclusion.start, segment.end)))
                }
                if exclusion.end < segment.end {
                    next.append((max(exclusion.end, segment.start), segment.end))
                }
            }
            segments = next
            if segments.isEmpty { break }
        }
        return segments.compactMap { segment in
            guard segment.end > segment.start else { return nil }
            return ActivityContextInterval(start: segment.start,
                                           end: segment.end,
                                           intensity: intensity)
        }
    }

    /// Sleep requires the same durable main-sleep and independent qualification
    /// gate as live scoring. A low-HR or clock-only inferred sleep never becomes
    /// a historical overlay or modifier.
    static func isQualifiedHistoricalSleep(_ sleep: UserConfirmedSleep) -> Bool {
        guard SessionStore.confirmedSleepIsPhysiologicalMainSleep(sleep) else {
            return false
        }
        let userQualified = sleep.source.hasPrefix("manual_")
            || sleep.source.hasPrefix("user_adjusted_")
            || sleep.confidence.hasPrefix("user_confirmed_")
        return sleep.motionValidated || userQualified
    }

    /// Requires at least 80% independently qualified context coverage across the
    /// exact five-minute score window. This prevents a one-beat or one-epoch hint
    /// from relabelling and attenuating the full fact.
    private static func qualifiedMotionContext(
        _ contexts: [ActivityContextInterval],
        lowerIndex: inout Int,
        windowStart: Date,
        windowEnd: Date
    ) -> AtriaPhysiologicalStressModel.MotionContext {
        while lowerIndex < contexts.count,
              contexts[lowerIndex].end <= windowStart {
            lowerIndex += 1
        }
        var cursor = windowStart
        var covered: TimeInterval = 0
        var weightedIntensity = 0.0
        var index = lowerIndex
        while index < contexts.count, contexts[index].start < windowEnd {
            let context = contexts[index]
            if context.qualified {
                let lower = max(max(windowStart, context.start), cursor)
                let upper = min(windowEnd, context.end)
                if upper > lower {
                    let duration = upper.timeIntervalSince(lower)
                    covered += duration
                    weightedIntensity += duration * context.intensity
                    cursor = max(cursor, upper)
                }
            }
            index += 1
        }
        let required = 0.80 * windowEnd.timeIntervalSince(windowStart)
        guard covered >= required, covered > 0 else { return .unavailable }
        return .qualifiedActivity(intensity: weightedIntensity / covered)
    }

    private static func qualifiedSleepContext(
        _ contexts: [SleepContextInterval],
        lowerIndex: inout Int,
        windowStart: Date,
        windowEnd: Date
    ) -> AtriaPhysiologicalStressModel.SleepContext {
        while lowerIndex < contexts.count,
              contexts[lowerIndex].end <= windowStart {
            lowerIndex += 1
        }
        var cursor = windowStart
        var covered: TimeInterval = 0
        var index = lowerIndex
        while index < contexts.count, contexts[index].start < windowEnd {
            let context = contexts[index]
            if context.qualified {
                let lower = max(max(windowStart, context.start), cursor)
                let upper = min(windowEnd, context.end)
                if upper > lower {
                    covered += upper.timeIntervalSince(lower)
                    cursor = max(cursor, upper)
                }
            }
            index += 1
        }
        let required = 0.80 * windowEnd.timeIntervalSince(windowStart)
        return covered >= required ? .asleep : .unavailable
    }

    private static func isChronological<Value>(
        _ values: [Value],
        date: (Value) -> Date
    ) -> Bool {
        var previous: Date?
        for value in values {
            let current = date(value)
            guard current.timeIntervalSinceReferenceDate.isFinite,
                  previous.map({ current >= $0 }) ?? true else { return false }
            previous = current
        }
        return true
    }

    /// SessionStore publishes one monotonic session order (newest-first in the
    /// normal cache). Accept either monotonic direction and reverse when needed;
    /// a mixed/corrupt order fails closed instead of paying for an O(n log n)
    /// reorder that could hide overlapping provenance.
    private static func chronologicallyOrderedSessions(
        _ sessions: [Session]
    ) -> [Session]? {
        var direction = 0 // 1 ascending, -1 descending
        var previous: Date?
        for session in sessions {
            guard session.start.timeIntervalSinceReferenceDate.isFinite,
                  session.end.timeIntervalSinceReferenceDate.isFinite else {
                return nil
            }
            if let previous, session.start != previous {
                let nextDirection = session.start > previous ? 1 : -1
                if direction != 0, direction != nextDirection { return nil }
                direction = nextDirection
            }
            previous = session.start
        }
        return direction == -1 ? Array(sessions.reversed()) : sessions
    }

    private static func minuteFloor(_ date: Date) -> Date {
        Date(timeIntervalSince1970:
            floor(date.timeIntervalSince1970
                  / AtriaPhysiologicalStressModel.evaluationCadence)
                * AtriaPhysiologicalStressModel.evaluationCadence)
    }

    private static func minuteCeiling(_ date: Date) -> Date {
        Date(timeIntervalSince1970:
            ceil(date.timeIntervalSince1970
                 / AtriaPhysiologicalStressModel.evaluationCadence)
                * AtriaPhysiologicalStressModel.evaluationCadence)
    }
}

/// Monotonic coalescing authority for recovered-history notifications. Tests
/// can deterministically prove that a rapid second publication invalidates the
/// first worker before either result reaches the archive merge.
struct AtriaHistoricalStressReplayGenerationGate: Equatable, Sendable {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        if current == 0 { current = 1 }
        return current
    }

    func accepts(_ generation: UInt64) -> Bool {
        generation != 0 && generation == current
    }
}

/// O(1) identity of every personalization scalar consumed by the v3 kernel.
/// Constructing it is bounded by PersonalBaseline's 90-day cap and happens only
/// when baseline/profile authority publishes—not on the live HR hot loop. Home
/// retains only this fixed-size value, so equality and replay dedup are O(1).
struct AtriaHistoricalStressCalibrationFingerprint: Equatable, Sendable {
    let restingHeartRate: Double
    let maximumHeartRate: Double
    let restingBaselineDayCount: Int
    let medianLnRMSSD: Double?
    let robustScale: Double?
    let qualifiedHRVDayCount: Int?

    init(_ personalization: AtriaPhysiologicalStressModel.Personalization) {
        restingHeartRate = personalization.restingHeartRate
        maximumHeartRate = personalization.maximumHeartRate
        restingBaselineDayCount = personalization.restingBaselineDayCount
        medianLnRMSSD = personalization.hrvBaseline?.medianLnRMSSD
        robustScale = personalization.hrvBaseline?.robustScale
        qualifiedHRVDayCount = personalization.hrvBaseline?.qualifiedDayCount
    }
}

/// Seeds from Home's initial settled publication, then accepts only a changed
/// complete calibration. Recovered/restore fences may expose provisional
/// baseline values while independent profile or fallback-rest changes survive a
/// rollback. Those observations stay typed as pending until SessionStore emits
/// an exact terminal edge and Home supplies the final post-fence fingerprint.
struct AtriaHistoricalStressCalibrationPublicationGate: Equatable, Sendable {
    private var current: AtriaHistoricalStressCalibrationFingerprint?
    private var pendingDeferred: AtriaHistoricalStressCalibrationFingerprint?
    private var pendingSourceReplayRequired = false

    mutating func accepts(
        _ fingerprint: AtriaHistoricalStressCalibrationFingerprint,
        publicationDeferred: Bool
    ) -> Bool {
        if publicationDeferred
            || pendingDeferred != nil
            || pendingSourceReplayRequired {
            pendingDeferred = fingerprint
            return false
        }
        return settle(fingerprint)
    }

    /// Records a terminal publication without consuming provisional state.
    /// Recovery and backup restore own independent fences, so the first edge
    /// may arrive while the other transaction is still exposing provisional
    /// authority. A successful source publication is retained as one bit until
    /// the final fence releases; calibration-only failure edges do not invent a
    /// replay. Home must call `releaseDeferred(final:)` only when this returns
    /// true, which also keeps the pre-bounded personalization projection off
    /// intermediate terminal edges.
    mutating func recordTerminal(
        sourceReplayRequired: Bool,
        publicationDeferred: Bool
    ) -> Bool {
        pendingSourceReplayRequired = pendingSourceReplayRequired
            || sourceReplayRequired
        guard !publicationDeferred else { return false }
        return pendingDeferred != nil || pendingSourceReplayRequired
    }

    /// Releases exactly one deferred transaction against its authoritative
    /// post-fence state. A rollback callback may arrive after SessionStore has
    /// cleared its active ticket; because `pendingDeferred` remains set, that
    /// callback updates only pending state and can never leak a provisional
    /// replay before this terminal comparison.
    mutating func releaseDeferred(
        final fingerprint: AtriaHistoricalStressCalibrationFingerprint
    ) -> Bool {
        guard pendingDeferred != nil || pendingSourceReplayRequired else {
            return false
        }
        let sourceReplayRequired = pendingSourceReplayRequired
        pendingDeferred = nil
        pendingSourceReplayRequired = false
        return settle(fingerprint) || sourceReplayRequired
    }

    private mutating func settle(
        _ fingerprint: AtriaHistoricalStressCalibrationFingerprint
    ) -> Bool {
        guard fingerprint != current else { return false }
        let hadCurrent = current != nil
        current = fingerprint
        return hadCurrent
    }
}

/// Exact fact-revision accounting shared by bounded live checkpoints and full
/// recovered-history saves. Completion order is deliberately irrelevant: a
/// successful writer clears a timestamp only when the currently dirty mutation
/// revision exactly matches the revision captured in that writer's submission.
/// Replacing a fact at the same minute while I/O is in flight therefore cannot
/// be falsely declared durable by the older completion.
struct AtriaStressHistoryDurabilityLedger: Equatable, Sendable {
    struct Submission: Equatable, Sendable {
        fileprivate let revisions: [Date: UInt64]
        var count: Int { revisions.count }
    }

    private var nextRevision: UInt64 = 0
    private var dirtyRevisions: [Date: UInt64] = [:]

    var dirtyCount: Int { dirtyRevisions.count }
    var isEmpty: Bool { dirtyRevisions.isEmpty }

    mutating func markDirty(_ date: Date) {
        nextRevision &+= 1
        if nextRevision == 0 { nextRevision = 1 }
        dirtyRevisions[date] = nextRevision
    }

    mutating func markDirty<S: Sequence>(_ dates: S) where S.Element == Date {
        for date in dates { markDirty(date) }
    }

    func isDirty(_ date: Date) -> Bool {
        dirtyRevisions[date] != nil
    }

    mutating func retainOnly<S: Sequence>(_ retainedDates: S)
        where S.Element == Date {
        let retained = Set(retainedDates)
        dirtyRevisions = dirtyRevisions.filter { retained.contains($0.key) }
    }

    func submission<S: Sequence>(for dates: S) -> Submission
        where S.Element == Date {
        var revisions: [Date: UInt64] = [:]
        for date in dates {
            if let revision = dirtyRevisions[date] {
                revisions[date] = revision
            }
        }
        return Submission(revisions: revisions)
    }

    @discardableResult
    mutating func complete(_ submission: Submission, succeeded: Bool) -> Int {
        guard succeeded else { return 0 }
        var cleared = 0
        for (date, submittedRevision) in submission.revisions
        where dirtyRevisions[date] == submittedRevision {
            dirtyRevisions.removeValue(forKey: date)
            cleared += 1
        }
        return cleared
    }
}

/// Thin store that frames qualified live samples into overlapping five-minute
/// windows on a one-minute cadence. Both this live path and historical replay
/// call `AtriaPhysiologicalStressModel.evaluate`; this class remains I/O-shaped
/// plumbing and bounded persistence only.
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
    /// Scored readings emitted once per minute and bounded to 48 hours / 2,880
    /// points. The production store restores a local display-only checkpoint;
    /// isolated stores remain memory-only unless persistence is injected. Real
    /// sample timestamps survive relaunch, so missing strap intervals remain
    /// gaps and are never interpolated.
    private(set) var history: [StressHistoryPoint] = []
    /// Real timestamped HR observations sampled at minute evaluation. Kept
    /// separate from the five-minute mean stored inside each stress fact.
    private(set) var heartRateHistory: [HeartRateHistoryPoint] = []
    /// Cheap change token for SwiftUI observers. The Health screen reads
    /// `history` for data, but watches this integer so live updates never
    /// compare the full rolling array.
    @Published private(set) var historyRevision = 0
    /// Explicit restore authority. `loaded` with an empty `history` means there
    /// truly are no retained readings; `loading` / `unavailable` must not be
    /// presented as the same empty-data claim.
    @Published private(set) var historyLoadState: AtriaStressHistoryLoadState = .disabled
    /// Persisted, measured physiological-stress band counts. Complete v3
    /// HR-only facts participate with their explicit low-confidence provenance;
    /// this remains a compact aggregate rather than a second sample archive.
    private var distributionArchive: AtriaStressDistributionArchive
    @Published private(set) var distributionRevision = 0

    struct StressHistoryPoint: Identifiable, Equatable, Sendable {
        let t: Date
        /// Continuous activation 0-1 behind the discrete level.
        let activation: Double
        let level: AtriaStressLevel
        /// Confidence published with this exact derived sample.
        let confidence: Double
        /// Provenance: true for HR+HRV corroboration, false for HR-only.
        let hrvAvailable: Bool
        /// Scorer/banding/hysteresis contract that produced this point.
        let scoringVersion: Int
        /// Versioned minute fact shared by the live and historical paths.
        let minuteFact: AtriaPhysiologicalStressModel.MinuteFact?
        /// Exact-timestamp collision authority. Live acquisition is immutable;
        /// replay may only replace replay under the non-regression rule below.
        let factSource: AtriaStressHistoryFactSource
        /// Present only for revision-aware recovered replay. Live acquisition
        /// never carries replay authority.
        let replayAuthority: AtriaStressReplayAuthority?

        init(t: Date,
             activation: Double,
             level: AtriaStressLevel,
             confidence: Double = 0,
             hrvAvailable: Bool = false,
             minuteFact: AtriaPhysiologicalStressModel.MinuteFact? = nil,
             factSource: AtriaStressHistoryFactSource = .live,
             replayAuthority: AtriaStressReplayAuthority? = nil,
             scoringVersion: Int = AtriaStressMonitor.scoringVersion) {
            self.t = t
            self.activation = activation
            self.level = level
            self.confidence = confidence
            self.hrvAvailable = hrvAvailable
            self.minuteFact = minuteFact
            self.factSource = factSource
            self.replayAuthority = replayAuthority
            self.scoringVersion = scoringVersion
        }

        var id: TimeInterval { t.timeIntervalSinceReferenceDate }

        var evidenceMode: AtriaStressEvidenceMode {
            if minuteFact?.scoringVersion == AtriaPhysiologicalStressModel.scoringVersion {
                return .physiologicalStress
            }
            return hrvAvailable ? .physiologicalStress : .cardiacArousal
        }

        var evidenceProjection: AtriaStressEvidenceProjection {
            AtriaStressEvidenceProjection(activation: activation,
                                          mode: evidenceMode)
        }
    }

    struct HeartRateHistoryPoint: Identifiable, Equatable, Sendable {
        let t: Date
        let bpm: Int
        /// Exact-clock acquisition authority mirrors minute facts so a full
        /// replay may remove obsolete recovered HR without erasing live HR.
        let factSource: AtriaStressHistoryFactSource

        init(t: Date,
             bpm: Int,
             factSource: AtriaStressHistoryFactSource = .live) {
            self.t = t
            self.bpm = bpm
            self.factSource = factSource
        }

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
    private let historyPersistence: AtriaStressHistoryPersistence?
    private var historyHydrationWaiters: [CheckedContinuation<Void, Never>] = []
    private var historyCheckpointWaiters: [CheckedContinuation<Void, Never>] = []
    /// Advances only after the background writer confirms a synchronized atomic
    /// replacement. A queued or failed write is never called durable.
    private var historyHasDurableCheckpoint = false
    private var historyDurabilityLedger = AtriaStressHistoryDurabilityLedger()
    private var unsavedHistorySamples: Int {
        historyDurabilityLedger.dirtyCount
    }
    private var historyCheckpointInFlight = false
    private var historyCheckpointRetryPending = false
    private var historyForcedFlushPending = false
    /// Number of samples from the checkpoint trigger that still need a
    /// confirmed shard replacement. A trigger may span disconnected hours;
    /// draining those hours serially keeps each write bounded to two shards
    /// without calling an omitted older island durable.
    private var historyCheckpointDrainRemainingSamples = 0
    private var lastHistoryCheckpointAttemptAt: Date?
    /// Five one-minute facts trigger at most one routine checkpoint every five
    /// minutes. The first retained sample is checkpointed immediately so a
    /// short session can still restore something after a relaunch.
    nonisolated private static let historyPersistEverySamples = 5
    nonisolated private static let historyCheckpointMinimumInterval: TimeInterval = 5 * 60

    init(defaults: UserDefaults = .standard,
         historyPersistence: AtriaStressHistoryPersistence? = nil,
         historyLoadNow: Date = Date()) {
        self.awakeReferenceDefaults = defaults
        self.distributionArchive = AtriaStressDistributionArchive.load(defaults: defaults)
        self.persistedAwakeReference = Self.loadPersistedAwakeReference(defaults: defaults)
        self.awakeBaselineArchive = AtriaAwakeBaselineArchive.load(defaults: defaults)
        self.historyPersistence = historyPersistence
        self.historyLoadState = historyPersistence == nil ? .disabled : .loading

        if let historyPersistence {
            Task { [weak self] in
                let result = await historyPersistence.load(now: historyLoadNow)
                guard let self else { return }
                self.completeHistoryHydration(result, now: historyLoadNow)
            }
        }
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

    private var previousMinuteFact: AtriaPhysiologicalStressModel.MinuteFact?
    private var lastEvaluatedMinute: Date?
    private var unsavedDistributionSamples = 0
    private var historicalReplayGeneration = 0

    // Minute scoring floors `now`; one cadence of headroom prevents a :59 tick
    // from pruning the first minute of the window being evaluated.
    private static let hrWindowSeconds = AtriaPhysiologicalStressModel.windowDuration
        + AtriaPhysiologicalStressModel.evaluationCadence
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

    /// Correlates each RR interval only with a heart-rate observation measured
    /// near that exact beat. This preserves the existing HR/RR mismatch gate
    /// without assigning the latest HR to an older five-minute tachogram.
    /// Inputs are expected in capture order and fail closed if either clock
    /// moves backwards. The two advancing indices keep the pass O(n).
    nonisolated static func timeAlignedRRIntervals(
        _ samples: [AtriaBreathworkSession.RRSample],
        heartRates: [(t: Date, bpm: Int)],
        start: Date,
        end: Date,
        maximumHeartRateMatchAge: TimeInterval = 5
    ) -> [RRInterval] {
        guard end >= start,
              maximumHeartRateMatchAge.isFinite,
              maximumHeartRateMatchAge >= 0 else { return [] }

        var previousHeartRateDate: Date?
        for sample in heartRates {
            if let previousHeartRateDate, sample.t < previousHeartRateDate {
                return []
            }
            previousHeartRateDate = sample.t
        }
        var previousRRDate: Date?
        for sample in samples {
            if let previousRRDate, sample.date < previousRRDate { return [] }
            previousRRDate = sample.date
        }

        var output: [RRInterval] = []
        output.reserveCapacity(samples.count)
        var heartRateIndex = 0

        for sample in samples where sample.date >= start && sample.date <= end {
            while heartRateIndex + 1 < heartRates.count,
                  heartRates[heartRateIndex + 1].t <= sample.date {
                heartRateIndex += 1
            }

            var nearest: (age: TimeInterval, bpm: Int)?
            if heartRates.indices.contains(heartRateIndex) {
                let candidate = heartRates[heartRateIndex]
                if (30...240).contains(candidate.bpm) {
                    nearest = (abs(candidate.t.timeIntervalSince(sample.date)),
                               candidate.bpm)
                }
            }
            let nextIndex = heartRateIndex + 1
            if heartRates.indices.contains(nextIndex) {
                let candidate = heartRates[nextIndex]
                let age = abs(candidate.t.timeIntervalSince(sample.date))
                if (30...240).contains(candidate.bpm),
                   nearest.map({ age < $0.age }) ?? true {
                    nearest = (age, candidate.bpm)
                }
            }
            let expectedHR = nearest.flatMap {
                $0.age <= maximumHeartRateMatchAge ? $0.bpm : nil
            }
            output.append(RRInterval(t: sample.date,
                                     ms: Double(sample.ms),
                                     expectedHR: expectedHR,
                                     source: sample.source))
        }
        return output
    }

    /// Only an explicit, durable main-sleep interval with independent
    /// qualification can mark a live minute asleep. Ordinary inferred or
    /// already-ended sleep history does not become present-tense evidence.
    nonisolated static func hasQualifiedActiveSleepEvidence(
        in sleeps: [UserConfirmedSleep],
        at now: Date
    ) -> Bool {
        sleeps.contains { sleep in
            guard sleep.start <= now,
                  now < sleep.end else {
                return false
            }
            return AtriaHistoricalStressReplay.isQualifiedHistoricalSleep(sleep)
        }
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

    /// Deterministic seam for tests and consumers that must await the initial
    /// local restore before deciding whether a timeline is genuinely empty.
    func waitForHistoryHydration() async {
        guard historyLoadState == .loading else { return }
        await withCheckedContinuation { continuation in
            historyHydrationWaiters.append(continuation)
        }
    }

    /// Deterministic test/support seam; ordinary UI never awaits persistence.
    func waitForPendingHistoryCheckpoint() async {
        guard historyCheckpointInFlight else { return }
        await withCheckedContinuation { continuation in
            historyCheckpointWaiters.append(continuation)
        }
    }

    private func completeHistoryHydration(_ result: AtriaStressHistoryPersistence.LoadResult,
                                          now: Date) {
        switch result {
        case .loaded(let archive):
            let restored = archive.points.compactMap { point -> StressHistoryPoint? in
                guard let level = point.level else { return nil }
                return StressHistoryPoint(t: point.t,
                                          activation: point.activation,
                                          level: level,
                                          confidence: point.confidence,
                                          hrvAvailable: point.hrvAvailable,
                                          minuteFact: point.minuteFact,
                                          factSource: point.resolvedFactSource,
                                          replayAuthority: point.replayAuthority,
                                          scoringVersion: point.scoringVersion)
            }
            let merged = Self.mergeHistory(restored: restored,
                                           live: history,
                                           now: now)
            if merged != history {
                history = merged
                historyRevision &+= 1
            }
            historyHasDurableCheckpoint = !archive.points.isEmpty
            historyLoadState = .loaded

        case .unavailable:
            // Keep any live tail recorded while the background load ran, but
            // never relabel a failed/corrupt restore as a true empty archive.
            history = Self.mergeHistory(restored: [], live: history, now: now)
            historyHasDurableCheckpoint = false
            historyLoadState = .unavailable
        }
        historyDurabilityLedger.retainOnly(history.lazy.map(\.t))

        let waiters = historyHydrationWaiters
        historyHydrationWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        if historyForcedFlushPending || Self.shouldPersistHistory(
            hasDurableCheckpoint: historyHasDurableCheckpoint,
            unsavedSampleCount: unsavedHistorySamples
        ) {
            let force = historyForcedFlushPending
            historyForcedFlushPending = false
            checkpointHistory(now: now, force: force)
        }
    }

    /// Timestamp-keyed union used only at restore. Persisted evidence is loaded
    /// first; a same-clock live point wins because it is the newer in-process
    /// publication. Sorting and de-duplicating exact clocks cannot bridge gaps.
    private static func mergeHistory(restored: [StressHistoryPoint],
                                     live: [StressHistoryPoint],
                                     now: Date) -> [StressHistoryPoint] {
        let cutoff = now.addingTimeInterval(-AtriaStressHistoryArchive.retentionWindow)
        var byTimestamp: [Date: StressHistoryPoint] = [:]
        byTimestamp.reserveCapacity(restored.count + live.count)
        for point in restored where point.t >= cutoff {
            byTimestamp[point.t] = point
        }
        for point in live where point.t >= cutoff {
            byTimestamp[point.t] = point
        }
        let ordered = byTimestamp.values.sorted { $0.t < $1.t }
        if ordered.count > AtriaStressHistoryArchive.maximumPointCount {
            return Array(ordered.suffix(AtriaStressHistoryArchive.maximumPointCount))
        }
        return ordered
    }

    /// Recovered replay has a different exact-clock contract from hydration.
    /// A genuine live acquisition is immutable. Replay-origin points carry
    /// independent cardiac-input, calibration, and confirmed-context revisions:
    /// current context may add, shrink, or remove overlays; current calibration
    /// may recompute derived terms against the same measured cardiac input; and
    /// a complete replay from the generation-gated current source snapshot may
    /// replace an older replay atomically when several authority axes change.
    private static func mergeHistoricalReplay(
        _ replay: [StressHistoryPoint],
        into existing: [StressHistoryPoint],
        managedRanges: [AtriaHistoricalStressReplay.ManagedRange],
        now: Date
    ) -> [StressHistoryPoint] {
        let cutoff = now.addingTimeInterval(-AtriaStressHistoryArchive.retentionWindow)
        let candidateDates = Set(replay.lazy.map(\.t))
        var byTimestamp: [Date: StressHistoryPoint] = [:]
        byTimestamp.reserveCapacity(existing.count + replay.count)
        for point in existing where point.t >= cutoff {
            let obsoleteManagedReplay = point.factSource == .historicalReplay
                && isManaged(point.t, by: managedRanges)
                && !candidateDates.contains(point.t)
            if !obsoleteManagedReplay { byTimestamp[point.t] = point }
        }
        for candidate in replay where candidate.t >= cutoff {
            guard let current = byTimestamp[candidate.t] else {
                byTimestamp[candidate.t] = candidate
                continue
            }
            if replayMayReplace(candidate, current: current) {
                byTimestamp[candidate.t] = candidate
            }
        }
        let ordered = byTimestamp.values.sorted { $0.t < $1.t }
        if ordered.count > AtriaStressHistoryArchive.maximumPointCount {
            return Array(ordered.suffix(AtriaStressHistoryArchive.maximumPointCount))
        }
        return ordered
    }

    private static func isManaged(
        _ date: Date,
        by ranges: [AtriaHistoricalStressReplay.ManagedRange]
    ) -> Bool {
        ranges.contains { $0.contains(date) }
    }

    private static func replayMayReplace(
        _ candidate: StressHistoryPoint,
        current: StressHistoryPoint
    ) -> Bool {
        guard candidate != current,
              candidate.factSource == .historicalReplay,
              current.factSource == .historicalReplay,
              candidate.scoringVersion == current.scoringVersion,
              let candidateFact = candidate.minuteFact,
              let currentFact = current.minuteFact,
              candidateFact.scoringVersion == currentFact.scoringVersion else {
            return false
        }

        if let candidateAuthority = candidate.replayAuthority {
            guard candidateAuthority.isStructurallyValid else { return false }
            if let currentAuthority = current.replayAuthority {
                let sameCardiacInput = candidateAuthority.cardiacInputRevision
                    == currentAuthority.cardiacInputRevision
                let sameCalibration = candidateAuthority.calibrationRevision
                    == currentAuthority.calibrationRevision
                let sameContext = candidateAuthority.contextRevision
                    == currentAuthority.contextRevision

                if sameCardiacInput {
                    if sameCalibration {
                        // Motion/sleep may change score and confidence, but the
                        // exact same cardiac input + calibration must reproduce
                        // every cardiac component. Confidence alone can never
                        // authorize an RMSSD/HRV-stress mutation.
                        guard cardiacComponentsAreEquivalent(currentFact,
                                                             candidateFact) else {
                            return false
                        }
                        return !sameContext
                    }
                    // A confirmed sleep may rebuild personalized RHR/HRV
                    // calibration. With the exact same cardiac source input,
                    // the current model is authoritative even when HR stress,
                    // weights, confidence, and the final score all change.
                    return cardiacMeasurementsAreEquivalent(currentFact,
                                                             candidateFact)
                }

                // A changed cardiac fingerprint is explicit authority for the
                // raw HR/RR source—not an inference from confidence. Home's
                // generation gate admits only the newest complete replay, so
                // accept its fact atomically even when calibration and context
                // changed in the same publication. Otherwise an RR upgrade plus
                // a sleep-baseline change (or a context delete plus one changed
                // HR row) would be rejected forever and could never converge.
                return true
            }

            // One-time migration from replay points written before independent
            // authority revisions existed. Preserve the measured cardiac
            // values, then adopt the current complete replay result so later
            // delete/shrink operations have a durable revision to compare.
            return cardiacMeasurementsAreEquivalent(currentFact, candidateFact)
        }

        // Never let a legacy/unversioned candidate erase authority already
        // established by a current replay.
        guard current.replayAuthority == nil,
              candidateFact.confidence.numericValue
                >= currentFact.confidence.numericValue,
              !(!currentFact.baselineLearning && candidateFact.baselineLearning),
              motionAuthorityDoesNotRegress(from: currentFact.motionContext,
                                            to: candidateFact.motionContext),
              sleepAuthorityDoesNotRegress(from: currentFact.sleepContext,
                                           to: candidateFact.sleepContext),
              cardiacAuthorityDoesNotRegress(from: currentFact,
                                             to: candidateFact) else {
            return false
        }
        return true
    }

    private static func cardiacMeasurementsAreEquivalent(
        _ current: AtriaPhysiologicalStressModel.MinuteFact,
        _ candidate: AtriaPhysiologicalStressModel.MinuteFact
    ) -> Bool {
        approximatelyEqual(current.meanHeartRate, candidate.meanHeartRate)
            && optionalApproximatelyEqual(current.rmssd, candidate.rmssd)
    }

    private static func cardiacComponentsAreEquivalent(
        _ current: AtriaPhysiologicalStressModel.MinuteFact,
        _ candidate: AtriaPhysiologicalStressModel.MinuteFact
    ) -> Bool {
        cardiacMeasurementsAreEquivalent(current, candidate)
            && approximatelyEqual(current.hrStress, candidate.hrStress)
            && optionalApproximatelyEqual(current.hrvStress,
                                          candidate.hrvStress)
            && approximatelyEqual(current.heartRateWeight,
                                  candidate.heartRateWeight)
            && current.baselineLearning == candidate.baselineLearning
    }

    private static func cardiacAuthorityDoesNotRegress(
        from current: AtriaPhysiologicalStressModel.MinuteFact,
        to candidate: AtriaPhysiologicalStressModel.MinuteFact
    ) -> Bool {
        guard approximatelyEqual(current.meanHeartRate, candidate.meanHeartRate),
              approximatelyEqual(current.hrStress, candidate.hrStress) else {
            return false
        }
        if current.isHROnly {
            // Qualified RR is an authority upgrade. Otherwise the HR-only
            // weighting must remain the same cardiac model input.
            return !candidate.isHROnly
                || approximatelyEqual(current.heartRateWeight,
                                      candidate.heartRateWeight)
        }
        guard !candidate.isHROnly,
              let currentRMSSD = current.rmssd,
              let candidateRMSSD = candidate.rmssd,
              let currentHRVStress = current.hrvStress,
              let candidateHRVStress = candidate.hrvStress else {
            return false
        }
        return approximatelyEqual(currentRMSSD, candidateRMSSD)
            && approximatelyEqual(currentHRVStress, candidateHRVStress)
            && approximatelyEqual(current.heartRateWeight,
                                  candidate.heartRateWeight)
    }

    private static func motionAuthorityDoesNotRegress(
        from current: AtriaPhysiologicalStressModel.MotionContext,
        to candidate: AtriaPhysiologicalStressModel.MotionContext
    ) -> Bool {
        guard current.qualified else { return true }
        guard candidate.qualified else { return false }
        if current.kind == .activity { return candidate.kind == .activity }
        if current.kind == .still { return candidate.kind == .still }
        return true
    }

    private static func sleepAuthorityDoesNotRegress(
        from current: AtriaPhysiologicalStressModel.SleepContext,
        to candidate: AtriaPhysiologicalStressModel.SleepContext
    ) -> Bool {
        switch current {
        case .unavailable:
            return true
        case .awake:
            return candidate == .awake
        case .asleep:
            return candidate == .asleep
        }
    }

    private static func approximatelyEqual(_ lhs: Double,
                                           _ rhs: Double,
                                           tolerance: Double = 1e-9) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func optionalApproximatelyEqual(_ lhs: Double?,
                                                   _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return approximatelyEqual(lhs, rhs)
        default:
            return false
        }
    }

    nonisolated static func shouldPersistHistory(hasDurableCheckpoint: Bool,
                                                 unsavedSampleCount: Int) -> Bool {
        guard unsavedSampleCount > 0 else { return false }
        return !hasDurableCheckpoint
            || unsavedSampleCount >= historyPersistEverySamples
    }

    /// Keeps dirty-suffix accounting inside the points that still exist after
    /// retention/count pruning. This matters after a prolonged write failure:
    /// expired unsaved samples cannot remain as phantom work that repeatedly
    /// selects the same surviving suffix.
    nonisolated static func boundedUnsavedHistorySampleCount(_ unsavedSampleCount: Int,
                                                             retainedPointCount: Int) -> Int {
        min(max(0, unsavedSampleCount), max(0, retainedPointCount))
    }

    /// Nonblocking lifecycle seam. It only schedules the small current/previous
    /// hour snapshot; JSON/file work remains on the persistence utility queue.
    func flushHistoryCheckpoint(now: Date = Date()) {
        checkpointHistory(now: now, force: true)
    }

    private func checkpointHistory(now: Date,
                                   force: Bool = false,
                                   continuingDrain: Bool = false) {
        guard let historyPersistence, !history.isEmpty else { return }
        guard historyLoadState != .loading else {
            if force { historyForcedFlushPending = true }
            return
        }
        guard !historyCheckpointInFlight else {
            if force { historyForcedFlushPending = true }
            return
        }
        guard unsavedHistorySamples > 0 else {
            historyCheckpointDrainRemainingSamples = 0
            return
        }
        if !force, !continuingDrain,
           let lastHistoryCheckpointAttemptAt,
           now.timeIntervalSince(lastHistoryCheckpointAttemptAt)
                < Self.historyCheckpointMinimumInterval {
            return
        }

        if !continuingDrain {
            // Freeze the amount this trigger promises to make durable. Samples
            // arriving while I/O is in flight may piggyback when they share a
            // targeted hour, but do not turn one checkpoint into an unbounded
            // foreground write loop.
            historyCheckpointDrainRemainingSamples = max(
                historyCheckpointDrainRemainingSamples,
                unsavedHistorySamples
            )
        }

        // Backfill can insert dirty facts before an already durable live tail, so
        // dirtiness is identity/revision based—not an assumed array suffix. Start
        // with the oldest dirty hour; adjacent hours share one bounded rewrite.
        let dirtyPoints = history.lazy.filter {
            self.historyDurabilityLedger.isDirty($0.t)
        }
        guard let firstUnsaved = dirtyPoints.first else {
            historyCheckpointDrainRemainingSamples = 0
            return
        }
        let oldestDirtyHour = Self.historyHourIndex(for: firstUnsaved.t)
        let nextDirtyHour = dirtyPoints
            .map { Self.historyHourIndex(for: $0.t) }
            .first { $0 != oldestDirtyHour }
        let anchorHour = nextDirtyHour == oldestDirtyHour + 1
            ? oldestDirtyHour + 1
            : oldestDirtyHour
        let previousHour = anchorHour - 1
        let isTargetHour: (Int64) -> Bool = {
            $0 == previousHour || $0 == anchorHour
        }
        let submission = historyDurabilityLedger.submission(
            for: history.lazy.filter {
                self.historyDurabilityLedger.isDirty($0.t)
                    && isTargetHour(Self.historyHourIndex(for: $0.t))
            }.map(\.t)
        )
        guard submission.count > 0 else { return }

        // Submit the complete canonical contents of both target hours, not just
        // their dirty suffix. This makes shard replacement preserve previously
        // durable readings in the same hour. Routine work remains <=256 points.
        let points = history.lazy.filter {
            isTargetHour(Self.historyHourIndex(for: $0.t))
        }.map {
            AtriaStressHistoryArchive.Point(t: $0.t,
                                            activation: $0.activation,
                                            level: $0.level,
                                            confidence: $0.confidence,
                                            hrvAvailable: $0.hrvAvailable,
                                            minuteFact: $0.minuteFact,
                                            factSource: $0.factSource,
                                            replayAuthority: $0.replayAuthority,
                                            scoringVersion: $0.scoringVersion)
        }
        guard !points.isEmpty else { return }

        let wasRetry = historyCheckpointRetryPending
        historyCheckpointInFlight = true
        lastHistoryCheckpointAttemptAt = now
        if wasRetry {
            AtriaDebugLog("ATRIADBG stress_history_checkpoint status=retry_queued")
        }
        historyPersistence.enqueueCheckpoint(
            AtriaStressHistoryArchive(points: Array(points)),
            now: now
        ) { [weak self] succeeded in
            Task { @MainActor [weak self] in
                self?.completeHistoryCheckpoint(succeeded: succeeded,
                                                submission: submission,
                                                wasRetry: wasRetry,
                                                now: now)
            }
        }
    }

    private func completeHistoryCheckpoint(succeeded: Bool,
                                           submission: AtriaStressHistoryDurabilityLedger.Submission,
                                           wasRetry: Bool,
                                           now: Date) {
        historyCheckpointInFlight = false
        if succeeded {
            historyHasDurableCheckpoint = true
            let clearedRevisionCount = historyDurabilityLedger.complete(
                submission,
                succeeded: true
            )
            historyCheckpointDrainRemainingSamples = max(
                0,
                historyCheckpointDrainRemainingSamples - clearedRevisionCount
            )
            historyCheckpointRetryPending = false
            if historyLoadState == .unavailable {
                // The corrupt/unreadable archive has now been replaced by a
                // confirmed valid checkpoint. The retained live tail is the
                // honest available history from this point forward.
                historyLoadState = .loaded
            }
            if wasRetry {
                AtriaDebugLog("ATRIADBG stress_history_checkpoint status=retry_recovered")
            }
        } else {
            // Keep the unsaved count intact. The next ordinary attempt is still
            // rate-limited by the five-minute floor; backgrounding can force a
            // single earlier retry without turning failure into a write loop.
            historyCheckpointRetryPending = true
        }

        if historyForcedFlushPending, unsavedHistorySamples > 0 {
            historyForcedFlushPending = false
            checkpointHistory(now: now, force: true)
        } else if succeeded,
                  historyCheckpointDrainRemainingSamples > 0,
                  unsavedHistorySamples > 0 {
            // Continue only the finite sample budget captured by the original
            // trigger. Each hop still rewrites no more than two complete hours.
            checkpointHistory(now: now, force: true, continuingDrain: true)
        }
        if !historyCheckpointInFlight {
            let waiters = historyCheckpointWaiters
            historyCheckpointWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
        }
    }

    private func recordHistory(now: Date) {
        // Production history is emitted only from a versioned minute fact, so
        // live and restored timelines cannot silently mix scoring kernels.
        guard case .scored = state.kind, let level = state.level,
              state.minuteFact != nil else { return }
        let priorUnsavedSamples = unsavedHistorySamples
        let livePoint = StressHistoryPoint(
            t: now,
            activation: state.rawActivation,
            level: level,
            confidence: state.confidence,
            hrvAvailable: state.hrvAvailable,
            minuteFact: state.minuteFact,
            factSource: .live,
            scoringVersion: AtriaStressMonitor.scoringVersion
        )
        if let last = history.last, last.t == now {
            // Recovered replay can finish just before the live minute publishes.
            // Exact-clock acquisition authority belongs to the live fact.
            guard last.factSource != .live else { return }
            history[history.count - 1] = livePoint
        } else {
            if let last = history.last,
               now.timeIntervalSince(last.t)
                < AtriaPhysiologicalStressModel.evaluationCadence {
                return
            }
            history.append(livePoint)
        }
        history.removeAll {
            now.timeIntervalSince($0.t) > AtriaStressHistoryArchive.retentionWindow
        }
        if history.count > AtriaStressHistoryArchive.maximumPointCount {
            history.removeFirst(history.count - AtriaStressHistoryArchive.maximumPointCount)
        }
        historyRevision &+= 1
        historyDurabilityLedger.retainOnly(history.lazy.map(\.t))
        let survivingPriorUnsavedSamples = unsavedHistorySamples
        let prunedUnsavedSamples = priorUnsavedSamples - survivingPriorUnsavedSamples
        historyDurabilityLedger.markDirty(now)
        historyCheckpointDrainRemainingSamples = max(
            0,
            historyCheckpointDrainRemainingSamples - prunedUnsavedSamples
        )
        if Self.shouldPersistHistory(
            hasDurableCheckpoint: historyHasDurableCheckpoint,
            unsavedSampleCount: unsavedHistorySamples
        ) {
            checkpointHistory(now: now)
        }

        // Every complete v3 fact participates. HR-only facts remain explicitly
        // lower confidence in minute provenance; silently dropping them would
        // turn the daily distribution into undisclosed HR+HRV-only coverage.
        if distributionArchive.record(level: level, at: now) {
            distributionRevision &+= 1
            unsavedDistributionSamples += 1
            // At the one-minute history cadence this writes at most every ten
            // minutes. A process interruption can lose only the small pending
            // tail; previously persisted evidence is never reconstructed.
            if unsavedDistributionSamples >= 10 {
                distributionArchive.save(defaults: awakeReferenceDefaults)
                unsavedDistributionSamples = 0
            }
        }
    }

    nonisolated private static func historyHourIndex(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / 3_600))
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

    /// Bounded historical/backfill ingestion through the exact v3 batch kernel
    /// used by live scoring. Framed raw windows are evaluated off MainActor;
    /// only complete versioned minute facts are merged, and real gaps remain.
    func ingestHistoricalStressWindows(
        _ inputs: [AtriaPhysiologicalStressModel.WindowInput],
        now: Date = Date()
    ) async {
        if historyLoadState == .loading { await waitForHistoryHydration() }
        let boundedInputs = Array(inputs.suffix(AtriaStressHistoryArchive.maximumPointCount))
        let perWindowSampleLimit = 600
        let totalSampleLimit = 500_000
        guard boundedInputs.allSatisfy({
            $0.heartRates.count <= perWindowSampleLimit
                && $0.rrIntervals.count <= perWindowSampleLimit
        }), boundedInputs.reduce(into: 0, {
            $0 += $1.heartRates.count + $1.rrIntervals.count
        }) <= totalSampleLimit else { return }
        let firstEnd = boundedInputs.first?.end
        let seed = history.lazy.reversed().compactMap(\.minuteFact).first(
            where: { fact in
                firstEnd.map { end in end > fact.date } ?? false
            }
        )
        historicalReplayGeneration &+= 1
        let generation = historicalReplayGeneration
        let replay = await Task.detached(priority: .utility) {
            let facts = AtriaPhysiologicalStressModel.evaluate(boundedInputs,
                                                               previous: seed)
            let heartRates = boundedInputs.compactMap { input -> AtriaHistoricalStressReplay.HeartRatePoint? in
                guard let sample = input.heartRates.last(where: {
                    $0.qualified && $0.date <= input.end && (30...240).contains($0.bpm)
                }) else { return nil }
                return AtriaHistoricalStressReplay.HeartRatePoint(
                    date: sample.date,
                    bpm: sample.bpm
                )
            }
            return AtriaHistoricalStressReplay.Result(facts: facts,
                                                      heartRates: heartRates)
        }.value
        guard generation == historicalReplayGeneration else { return }
        await mergeHistoricalMinuteFacts(replay, now: now)
    }

    /// Chronological, idempotent archive boundary shared by explicit test
    /// replay and SessionStore recovered-data publication. Existing in-process
    /// live facts win exact-clock collisions. The compact daily distribution is
    /// intentionally untouched: it has no minute identity, so replaying into it
    /// would double-count every recovered publication.
    func mergeHistoricalMinuteFacts(
        _ replay: AtriaHistoricalStressReplay.Result,
        now: Date = Date()
    ) async {
        if historyLoadState == .loading { await waitForHistoryHydration() }
        let factDates = Set(replay.facts.map(\.date))
        guard replay.facts.count <= AtriaStressHistoryArchive.maximumPointCount,
              replay.heartRates.count <= AtriaStressHistoryArchive.maximumPointCount,
              Self.areValidManagedRanges(replay.managedRanges, now: now),
              replay.authorityByDate.count <= replay.facts.count,
              replay.authorityByDate.allSatisfy({ date, authority in
                  factDates.contains(date) && authority.isStructurallyValid
              }),
              Self.isStrictlyChronological(replay.facts.map(\.date)),
              Self.isChronological(replay.heartRates.map(\.date)),
              replay.facts.allSatisfy(\.isStructurallyValid),
              replay.facts.allSatisfy({
                  $0.date.timeIntervalSince(now)
                    <= AtriaStressHistoryArchive.maximumFutureSkew
              }),
              replay.heartRates.allSatisfy({
                  $0.date.timeIntervalSinceReferenceDate.isFinite
                    && $0.date.timeIntervalSince(now)
                        <= AtriaStressHistoryArchive.maximumFutureSkew
                    && (30...240).contains($0.bpm)
              }),
              replay.managedRanges.isEmpty || replay.facts.allSatisfy({ fact in
                  Self.isManaged(fact.date, by: replay.managedRanges)
              }),
              replay.managedRanges.isEmpty || replay.heartRates.allSatisfy({ point in
                  Self.isManaged(point.date, by: replay.managedRanges)
              }) else { return }

        let backfilled = replay.facts.map { fact in
            Self.historyPoint(from: fact,
                              replayAuthority: replay.authorityByDate[fact.date])
        }
        let previousByTimestamp = Dictionary(uniqueKeysWithValues: history.map {
            ($0.t, $0)
        })
        let merged = Self.mergeHistoricalReplay(backfilled,
                                                into: history,
                                                managedRanges: replay.managedRanges,
                                                now: now)
        let historyChanged = merged != history
        if historyChanged {
            history = merged
            historyDurabilityLedger.retainOnly(history.lazy.map(\.t))
            historyDurabilityLedger.markDirty(history.lazy.compactMap { point in
                previousByTimestamp[point.t] == point ? nil : point.t
            })
        }
        let heartRateChanged = mergeHistoricalHeartRateHistory(
            replay.heartRates.map {
                HeartRateHistoryPoint(t: $0.date,
                                      bpm: $0.bpm,
                                      factSource: .historicalReplay)
            },
            managedRanges: replay.managedRanges,
            now: now
        )
        guard historyChanged || heartRateChanged else { return }
        historyRevision &+= 1
        guard historyChanged, let historyPersistence else { return }
        let submission = historyDurabilityLedger.submission(
            for: history.lazy.map(\.t)
        )
        let archive = AtriaStressHistoryArchive(points: history.map {
            AtriaStressHistoryArchive.Point(t: $0.t,
                                            activation: $0.activation,
                                            level: $0.level,
                                            confidence: $0.confidence,
                                            hrvAvailable: $0.hrvAvailable,
                                            minuteFact: $0.minuteFact,
                                            factSource: $0.factSource,
                                            replayAuthority: $0.replayAuthority,
                                            scoringVersion: $0.scoringVersion)
        })
        if await historyPersistence.save(archive, now: now) {
            historyHasDurableCheckpoint = true
            historyDurabilityLedger.complete(submission, succeeded: true)
            if historyLoadState == .unavailable { historyLoadState = .loaded }
        }
    }

    nonisolated private static func isStrictlyChronological(_ dates: [Date]) -> Bool {
        var previous: Date?
        for date in dates {
            guard date.timeIntervalSinceReferenceDate.isFinite,
                  previous.map({ date > $0 }) ?? true else { return false }
            previous = date
        }
        return true
    }

    nonisolated private static func isChronological(_ dates: [Date]) -> Bool {
        var previous: Date?
        for date in dates {
            guard date.timeIntervalSinceReferenceDate.isFinite,
                  previous.map({ date >= $0 }) ?? true else { return false }
            previous = date
        }
        return true
    }

    nonisolated private static func areValidManagedRanges(
        _ ranges: [AtriaHistoricalStressReplay.ManagedRange],
        now: Date
    ) -> Bool {
        guard ranges.count <= AtriaHistoricalStressReplay.maximumManagedRangeCount,
              now.timeIntervalSinceReferenceDate.isFinite else { return false }
        let cutoff = now.addingTimeInterval(-AtriaStressHistoryArchive.retentionWindow)
        let futureLimit = now.addingTimeInterval(
            AtriaStressHistoryArchive.maximumFutureSkew
        )
        var previousEnd: Date?
        for range in ranges {
            guard range.isStructurallyValid,
                  range.start >= cutoff,
                  range.end <= futureLimit,
                  previousEnd.map({ range.start > $0 }) ?? true else {
                return false
            }
            previousEnd = range.end
        }
        return true
    }

    nonisolated private static func historyPoint(
        from fact: AtriaPhysiologicalStressModel.MinuteFact,
        replayAuthority: AtriaStressReplayAuthority?
    ) -> StressHistoryPoint {
        let level: AtriaStressLevel
        switch fact.zone {
        case .calm: level = .calm
        case .moderate: level = .medium
        case .high: level = .high
        }
        return StressHistoryPoint(t: fact.date,
                                  activation: fact.score / 3,
                                  level: level,
                                  confidence: fact.confidence.numericValue,
                                  hrvAvailable: !fact.isHROnly,
                                  minuteFact: fact,
                                  factSource: .historicalReplay,
                                  replayAuthority: replayAuthority,
                                  scoringVersion: fact.scoringVersion)
    }

    @discardableResult
    private func mergeHeartRateHistory(_ additions: [HeartRateHistoryPoint],
                                       now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-AtriaStressHistoryArchive.retentionWindow)
        var byClock = Dictionary(uniqueKeysWithValues: heartRateHistory
            .filter { $0.t >= cutoff }
            .map { ($0.t, $0) })
        byClock.reserveCapacity(additions.count + heartRateHistory.count)
        // This helper receives genuine live observations. They own an exact
        // collision even when a recovered replay landed milliseconds earlier.
        for point in additions where point.t >= cutoff {
            byClock[point.t] = point
        }
        let ordered = byClock.values.sorted { $0.t < $1.t }
        let merged = Array(ordered.suffix(AtriaStressHistoryArchive.maximumPointCount))
        guard merged != heartRateHistory else { return false }
        heartRateHistory = merged
        return true
    }

    @discardableResult
    private func mergeHistoricalHeartRateHistory(
        _ additions: [HeartRateHistoryPoint],
        managedRanges: [AtriaHistoricalStressReplay.ManagedRange],
        now: Date
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-AtriaStressHistoryArchive.retentionWindow)
        let candidateDates = Set(additions.lazy.map(\.t))
        var byClock: [Date: HeartRateHistoryPoint] = [:]
        byClock.reserveCapacity(additions.count + heartRateHistory.count)
        for point in heartRateHistory where point.t >= cutoff {
            let obsoleteManagedReplay = point.factSource == .historicalReplay
                && Self.isManaged(point.t, by: managedRanges)
                && !candidateDates.contains(point.t)
            if !obsoleteManagedReplay { byClock[point.t] = point }
        }
        for candidate in additions where candidate.t >= cutoff {
            if byClock[candidate.t]?.factSource != .live {
                byClock[candidate.t] = candidate
            }
        }
        let ordered = byClock.values.sorted { $0.t < $1.t }
        let merged = Array(ordered.suffix(AtriaStressHistoryArchive.maximumPointCount))
        guard merged != heartRateHistory else { return false }
        heartRateHistory = merged
        return true
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
        // sleeping HR. Qualified active sleep is supplied independently by the
        // caller; the explicit resting-HR floor remains a fail-closed guard when
        // sleep context is unavailable, so overnight HR cannot collapse this
        // reference and overstate the following morning's physiological stress.
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
        _ = awakeReference

        guard hasContact, heartRate > 0 else {
            previousMinuteFact = nil
            lastEvaluatedMinute = nil
            lastMeasuredAt = nil
            if state != .noSignal { state = .noSignal }
            return
        }

        let contactAge = contactStartedAt.map { now.timeIntervalSince($0) } ?? 0
        guard contactAge >= AtriaStressMonitor.warmUpSeconds else {
            previousMinuteFact = nil
            lastMeasuredAt = nil
            let warming = AtriaStressState(level: nil,
                                           label: "Warming up",
                                           detail: "Building a five-minute cardiac window",
                                           kind: .warmingUp,
                                           confidence: 0,
                                           rawActivation: 0,
                                           hrvAvailable: false)
            if warming != state { state = warming }
            return
        }

        let minute = Date(timeIntervalSince1970:
            floor(now.timeIntervalSince1970 / AtriaPhysiologicalStressModel.evaluationCadence)
                * AtriaPhysiologicalStressModel.evaluationCadence)
        guard lastEvaluatedMinute != minute else { return }
        lastEvaluatedMinute = minute

        let freshBaseline = baseline.freshSamples(now: minute)
        let qualifiedLnRMSSD = freshBaseline
            .filter(\.isOvernightSample)
            .compactMap(\.lnRMSSD)
        let hrvBaseline = AtriaPhysiologicalStressModel.robustHRVBaseline(
            lnRMSSDValues: qualifiedLnRMSSD,
            qualifiedDayCount: baseline.freshHRVSampleCount(now: minute)
        )
        let personalization = AtriaPhysiologicalStressModel.Personalization(
            restingHeartRate: baseline.restingHR ?? Double(restingMaxHR.rest),
            maximumHeartRate: Double(restingMaxHR.max),
            restingBaselineDayCount: baseline.freshRestingSampleCount(now: minute),
            hrvBaseline: hrvBaseline
        )

        let motionContext: AtriaPhysiologicalStressModel.MotionContext
        if isRecording {
            // An explicitly active workout is qualified activity evidence.
            // `zoneIndex` is derived from HR itself and must never attenuate a
            // cardiac elevation as if it independently proved motion.
            let workoutIntensity = zoneIndex.map {
                min(max(Double($0 - 1) / 3, 0.35), 1)
            } ?? 0.65
            motionContext = .qualifiedActivity(intensity: workoutIntensity)
        } else {
            // Missing motion fails closed to M=1. Zone-only context is not a
            // validated motion authority.
            motionContext = .unavailable
        }
        let sleepContext: AtriaPhysiologicalStressModel.SleepContext =
            hasActiveSleepEvidence ? .asleep : .unavailable

        // Persisted cadence HRV is deliberately not substituted here. Admit RR
        // only when the existing artifact/provenance/confidence pipeline marks
        // the complete local five-minute window ready. Rejected beats remain in
        // the sequence as explicit breaks, so RMSSD never differences across an
        // artifact. This bounded work occurs once per minute, after the cadence
        // guard above, rather than on every live pulse tick.
        _ = hrvSnapshot
        let rrStart = minute.addingTimeInterval(-AtriaPhysiologicalStressModel.windowDuration)
        let rawRR = Self.timeAlignedRRIntervals(
            recentRRSamples,
            heartRates: hrBuffer,
            start: rrStart,
            end: minute
        )
        let (rrQuality, correctedRR) = HRVAnalyzer.analyze(
            rawRR,
            now: minute,
            includeTachogram: true,
            provenance: .localRRWindow
        )
        let qualifiedRR: [AtriaPhysiologicalStressModel.RRSample]
        if rrQuality?.isLiveStressEligible(on: minute, maximumAge: 60) == true {
            qualifiedRR = correctedRR.map {
                .init(date: $0.t,
                      milliseconds: $0.ms,
                      qualified: $0.corrected && !$0.interpolated)
            }
        } else {
            qualifiedRR = []
        }
        let input = AtriaPhysiologicalStressModel.WindowInput(
            end: minute,
            heartRates: hrBuffer.map {
                .init(date: $0.t, bpm: $0.bpm, qualified: true)
            },
            rrIntervals: qualifiedRR,
            personalization: personalization,
            motionContext: motionContext,
            sleepContext: sleepContext
        )
        guard let fact = AtriaPhysiologicalStressModel.evaluate(
            input,
            previous: previousMinuteFact
        ) else {
            previousMinuteFact = nil
            lastMeasuredAt = nil
            if state != .noSignal { state = .noSignal }
            return
        }
        previousMinuteFact = fact

        let level: AtriaStressLevel
        switch fact.zone {
        case .calm: level = .calm
        case .moderate: level = .medium
        case .high: level = .high
        }
        var detail = fact.isHROnly
            ? "HR-only estimate · lower confidence"
            : "Physiological stress · HR + HRV"
        if fact.baselineLearning { detail += " · learning baseline" }
        if fact.motionContext.qualified, fact.motionContext.kind == .activity {
            detail += " · activity-adjusted"
        }
        let finalState = AtriaStressState(
            level: level,
            label: fact.zone.rawValue,
            detail: detail,
            kind: .scored,
            confidence: fact.confidence.numericValue,
            rawActivation: fact.score / AtriaStressEvidenceProjection.maximumDisplayValue,
            hrvAvailable: !fact.isHROnly,
            minuteFact: fact
        )
        if finalState != state { state = finalState }
        lastMeasuredAt = fact.date
        // The HR tab receives a real timestamped observation from inside this
        // exact minute window—not the later UI tick and not the five-minute
        // mean embedded in the stress fact.
        if let measuredHeartRate = hrBuffer.last(where: {
            $0.t <= fact.date && (30...240).contains($0.bpm)
        }) {
            mergeHeartRateHistory(
                [HeartRateHistoryPoint(t: measuredHeartRate.t,
                                       bpm: measuredHeartRate.bpm)],
                now: now
            )
        }
        recordHistory(now: fact.date)
    }
}
