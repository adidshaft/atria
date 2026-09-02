import Combine
import SwiftUI

// MARK: - Model

/// One day's checkmark state for a single routine target. `.noData` and
/// `.missed` are deliberately distinct: `.noData` means Atria has no signal
/// to judge the day (no strap rollup at all that day), `.missed` means there
/// IS a signal and it didn't clear the bar. Collapsing the two would either
/// scold users for days the strap wasn't worn, or quietly hide real misses --
/// this card does neither.
enum AtriaRoutineDayState: Equatable {
    case kept
    case missed
    case noData
    case upcoming
}

struct AtriaRoutineDay: Equatable, Identifiable {
    let date: Date
    let state: AtriaRoutineDayState
    var id: Date { date }
}

struct AtriaRoutineTarget: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case bedtime
        case workout
        case journal
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let systemImage: String
    /// Current ISO week, Monday...Sunday, oldest first. 7 entries.
    let week: [AtriaRoutineDay]
    /// Current streak of kept days, computed over a longer lookback window
    /// than the visible week (see `AtriaRoutineComputer`) so a streak that
    /// started last week doesn't visually reset to 0 every Monday.
    let streak: Int

    var id: String { kind.rawValue }
}

struct AtriaRoutineSummary: Equatable {
    let isoYear: Int
    let isoWeek: Int
    /// Monday of the ISO week `isoWeek` names -- carried so the header can show a
    /// human date range ("Aug 4 - 10") instead of the "W32" ISO-week jargon.
    let weekStart: Date
    let targets: [AtriaRoutineTarget]
    /// False only when there is truly nothing to show yet (no rollups, no
    /// journal entries at all) -- gates the honest empty state.
    let hasAnyHistory: Bool
}

// MARK: - Computer (pure; no SwiftUI/store dependency)

