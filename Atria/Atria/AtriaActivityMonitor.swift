import SwiftUI
import Charts

/// Activity Monitor — every logged activity (sleep, naps, workouts) in one
/// place, grouped by day newest-first, each row tappable to review or adjust.
///
/// Replaces the redundant Plan tab, whose two cards already live elsewhere
/// (weekly plan on Today, routine on Journal). All data is read from the live
/// `SessionStore`; nothing here is fabricated — a metric only renders when the
/// underlying session actually recorded it.
struct AtriaActivityMonitorTab: View {
    @ObservedObject var store: SessionStore
    /// Opens the existing manual-sleep sheet seeded with this night for editing.
    let onEditSleep: (SleepHistorySnapshot.Night) -> Void
    /// Opens the manual-sleep sheet with no seed, to add a fresh sleep or nap.
    let onAddSleep: () -> Void

    @State private var workoutDetail: UserConfirmedWorkout?
    @State private var showAddWorkout = false
    /// Day shown in the header timeline (user feedback 2026-07-07: "the top
    /// of activity should have an entire graph with activities listed and
    /// days can be changed").
    @State private var timelineDay: Date = Calendar.current.startOfDay(for: Date())

    private enum Entry: Identifiable {
        case sleep(SleepHistorySnapshot.Night)
        case workout(UserConfirmedWorkout)

        var id: String {
            switch self {
            case .sleep(let night): return "sleep-\(night.id)"
            case .workout(let workout): return "workout-\(workout.id)"
            }
        }

        /// Sort anchor: when the activity happened.
        var date: Date {
            switch self {
            case .sleep(let night): return night.start ?? night.end ?? night.day
            case .workout(let workout): return workout.start
            }
        }
    }

    private struct DaySection: Identifiable {
        let id: String
        let date: Date
        let entries: [Entry]
    }

