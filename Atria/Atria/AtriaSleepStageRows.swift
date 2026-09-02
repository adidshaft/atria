import SwiftUI

// P5 — WHOOP-style per-stage rows with occurrence strips (2026-08-20 sleep-
// stage design, Track 2 §2.1). One row per display stage in
// `SleepStageKind.displayOrder` ([awake, light, rem, deep]): palette color
// dot, stage name, largest-remainder percent, real duration, and a one-lane
// occurrence strip of capsules positioned at the stage's real wall-clock
// spans across the sleep window (clock labels at the strip edges).
//
// Honesty rules (design §2.0, binding):
//   - Consumes ONLY `night.displayStageSegments` (already honesty-gated and
//     SWS→Deep folded), the night's real window, and estimate provenance —
//     never raw `stageSegments`.
//   - Percent authority is `AtriaSleepStagePresentation.shares` — the same
//     largest-remainder shares-of-classified-time basis as the hypnogram
//     legend, so the two surfaces can never disagree. Durations are real
//     minutes, never re-derived from percent.
//   - Occurrence capsules come from the same pure math as the hypnogram
//     (`AtriaSleepHypnogramPresentation.spans(for:)`) — a legend affordance,
//     not a second timeline grammar. Unscored gaps stay empty lane; nothing
//     is interpolated.
//   - `isEstimated` ⇒ `AtriaSleepStageEstimateLabel.title` is co-rendered as
//     this component's own header — the labeled hypnogram card elsewhere on
//     the screen is not enough on its own (2.0 invariant).
//   - Stage-specific confidence (design §1.4): on estimate nights the Deep
//     row carries a hedge caption — deep is the least reliable HR-only call.
//     REM carries none (the strongest HR-only call per the brief).
//   - The confidence tier input is P2's `SleepStageEstimateConfidenceTier`
//     (defaulting `.standard`), fed from `night.estimateConfidenceTier` at
//     the mount. Display-only: no tier grants duration credit, auto-confirm,
//     or validated authority, and the estimate label is tier-independent.

/// Pure row math for `AtriaSleepStageRowStrip`, unit-testable without SwiftUI.
enum AtriaSleepStageRowStripPresentation {
    /// New copy (design §1.4) — pinned by AtriaSleepStageRowStripTests, and
    /// deliberately NOT one of the strings pinned by
    /// AtriaSleepDetailLegibilityTests (`unavailableStagesDetail` is untouched).
    static let deepEstimateHedgeCaption = "Hardest to detect from HR alone"

    struct Row: Equatable, Identifiable {
        let stage: SleepStageKind
        let name: String
        /// Largest-remainder share of classified time; present rows sum to
        /// 100. A stage with no classified time reads an honest 0.
        let percent: Int
        /// Real minutes of this displayed stage — never re-derived from percent.
        let minutes: Int
        /// This stage's occurrence spans on the real time axis — exactly
        /// `AtriaSleepHypnogramPresentation.spans(for:)` filtered to the row.
        let spans: [AtriaSleepHypnogramPresentation.Span]
        /// Stage-specific confidence hedge (estimate nights: Deep only).
        let hedgeCaption: String?

        var id: String { stage.rawValue }
    }

    /// The component's own mandatory header: estimate nights co-render the
    /// estimate title with the stage-derived pixels below it (2.0 invariant).
    static func headerTitle(isEstimated: Bool) -> String {
        isEstimated ? AtriaSleepStageEstimateLabel.title : "Stages"
    }

    /// Per-stage hedge slot (design §1.4). Only the Deep row on estimate
    /// nights carries copy today — deep is the least reliable HR-only call
    /// in either tier, so `.strongRR` keeps the hedge; the tier input exists
    /// so tier-differentiated per-stage copy never needs a signature change.
    static func hedgeCaption(for stage: SleepStageKind,
                             isEstimated: Bool,
                             tier: SleepStageEstimateConfidenceTier = .standard) -> String? {
        guard isEstimated, stage.displayStage == .deep else { return nil }
        return deepEstimateHedgeCaption
    }

