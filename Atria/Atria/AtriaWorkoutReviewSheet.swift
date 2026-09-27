import SwiftUI
import Charts

/// Add a possible workout (rework 2026-09-27, owner: "review detected workout
/// needs rework throughout"). One native screen instead of a four-step
/// wizard: the heart rate of the window being confirmed, its time, the
/// activity, and — for gym activities — the exercises. Save commits all of it
/// through the same canonical path.
///
/// Kept from the old flow on purpose:
/// - the detector suggests at most a broad type; the style starts unset and
///   resets whenever the type changes (never invented);
/// - Avg/Peak come only from heart rate recorded inside the window, never
///   from the detector's current reading;
/// - no sharing before save (the post-save receipt owns that).
struct AtriaWorkoutReviewSheet: View {
    let draft: AtriaWorkoutReviewDraft
    let loadHeartRate: (DateInterval) async -> [HistoricalArchive.HeartRatePoint]
    let onCancel: () -> Void
    let onSave: @MainActor (AtriaWorkoutReviewResult) async -> UserConfirmedWorkout?

    @State private var start: Date
    @State private var end: Date
    @State private var selectedType: AtriaWorkoutActivityType
    @State private var selectedSubtype: String?
    @State private var selectedExercises: [String] = []
    @State private var heartRate: [HistoricalArchive.HeartRatePoint] = []
    @State private var heartRateLoaded = false
    @State private var isSaving = false

    /// Context shown either side of the window on the chart.
    static let chartMargin: TimeInterval = 15 * 60

    init(draft: AtriaWorkoutReviewDraft,
         loadHeartRate: @escaping (DateInterval) async -> [HistoricalArchive.HeartRatePoint],
         onCancel: @escaping () -> Void,
         onSave: @escaping @MainActor (AtriaWorkoutReviewResult) async -> UserConfirmedWorkout?) {
        self.draft = draft
        self.loadHeartRate = loadHeartRate
        self.onCancel = onCancel
        self.onSave = onSave
        _start = State(initialValue: draft.suggestedStart)
        _end = State(initialValue: draft.suggestedEnd)
        _selectedType = State(initialValue: draft.prompt.suggestedActivityType)
        _selectedSubtype = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    heartRateCard
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                }

