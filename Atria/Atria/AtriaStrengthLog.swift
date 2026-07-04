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
        for set in sets {
            if let weight = set.weightKg {
                records.maxWeightKg = max(records.maxWeightKg ?? weight, weight)
                if let reps = set.reps {
                    records.maxRepsAtWeight[weight] = max(records.maxRepsAtWeight[weight] ?? reps, reps)
                }
            }
            if let e1RM = estimatedOneRepMax(weightKg: set.weightKg, reps: set.reps) {
                records.maxE1RM = max(records.maxE1RM ?? e1RM, e1RM)
            }
        }
        return records
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

    private static func normalized(_ value: String) -> String {
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
}
