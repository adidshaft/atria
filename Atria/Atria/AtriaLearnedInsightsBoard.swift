import SwiftUI

/// Physiological reads as a ledger. The first insight is the featured read;
/// the rest sit as compact rail rows. Kind color carries the metric, not
/// a generic good/bad palette.
struct AtriaLearnedInsightsBoard: View {
    let insights: [AtriaLearnedInsight]
    var title: String = "Today's read"
    var subtitle: String = "What moved you"
    var showsHeader: Bool = true
    /// When true, wrap the board in a card. Today and Journal want that;
    /// Insights already sits inside `AtriaInsightsCard`.
    var usesOwnCard: Bool = true

    var body: some View {
        Group {
            if usesOwnCard {
                board
                    .padding(AtriaDesignTokens.Spacing.md)
                    .atriaCard(cornerRadius: AtriaDesignTokens.Radius.tile, emphasis: .soft)
            } else {
                board
            }
        }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    AtriaPanelSectionHeader(title: title, subtitle: subtitle)
                    if !insights.isEmpty {
                        Text("\(insights.count)")
                            .font(AtriaDesignTokens.Typography.eyebrow)
                            .tracking(AtriaDesignTokens.Typography.eyebrowTracking)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Color.primary.opacity(0.06),
                                in: Capsule()
                            )
                            .accessibilityHidden(true)
                    }
                }
            }
            if insights.isEmpty {
                Text("Atria writes a specific read here once nights of sleep, recovery, and strain exist. Raw files can be retired; these stay.")
                    .font(AtriaDesignTokens.Typography.metricCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                featuredCard(insights[0])
                if insights.count > 1 {
                    VStack(spacing: 0) {
                        ForEach(Array(insights.dropFirst())) { insight in
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 1)
                                .padding(.vertical, 6)
                            compactRow(insight)
                        }
                    }
                }
            }
        }
    }

    private func featuredCard(_ insight: AtriaLearnedInsight) -> some View {
        let tint = Self.railColor(for: insight)
        return HStack(alignment: .top, spacing: 0) {
            Capsule()
                .fill(tint)
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text(insight.emphasisLabel.uppercased())
                        .atriaEyebrow()
                        .foregroundStyle(tint)
                    Spacer(minLength: 8)
                    Image(systemName: insight.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 32, height: 32)
                        .background(tint.opacity(0.18), in: RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        ))
                }
                Text(insight.headline)
                    .font(.title3.weight(.semibold))
                    .tracking(AtriaDesignTokens.Typography.valueTracking)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.detail)
                    .font(AtriaDesignTokens.Typography.metricCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, AtriaDesignTokens.Spacing.md)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(
            cornerRadius: AtriaDesignTokens.Radius.inset,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.headline). \(insight.detail)")
    }

    private func compactRow(_ insight: AtriaLearnedInsight) -> some View {
        let tint = Self.railColor(for: insight)
        return HStack(alignment: .top, spacing: AtriaDesignTokens.Spacing.md) {
            Capsule()
                .fill(tint)
                .frame(width: 3, height: 28)
                .padding(.top, 2)
            Image(systemName: insight.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                ))
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.emphasisLabel.uppercased())
                    .atriaEyebrow()
                    .foregroundStyle(tint)
                Text(insight.headline)
                    .font(AtriaDesignTokens.Typography.metricLabel)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.detail)
                    .font(AtriaDesignTokens.Typography.metricCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.headline). \(insight.detail)")
    }

    /// Kind color, not positive/negative green-orange. Sleep is brass, strain
    /// is ember, pulse is rose, HRV is the Live teal already on the status chip.
    static func railColor(for insight: AtriaLearnedInsight) -> Color {
        switch insight.kind {
        case .sleepDebt, .weeklySleepDebt, .bedtimeSpread:
            return Color(red: 0.78, green: 0.62, blue: 0.38)
        case .loadMismatch, .weeklyStrain, .yesterdayStrain:
            return Color(red: 0.96, green: 0.45, blue: 0.28)
        case .restingHRDrift:
            return Color(red: 0.93, green: 0.32, blue: 0.42)
        case .hrvDrift:
            return Color(red: 0.20, green: 0.78, blue: 0.70)
        case .recoveryDrift, .readiness, .stackedRecovery:
            return Color(red: 0.98, green: 0.74, blue: 0.22)
        case .daySnapshot:
            return Color(red: 0.58, green: 0.64, blue: 0.70)
        }
    }
}
