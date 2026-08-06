import SwiftUI

// Sleep-stages hypnogram (design source: Claude Design "Atria App UI.dc.html",
// "SLEEP · FULL SCROLL" screen, "STAGES · HYPNOGRAM" card):
//   - four lanes top→bottom Awake / REM / Light / Deep, one 16pt lane per
//     stage with 5pt gaps and 40pt lane labels tinted in the stage's own hue
//   - segmented per-lane bars (radius 3) positioned on the real time axis
//   - axis row with the exact clock at both ends and sparse whole hours
//     between ("11:42p · 2a · 4a · 7:24a" — lowercase single-letter am/pm)
//   - per-stage duration tiles under the graph ("1h 34m" / "Deep · 20%")
// Stage hues from the design's stage table: Awake #FFB340, REM #64D2FF,
// Light #4C8DFF, Deep #7B6CF0 (the app's SWS band folds into Deep for
// display, as everywhere else).
//
// Honesty (hard constraint): the timeline renders ONLY from motion-validated
// display segments — `SleepHistorySnapshot.Night.displayStageSegments` is
// already empty for `.hrOnlyEstimate`/`.none` nights, and this card renders
// the existing "Stages need motion data" honest state for them instead of a
// fabricated band.

/// Pure segment→lane / legend / axis math, unit-testable without SwiftUI.
enum AtriaSleepHypnogramPresentation {
    /// Design lane order, top → bottom.
    static let lanes: [SleepStageKind] = [.awake, .rem, .light, .deep]

    struct Span: Equatable {
        let laneIndex: Int
        let stage: SleepStageKind
        let startFraction: Double
        let endFraction: Double
    }

    struct LegendEntry: Equatable {
        let stage: SleepStageKind
        /// Real minutes of this displayed stage — never re-derived from percent.
        let minutes: Int
        /// Largest-remainder share of classified time; entries sum to 100.
        let percent: Int
    }

    struct AxisTick: Equatable {
        let fraction: Double
        let label: String
    }

    static func laneIndex(for stage: SleepStageKind) -> Int {
        lanes.firstIndex(of: stage.displayStage) ?? lanes.count - 1
    }

    /// Segments clipped to the sleep window and normalized to 0...1 fractions
    /// of it. SWS folds into the Deep lane; zero-length or out-of-window
    /// segments drop out. Positions come from the segment's real wall-clock
    /// range — a late segment stays late even when earlier coverage is sparse.
    static func spans(for segments: [SleepStageSegment],
                      windowStart: Date,
                      windowEnd: Date) -> [Span] {
        let windowDuration = windowEnd.timeIntervalSince(windowStart)
        guard windowDuration > 0 else { return [] }
        return segments.compactMap { segment in
            let clippedStart = max(segment.start, windowStart)
            let clippedEnd = min(segment.end, windowEnd)
            guard clippedEnd > clippedStart else { return nil }
            let display = segment.stage.displayStage
            return Span(laneIndex: laneIndex(for: display),
                        stage: display,
                        startFraction: clippedStart.timeIntervalSince(windowStart) / windowDuration,
                        endFraction: clippedEnd.timeIntervalSince(windowStart) / windowDuration)
        }
    }

    /// Real minutes per displayed stage in design lane order, present stages
    /// only. Percent reuses the existing largest-remainder share allocation so
    /// this legend and the review sheet's distribution row can never disagree.
    static func legend(for segments: [SleepStageSegment]) -> [LegendEntry] {
        var durations: [SleepStageKind: TimeInterval] = [:]
        for segment in segments {
            durations[segment.stage.displayStage, default: 0] += max(0, segment.duration)
        }
        guard durations.values.reduce(0, +) > 0 else { return [] }
        let shares = AtriaSleepStagePresentation.shares(for: segments)
        return lanes.compactMap { stage in
            guard let duration = durations[stage], duration > 0 else { return nil }
            return LegendEntry(stage: stage,
                               minutes: Int((duration / 60).rounded()),
                               percent: shares.first(where: { $0.stage == stage })?.percent ?? 0)
        }
    }

    static func durationText(minutes: Int) -> String {
        SleepHistorySnapshot.formatDuration(TimeInterval(minutes) * 60)
    }

