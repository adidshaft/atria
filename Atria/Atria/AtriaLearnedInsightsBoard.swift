import SwiftUI

extension AtriaLearnedInsight {
    /// Identity + valence color for Today's read pictures. Recovery keeps the
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

/// Colored ring with a pictorial SF Symbol in the hole. Not a metric score —
/// fill is valence so Sleep / Recovery / Strain are recognizable at a glance.
struct AtriaInsightPictureRing: View {
    let insight: AtriaLearnedInsight
    var size: CGFloat = 72

    private var lineWidth: CGFloat { max(5, size * 0.11) }

    var body: some View {
        let tint = insight.pictureTint
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: insight.pictureRingFill)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.55), tint],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360 * insight.pictureRingFill)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Image(systemName: insight.pictureSystemImage)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .minimumScaleFactor(0.6)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Physiological reads as a ledger. Interactive chrome is glass; the list
/// itself is naked so a sheet is not a card inside a card. Picture rings
/// carry Sleep / Recovery / Strain color without a left rail.
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
    /// Three-ring hero for Sleep / Recovery / Strain. Sheet-only.
    var showsRingHero: Bool = false
    /// Day / Week / Month ledger window. Compact Today bar ignores this.
    var lookback: AtriaInsightLookback = .week

    var body: some View {
        Group {
            if usesOwnCard && style == .compactBar {
                styledContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
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
        let hero = AtriaLearnedInsight.ringHeroInsights(from: insights)
        return HStack(spacing: 10) {
            if hero.isEmpty {
                Image(systemName: "text.alignleft")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
            } else {
                ForEach(hero) { insight in
                    VStack(spacing: 4) {
                        AtriaInsightPictureRing(insight: insight, size: 38)
                        Text(insight.emphasisLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(insight.pictureTint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(insight.ringFamily.title). \(insight.emphasisLabel). \(insight.headline)")
                }
            }
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

    private var compactBarAccessibilityLabel: String {
        if let featured = insights.first {
            let detail = featured.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(title). \(featured.headline)"
                : "\(title). \(featured.headline). \(detail)"
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

    private var heroInsights: [AtriaLearnedInsight] {
        AtriaLearnedInsight.ringHeroInsights(from: insights)
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
                if showsRingHero, heroInsights.count >= 2 {
                    ringHero(heroInsights)
                }
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

    private func ringHero(_ hero: [AtriaLearnedInsight]) -> some View {
        HStack(spacing: 12) {
            ForEach(hero) { insight in
                VStack(spacing: 8) {
                    AtriaInsightPictureRing(insight: insight, size: 84)
                    Text(insight.ringFamily.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(insight.pictureTint)
                    Text(insight.emphasisLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(insight.ringFamily.title). \(insight.emphasisLabel). \(insight.headline)")
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func nakedRow(_ insight: AtriaLearnedInsight, compact: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AtriaInsightPictureRing(insight: insight, size: compact ? 44 : 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(insight.emphasisLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(insight.pictureTint)
                Text(insight.headline)
                    .font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, compact ? 8 : 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.emphasisLabel). \(insight.headline). \(insight.detail)")
    }
}

/// Today's read sheet: picture rings for Sleep / Recovery / Strain, then the
/// naked scrolling list. Glass only on the close control.
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
                        showsRingHero: lookback == .day,
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
        return HStack(spacing: 12) {
            Image(systemName: insight.symbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            Text(insight.tagLabel)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: up ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(insight.compactDeltaText)
                .font(.headline.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.tagLabel). \(insight.headline). \(insight.detail)")
    }
}