/// v1 routine/streak math (gap spec d): a pure function over data the app
/// already computes elsewhere -- `DailyRollupStoreEntry` (bedtime, strain)
/// and `BehaviorJournalEntry` (journal logging). No new tracking, no new
/// persistence.
enum AtriaRoutineComputer {
    /// Matches `WeeklyPlan`'s ISO-week calendar so the Routine card and the
    /// "This week" plan card always agree on what "this week" means.
    static let isoCalendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }()

    /// Strain threshold for "workout done" -- matches
    /// `WeeklyPlan.workoutTarget`'s threshold exactly so the two cards never
    /// disagree about whether a day counted.
    static let workoutStrainThreshold: Double = 10

    /// Minutes of grace after the median recent bedtime -- matches
    /// `WeeklyPlan.bedtimeTarget`'s "+20" buffer.
    private static let bedtimeGraceMinutes = 20

    /// How far back "current streak" looks so a streak begun last week
    /// doesn't appear to reset on Monday even though only 7 days render.
    private static let streakLookbackDays = 90

    static func summary(rollups: [DailyRollupStoreEntry],
                        journalEntries: [BehaviorJournalEntry],
                        now: Date = Date(),
                        calendar: Calendar = AtriaRoutineComputer.isoCalendar) -> AtriaRoutineSummary {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let weekDays = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        let lookbackDays = (0..<streakLookbackDays).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }

        var rollupsByDay: [Date: DailyRollupStoreEntry] = [:]
        for entry in rollups {
            rollupsByDay[calendar.startOfDay(for: entry.day)] = entry
        }
        let loggedJournalDays = Set(journalEntries
            .filter { !$0.tags.isEmpty || !$0.healthAutoTags.isEmpty }
            .map { calendar.startOfDay(for: $0.day) })

        let recent28 = recentEntries(rollups, calendar: calendar, onOrBefore: today, count: 28)
        // nil until enough bedtimes exist — the card then says "Learning"
        // instead of the fabricated 23:00 it used to fall back to.
        let bedtimeTarget = bedtimeTargetMinute(recentRollups: recent28)

        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)

        let targets: [AtriaRoutineTarget] = AtriaRoutineTarget.Kind.allCases.map { kind in
            func state(for day: Date) -> AtriaRoutineDayState {
                dayState(for: kind,
                        day: day,
                        today: today,
                        rollupsByDay: rollupsByDay,
                        loggedJournalDays: loggedJournalDays,
                        bedtimeTargetMinute: bedtimeTarget,
                        calendar: calendar)
            }
            let weekStates = weekDays.map { AtriaRoutineDay(date: $0, state: state(for: $0)) }
            let streak = currentStreak(lookbackDays.map(state(for:)))
            return AtriaRoutineTarget(kind: kind,
                                      title: title(for: kind),
                                      subtitle: subtitle(for: kind, bedtimeTargetMinute: bedtimeTarget),
                                      systemImage: systemImage(for: kind),
                                      week: weekStates,
                                      streak: streak)
        }

        return AtriaRoutineSummary(isoYear: components.yearForWeekOfYear ?? components.year ?? 0,
                                   isoWeek: components.weekOfYear ?? 0,
                                   weekStart: weekStart,
                                   targets: targets,
                                   hasAnyHistory: !rollups.isEmpty || !journalEntries.isEmpty)
    }

    /// Longest RUNNING streak, processed in chronological order: a `.kept`
    /// day extends it, `.missed`/`.noData` resets it to 0, `.upcoming`
    /// (future days that haven't happened) is skipped rather than resetting
    /// anything. The value after the last real day is "the current streak."
    static func currentStreak(_ states: [AtriaRoutineDayState]) -> Int {
        var current = 0
        for state in states {
            switch state {
            case .kept:
                current += 1
            case .upcoming:
                continue
            case .missed, .noData:
                current = 0
            }
        }
        return current
    }

    // MARK: Per-day state

    private static func dayState(for kind: AtriaRoutineTarget.Kind,
                                 day: Date,
                                 today: Date,
                                 rollupsByDay: [Date: DailyRollupStoreEntry],
                                 loggedJournalDays: Set<Date>,
                                 bedtimeTargetMinute: Int?,
                                 calendar: Calendar) -> AtriaRoutineDayState {
        let normalizedDay = calendar.startOfDay(for: day)
        guard normalizedDay <= today else { return .upcoming }
        switch kind {
        case .bedtime:
            guard let bedtimeTargetMinute,
                  let entry = rollupsByDay[normalizedDay], let minutes = entry.bedtimeMinutes else { return .noData }
            return WeeklyPlan.minuteIsNoLater(minutes, than: bedtimeTargetMinute) ? .kept : .missed
        case .workout:
            guard let entry = rollupsByDay[normalizedDay], let strain = entry.strain else { return .noData }
            return strain >= workoutStrainThreshold ? .kept : .missed
        case .journal:
            // Unlike bedtime/workout (which depend on strap data that may
            // simply be absent that day), a missing journal entry for a past
            // day IS the ground truth -- the user didn't log. Honest to call
            // it `.missed`, not `.noData`.
            return loggedJournalDays.contains(normalizedDay) ? .kept : .missed
        }
    }

    // MARK: Copy

    private static func title(for kind: AtriaRoutineTarget.Kind) -> String {
        switch kind {
        case .bedtime: return "Bedtime kept"
        case .workout: return "Workout day"
        case .journal: return "Journal logged"
        }
    }

    private static func systemImage(for kind: AtriaRoutineTarget.Kind) -> String {
        switch kind {
        case .bedtime: return "moon.zzz.fill"
        case .workout: return "figure.mixed.cardio"
        case .journal: return "square.and.pencil"
        }
    }

    private static func subtitle(for kind: AtriaRoutineTarget.Kind, bedtimeTargetMinute: Int?) -> String {
        switch kind {
        case .bedtime: return bedtimeTargetMinute.map { "By \(formatClockMinute($0))" } ?? "Learning"
        case .workout: return "\u{2265} \(Int(workoutStrainThreshold)) strain"
        case .journal: return "Any tag logged"
        }
    }

    // MARK: Bedtime target math

    // The following mirrors `WeeklyPlan.bedtimeTarget`'s median+grace
    // computation exactly (median recent bedtime + 20 minutes). It is
    // duplicated rather than called because those methods are `private` to
    // AtriaWeeklyPlan.swift, a file outside this feature's ownership --
    // duplicating a few small pure functions keeps the two cards in
    // agreement without editing that file.

    private static func recentEntries(_ rollups: [DailyRollupStoreEntry],
                                      calendar: Calendar,
                                      onOrBefore today: Date,
                                      count: Int) -> [DailyRollupStoreEntry] {
        guard count > 0 else { return [] }
        var recent: [DailyRollupStoreEntry] = []

        for entry in rollups where calendar.startOfDay(for: entry.day) <= today {
            if recent.count < count {
                insertRecentEntry(entry, into: &recent)
            } else if let oldest = recent.last, entry.day > oldest.day {
                recent.removeLast()
                insertRecentEntry(entry, into: &recent)
            }
        }

        return recent
    }

    private static func insertRecentEntry(_ entry: DailyRollupStoreEntry,
                                          into recent: inout [DailyRollupStoreEntry]) {
        let index = recent.firstIndex { $0.day < entry.day } ?? recent.endIndex
        recent.insert(entry, at: index)
    }

    /// Same rhythm the weekly plan uses (one authority): a circular median of
    /// the recent bedtimes plus grace, or nil until enough nights exist. The
    /// card used to keep its own copy of the plan's noon-cut median, so both
    /// carried issue #41's defect for afternoon sleepers.
    private static func bedtimeTargetMinute(recentRollups: [DailyRollupStoreEntry]) -> Int? {
        let minutes = recentRollups.compactMap(\.bedtimeMinutes)
        guard minutes.count >= WeeklyPlan.minimumBedtimeNights,
              let median = WeeklyPlan.circularMedianMinute(minutes) else { return nil }
        return (median + bedtimeGraceMinutes) % 1_440
    }

    private static func formatClockMinute(_ minute: Int) -> String {
        let wrapped = ((minute % 1_440) + 1_440) % 1_440
        let hour = wrapped / 60
        let mins = wrapped % 60
        let suffix = hour >= 12 ? "PM" : "AM"
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", displayHour, mins, suffix)
    }
}

