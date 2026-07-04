import SwiftUI

// MARK: - Value model

/// Per-day join of a stored rollup with that day's confirmed workouts/sleeps.
/// Built once per `AtriaHistoryModel.make` call -- never mutated in place.
struct AtriaHistoryDay: Identifiable, Equatable {
    enum DayState: Equatable {
        case confirmed
        case review
        case sleepOnly
        case none

        /// Precedence: confirmed > review > sleepOnly > none.
        var tint: Color {
            switch self {
            case .confirmed: return .orange
            case .review: return .cyan
            case .sleepOnly: return Metrics.electricSleep
            case .none: return Color.secondary.opacity(0.4)
            }
        }
    }

    let date: Date
    let strain: Double?
    let recovery: Int?
    let rhrInt: Int?
    let hrvMs: Double?
    let sleepSeconds: TimeInterval?
    let sleepPerformance: Int?
    let confirmedWorkoutCount: Int
    let confirmedSleepCount: Int
    let savedDurationSeconds: TimeInterval
    /// Honest placeholder (2026-07-05): 0 until a real review-queue signal exists.
    let reviewPending: Int
    let state: DayState

    var id: Date { date }
}

/// A trailing-14-day median snapshot used by the day-detail sheet's delta rows.
/// Any field is `nil` when the window has fewer than 3 non-nil samples for that
/// metric ("building" -- never a fabricated comparison off too few points).
struct AtriaHistoryMedians: Equatable {
    let recovery: Double?
    let rhr: Double?
    let hrvMs: Double?
    let sleepSeconds: Double?
    let strain: Double?

    static let empty = AtriaHistoryMedians(recovery: nil, rhr: nil, hrvMs: nil, sleepSeconds: nil, strain: nil)

    fileprivate static func median(_ values: [Double]) -> Double? {
        guard values.count >= 3 else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

struct AtriaHistoryModel: Equatable {
    let days: [AtriaHistoryDay]
    let sessionsCount: Int
    /// Honest placeholder (2026-07-05): 0 until a real detected-but-unconfirmed
    /// session signal exists -- never fabricated.
    let detectedCount: Int
    let baselineReady: Int
    let baselineTarget: Int

    static let empty = AtriaHistoryModel(days: [], sessionsCount: 0, detectedCount: 0, baselineReady: 0, baselineTarget: 14)

    static func make(rollups: [DailyRollupStoreEntry],
                      workouts: [UserConfirmedWorkout],
                      sleeps: [UserConfirmedSleep],
                      calendar: Calendar = .current) -> AtriaHistoryModel {
        let workoutsByDay = Dictionary(grouping: workouts) { calendar.startOfDay(for: $0.start) }
        let sleepsByDay = Dictionary(grouping: sleeps) { calendar.startOfDay(for: $0.start) }

        let days: [AtriaHistoryDay] = rollups.map { rollup in
            let dayWorkouts = workoutsByDay[rollup.day] ?? []
            let daySleeps = sleepsByDay[rollup.day] ?? []
            let confirmedWorkoutCount = dayWorkouts.count
            let confirmedSleepCount = daySleeps.count
            let reviewPending = 0

            let state: AtriaHistoryDay.DayState
            if confirmedWorkoutCount > 0 {
                state = .confirmed
            } else if reviewPending > 0 {
                state = .review
            } else if confirmedSleepCount > 0 {
                state = .sleepOnly
            } else {
                state = .none
            }

            return AtriaHistoryDay(date: rollup.day,
                                    strain: rollup.strain,
                                    recovery: rollup.recovery,
                                    rhrInt: rollup.rhr,
                                    hrvMs: rollup.lnRMSSD.map(exp),
                                    sleepSeconds: rollup.sleepSeconds,
                                    sleepPerformance: rollup.sleepPerformance,
                                    confirmedWorkoutCount: confirmedWorkoutCount,
                                    confirmedSleepCount: confirmedSleepCount,
                                    savedDurationSeconds: dayWorkouts.reduce(0) { $0 + $1.duration },
                                    reviewPending: reviewPending,
                                    state: state)
        }

        let baselineReady = rollups.prefix(14).filter { $0.recovery != nil }.count

        return AtriaHistoryModel(days: days,
                                  sessionsCount: workouts.count,
                                  detectedCount: 0,
                                  baselineReady: baselineReady,
                                  baselineTarget: 14)
    }

    /// Trailing 14 calendar days ending on (and including) `day`.
    func medianWindow(around day: AtriaHistoryDay, calendar: Calendar = .current) -> AtriaHistoryMedians {
        guard let start = calendar.date(byAdding: .day, value: -13, to: day.date) else { return .empty }
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: day.date)
        let window = days.filter { $0.date >= startDay && $0.date <= endDay }

        return AtriaHistoryMedians(recovery: AtriaHistoryMedians.median(window.compactMap { $0.recovery.map(Double.init) }),
                                    rhr: AtriaHistoryMedians.median(window.compactMap { $0.rhrInt.map(Double.init) }),
                                    hrvMs: AtriaHistoryMedians.median(window.compactMap { $0.hrvMs }),
                                    sleepSeconds: AtriaHistoryMedians.median(window.compactMap { $0.sleepSeconds }),
                                    strain: AtriaHistoryMedians.median(window.compactMap { $0.strain }))
    }
}

// MARK: - Inline section (memoized subtree)

/// The compact, inline History card shown in the Vitals tab: hero stat chips,
/// a 14-day activity-rhythm strip, and the last 14 tappable rollup rows, with
/// a push to the full ≤400-row history list.
///
/// `.equatable()` at the call site plus the revision-only `==` below means
/// live-pulse re-renders of the surrounding Vitals tree never rebuild this
/// subtree -- only an actual rollup or confirmed-workout write does (mirrors
/// the `dailyRollupHistoryRevision` memoization pattern used by
/// AtriaTodayScreen, measured-perf pass 2026-07-05).
struct AtriaHistorySection: View, Equatable {
    let rollups: [DailyRollupStoreEntry]
    let rollupRevision: Int
    let workouts: [UserConfirmedWorkout]
    let sleeps: [UserConfirmedSleep]
    let workoutsRevision: Int

