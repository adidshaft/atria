import SwiftUI

struct AtriaManualSleepSheet: View {
    let onSave: (Date, Date, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isNap = false
    @State private var typeWasManuallyEdited = false
    @State private var start = Date().addingTimeInterval(-8 * 60 * 60)
    @State private var end = Date()

    private var durationText: String {
        SleepHistorySnapshot.formatDuration(max(0, end.timeIntervalSince(start)))
    }

    private var duration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }

    private var canSave: Bool {
        guard end > start else { return false }
        if isNap {
            return duration >= AggregateSleepCandidate.napMinimumDuration
                && duration <= AggregateSleepCandidate.napMaximumSpan
        }
        return duration >= AggregateSleepCandidate.strictMinimumDuration
    }

    private var inferredIsNap: Bool {
        AtriaAnalytics.ManualSleep.inferredIsNap(start: start,
                                                 end: end,
                                                 currentSelection: isNap)
    }

    private var typeBinding: Binding<Bool> {
        Binding(
            get: { isNap },
            set: { next in
                typeWasManuallyEdited = true
                isNap = next
            }
        )
    }

    private var typeSuggestionText: String {
        let suggested = inferredIsNap ? "Nap" : "Sleep"
        if typeWasManuallyEdited {
            return "Suggested by the window: \(suggested). Your manual choice is kept."
        }
        return "Atria suggested \(suggested) from duration and time of day."
    }

    private var validationText: String {
        guard end > start else { return "Choose an end time after the start." }
        if isNap {
            if duration < AggregateSleepCandidate.napMinimumDuration {
                return "Naps need at least 20 minutes."
            }
            if duration > AggregateSleepCandidate.napMaximumSpan {
                return "Longer than 3 hours should be saved as sleep."
            }
            return "Ready to save as a nap."
        }
        if duration < AggregateSleepCandidate.strictMinimumDuration {
            return "Sleep needs at least 3 hours."
        }
        return "Ready to save as sleep."
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: typeBinding) {
                    Text("Sleep").tag(false)
                    Text("Nap").tag(true)
                }
                .pickerStyle(.segmented)

                Text(typeSuggestionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                DatePicker("End", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])

                Section("Duration") {
                    LabeledContent("Window") {
                        Text(durationText)
                            .monospacedDigit()
                    }
                    Text(validationText)
                        .font(.caption)
                        .foregroundStyle(canSave ? Color.secondary : Color.orange)
                }

                Section("Stages") {
                    ForEach(SleepStageKind.allCases) { stage in
                        HStack {
                            Label(stage.label, systemImage: AtriaSleepStageGlyph.symbol(for: stage))
                            Spacer()
                            Text(stagePreviewText(stage))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("Atria will save this \(isNap ? "nap" : "sleep") locally and split the window into research stages: Awake, Light, SWS, and Deep.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add \(isNap ? "Nap" : "Sleep")")
            .onAppear(perform: applyInferredTypeIfNeeded)
            .onChange(of: start) { _, _ in applyInferredTypeIfNeeded() }
            .onChange(of: end) { _, _ in applyInferredTypeIfNeeded() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(start, end, isNap)
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func applyInferredTypeIfNeeded() {
        guard !typeWasManuallyEdited else { return }
        isNap = inferredIsNap
    }

    private func stagePreviewText(_ stage: SleepStageKind) -> String {
        let fraction: Double
        switch (isNap, stage) {
        case (_, .awake): fraction = isNap ? 0.06 : 0.08
        case (true, .light): fraction = 0.72
        case (false, .light): fraction = 0.52
        case (true, .sws): fraction = 0.14
        case (false, .sws): fraction = 0.22
        case (true, .deep): fraction = 0.08
        case (false, .deep): fraction = 0.18
        }
        return SleepHistorySnapshot.formatDuration(duration * fraction)
    }
}
