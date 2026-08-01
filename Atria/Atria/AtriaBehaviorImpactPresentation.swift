import Foundation

// Behavior Impact (design source: Claude Design "Atria App UI.dc.html",
// section 8 "BEHAVIOR IMPACT" and section 9 "IMPACT MAP" — 2026-08-01
// design-parity slice 3).
//
// THE SIGNIFICANCE GATE IS THE SURFACE. A behavior earns a bar only when it
// has at least `AtriaBehaviorImpact.minimumLoggedDays` logged nights, the same
// minimum of quiet nights on the other side (Welch needs two populated sides),
// and a two-sided p below `AtriaBehaviorImpact.maximumPValue`. Everything that
// misses the gate is still printed — as "learning", with its real night count.
// Nothing is hidden and nothing is promoted.
//
// This deliberately does NOT reuse `AtriaBehaviorImpact.summaries`. That engine
// adds a >=3-point magnitude floor for the compact Today strip, which would
// silently contradict this screen's printed footer ("Only behaviors with >=5
// logged nights and p < 0.10 are shown"). The statistic itself is the identical
// Welch two-sample test from `AtriaBehaviorImpact`, so the two surfaces can
// never disagree about a NUMBER — only about how many rows they choose to
// print, which the footer states out loud.
//
// Honesty rules that shape the math below:
//   * every value comes from the real journal + the real daily metric history;
//     there is no sample data path, in DEBUG or otherwise.
//   * a night only participates if it has a real recovery score. Missing
//     recovery is a missing night, not a zero.
//   * deep-sleep deltas are computed ONLY from nights with validated stage
//     evidence. HR-only stage segments still exist in storage (see
//     `stageSegmentsForStorage`), but the 2026-08-01 presentation honesty pass
//     withholds them from display, so they must not become a "-34 min" claim
//     here either.
enum AtriaBehaviorImpactPresentation {
    /// One scored night: the recovery it produced plus the vitals that can
    /// explain a shift. `recoveryPercent` is non-optional by construction —
    /// unscored nights never become a `Night`.
    struct Night: Equatable {
        let day: Date
        let recoveryPercent: Int
        let hrv: Int?
        let restingHR: Int?
        /// Minutes of deep sleep, present only when the night's stages are
        /// validated. Nil for HR-only/estimated nights (see file header).
        let validatedDeepSleepMinutes: Int?
    }

    /// How a behavior reads on the Journal impact map (spec 9).
    enum Classification: String, Equatable {
        case supports
        case watch
        case noEffectYet

        var label: String {
            switch self {
            case .supports: return "Supports"
            case .watch: return "Watch"
            case .noEffectYet: return "No effect yet"
            }
        }
    }

    /// Every behavior that was logged at least once inside the window, with the
    /// full two-sample comparison behind it — gated or not.
    struct Stat: Identifiable, Equatable {
        let tag: BehaviorJournalEntry.Tag
        let loggedNights: Int
        let quietNights: Int
        let loggedMeanRecovery: Double
        let quietMeanRecovery: Double
        /// Nil when the comparison is not computable (a side is empty), which is
        /// itself a "learning" state rather than a p of 1.
        let pValue: Double?

        var id: String { tag.rawValue }

        /// Signed effect on next-day recovery, in recovery points.
        var impact: Double { loggedMeanRecovery - quietMeanRecovery }

        /// The law. Both sides must clear the night minimum and p must be
        /// strictly below the threshold — "p < 0.10", exactly as printed.
        var passesSignificanceGate: Bool {
            guard loggedNights >= AtriaBehaviorImpact.minimumLoggedDays,
                  quietNights >= AtriaBehaviorImpact.minimumComparisonDays,
                  let pValue else { return false }
            return pValue < AtriaBehaviorImpact.maximumPValue
        }

        var classification: Classification {
            guard passesSignificanceGate else { return .noEffectYet }
            return impact >= 0 ? .supports : .watch
        }

        /// "+5.8%" / "-4.9%" — one decimal, matching the design's row values.
        var impactText: String { String(format: "%+.1f%%", impact) }

        var pText: String { AtriaBehaviorImpactPresentation.pText(pValue) }

        /// The p column of the evidence table: a real p only once the row has
        /// earned one, otherwise the app's canonical not-ready word.
        var evidencePText: String { passesSignificanceGate ? pText : "learning" }