    @State private var model = AtriaHistoryModel.empty
    @State private var selectedDay: AtriaHistoryDay?

    static func == (lhs: AtriaHistorySection, rhs: AtriaHistorySection) -> Bool {
        lhs.rollupRevision == rhs.rollupRevision && lhs.workoutsRevision == rhs.workoutsRevision
    }

    var body: some View {
        VStack(spacing: 16) {
            historyHeroCard
            if model.days.isEmpty {
                emptyStateCard
            } else {
                activityRhythmCard
                recentRowsCard
            }
        }
        .onAppear { rebuild() }
        .onChange(of: rollupRevision) { _, _ in rebuild() }
        .onChange(of: workoutsRevision) { _, _ in rebuild() }
        .sheet(item: $selectedDay) { day in
            AtriaHistoryDayDetailSheet(day: day, medians: model.medianWindow(around: day))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func rebuild() {
        model = .make(rollups: rollups, workouts: workouts, sleeps: sleeps)
    }

    private var historyHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "History", subtitle: "Saved sessions, trends, and local activity evidence")
                Spacer(minLength: 8)
                Text("\(model.sessionsCount)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Metrics.electricStrain)
            }
            HStack(spacing: 10) {
                AtriaHistoryStatChip(label: "Sessions", value: "\(model.sessionsCount)", tint: Metrics.electricStrain)
                AtriaHistoryStatChip(label: "Detected", value: "\(model.detectedCount)", tint: .cyan)
                AtriaHistoryStatChip(label: "Baseline", value: "\(model.baselineReady)/\(model.baselineTarget)", tint: Metrics.electricGreen)
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }

    private var rhythmWindow: [AtriaHistoryDay] {
        Array(model.days.prefix(14))
    }

    private var activityRhythmCard: some View {
        let confirmedCount = rhythmWindow.filter { $0.state == .confirmed }.count
        let reviewCount = rhythmWindow.filter { $0.state == .review }.count
        let sleepCount = rhythmWindow.filter { $0.state == .sleepOnly }.count

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(Metrics.electricStrain)
                Text("Activity rhythm")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("14d")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            AtriaActivityRhythmStrip(days: Array(rhythmWindow.reversed()))
            HStack(spacing: 8) {
                if confirmedCount > 0 {
                    AtriaVitalsHintChip(text: "\(confirmedCount) Saved", tint: .orange)
                }
                if reviewCount > 0 {
                    AtriaVitalsHintChip(text: "\(reviewCount) Review", tint: .cyan)
                }
                if sleepCount > 0 {
                    AtriaVitalsHintChip(text: "\(sleepCount) Sleep", tint: Metrics.electricSleep)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }

    private var recentRowsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent days")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVStack(spacing: 8) {
                ForEach(model.days.prefix(14)) { day in
                    Button {
                        selectedDay = day
                    } label: {
                        AtriaHistoryDayRow(day: day)
                    }
                    .buttonStyle(.plain)
                }
            }
            if model.days.count > 14 {
                NavigationLink {
                    AtriaHistoryFullScreen(model: model, onSelect: { selectedDay = $0 })
                } label: {
                    HStack {
                        Text("See all history")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(12)
                    .atriaInsetCard(cornerRadius: 16, tint: Color.secondary.opacity(0.08))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No saved days yet")
                .font(.subheadline.weight(.semibold))
            Text("Recovery, sleep, and strain appear here after your first overnight and workout.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }
}

private struct AtriaHistoryStatChip: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .atriaInsetCard(cornerRadius: 16, tint: tint)
    }
}

/// 14-column rhythm strip: bar height ∝ strain normalized to the window max,
/// dot below tinted by that day's `DayState`. Bars with no strain draw only
/// the faint track -- never a fabricated height.
struct AtriaActivityRhythmStrip: View {
    let days: [AtriaHistoryDay]

    private static let barHeight: CGFloat = 56
    private static let barWidth: CGFloat = 8

    private var maxStrain: Double {
        days.compactMap { $0.strain }.max() ?? 0
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(0.14))
                            .frame(width: Self.barWidth, height: Self.barHeight)
                        if let strain = day.strain, maxStrain > 0 {
                            Capsule(style: .continuous)
                                .fill(Metrics.electricStrain)
                                .frame(width: Self.barWidth,
                                       height: max(4, Self.barHeight * CGFloat(strain / maxStrain)))
                        }
                    }
                    Circle()
                        .fill(day.state.tint)
                        .frame(width: 6, height: 6)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Day row (shared by inline + full history list)

struct AtriaHistoryDayRow: View, Equatable {
    let day: AtriaHistoryDay

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: day.confirmedWorkoutCount > 0 ? "figure.run" : "calendar")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(day.state.tint)
                .frame(width: 30, height: 30)
                .background(day.state.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(day.date.formatted(.dateTime.month(.wide).day().year()))
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                chipRow
            }

            Spacer(minLength: 8)

            Text(day.strain.map { "\(AtriaMetricFormat.strain($0)) strain" } ?? "—")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(day.strain != nil ? Metrics.electricStrain : .secondary)
                .lineLimit(1)
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 16, tint: day.state == .none ? Color.clear : day.state.tint.opacity(0.5))
    }

    @ViewBuilder
    private var chipRow: some View {
        HStack(spacing: 6) {
            if day.savedDurationSeconds > 0 {
                AtriaVitalsHintChip(text: "\(SleepHistorySnapshot.formatDuration(day.savedDurationSeconds)) Saved", tint: .orange)
            }
            if day.confirmedWorkoutCount > 0 {
                AtriaVitalsHintChip(text: "\(day.confirmedWorkoutCount) Confirmed", tint: .orange)
            }
            if day.confirmedSleepCount > 0 {
                AtriaVitalsHintChip(text: "\(day.confirmedSleepCount) Sleep", tint: .blue)
            }
            if day.reviewPending > 0 {
                AtriaVitalsHintChip(text: "\(day.reviewPending) Review", tint: .cyan)
            }
        }
    }
}

// MARK: - Full history (pushed, pinned-month list)

/// Owns its own scroll + LazyVStack so all ≤400 rows are never instantiated
/// eagerly -- only visible rows render, with pinned month section headers for
/// scannability. Rows funnel back to the parent's single day-detail sheet via
/// `onSelect` rather than presenting their own.
struct AtriaHistoryFullScreen: View {
    let model: AtriaHistoryModel
    let onSelect: (AtriaHistoryDay) -> Void

