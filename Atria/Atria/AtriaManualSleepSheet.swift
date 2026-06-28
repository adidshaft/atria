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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    typeCard
                    timeCard
                    durationCard
                    stageEvidenceCard
                    footnoteCard
                }
                .padding(20)
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

    private var typeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaManualSleepCardHeader(title: "Type",
                                       detail: typeSuggestionText,
                                       systemImage: isNap ? "moon.zzz.fill" : "bed.double.fill",
                                       tint: .cyan)

            HStack(spacing: 8) {
                manualTypeButton(title: "Sleep",
                                 systemImage: "bed.double.fill",
                                 isSelected: !isNap,
                                 isNapValue: false)
                manualTypeButton(title: "Nap",
                                 systemImage: "moon.zzz.fill",
                                 isSelected: isNap,
                                 isNapValue: true)
            }
        }
        .manualSleepCard(tint: .cyan)
    }

    private func manualTypeButton(title: String,
                                  systemImage: String,
                                  isSelected: Bool,
                                  isNapValue: Bool) -> some View {
        Button {
            typeBinding.wrappedValue = isNapValue
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .atriaGlassSelectable(selected: isSelected, tint: .cyan)
        .accessibilityLabel("Save as \(title)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var timeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaManualSleepCardHeader(title: "Window",
                                       detail: "Choose the local time range Atria should save.",
                                       systemImage: "clock.fill",
                                       tint: .blue)

            DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
            DatePicker("End", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
        }
        .manualSleepCard(tint: .blue)
    }

    private var durationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaManualSleepCardHeader(title: "Duration",
                                       detail: validationText,
                                       systemImage: canSave ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                                       tint: canSave ? .green : .orange)

            LabeledContent("Window") {
                Text(durationText)
                    .font(.headline.weight(.semibold).monospacedDigit())
            }
        }
        .manualSleepCard(tint: canSave ? .green : .orange)
    }

    private var stageEvidenceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaManualSleepCardHeader(title: "Stages",
                                       detail: "Manual entries save the window only.",
                                       systemImage: "checklist.unchecked",
                                       tint: .purple)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text("Awake, Light, REM, SWS, and Deep stay blank until Atria has sensor-derived stage evidence. This manual \(isNap ? "nap" : "sleep") will not fabricate stage bars.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("No manual stage estimate. Sleep stages stay blank until sensor-derived stage evidence exists.")
        }
        .manualSleepCard(tint: .purple)
    }

    private var footnoteCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text("Atria will save this \(isNap ? "nap" : "sleep") locally. Manual entries improve duration, nap, and sleep-history continuity; sleep stages require sensor evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .manualSleepCard(tint: .secondary)
    }

    private func applyInferredTypeIfNeeded() {
        guard !typeWasManuallyEdited else { return }
        isNap = inferredIsNap
    }

}

private struct AtriaManualSleepCardHeader: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(AtriaIconTileBackground(cornerRadius: 11, tint: tint))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    func manualSleepCard(tint: Color) -> some View {
        self
            .padding(14)
            .atriaInsetCard(tint: tint)
    }
}
