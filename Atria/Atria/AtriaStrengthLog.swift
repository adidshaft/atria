import Foundation

struct LoggedSet: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    let exercise: String
    var weightKg: Double?
    var reps: Int?
    var rpe: Double?
    let t: Date
    /// The resistance moved by this exact set, captured at logging time when
    /// Atria can derive it from body mass (for example a pull-up).  This is
    /// deliberately separate from `weightKg`: the latter is the external
    /// load the wearer entered, while this value freezes the effective load
    /// needed to reproduce a body-weight set after profile edits.
    ///
    /// Nil means Atria did not have a defensible effective-load estimate. Old
    /// archives retain that nil rather than being reconstructed from today's
    /// body mass.
    var effectiveLoadKg: Double? = nil
    /// Optional ordered superset receipt. Nil means this set was logged as an
    /// ordinary set; legacy rows remain exactly that.
    var supersetGroupID: String? = nil
    var supersetOrder: Int? = nil
    /// Observed time since the previous member of this group. This lets later
    /// muscular-load work distinguish the quick intra-round handoff from the
    /// longer rest before the next round without guessing from HR.
    var supersetTransitionSeconds: TimeInterval? = nil
}

struct StrengthSuperset: Codable, Equatable, Identifiable {
    let id: String
    var exercises: [String]

    init(id: String = UUID().uuidString, exercises: [String]) {
        self.id = id
        self.exercises = exercises
    }
}

struct ExcludedInterval: Codable, Equatable {
    let start: Date
    let end: Date
}

enum AtriaStrengthLog {
    static let customExercisesKey = "atria.exercises.custom.v1"
    static let restSecondsKey = "atria.strength.restSeconds.v1"

    enum MovementClass: String, Codable, CaseIterable, Hashable {
        case externalLoad = "External load"
        case bodyweightEstimate = "Bodyweight estimate"
        case unavailable = "Load unavailable"
    }

    /// Reproducible logged-strength input, intentionally separate from
    /// cardiovascular Strain. The receipt carries its qualification state so
    /// an unlogged Strength activity is never inferred from HR or duration,
    /// and missing RPE is never silently converted into an average effort.
    struct MuscularLoadReceipt: Codable, Equatable {
        /// Bump only when the meaning of the persisted receipt changes. A
        /// completed workout keeps its original version rather than opening
        /// under silently revised muscular-input math.
        let calculationVersion: Int
        let setCount: Int
        /// Sets carrying a frozen effective or directly entered external load
        /// and a positive repetition count.
        let loadQualifiedSetCount: Int
        /// Load-qualified sets with a user-entered RPE. A muscular-input score
        /// is only available when this equals `loadQualifiedSetCount`.
        let effortQualifiedSetCount: Int
        let externalVolumeKg: Double
        let effectiveVolumeKg: Double
        let densityBonusFraction: Double
        /// A relative, logged muscular-input index (0...100). It is not
        /// Strain and is intentionally nil until every load-qualified set has
        /// an explicit RPE. It must not be fused with cardiovascular Strain
        /// until that model is calibrated.
        let muscularInputScore: Double?
        let movementClasses: Set<MovementClass>

        var qualifiedSetCount: Int { loadQualifiedSetCount }
        var volumeKg: Double { effectiveVolumeKg }
        var score: Double? { muscularInputScore }
        var hasCompleteEffortEvidence: Bool {
            loadQualifiedSetCount > 0 && effortQualifiedSetCount == loadQualifiedSetCount
        }
        var rpeCoverageText: String {
            "\(effortQualifiedSetCount) of \(loadQualifiedSetCount) sets with RPE"
        }

        /// True when any qualified volume is a body-mass estimate rather than a
        /// measured external load.
        var includesBodyweightEstimate: Bool {
            movementClasses.contains(.bodyweightEstimate)
        }

