import SwiftUI

// Behavior Impact card (design spec 8a): a diverging next-day-recovery chart
// about a single center axis, a top-mover callout carrying the real p-value and
// night counts, an evidence table that names every behavior still learning, and
// the verbatim significance footer.
//
// Every number here is produced by `AtriaBehaviorImpactPresentation.model`
// from the real journal entries and the real daily metric history. There is no
// sample path: when nothing clears the gate, the card prints what it actually
// has (scored nights, logged nights, per-behavior night counts) and says so.

/// The full card. `model` is precomputed off the view body (see
/// `AtriaBehaviorImpactMemo` in the Journal tab) — this view only draws.
struct AtriaBehaviorImpactCard: View {
    let model: AtriaBehaviorImpactPresentation.Model

    @State private var drillInTag: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.lg) {
            AtriaPanelSectionHeader(title: "Behavior impact",
                                    subtitle: AtriaBehaviorImpactPresentation.framing)

            if model.significant.isEmpty {
                AtriaBehaviorImpactBuildingState(model: model)
            } else {
                AtriaBehaviorImpactDivergingChart(model: model) { tag in
                    drillInTag = tag
                }
                if let mover = model.topMover {
                    AtriaBehaviorImpactTopMover(stat: mover)
                }
            }

            if !model.stats.isEmpty {
                AtriaBehaviorImpactEvidenceTable(rows: model.evidenceRows())
            }

            Text(AtriaBehaviorImpactPresentation.significanceFooter)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(emphasis: .soft)
        .sheet(item: Binding(get: { drillInTag.map(AtriaBehaviorImpactDrillInRoute.init(tagRawValue:)) },
                             set: { drillInTag = $0?.tagRawValue })) { route in
            if let detail = model.details[route.tagRawValue],
               let stat = model.stats.first(where: { $0.id == route.tagRawValue }) {
                AtriaBehaviorImpactDetailSheet(stat: stat, detail: detail)
            }
        }
    }
}

/// `sheet(item:)` needs an Identifiable; the tag raw value already is the id.
struct AtriaBehaviorImpactDrillInRoute: Identifiable, Equatable {
    let tagRawValue: String
    var id: String { tagRawValue }
}

/// Diverging rows about one center line. Positive grows right in green,
/// negative grows left in red, exactly as the design specifies — the direction
/// itself is the reading, so the value label repeats it in words-and-sign.
struct AtriaBehaviorImpactDivergingChart: View {
    let model: AtriaBehaviorImpactPresentation.Model
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            axisLabels

            // ONE center line for the whole chart (design 8a), drawn behind the
            // rows — a per-row tick would read as four separate marks instead of
            // the single axis every bar is measured from.
            ZStack {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 1)
                        .offset(x: proxy.size.width / 2)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
                    ForEach(model.significant) { stat in
                        Button {
                            onSelect(stat.id)
                        } label: {
                            AtriaBehaviorImpactDivergingRow(stat: stat,
                                                            fraction: model.barFraction(for: stat))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(stat.tag.label), \(stat.impactText) next-day recovery, \(stat.nightsText), \(stat.pText)")
                    }
                }
            }
        }
    }

    private var axisLabels: some View {
        let magnitude = Int(model.axisMagnitude)
        return HStack(spacing: 0) {
            Text("-\(magnitude)%")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("0")
                .frame(maxWidth: .infinity, alignment: .center)
            Text("+\(magnitude)%")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
}

struct AtriaBehaviorImpactDivergingRow: View {
    let stat: AtriaBehaviorImpactPresentation.Stat
    let fraction: Double

    /// Design row track height.
    private static let trackHeight: CGFloat = 12

    private var tint: Color {
        stat.impact >= 0 ? Metrics.electricGreen : Metrics.electricRed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(stat.tag.label, systemImage: stat.tag.symbolName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(stat.impactText)
                    .font(.caption.weight(.heavy).monospacedDigit())
                    .foregroundStyle(tint)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                let center = width / 2
                let barWidth = max(2, CGFloat(fraction) * center)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Self.trackHeight / 2, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                        .frame(width: width, height: Self.trackHeight)

                    UnevenRoundedRectangle(topLeadingRadius: stat.impact >= 0 ? 0 : 6,
                                           bottomLeadingRadius: stat.impact >= 0 ? 0 : 6,
                                           bottomTrailingRadius: stat.impact >= 0 ? 6 : 0,
                                           topTrailingRadius: stat.impact >= 0 ? 6 : 0,
                                           style: .continuous)
                        .fill(LinearGradient(colors: stat.impact >= 0
                                                ? [tint.opacity(0.55), tint]
                                                : [tint, tint.opacity(0.55)],
                                             startPoint: .leading,
                                             endPoint: .trailing))
                        .frame(width: barWidth, height: Self.trackHeight)
                        .offset(x: stat.impact >= 0 ? center : center - barWidth)
                }
                .frame(width: width, height: Self.trackHeight)
            }
            .frame(height: Self.trackHeight)
        }
        .contentShape(Rectangle())
    }
}

