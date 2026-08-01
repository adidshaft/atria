import Foundation

// Strength Log presentation math (design source: Claude Design "Atria App
// UI.dc.html", section 7 "STRENGTH LOG", 2026-08-01 design-parity slice 2):
//   7b — estimated 1RM progress: hero e1RM + 90-day delta, M/3M/6M/1Y/All
//        ranges, amber line/area chart with session dots and PR markers
//        (hollow for past PRs, solid for the newest), PR chips.
//   7c — exercise catalog: search, muscle-group chips, rows carrying the real
//        e1RM, recency and a sparkline of the exercise's own saved days.
//
// Honesty (hard constraint): every number here is derived from saved
// `LoggedSet`s through `AtriaStrengthLog` — Epley e1RM, `StrengthPersonalRecords`
// and the day-level `StrengthHistoryProjection`. Days whose best set cannot
// produce a real e1RM (no weight, or reps outside Epley's 1–12 band) are not
// plotted at all, and an exercise with fewer than three such days renders the
// learning state instead of a chart. Nothing is smoothed, extrapolated or
// sampled.
//
// This is deliberately SwiftUI-free so the point/marker selection and the
// three-session gate are unit-testable without a render pass.
enum AtriaStrengthProgressPresentation {
    /// A trend needs at least three real sessions before a line means
    /// anything; below that the surfaces say how many sets exist instead.
    static let minimumSessions = 3

    /// The design's hero delta window.
    static let deltaWindowDays = 90

    enum Range: String, CaseIterable, Identifiable {
        case month = "M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case year = "1Y"
        case all = "All"

        var id: String { rawValue }

        /// Nil means "everything saved".
        var days: Int? {
            switch self {
            case .month: return 30
            case .threeMonths: return 91
            case .sixMonths: return 183
            case .year: return 365
            case .all: return nil
            }
        }

        var accessibilityName: String {
            switch self {
            case .month: return "One month"
            case .threeMonths: return "Three months"
            case .sixMonths: return "Six months"
            case .year: return "One year"
            case .all: return "All saved days"
            }
        }
    }

    /// One saved day that produced a real Epley e1RM.
    struct Session: Equatable {
        let day: Date
        let e1RM: Double
        let weightKg: Double
        let reps: Int
        let setCount: Int
        /// True when this day's e1RM beat every earlier saved day — the
        /// definition the PR markers draw.
        let isPersonalRecord: Bool
    }

    /// Full lifetime series, oldest first, with PR flags resolved against
    /// everything logged before each day (never against the visible window).
    static func timeline(_ history: [StrengthHistoryDay]) -> [Session] {
        let ordered = history.sorted { $0.day < $1.day }
        var runningMax = 0.0
        var sessions: [Session] = []
        sessions.reserveCapacity(ordered.count)
        for entry in ordered {
            guard let e1RM = AtriaStrengthLog.estimatedOneRepMax(weightKg: entry.best.weightKg,
                                                                 reps: entry.best.reps),
                  let weight = entry.best.weightKg,
                  let reps = entry.best.reps else { continue }
            let isRecord = e1RM > runningMax
            runningMax = max(runningMax, e1RM)
            sessions.append(Session(day: entry.day,
                                    e1RM: e1RM,
                                    weightKg: weight,
                                    reps: reps,
                                    setCount: entry.setCount,
                                    isPersonalRecord: isRecord))
        }
        return sessions
    }

    /// The sessions a range shows. `.all` returns the timeline untouched.
    static func windowed(_ timeline: [Session], range: Range, now: Date) -> [Session] {
        guard let days = range.days else { return timeline }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return timeline.filter { $0.day >= cutoff }
    }

    /// Total sets logged across the whole timeline — the number the learning
    /// copy states.
    static func setCount(_ timeline: [Session]) -> Int {
        timeline.reduce(0) { $0 + $1.setCount }
    }

    struct Point: Equatable {
        let day: Date
        let e1RM: Double
        /// 0 (left/oldest) … 1 (right/newest).
        let x: Double
        /// 0 (bottom of the plotted band) … 1 (top).
        let y: Double
        let isPersonalRecord: Bool
        /// The most recent PR inside the window draws solid; earlier PRs draw
        /// hollow, exactly as the design specifies.
        let isNewestPersonalRecord: Bool
    }

    struct AxisLabel: Equatable {
        let fraction: Double
        let text: String
    }