    private var daySections: [DaySection] {
        let calendar = Calendar.current
        var entries: [Entry] = []
        entries.append(contentsOf: store.sleepHistorySnapshot.nights.map(Entry.sleep))
        entries.append(contentsOf: store.confirmedWorkouts.map(Entry.workout))

        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            DaySection(id: String(day.timeIntervalSinceReferenceDate),
                       date: day,
                       entries: (grouped[day] ?? []).sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Activity",
                                    subtitle: "Every logged sleep, nap and workout — tap to review or adjust.")

            addActivityMenu

            dayTimelineCard

            let sections = daySections
            if sections.isEmpty {
                emptyState
            } else {
                ForEach(sections) { section in
                    daySectionCard(section)
                }
            }
        }
        .sheet(item: $workoutDetail) { workout in
            AtriaActivityWorkoutDetailSheet(store: store, workout: workout)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddWorkout) {
            AtriaAddWorkoutSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// A span of one activity clipped to the selected day, for the header
    /// timeline lanes.
    private struct TimelineSpan: Identifiable {
        let id: String
        let lane: String
        let start: Date
        let end: Date
        let tint: Color
        let label: String
    }

    private var timelineSpans: [TimelineSpan] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: timelineDay)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        var spans: [TimelineSpan] = []
        for night in store.sleepHistorySnapshot.nights {
            guard let start = night.start, let end = night.end,
                  end > dayStart, start < dayEnd else { continue }
            spans.append(TimelineSpan(id: "sleep-\(night.id)",
                                      lane: night.isNapEvidence ? "Nap" : "Sleep",
                                      start: max(start, dayStart),
                                      end: min(end, dayEnd),
                                      tint: Metrics.electricSleep,
                                      label: night.isNapEvidence ? "Nap" : "Sleep"))
        }
        for workout in store.confirmedWorkouts {
            guard workout.end > dayStart, workout.start < dayEnd else { continue }
            spans.append(TimelineSpan(id: "workout-\(workout.id)",
                                      lane: "Workout",
                                      start: max(workout.start, dayStart),
                                      end: min(workout.end, dayEnd),
                                      tint: Metrics.electricStrain,
                                      label: workout.activitySubtype ?? workout.activityType ?? "Workout"))
        }
        return spans
    }

    private var canGoToNextDay: Bool {
        Calendar.current.startOfDay(for: timelineDay) < Calendar.current.startOfDay(for: Date())
    }

    private var dayTimelineCard: some View {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: timelineDay)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let spans = timelineSpans

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    if let previous = calendar.date(byAdding: .day, value: -1, to: timelineDay) {
                        timelineDay = previous
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous day")

                Spacer(minLength: 0)
                Text(calendar.isDateInToday(timelineDay)
                     ? "Today"
                     : timelineDay.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.subheadline.weight(.bold))
                Spacer(minLength: 0)

                Button {
                    if let next = calendar.date(byAdding: .day, value: 1, to: timelineDay) {
                        timelineDay = next
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canGoToNextDay)
                .opacity(canGoToNextDay ? 1 : 0.3)
                .accessibilityLabel("Next day")
            }

            if spans.isEmpty {
                Text("Nothing recorded this day.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 84)
            } else {
                Chart(spans) { span in
                    BarMark(xStart: .value("Start", span.start),
                            xEnd: .value("End", span.end),
                            y: .value("Lane", span.lane))
                        .foregroundStyle(span.tint.opacity(0.85))
                        .cornerRadius(4)
                }
                .chartXScale(domain: dayStart...dayEnd)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: max(64, CGFloat(Set(spans.map(\.lane)).count) * 34 + 30))
                .clipped()
            }
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
        .animation(.snappy(duration: 0.2), value: timelineDay)
    }

    private var addActivityMenu: some View {
        Menu {
            Button { showAddWorkout = true } label: {
                Label("Add workout", systemImage: "figure.run")
            }
            Button { onAddSleep() } label: {
                Label("Add sleep or nap", systemImage: "bed.double.fill")
            }
        } label: {
            Label("Add activity", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(Metrics.electricStrain)
        .accessibilityHint("Log a workout, or a sleep/nap the strap missed.")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No activity logged yet")
                .font(.footnote.weight(.semibold))
            Text("Wear the strap overnight or during a workout — sleep, naps and workouts show up here to review and adjust. Nothing is filled in for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetCard(tint: .secondary)
    }

    private func daySectionCard(_ section: DaySection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.dayLabel(for: section.date))
                .font(.caption.weight(.black))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(section.entries) { entry in
                    entryRow(entry)
                }
            }
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private func entryRow(_ entry: Entry) -> some View {
        switch entry {
        case .sleep(let night):
            Button { onEditSleep(night) } label: { sleepRow(night) }
                .buttonStyle(.plain)
        case .workout(let workout):
            Button { workoutDetail = workout } label: { workoutRow(workout) }
                .buttonStyle(.plain)
        }
    }

    private func sleepRow(_ night: SleepHistorySnapshot.Night) -> some View {
        let isNap = night.isNapEvidence
        let tint: Color = isNap ? .indigo : Metrics.electricSleep
        return activityRow(icon: isNap ? "moon.zzz.fill" : "bed.double.fill",
                           tint: tint,
                           title: isNap ? "Nap" : "Sleep",
                           subtitle: Self.timeRange(start: night.start, end: night.end),
                           value: night.durationText,
                           badge: night.confirmed ? "Confirmed" : night.confidence.capitalized)
            .accessibilityLabel("\(isNap ? "Nap" : "Sleep"), \(night.durationText), \(Self.timeRange(start: night.start, end: night.end)). Tap to adjust.")
    }

    private func workoutRow(_ workout: UserConfirmedWorkout) -> some View {
        activityRow(icon: "figure.run",
                    tint: Metrics.electricStrain,
                    title: workout.label,
                    subtitle: Self.timeRange(start: workout.start, end: workout.end),
                    value: Self.durationText(workout.duration),
                    badge: workout.strain.map { "Strain \(String(format: "%.1f", $0))" }
                        ?? "\(workout.avgHR) bpm avg")
            .accessibilityLabel("\(workout.label), \(Self.durationText(workout.duration)), average \(workout.avgHR) bpm. Tap for details.")
    }

    private func activityRow(icon: String,
                             tint: Color,
                             title: String,
                             subtitle: String,
                             value: String,
                             badge: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.callout.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                // User-editable workout names get a scale guard + priority so
                // the fixed trailing column yields (UX audit 2026-07-07).
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.black).monospacedDigit())
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            .fixedSize()

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .atriaInsetCard(tint: tint)
        .contentShape(Rectangle())
    }

    // MARK: - Formatting

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    private static func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    private static func timeRange(start: Date?, end: Date?) -> String {
        switch (start, end) {
        case let (start?, end?):
            return "\(timeFormatter.string(from: start)) – \(timeFormatter.string(from: end))"
        case let (start?, nil):
            return timeFormatter.string(from: start)
        case let (nil, end?):
            return "until \(timeFormatter.string(from: end))"
        case (nil, nil):
            return "time not recorded"
        }
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((interval / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// Detail + editor for a confirmed workout in the Activity Monitor. The measured
/// The measured stats (HR, strain, calories) are read-only — they come straight
/// from the recorded session and are never estimated. Editable: the name, the
/// activity type (Run / Walk / Dance …), the time window (re-derives metrics from
/// the strap samples in the new window), and removal (delete a wrong detection).
private struct AtriaActivityWorkoutDetailSheet: View {
    @ObservedObject var store: SessionStore
    let workout: UserConfirmedWorkout
    @Environment(\.dismiss) private var dismiss

    @State private var label: String
    @State private var activityType: String
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var showDeleteConfirm = false

    /// Common activity types offered in the type picker (real workout kinds, not
    /// fabricated data — just labels for what the effort was).
    static let activityTypes = ["Run", "Walk", "Hike", "Cycle", "Strength", "HIIT",
                                "Yoga", "Swim", "Row", "Dance", "Other"]

    init(store: SessionStore, workout: UserConfirmedWorkout) {
        self.store = store
        self.workout = workout
        _label = State(initialValue: workout.label)
        _activityType = State(initialValue: workout.activityType ?? "")
        _startTime = State(initialValue: workout.start)
        _endTime = State(initialValue: workout.end)
    }

    /// The workout window's real recorded HR samples from the saved
    /// sessions that overlap it. Empty when no session covered the window
    /// (e.g. a manually added workout) — the card then doesn't render.
    private var heartRateTracePoints: [AtriaHomeModel.HeartRateChartPoint] {
        store.sessions
            .filter { $0.end > workout.start && $0.start < workout.end }
            .flatMap { session in
                session.points.compactMap { point -> AtriaHomeModel.HeartRateChartPoint? in
                    let t = session.start.addingTimeInterval(point.t)
                    guard t >= workout.start, t <= workout.end, point.bpm > 0 else { return nil }
                    return AtriaHomeModel.HeartRateChartPoint(t: t, bpm: point.bpm)
                }
            }
            .sorted { $0.t < $1.t }
    }

    /// Per-workout HR trace (design backlog item 6). Reuses the shared axis
    /// chart, which auto-smooths dense windows into an average + min-max
    /// band per the 2026-07-07 feedback.
    @ViewBuilder
    private var heartRateTraceCard: some View {
        let points = heartRateTracePoints
        if points.count >= 30 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Heart-rate trace")
                    .font(.subheadline.weight(.semibold))
                AtriaHeartRateAxisChart(points: points,
                                        yDomain: AtriaHeartRateChartSeries.yDomain(for: points),
                                        selectedTime: .constant(nil))
                    .frame(height: 150)
                    .clipped()
                Text("Recorded strap samples during this workout.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .atriaInsetCard(tint: .red)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Heart-rate trace, \(points.count) samples during this workout.")
        }
    }

    private var timesChanged: Bool {
        abs(startTime.timeIntervalSince(workout.start)) >= 60
            || abs(endTime.timeIntervalSince(workout.end)) >= 60
    }

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveName: Bool {
        !trimmedLabel.isEmpty && trimmedLabel != workout.label
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AtriaPanelSectionHeader(title: "Workout",
                                            subtitle: Self.rangeText(workout))

                    heartRateTraceCard

                    VStack(alignment: .leading, spacing: 8) {
                        Text("NAME")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("Workout name", text: $label)
                                .textInputAutocapitalization(.words)
                                .submitLabel(.done)
                                .onSubmit(saveName)
                            Button("Save", action: saveName)
                                .font(.subheadline.weight(.bold))
                                .disabled(!canSaveName)
                        }
                        .padding(12)
                        .atriaInsetCard(tint: Metrics.electricStrain)
                    }

                    // Activity type — what the effort was (Run / Walk / Dance …).
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ACTIVITY TYPE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Menu {
                            ForEach(Self.activityTypes, id: \.self) { type in
                                Button(type) { setType(type) }
                            }
                            if !activityType.isEmpty {
                                Button("Clear", role: .destructive) { setType("") }
                            }
                        } label: {
                            HStack {
                                Text(activityType.isEmpty ? "Choose type" : activityType)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(activityType.isEmpty ? .secondary : .primary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .atriaInsetCard(tint: .mint)
                        }
                    }

                    // Time window — editable; saving re-derives every metric from
                    // the strap samples in the new window (nothing fabricated).
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TIME")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        VStack(spacing: 6) {
                            DatePicker("Start", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                            DatePicker("End", selection: $endTime, in: startTime..., displayedComponents: [.date, .hourAndMinute])
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(12)
                        .atriaInsetCard(tint: .cyan)
                        Button(action: saveTimes) {
                            Text("Save times")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.cyan)
                        .disabled(!timesChanged)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        if let strain = workout.strain {
                            statTile("Strain", String(format: "%.1f", strain), tint: Metrics.electricStrain)
                        }
                        statTile("Duration", durationText(workout.duration), tint: Metrics.electricStrain)
                        statTile("Avg HR", "\(workout.avgHR)", tint: .pink)
                        statTile("Peak HR", "\(workout.peakHR)", tint: .red)
                        if let calories = workout.activeEnergyKilocalories {
                            statTile("Calories", "\(Int(calories.rounded()))", tint: .orange)
                        }
                    }

                    Text("Times and stats come straight from the recorded session — nothing here is estimated or filled in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete workout", systemImage: "trash")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .tint(.red)
                }
                .padding(16)
            }
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete this workout?",
                                isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("Delete workout", role: .destructive) {
                    store.deleteConfirmedWorkout(id: workout.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes it from your history and strain. The recorded sensor data is kept; only this confirmed workout is deleted.")
            }
        }
    }

    private func saveName() {
        guard canSaveName else { return }
        store.renameConfirmedWorkout(id: workout.id, label: trimmedLabel)
        dismiss()
    }

    private func setType(_ type: String) {
        activityType = type
        store.setConfirmedWorkoutActivityType(id: workout.id, activityType: type)
    }

    private func saveTimes() {
        guard timesChanged, endTime > startTime else { return }
        let rest = store.baseline.restingInt ?? 60
        _ = store.updateConfirmedWorkoutWindow(id: workout.id,
                                               newStart: startTime,
                                               newEnd: endTime,
                                               rest: rest,
                                               maxHR: store.profile.maxHR)
        dismiss()
    }

    private func statTile(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.black).monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: tint)
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((interval / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d · h:mm a"
        return formatter
    }()

    private static func rangeText(_ workout: UserConfirmedWorkout) -> String {
        rangeFormatter.string(from: workout.start)
    }
}

