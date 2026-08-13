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

    private let calendar = Calendar.current

    /// A FIXED 7-day frame ending on the most recent day that has data, so the
    /// x-axis always shows seven day-ticks (not a couple of scattered labels over
    /// a sparse wide range). Anchoring on the latest data day keeps the readings
    /// flush at the right edge instead of leaving an empty tail.
    private var weekDays: [Date] {
        let allDays = (strain + recovery).map { calendar.startOfDay(for: $0.day) }
        guard let end = allDays.max() else { return [] }
        let start = calendar.date(byAdding: .day, value: -6, to: end) ?? end
        return (0...6).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Points snapped to day-starts and clipped to the 7-day frame, so they align
    /// exactly on the day-ticks and nothing outside the week is drawn.
    private func windowed(_ points: [AtriaDetailChartPoint]) -> [AtriaDetailChartPoint] {
        guard let first = weekDays.first, let last = weekDays.last else { return [] }
        return points.compactMap { point in
            let day = calendar.startOfDay(for: point.day)
            guard day >= first, day <= last else { return nil }
            return AtriaDetailChartPoint(day: day, value: point.value, tint: point.tint)
        }
    }

    /// Domain padded half a day each side so edge ticks/points aren't clipped.
    private var xDomain: ClosedRange<Date>? {
        guard let first = weekDays.first, let last = weekDays.last else { return nil }
        let lo = calendar.date(byAdding: .hour, value: -12, to: first) ?? first
        let hi = calendar.date(byAdding: .hour, value: 12, to: last) ?? last
        return lo...hi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // Handoff-10 CP3: the former full-bleed negative padding plus a
            // whole-chart `.clipped()` cut the top `21`/`100%` labels and the
            // trailing axis. The plot now keeps the card inset and gets
            // explicit headroom instead.
            chart
            Text("Strain (0–21, left) and recovery % (right) as two lines. Recovery points are colored by band; each line breaks on days with no reading rather than drawing across the gap.")
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
        let strainWindow = windowed(strain)
        let recoveryWindow = windowed(recovery)
        return Chart {
            // Two zigzag lines on a shared 0–21 domain (recovery % mapped onto
            // it), each BROKEN at day gaps via its contiguous-run id so neither
            // line is drawn across days with no reading.
            ForEach(strainWindow.contiguousDayRuns(), id: \.point.day) { entry in
                LineMark(x: .value("Day", entry.point.day, unit: .day),
                         y: .value("Strain", min(entry.point.value, strainAxisMax)),
                         series: .value("Strain run", "s\(entry.runID)"))
                    .foregroundStyle(Metrics.electricStrain)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            // A dot on each real strain day so an isolated day (a length-1 run
            // that a LineMark cannot draw) still renders — mirrors the recovery
            // dots below and prevents a single-day window looking empty.
            ForEach(strainWindow) { point in
                PointMark(x: .value("Day", point.day, unit: .day),
                          y: .value("Strain", min(point.value, strainAxisMax)))
                    .foregroundStyle(Metrics.electricStrain)
                    .symbolSize(36)
            }
            ForEach(recoveryWindow.contiguousDayRuns(), id: \.point.day) { entry in
                LineMark(x: .value("Day", entry.point.day, unit: .day),
                         y: .value("Recovery", entry.point.value / 100.0 * strainAxisMax),
                         series: .value("Recovery run", "r\(entry.runID)"))
                    .foregroundStyle(Metrics.electricGreen)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            // A dot on each real recovery day, colored by its band, so the
            // recovery line's points read green/yellow/red at a glance.
            ForEach(recoveryWindow) { point in
                PointMark(x: .value("Day", point.day, unit: .day),
                          y: .value("Recovery", point.value / 100.0 * strainAxisMax))
                    .foregroundStyle(Metrics.recoveryColor(Int(point.value.rounded())))
                    .symbolSize(50)
            }
        }
        .chartXScale(domain: xDomain ?? Date()...Date())
        .chartXAxis {
            AxisMarks(values: weekDays) { value in
                AxisGridLine()
                    .foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let day = value.as(Date.self) {
                        Text(Self.dayTickLabel(for: day, calendar: calendar))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYScale(domain: 0...strainAxisMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 7, 14, 21]) { value in
                AxisGridLine()
                    .foregroundStyle(.quaternary)
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
        // Explicit plot insets (handoff-10 CP3): headroom keeps the top
        // `21` / `100%` labels and edge points fully visible; no `.clipped()`.
        .chartPlotStyle { plot in
            plot.padding(.top, 10)
        }
        .frame(height: 158)
    }

    /// Compact weekday + day-of-month tick (`M 10`, `T 11`) so a week whose
    /// narrow weekday initials repeat (`S S`, `T T`) stays unambiguous.
    /// Internal for the tick-formatter tests.
    static func dayTickLabel(for day: Date, calendar: Calendar = .current) -> String {
        let weekday = day.formatted(.dateTime.weekday(.narrow))
        let dayOfMonth = calendar.component(.day, from: day)
        return "\(weekday) \(dayOfMonth)"
    }
}

extension Array where Element == AtriaDetailChartPoint {
    /// Split into contiguous day-runs so a charted line BREAKS at day gaps
    /// instead of drawing a straight segment across days with no reading (which
    /// would imply data that never existed — honesty-first chart rule,
    /// 2026-08-03). The run id increments whenever consecutive points are more
    /// than a day apart; feed it to `LineMark(series:)` so each run is its own
    /// line. Shared by the combo and the metric detail charts.
    func contiguousDayRuns(calendar: Calendar = .current)
        -> [(runID: Int, point: AtriaDetailChartPoint)] {
        let sorted = self.sorted { $0.day < $1.day }
        var out: [(Int, AtriaDetailChartPoint)] = []
        var run = 0
        var previous: Date?
        for point in sorted {
            if let previous {
                let days = calendar.dateComponents([.day], from: previous, to: point.day).day ?? 1
                if days > 1 { run += 1 }
            }
            out.append((run, point))
            previous = point.day
        }
        return out
    }
}
