import SwiftUI

struct AtriaSleepStageShare: Equatable {
    let stage: SleepStageKind
    var percent: Int
}

enum AtriaManualSleepMode: Equatable {
    case add
    case review
    case edit
}

enum AtriaSleepStagePresentation {
    static func shares(for segments: [SleepStageSegment]) -> [AtriaSleepStageShare] {
        var durations: [SleepStageKind: TimeInterval] = [:]
        for segment in segments {
            durations[segment.stage.displayStage, default: 0] += max(0, segment.duration)
        }
        let total = durations.values.reduce(0, +)
        guard total > 0 else { return [] }

        var shares = SleepStageKind.displayOrder.compactMap { stage -> AtriaSleepStageShare? in
            guard let duration = durations[stage], duration > 0 else { return nil }
            let rawPercent = duration / total * 100
            return AtriaSleepStageShare(stage: stage, percent: Int(rawPercent.rounded(.down)))
        }
        var remainder = 100 - shares.reduce(0) { $0 + $1.percent }
        let rankedIndices = shares.indices.sorted { left, right in
            let leftDuration = durations[shares[left].stage] ?? 0
            let rightDuration = durations[shares[right].stage] ?? 0
            let leftFraction = leftDuration / total * 100 - Double(shares[left].percent)
            let rightFraction = rightDuration / total * 100 - Double(shares[right].percent)
            return leftFraction == rightFraction ? left < right : leftFraction > rightFraction
        }
        for index in rankedIndices where remainder > 0 {
            shares[index].percent += 1
            remainder -= 1
        }
        return shares
    }
}

private struct AtriaManualSleepHypnogram: View, Equatable {
    private static let lanes: [SleepStageKind] = [.awake, .rem, .light, .deep]

    let segments: [SleepStageSegment]
    let start: Date?
    let end: Date?
    let eventTimeZoneIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stages · Hypnogram")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.lanes) { stage in
                        Text(stage.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AtriaSleepStageGlyph.color(for: stage))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
                .frame(width: 34, height: 76, alignment: .leading)

                VStack(spacing: 4) {
                    Canvas { context, size in
                        draw(in: &context, size: size)
                    }
                    .frame(height: 76)

                    HStack {
                        Text(Self.timeText(start, timeZoneIdentifier: eventTimeZoneIdentifier))
                        Spacer(minLength: 0)
                        Text(Self.timeText(midpoint, timeZoneIdentifier: eventTimeZoneIdentifier))
                        Spacer(minLength: 0)
                        Text(Self.timeText(end, timeZoneIdentifier: eventTimeZoneIdentifier))
                    }
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var midpoint: Date? {
        guard let start, let end, end > start else { return nil }
        return start.addingTimeInterval(end.timeIntervalSince(start) / 2)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        for lane in Self.lanes {
            let y = Self.laneY(lane, height: size.height)
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: y))
            guide.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(guide,
                           with: .color(Color.primary.opacity(0.07)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }

        guard let timelineStart = start ?? segments.map(\.start).min(),
              let timelineEnd = end ?? segments.map(\.end).max(),
              timelineEnd > timelineStart else { return }
        let laneHeight = max(7, min(11, size.height / 7))
        for segment in segments {
            guard let range = AtriaSleepStageHypnogram.normalizedRange(for: segment,
                                                                       timelineStart: timelineStart,
                                                                       timelineEnd: timelineEnd) else { continue }
            let displayStage = segment.stage.displayStage
            let x = size.width * range.lowerBound
            let width = max(2, size.width * (range.upperBound - range.lowerBound))
            let rect = CGRect(x: x,
                              y: Self.laneY(displayStage, height: size.height) - laneHeight / 2,
                              width: min(width, max(0, size.width - x)),
                              height: laneHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: 2.5),
                         with: .color(AtriaSleepStageGlyph.color(for: displayStage)))
        }
    }

    private static func laneY(_ stage: SleepStageKind, height: CGFloat) -> CGFloat {
        switch stage.displayStage {
        case .awake: return height * 0.12
        case .rem: return height * 0.38
        case .light: return height * 0.63
        case .sws, .deep: return height * 0.88
        }
    }

    private static func timeText(_ date: Date?, timeZoneIdentifier: String?) -> String {
        guard let date else { return "--" }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            style.timeZone = timeZone
        }
        return date.formatted(style)
    }
}

struct AtriaManualSleepSheet: View {
    /// Returns whether the save actually persisted. false keeps the sheet
    /// open and shows an inline error instead of silently dismissing
    /// (2026-07-07: failed adjustments used to vanish without a trace).
    let onSave: (Date, Date, Bool) async -> Bool
    /// Removes a saved item, or dismisses an unsaved detection. Keeping this
    /// optional means the plain Add flow has no destructive action.
    private let onRemove: (() async -> Bool)?
    private let mode: AtriaManualSleepMode
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
    @State private var saveFailed = false
    @State private var removeFailed = false
    @State private var showsRemoveConfirmation = false
    @State private var showsStageMethodology = false
    @State private var isSaving = false

