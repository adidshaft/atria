import SwiftUI
import Charts

/// WHOOP-style "Strain & Recovery" combo chart (design backlog G1, 2026-08-03).
///
/// Strain is a daily bar on the 0–21 left axis (same shape as the Strain
/// sheet); each day's recovery is a colored dot on a right 0–100% axis
/// (dots colored strictly by recovery band). Both series are the same
/// day-bucketed history the metric detail charts already use.
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
    /// Anchor for the trailing week. Injected in tests so a July fixture is
    /// not clipped by a September `Date()`.
    var now: Date = Date()
    var calendar: Calendar = .current

    /// Strain's fixed physiological ceiling; also the shared chart domain that
    /// recovery (0–100%) is mapped onto so the two axes align on 0/33/66/100%.
    private let strainAxisMax = 21.0

    /// Trailing 7-day frame ending on `now`'s civil day — the same contract
    /// as `AtriaTrendRange.week` (owner 2026-09-02: the axis is the window,
    /// not the extent of the data). Anchoring on the latest reading used to
    /// drop today from a card labelled "the last 7 days" whenever the current
    /// cycle had no closed point yet.
    private var weekDays: [Date] {
        Self.trailingWeekDays(now: now, calendar: calendar)
    }

    /// Points snapped to day-starts and clipped to the 7-day frame, so they align
    /// exactly on the day-ticks and nothing outside the week is drawn.
    private func windowed(_ points: [AtriaDetailChartPoint]) -> [AtriaDetailChartPoint] {
        Self.pointsInTrailingWeek(points, now: now, calendar: calendar)
    }

    /// Seven civil days, `now`'s day inclusive. Internal for the window tests.
    static func trailingWeekDays(now: Date, calendar: Calendar = .current) -> [Date] {
        let dayStart = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        return (0...6).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Clip a series to the trailing week. Internal for the window tests.
    static func pointsInTrailingWeek(_ points: [AtriaDetailChartPoint],
                                     now: Date,
                                     calendar: Calendar = .current) -> [AtriaDetailChartPoint] {
        let days = trailingWeekDays(now: now, calendar: calendar)
        guard let first = days.first, let last = days.last else { return [] }
        return points.compactMap { point in
            let day = calendar.startOfDay(for: point.day)
            guard day >= first, day <= last else { return nil }
            return AtriaDetailChartPoint(day: day, value: point.value, tint: point.tint)
        }
    }

    /// Same words the Trends and metric-detail cards use. Silent on a full
    /// window. Strain counts days; recovery counts nights. Internal for tests.
    static func coverageCaption(strain: [AtriaDetailChartPoint],
                                recovery: [AtriaDetailChartPoint],
                                now: Date,
                                calendar: Calendar = .current) -> String? {
        let window = trailingWeekDays(now: now, calendar: calendar).count
        guard window > 1 else { return nil }
        let strainDays = Set(
            pointsInTrailingWeek(strain, now: now, calendar: calendar)
                .map { calendar.startOfDay(for: $0.day) }
        ).count
        let recoveryNights = Set(
            pointsInTrailingWeek(recovery, now: now, calendar: calendar)
                .map { calendar.startOfDay(for: $0.day) }
        ).count
        guard strainDays < window || recoveryNights < window else { return nil }
        return "\(strainDays) of \(window) days · \(recoveryNights) of \(window) nights recorded"
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
            if let coverageText {
                Text(coverageText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricStrain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityCaption)
    }

    private var coverageText: String? {
        Self.coverageCaption(strain: strain, recovery: recovery, now: now, calendar: calendar)
    }

    private var accessibilityCaption: String {
        let base = "Strain and recovery over \(rangeLabel). Strain on a 0 to 21 scale, recovery as a percentage, one point per day."
        guard let coverageText else { return base }
        return "\(base) \(coverageText)."
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Strain & recovery")
                .font(.subheadline.weight(.semibold))
            Spacer()
            HStack(spacing: 12) {
                Label("Strain", systemImage: "chart.bar.fill")
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
            ForEach(strainWindow) { point in
                BarMark(x: .value("Day", point.day, unit: .day),
                        y: .value("Strain", min(point.value, strainAxisMax)),
                        width: .ratio(AtriaChartVisualGrammar.dailyBarWidthRatio))
                    .foregroundStyle(Metrics.electricStrain.gradient)
                    .cornerRadius(AtriaChartVisualGrammar.dailyBarCornerRadius)
            }
            // Recovery stays a band-colored dot on the mapped 0–21 axis so
            // the two series do not fight as two zigzags. Missing nights
            // draw nothing.
            ForEach(recoveryWindow) { point in
                PointMark(x: .value("Day", point.day, unit: .day),
                          y: .value("Recovery", point.value / 100.0 * strainAxisMax))
                    .foregroundStyle(Metrics.recoveryColor(Int(point.value.rounded())))
                    .symbolSize(50)
            }
        }
        .atriaDailyChartPlotChrome()
        .chartXScale(domain: xDomain ?? Date()...Date())
        .chartXAxis {
            AxisMarks(values: weekDays) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel(centered: true) {
                    if let day = value.as(Date.self) {
                        Text(Self.dayTickLabel(for: day, calendar: calendar))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYScale(domain: 0...strainAxisMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 7, 14, 21]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text("\(Int(raw))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Metrics.electricStrain)
                    }
                }
            }
            AxisMarks(position: .trailing, values: [0, 7, 14, 21]) { value in
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text("\(Int((raw / strainAxisMax * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Metrics.electricGreen)
                    }
                }
            }
        }
        .frame(height: 168)
    }

    /// Compact weekday + day-of-month tick (`M 10`, `T 11`) so a week whose
    /// narrow weekday initials repeat (`S S`, `T T`) stays unambiguous.
    /// Internal for the tick-formatter tests.
    static func dayTickLabel(for day: Date, calendar: Calendar = .current) -> String {
        AtriaChartVisualGrammar.compactWeekdayDayLabel(for: day, calendar: calendar)
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