    /// Axis ticks for the real window: exact clock at both endpoints, then
    /// whole hours strictly inside it, kept clear of the endpoint labels and
    /// thinned to at most three so the row never crowds.
    static func axisTicks(windowStart: Date,
                          windowEnd: Date,
                          calendar: Calendar) -> [AxisTick] {
        let windowDuration = windowEnd.timeIntervalSince(windowStart)
        guard windowDuration > 0 else { return [] }
        var ticks: [AxisTick] = [AxisTick(fraction: 0,
                                          label: clockLabel(windowStart, calendar: calendar))]
        var interior: [AxisTick] = []
        var hour = nextWholeHour(after: windowStart, calendar: calendar)
        while let current = hour, current < windowEnd {
            let fraction = current.timeIntervalSince(windowStart) / windowDuration
            if fraction > endpointClearance, fraction < 1 - endpointClearance {
                interior.append(AxisTick(fraction: fraction,
                                         label: clockLabel(current, calendar: calendar)))
            }
            hour = calendar.date(byAdding: .hour, value: 1, to: current)
        }
        let stride = max(1, Int((Double(interior.count) / Double(maximumInteriorTicks)).rounded(.up)))
        for (index, tick) in interior.enumerated() where index % stride == 0 {
            ticks.append(tick)
        }
        ticks.append(AxisTick(fraction: 1,
                              label: clockLabel(windowEnd, calendar: calendar)))
        return ticks
    }

    /// Design axis clock: "11:42p" when minutes matter, "2a" on the whole hour.
    static func clockLabel(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour24 = components.hour ?? 0
        let minute = components.minute ?? 0
        let suffix = hour24 >= 12 ? "p" : "a"
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        guard minute > 0 else { return "\(hour12)\(suffix)" }
        return "\(hour12):" + String(format: "%02d", minute) + suffix
    }

    private static let endpointClearance = 0.12
    private static let maximumInteriorTicks = 3

    private static func nextWholeHour(after date: Date, calendar: Calendar) -> Date? {
        let truncated = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return truncated < date
            ? calendar.date(byAdding: .hour, value: 1, to: truncated)
            : truncated
    }
}

/// Shared hypnogram card for the sleep detail sheet and the History day sheet.
/// Fed by display segments + the real sleep window; axis, lanes, and legend
/// derive from data only.
struct AtriaSleepHypnogramCard: View, Equatable {
    enum DisplayState: Equatable {
        case timeline
        /// HR-only night: segments exist in storage but lack validated motion.
        case needsMotion
        /// Hand-typed window: stages will never arrive without sensor data,
        /// so "building"/"calibrating" copy would be a false promise
        /// (2026-08-05 manual-sleep honesty audit).
        case manualEntry
        /// No usable segments/window at all.
        case building
    }

    let segments: [SleepStageSegment]
    let start: Date?
    let end: Date?
    let stageEvidence: SleepStageEvidence
    let provenanceText: String
    let eventTimeZoneIdentifier: String?
    let isManualEntry: Bool

    init(segments: [SleepStageSegment],
         start: Date?,
         end: Date?,
         stageEvidence: SleepStageEvidence,
         provenanceText: String,
         eventTimeZoneIdentifier: String? = nil,
         isManualEntry: Bool = false) {
        self.segments = segments
        self.start = start
        self.end = end
        self.stageEvidence = stageEvidence
        self.provenanceText = provenanceText
        self.eventTimeZoneIdentifier = eventTimeZoneIdentifier
        self.isManualEntry = isManualEntry
    }

    /// The canonical feed: `displayStageSegments` is already honesty-gated
    /// (empty for `.hrOnlyEstimate`/`.none`), so this card can never render a
    /// band that motion evidence does not back.
    init(night: SleepHistorySnapshot.Night) {
        // For withheld-stage states the honest body already names the state,
        // so the provenance line carries confirmation provenance only.
        let provenance: String
        switch night.stageEvidence {
        case .hrOnlyEstimate, .none:
            provenance = night.confirmationText
        default:
            provenance = "\(night.confirmationText) · \(night.stageEvidence.label)"
        }
        self.init(segments: night.displayStageSegments,
                  start: night.start,
                  end: night.end,
                  stageEvidence: night.stageEvidence,
                  provenanceText: provenance,
                  eventTimeZoneIdentifier: night.eventTimeZoneIdentifier,
                  isManualEntry: night.isManualEntry)
    }

    static func displayState(segments: [SleepStageSegment],
                             stageEvidence: SleepStageEvidence,
                             start: Date?,
                             end: Date?,
                             isManualEntry: Bool = false) -> DisplayState {
        // Manual wins over the sensor states: a hand-typed window without
        // segments must say "manual entry", not promise motion or building.
        if isManualEntry, segments.isEmpty { return .manualEntry }
        if stageEvidence == .hrOnlyEstimate { return .needsMotion }
        guard !segments.isEmpty, let start, let end, end > start else { return .building }
        return .timeline
    }

    /// Stage hues from the design file's stage table (dark-first palette).
    static func color(for stage: SleepStageKind) -> Color {
        switch stage.displayStage {
        case .awake: return Color(red: 1.0, green: 0.702, blue: 0.251)      // #FFB340
        case .rem: return Color(red: 0.392, green: 0.824, blue: 1.0)        // #64D2FF
        case .light: return Color(red: 0.298, green: 0.553, blue: 1.0)      // #4C8DFF
        case .sws, .deep: return Color(red: 0.482, green: 0.424, blue: 0.941) // #7B6CF0
        }
    }

