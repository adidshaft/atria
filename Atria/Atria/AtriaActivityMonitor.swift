import SwiftUI

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

            addSleepButton

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
    }

    private var addSleepButton: some View {
        Button {
            onAddSleep()
        } label: {
            Label("Add sleep or nap", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(Metrics.electricSleep)
        .accessibilityHint("Opens the manual sleep editor to log a night or nap the strap missed.")
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
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.black).monospacedDigit())
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }

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