        /// Honest one-line basis for the logged volume (GAP-09: the results UI
        /// must distinguish measured/logged load from body-mass-estimated load,
        /// so an estimated pull-up session is never shown like measured barbell
        /// work).
        var loadBasisText: String {
            switch (movementClasses.contains(.externalLoad), includesBodyweightEstimate) {
            case (true, true): return "Measured + body-mass estimate"
            case (false, true): return "Body-mass estimate"
            default: return "Measured external load"
            }
        }
    }

    /// Returns a per-set effective resistance. External resistance is already
    /// a useful measurement for barbell/dumbbell work. For a narrow list of
    /// body-weight movements, the frozen profile mass is converted to an
    /// *estimated* moved fraction; unknown movements remain unavailable rather
    /// than pretending every repetition moved the full body mass.
    static func effectiveLoadKg(exercise: String,
                                externalWeightKg: Double?,
                                bodyMassKg: Double?) -> (loadKg: Double, movementClass: MovementClass)? {
        let external = externalWeightKg.map { max(0, $0) } ?? 0
        let bodyweightFraction = estimatedBodyweightFraction(for: exercise)

        guard let bodyweightFraction,
              let bodyMassKg,
              bodyMassKg.isFinite,
              bodyMassKg > 0 else {
            guard external > 0 else { return nil }
            return (external, .externalLoad)
        }
        let effective = external + bodyMassKg * bodyweightFraction
        return (effective, .bodyweightEstimate)
    }

    /// True only for movements for which Atria has a deliberately narrow
    /// effective-body-mass estimate. The live logger uses this to label the
    /// entered number as added weight instead of misleadingly pre-filling a
    /// barbell-style load for a push-up or pull-up.
    static func isEstimatedBodyweightExercise(_ exercise: String) -> Bool {
        estimatedBodyweightFraction(for: exercise) != nil
    }

    private static func estimatedBodyweightFraction(for exercise: String) -> Double? {
        let normalized = normalized(exercise)
        if normalized.contains("pull-up") || normalized.contains("pullup")
            || normalized.contains("chin-up") || normalized.contains("chinup") {
            return 0.95
        }
        if normalized.contains("dip") { return 0.90 }
        if normalized.contains("push-up") || normalized.contains("pushup") { return 0.65 }
        if normalized.contains("air squat") || normalized.contains("walking lunge")
            || normalized.contains("step-up") || normalized.contains("step up") {
            return 0.75
        }
        if normalized.contains("burpee") || normalized.contains("jump squat") { return 0.60 }
        return nil
    }

    static func muscularLoadReceipt(for sets: [LoggedSet]) -> MuscularLoadReceipt? {
        guard !sets.isEmpty else { return nil }
        struct QualifiedSet {
            let effectiveVolumeKg: Double
            let externalVolumeKg: Double
            let rpe: Double?
            let movementClass: MovementClass
        }
        let qualified = sets.compactMap { set -> QualifiedSet? in
            guard let reps = set.reps, reps > 0 else { return nil }
            let effectiveLoad = set.effectiveLoadKg ?? set.weightKg
            guard let effectiveLoad,
                  effectiveLoad.isFinite,
                  effectiveLoad > 0 else { return nil }
            let movementClass: MovementClass = set.effectiveLoadKg == nil
                ? .externalLoad
                : .bodyweightEstimate
            return QualifiedSet(effectiveVolumeKg: effectiveLoad * Double(reps),
                                externalVolumeKg: max(0, set.weightKg ?? 0) * Double(reps),
                                rpe: set.rpe.map { min(max($0, 0), 10) },
                                movementClass: movementClass)
        }
        guard !qualified.isEmpty else { return nil }
        let quickTransitions = sets.filter {
            guard $0.supersetGroupID != nil,
                  let seconds = $0.supersetTransitionSeconds else { return false }
            return seconds <= 90
        }.count
        let density = min(0.15, Double(quickTransitions) * 0.03)
        let effectiveVolume = qualified.reduce(0) { $0 + $1.effectiveVolumeKg }
        let externalVolume = qualified.reduce(0) { $0 + $1.externalVolumeKg }
        let effortQualified = qualified.compactMap(\.rpe)
        let inputScore: Double?
        if effortQualified.count == qualified.count {
            let effortAdjustedVolume = zip(qualified, effortQualified).reduce(0.0) { total, pair in
                total + pair.0.effectiveVolumeKg * (0.55 + 0.45 * pair.1 / 10)
            }
            // This is a bounded *within-person logged-input* presentation
            // scale. It is not a cardiovascular score or an authoritative
            // muscular Strain model, and therefore never alters Strain.
            inputScore = min(100, 100 * (1 - exp(-(effortAdjustedVolume * (1 + density)) / 5_000)))
        } else {
            inputScore = nil
        }
        return MuscularLoadReceipt(calculationVersion: 1,
                                   setCount: sets.count,
                                   loadQualifiedSetCount: qualified.count,
                                   effortQualifiedSetCount: effortQualified.count,
                                   externalVolumeKg: externalVolume,
                                   effectiveVolumeKg: effectiveVolume,
                                   densityBonusFraction: density,
                                   muscularInputScore: inputScore,
                                   movementClasses: Set(qualified.map(\.movementClass)))
    }

