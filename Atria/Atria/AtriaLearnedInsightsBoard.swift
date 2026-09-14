import SwiftUI

/// Physiological reads as a ledger, not a caption stack. Featured first insight
/// gets a kind-colored rail and a large headline; the rest sit as compact rows.
struct AtriaLearnedInsightsBoard: View {
    let insights: [AtriaLearnedInsight]
    var title: String = "Today's read"
    var subtitle: String = "What moved you"
    var showsHeader: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            if showsHeader {
                AtriaPanelSectionHeader(title: title, subtitle: subtitle)
            }
            if insights.isEmpty {
                Text("Atria writes a specific read here once nights of sleep, recovery, and strain exist. Raw files can be retired; these stay.")
                    .font(AtriaDesignTokens.Typography.metricCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                featuredCard(insights[0])
                ForEach(Array(insights.dropFirst())) { insight in
                    compactRow(insight)
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
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(insight.emphasisLabel.uppercased())
                        .atriaEyebrow()
                        .foregroundStyle(tint)
                    Spacer(minLength: 8)
                    Image(systemName: insight.systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 36, height: 36)
                        .background(tint.opacity(0.16), in: RoundedRectangle(
                            cornerRadius: AtriaDesignTokens.Radius.chip,
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
            .padding(.vertical, 4)
        }
        .padding(AtriaDesignTokens.Spacing.md)
        .atriaCard(cornerRadius: AtriaDesignTokens.Radius.tile, emphasis: .soft)
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.tile, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.headline). \(insight.detail)")
    }

    private func compactRow(_ insight: AtriaLearnedInsight) -> some View {
        let tint = Self.railColor(for: insight)
        return HStack(alignment: .top, spacing: AtriaDesignTokens.Spacing.md) {
            Image(systemName: insight.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                ))
            VStack(alignment: .leading, spacing: 3) {
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
        .padding(.vertical, 2)
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