    private struct MonthGroup: Identifiable {
        let id: String
        let title: String
        let days: [AtriaHistoryDay]
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    private var monthGroups: [MonthGroup] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [AtriaHistoryDay]] = [:]
        for day in model.days {
            let comps = calendar.dateComponents([.year, .month], from: day.date)
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(day)
        }
        return order.compactMap { key in
            guard let days = buckets[key], let first = days.first else { return nil }
            return MonthGroup(id: key, title: Self.monthFormatter.string(from: first.date), days: days)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                ForEach(monthGroups) { group in
                    Section {
                        ForEach(group.days) { day in
                            Button {
                                onSelect(day)
                            } label: {
                                AtriaHistoryDayRow(day: day)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        monthHeader(group.title)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("History")
    }

    private func monthHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.bold))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.bar)
    }
}

// MARK: - Day detail sheet

private enum AtriaHistoryGoodDirection {
    case up
    case down
    case neutral
}

private struct AtriaHistoryDeltaGlyph: View {
    let current: Double?
    let median: Double?
    let goodDirection: AtriaHistoryGoodDirection
    let formatMagnitude: (Double) -> String

    var body: some View {
        if let current, let median {
            let delta = current - median
            let isUp = delta >= 0
            Label {
                Text(formatMagnitude(abs(delta)))
            } icon: {
                Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
            }
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(tint(isUp: isUp))
        } else {
            Text("Building median")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func tint(isUp: Bool) -> Color {
        switch goodDirection {
        case .neutral: return .secondary
        case .up: return isUp ? Metrics.electricGreen : Metrics.electricYellow
        case .down: return isUp ? Metrics.electricYellow : Metrics.electricGreen
        }
    }
}

/// Replica of `AtriaWeeklyReportStatRow` (AtriaOverviewSections.swift, private
/// to that file) extended with a trailing delta glyph vs the 14-day median.
private struct AtriaHistoryStatRow: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    let delta: AtriaHistoryDeltaGlyph

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(value)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                delta
            }
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 16, tint: tint)
    }
}