    static func estimatedOneRepMax(weightKg: Double?, reps: Int?) -> Double? {
        guard let weightKg,
              let reps,
              weightKg > 0,
              (1...12).contains(reps) else {
            return nil
        }
        return weightKg * (1 + Double(reps) / 30.0)
    }

    static func history(for exercise: String,
                        in sessions: [SavedSession],
                        calendar: Calendar = .current) -> [(day: Date, best: LoggedSet)] {
        let matching = sessions
            .flatMap { $0.strengthSets ?? [] }
            .filter { normalized($0.exercise) == normalized(exercise) }

        let grouped = Dictionary(grouping: matching) { set in
            calendar.startOfDay(for: set.t)
        }
        return grouped.compactMap { day, sets -> (day: Date, best: LoggedSet)? in
            guard let best = sets.max(by: { setScore($0) < setScore($1) }) else { return nil }
            return (day, best)
        }
        .sorted { $0.day < $1.day }
    }

    static func personalRecords(for exercise: String,
                                in sessions: [SavedSession]) -> StrengthPersonalRecords {
        let sets = sessions
            .flatMap { $0.strengthSets ?? [] }
            .filter { normalized($0.exercise) == normalized(exercise) }
        var records = StrengthPersonalRecords()
        for set in sets { records.accept(set) }
        return records
    }

