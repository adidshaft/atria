import Charts
import SwiftUI
import UIKit

/// A data-bearing graph that can be inspected without changing its meaning.
/// Time series carry an explicit segment so an observation gap is never drawn
/// as a continuous line. Histograms and intervals keep their native shapes.
struct AtriaInspectableGraph {
    enum Content {
        case timeSeries([Series])
        case histogram([Bar])
        case intervals([Interval], domain: ClosedRange<Date>)
    }

    struct Point: Identifiable, Equatable {
        let id: String
        let date: Date
        let value: Double
        let segment: Int

        init(id: String? = nil, date: Date, value: Double, segment: Int = 0) {
            self.id = id ?? "\(date.timeIntervalSinceReferenceDate)-\(segment)-\(value)"
            self.date = date
            self.value = value
            self.segment = segment
        }
    }

    struct Series: Identifiable {
        let id: String
        let title: String
        let unit: String
        let tint: Color
        let points: [Point]

        init(id: String? = nil,
             title: String,
             unit: String,
             tint: Color,
             points: [Point]) {
            self.id = id ?? title
            self.title = title
            self.unit = unit
            self.tint = tint
            self.points = points.sorted { $0.date < $1.date }
        }
    }

    struct Bar: Identifiable {
        let id: String
        let label: String
        let value: Double
        let unit: String
        let tint: Color

        init(id: String? = nil, label: String, value: Double, unit: String, tint: Color) {
            self.id = id ?? label
            self.label = label
            self.value = value
            self.unit = unit
            self.tint = tint
        }
    }

    struct Interval: Identifiable {
        let id: String
        let lane: String
        let label: String
        let start: Date
        let end: Date
        let tint: Color

        var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
    }

    struct Reading: Identifiable {
        let series: Series
        let point: Point
        var id: String { series.id }
    }

    let title: String
    let subtitle: String?
    let content: Content

    static func segmentedPoints(_ values: [(date: Date, value: Double)],
                                gapThreshold: TimeInterval) -> [Point] {
        let sorted = values.sorted { $0.date < $1.date }
        var segment = 0
        var previous: Date?
        return sorted.map { value in
            if let previous, value.date.timeIntervalSince(previous) > gapThreshold {
                segment += 1
            }
            previous = value.date
            return Point(date: value.date, value: value.value, segment: segment)
        }
    }

    func nearestReadings(to date: Date) -> [Reading] {
        guard case let .timeSeries(series) = content else { return [] }
        return series.compactMap { item in
            guard let point = Self.nearestPoint(in: item.points, to: date) else { return nil }
            return Reading(series: item, point: point)
        }
    }

    private static func nearestPoint(in points: [Point], to date: Date) -> Point? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].date < date { low = middle + 1 } else { high = middle }
        }
        if low == 0 { return points[0] }
        if low == points.count { return points[points.count - 1] }
        let before = points[low - 1]
        let after = points[low]
        return date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date) ? before : after
    }
}

