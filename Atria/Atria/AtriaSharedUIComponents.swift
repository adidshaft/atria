import SwiftUI

struct AtriaLoadingPanel: View, Equatable {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ProgressView()
                .tint(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }
}

struct AtriaPanelSectionHeader: View, Equatable {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AtriaQuickTile: View, Equatable {
    let title: String
    let value: String
    let detail: String
    let system: String
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: AtriaQuickTile, rhs: AtriaQuickTile) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.detail == rhs.detail
            && lhs.system == rhs.system
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: system)
                .font(.caption.weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? tint.opacity(0.95) : tint)
            Text(value)
                .font(.headline.weight(.bold).monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.66) : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: tint)
    }
}

struct AtriaGuidanceCard: View, Equatable {
    let guidance: Coach.Guidance
    let strain: Double

    private var tint: Color { guidance.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)
                Text(guidance.headline)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(targetLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(guidance.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 8)

                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(18, 220 * CGFloat(min(max(strain / 21, 0), 1))), height: 8)

                    if let target = guidance.target {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.72))
                            .frame(width: 3, height: 14)
                            .offset(x: 220 * CGFloat(min(max(target / 21, 0), 1)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Text("strain \(String(format: "%.1f", strain))")
                        .font(.caption.monospacedDigit())
                    Spacer(minLength: 0)
                    Text("0-21 scale")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .atriaInsetCard(tint: tint)
        }
    }

    private var targetLabel: String {
        if let target = guidance.target {
            return "target \(String(format: "%.1f", target))"
        }
        return guidance.state
    }
}

struct AtriaRecoveryMeter: View, Equatable {
    let estimate: Metrics.RecoveryEstimate

    private var tint: Color {
        guard let percent = estimate.percent else { return .orange }
        return Metrics.recoveryColor(percent)
    }

    private var fillFraction: CGFloat {
        guard let percent = estimate.percent else { return 0.16 }
        return CGFloat(min(max(Double(percent) / 100.0, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recovery", systemImage: "gauge.with.dots.needle.bottom.50percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(estimate.percent.map { "\($0)%" } ?? "Learning")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()

            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(18, 120 * fillFraction), height: 8)
                }

            Text(estimate.confidence.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(estimate.confidence == .validated ? .green : .orange)

            Text(estimate.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetCard(tint: .green)
    }
}

struct AtriaStrainMeter: View, Equatable {
    let strain: Double
    let detail: String
    let confidence: String

    private var tint: Color {
        Metrics.strainColor(strain)
    }

    private var fillFraction: CGFloat {
        CGFloat(min(max(strain / 21.0, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Day strain", systemImage: "flame.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(String(format: "%.1f", strain))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()

            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(18, 120 * fillFraction), height: 8)
                }

            Text(confidence)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(confidence == "local" ? .green : .orange)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetCard(tint: .orange)
    }
}

struct AtriaSummaryRow: View, Equatable {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct AtriaStatusChip: View, Equatable {
    let text: String
    let systemImage: String
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: AtriaStatusChip, rhs: AtriaStatusChip) -> Bool {
        lhs.text == rhs.text && lhs.systemImage == rhs.systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(colorScheme == .dark ? tint.opacity(0.98) : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .atriaChromeCapsule(tint: tint)
    }
}

enum AtriaMetricState: Equatable {
    case learning
    case personalBaseline
    case validated
    case noContact
    case conflict
    case local
    case estimate
    case research
    case live

    var tint: Color {
        switch self {
        case .learning:
            return .orange
        case .personalBaseline:
            return .blue
        case .validated, .live:
            return .green
        case .noContact:
            return .red
        case .conflict:
            return .orange
        case .local:
            return .purple
        case .estimate:
            return .orange
        case .research:
            return .teal
        }
    }

    var systemImage: String {
        switch self {
        case .learning:
            return "circle.dashed"
        case .personalBaseline:
            return "person.crop.circle.badge.checkmark"
        case .validated:
            return "checkmark.seal.fill"
        case .noContact:
            return "heart.slash.fill"
        case .conflict:
            return "exclamationmark.triangle.fill"
        case .local:
            return "iphone"
        case .estimate:
            return "function"
        case .research:
            return "waveform.badge.magnifyingglass"
        case .live:
            return "waveform.path.ecg"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .learning:
            return "Learning"
        case .personalBaseline:
            return "Personal baseline"
        case .validated:
            return "Validated"
        case .noContact:
            return "No contact"
        case .conflict:
            return "App conflict"
        case .local:
            return "Local"
        case .estimate:
            return "Estimate"
        case .research:
            return "Research"
        case .live:
            return "Live"
        }
    }
}

struct AtriaStateBadge: View, Equatable {
    let state: AtriaMetricState

    var body: some View {
        Image(systemName: state.systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(state.tint)
            .frame(width: 28, height: 28)
            .background(AtriaIconTileBackground(cornerRadius: 9, tint: state.tint))
            .accessibilityLabel(state.accessibilityLabel)
    }
}

struct AtriaMetricTile: View, Equatable {
    static let gridSpacing: CGFloat = 12
    static let gridMinimumWidth: CGFloat = 142
    static let gridColumns = [GridItem(.adaptive(minimum: gridMinimumWidth), spacing: gridSpacing)]

    private static let compactHeight: CGFloat = 122
    private static let sparklineHeight: CGFloat = 132

    let label: String
    let value: String
    var unit: String? = nil
    var state: AtriaMetricState? = nil
    var tint: Color = .blue
    var footnote: String? = nil
    var sparklineValues: [Int]? = nil

    private var displayValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("learning")
            || trimmed.localizedCaseInsensitiveContains("prepar") {
            return "--"
        }
        return trimmed.isEmpty ? "--" : value
    }

    private var accessibilityText: String {
        var parts = ["\(label) \(displayValue)"]
        if let unit {
            parts[0] += " \(unit)"
        }
        if let state {
            parts.append(state.accessibilityLabel)
        }
        if let footnote,
           !footnote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(footnote)
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 0)
                if let state {
                    AtriaStateBadge(state: state)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(displayValue)
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                if let unit {
                    Text(unit)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            if let sparklineValues {
                Sparkline(values: sparklineValues)
                    .frame(height: 34)
            } else if let footnote {
                Text(footnote)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity,
               minHeight: tileHeight,
               maxHeight: tileHeight,
               alignment: .leading)
        .padding(13)
        .atriaInsetCard(tint: tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var tileHeight: CGFloat {
        sparklineValues == nil ? Self.compactHeight : Self.sparklineHeight
    }
}

struct AtriaSectionDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.24))
            .frame(height: 1)
    }
}

struct AtriaInlineQuickStat: View, Equatable {
    let label: String
    let value: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(10)
        .atriaInsetCard(tint: .white)
    }
}

struct AtriaProfileStepperTile: View {
    let title: String
    let value: String
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title.weight(.bold).monospacedDigit())
            HStack(spacing: 10) {
                Button(action: decrement) {
                    Image(systemName: "minus")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
                .accessibilityLabel("Decrease \(title)")

                Button(action: increment) {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
                .accessibilityLabel("Increase \(title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetCard(tint: .white)
    }
}