    struct Chart: Equatable {
        let points: [Point]
        let lowValue: Double
        let highValue: Double
        /// Three y labels, top first.
        let yLabels: [Double]
        let xLabels: [AxisLabel]
    }

    /// Nil below the three-session floor: there is no honest line to draw.
    static func chart(for sessions: [Session], calendar: Calendar = .current) -> Chart? {
        guard sessions.count >= minimumSessions else { return nil }
        let values = sessions.map(\.e1RM)
        guard let rawLow = values.min(), let rawHigh = values.max() else { return nil }
        // A flat series still needs a band to sit in; pad it symmetrically so
        // the line renders mid-card instead of on the floor.
        let span = rawHigh - rawLow
        let padding = span < 0.5 ? max(2.5, rawHigh * 0.02) : span * 0.18
        let low = max(0, rawLow - padding)
        let high = rawHigh + padding
        let height = max(high - low, 0.001)

        let firstDay = sessions[0].day
        let lastDay = sessions[sessions.count - 1].day
        let span2 = max(lastDay.timeIntervalSince(firstDay), 1)
        let newestRecordDay = sessions.last(where: \.isPersonalRecord)?.day

        var points: [Point] = []
        points.reserveCapacity(sessions.count)
        for session in sessions {
            points.append(Point(day: session.day,
                                e1RM: session.e1RM,
                                x: session.day.timeIntervalSince(firstDay) / span2,
                                y: (session.e1RM - low) / height,
                                isPersonalRecord: session.isPersonalRecord,
                                isNewestPersonalRecord: session.isPersonalRecord
                                    && session.day == newestRecordDay))
        }
        return Chart(points: points,
                     lowValue: low,
                     highValue: high,
                     yLabels: [high, (high + low) / 2, low],
                     xLabels: monthLabels(from: firstDay, to: lastDay, span: span2, calendar: calendar))
    }

