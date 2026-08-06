import SwiftUI

// Journal impact map (design spec 9) — the row that was missing from the
// Journal tab entirely. One hairline-separated row per behavior:
//
//   Watch          significant AND negative  (amber, the app's caution tier)
//   Supports       significant AND positive  (green)
//   No effect yet  logged, but under the gate (tertiary)
//
// It reads the SAME gated statistics as the Behavior Impact chart above it —
// one model, computed once per journal/metric revision — so the two cards can
// never label the same behavior differently.
//
// Named `AtriaBehaviorImpactMapCard` rather than `…ImpactMap` because
// AtriaOverviewSections.swift already owns a fileprivate `AtriaJournalImpactMap`
// (the Overview scatter rail); this is a different surface with a different
// data source and must not shadow it.

struct AtriaBehaviorImpactMapCard: View {
    let model: AtriaBehaviorImpactPresentation.Model

    private var rows: [AtriaBehaviorImpactPresentation.Stat] { model.mapRows() }

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            AtriaPanelSectionHeader(title: "Impact map",
                                    subtitle: "Where each logged behavior stands")

            if rows.isEmpty {
                Text(AtriaBehaviorImpactPresentation.mapEmptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AtriaDesignTokens.Spacing.md)
                    .overlay {
                        RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
                            .stroke(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().opacity(0.4)
                        }
                        AtriaBehaviorImpactMapRow(stat: row)
                    }
                }
            }
        }
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(emphasis: .soft)
    }
}

struct AtriaBehaviorImpactMapRow: View {
    let stat: AtriaBehaviorImpactPresentation.Stat

    static func tint(for classification: AtriaBehaviorImpactPresentation.Classification) -> Color {
        switch classification {
        case .watch: return Metrics.electricStress
        case .supports: return Metrics.electricGreen
        case .noEffectYet: return .secondary
        }
    }

    private var classification: AtriaBehaviorImpactPresentation.Classification {
        stat.classification
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: stat.tag.symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(Self.tint(for: classification))
                .frame(width: 18)
            Text(stat.tag.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Text(classification.label)
                .font(.caption.weight(.bold))
                .foregroundStyle(Self.tint(for: classification))
            Text("\(stat.loggedNights)n")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stat.tag.label), \(classification.label), \(stat.nightsText)")
    }
}
