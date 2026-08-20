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
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

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
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.tertiary)
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
                Text("\(row.percent)%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(AtriaSleepStageRowStripPresentation.durationText(minutes: row.minutes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            occurrenceLane(row)
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
                context.fill(mark, with: .color(color))
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
        if let hedge = row.hedgeCaption { parts.append(hedge) }
        return parts.joined(separator: ", ")
    }
}
