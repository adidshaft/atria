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
        let featured = insights.first
        return HStack(spacing: 10) {
            if let featured {
                AtriaInsightPictureRing(insight: featured, size: 34)
            } else {
                Image(systemName: "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .atriaEyebrow()
                    if !insights.isEmpty {
                        Text("\(insights.count)")
                            .font(AtriaDesignTokens.Typography.eyebrow)
                            .tracking(AtriaDesignTokens.Typography.eyebrowTracking)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(featured?.headline ?? "Open for the full read")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                if let detail = featured?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2.weight(.medium))
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
        VStack(alignment: .leading, spacing: 4) {
            Text(insight.headline)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .foregroundStyle(.primary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text(insight.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, compact ? 6 : 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.headline). \(insight.detail)")
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
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: insight.isPositive
                                      ? "arrow.up.right.circle.fill"
                                      : "arrow.down.right.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(insight.isPositive
                                                     ? Metrics.electricGreen
                                                     : Metrics.electricRed)
                                    .symbolRenderingMode(.hierarchical)
                                    .frame(width: 36, height: 36)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(insight.tagLabel)
                                        .font(.headline)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .layoutPriority(2)
                                    Text("\(insight.headline). \(insight.detail)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 8)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(insight.tagLabel). \(insight.headline). \(insight.detail)")
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
}