/// Top-mover callout: the strongest surviving effect, its p-badge, and the real
/// sentence with both night counts in it.
struct AtriaBehaviorImpactTopMover: View {
    let stat: AtriaBehaviorImpactPresentation.Stat

    private var tint: Color {
        stat.impact >= 0 ? Metrics.electricGreen : Metrics.electricRed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Your biggest lever")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(stat.pText)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.16), in: Capsule())
            }
            Text(stat.topMoverSentence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.md)
        .atriaInsetCard(tint: tint)
        .accessibilityElement(children: .combine)
    }
}

/// BEHAVIOR / NIGHTS / p. Rows that have not cleared the gate print "learning"
/// in the p column rather than a p-value they have not earned.
struct AtriaBehaviorImpactEvidenceTable: View {
    let rows: [AtriaBehaviorImpactPresentation.Stat]

    private static let nightsColumnWidth: CGFloat = 58
    private static let pColumnWidth: CGFloat = 62

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("BEHAVIOR")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("NIGHTS")
                    .frame(width: Self.nightsColumnWidth, alignment: .trailing)
                Text("p")
                    .frame(width: Self.pColumnWidth, alignment: .trailing)
            }
            .font(.caption2.weight(.black))
            .foregroundStyle(.tertiary)
            .kerning(0.8)

            ForEach(rows) { row in
                Divider().opacity(0.4)
                HStack(spacing: 8) {
                    Text(row.tag.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(row.loggedNights)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .frame(width: Self.nightsColumnWidth, alignment: .trailing)
                    Text(row.evidencePText)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(row.passesSignificanceGate ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: Self.pColumnWidth, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.tag.label), \(row.nightsText), \(row.evidencePText)")
            }
        }
        .padding(AtriaDesignTokens.Spacing.md)
        .atriaInsetCard(tint: .cyan)
    }
}

/// Nothing has cleared the gate yet. This is not a paywall and not a spinner —
/// it reports the two real counts the gate is waiting on.
struct AtriaBehaviorImpactBuildingState: View {
    let model: AtriaBehaviorImpactPresentation.Model

    private var headline: String {
        model.loggedNights == 0 ? "Impact needs logged nights" : "Impact is learning"
    }

    private var detailText: String {
        guard model.scoredNights > 0 else {
            return "No scored nights yet, so there is nothing to compare a behavior against."
        }
        if model.loggedNights == 0 {
            return "\(model.scoredNights) scored \(model.scoredNights == 1 ? "night" : "nights") in the window, "
                + "none with a behavior logged."
        }
        return "\(model.loggedNights) of \(model.scoredNights) scored nights carry a behavior log. "
            + "No behavior has cleared ≥5 nights and p < 0.10 yet."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.subheadline.weight(.bold))
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(AtriaDesignTokens.Spacing.md)
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .accessibilityElement(children: .combine)
    }
}