        var nightsText: String {
            loggedNights == 1 ? "1 night" : "\(loggedNights) nights"
        }

        /// The design's top-mover sentence, with this behavior's real counts.
        var topMoverSentence: String {
            "On the \(loggedNights) nights you logged \(tag.label.lowercased()), "
                + "next-day recovery averaged \(impactText) vs the other \(quietNights) nights."
        }
    }

    /// Recovery distribution for one side of a drill-in, in five fixed 20-point
    /// bins. Fixed bins (not data-derived) so the quiet and logged histograms
    /// are read against the same ruler.
    struct Distribution: Equatable {
        static let binCount = 5

        let bins: [Int]
        let nights: Int
        let meanRecovery: Double

        var peak: Int { bins.max() ?? 0 }

        /// Share of THIS side's nights in each bin. The two sides of a drill-in
        /// almost never have the same night count (12 logged vs 48 quiet is
        /// typical), so raw counts would draw the smaller side as a flat smear
        /// and hide the very shape the screen exists to compare.
        var shares: [Double] {
            guard nights > 0 else { return Array(repeating: 0, count: bins.count) }
            return bins.map { Double($0) / Double(nights) }
        }

        var peakShare: Double { shares.max() ?? 0 }

        static let empty = Distribution(bins: Array(repeating: 0, count: binCount),
                                        nights: 0,
                                        meanRecovery: 0)
    }

    /// One "WHAT SHIFTS ON THOSE NIGHTS" row. Only emitted when BOTH sides
    /// carry enough real readings of that metric.
    struct MetricShift: Identifiable, Equatable {
        enum Metric: String, Equatable {
            case hrv
            case restingHR
            case deepSleep

            var label: String {
                switch self {
                case .hrv: return "HRV"
                case .restingHR: return "Resting HR"
                case .deepSleep: return "Deep sleep"
                }
            }

            var unit: String {
                switch self {
                case .hrv: return "ms"
                case .restingHR: return "bpm"
                case .deepSleep: return "min"
                }
            }
        }

        let metric: Metric
        let delta: Double
        let loggedNights: Int
        let quietNights: Int

        var id: String { metric.rawValue }

        var deltaText: String { String(format: "%+.0f %@", delta, metric.unit) }
    }

    /// A logged night, for the drill-in's "see nights" list.
    struct LoggedNight: Identifiable, Equatable {
        let day: Date
        let recoveryPercent: Int

        var id: Date { day }
    }

    struct Detail: Equatable {
        let tag: BehaviorJournalEntry.Tag
        let quiet: Distribution
        let logged: Distribution
        let shifts: [MetricShift]
        let loggedNightList: [LoggedNight]
    }

    struct Model: Equatable {
        /// Every behavior logged at least once in the window, significant rows
        /// first (largest absolute effect first), then the learning rows by
        /// evidence weight.
        let stats: [Stat]
        /// Drill-in payloads, keyed by tag raw value. Precomputed for the gated
        /// rows only — a sheet must never do this work inside a view body.
        let details: [String: Detail]
        /// Nights in the window that carry a real recovery score.
        let scoredNights: Int
        /// Scored nights that also carry at least one journal tag.
        let loggedNights: Int

        static let empty = Model(stats: [], details: [:], scoredNights: 0, loggedNights: 0)

        var significant: [Stat] { stats.filter(\.passesSignificanceGate) }

        var topMover: Stat? { significant.first }

        /// Design axis is -8% .. +8%; a real effect larger than that widens the
        /// axis rather than clipping the bar.
        var axisMagnitude: Double {
            let largest = significant.map { abs($0.impact) }.max() ?? 0
            return max(8, largest.rounded(.up))
        }

        /// Fraction of the half-track a row's bar fills (0...1).
        func barFraction(for stat: Stat) -> Double {
            guard axisMagnitude > 0 else { return 0 }
            return min(1, abs(stat.impact) / axisMagnitude)
        }

        /// Evidence table rows: the gated ones plus the most-logged learning
        /// rows, so the table always shows what the app is still working on.
        func evidenceRows(limit: Int = 6) -> [Stat] {
            Array(stats.prefix(max(limit, significant.count)))
        }