    /// One row per display stage — every `displayOrder` stage is always
    /// present, so an estimate night whose reconciled timeline carries no
    /// awake still shows an honest "Awake · 0%" row instead of hiding it.
    static func rows(for segments: [SleepStageSegment],
                     windowStart: Date,
                     windowEnd: Date,
                     isEstimated: Bool,
                     tier: SleepStageEstimateConfidenceTier = .standard) -> [Row] {
        let shares = AtriaSleepStagePresentation.shares(for: segments)
        let spans = AtriaSleepHypnogramPresentation.spans(for: segments,
                                                          windowStart: windowStart,
                                                          windowEnd: windowEnd)
        var durations: [SleepStageKind: TimeInterval] = [:]
        for segment in segments {
            durations[segment.stage.displayStage, default: 0] += max(0, segment.duration)
        }
        return SleepStageKind.displayOrder.map { stage in
            Row(stage: stage,
                name: stage.label,
                percent: shares.first(where: { $0.stage == stage })?.percent ?? 0,
                minutes: Int(((durations[stage] ?? 0) / 60).rounded()),
                spans: spans.filter { $0.stage == stage },
                hedgeCaption: hedgeCaption(for: stage, isEstimated: isEstimated, tier: tier))
        }
    }

    /// Row duration text: real minutes through the shared formatter; a stage
    /// with no classified time reads an explicit "0m", not an unknown "--".
    static func durationText(minutes: Int) -> String {
        minutes > 0 ? AtriaSleepHypnogramPresentation.durationText(minutes: minutes) : "0m"
    }

    // MARK: - P7 typical-range sub-strip (design §2.1, AtriaStageTypicalRange)

    /// New copy (P7) — the typical sub-strips are a second, DURATION-scaled
    /// axis under the wall-clock occurrence lanes, so the card says what the
    /// extra pixels mean instead of leaving mystery bands. Rendered once per
    /// card, only when at least one typical band is present.
    static let typicalRangeFootnote =
        "Thin bars compare this sleep with your typical range (hatched) from recent motion-checked nights"

    /// Pure geometry for one row's typical sub-strip: tonight's stage
    /// duration and the typical band, both as fractions of one shared
    /// duration scale. The scale is the sleep window (so sub-strips across
    /// rows stay mutually comparable), widened only when the typical band or
    /// tonight's duration exceeds it — nothing is ever clipped away.
    struct TypicalBand: Equatable {
        let bandStartFraction: Double
        let bandEndFraction: Double
        /// Tonight's real stage duration on the same scale.
        let nightFraction: Double
    }

    static func typicalBand(range: ClosedRange<TimeInterval>?,
                            nightSeconds: TimeInterval,
                            windowSeconds: TimeInterval) -> TypicalBand? {
        guard let range, range.upperBound > range.lowerBound, range.lowerBound >= 0 else {
            return nil
        }
        let scale = max(windowSeconds, range.upperBound, nightSeconds)
        guard scale > 0 else { return nil }
        return TypicalBand(bandStartFraction: range.lowerBound / scale,
                           bandEndFraction: range.upperBound / scale,
                           nightFraction: min(1, max(0, nightSeconds / scale)))
    }

    /// Accessibility/legibility text for a row's typical band — real
    /// durations through the shared formatter, never re-derived fractions.
    static func typicalText(range: ClosedRange<TimeInterval>) -> String {
        let low = durationText(minutes: Int((range.lowerBound / 60).rounded()))
        let high = durationText(minutes: Int((range.upperBound / 60).rounded()))
        return "Typically \(low)–\(high)"
    }
}

