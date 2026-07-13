import Foundation

struct WeeklyPlanTarget: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case bedtimeConsistency
        case workoutCount
        case rhrInRange
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let goal: Double
    let current: Double

    var progress: Double {
        guard goal > 0 else { return 0 }
        return min(max(current / goal, 0), 1)
    }

    var progressText: String {
        "\(Int(min(current, goal).rounded()))/\(Int(goal.rounded()))"
    }
}

struct WeeklyPlan: Codable, Equatable {
    let isoYear: Int
    let isoWeek: Int
    let generatedAt: Date
    let targets: [WeeklyPlanTarget]

    /// Plain-language week label (e.g. "Jul 7–13") for the surface, instead of
    /// the ISO week number "W28" — nobody thinks in week-of-year (2026-07-08
    /// UX audit: jargon on the surface).
    var dateRangeText: String {
        let calendar = WeeklyPlanCalendar.iso
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: generatedAt) else { return "" }
        let end = calendar.date(byAdding: .day, value: 6, to: interval.start) ?? interval.start
        let startText = interval.start.formatted(.dateTime.month(.abbreviated).day())
        let endText = calendar.isDate(interval.start, equalTo: end, toGranularity: .month)
            ? end.formatted(.dateTime.day())
            : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(startText)–\(endText)"
    }

    init(rollups: [DailyRollupStoreEntry],
         now: Date = Date(),
         calendar: Calendar = WeeklyPlanCalendar.iso) {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        isoYear = components.yearForWeekOfYear ?? components.year ?? 0
        isoWeek = components.weekOfYear ?? 0
        generatedAt = now
        targets = Self.generate(from: rollups, now: now, calendar: calendar)
    }

    static func generate(from rollups: [DailyRollupStoreEntry],
                         now: Date = Date(),
                         calendar: Calendar = WeeklyPlanCalendar.iso) -> [WeeklyPlanTarget] {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let windows = rollupWindows(rollups: rollups, weekStart: weekStart, recentLimit: 28)
        let candidates = [
            bedtimeTarget(recent28: windows.recent, currentWeek: windows.currentWeek),
            workoutTarget(recent28: windows.recent, currentWeek: windows.currentWeek),
            rhrTarget(recent28: windows.recent, currentWeek: windows.currentWeek)
        ]
        return candidates
            .sorted { first, second in
                let firstGap = first.goal - first.current
                let secondGap = second.goal - second.current
                if firstGap == secondGap { return first.id < second.id }
                return firstGap > secondGap
            }
            .prefix(3)
            .map { $0 }
    }

    private static func rollupWindows(rollups: [DailyRollupStoreEntry],
                                      weekStart: Date,
                                      recentLimit: Int) -> (recent: [DailyRollupStoreEntry], currentWeek: [DailyRollupStoreEntry]) {
        guard recentLimit > 0 else {
            return ([], rollups.filter { $0.day >= weekStart })
        }
        var recent: [DailyRollupStoreEntry] = []
        var currentWeek: [DailyRollupStoreEntry] = []

        for entry in rollups {
            if entry.day >= weekStart {
                currentWeek.append(entry)
            }
            if recent.count < recentLimit {
                insertRecentEntry(entry, into: &recent)
            } else if let oldest = recent.last, entry.day > oldest.day {
                recent.removeLast()
                insertRecentEntry(entry, into: &recent)
            }
        }

        return (recent, currentWeek)
    }

    private static func insertRecentEntry(_ entry: DailyRollupStoreEntry,
                                          into recent: inout [DailyRollupStoreEntry]) {
        let index = recent.firstIndex { $0.day < entry.day } ?? recent.endIndex
        recent.insert(entry, at: index)
    }

    private static func bedtimeTarget(recent28: [DailyRollupStoreEntry],
                                      currentWeek: [DailyRollupStoreEntry]) -> WeeklyPlanTarget {
        let bedtimeMinutes = recent28.compactMap(\.bedtimeMinutes)
        let median = medianMinute(bedtimeMinutes) ?? 23 * 60
        let target = (median + 20) % 1_440
        let current = Double(currentWeek.filter { entry in
            guard let minute = entry.bedtimeMinutes else { return false }
            return minuteIsNoLater(minute, than: target)
        }.count)
        return WeeklyPlanTarget(id: WeeklyPlanTarget.Kind.bedtimeConsistency.rawValue,
                                kind: .bedtimeConsistency,
                                title: "Lights out by \(formatClockMinute(target)) x4",
                                detail: "Based on your recent bedtime rhythm",
                                goal: 4,
                                current: current)
    }

    private static func workoutTarget(recent28: [DailyRollupStoreEntry],
                                      currentWeek: [DailyRollupStoreEntry]) -> WeeklyPlanTarget {
        let strainDays = recent28.filter { ($0.strain ?? 0) >= 10 }.count
        let goal = strainDays >= 6 ? 2.0 : 1.0
        let current = Double(currentWeek.filter { ($0.strain ?? 0) >= 10 }.count)
        return WeeklyPlanTarget(id: WeeklyPlanTarget.Kind.workoutCount.rawValue,
                                kind: .workoutCount,
                                title: "\(Int(goal)) workouts >= 10 strain",
                                detail: "Auto-counted from saved strain days",
                                goal: goal,
                                current: current)
    }

    private static func rhrTarget(recent28: [DailyRollupStoreEntry],
                                  currentWeek: [DailyRollupStoreEntry]) -> WeeklyPlanTarget {
        let current = Double(currentWeek.filter { entry in
            guard let rhr = entry.rhr,
                  let stat = entry.vitals?.rhr,
                  stat.sd > 0 else { return false }
            return abs((Double(rhr) - stat.mean) / stat.sd) <= 1.5
        }.count)
        let trustedDays = recent28.filter { $0.vitals?.rhr != nil && $0.rhr != nil }.count
        let goal = trustedDays >= 7 ? 7.0 : 4.0
        return WeeklyPlanTarget(id: WeeklyPlanTarget.Kind.rhrInRange.rawValue,
                                kind: .rhrInRange,
                                title: "Keep RHR in range",
                                detail: "Morning RHR versus your typical range",
                                goal: goal,
                                current: current)
    }

    private static func medianMinute(_ minutes: [Int]) -> Int? {
        guard !minutes.isEmpty else { return nil }
        let normalized = minutes.map { minute -> Int in
            let wrapped = ((minute % 1_440) + 1_440) % 1_440
            return wrapped < 720 ? wrapped + 1_440 : wrapped
        }.sorted()
        return normalized[normalized.count / 2] % 1_440
    }

    private static func minuteIsNoLater(_ minute: Int, than target: Int) -> Bool {
        let normalized = normalizeBedtimeMinute(minute)
        let normalizedTarget = normalizeBedtimeMinute(target)
        return normalized <= normalizedTarget
    }

    private static func normalizeBedtimeMinute(_ minute: Int) -> Int {
        let wrapped = ((minute % 1_440) + 1_440) % 1_440
        return wrapped < 720 ? wrapped + 1_440 : wrapped
    }

    private static func formatClockMinute(_ minute: Int) -> String {
        let wrapped = ((minute % 1_440) + 1_440) % 1_440
        let hour = wrapped / 60
        let minutes = wrapped % 60
        let suffix = hour >= 12 ? "PM" : "AM"
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", displayHour, minutes, suffix)
    }
}