        /// Impact-map rows (spec 9). Same ordering as the evidence table.
        func mapRows(limit: Int = 6) -> [Stat] {
            Array(stats.prefix(limit))
        }
    }

    // MARK: - Formatting

    static func pText(_ pValue: Double?) -> String {
        guard let pValue else { return "learning" }
        if pValue < 0.01 { return "p < 0.01" }
        return String(format: "p = %.2f", pValue)
    }

    /// Verbatim from the design file. Pinned by the static gate — do not reword.
    static let significanceFooter =
        "Only behaviors with ≥5 logged nights and p < 0.10 are shown. "
        + "Association, not proof — keep logging to sharpen it."

    static let mapEmptyText = "Impact map appears once behaviors and outcomes overlap in your history."

    static let framing = "Next-day recovery · last 90 days"

    // MARK: - Inputs

    /// Real daily metric rows → scored nights. A row without a recovery score is
    /// dropped entirely; it cannot vote on either side of a comparison.
    static func nights(from metrics: [SavedDailyMetric],
                       calendar: Calendar = .current) -> [Night] {
        metrics.compactMap { metric in
            guard let recovery = metric.recoveryPercent else { return nil }
            return Night(day: calendar.startOfDay(for: metric.day),
                         recoveryPercent: recovery,
                         hrv: metric.hrv,
                         restingHR: metric.restingHR,
                         validatedDeepSleepMinutes: validatedDeepSleepMinutes(for: metric))
        }
    }

    /// Deep sleep is only claimable when the night's stages carry validated
    /// evidence — `SleepStageEvidence.validated` is derived from exactly this
    /// source string (see `stageEvidence(source:confirmed:hasSegments:)`).
    static func validatedDeepSleepMinutes(for metric: SavedDailyMetric) -> Int? {
        guard metric.sleepSource == "validated_sleep_stages",
              !metric.sleepStageSegments.isEmpty else { return nil }
        let seconds = metric.sleepStageSegments
            .filter { $0.stage.displayStage == .deep }
            .reduce(0) { $0 + $1.duration }
        return Int((seconds / 60).rounded())
    }

    // MARK: - Model

    static func model(nights: [Night],
                      journalEntries: [BehaviorJournalEntry],
                      referenceDate: Date? = nil,
                      calendar: Calendar = .current) -> Model {
        let latest = referenceDate
            ?? (nights.map(\.day) + journalEntries.map(\.day)).max()
            ?? Date()
        let referenceDay = calendar.startOfDay(for: latest)
        let windowStart = calendar.date(byAdding: .day,
                                        value: -AtriaBehaviorImpact.trailingWindowDays,
                                        to: referenceDay)
            ?? referenceDay.addingTimeInterval(TimeInterval(-AtriaBehaviorImpact.trailingWindowDays * 24 * 60 * 60))

        // One night per day, same pairing convention as AtriaBehaviorImpact.
        var nightsByDay: [Date: Night] = [:]
        for night in nights {
            let key = calendar.startOfDay(for: night.day)
            guard key >= windowStart, key <= referenceDay else { continue }
            if nightsByDay[key] == nil { nightsByDay[key] = night }
        }
        guard !nightsByDay.isEmpty else { return .empty }

        let windowedEntries = journalEntries.filter {
            let day = calendar.startOfDay(for: $0.day)
            return day >= windowStart && day <= referenceDay
        }
        var loggedDaysByTag: [BehaviorJournalEntry.Tag: Set<Date>] = [:]
        var anyLoggedDays: Set<Date> = []
        for entry in windowedEntries {
            let day = calendar.startOfDay(for: entry.day)
            guard nightsByDay[day] != nil, !entry.tags.isEmpty else { continue }
            anyLoggedDays.insert(day)
            for tag in entry.tags {
                loggedDaysByTag[tag, default: []].insert(day)
            }
        }

        var stats: [Stat] = []
        for tag in BehaviorJournalEntry.Tag.allCases {
            guard let loggedDays = loggedDaysByTag[tag], !loggedDays.isEmpty else { continue }
            let logged = nightsByDay.filter { loggedDays.contains($0.key) }.map(\.value)
            let quiet = nightsByDay.filter { !loggedDays.contains($0.key) }.map(\.value)
            let loggedRecovery = logged.map { Double($0.recoveryPercent) }
            let quietRecovery = quiet.map { Double($0.recoveryPercent) }
            let pValue = (loggedRecovery.count >= 2 && quietRecovery.count >= 2)
                ? AtriaBehaviorImpact.welchTwoSidedPValue(loggedRecovery, quietRecovery)
                : nil
            stats.append(Stat(tag: tag,
                              loggedNights: loggedRecovery.count,
                              quietNights: quietRecovery.count,
                              loggedMeanRecovery: loggedRecovery.isEmpty ? 0 : AtriaBehaviorImpact.mean(loggedRecovery),
                              quietMeanRecovery: quietRecovery.isEmpty ? 0 : AtriaBehaviorImpact.mean(quietRecovery),
                              pValue: pValue))
        }

        stats.sort { lhs, rhs in
            if lhs.passesSignificanceGate != rhs.passesSignificanceGate {
                return lhs.passesSignificanceGate
            }
            if lhs.passesSignificanceGate {
                if abs(lhs.impact) != abs(rhs.impact) { return abs(lhs.impact) > abs(rhs.impact) }
            } else if lhs.loggedNights != rhs.loggedNights {
                return lhs.loggedNights > rhs.loggedNights
            }
            return lhs.tag.rawValue < rhs.tag.rawValue
        }

        var details: [String: Detail] = [:]
        for stat in stats where stat.passesSignificanceGate {
            let loggedDays = loggedDaysByTag[stat.tag] ?? []
            details[stat.tag.rawValue] = detail(tag: stat.tag,
                                                nightsByDay: nightsByDay,
                                                loggedDays: loggedDays)
        }

        return Model(stats: stats,
                     details: details,
                     scoredNights: nightsByDay.count,
                     loggedNights: anyLoggedDays.count)
    }

