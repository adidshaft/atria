import SwiftUI
import Charts

/// WHOOP-style "Strain & Recovery" combo chart (design backlog G1, 2026-08-03).
///
/// Strain is a line on the 0–21 left axis; each day's recovery is a colored dot
/// on a right 0–100% axis (dots colored strictly by recovery band). Both series
/// are the same day-bucketed history the metric detail charts already use, so
/// there is no new data path.
///
/// Honesty: recovery dots plot only on days that actually have a recovery score
/// (missing ≠ zero); strain is the drained/lagged value the rest of the app
/// already shows — never a fabricated live point. Reusable so the metric detail
/// sheet AND the Activity surface can render the identical card.
///
/// Self-contained (no environment dependencies) so it renders straight to an
/// image in a test for visual verification.
struct AtriaStrainRecoveryComboChart: View {
    let strain: [AtriaDetailChartPoint]
    let recovery: [AtriaDetailChartPoint]
    let rangeLabel: String

    /// Strain's fixed physiological ceiling; also the shared chart domain that
    /// recovery (0–100%) is mapped onto so the two axes align on 0/33/66/100%.
    private let strainAxisMax = 21.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            chart
            Text("Strain (0–21, left) against each day's recovery % (right). Recovery dots are colored by band — days without a recovery score don't plot.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricStrain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Strain and recovery over \(rangeLabel). Strain on a 0 to 21 scale, recovery as a percentage, one point per day.")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Strain & recovery")
                .font(.subheadline.weight(.semibold))
            Spacer()
            HStack(spacing: 12) {
                Label("Strain", systemImage: "line.diagonal")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Metrics.electricStrain)
                Label("Recovery", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Metrics.electricGreen)
            }
            .font(.caption2.weight(.semibold))
            .imageScale(.small)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(strain) { point in
                LineMark(x: .value("Day", point.day),
                         y: .value("Strain", min(point.value, strainAxisMax)),
                         series: .value("Series", "Strain"))
                    .foregroundStyle(Metrics.electricStrain)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(recovery) { point in
                PointMark(x: .value("Day", point.day),
                          y: .value("Recovery", point.value / 100.0 * strainAxisMax))
                    .foregroundStyle(Metrics.recoveryColor(Int(point.value.rounded())))
                    .symbolSize(70)
            }
        }
        .chartYScale(domain: 0...strainAxisMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 7, 14, 21]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text("\(Int(raw))")
                            .foregroundStyle(Metrics.electricStrain)
                    }
                }
            }
            AxisMarks(position: .trailing, values: [0, 7, 14, 21]) { value in
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text("\(Int((raw / strainAxisMax * 100).rounded()))%")
                            .foregroundStyle(Metrics.electricGreen)
                    }
                }
            }
        }
        .frame(height: 150)
        .clipped()
    }
}