/// The per-stage row strip (design §2.1). Mounted in the sleep review sheet
/// in place of the P4 percent bars — the occurrence strip subsumes them: the
/// number keeps the shares basis, and the pixels show WHERE each stage
/// occurred on the real clock instead of an abstract percent width.
struct AtriaSleepStageRowStrip: View {
    let segments: [SleepStageSegment]
    let windowStart: Date
    let windowEnd: Date
    let isEstimated: Bool
    /// P2's prefix-derived display tier (`night.estimateConfidenceTier`).
    var confidenceTier: SleepStageEstimateConfidenceTier = .standard
    /// A travel night renders in the clock it was slept in (GAP-07).
    var eventTimeZoneIdentifier: String? = nil
    /// P7 (optional, default nil so no mount site churns): per-stage typical
    /// bands from `AtriaStageTypicalRange.ranges` — the validated-nights-only,
    /// 14-night-gated baseline. When present, each stage row gains a subtle
    /// duration sub-strip comparing this sleep against the hatched typical
    /// band (the design's WHOOP reference). Nil, or a stage with no band,
    /// renders exactly what P5 rendered — nothing extra.
    var typicalRanges: [SleepStageKind: ClosedRange<TimeInterval>]? = nil

    private var rows: [AtriaSleepStageRowStripPresentation.Row] {
        AtriaSleepStageRowStripPresentation.rows(for: segments,
                                                 windowStart: windowStart,
                                                 windowEnd: windowEnd,
                                                 isEstimated: isEstimated,
                                                 tier: confidenceTier)
    }

