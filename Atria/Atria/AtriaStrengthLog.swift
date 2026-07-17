import Foundation

struct LoggedSet: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    let exercise: String
    var weightKg: Double?
    var reps: Int?
    var rpe: Double?
    let t: Date
}

struct ExcludedInterval: Codable, Equatable {
    let start: Date
    let end: Date
}

enum AtriaStrengthLog {
    static let customExercisesKey = "atria.exercises.custom.v1"
    static let restSecondsKey = "atria.strength.restSeconds.v1"

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
            }
        }

        var recentHistoryByExercise: [String: [StrengthHistoryDay]] = [:]
        recentHistoryByExercise.reserveCapacity(dailyBestByExercise.count)
        for (key, bestByDay) in dailyBestByExercise {
            let recent = bestByDay
                .map { StrengthHistoryDay(day: $0.key, best: $0.value) }
                .sorted { $0.day < $1.day }
                .suffix(dayLimit)
            recentHistoryByExercise[key] = Array(recent)
        }
        return StrengthHistoryProjection(recordsByExercise: recordsByExercise,
                                         recentHistoryByExercise: recentHistoryByExercise,
                                         recentDaysPerExercise: dayLimit)
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
}

/// Small immutable projection passed into workout UI. PR aggregates cover all
/// saved strength sets exactly; only display history is bounded.
struct StrengthHistoryProjection: Equatable {
    static let empty = StrengthHistoryProjection(recordsByExercise: [:],
                                                 recentHistoryByExercise: [:],
                                                 recentDaysPerExercise: 12)

    private let recordsByExercise: [String: StrengthPersonalRecords]
    private let recentHistoryByExercise: [String: [StrengthHistoryDay]]
    let recentDaysPerExercise: Int

    init(recordsByExercise: [String: StrengthPersonalRecords],
         recentHistoryByExercise: [String: [StrengthHistoryDay]],
         recentDaysPerExercise: Int) {
        self.recordsByExercise = recordsByExercise
        self.recentHistoryByExercise = recentHistoryByExercise
        self.recentDaysPerExercise = recentDaysPerExercise
    }

    func records(for exercise: String) -> StrengthPersonalRecords {
        recordsByExercise[AtriaStrengthLog.normalized(exercise)] ?? StrengthPersonalRecords()
    }

    func history(for exercise: String) -> [StrengthHistoryDay] {
        recentHistoryByExercise[AtriaStrengthLog.normalized(exercise)] ?? []
    }
}