    private var state: DisplayState {
        Self.displayState(segments: segments,
                          stageEvidence: stageEvidence,
                          start: start,
                          end: end,
                          isManualEntry: isManualEntry)
    }

    private var eventCalendar: Calendar {
        EventCivilTime.eventCalendar(timeZoneIdentifier: eventTimeZoneIdentifier,
                                     fallback: .current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: AtriaDesignTokens.Spacing.sm) {
                Text("Stages · Hypnogram")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(provenanceText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            switch state {
            case .timeline:
                if let start, let end {
                    lanes(windowStart: start, windowEnd: end)
                    axis(windowStart: start, windowEnd: end)
                    legendTiles
                }
            case .needsMotion:
                honestState(title: "Stage analysis unavailable for this night",
                            detail: "Your sleep duration is saved. Heart rate alone cannot separate stages; this night needs continuous motion evidence before Atria can show a timeline.")
            case .manualEntry:
                honestState(title: "No stages — manual entry",
                            detail: "You entered this window by hand. Atria draws stage timelines only from sensor data. Duration and any overnight vitals for this window are kept.")
            case .building:
                honestState(title: "Stage analysis unavailable for this night",
                            detail: "Your sleep duration is saved. Stages require qualified motion evidence and a validated stage model — hours asleep alone do not create a hypnogram.")
            }
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricSleep)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Timeline

    private func lanes(windowStart: Date, windowEnd: Date) -> some View {
        let spans = AtriaSleepHypnogramPresentation.spans(for: segments,
                                                          windowStart: windowStart,
                                                          windowEnd: windowEnd)
        return VStack(spacing: 5) {
            ForEach(Array(AtriaSleepHypnogramPresentation.lanes.enumerated()),
                    id: \.element) { laneIndex, stage in
                HStack(spacing: AtriaDesignTokens.Spacing.sm) {
                    Text(stage.label)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Self.color(for: stage))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: Self.laneLabelWidth, alignment: .leading)

                    GeometryReader { proxy in
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                                if span.laneIndex == laneIndex {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Self.color(for: span.stage))
                                        .frame(width: max(2, proxy.size.width * (span.endFraction - span.startFraction)),
                                               height: Self.laneHeight)
                                        .offset(x: proxy.size.width * span.startFraction)
                                }
                            }
                        }
                    }
                    .frame(height: Self.laneHeight)
                }
            }
        }
    }

    private func axis(windowStart: Date, windowEnd: Date) -> some View {
        let ticks = AtriaSleepHypnogramPresentation.axisTicks(windowStart: windowStart,
                                                              windowEnd: windowEnd,
                                                              calendar: eventCalendar)
        return GeometryReader { proxy in
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                Text(tick.label)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: min(max(proxy.size.width * tick.fraction, 16),
                                     proxy.size.width - 16),
                              y: proxy.size.height / 2)
            }
        }
        .frame(height: 14)
        .padding(.leading, Self.laneLabelWidth + AtriaDesignTokens.Spacing.sm)
        .accessibilityHidden(true)
    }

    private var legendTiles: some View {
        HStack(spacing: AtriaDesignTokens.Spacing.sm) {
            ForEach(AtriaSleepHypnogramPresentation.legend(for: segments),
                    id: \.stage) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(AtriaSleepHypnogramPresentation.durationText(minutes: entry.minutes))
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Self.color(for: entry.stage))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                    Text("\(entry.stage.label) · \(entry.percent)%")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Self.color(for: entry.stage).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func honestState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityText: String {
        switch state {
        case .timeline:
            let legend = AtriaSleepHypnogramPresentation.legend(for: segments)
            let stages = legend
                .map { "\($0.stage.label) \(AtriaSleepHypnogramPresentation.durationText(minutes: $0.minutes))" }
                .joined(separator: ", ")
            return "Sleep stages hypnogram. \(provenanceText). \(stages)."
        case .needsMotion:
            return "\(provenanceText). Stage analysis unavailable for this night. Your sleep duration is saved; heart rate alone cannot separate stages, so continuous motion evidence is required."
        case .manualEntry:
            return "\(provenanceText). No stages — this window was entered by hand; stage timelines come only from sensor data."
        case .building:
            return "\(provenanceText). Stage analysis unavailable for this night. Sleep duration is saved; stages require qualified motion evidence and a validated stage model."
        }
    }

    private static let laneHeight: CGFloat = 16
    private static let laneLabelWidth: CGFloat = 40
}