    private var eventCalendar: Calendar {
        EventCivilTime.eventCalendar(timeZoneIdentifier: eventTimeZoneIdentifier,
                                     fallback: .current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            // The estimate marker stays attached to these rows — mandatory
            // whenever stage-derived pixels render (2.0 invariant).
            Text(AtriaSleepStageRowStripPresentation.headerTitle(isEstimated: isEstimated))
                .atriaEyebrow()

            ForEach(rows) { row in
                stageRow(row)
            }

            // Clock-edge context for the aligned occurrence lanes above: the
            // strips all span the exact saved sleep window.
            HStack {
                Text(AtriaSleepHypnogramPresentation.clockLabel(windowStart, calendar: eventCalendar))
                Spacer(minLength: 0)
                Text(AtriaSleepHypnogramPresentation.clockLabel(windowEnd, calendar: eventCalendar))
            }
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.tertiary)

            // P7: the typical sub-strips are duration-scaled, not wall-clock
            // — say so once whenever any of them rendered above.
            if hasTypicalBands {
                Text(AtriaSleepStageRowStripPresentation.typicalRangeFootnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AtriaDesignTokens.Spacing.md)
        .atriaInsetCard(tint: Metrics.electricSleep)
    }

    private func stageRow(_ row: AtriaSleepStageRowStripPresentation.Row) -> some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.xs) {
            HStack(spacing: AtriaDesignTokens.Spacing.sm) {
                Circle()
                    .fill(AtriaSleepStagePalette.color(for: row.stage))
                    .frame(width: 8, height: 8)
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                // 2026-08-29 minimalism pass: the value reads primary, the
                // unit-ish duration secondary — no stage-tinted text; the dot
                // and the lanes below carry the stage color.
                Text("\(row.percent)%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(AtriaSleepStageRowStripPresentation.durationText(minutes: row.minutes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            occurrenceLane(row)
            if let band = typicalBand(for: row) {
                typicalLane(stage: row.stage, band: band)
            }
            if let hedge = row.hedgeCaption {
                Text(hedge)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(for: row))
    }

    private var windowSeconds: TimeInterval {
        windowEnd.timeIntervalSince(windowStart)
    }

    private func typicalBand(for row: AtriaSleepStageRowStripPresentation.Row)
        -> AtriaSleepStageRowStripPresentation.TypicalBand? {
        AtriaSleepStageRowStripPresentation.typicalBand(
            range: typicalRanges?[row.stage],
            nightSeconds: TimeInterval(row.minutes) * 60,
            windowSeconds: windowSeconds
        )
    }

    private var hasTypicalBands: Bool {
        rows.contains { typicalBand(for: $0) != nil }
    }

    /// P7 typical sub-strip: one thin duration-scaled lane — a solid bar for
    /// this sleep's real stage duration and a hatched/soft band across the
    /// typical range (mean ± 1 SD over recent motion-validated nights). Drawn
    /// only when a real 14-night baseline exists; absent bands render
    /// nothing, never a placeholder.
    private func typicalLane(stage: SleepStageKind,
                             band: AtriaSleepStageRowStripPresentation.TypicalBand) -> some View {
        let color = AtriaSleepStagePalette.color(for: stage)
        return Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: size.height / 2)
            context.fill(track, with: .color(color.opacity(0.08)))
            // This sleep, solid (subtler than the occurrence capsules above —
            // this lane is comparison context, not the timeline).
            let nightWidth = band.nightFraction * size.width
            if nightWidth > 0 {
                let night = Path(roundedRect: CGRect(x: 0, y: 0,
                                                     width: max(2, nightWidth),
                                                     height: size.height),
                                 cornerRadius: size.height / 2)
                context.fill(night, with: .color(color.opacity(0.55)))
            }
            // The typical range, hatched over a soft fill.
            let bandWidth = max(2, (band.bandEndFraction - band.bandStartFraction) * size.width)
            let bandX = min(band.bandStartFraction * size.width, size.width - bandWidth)
            let bandRect = CGRect(x: max(0, bandX), y: 0,
                                  width: bandWidth, height: size.height)
            context.drawLayer { layer in
                layer.clip(to: Path(roundedRect: bandRect, cornerRadius: size.height / 2))
                layer.fill(Path(bandRect), with: .color(color.opacity(0.16)))
                var hatch = Path()
                var x = bandRect.minX - size.height
                while x < bandRect.maxX + size.height {
                    hatch.move(to: CGPoint(x: x, y: bandRect.maxY))
                    hatch.addLine(to: CGPoint(x: x + size.height, y: bandRect.minY))
                    x += 3
                }
                layer.stroke(hatch, with: .color(color.opacity(0.45)), lineWidth: 1)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    /// One lane of capsules at the row's real wall-clock span fractions.
    /// Empty lane = the stage never occurred (or the time is an unscored
    /// gap) — never padded, never interpolated.
    private func occurrenceLane(_ row: AtriaSleepStageRowStripPresentation.Row) -> some View {
        let color = AtriaSleepStagePalette.color(for: row.stage)
        return Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: size.height / 2)
            context.fill(track, with: .color(color.opacity(0.12)))
            for span in row.spans {
                let width = max(2, (span.endFraction - span.startFraction) * size.width)
                let x = min(span.startFraction * size.width, size.width - width)
                let mark = Path(roundedRect: CGRect(x: max(0, x), y: 0,
                                                    width: width, height: size.height),
                                cornerRadius: size.height / 2)
                // 2026-08-29 minimalism pass: capsules keep the stage color
                // (they are the data) at reduced opacity so the strip reads
                // calmer against the neutral text around it.
                context.fill(mark, with: .color(color.opacity(0.85)))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private func accessibilityText(for row: AtriaSleepStageRowStripPresentation.Row) -> String {
        var parts = [
            row.name,
            "\(row.percent) percent",
            AtriaSleepStageRowStripPresentation.durationText(minutes: row.minutes)
        ]
        // The typical band is spoken only when it is drawn (same gate as the
        // sub-strip): a real baseline range in real durations.
        if typicalBand(for: row) != nil, let range = typicalRanges?[row.stage] {
            parts.append(AtriaSleepStageRowStripPresentation.typicalText(range: range))
        }
        if let hedge = row.hedgeCaption { parts.append(hedge) }
        return parts.joined(separator: ", ")
    }
}