    /// Builds the compact strength-only input used by interactive workout UI.
    /// This is intentionally created once when a logger/review flow opens. The
    /// live sheet must never retain or repeatedly scan the HR/RR-heavy lifetime
    /// session archive just to render a set row.
    static func historyProjection(in sessions: [SavedSession],
                                  recentDaysPerExercise: Int = 12,
                                  calendar: Calendar = .current) -> StrengthHistoryProjection {
        let dayLimit = max(1, recentDaysPerExercise)
        var recordsByExercise: [String: StrengthPersonalRecords] = [:]
        var dailyBestByExercise: [String: [Date: LoggedSet]] = [:]
        var dailySetCountByExercise: [String: [Date: Int]] = [:]
        var displayNameByExercise: [String: (name: String, t: Date)] = [:]

        for session in sessions {
            guard let sets = session.strengthSets, !sets.isEmpty else { continue }
            for set in sets {
                let key = normalized(set.exercise)
                guard !key.isEmpty else { continue }
                var records = recordsByExercise[key] ?? StrengthPersonalRecords()
                records.accept(set)
                recordsByExercise[key] = records

                let day = calendar.startOfDay(for: set.t)
                let existing = dailyBestByExercise[key]?[day]
                if existing == nil || setScore(existing!) < setScore(set) {
                    dailyBestByExercise[key, default: [:]][day] = set
                }
                dailySetCountByExercise[key, default: [:]][day, default: 0] += 1
                if let seen = displayNameByExercise[key] {
                    if set.t > seen.t {
                        displayNameByExercise[key] = (set.exercise, set.t)
                    }
                } else {
                    displayNameByExercise[key] = (set.exercise, set.t)
                }
            }
        }

        var recentHistoryByExercise: [String: [StrengthHistoryDay]] = [:]
        recentHistoryByExercise.reserveCapacity(dailyBestByExercise.count)
        // One row per exercise-day, so the lifetime series stays a few hundred
        // small values even for years of lifting. It never carries HR/RR
        // samples; the heavy session archive is still only scanned here, once.
        var fullHistoryByExercise: [String: [StrengthHistoryDay]] = [:]
        fullHistoryByExercise.reserveCapacity(dailyBestByExercise.count)
        for (key, bestByDay) in dailyBestByExercise {
            let counts = dailySetCountByExercise[key] ?? [:]
            let days = bestByDay
                .map { StrengthHistoryDay(day: $0.key, best: $0.value, setCount: counts[$0.key] ?? 1) }
                .sorted { $0.day < $1.day }
            fullHistoryByExercise[key] = days
            recentHistoryByExercise[key] = Array(days.suffix(dayLimit))
        }
        return StrengthHistoryProjection(recordsByExercise: recordsByExercise,
                                         recentHistoryByExercise: recentHistoryByExercise,
                                         recentDaysPerExercise: dayLimit,
                                         fullHistoryByExercise: fullHistoryByExercise,
                                         displayNamesByExercise: displayNameByExercise.mapValues(\.name))
    }

    static func isPR(_ set: LoggedSet, against records: StrengthPersonalRecords) -> Bool {
        if let weight = set.weightKg,
           weight > (records.maxWeightKg ?? 0) {
            return true
        }
        if let e1RM = estimatedOneRepMax(weightKg: set.weightKg, reps: set.reps),
           e1RM > (records.maxE1RM ?? 0) {
            return true
        }
        if let weight = set.weightKg,
           let reps = set.reps,
           reps > (records.maxRepsAtWeight[weight] ?? 0) {
            return true
        }
        return false
    }

    static func pointsExcludingIntervals(_ points: [SavedSession.Point],
                                         sessionStart: Date,
                                         excludedIntervals: [ExcludedInterval]?) -> [SavedSession.Point] {
        guard let excludedIntervals, !excludedIntervals.isEmpty else { return points }
        return points.filter { point in
            let sampleTime = sessionStart.addingTimeInterval(point.t)
            return !excludedIntervals.contains { interval in
                sampleTime >= interval.start && sampleTime <= interval.end
            }
        }
    }

    static func samplesExcludingIntervals(_ samples: [HRSample],
                                          excludedIntervals: [ExcludedInterval]?) -> [HRSample] {
        guard let excludedIntervals, !excludedIntervals.isEmpty else { return samples }
        return samples.filter { sample in
            !excludedIntervals.contains { interval in
                sample.t >= interval.start && sample.t <= interval.end
            }
        }
    }

    static func restSeconds(for exercise: String,
                            defaults: UserDefaults = .standard) -> TimeInterval {
        restOverrides(defaults: defaults)[exercise] ?? 120
    }

    static func setRestSeconds(_ seconds: TimeInterval,
                               for exercise: String,
                               defaults: UserDefaults = .standard) {
        var overrides = restOverrides(defaults: defaults)
        overrides[exercise] = min(max(seconds, 30), 600)
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: restSecondsKey)
        }
    }

    private static func restOverrides(defaults: UserDefaults = .standard) -> [String: TimeInterval] {
        guard let data = defaults.data(forKey: restSecondsKey),
              let overrides = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return [:]
        }
        return overrides
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func setScore(_ set: LoggedSet) -> Double {
        estimatedOneRepMax(weightKg: set.weightKg, reps: set.reps)
            ?? set.weightKg
            ?? Double(set.reps ?? 0)
    }
}

