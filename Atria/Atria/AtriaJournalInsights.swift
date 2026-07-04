import Foundation

/// Journal insight-engine v2 (docs/24 §12.2 P3): typed-answer analyses layered
/// beside the frozen boolean-tag engine in AtriaBehaviorImpact. Pure and
/// snapshot-driven — safe to run on the utility queue, never in a view body.
struct JournalInsight: Identifiable, Equatable {
    enum Kind: Equatable {
        case booleanImpact(impact: Double, loggedDays: Int, comparisonDays: Int, pValue: Double)
        case thresholdSplit(splitMinutes: Int, laterMeanDelta: Double, earlierDays: Int, laterDays: Int, adjustedPValue: Double)
        case rankCorrelation(rho: Double, days: Int, pValue: Double)
    }

    let questionID: String
    let label: String
    let kind: Kind

    var id: String { questionID }

    /// One-line user-facing statement, always carrying the evidence base (n).
    var valueText: String {
        switch kind {
        case .booleanImpact(let impact, let loggedDays, let comparisonDays, _):
            return String(format: "%@ → %+.0f%% next-day recovery (%d vs %d days, %@)",
                          label, impact, loggedDays, comparisonDays, confidenceText)
        case .thresholdSplit(let splitMinutes, let laterMeanDelta, let earlierDays, let laterDays, _):
            return String(format: "%@ after %@ → %+.0f%% next-day recovery (%d vs %d days, %@)",
                          label,
                          Self.timeText(minutes: splitMinutes),
                          laterMeanDelta,
                          laterDays,
                          earlierDays,
                          confidenceText)
        case .rankCorrelation(let rho, let days, _):
            return String(format: "More %@ tracks with %@ next-day recovery (rho %+.2f, %d days, %@)",
                          label.lowercased(),
                          rho < 0 ? "lower" : "higher",
                          rho,
                          days,
                          confidenceText)
        }
    }

    var confidenceText: String {
        let p: Double
        switch kind {
        case .booleanImpact(_, _, _, let pValue): p = pValue
        case .thresholdSplit(_, _, _, _, let adjustedPValue): p = adjustedPValue
        case .rankCorrelation(_, _, let pValue): p = pValue
        }
        return p <= 0.05 ? "high confidence" : "moderate confidence"
    }

    var effectMagnitude: Double {
        switch kind {
        case .booleanImpact(let impact, _, _, _): return abs(impact)
        case .thresholdSplit(_, let delta, _, _, _): return abs(delta)
        case .rankCorrelation(let rho, _, _): return abs(rho) * 10
        }
    }

    var pairedDays: Int {
        switch kind {
        case .booleanImpact(_, let logged, let comparison, _): return logged + comparison
        case .thresholdSplit(_, _, let earlier, let later, _): return earlier + later
        case .rankCorrelation(_, let days, _): return days
        }
    }

