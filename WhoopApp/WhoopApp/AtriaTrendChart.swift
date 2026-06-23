import SwiftUI
import Charts

/// Native iOS 26 Swift Charts trend card with a segmented metric selector.
/// Renders recent saved-session history for resting HR, strain, or HRV so the
/// long text-only "Trend" line becomes a real, selectable graph. Performance:
/// the data points are derived once per (sessions, metric) change and the chart
/// itself draws static marks (no interactive glass, no per-frame work).
struct AtriaTrendChartCard: View {
    let points: [AtriaTrendPoint]
    let baselineRestingHR: Int?

    @State private var metric: AtriaTrendMetric = .restingHR
    @Environment(\.colorScheme) private var colorScheme

    private var series: [AtriaTrendPoint.Sample] {
        points.compactMap { point in
            guard let value = point.value(for: metric) else { return nil }
            return AtriaTrendPoint.Sample(date: point.date, value: value)
        }
    }

    private var referenceValue: Double? {
        metric == .restingHR ? baselineRestingHR.map(Double.init) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                AtriaPanelSectionHeader(title: "Trends", subtitle: "Your last \(max(points.count, 0)) sessions")
                Spacer(minLength: 0)
                if let latest = series.last {
                    Text(metric.format(latest.value))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(metric.tint)
                }
            }

            Picker("Metric", selection: $metric) {
                ForEach(AtriaTrendMetric.allCases) { item in
                    Text(item.shortLabel).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if series.count < 2 {
                emptyState
            } else {
                chart
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
        .animation(.snappy(duration: 0.25), value: metric)
    }

    private var chart: some View {
        Chart {
            if let referenceValue {
                RuleMark(y: .value("Baseline", referenceValue))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, alignment: .leading) {
                        Text("baseline \(Int(referenceValue))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }

            ForEach(series) { sample in
                AreaMark(
                    x: .value("Date", sample.date),
                    y: .value(metric.shortLabel, sample.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [metric.tint.opacity(0.30), metric.tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Date", sample.date),
                    y: .value(metric.shortLabel, sample.value)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .foregroundStyle(metric.tint)
            }

            if let latest = series.last {
                PointMark(
                    x: .value("Date", latest.date),
                    y: .value(metric.shortLabel, latest.value)
                )
                .symbolSize(70)
                .foregroundStyle(metric.tint)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel().font(.caption2)
            }
        }
        .frame(height: 168)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundStyle(metric.tint.opacity(0.7))
            Text("Not enough \(metric.shortLabel.lowercased()) yet")
                .font(.subheadline.weight(.semibold))
            Text("Wear the strap across a few sessions and your \(metric.shortLabel.lowercased()) trend fills in here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
    }
}

/// Builds the trend points from saved sessions on the store side and renders the
/// chart. Caps to the most recent 30 sessions with enough samples to be a real
/// session (skips the tiny auto-saved fragments) so the graph stays meaningful
/// and cheap to redraw.
struct AtriaOverviewTrendChartHost: View {
    @ObservedObject var store: SessionStore
    let maxHR: Int

    var body: some View {
        AtriaTrendChartCard(points: trendPoints,
                            baselineRestingHR: store.baseline.restingInt)
    }

    private var trendPoints: [AtriaTrendPoint] {
        let rest: Int = store.baseline.restingInt ?? 60
        let meaningful: [SavedSession] = store.sessions.filter { $0.points.count >= 8 }
        let ordered: [SavedSession] = meaningful.sorted { $0.start < $1.start }
        let recent: [SavedSession] = Array(ordered.suffix(30))
        var result: [AtriaTrendPoint] = []
        result.reserveCapacity(recent.count)
        for session in recent {
            let strainValue: Double = Metrics.strain(fromTRIMP: session.trimp(rest: rest, max: maxHR))
            result.append(
                AtriaTrendPoint(
                    id: session.id,
                    date: session.start,
                    restingHR: session.restingStable,
                    strain: strainValue,
                    hrv: session.hrv
                )
            )
        }
        return result
    }
}

enum AtriaTrendMetric: String, CaseIterable, Identifiable {
    case restingHR
    case strain
    case hrv

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .restingHR: return "Resting HR"
        case .strain: return "Strain"
        case .hrv: return "HRV"
        }
    }

    var tint: Color {
        switch self {
        case .restingHR: return .pink
        case .strain: return .orange
        case .hrv: return .cyan
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .restingHR: return "\(Int(value.rounded())) bpm"
        case .strain: return String(format: "%.1f", value)
        case .hrv: return "\(Int(value.rounded())) ms"
        }
    }
}

/// One session's trend-relevant values, prepared on the main-actor store side so
/// the chart view stays cheap and Equatable.
struct AtriaTrendPoint: Equatable, Identifiable {
    let id: UUID
    let date: Date
    let restingHR: Int?
    let strain: Double?
    let hrv: Int?

    func value(for metric: AtriaTrendMetric) -> Double? {
        switch metric {
        case .restingHR: return restingHR.flatMap { $0 > 0 ? Double($0) : nil }
        case .strain: return strain.flatMap { $0 > 0 ? $0 : nil }
        case .hrv: return hrv.flatMap { $0 > 0 ? Double($0) : nil }
        }
    }

    struct Sample: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    /// Deterministic sample series for previews and on-device visual checks.
    static func sampleData(now: Date) -> [AtriaTrendPoint] {
        let resting = [62, 61, 63, 60, 59, 60, 58, 59, 57, 58, 56, 57]
        let strain = [8.2, 11.4, 6.1, 14.0, 9.5, 12.8, 7.3, 15.1, 10.2, 13.6, 8.9, 11.0]
        let hrv = [41, 44, 39, 47, 52, 48, 55, 51, 58, 54, 60, 57]
        return (0..<resting.count).map { index in
            AtriaTrendPoint(
                id: UUID(),
                date: now.addingTimeInterval(Double(index - resting.count) * 86_400),
                restingHR: resting[index],
                strain: strain[index],
                hrv: hrv[index]
            )
        }
    }
}

#Preview("Trend chart") {
    AtriaTrendChartCard(points: AtriaTrendPoint.sampleData(now: Date()),
                        baselineRestingHR: 58)
        .padding()
        .background(Color.black)
}
