import SwiftUI
import Charts

/// An event overlaid on an expanded chart — a workout, confirmed sleep, or
/// journal entry that happened on that day. Only ever built from real saved
/// records; an empty list simply renders no marker lane.
struct AtriaChartEvent: Identifiable, Equatable {
    let id: String
    let day: Date
    let label: String
    let systemImage: String
    let tint: Color
}

/// Shared expanded-chart experience (user feedback 2026-07-07: "all of the
/// graphs should have basic functions and open in landscape mode when
/// expanded"). Presented full-screen; the canvas renders rotated 90° so the
/// chart reads landscape when the phone is turned on its side — no
/// orientation-lock fight. Interactions: pinch/scroll zoom via the native
/// visible x-domain, drag-brush range selection with an honest window
/// summary, and a real-event marker lane.
struct AtriaExpandedChartView: View {
    let title: String
    let unit: String
    let tint: Color
    let points: [AtriaDetailChartPoint]
    var priorPoints: [AtriaDetailChartPoint] = []
    var baselineBand: AtriaDetailBaselineBand? = nil
    var events: [AtriaChartEvent] = []
    /// Sibling series offered as an overlay ("Edit this chart", design
    /// handoff). One at a time; the overlay is rescaled into this chart's
    /// y-domain and the legend says so — comparison of shape, not units.
    var overlays: [(title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])] = []
    let onDismiss: () -> Void
    private let prepared: AtriaExpandedChartPreparedModel

    @State private var visibleDays: Int = 0
    @State private var activeOverlayTitle: String?
    @State private var brushStart: Date?
    @State private var brushEnd: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String,
         unit: String,
         tint: Color,
         points: [AtriaDetailChartPoint],
         priorPoints: [AtriaDetailChartPoint] = [],
         baselineBand: AtriaDetailBaselineBand? = nil,
         events: [AtriaChartEvent] = [],
         overlays: [(title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])] = [],
         onDismiss: @escaping () -> Void) {
        self.title = title
        self.unit = unit
        self.tint = tint
        self.points = points
        self.priorPoints = priorPoints
        self.baselineBand = baselineBand
        self.events = events
        self.overlays = overlays
        self.onDismiss = onDismiss
        self.prepared = AtriaExpandedChartPreparedModel(points: points,
                                                        priorPoints: priorPoints,
                                                        baselineBand: baselineBand,
                                                        overlays: overlays)
    }

    private var spanDays: Int {
        prepared.spanDays
    }

    var body: some View {
        GeometryReader { proxy in
            // Keep only a compact outer gutter. The previous 96-point vertical
            // reservation left a large dead band on iPhone landscape and made
            // the plot needlessly short.
            let landscapeWidth = max(proxy.size.width, proxy.size.height) - 24
            let landscapeHeight = min(proxy.size.width, proxy.size.height) - 24
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 10) {
                    header
                    if points.isEmpty {
                        // Honest no-data state (2026-07-31 audit item 6): an
                        // empty series used to fabricate dataStart = dataEnd =
                        // now with a 0…1 y-axis and a "1 of 1 days visible"
                        // footer. Same rule as the brush summary's "No data in
                        // selection": say there is nothing, draw no axes.
                        emptyState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        chartBody
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        footer
                    }
                }
                .frame(width: landscapeWidth, height: landscapeHeight)
                // Landscape canvas on a portrait screen: rotate the whole
                // stage 90°; turning the phone makes it read upright. The
                // explicit position re-centers the oversized pre-rotation
                // frame inside the screen.
                .rotationEffect(.degrees(proxy.size.height > proxy.size.width ? 90 : 0))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if visibleDays == 0 { visibleDays = spanDays }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.headline.weight(.bold))
            if let summary = brushSummaryText {
                Text(summary)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("Drag to select a window \u{00b7} pinch or scroll to zoom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if brushStart != nil {
                Button("Clear") {
                    brushStart = nil
                    brushEnd = nil
                }
                .font(.caption.weight(.bold))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close expanded chart")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundStyle(tint.opacity(0.7))
            Text("No data in this range")
                .font(.subheadline.weight(.semibold))
            Text("\(title) has no recorded values here, so nothing is drawn.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var chartBody: some View {
        Chart {
            if let baselineBand {
                RectangleMark(xStart: .value("Start", prepared.dataStart),
                              xEnd: .value("End", prepared.dataEnd),
                              yStart: .value("Lower", baselineBand.lower),
                              yEnd: .value("Upper", baselineBand.upper))
                    .foregroundStyle(baselineBand.tint.opacity(0.10))
            }

            ForEach(priorPoints) { point in
                LineMark(x: .value("Day", point.day, unit: .day),
                         y: .value(title, point.value),
                         series: .value("Series", "prior"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }

            if let overlay = activeOverlay {
                ForEach(overlay.points) { point in
                    LineMark(x: .value("Day", point.day, unit: .day),
                             y: .value(title, point.value),
                             series: .value("Series", "overlay"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(overlay.tint.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                }
            }

            ForEach(points) { point in
                // Subtle area fill beneath the current line (Apple Health idiom,
                // matching AtriaTrendChartCard). Purely decorative: the bounded
                // y-scale below keeps it inside the plot, and no value is
                // implied beyond the real sampled line it sits under.
                AreaMark(x: .value("Day", point.day, unit: .day),
                         y: .value(title, point.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [tint.opacity(0.24), tint.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                LineMark(x: .value("Day", point.day, unit: .day),
                         y: .value(title, point.value),
                         series: .value("Series", "current"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                PointMark(x: .value("Day", point.day, unit: .day),
                          y: .value(title, point.value))
                    .foregroundStyle(point.tint)
                    .symbolSize(30)
            }

            // Event lane: real saved activity pinned to the top of the plot.
            ForEach(events) { event in
                PointMark(x: .value("Day", event.day, unit: .day),
                          y: .value(title, prepared.eventLaneY))
                    .symbol {
                        Image(systemName: event.systemImage)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(event.tint)
                    }
            }

            if let start = brushStart, let end = brushEnd {
                RectangleMark(xStart: .value("Brush start", min(start, end)),
                              xEnd: .value("Brush end", max(start, end)))
                    .foregroundStyle(tint.opacity(0.14))
            }
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: max(1, visibleDays) * 86_400)
        .chartXScale(domain: prepared.xDomain)
        .chartYScale(domain: prepared.yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
                AxisTick().foregroundStyle(.secondary.opacity(0.55))
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(date, format: .dateTime.month(.abbreviated).day())
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                AxisValueLabel().font(.caption2.monospacedDigit())
            }
        }
        .chartOverlay { chartProxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                let plot = geo[chartProxy.plotFrame!]
                                let startX = value.startLocation.x - plot.origin.x
                                let currentX = value.location.x - plot.origin.x
                                brushStart = chartProxy.value(atX: startX, as: Date.self)
                                brushEnd = chartProxy.value(atX: currentX, as: Date.self)
                            }
                    )
            }
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    let target = Double(spanDays) / Double(scale)
                    visibleDays = min(max(Int(target.rounded()), 3), spanDays)
                }
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !prepared.overlays.isEmpty {
                ForEach(prepared.overlays) { overlay in
                    let isActive = activeOverlayTitle == overlay.title
                    Button {
                        activeOverlayTitle = isActive ? nil : overlay.title
                    } label: {
                        Text(overlay.title)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isActive ? overlay.tint : .secondary)
                            .padding(.horizontal, 9)
                            .frame(minHeight: 30)
                            .background((isActive ? overlay.tint : Color.secondary).opacity(0.14), in: Capsule(style: .continuous))
                            .contentShape(Capsule())
                    }
                    .accessibilityLabel("\(isActive ? "Hide" : "Overlay") \(overlay.title)")
                }
                if activeOverlay != nil {
                    Text("dashed \u{00b7} scaled to fit")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if visibleEventCount > 0 {
                Label("\(visibleEventCount) activities marked", systemImage: "flag.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("\(min(visibleDays, spanDays)) of \(spanDays) days visible")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var activeOverlay: AtriaExpandedChartPreparedOverlay? {
        prepared.overlay(title: activeOverlayTitle)
    }

    /// Only events inside the chart's x-domain: the marker lane clips to it,
    /// so counting the full unfiltered list over-reported what is actually
    /// marked (2026-07-31 audit item 10).
    private var visibleEventCount: Int {
        events.reduce(into: 0) { count, event in
            if prepared.xDomain.contains(event.day) { count += 1 }
        }
    }

    /// Honest summary of the brushed window: only real points inside it.
    private var brushSummaryText: String? {
        guard let start = brushStart, let end = brushEnd else { return nil }
        return prepared.brushSummary(start: start, end: end, unit: unit)
    }
}

private struct AtriaExpandedChartPreparedOverlay: Identifiable {
    let title: String
    let unit: String
    let tint: Color
    let points: [AtriaDetailChartPoint]

    var id: String { title }
}

private struct AtriaExpandedChartPreparedModel {
    let dataStart: Date
    let dataEnd: Date
    let xDomain: ClosedRange<Date>
    let yDomain: ClosedRange<Double>
    let eventLaneY: Double
    let spanDays: Int
    let overlays: [AtriaExpandedChartPreparedOverlay]

    private let brushPoints: [AtriaDetailChartPoint]

    init(points: [AtriaDetailChartPoint],
         priorPoints: [AtriaDetailChartPoint],
         baselineBand: AtriaDetailBaselineBand?,
         overlays: [(title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])]) {
        let now = Date()
        dataStart = points.first?.day ?? now
        dataEnd = points.last?.day ?? now
        xDomain = dataStart.addingTimeInterval(-43_200)...dataEnd.addingTimeInterval(43_200)
        spanDays = max(1, Calendar.current.dateComponents([.day], from: dataStart, to: dataEnd).day ?? 1)

        var values: [Double] = []
        values.reserveCapacity(points.count + priorPoints.count + 2)
        for point in points {
            values.append(point.value)
        }
        for point in priorPoints {
            values.append(point.value)
        }
        if let baselineBand {
            values.append(baselineBand.lower)
            values.append(baselineBand.upper)
        }
        let computedYDomain: ClosedRange<Double>
        if let lo = values.min(), let hi = values.max(), hi > lo {
            let pad = (hi - lo) * 0.12
            computedYDomain = (lo - pad)...(hi + pad)
        } else {
            computedYDomain = 0...1
        }
        yDomain = computedYDomain
        eventLaneY = computedYDomain.upperBound - (computedYDomain.upperBound - computedYDomain.lowerBound) * 0.04
        brushPoints = points.sorted { $0.day < $1.day }
        self.overlays = overlays.map { overlay in
            AtriaExpandedChartPreparedOverlay(title: overlay.title,
                                              unit: overlay.unit,
                                              tint: overlay.tint,
                                              points: Self.rescaledOverlayPoints(overlay.points,
                                                                                tint: overlay.tint,
                                                                                yDomain: computedYDomain))
        }
    }

    func overlay(title: String?) -> AtriaExpandedChartPreparedOverlay? {
        guard let title else { return nil }
        return overlays.first { $0.title == title }
    }

    /// Maps an overlay from its own min-max into this chart's y-domain: an honest
    /// shape comparison. The UI labels it as scaled, so units are never implied.
    private static func rescaledOverlayPoints(_ points: [AtriaDetailChartPoint],
                                              tint: Color,
                                              yDomain: ClosedRange<Double>) -> [AtriaDetailChartPoint] {
        var lo: Double?
        var hi: Double?
        for point in points {
            lo = min(lo ?? point.value, point.value)
            hi = max(hi ?? point.value, point.value)
        }
        guard let low = lo, let high = hi, high > low else { return [] }
        let pad = (yDomain.upperBound - yDomain.lowerBound) * 0.06
        let targetLo = yDomain.lowerBound + pad
        let targetHi = yDomain.upperBound - pad
        return points.map { point in
            let fraction = (point.value - low) / (high - low)
            return AtriaDetailChartPoint(day: point.day,
                                         value: targetLo + fraction * (targetHi - targetLo),
                                         tint: tint)
        }
    }

    /// Honest summary of the brushed window: binary-search the sorted days, then
    /// aggregate only real points in range. No filtered/mapped arrays during drag.
    func brushSummary(start: Date,
                      end: Date,
                      unit: String,
                      calendar: Calendar = .current) -> String {
        let lo = min(start, end)
        let hi = max(start, end)
        let lower = lowerBound(for: lo)
        let upper = upperBound(for: hi)
        guard lower < upper else { return "No data in selection" }

        var count = 0
        var sum = 0.0
        var minValue = Double.greatestFiniteMagnitude
        var maxValue = -Double.greatestFiniteMagnitude
        for point in brushPoints[lower..<upper] {
            count += 1
            sum += point.value
            minValue = min(minValue, point.value)
            maxValue = max(maxValue, point.value)
        }
        let avg = sum / Double(count)
        let days = (calendar.dateComponents([.day], from: lo, to: hi).day ?? 0) + 1
        return String(format: "%dd \u{00b7} avg %.1f%@ \u{00b7} %.1f\u{2013}%.1f", days, avg, unit, minValue, maxValue)
    }

    private func lowerBound(for day: Date) -> Int {
        var low = 0
        var high = brushPoints.count
        while low < high {
            let mid = (low + high) / 2
            if brushPoints[mid].day < day {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func upperBound(for day: Date) -> Int {
        var low = 0
        var high = brushPoints.count
        while low < high {
            let mid = (low + high) / 2
            if brushPoints[mid].day <= day {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