private struct AtriaInspectableGraphModifier: ViewModifier {
    let graph: AtriaInspectableGraph?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                guard graph != nil else { return }
                isPresented = true
            }
            .overlay(alignment: .topTrailing) {
                if graph != nil {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(7)
                        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                        .padding(6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityAddTraits(graph == nil ? [] : .isButton)
            .accessibilityHint(graph == nil ? "" : "Opens a full-screen landscape graph inspector")
            .fullScreenCover(isPresented: $isPresented) {
                if let graph {
                    AtriaGraphInspectorView(graph: graph) { isPresented = false }
                }
            }
    }
}

extension View {
    func atriaInspectableGraph(_ graph: AtriaInspectableGraph?) -> some View {
        modifier(AtriaInspectableGraphModifier(graph: graph))
    }
}

struct AtriaGraphInspectorOrientationPolicy {
    static let transitionMask: UIInterfaceOrientationMask = .allButUpsideDown
    static let presentedMask: UIInterfaceOrientationMask = .landscape
    static let preferredOrientation: UIInterfaceOrientation = .landscapeRight
}

private struct AtriaGraphInspectorView: View {
    let graph: AtriaInspectableGraph
    let onDismiss: () -> Void

    @State private var selectedDate: Date?
    @State private var visibleDuration: TimeInterval?

    var body: some View {
        GeometryReader { proxy in
            let portraitFallback = proxy.size.height > proxy.size.width
            let stageWidth = max(proxy.size.width, proxy.size.height)
            let stageHeight = min(proxy.size.width, proxy.size.height)
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 10) {
                    header
                    graphBody
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(width: stageWidth, height: stageHeight)
                // Orientation lock can reject a geometry request. Keep a
                // landscape-shaped, rotated fallback so inspection still uses
                // the phone's long edge and never collapses to a portrait plot.
                .rotationEffect(.degrees(portraitFallback ? 90 : 0))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .onAppear {
                AtriaAppDelegate.supportedOrientations = AtriaGraphInspectorOrientationPolicy.transitionMask
                requestOrientation(AtriaGraphInspectorOrientationPolicy.presentedMask)
            }
            .onDisappear {
                AtriaAppDelegate.supportedOrientations = .portrait
                requestOrientation(.portrait)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(graph.title).font(.headline.weight(.bold))
                if let subtitle = graph.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let fullDuration = inspectableDuration,
               fullDuration > minimumVisibleDuration {
                Button {
                    adjustVisibleDuration(by: 2)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .frame(width: 44, height: 44)
                }
                .disabled((visibleDuration ?? fullDuration) >= fullDuration)
                .accessibilityLabel("Show a wider time range")

                Button {
                    adjustVisibleDuration(by: 0.5)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .frame(width: 44, height: 44)
                }
                .disabled((visibleDuration ?? fullDuration) <= minimumVisibleDuration)
                .accessibilityLabel("Show a narrower time range")
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close graph inspector")
        }
    }

    @ViewBuilder private var graphBody: some View {
        switch graph.content {
        case let .timeSeries(series):
            timeSeriesChart(series)
        case let .histogram(bars):
            histogramChart(bars)
        case let .intervals(intervals, domain):
            intervalChart(intervals, domain: domain)
        }
    }

    private func timeSeriesChart(_ series: [AtriaInspectableGraph.Series]) -> some View {
        Chart {
            ForEach(series) { item in
                ForEach(item.points) { point in
                    LineMark(x: .value("Time", point.date),
                             y: .value(item.title, point.value),
                             series: .value("Observed segment", "\(item.id)-\(point.segment)"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(item.tint)
                    PointMark(x: .value("Time", point.date), y: .value(item.title, point.value))
                        .foregroundStyle(item.tint.opacity(0.8))
                        .symbolSize(18)
                }
            }
            if let selectedDate {
                RuleMark(x: .value("Selected", selectedDate))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleDuration ?? defaultVisibleDuration(series))
        .chartXSelection(value: $selectedDate)
        .chartLegend(position: .top, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func histogramChart(_ bars: [AtriaInspectableGraph.Bar]) -> some View {
        Chart(bars) { bar in
            BarMark(x: .value("Value", bar.value), y: .value("Category", bar.label))
                .foregroundStyle(bar.tint.gradient)
                .annotation(position: .trailing) {
                    Text(Self.valueText(bar.value, unit: bar.unit))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func intervalChart(_ intervals: [AtriaInspectableGraph.Interval],
                               domain: ClosedRange<Date>) -> some View {
        Chart(intervals) { interval in
            BarMark(xStart: .value("Start", interval.start),
                    xEnd: .value("End", interval.end),
                    y: .value("Lane", interval.lane))
                .foregroundStyle(interval.tint)
                .cornerRadius(5)
                .annotation(position: .overlay) {
                    Text(interval.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
        }
        .chartXScale(domain: domain)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleDuration ?? domain.upperBound.timeIntervalSince(domain.lowerBound))
        .chartXSelection(value: $selectedDate)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var footer: some View {
        switch graph.content {
        case .timeSeries:
            HStack(spacing: 14) {
                if let selectedDate {
                    Text(selectedDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit())
                    ForEach(graph.nearestReadings(to: selectedDate)) { reading in
                        Text("\(reading.series.title) \(Self.valueText(reading.point.value, unit: reading.series.unit))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(reading.series.tint)
                    }
                } else {
                    Text("Drag across the graph to inspect real recorded values")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        case let .histogram(bars):
            Text("\(bars.count) recorded categories · values are not interpolated")
                .font(.caption).foregroundStyle(.secondary)
        case let .intervals(intervals, _):
            Text("\(intervals.count) recorded intervals · bar width is actual duration")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func defaultVisibleDuration(_ series: [AtriaInspectableGraph.Series]) -> TimeInterval {
        let allDates = series.flatMap(\.points).map(\.date)
        guard let first = allDates.min(), let last = allDates.max() else { return 86_400 }
        return max(60, last.timeIntervalSince(first))
    }

    private var inspectableDuration: TimeInterval? {
        switch graph.content {
        case let .timeSeries(series):
            return defaultVisibleDuration(series)
        case let .intervals(_, domain):
            return max(60, domain.upperBound.timeIntervalSince(domain.lowerBound))
        case .histogram:
            return nil
        }
    }

    private var minimumVisibleDuration: TimeInterval {
        switch graph.content {
        case .timeSeries: return 60
        case .intervals: return 5 * 60
        case .histogram: return 0
        }
    }

    private func adjustVisibleDuration(by multiplier: Double) {
        guard let fullDuration = inspectableDuration else { return }
        let current = visibleDuration ?? fullDuration
        visibleDuration = min(fullDuration,
                              max(minimumVisibleDuration, current * multiplier))
    }

    private static func valueText(_ value: Double, unit: String) -> String {
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return number + unit
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.windows.first(where: \.isKeyWindow)?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