struct StrengthPersonalRecords: Equatable {
    var maxWeightKg: Double?
    var maxE1RM: Double?
    var maxRepsAtWeight: [Double: Int] = [:]

    mutating func accept(_ set: LoggedSet) {
        if let weight = set.weightKg {
            maxWeightKg = max(maxWeightKg ?? weight, weight)
            if let reps = set.reps {
                maxRepsAtWeight[weight] = max(maxRepsAtWeight[weight] ?? reps, reps)
            }
        }
        if let e1RM = AtriaStrengthLog.estimatedOneRepMax(weightKg: set.weightKg, reps: set.reps) {
            maxE1RM = max(maxE1RM ?? e1RM, e1RM)
        }
    }

    func including(_ sets: [LoggedSet], exercise: String) -> StrengthPersonalRecords {
        let key = AtriaStrengthLog.normalized(exercise)
        var result = self
        for set in sets where AtriaStrengthLog.normalized(set.exercise) == key {
            result.accept(set)
        }
        return result
    }
}

struct StrengthHistoryDay: Equatable {
    let day: Date
    let best: LoggedSet
    /// How many sets of this exercise were actually logged that day. The
    /// learning copy ("2 sets logged") states real sets, not days.
    let setCount: Int

    init(day: Date, best: LoggedSet, setCount: Int = 1) {
        self.day = day
        self.best = best
        self.setCount = max(1, setCount)
    }
}

/// Small immutable projection passed into workout UI. PR aggregates cover all
/// saved strength sets exactly; the recent list stays bounded for the live
/// sheet, while `fullHistory` carries the day-level series the e1RM progress
/// chart and the exercise catalog read (one small row per exercise-day).
struct StrengthHistoryProjection: Equatable {
    static let empty = StrengthHistoryProjection(recordsByExercise: [:],
                                                 recentHistoryByExercise: [:],
                                                 recentDaysPerExercise: 12)

    private let recordsByExercise: [String: StrengthPersonalRecords]
    private let recentHistoryByExercise: [String: [StrengthHistoryDay]]
    private let fullHistoryByExercise: [String: [StrengthHistoryDay]]
    private let displayNamesByExercise: [String: String]
    let recentDaysPerExercise: Int

    init(recordsByExercise: [String: StrengthPersonalRecords],
         recentHistoryByExercise: [String: [StrengthHistoryDay]],
         recentDaysPerExercise: Int,
         fullHistoryByExercise: [String: [StrengthHistoryDay]] = [:],
         displayNamesByExercise: [String: String] = [:]) {
        self.recordsByExercise = recordsByExercise
        self.recentHistoryByExercise = recentHistoryByExercise
        self.recentDaysPerExercise = recentDaysPerExercise
        self.fullHistoryByExercise = fullHistoryByExercise
        self.displayNamesByExercise = displayNamesByExercise
    }

    func records(for exercise: String) -> StrengthPersonalRecords {
        recordsByExercise[AtriaStrengthLog.normalized(exercise)] ?? StrengthPersonalRecords()
    }

    func history(for exercise: String) -> [StrengthHistoryDay] {
        recentHistoryByExercise[AtriaStrengthLog.normalized(exercise)] ?? []
    }

    /// Every saved day for one exercise, oldest first. Empty when the exercise
    /// has never been logged — the progress chart shows its learning state
    /// rather than inventing a line.
    func fullHistory(for exercise: String) -> [StrengthHistoryDay] {
        fullHistoryByExercise[AtriaStrengthLog.normalized(exercise)] ?? []
    }

    /// Exercise names exactly as they were last logged, so the catalog can
    /// list a lift that is no longer in the built-in groups.
    var loggedExerciseNames: [String] {
        Array(displayNamesByExercise.values)
    }
}