// MARK: - View

/// v1 routine/streak card (gap spec d): pure visualization over data the app
/// already has -- `WeeklyPlan`'s underlying rollups and the behavior journal.
/// No new tracking, no new stores. Mounted in the Journal tab near the cycle
/// card.
struct AtriaRoutineCard: View {
    let store: SessionStore
    @StateObject private var projectionStore: AtriaRoutineProjectionStore

    init(store: SessionStore) {
        self.store = store
        _projectionStore = StateObject(wrappedValue: AtriaRoutineProjectionStore(store: store))
    }

    var body: some View {
        let summary = projectionStore.summary
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Routine",
                                    subtitle: "This week \u{00B7} \(Self.weekRangeText(summary))")

            if summary.hasAnyHistory {
                VStack(spacing: 14) {
                    ForEach(summary.targets) { target in
                        AtriaRoutineTargetRow(target: target)
                    }
                }
            } else {
                emptyState
            }
        }
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(emphasis: .soft)
    }

    /// Human "Aug 4 - 10" range for the header, replacing the "W32" ISO-week
    /// jargon. Uses the SAME iso calendar the summary's week was computed with,
    /// so the range can never disagree with the day dots below it.
    private static let weekRangeFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.calendar = AtriaRoutineComputer.isoCalendar
        formatter.dateTemplate = "MMMd"
        return formatter
    }()

    private static func weekRangeText(_ summary: AtriaRoutineSummary) -> String {
        let calendar = AtriaRoutineComputer.isoCalendar
        let end = calendar.date(byAdding: .day, value: 6, to: summary.weekStart) ?? summary.weekStart
        return weekRangeFormatter.string(from: summary.weekStart, to: end)
    }

    private var emptyState: some View {
        Text("Log a few days \u{2014} bedtime, a workout, a journal tag \u{2014} and Atria will track your streaks here.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Card-local bridge that keeps the retained Journal hierarchy insulated from
/// unrelated SessionStore publishes. Dashboard changes are only inspected when
/// the journal revision advanced, and equal rendered summaries never publish.
@MainActor
final class AtriaRoutineProjectionStore: ObservableObject {
    @Published private(set) var summary: AtriaRoutineSummary

    private weak var store: SessionStore?
    private var journalRevision: Int
    private var cancellables = Set<AnyCancellable>()

    init(store: SessionStore) {
        self.store = store
        journalRevision = store.behaviorJournalRevision
        summary = AtriaRoutineComputer.summary(rollups: store.dailyRollupHistory,
                                               journalEntries: store.behaviorJournalEntries)
        bind(to: store)
    }

    init(summary: AtriaRoutineSummary) {
        self.summary = summary
        journalRevision = 0
    }

    @discardableResult
    func refresh(rollups: [DailyRollupStoreEntry],
                 journalEntries: [BehaviorJournalEntry],
                 now: Date = Date()) -> Bool {
        refresh(AtriaRoutineComputer.summary(rollups: rollups,
                                             journalEntries: journalEntries,
                                             now: now))
    }

    @discardableResult
    func refresh(_ next: AtriaRoutineSummary) -> Bool {
        guard next != summary else { return false }
        summary = next
        return true
    }

    @discardableResult
    func refreshForJournalRevision(_ revision: Int,
                                   rollups: [DailyRollupStoreEntry],
                                   journalEntries: [BehaviorJournalEntry],
                                   now: Date = Date()) -> Bool {
        guard revision != journalRevision else { return false }
        journalRevision = revision
        return refresh(rollups: rollups,
                       journalEntries: journalEntries,
                       now: now)
    }

    private func bind(to store: SessionStore) {
        store.$dailyRollupHistory
            .dropFirst()
            .sink { [weak self, weak store] rollups in
                guard let self, let store else { return }
                self.refresh(rollups: rollups,
                             journalEntries: store.behaviorJournalEntries)
            }
            .store(in: &cancellables)

        store.$dashboardRevision
            .dropFirst()
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.refreshForJournalRevision(store.behaviorJournalRevision,
                                               rollups: store.dailyRollupHistory,
                                               journalEntries: store.behaviorJournalEntries)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .sink { [weak self] _ in
                guard let self, let store = self.store else { return }
                self.refresh(rollups: store.dailyRollupHistory,
                             journalEntries: store.behaviorJournalEntries)
            }
            .store(in: &cancellables)
    }
}

private struct AtriaRoutineTargetRow: View, Equatable {
    let target: AtriaRoutineTarget

    static func == (lhs: AtriaRoutineTargetRow, rhs: AtriaRoutineTargetRow) -> Bool {
        lhs.target == rhs.target
    }

    private static let weekdaySymbols = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(target.title, systemImage: target.systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if target.streak > 0 {
                    AtriaStatusChip(text: "\(target.streak)d streak",
                                    systemImage: "flame.fill",
                                    tint: .orange)
                }
            }

            Text(target.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(Array(target.week.enumerated()), id: \.offset) { index, day in
                    dayDot(day, label: Self.weekdaySymbols[index % Self.weekdaySymbols.count])
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func dayDot(_ day: AtriaRoutineDay, label: String) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(fillColor(day.state))
                if day.state == .upcoming {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                if day.state == .kept {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else if day.state == .missed {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 22, height: 22)

            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func fillColor(_ state: AtriaRoutineDayState) -> Color {
        switch state {
        case .kept: return .cyan
        case .missed: return .red.opacity(0.55)
        case .noData: return .primary.opacity(0.08)
        case .upcoming: return .clear
        }
    }
}
