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
        .atriaQuietPanel(emphasis: .soft)
    }
}

struct AtriaPanelSectionHeader: View, Equatable {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
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
        .atriaInsetTile(cornerRadius: 16, tint: tint)
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
            .atriaInsetTile(cornerRadius: 16, tint: tint)
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
                .foregroundStyle(estimate.confidence == .high ? .green : .orange)

            Text(estimate.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetTile(cornerRadius: 20, tint: .green)
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
        .atriaInsetTile(cornerRadius: 20, tint: .orange)
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
            .atriaGlassCapsule(tint: tint)
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
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(10)
        .atriaInsetTile(cornerRadius: 15, tint: .white)
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
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AtriaGlassIconSegmentStyle())

                Button(action: increment) {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AtriaGlassIconSegmentStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetTile(cornerRadius: 18, tint: .white)
    }
}
