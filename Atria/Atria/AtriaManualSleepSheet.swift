import SwiftUI

struct AtriaManualSleepSheet: View {
    let onSave: (Date, Date, Bool) -> Void
    private let reviewDetectedTypeText: String?
    /// Detected night backing this review, when one exists (2026-07-07 design
    /// handoff): drives the sensor-evidence card (stage strip, efficiency).
    /// nil for plain manual entry -- the card renders nothing.
    private let evidenceNight: SleepHistorySnapshot.Night?
    /// Sleep performance for the detected night, computed by the caller with
    /// its own need context. nil hides the tile (never a fabricated percent).
    private let evidencePerformancePercent: Int?
    /// True when saving re-derives sensor stage bars over the chosen window
    /// (the "adjust an auto-detected sleep" flow) rather than saving a blank
    /// manual entry. Drives honest Stages copy — see `stageEvidenceCard`.
    private let preservesSensorStages: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var isNap = false
    @State private var typeWasManuallyEdited = false
    @State private var start = Date().addingTimeInterval(-8 * 60 * 60)
    @State private var end = Date()

    init(initialStart: Date? = nil,
         initialEnd: Date? = nil,
         initialIsNap: Bool? = nil,
         preservesSensorStages: Bool = false,
         evidenceNight: SleepHistorySnapshot.Night? = nil,
         evidencePerformancePercent: Int? = nil,
         onSave: @escaping (Date, Date, Bool) -> Void) {
        self.onSave = onSave
        self.preservesSensorStages = preservesSensorStages
        self.evidenceNight = evidenceNight
        self.evidencePerformancePercent = evidencePerformancePercent
        self.reviewDetectedTypeText = initialIsNap.map { $0 ? "Nap" : "Sleep" }
        let resolvedEnd = initialEnd ?? Date()
        let resolvedStart = initialStart ?? resolvedEnd.addingTimeInterval(-8 * 60 * 60)
        _start = State(initialValue: resolvedStart)
        _end = State(initialValue: max(resolvedEnd, resolvedStart.addingTimeInterval(60)))
        _isNap = State(initialValue: initialIsNap ?? false)
        _typeWasManuallyEdited = State(initialValue: initialIsNap != nil)
    }

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
        // Sensor-backed adjustments may save a SHORT sleep: the 3-hour floor
        // is a fabrication guard for blank manual adds, but it blocked the
        // real correction "this detected nap was actually sleep" whenever the
        // captured window was under 3h (user-reported 2026-07-07).
        if preservesSensorStages {
            return duration >= AggregateSleepCandidate.napMinimumDuration
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
        if let reviewDetectedTypeText {
            let current = isNap ? "Nap" : "Sleep"
            if typeWasManuallyEdited, current != reviewDetectedTypeText {
                return "Detected as \(reviewDetectedTypeText). Saving as \(current); adjust the window if needed."
            }
            return "Detected as \(reviewDetectedTypeText). Change type or window before saving."
        }
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
        if preservesSensorStages {
            if duration < AggregateSleepCandidate.napMinimumDuration {
                return "Sleep needs at least 20 minutes."
            }
            return "Ready to save as sleep."
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
                    detectedEvidenceCard
                    typeCard
                    timeCard
                    durationCard
                    stageEvidenceCard
                    footnoteCard
                }
                .padding(20)
            }
            .navigationTitle("\(reviewDetectedTypeText == nil ? "Add" : "Review") \(isNap ? "Nap" : "Sleep")")
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

    /// Sensor-evidence header for a detected night (design handoff): stage
    /// strip with per-stage shares plus performance/efficiency tiles. Every
    /// element is gated on real data -- no stages means an honest line, no
    /// performance means no tile.
    @ViewBuilder
    private var detectedEvidenceCard: some View {
        if let night = evidenceNight {
            VStack(alignment: .leading, spacing: 12) {
                AtriaManualSleepCardHeader(title: "From sensor data",
                                           detail: "What Atria detected for this window.",
                                           systemImage: "waveform.path.ecg",
                                           tint: Metrics.electricSleep)

                if night.displayStageSegments.isEmpty {
                    Text("Stages are still building for this night \u{2014} heart-rate estimate only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    GeometryReader { proxy in
                        let total = max(night.duration, 1)
                        HStack(spacing: 2) {
                            ForEach(night.displayStageSegments) { segment in
                                Rectangle()
                                    .fill(evidenceStageTint(segment.stage))
                                    .frame(width: max(5, proxy.size.width * CGFloat(segment.duration / total)))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                    .frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    HStack(spacing: 12) {
                        ForEach(evidenceStageShares, id: \.stage) { share in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(evidenceStageTint(share.stage))
                                    .frame(width: 7, height: 7)
                                Text("\(share.stage.label) \(share.percent)%")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if evidencePerformancePercent != nil || night.sleepEfficiency != nil {
                    HStack(spacing: 10) {
                        if let performance = evidencePerformancePercent {
                            evidenceStatTile(title: "Performance", value: "\(performance)%")
                        }
                        if night.sleepEfficiency != nil {
                            evidenceStatTile(title: "Efficiency", value: night.sleepEfficiencyText)
                        }
                    }
                }
            }
            .manualSleepCard(tint: Metrics.electricSleep)
            .accessibilityElement(children: .combine)
        }
    }

    /// Stage shares in display order, folded (SWS into Deep), zero stages
    /// dropped -- percentages of the night's total window.
    private var evidenceStageShares: [(stage: SleepStageKind, percent: Int)] {
        guard let night = evidenceNight, night.duration > 0 else { return [] }
        var durations: [SleepStageKind: TimeInterval] = [:]
        for segment in night.displayStageSegments {
            durations[segment.stage.displayStage, default: 0] += segment.duration
        }
        return SleepStageKind.displayOrder.compactMap { stage in
            guard let duration = durations[stage], duration > 0 else { return nil }
            return (stage, Int((duration / night.duration * 100).rounded()))
        }
    }

    private func evidenceStageTint(_ stage: SleepStageKind) -> Color {
        switch stage {
        case .awake: return .orange
        case .light: return .cyan.opacity(0.65)
        case .rem: return .blue
        case .sws, .deep: return .indigo
        }
    }

    private func evidenceStatTile(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline.weight(.bold).monospacedDigit())
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Metrics.electricSleep.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                                       detail: preservesSensorStages ? "Re-derived from sensor data for this window." : "Manual entries save the window only.",
                                       systemImage: preservesSensorStages ? "waveform.path.ecg" : "checklist.unchecked",
                                       tint: .purple)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(preservesSensorStages
                     ? "Atria recomputes Awake, Light, REM, SWS, and Deep from the heart-rate samples inside this window. Adjusting the boundaries keeps the sensor-derived stages — it does not blank them, and it does not fabricate any."
                     : "Awake, Light, REM, SWS, and Deep stay blank until Atria has sensor-derived stage evidence. This manual \(isNap ? "nap" : "sleep") will not fabricate stage bars.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(preservesSensorStages
                                ? "Sleep stages are re-derived from sensor data for the chosen window."
                                : "No manual stage estimate. Sleep stages stay blank until sensor-derived stage evidence exists.")
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