                Section("Time") {
                    DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $end, displayedComponents: [.date, .hourAndMinute])
                    if end <= start {
                        Label("End must be after start", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Activity") {
                    ForEach(suggestedTypes) { type in
                        typeRow(type)
                    }
                    NavigationLink {
                        AtriaWorkoutTypePicker(selection: typeBinding)
                    } label: {
                        LabeledContent("All activities",
                                       value: suggestedTypes.contains(selectedType) ? "" : selectedType.rawValue)
                    }
                    if !selectedType.subtypeOptions.isEmpty {
                        Picker("Style", selection: $selectedSubtype) {
                            Text("Not set").tag(String?.none)
                            ForEach(selectedType.subtypeOptions, id: \.self) { option in
                                Text(option).tag(Optional(option))
                            }
                        }
                    }
                }

                if selectedType.supportsExerciseSelection {
                    Section("Exercises") {
                        NavigationLink {
                            AtriaWorkoutExercisePicker(selection: $selectedExercises)
                        } label: {
                            LabeledContent("Exercises",
                                           value: selectedExercises.isEmpty ? "Optional" : "\(selectedExercises.count)")
                        }
                        ForEach(selectedExercises, id: \.self) { exercise in
                            Text(exercise)
                        }
                        .onDelete { selectedExercises.remove(atOffsets: $0) }
                    }
                }
            }
            .navigationTitle("Add workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityLabel("Cancel workout review")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { commitSave() }
                        .fontWeight(.semibold)
                        .disabled(end <= start || isSaving)
                        .accessibilityLabel("Save workout")
                }
            }
            .task(id: windowKey) {
                // Coalesce DatePicker scrubbing into one read.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await reloadHeartRate()
            }
        }
    }

    // MARK: Heart rate

    private var heartRateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(durationText)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Spacer()
                Text(timeRangeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !heartRateLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if heartRate.isEmpty {
                Text("No heart rate was recorded around this time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                chart
                    .frame(height: 140)
            }

            if let stats = windowStats {
                HStack(spacing: 16) {
                    stat("Avg", "\(stats.avg)")
                    stat("Peak", "\(stats.peak)")
                    if stats.missingMinutes > 0 {
                        stat("Gaps", "\(stats.missingMinutes) min")
                    }
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var chart: some View {
        let projection = AtriaActivityTimelineSignalProjection.heartRate(
            samples: heartRate,
            interval: chartInterval,
            targetPointCount: 180
        )
        return Chart {
            RectangleMark(xStart: .value("Start", start),
                          xEnd: .value("End", max(end, start)))
                .foregroundStyle(Color.orange.opacity(0.14))
            ForEach(projection.points, id: \.id) { point in
                LineMark(x: .value("Time", point.t),
                         y: .value("BPM", point.bpm),
                         series: .value("Run", point.segment))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(point.t >= start && point.t <= end ? Color.orange : Color.secondary)
            }
        }
        .chartXScale(domain: chartInterval.start...chartInterval.end)
        // Fit the measured range (a 0–200 axis flattened a real effort).
        .chartYScale(domain: yDomain(projection))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
    }

    private func yDomain(_ projection: AtriaActivityTimelineHeartRateProjection) -> ClosedRange<Int> {
        let low = projection.measuredMinimumBPM ?? 50
        let high = projection.measuredMaximumBPM ?? 150
        let lower = max(30, (low - 10) / 10 * 10)
        let upper = min(230, (high + 19) / 10 * 10)
        return lower...max(upper, lower + 30)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
    }

    private struct WindowStats {
        let avg: Int
        let peak: Int
        let missingMinutes: Int
    }

    /// Measured inside the window only; gaps are minutes with no sample.
    private var windowStats: WindowStats? {
        let inside = heartRate.filter { $0.t >= start && $0.t <= end }
        guard !inside.isEmpty else { return nil }
        let avg = inside.map(\.bpm).reduce(0, +) / inside.count
        let peak = inside.map(\.bpm).max() ?? avg
        let coveredMinutes = Set(inside.map { Int($0.t.timeIntervalSince(start) / 60) }).count
        let totalMinutes = max(1, Int(end.timeIntervalSince(start) / 60))
        return WindowStats(avg: avg, peak: peak, missingMinutes: max(0, totalMinutes - coveredMinutes))
    }

    private var chartInterval: DateInterval {
        DateInterval(start: start.addingTimeInterval(-Self.chartMargin),
                     end: max(end, start).addingTimeInterval(Self.chartMargin))
    }

    private var windowKey: String {
        "\(Int(start.timeIntervalSince1970 / 60))-\(Int(end.timeIntervalSince1970 / 60))"
    }

    @MainActor
    private func reloadHeartRate() async {
        heartRate = await loadHeartRate(chartInterval)
        heartRateLoaded = true
    }

    // MARK: Activity

    private var suggestedTypes: [AtriaWorkoutActivityType] {
        var types = draft.prompt.suggestedActivityTypes
        for common in [AtriaWorkoutActivityType.walking, .running, .strength]
        where !types.contains(common) && types.count < 4 {
            types.append(common)
        }
        return types
    }

    private var typeBinding: Binding<AtriaWorkoutActivityType> {
        Binding(get: { selectedType }, set: { applyWorkoutType($0) })
    }

    private func typeRow(_ type: AtriaWorkoutActivityType) -> some View {
        Button {
            applyWorkoutType(type)
        } label: {
            HStack {
                Label {
                    Text(type.rawValue).foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: type.icon).foregroundStyle(Color.accentColor)
                }
                Spacer()
                if type == selectedType {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityAddTraits(type == selectedType ? .isSelected : [])
    }

    private func applyWorkoutType(_ type: AtriaWorkoutActivityType) {
        selectedType = type
        selectedSubtype = nil
        if !selectedType.supportsExerciseSelection {
            selectedExercises.removeAll()
        }
    }

    // MARK: Save

    private func commitSave() {
        guard !isSaving, end > start else { return }
        isSaving = true
        Task { @MainActor in
            _ = await onSave(AtriaWorkoutReviewResult(
                start: start,
                end: end,
                activityType: selectedType.rawValue,
                activitySubtype: selectedSubtype,
                exerciseNames: selectedExercises,
                strengthSets: draft.strengthSets
            ))
            isSaving = false
        }
    }

    // MARK: Text

    private var durationText: String {
        let minutes = max(1, Int(end.timeIntervalSince(start) / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }

    private var timeRangeText: String {
        "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    private var accessibilitySummary: String {
        var parts = ["Possible workout, \(durationText), \(timeRangeText)"]
        if let stats = windowStats {
            parts.append("average \(stats.avg), peak \(stats.peak) beats per minute")
        } else if heartRateLoaded {
            parts.append("no heart rate recorded")
        }
        return parts.joined(separator: ", ")
    }
}

/// Every activity type, grouped by category, searchable.
struct AtriaWorkoutTypePicker: View {
    @Binding var selection: AtriaWorkoutActivityType
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if search.isEmpty {
                ForEach(AtriaWorkoutActivityType.Category.allCases) { category in
                    let types = AtriaWorkoutActivityType.allCases.filter { $0.category == category }
                    if !types.isEmpty {
                        Section(category.rawValue) {
                            ForEach(types) { row($0) }
                        }
                    }
                }
            } else {
                ForEach(AtriaWorkoutActivityType.allCases.filter {
                    $0.rawValue.localizedCaseInsensitiveContains(search)
                }) { row($0) }
            }
        }
        .searchable(text: $search, prompt: "Search activities")
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ type: AtriaWorkoutActivityType) -> some View {
        Button {
            selection = type
            dismiss()
        } label: {
            HStack {
                Label {
                    Text(type.rawValue).foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: type.icon).foregroundStyle(Color.accentColor)
                }
                Spacer()
                if type == selection {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

/// Exercises for a gym-style workout: grouped catalog, search, and a custom
/// entry when the search matches nothing.
struct AtriaWorkoutExercisePicker: View {
    @Binding var selection: [String]
    @State private var search = ""
    @State private var groups = AtriaWorkoutExerciseCatalog.allGroups()

    var body: some View {
        List {
            if let custom = customCandidate {
                Section {
                    Button {
                        AtriaWorkoutExerciseCatalog.addCustomExercise(custom)
                        groups = AtriaWorkoutExerciseCatalog.allGroups()
                        if !selection.contains(custom) { selection.append(custom) }
                        search = ""
                    } label: {
                        Label("Add \"\(custom)\"", systemImage: "plus.circle.fill")
                    }
                    .accessibilityLabel("Add custom exercise \(custom)")
                }
            }
            ForEach(AtriaWorkoutExerciseCatalog.filteredGroups(search: search, groups: groups)) { group in
                Section(group.title) {
                    ForEach(group.exercises, id: \.self) { exercise in
                        Button {
                            toggle(exercise)
                        } label: {
                            HStack {
                                Text(exercise).foregroundStyle(Color.primary)
                                Spacer()
                                if selection.contains(exercise) {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search exercises")
        .navigationTitle("Exercises")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var customCandidate: String? {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let known = groups.flatMap(\.exercises).contains {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == key
        }
        return known ? nil : trimmed
    }

    private func toggle(_ exercise: String) {
        if let index = selection.firstIndex(of: exercise) {
            selection.remove(at: index)
        } else {
            selection.append(exercise)
        }
    }
}