    /// Month ticks across the plotted span (design x-axis "Dec Jan Feb Mar").
    /// A window shorter than two months falls back to the two end dates.
    static func monthLabels(from first: Date,
                            to last: Date,
                            span: TimeInterval,
                            calendar: Calendar = .current) -> [AxisLabel] {
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.locale = .current
        monthFormatter.setLocalizedDateFormatFromTemplate("MMM")

        var starts: [Date] = []
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: first)) ?? first
        while cursor <= last {
            if cursor >= first { starts.append(cursor) }
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        if starts.count >= 2 {
            let stride = max(1, Int((Double(starts.count) / 4.0).rounded(.up)))
            var labels: [AxisLabel] = []
            for (index, start) in starts.enumerated() where index % stride == 0 {
                labels.append(AxisLabel(fraction: start.timeIntervalSince(first) / span,
                                        text: monthFormatter.string(from: start)))
            }
            return labels
        }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = .current
        dayFormatter.setLocalizedDateFormatFromTemplate("MMMd")
        return [AxisLabel(fraction: 0, text: dayFormatter.string(from: first)),
                AxisLabel(fraction: 1, text: dayFormatter.string(from: last))]
    }

    /// Change in e1RM over the delta window: newest session minus the most
    /// recent session at or before the cutoff. Nil when nothing was logged
    /// that far back — a delta needs two real ends, so the pill stays away.
    static func delta(_ timeline: [Session],
                      days: Int = deltaWindowDays,
                      now: Date) -> Double? {
        guard let latest = timeline.last else { return nil }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        guard let baseline = timeline.last(where: { $0.day <= cutoff }) else { return nil }
        return latest.e1RM - baseline.e1RM
    }

    /// Heaviest reps-at-a-weight record, e.g. 8 reps at 100 kg. Ties break to
    /// the heavier bar.
    static func repRecord(_ records: StrengthPersonalRecords) -> (reps: Int, weightKg: Double)? {
        var best: (reps: Int, weightKg: Double)?
        for (weight, reps) in records.maxRepsAtWeight {
            guard let current = best else {
                best = (reps, weight)
                continue
            }
            if reps > current.reps || (reps == current.reps && weight > current.weightKg) {
                best = (reps, weight)
            }
        }
        return best
    }

    // MARK: - Catalog

    struct CatalogRow: Identifiable, Equatable {
        let id: String
        let name: String
        let group: String
        let e1RM: Double?
        let lastLogged: Date?
        let sessionCount: Int
        let setCount: Int
        /// Normalized 0…1 sparkline values, oldest first. Empty until the
        /// exercise clears the three-session floor.
        let sparkline: [Double]
        let holdsCurrentRecord: Bool

        var hasEnoughHistory: Bool { sessionCount >= minimumSessions }
    }

    static func catalogRows(groups: [AtriaWorkoutExerciseGroup],
                            projection: StrengthHistoryProjection,
                            now: Date) -> [CatalogRow] {
        var rows: [CatalogRow] = []
        var seen = Set<String>()
        for group in groups {
            for exercise in group.exercises {
                let key = AtriaStrengthLog.normalized(exercise)
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                rows.append(catalogRow(name: exercise, group: group.title, projection: projection))
            }
        }
        // A lift that was logged under a name no longer in the groups still
        // owns real history, so it stays listed rather than disappearing.
        for exercise in projection.loggedExerciseNames {
            let key = AtriaStrengthLog.normalized(exercise)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            rows.append(catalogRow(name: exercise, group: "Logged", projection: projection))
        }
        return sortedByRecency(rows)
    }

    static func catalogRow(name: String,
                           group: String,
                           projection: StrengthHistoryProjection) -> CatalogRow {
        let sessions = timeline(projection.fullHistory(for: name))
        let records = projection.records(for: name)
        let enough = sessions.count >= minimumSessions
        return CatalogRow(id: AtriaStrengthLog.normalized(name),
                          name: name,
                          group: group,
                          e1RM: records.maxE1RM,
                          lastLogged: sessions.last?.day,
                          sessionCount: sessions.count,
                          setCount: setCount(sessions),
                          sparkline: enough ? sparkline(sessions) : [],
                          // A first-ever session trivially beats nothing, so a
                          // record badge only means something once the
                          // exercise has real history behind it.
                          holdsCurrentRecord: enough && (sessions.last?.isPersonalRecord ?? false))
    }

    /// Normalizes the last twelve sessions into 0…1 for the row sparkline.
    static func sparkline(_ sessions: [Session], limit: Int = 12) -> [Double] {
        let values = sessions.suffix(limit).map(\.e1RM)
        guard let low = values.min(), let high = values.max() else { return [] }
        let span = high - low
        guard span > 0.001 else { return values.map { _ in 0.5 } }
        return values.map { ($0 - low) / span }
    }

    static func sortedByRecency(_ rows: [CatalogRow]) -> [CatalogRow] {
        rows.sorted { left, right in
            switch (left.lastLogged, right.lastLogged) {
            case let (leftDate?, rightDate?):
                if leftDate != rightDate { return leftDate > rightDate }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
        }
    }

    static func filter(_ rows: [CatalogRow], search: String, group: String?) -> [CatalogRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            if let group, row.group != group { return false }
            guard !query.isEmpty else { return true }
            return row.name.localizedCaseInsensitiveContains(query)
        }
    }

    /// "today" / "yesterday" / "6 days ago" / "3 weeks ago" — real recency of
    /// the last saved set.
    static func recencyText(_ date: Date?, now: Date, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        switch days {
        case ..<0: return "today"
        case 0: return "today"
        case 1: return "yesterday"
        case 2...13: return "\(days) days ago"
        case 14...59: return "\(days / 7) weeks ago"
        default: return "\(max(2, days / 30)) months ago"
        }
    }

    /// Weight text shared by every strength surface: whole kilos, one decimal
    /// only when the plate math actually needs it.
    static func weightText(_ value: Double?) -> String {
        guard let value else { return "--" }
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded())) kg"
        }
        return String(format: "%.1f kg", rounded)
    }

    static func signedWeightText(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let magnitude = weightText(abs(rounded))
        if rounded > 0.05 { return "+\(magnitude)" }
        if rounded < -0.05 { return "\u{2212}\(magnitude)" }
        return "0 kg"
    }

    /// Learning line for an exercise under the three-session floor.
    static func learningText(sessions: Int, sets: Int) -> String {
        guard sets > 0 else { return "No sets logged yet" }
        return "Learning \u{00B7} \(sets) \(sets == 1 ? "set" : "sets") logged"
    }

    static func needMoreText(sessions: Int) -> String {
        let remaining = max(0, minimumSessions - sessions)
        guard remaining > 0 else { return "" }
        return "Need 3+ workouts \u{00B7} \(remaining) to go"
    }
}
