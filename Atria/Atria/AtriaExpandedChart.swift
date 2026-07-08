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

    @State private var visibleDays: Int = 0
    @State private var activeOverlayTitle: String?
    @State private var brushStart: Date?
    @State private var brushEnd: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spanDays: Int {
        guard let first = points.first?.day, let last = points.last?.day else { return 1 }
        return max(1, Calendar.current.dateComponents([.day], from: first, to: last).day ?? 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let landscapeWidth = max(proxy.size.width, proxy.size.height) - 32
            let landscapeHeight = min(proxy.size.width, proxy.size.height) - 96
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 10) {
                    header
                    chartBody
                        .frame(width: landscapeWidth, height: landscapeHeight - 60)
                    footer
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

    private var chartBody: some View {
        Chart {
            if let baselineBand {
                RectangleMark(xStart: .value("Start", points.first?.day ?? Date()),
                              xEnd: .value("End", points.last?.day ?? Date()),
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
                ForEach(rescaledOverlayPoints(overlay)) { point in
                    LineMark(x: .value("Day", point.day, unit: .day),
                             y: .value(title, point.value),
                             series: .value("Series", "overlay"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(overlay.tint.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                }
            }

            ForEach(points) { point in
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
                          y: .value(title, eventLaneY))
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
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
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
            if !overlays.isEmpty {
                ForEach(overlays, id: \.title) { overlay in
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
            if !events.isEmpty {
                Label("\(events.count) activities marked", systemImage: "flag.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("\(min(visibleDays, spanDays)) of \(spanDays) days visible")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var activeOverlay: (title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])? {
        overlays.first { $0.title == activeOverlayTitle }
    }

    /// Maps the overlay's values from its own min-max into this chart's
    /// y-domain: an honest SHAPE comparison (the dashed line + "scaled to
    /// fit" caption make clear the units differ).
    private func rescaledOverlayPoints(_ overlay: (title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])) -> [AtriaDetailChartPoint] {
        let values = overlay.points.map(\.value)
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return [] }
        let domain = yDomain
        let pad = (domain.upperBound - domain.lowerBound) * 0.06
        let targetLo = domain.lowerBound + pad
        let targetHi = domain.upperBound - pad
        return overlay.points.map { point in
            let fraction = (point.value - lo) / (hi - lo)
            return AtriaDetailChartPoint(day: point.day,
                                         value: targetLo + fraction * (targetHi - targetLo),
                                         tint: overlay.tint)
        }
    }

    /// Honest summary of the brushed window: only real points inside it.
    private var brushSummaryText: String? {
        guard let start = brushStart, let end = brushEnd else { return nil }
        let lo = min(start, end), hi = max(start, end)
        let inside = points.filter { $0.day >= lo && $0.day <= hi }
        guard !inside.isEmpty else { return "No data in selection" }
        let values = inside.map(\.value)
        let avg = values.reduce(0, +) / Double(values.count)
        let days = (Calendar.current.dateComponents([.day], from: lo, to: hi).day ?? 0) + 1
        return String(format: "%dd \u{00b7} avg %.1f%@ \u{00b7} %.1f\u{2013}%.1f", days, avg, unit, values.min() ?? 0, values.max() ?? 0)
    }

    private var eventLaneY: Double {
        yDomain.upperBound - (yDomain.upperBound - yDomain.lowerBound) * 0.04
    }

    /// Half-day pad each side so edge points render fully.
    private var xDomain: ClosedRange<Date> {
        let first = points.first?.day ?? Date()
        let last = points.last?.day ?? Date()
        return first.addingTimeInterval(-43_200)...last.addingTimeInterval(43_200)
    }

    private var yDomain: ClosedRange<Double> {
        var values = points.map(\.value) + priorPoints.map(\.value)
        if let baselineBand {
            values.append(baselineBand.lower)
            values.append(baselineBand.upper)
        }
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return 0...1 }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }
}
