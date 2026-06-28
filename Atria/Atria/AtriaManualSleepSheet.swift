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
                    stagesCard
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

    private var stagesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaManualSleepCardHeader(title: "Stages",
                                       detail: isNap ? "Estimated nap preview." : "Estimated sleep preview.",
                                       systemImage: "waveform.path.ecg",
                                       tint: .purple)

            ForEach(SleepStageKind.allCases) { stage in
                HStack(spacing: 10) {
                    Label(stage.label, systemImage: AtriaSleepStageGlyph.symbol(for: stage))
                        .foregroundStyle(AtriaSleepStageGlyph.color(for: stage))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(stagePreviewText(stage))
                        .foregroundStyle(.secondary)
                        .font(.subheadline.monospacedDigit())
                }
                .accessibilityLabel("\(stage.label) \(stagePreviewText(stage))")
            }
        }
        .manualSleepCard(tint: .purple)
    }

    private var footnoteCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text("Atria will save this \(isNap ? "nap" : "sleep") locally. Stage bars are an editable estimate from the manual window, not sensor-validated sleep staging.")
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

    private func stagePreviewText(_ stage: SleepStageKind) -> String {
        let fraction: Double
        switch (isNap, stage) {
        case (_, .awake): fraction = isNap ? 0.06 : 0.08
        case (true, .light): fraction = 0.68
        case (false, .light): fraction = 0.47
        case (true, .rem): fraction = 0.08
        case (false, .rem): fraction = 0.17
        case (true, .sws): fraction = 0.12
        case (false, .sws): fraction = 0.16
        case (true, .deep): fraction = 0.06
        case (false, .deep): fraction = 0.12
        }
        return SleepHistorySnapshot.formatDuration(duration * fraction)
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
