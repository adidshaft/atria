import SwiftUI

extension AtriaLearnedInsight {
    /// Identity + valence color for Today's read. Recovery keeps the
    /// green/red grade; sleep uses gold when short; strain stays electric blue.
    var pictureTint: Color {
        switch (ringFamily, isPositive) {
        case (.recovery, true), (.sleep, true), (.other, true):
            return Metrics.electricGreen
        case (.recovery, false):
            return Metrics.electricRed
        case (.sleep, false):
            return Metrics.electricYellow
        case (.strain, _):
            return Metrics.electricStrain
        case (.other, false):
            return Color.secondary
        }
    }
}

/// Physiological reads as a ledger. Interactive chrome is glass; the list
/// itself is naked so a sheet is not a card inside a card. Master Sleep /
/// Recovery / Strain rings already live on Today — this surface is sentences.
struct AtriaLearnedInsightsBoard: View {
    enum Style {
        /// Naked list for the Insights sheet.
        case full
        /// One-line glass rail for Today. Tap opens the Insights sheet.
        case compactBar
    }

    let insights: [AtriaLearnedInsight]
    var ledger: [AtriaLearnedInsight] = []
    var title: String = "Today's read"
    var subtitle: String = "What moved you"
    var showsHeader: Bool = true
    /// When true, wrap the compact bar in a quiet material. The full sheet
    /// must stay a naked list.
    var usesOwnCard: Bool = true
    var style: Style = .full
    /// Day / Week / Month ledger window. Compact Today bar ignores this.
    var lookback: AtriaInsightLookback = .week

    var body: some View {
        Group {
            if usesOwnCard && style == .compactBar {
                styledContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .glassEffect(
                        .regular.interactive(),
                        in: .rect(cornerRadius: 19)
                    )
            } else {
                styledContent
            }
        }
    }

    @ViewBuilder
    private var styledContent: some View {
        switch style {
        case .compactBar:
            compactBar
        case .full:
            board
        }
    }

    private var compactBar: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let summary = compactReadSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compactBarAccessibilityLabel)
        .accessibilityIdentifier("atria.today.read")
        .accessibilityHint("Opens the full insights detail.")
        .accessibilityAddTraits(.isButton)
    }

    private var compactReadSummary: String? {
        AtriaLearnedInsight.compactReadSummary(from: insights, fallback: earlierReads)
    }

    private var compactBarAccessibilityLabel: String {
        if let summary = compactReadSummary {
            return "\(title). \(summary)"
        }
        return title
    }

    private var earlierReads: [AtriaLearnedInsight] {
        AtriaLearnedInsights.ledgerRows(
            ledger: ledger,
            lookback: lookback,
            now: Date(),
            calendar: .current
        )
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            if showsHeader {
                AtriaPanelSectionHeader(title: title, subtitle: subtitle)
            }
            if insights.isEmpty && earlierReads.isEmpty {
                Text("Atria writes a specific read here once nights of sleep, recovery, and strain exist. Raw files can be retired; these stay.")
                    .font(AtriaDesignTokens.Typography.metricCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(insights.enumerated()), id: \.element.id) { index, insight in
                    if index > 0 {
                        Divider()
                    }
                    nakedRow(insight)
                }
                if !earlierReads.isEmpty {
                    Text(lookback == .day ? "Captured read" : "\(lookback.title) reads")
                        .font(.headline)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(earlierReads.enumerated()), id: \.element.id) { index, insight in
                        if index > 0 {
                            Divider()
                        }
                        nakedRow(insight, compact: true)
                    }
                }
            }
        }
    }

    private func nakedRow(_ insight: AtriaLearnedInsight, compact: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(insight.pictureTint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.headline)
                    .font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !compact, !insight.detail.isEmpty {
                    Text(insight.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, compact ? 6 : 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.headline). \(insight.detail)")
    }
}

/// Today's read sheet: sentences for last night, then earlier captures.
/// Glass only on the close control. No second Sleep / Recovery / Strain rings.
struct AtriaLearnedInsightsSheet: View {
    let insights: [AtriaLearnedInsight]
    var ledger: [AtriaLearnedInsight] = []
    var tagged: [AtriaInsight] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var lookback: AtriaInsightLookback = .day

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if AtriaAppReviewDemo.isActive {
                        AtriaSampleDataBadge(compact: true)
                    }
                    Picker("Range", selection: $lookback) {
                        ForEach(AtriaInsightLookback.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("atria.insights.lookback")
                    AtriaLearnedInsightsBoard(
                        insights: lookback == .day ? insights : [],
                        ledger: ledger,
                        showsHeader: false,
                        usesOwnCard: false,
                        lookback: lookback
                    )
                    if !tagged.isEmpty {
                        Divider()
                        Text("From your tags")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(tagged.prefix(5)) { insight in
                            taggedInsightRow(insight)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: horizontalSizeClass == .regular ? 640 : .infinity,
                       alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Today's read")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close")
                }
            }
        }
        .atriaDemoSampleBadge()
    }

    private func taggedInsightRow(_ insight: AtriaInsight) -> some View {
        let up = insight.isPositive
        let tint = up ? Metrics.electricGreen : Metrics.electricRed
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.tagLabel)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !insight.headline.isEmpty {
                    Text(insight.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(insight.compactDeltaText)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.tagLabel). \(insight.headline). \(insight.detail)")
    }
}