    static func detail(tag: BehaviorJournalEntry.Tag,
                       nightsByDay: [Date: Night],
                       loggedDays: Set<Date>) -> Detail {
        let logged = nightsByDay.filter { loggedDays.contains($0.key) }.map(\.value)
        let quiet = nightsByDay.filter { !loggedDays.contains($0.key) }.map(\.value)
        return Detail(tag: tag,
                      quiet: distribution(for: quiet),
                      logged: distribution(for: logged),
                      shifts: shifts(logged: logged, quiet: quiet),
                      loggedNightList: logged
                          .sorted { $0.day > $1.day }
                          .map { LoggedNight(day: $0.day, recoveryPercent: $0.recoveryPercent) })
    }

    static func distribution(for nights: [Night]) -> Distribution {
        guard !nights.isEmpty else { return .empty }
        var bins = Array(repeating: 0, count: Distribution.binCount)
        for night in nights {
            let clamped = min(max(night.recoveryPercent, 0), 100)
            let index = min(Distribution.binCount - 1, clamped / 20)
            bins[index] += 1
        }
        return Distribution(bins: bins,
                            nights: nights.count,
                            meanRecovery: AtriaBehaviorImpact.mean(nights.map { Double($0.recoveryPercent) }))
    }

    /// A shift row needs the SAME night minimum as the headline gate on both
    /// sides. A metric that only a handful of nights recorded stays absent
    /// rather than being averaged into a confident-looking delta.
    static func shifts(logged: [Night], quiet: [Night]) -> [MetricShift] {
        var rows: [MetricShift] = []
        func append(_ metric: MetricShift.Metric, _ value: @escaping (Night) -> Double?) {
            let loggedValues = logged.compactMap(value)
            let quietValues = quiet.compactMap(value)
            guard loggedValues.count >= AtriaBehaviorImpact.minimumLoggedDays,
                  quietValues.count >= AtriaBehaviorImpact.minimumComparisonDays else { return }
            let delta = AtriaBehaviorImpact.mean(loggedValues) - AtriaBehaviorImpact.mean(quietValues)
            rows.append(MetricShift(metric: metric,
                                    delta: delta,
                                    loggedNights: loggedValues.count,
                                    quietNights: quietValues.count))
        }
        append(.hrv) { $0.hrv.map(Double.init) }
        append(.restingHR) { $0.restingHR.map(Double.init) }
        append(.deepSleep) { $0.validatedDeepSleepMinutes.map(Double.init) }
        return rows
    }
}
