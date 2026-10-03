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
    /// Non-nil while the target has too little history to be real (the
    /// bedtime target needs `WeeklyPlan.minimumBedtimeNights` recorded
    /// bedtimes). Optional so plans saved before 2026-09-02 still decode.
    var learningNightsRemaining: Int? = nil
    /// The minimum the learning state is counting toward, stored with the
    /// target so the row can print "1 of 3 nights" without reaching back
    /// into plan constants (2026-09-02). Optional for the same decode reason.
    var learningNightsNeeded: Int? = nil
    /// The bedtime target's clock minute, stored with the target (2026-09-02)
    /// so a saved plan can be checked against a fresh one: a target minted by
    /// the old noon-cut median has no stored minute and is replaced mid-week
    /// instead of standing as "Lights out by 1:21 AM" for an afternoon
    /// sleeper (device, W36). Optional so earlier plans still decode.
    var targetMinute: Int? = nil
    /// Set when the target was withheld rather than minted: the recorded
    /// bedtimes form no cluster to name a time from (device 2026-09-02:
    /// 24 bedtimes split between afternoon and pre-dawn minted "Lights out
    /// by 6:35 AM", a time only 3 of them sat near). Renders as Learning.
    var withheldReason: String? = nil
    var isWithheld: Bool { withheldReason != nil }

    var isLearning: Bool { learningNightsRemaining != nil }

    /// Learning shown as a count on the gauge, the same shape every other
    /// learning state uses, instead of the word alone. nil when not learning
    /// or when the minimum was not recorded with the target.
    var learningProgressText: String? {
        guard let remaining = learningNightsRemaining, let needed = learningNightsNeeded, needed > 0 else { return nil }
        let recorded = min(needed, max(0, needed - remaining))
        let unit = kind == .rhrInRange ? "mornings" : "nights"
        return "\(recorded) of \(needed) \(unit)"
    }

    var learningProgress: Double {
        guard let remaining = learningNightsRemaining, let needed = learningNightsNeeded, needed > 0 else { return 0 }
        return Double(min(needed, max(0, needed - remaining))) / Double(needed)
    }

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
                // Actionable targets first; a learning row has nothing to do
                // yet and should not push the one real target off the card
                // (on a fresh install two learning rows sat above it).
                let firstIdle = first.isLearning || first.isWithheld
                let secondIdle = second.isLearning || second.isWithheld
                if firstIdle != secondIdle { return !firstIdle }
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

    /// Fewer recorded bedtimes than this and there is no rhythm to base a
    /// target on. The old fallback quietly used 23:00 and still captioned it
    /// "Based on your recent bedtime rhythm" (2026-09-02 fresh-install
    /// screenshot: "Lights out by 11:20 PM · 4 nights" with zero nights).
    static let minimumBedtimeNights = 3
    /// A bedtime target needs a rhythm: at least half of the recorded
    /// bedtimes (and never fewer than `minimumBedtimeNights`) within this
    /// many minutes of the circular median, on either side.
    static let bedtimeClusterWindowMinutes = 90
    /// Trusted RHR mornings needed before the RHR-range target is real.
    static let minimumTrustedRHRDays = 3

    private static func bedtimeTarget(recent28: [DailyRollupStoreEntry],
                                      currentWeek: [DailyRollupStoreEntry]) -> WeeklyPlanTarget {
        let bedtimeMinutes = recent28.compactMap(\.bedtimeMinutes)
        guard bedtimeMinutes.count >= minimumBedtimeNights,
              let median = circularMedianMinute(bedtimeMinutes) else {
            let recorded = bedtimeMinutes.count
            return WeeklyPlanTarget(id: WeeklyPlanTarget.Kind.bedtimeConsistency.rawValue,
                                    kind: .bedtimeConsistency,
                                    title: "Lights-out target",
                                    detail: "Needs \(minimumBedtimeNights) recorded bedtimes (\(recorded) so far)",
                                    goal: 4,
                                    current: 0,
                                    learningNightsRemaining: max(0, minimumBedtimeNights - recorded),
                                    learningNightsNeeded: minimumBedtimeNights)
        }
        let clustered = bedtimeMinutes.filter {
            circularMinuteDistance($0, median) <= bedtimeClusterWindowMinutes
        }.count
        guard clustered >= minimumBedtimeNights, clustered * 2 >= bedtimeMinutes.count else {
            return WeeklyPlanTarget(id: WeeklyPlanTarget.Kind.bedtimeConsistency.rawValue,
                                    kind: .bedtimeConsistency,
                                    title: "Lights-out target",
                                    detail: "No steady bedtime in the last 28 nights",
                                    goal: 4,
                                    current: 0,
                                    withheldReason: "scattered_bedtimes")
        }
        let target = (median + 20) % 1_440
        let current = Double(currentWeek.filter { entry in
            guard let minute = entry.bedtimeMinutes else { return false }
            return minuteIsNoLater(minute, than: target)
        }.count)
        return WeeklyPlanTarget(id: WeeklyPlanTarget.Kind.bedtimeConsistency.rawValue,
                                kind: .bedtimeConsistency,
                                title: "Lights out by \(formatClockMinute(target)) · 4 nights",
                                detail: "Based on your recent bedtime rhythm",
                                goal: 4,
                                current: current,
                                targetMinute: target)
    }

    private static func workoutTarget(recent28: [DailyRollupStoreEntry],
                                      currentWeek: [DailyRollupStoreEntry]) -> WeeklyPlanTarget {
        let strainDays = recent28.filter { ($0.strain ?? 0) >= 10 }.count
        let goal = strainDays >= 6 ? 2.0 : 1.0
        let current = Double(currentWeek.filter { ($0.strain ?? 0) >= 10 }.count)
        return WeeklyPlanTarget(id: WeeklyPlanTarget.Kind.workoutCount.rawValue,
                                kind: .workoutCount,
                                title: "\(Int(goal)) \(Int(goal) == 1 ? "workout" : "workouts") of 10+ strain",
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
        // No trusted RHR days means no "typical range" to keep — "0/4" implied
        // four failed mornings on a fresh install (2026-09-02). Same learning
        // shape as the bedtime target until the baseline has a few days.
        guard trustedDays >= minimumTrustedRHRDays else {
            return WeeklyPlanTarget(id: WeeklyPlanTarget.Kind.rhrInRange.rawValue,
                                    kind: .rhrInRange,
                                    title: "RHR range target",
                                    detail: "Needs \(minimumTrustedRHRDays) mornings with a trusted RHR (\(trustedDays) so far)",
                                    goal: 4,
                                    current: 0,
                                    learningNightsRemaining: minimumTrustedRHRDays - trustedDays,
                                    learningNightsNeeded: minimumTrustedRHRDays)
        }
        let goal = trustedDays >= 7 ? 7.0 : 4.0
        return WeeklyPlanTarget(id: WeeklyPlanTarget.Kind.rhrInRange.rawValue,
                                kind: .rhrInRange,
                                title: "Keep RHR in range",
                                detail: "Morning RHR versus your typical range",
                                goal: goal,
                                current: current)
    }

    /// The recorded bedtime with the smallest total distance round the clock
    /// to every other one — always a real night's minute, and the same answer
    /// whichever side of midnight or noon the nights fall. The previous median
    /// added 24h to anything before noon, which put an afternoon sleeper's
    /// 11:28 and 12:08 a day apart (the same defect as issue #41).
    static func circularMedianMinute(_ minutes: [Int]) -> Int? {
        guard !minutes.isEmpty else { return nil }
        let wrapped = minutes.map { (($0 % 1_440) + 1_440) % 1_440 }
        var best: (minute: Int, cost: Int)?
        for candidate in wrapped.sorted() {
            let cost = wrapped.reduce(0) { $0 + circularMinuteDistance($1, candidate) }
            if let current = best, current.cost <= cost { continue }
            best = (candidate, cost)
        }
        return best?.minute
    }

    /// True when a saved bedtime target should yield to the freshly computed
    /// one mid-week: it carries no clock minute (minted before minutes were
    /// stored, by the noon-cut median) or sits more than three hours from the
    /// fresh minute on the clock. Learning targets are handled before this.
    static func savedBedtimeTargetIsStale(_ saved: WeeklyPlanTarget, fresh: WeeklyPlanTarget) -> Bool {
        guard saved.kind == .bedtimeConsistency, !saved.isLearning else { return false }
        guard let savedMinute = saved.targetMinute else { return true }
        // A fresh answer with no time at all (withheld: the bedtimes no
        // longer cluster) outranks a saved time the clock would not mint now.
        guard let freshMinute = fresh.targetMinute else { return fresh.isWithheld }
        return circularMinuteDistance(savedMinute, freshMinute) > 180
    }

    static func circularMinuteDistance(_ a: Int, _ b: Int) -> Int {
        let d = (((a - b) % 1_440) + 1_440) % 1_440
        return min(d, 1_440 - d)
    }

    /// "No later than the target" means within the twelve hours that end at
    /// the target, on the clock — so 11:28 counts against a 13:35 target and
    /// 23:00 counts against 00:20, without assuming when the day begins.
    static func minuteIsNoLater(_ minute: Int, than target: Int) -> Bool {
        var delta = (((minute - target) % 1_440) + 1_440) % 1_440
        if delta > 720 { delta -= 1_440 }
        return delta <= 0
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
            let rebuilt: [WeeklyPlanTarget] = saved.targets.map { target in
                                  guard let fresh = freshByKind[target.kind] else { return target }
                                  // A saved "learning" target is not a commitment
                                  // for the week; the moment enough bedtimes exist
                                  // the real target replaces it.
                                  if target.isLearning || target.isWithheld { return fresh }
                                  // A saved bedtime target that the current clock
                                  // arithmetic would never mint is a defect, not a
                                  // commitment: no stored minute (pre-2026-09-02
                                  // noon-cut median) or more than three hours from
                                  // the fresh answer on the clock. Re-mint it.
                                  if WeeklyPlan.savedBedtimeTargetIsStale(target, fresh: fresh) { return fresh }
                                  return WeeklyPlanTarget(id: target.id,
                                                          kind: target.kind,
                                                          title: target.title,
                                                          detail: target.detail,
                                                          goal: target.goal,
                                                          current: fresh.current,
                                                          targetMinute: target.targetMinute)
                              }
            // Actionable rows keep the saved week's order; a row that became
            // idle mid-week (learning or withheld) moves below them, as at
            // generation (phone 2026-09-02: the withheld bedtime row sat
            // above "1 workout of 10+ strain").
            let idle = rebuilt.filter { $0.isLearning || $0.isWithheld }
            return WeeklyPlan(isoYear: saved.isoYear,
                              isoWeek: saved.isoWeek,
                              generatedAt: saved.generatedAt,
                              targets: rebuilt.filter { !($0.isLearning || $0.isWithheld) } + idle)
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