final class WeeklyPlanStore {
    private struct CacheKey: Hashable {
        let isoYear: Int
        let isoWeek: Int
    }

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedPlans: [CacheKey: WeeklyPlan] = [:]

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        if let directory {
            self.directory = directory
        } else {
            let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directory = documents
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func currentPlan(rollups: [DailyRollupStoreEntry],
                     now: Date = Date(),
                     calendar: Calendar = WeeklyPlanCalendar.iso) -> WeeklyPlan {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let year = components.yearForWeekOfYear ?? components.year ?? 0
        let week = components.weekOfYear ?? 0
        if let saved = plan(isoYear: year, isoWeek: week) {
            let freshByKind = Dictionary(uniqueKeysWithValues: WeeklyPlan.generate(from: rollups,
                                                                                   now: now,
                                                                                   calendar: calendar)
                .map { ($0.kind, $0) })
            return WeeklyPlan(isoYear: saved.isoYear,
                              isoWeek: saved.isoWeek,
                              generatedAt: saved.generatedAt,
                              targets: saved.targets.map { target in
                                  guard let fresh = freshByKind[target.kind] else { return target }
                                  return WeeklyPlanTarget(id: target.id,
                                                          kind: target.kind,
                                                          title: target.title,
                                                          detail: target.detail,
                                                          goal: target.goal,
                                                          current: fresh.current)
                              })
        }
        let plan = WeeklyPlan(rollups: rollups, now: now, calendar: calendar)
        save(plan)
        return plan
    }

    func plan(isoYear: Int, isoWeek: Int) -> WeeklyPlan? {
        let key = CacheKey(isoYear: isoYear, isoWeek: isoWeek)
        if let cached = cachedPlans[key] {
            return cached
        }
        let url = urlForPlan(isoYear: isoYear, isoWeek: isoWeek)
        guard let data = try? Data(contentsOf: url),
              let plan = try? decoder.decode(WeeklyPlan.self, from: data) else { return nil }
        cachedPlans[key] = plan
        return plan
    }

    func save(_ plan: WeeklyPlan) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(plan)
            try data.write(to: urlForPlan(isoYear: plan.isoYear, isoWeek: plan.isoWeek), options: .atomic)
            cachedPlans[CacheKey(isoYear: plan.isoYear, isoWeek: plan.isoWeek)] = plan
            AtriaDebugLog("ATRIADBG weekly_plan_store_save status=ok isoYear=%d isoWeek=%d targets=%d",
                          plan.isoYear,
                          plan.isoWeek,
                          plan.targets.count)
        } catch {
            AtriaDebugLog("ATRIADBG weekly_plan_store_save status=failed error=%@",
                          error.localizedDescription)
        }
    }

    private func urlForPlan(isoYear: Int, isoWeek: Int) -> URL {
        directory.appendingPathComponent("weekly-plan-\(isoYear)-W\(isoWeek).json")
    }
}

private enum WeeklyPlanCalendar {
    static let iso: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }()
}

private extension WeeklyPlan {
    init(isoYear: Int, isoWeek: Int, generatedAt: Date, targets: [WeeklyPlanTarget]) {
        self.isoYear = isoYear
        self.isoWeek = isoWeek
        self.generatedAt = generatedAt
        self.targets = targets
    }
}