/// Manually log a workout for a past window the strap recorded but the detector
/// didn't surface (e.g. a walk or dance you wore the strap for). Metrics are
/// derived from the strap samples in that window — if there were none, it can't
/// be saved, because Atria never invents heart rate or strain.
private struct AtriaAddWorkoutSheet: View {
    @ObservedObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var activityType = "Walk"
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var failed = false

    init(store: SessionStore) {
        self.store = store
        let now = Date()
        _endTime = State(initialValue: now)
        _startTime = State(initialValue: now.addingTimeInterval(-45 * 60))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AtriaPanelSectionHeader(title: "Add workout",
                                            subtitle: "Log a window the strap recorded but didn't auto-detect.")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ACTIVITY TYPE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Menu {
                            ForEach(AtriaActivityWorkoutDetailSheet.activityTypes, id: \.self) { type in
                                Button(type) { activityType = type }
                            }
                        } label: {
                            HStack {
                                Text(activityType).font(.subheadline.weight(.bold))
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .atriaInsetCard(tint: .mint)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("TIME")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        VStack(spacing: 6) {
                            DatePicker("Start", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                            DatePicker("End", selection: $endTime, in: startTime..., displayedComponents: [.date, .hourAndMinute])
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(12)
                        .atriaInsetCard(tint: .cyan)
                    }

                    if failed {
                        Text("No strap heart-rate data in that window, so there's nothing to build a workout from. Pick a time you were wearing the strap.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Atria builds the workout from the strap samples in this window — it never invents heart rate or strain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: add) {
                        Text("Add workout")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Metrics.electricStrain)
                    .disabled(endTime <= startTime)
                }
                .padding(16)
            }
            .navigationTitle("Add workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func add() {
        guard endTime > startTime else { return }
        let rest = store.baseline.restingInt ?? 60
        let result = store.confirmWorkoutWindowForUI(start: startTime,
                                                     end: endTime,
                                                     rest: rest,
                                                     maxHR: store.profile.maxHR,
                                                     source: "manual_activity_add",
                                                     activityType: activityType)
        if result != nil {
            dismiss()
        } else {
            failed = true
        }
    }
}