struct AtriaHistoryDayDetailSheet: View {
    let day: AtriaHistoryDay
    let medians: AtriaHistoryMedians

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AtriaPanelSectionHeader(title: day.date.formatted(.dateTime.weekday(.wide).month().day()),
                                        subtitle: "vs 14-day median")
                VStack(spacing: 10) {
                    recoveryRow
                    rhrRow
                    hrvRow
                    sleepRow
                    strainRow
                }
            }
            .padding(20)
        }
    }

    private var recoveryRow: some View {
        AtriaHistoryStatRow(title: "Recovery",
                            value: day.recovery.map { "\($0)%" } ?? "—",
                            detail: medians.recovery.map { "Median \(Int($0.rounded()))%" } ?? "Building median",
                            systemImage: "heart.fill",
                            tint: day.recovery.map { Metrics.recoveryColor($0) } ?? .secondary,
                            delta: AtriaHistoryDeltaGlyph(current: day.recovery.map(Double.init),
                                                          median: medians.recovery,
                                                          goodDirection: .up,
                                                          formatMagnitude: { "\(Int($0.rounded()))%" }))
    }

    private var rhrRow: some View {
        AtriaHistoryStatRow(title: "Resting HR",
                            value: day.rhrInt.map { "\($0) bpm" } ?? "—",
                            detail: medians.rhr.map { "Median \(Int($0.rounded())) bpm" } ?? "Building median",
                            systemImage: "heart.text.square.fill",
                            tint: .cyan,
                            delta: AtriaHistoryDeltaGlyph(current: day.rhrInt.map(Double.init),
                                                          median: medians.rhr,
                                                          goodDirection: .down,
                                                          formatMagnitude: { "\(Int($0.rounded())) bpm" }))
    }

    private var hrvRow: some View {
        AtriaHistoryStatRow(title: "HRV",
                            value: AtriaMetricFormat.hrv(day.hrvMs),
                            detail: medians.hrvMs.map { "Median \(AtriaMetricFormat.hrv($0))" } ?? "Building median",
                            systemImage: "waveform.path.ecg",
                            tint: Metrics.electricGreen,
                            delta: AtriaHistoryDeltaGlyph(current: day.hrvMs,
                                                          median: medians.hrvMs,
                                                          goodDirection: .up,
                                                          formatMagnitude: { "\(Int($0.rounded())) ms" }))
    }

    private var sleepRow: some View {
        AtriaHistoryStatRow(title: "Sleep",
                            value: SleepHistorySnapshot.formatDuration(day.sleepSeconds ?? 0),
                            detail: medians.sleepSeconds.map { "Median \(SleepHistorySnapshot.formatDuration($0))" } ?? "Building median",
                            systemImage: "moon.fill",
                            tint: Metrics.electricSleep,
                            delta: AtriaHistoryDeltaGlyph(current: day.sleepSeconds,
                                                          median: medians.sleepSeconds,
                                                          goodDirection: .up,
                                                          formatMagnitude: { SleepHistorySnapshot.formatDuration($0) }))
    }

    private var strainRow: some View {
        AtriaHistoryStatRow(title: "Strain",
                            value: AtriaMetricFormat.strain(day.strain),
                            detail: medians.strain.map { "Median \(AtriaMetricFormat.strain($0))" } ?? "Building median",
                            systemImage: "bolt.fill",
                            tint: Metrics.electricStrain,
                            delta: AtriaHistoryDeltaGlyph(current: day.strain,
                                                          median: medians.strain,
                                                          goodDirection: .neutral,
                                                          formatMagnitude: { String(format: "%.1f", $0) }))
    }
}