    init(initialStart: Date? = nil,
         initialEnd: Date? = nil,
         initialIsNap: Bool? = nil,
         preservesSensorStages: Bool = false,
         evidenceNight: SleepHistorySnapshot.Night? = nil,
         evidencePerformancePercent: Int? = nil,
         mode: AtriaManualSleepMode? = nil,
         onRemove: (() async -> Bool)? = nil,
         onSave: @escaping (Date, Date, Bool) async -> Bool) {
        self.onSave = onSave
        self.onRemove = onRemove
        self.mode = mode ?? {
            guard let evidenceNight else { return .add }
            return evidenceNight.confirmed ? .edit : .review
        }()
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

    private var navigationVerb: String {
        switch mode {
        case .add: "Add"
        case .review: "Review"
        case .edit: "Edit"
        }
    }

    private var itemName: String { isNap ? "nap" : "sleep" }

    private var removeButtonTitle: String {
        mode == .edit ? "Delete \(itemName)" : "Dismiss suggestion"
    }

    private var removeConfirmationTitle: String {
        mode == .edit ? "Delete this \(itemName)?" : "Dismiss this \(itemName) suggestion?"
    }

    private var removeConfirmationMessage: String {
        if mode == .edit {
            return "This removes the saved \(itemName) from Activity. You can add it again later."
        }
        return "Atria will remove this detection from Activity. You can add the \(itemName) manually later."
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
                VStack(alignment: .leading, spacing: 12) {
                    if saveFailed {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Couldn't save \u{2014} the strap has less than 20 minutes of data inside that window. Widen the times to cover when it was worn, then try again.")
                                .font(.caption.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .atriaInsetCard(tint: .orange)
                    }

                    detectedEvidenceCard
                    editorCard
                    stageEvidenceCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .navigationTitle("\(navigationVerb) \(isNap ? "Nap" : "Sleep")")
            .onAppear(perform: applyInferredTypeIfNeeded)
            .onChange(of: start) { _, _ in
                saveFailed = false
                applyInferredTypeIfNeeded()
            }
            .onChange(of: end) { _, _ in
                saveFailed = false
                applyInferredTypeIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: cancelEditing)
                }
                if onRemove != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(removeButtonTitle,
                                   systemImage: "trash",
                                   role: .destructive) {
                                showsRemoveConfirmation = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("Sleep actions")
                    }

                    // Keep the destructive menu and commit action in separate
                    // Liquid Glass groups. An HStack inside one ToolbarItem is
                    // rendered as a nested/merged trailing control on iOS 26.
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        isSaving = true
                        Task { @MainActor in
                            saveFailed = !(await onSave(start, end, isNap))
                            isSaving = false
                        }
                    }
                    .fontWeight(.bold)
                    .disabled(!canSave || isSaving)
                }
            }
            .confirmationDialog(removeConfirmationTitle,
                                isPresented: $showsRemoveConfirmation,
                                titleVisibility: .visible) {
                Button(removeButtonTitle, role: .destructive) {
                    guard let onRemove else { return }
                    isSaving = true
                    Task { @MainActor in
                        if await onRemove() {
                            dismiss()
                        } else {
                            removeFailed = true
                        }
                        isSaving = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(removeConfirmationMessage)
            }
            .alert("Couldn't update Activity", isPresented: $removeFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nothing was removed. Please try again.")
            }
        }
    }

    /// Cancel is deliberately presentation-only. Detector dismissal belongs
    /// exclusively to the confirmed destructive action below; merely opening
    /// a sleep/nap review and backing out must leave the candidate untouched.
    private func cancelEditing() {
        dismiss()
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
                    AtriaManualSleepHypnogram(segments: night.displayStageSegments,
                                              start: night.start,
                                              end: night.end,
                                              eventTimeZoneIdentifier: night.eventTimeZoneIdentifier)

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

    /// Stage shares use the staged wall-clock timeline, not credited sleep
    /// duration, because awake epochs are part of the same evidence window.
    private var evidenceStageShares: [AtriaSleepStageShare] {
        AtriaSleepStagePresentation.shares(for: evidenceNight?.displayStageSegments ?? [])
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

    /// One compact editing surface keeps the three parts of the same decision
    /// (type, bounds, and resulting duration) together instead of presenting
    /// them as three vertically stacked cards.
    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: isNap ? "moon.zzz.fill" : "bed.double.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.cyan)
                    .frame(width: 30, height: 30)
                    .background(AtriaIconTileBackground(cornerRadius: 10, tint: .cyan))

                Text("Sleep details")
                    .font(.headline.weight(.semibold))

                Spacer(minLength: 8)

                Text(durationText)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(canSave ? Color.primary : Color.orange)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Duration \(durationText). \(validationText)")

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

            if reviewDetectedTypeText != nil || typeWasManuallyEdited {
                Text(typeSuggestionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
            DatePicker("End", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)

            if !canSave {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(validationText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .manualSleepCard(tint: canSave ? .cyan : .orange)
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

    private var stageEvidenceCard: some View {
        DisclosureGroup(isExpanded: $showsStageMethodology) {
            Text(stageMethodologyText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: preservesSensorStages ? "waveform.path.ecg" : "checklist.unchecked")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.purple)
                    .frame(width: 30, height: 30)
                    .background(AtriaIconTileBackground(cornerRadius: 10, tint: .purple))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sleep stages")
                        .font(.subheadline.weight(.semibold))
                    Text(preservesSensorStages ? "Sensor-derived for this window" : "Not estimated from manual entry")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .manualSleepCard(tint: .purple)
        .tint(.purple)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sleep stages")
        .accessibilityValue(preservesSensorStages
                            ? "Sensor-derived for this window"
                            : "Not estimated from manual entry")
        .accessibilityHint(showsStageMethodology ? "Collapses stage methodology" : "Shows stage methodology")
    }

    private var stageMethodologyText: String {
        if preservesSensorStages {
            return "Atria re-derives Awake, Light, REM, SWS, and Deep from sensor samples inside the edited window; changing its bounds does not fabricate stages."
        }
        return "This manual \(isNap ? "nap" : "sleep") saves its window and duration only. Stage bars stay blank until sensor evidence is available."
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
