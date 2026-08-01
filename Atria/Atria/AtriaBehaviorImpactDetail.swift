import SwiftUI

// Behavior drill-in (design spec 8b): "Logged vs quiet nights" — two recovery
// histograms drawn on one shared 0-100 ruler, the real mean/night-count pair
// under them, and the vitals that actually shift on the logged nights.
//
// Two deliberate departures from the design comp, both for honesty:
//   * the design hard-codes quiet=green / logged=red because its example
//     behavior (alcohol) hurts. Here the BETTER side is green and the worse
//     side red, so a supportive behavior cannot be drawn as if it were harmful.
//   * the comp's goal-setting action is omitted: the app has no behavior-goal
//     system to route it to (only a step target and the sleep planner), and a
//     button that leads nowhere is a promise the app cannot keep. "See nights"
//     stays, because the real logged nights exist and can be shown.

struct AtriaBehaviorImpactDetailSheet: View {
    let stat: AtriaBehaviorImpactPresentation.Stat
    let detail: AtriaBehaviorImpactPresentation.Detail

    @Environment(\.dismiss) private var dismiss
    @State private var showsNights = false

    /// The side with the higher mean recovery is the green side.
    private var loggedIsBetter: Bool { stat.impact >= 0 }

    private var loggedTint: Color { loggedIsBetter ? Metrics.electricGreen : Metrics.electricRed }
    private var quietTint: Color { loggedIsBetter ? Metrics.electricRed : Metrics.electricGreen }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.xl) {
                    VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
                        AtriaPanelSectionHeader(title: "Logged vs quiet nights",
                                                subtitle: AtriaBehaviorImpactPresentation.framing)
                        histograms
                        summaryPair
                    }
                    .padding(AtriaDesignTokens.Spacing.lg)
                    .atriaCard(emphasis: .soft)

                    shiftsCard

                    nightsCard

                    Text(AtriaBehaviorImpactPresentation.significanceFooter)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AtriaDesignTokens.Spacing.xl)
            }
            .navigationTitle(stat.tag.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var histograms: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: AtriaDesignTokens.Spacing.md) {
                AtriaBehaviorImpactHistogram(title: "Quiet nights",
                                             distribution: detail.quiet,
                                             peakShare: sharedPeakShare,
                                             tint: quietTint)
                Rectangle()
                    .fill(.clear)
                    .frame(width: 1)
                    .frame(height: AtriaBehaviorImpactHistogram.plotHeight)
                    .overlay {
                        Rectangle()
                            .stroke(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                AtriaBehaviorImpactHistogram(title: "\(stat.tag.label) nights",
                                             distribution: detail.logged,
                                             peakShare: sharedPeakShare,
                                             tint: loggedTint)
            }

            Text("Bar height is the share of that side's own nights, so the two "
                 + "distributions stay comparable at different night counts.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One shared vertical scale — in SHARE, not raw count (see Distribution).
    private var sharedPeakShare: Double {
        max(0.0001, max(detail.quiet.peakShare, detail.logged.peakShare))
    }

    private var summaryPair: some View {
        HStack(alignment: .top, spacing: AtriaDesignTokens.Spacing.md) {
            summaryColumn(value: detail.quiet.meanRecovery,
                          caption: "Quiet · \(nightsText(detail.quiet.nights))",
                          tint: quietTint)
            summaryColumn(value: detail.logged.meanRecovery,
                          caption: "\(stat.tag.label) · \(nightsText(detail.logged.nights))",
                          tint: loggedTint)
        }
    }

    private func summaryColumn(value: Double, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Int(value.rounded()))%")
                .font(.title3.weight(.heavy).monospacedDigit())
                .foregroundStyle(tint)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func nightsText(_ count: Int) -> String {
        count == 1 ? "1 night" : "\(count) nights"
    }

    @ViewBuilder
    private var shiftsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHAT SHIFTS ON THOSE NIGHTS")
                .font(.caption2.weight(.black))
                .foregroundStyle(.tertiary)
                .kerning(0.8)

            if detail.shifts.isEmpty {
                Text("No vital has enough readings on both sides yet — "
                     + "a shift row needs ≥5 nights of that metric logged and ≥5 quiet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(detail.shifts) { shift in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(shift.metric.label)
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(shift.deltaText)
                            .font(.subheadline.weight(.heavy).monospacedDigit())
                            .foregroundStyle(Self.tint(for: shift.metric))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(shift.metric.label) \(shift.deltaText) on \(nightsText(shift.loggedNights))")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(emphasis: .soft)
    }

    /// One hue per metric, from the shared palette — HRV rose, RHR red-warm,
    /// deep sleep indigo.
    private static func tint(for metric: AtriaBehaviorImpactPresentation.MetricShift.Metric) -> Color {
        switch metric {
        case .hrv: return Metrics.electricHRV
        case .restingHR: return Metrics.electricRed
        case .deepSleep: return Metrics.electricSleep
        }
    }

    @ViewBuilder
    private var nightsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                    showsNights.toggle()
                }
            } label: {
                HStack {
                    Text("See nights")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: showsNights ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsNights {
                ForEach(detail.loggedNightList) { night in
                    HStack {
                        Text(night.day, format: .dateTime.month(.abbreviated).day())
                            .font(.caption.weight(.semibold).monospacedDigit())
                        Spacer(minLength: 8)
                        Text("\(night.recoveryPercent)%")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Metrics.recoveryColor(night.recoveryPercent))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(emphasis: .soft)
    }
}

/// Five fixed 20-point recovery bins, drawn against a shared peak so the two
/// sides of a drill-in can be compared by eye.
struct AtriaBehaviorImpactHistogram: View {
    static let plotHeight: CGFloat = 130

    let title: String
    let distribution: AtriaBehaviorImpactPresentation.Distribution
    let peakShare: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(distribution.shares.enumerated()), id: \.offset) { index, share in
                    UnevenRoundedRectangle(topLeadingRadius: 3,
                                           bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0,
                                           topTrailingRadius: 3,
                                           style: .continuous)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.45)],
                                             startPoint: .top,
                                             endPoint: .bottom))
                        .frame(height: barHeight(share))
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                        .opacity(share == 0 ? 0 : 1)
                        .overlay(alignment: .bottom) {
                            if share == 0 {
                                Rectangle()
                                    .fill(.quaternary)
                                    .frame(height: 1)
                            }
                        }
                        .id(index)
                }
            }
            .frame(height: Self.plotHeight, alignment: .bottom)

            HStack {
                Text("low")
                Spacer(minLength: 4)
                Text("high")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(distribution.nights) nights, average \(Int(distribution.meanRecovery.rounded())) percent recovery")
    }

    private func barHeight(_ share: Double) -> CGFloat {
        guard peakShare > 0, share > 0 else { return 1 }
        return max(4, Self.plotHeight * CGFloat(share / peakShare))
    }
}