    static func timeText(minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else { return "\(minutes)m" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

enum AtriaJournalInsights {
    struct AnswerDay: Equatable {
        let day: Date
        let value: Value
    }

    enum Value: Equatable {
        case boolean(Bool)
        case timeOfDayMinutes(Int)
        case quantity(Double)
        case scale1to5(Int)
    }

    // Gating constants (also pinned by tests/static checks).
    static let minimumSideDays = 5
    static let minimumSplitTotalDays = 12
    static let splitGridStepMinutes = 30
    static let minimumSplitEffect = 3.0
    static let maximumAdjustedPValue = 0.10
    static let minimumCorrelationPairs = 8
    static let minimumDistinctValues = 3
    static let minimumAbsRho = 0.3
    static let permutationCount = 2000

    static func insights(questionAnswers: [String: [AnswerDay]],
                         labels: [String: String] = [:],
                         days: [AtriaBehaviorImpact.Day],
                         referenceDate: Date? = nil,
                         calendar: Calendar = .current) -> [JournalInsight] {
        let latest = referenceDate
            ?? (days.map(\.day) + questionAnswers.values.flatMap { $0.map(\.day) }).max()
            ?? Date()
        let referenceDay = calendar.startOfDay(for: latest)
        let windowStart = calendar.date(byAdding: .day,
                                        value: -AtriaBehaviorImpact.trailingWindowDays,
                                        to: referenceDay)
            ?? referenceDay.addingTimeInterval(TimeInterval(-AtriaBehaviorImpact.trailingWindowDays * 24 * 60 * 60))

        // Same day↔recovery pairing convention as AtriaBehaviorImpact.summaries.
        let recoveryByDay = Dictionary(uniqueKeysWithValues: days.compactMap { day -> (Date, Double)? in
            let key = calendar.startOfDay(for: day.day)
            guard key >= windowStart, key <= referenceDay, let recovery = day.recoveryPercent else {
                return nil
            }
            return (key, Double(recovery))
        })
        guard !recoveryByDay.isEmpty else { return [] }

        var results: [JournalInsight] = []
        for (questionID, answers) in questionAnswers {
            let windowed = answers.filter {
                let day = calendar.startOfDay(for: $0.day)
                return day >= windowStart && day <= referenceDay
            }
            let pairs: [(value: Value, recovery: Double)] = windowed.compactMap { answer in
                guard let recovery = recoveryByDay[calendar.startOfDay(for: answer.day)] else { return nil }
                return (answer.value, recovery)
            }
            guard !pairs.isEmpty else { continue }
            let label = labels[questionID] ?? questionID

            if let insight = analyze(questionID: questionID, label: label, pairs: pairs) {
                results.append(insight)
            }
        }
        return results.sorted {
            if $0.effectMagnitude != $1.effectMagnitude { return $0.effectMagnitude > $1.effectMagnitude }
            if $0.pairedDays != $1.pairedDays { return $0.pairedDays > $1.pairedDays }
            return $0.questionID < $1.questionID
        }
    }

    private static func analyze(questionID: String,
                                label: String,
                                pairs: [(value: Value, recovery: Double)]) -> JournalInsight? {
        if pairs.allSatisfy({ if case .boolean = $0.value { return true } else { return false } }) {
            return booleanInsight(questionID: questionID, label: label, pairs: pairs)
        }
        if pairs.allSatisfy({ if case .timeOfDayMinutes = $0.value { return true } else { return false } }) {
            let timePairs = pairs.compactMap { pair -> (minutes: Int, recovery: Double)? in
                if case .timeOfDayMinutes(let minutes) = pair.value { return (minutes, pair.recovery) }
                return nil
            }
            return thresholdSplitInsight(questionID: questionID, label: label, pairs: timePairs)
        }
        let numeric = pairs.compactMap { pair -> (x: Double, y: Double)? in
            switch pair.value {
            case .quantity(let value): return (value, pair.recovery)
            case .scale1to5(let level): return (Double(level), pair.recovery)
            case .boolean, .timeOfDayMinutes: return nil
            }
        }
        guard numeric.count == pairs.count else { return nil }
        return rankCorrelationInsight(questionID: questionID, label: label, pairs: numeric)
    }

    private static func booleanInsight(questionID: String,
                                       label: String,
                                       pairs: [(value: Value, recovery: Double)]) -> JournalInsight? {
        var logged: [Double] = []
        var comparison: [Double] = []
        for pair in pairs {
            if case .boolean(let isOn) = pair.value {
                if isOn { logged.append(pair.recovery) } else { comparison.append(pair.recovery) }
            }
        }
        guard logged.count >= AtriaBehaviorImpact.minimumLoggedDays,
              comparison.count >= AtriaBehaviorImpact.minimumComparisonDays else { return nil }
        let impact = AtriaBehaviorImpact.mean(logged) - AtriaBehaviorImpact.mean(comparison)
        let pValue = AtriaBehaviorImpact.welchTwoSidedPValue(logged, comparison)
        guard abs(impact) >= AtriaBehaviorImpact.minimumImpact,
              pValue <= AtriaBehaviorImpact.maximumPValue else { return nil }
        return JournalInsight(questionID: questionID,
                              label: label,
                              kind: .booleanImpact(impact: impact,
                                                   loggedDays: logged.count,
                                                   comparisonDays: comparison.count,
                                                   pValue: pValue))
    }

    /// Threshold split for time-of-day answers: search a coarse 30-minute grid
    /// for the split maximizing the later-vs-earlier recovery difference, with a
    /// Bonferroni correction over the searched candidates and a leave-one-out
    /// sign-stability check as overfitting guard rails.
    static func thresholdSplitInsight(questionID: String,
                                      label: String,
                                      pairs: [(minutes: Int, recovery: Double)]) -> JournalInsight? {
        guard pairs.count >= minimumSplitTotalDays,
              let minMinutes = pairs.map(\.minutes).min(),
              let maxMinutes = pairs.map(\.minutes).max(),
              maxMinutes > minMinutes else { return nil }

        var admissible: [(grid: Int, diff: Double, pValue: Double, earlier: [Double], later: [Double])] = []
        let firstGrid = ((minMinutes / splitGridStepMinutes) + 1) * splitGridStepMinutes
        for grid in stride(from: firstGrid, through: maxMinutes, by: splitGridStepMinutes) {
            let later = pairs.filter { $0.minutes >= grid }.map(\.recovery)
            let earlier = pairs.filter { $0.minutes < grid }.map(\.recovery)
            guard later.count >= minimumSideDays, earlier.count >= minimumSideDays else { continue }
            let diff = AtriaBehaviorImpact.mean(later) - AtriaBehaviorImpact.mean(earlier)
            let pValue = AtriaBehaviorImpact.welchTwoSidedPValue(later, earlier)
            admissible.append((grid, diff, pValue, earlier, later))
        }
        guard !admissible.isEmpty else { return nil }

        let maxAbsDiff = admissible.map { abs($0.diff) }.max() ?? 0
        guard let best = admissible.first(where: { abs($0.diff) >= maxAbsDiff - 1e-12 }) else { return nil }
        let adjustedPValue = min(1.0, best.pValue * Double(admissible.count))
        guard abs(best.diff) >= minimumSplitEffect,
              adjustedPValue <= maximumAdjustedPValue else { return nil }

        // Leave-one-out sign stability: drop the most extreme recovery value on
        // the smaller side; the effect direction must survive.
        let smallerIsLater = best.later.count <= best.earlier.count
        var smaller = smallerIsLater ? best.later : best.earlier
        if smaller.count > 1 {
            let sideMean = AtriaBehaviorImpact.mean(smaller)
            if let extremeIndex = smaller.indices.max(by: { abs(smaller[$0] - sideMean) < abs(smaller[$1] - sideMean) }) {
                smaller.remove(at: extremeIndex)
                let recomputed = smallerIsLater
                    ? AtriaBehaviorImpact.mean(smaller) - AtriaBehaviorImpact.mean(best.earlier)
                    : AtriaBehaviorImpact.mean(best.later) - AtriaBehaviorImpact.mean(smaller)
                guard recomputed.sign == best.diff.sign else { return nil }
            }
        }

        return JournalInsight(questionID: questionID,
                              label: label,
                              kind: .thresholdSplit(splitMinutes: best.grid,
                                                    laterMeanDelta: best.diff,
                                                    earlierDays: best.earlier.count,
                                                    laterDays: best.later.count,
                                                    adjustedPValue: adjustedPValue))
    }

    /// Tie-exact Spearman (Pearson on average ranks) with a seeded permutation
    /// p-value: assumption-free, tie-native, and deterministic for tests.
    static func rankCorrelationInsight(questionID: String,
                                       label: String,
                                       pairs: [(x: Double, y: Double)]) -> JournalInsight? {
        guard pairs.count >= minimumCorrelationPairs,
              Set(pairs.map(\.x)).count >= minimumDistinctValues else { return nil }
        let xRanks = averageRanks(pairs.map(\.x))
        let yRanks = averageRanks(pairs.map(\.y))
        guard let observed = pearson(xRanks, yRanks) else { return nil }

        var rng = SplitMix64(state: fnv1aHash(questionID))
        var extremeCount = 0
        var shuffled = yRanks
        for _ in 0..<permutationCount {
            shuffled.shuffle(using: &rng)
            if let permuted = pearson(xRanks, shuffled), abs(permuted) >= abs(observed) - 1e-12 {
                extremeCount += 1
            }
        }
        let pValue = Double(1 + extremeCount) / Double(permutationCount + 1)
        guard abs(observed) >= minimumAbsRho, pValue <= maximumAdjustedPValue else { return nil }
        return JournalInsight(questionID: questionID,
                              label: label,
                              kind: .rankCorrelation(rho: observed, days: pairs.count, pValue: pValue))
    }

    /// Average ranks with tie groups sharing the mean of the ranks they span.
    static func averageRanks(_ values: [Double]) -> [Double] {
        let sortedIndices = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)
        var position = 0
        while position < sortedIndices.count {
            var end = position
            while end + 1 < sortedIndices.count,
                  values[sortedIndices[end + 1]] == values[sortedIndices[position]] {
                end += 1
            }
            let averageRank = Double(position + end) / 2 + 1
            for slot in position...end {
                ranks[sortedIndices[slot]] = averageRank
            }
            position = end + 1
        }
        return ranks
    }

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count > 1 else { return nil }
        let meanA = AtriaBehaviorImpact.mean(a)
        let meanB = AtriaBehaviorImpact.mean(b)
        var covariance = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for index in a.indices {
            let deltaA = a[index] - meanA
            let deltaB = b[index] - meanB
            covariance += deltaA * deltaB
            varianceA += deltaA * deltaA
            varianceB += deltaB * deltaB
        }
        guard varianceA > 0, varianceB > 0 else { return nil }
        return covariance / sqrt(varianceA * varianceB)
    }

    /// Stable across processes (Swift's Hasher is per-run randomized).
    private static func fnv1aHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash == 0 ? 0x9E3779B97F4A7C15 : hash
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
