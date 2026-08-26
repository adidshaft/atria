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

extension AtriaChartEvent {
    /// The ONE activity-marker builder every chart route shares: the compact
    /// trend card's expanded route, the metric-detail expanded route, and the
    /// Vitals trend host must all describe the same saved records the same
    /// way. Divergent per-surface copies were one way the full-screen chart
    /// disagreed with inline surfaces about the same day (2026-08-20
    /// expanded-activities report): the detail-sheet copy skipped the
    /// accidental-fragment gate the inline Vitals copy applied.
    /// `presentableWorkouts` is the documented shared filter for chart
    /// markers (AtriaWorkoutMetricPresentation); only real confirmed sleep
    /// nights mark — never review candidates.
    static func activityEvents(
        workouts: [UserConfirmedWorkout],
        sleepNights: [SleepHistorySnapshot.Night]
    ) -> [AtriaChartEvent] {
        var events = AtriaWorkoutMetricPresentation.presentableWorkouts(workouts).map { workout in
            AtriaChartEvent(id: "workout-\(workout.id)",
                            day: workout.start,
                            label: workout.activitySubtype ?? workout.activityType ?? "Workout",
                            systemImage: "flame.fill",
                            tint: Metrics.electricStrain)
        }
        events.append(contentsOf: sleepNights.filter(\.confirmed).map { night in
            AtriaChartEvent(id: "sleep-\(night.id)",
                            day: night.day,
                            label: "Sleep",
                            systemImage: "bed.double.fill",
                            tint: Metrics.electricSleep)
        })
        return events
    }
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
    /// Window noun ("week", "month", …) used only to word the compare delta's
    /// scope ("Month-over-month"). The comparison series is always priorPoints.
    var comparisonPeriodNoun: String = "period"
    /// Form the chart opens in. Expanding a chart should show the SAME shape
    /// the user just tapped — a once-a-day metric drawn as bars (a bar states
    /// "this much, measured from zero") opened as a line, which read as a
    /// different chart of different data. The user can still switch form from
    /// "Edit this chart"; this only sets where it starts.
    var defaultChartType: AtriaGraphChartType = .line
    let onDismiss: () -> Void
    private let prepared: AtriaExpandedChartPreparedModel

    @State private var visibleDays: Int = 0
    @State private var activeOverlayTitle: String?
    @State private var brushStart: Date?
    @State private var brushEnd: Date?
    // Graph grammar slice 4 (2026-08-01). Compare (pattern 2) and edit-chart
    // (pattern 4) state. Compare is off by default — the design's "Compare on"
    // toggle — so the prior-period overlay appears only when asked for.
    @State private var compareOn: Bool = false
    @State private var compareMode: AtriaGraphCompareMode = .previousPeriod
    @State private var chartType: AtriaGraphChartType = .line
    @State private var markJournalEvents: Bool = true
    @State private var showCompareSheet: Bool = false
    @State private var showEditSheet: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String,
         unit: String,
         tint: Color,
         points: [AtriaDetailChartPoint],
         priorPoints: [AtriaDetailChartPoint] = [],
         baselineBand: AtriaDetailBaselineBand? = nil,
         events: [AtriaChartEvent] = [],
         overlays: [(title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])] = [],
         xDomain: ClosedRange<Date>? = nil,
         comparisonPeriodNoun: String = "period",
         defaultChartType: AtriaGraphChartType = .line,
         onDismiss: @escaping () -> Void) {
        self.title = title
        self.unit = unit
        self.tint = tint
        self.points = points
        self.priorPoints = priorPoints
        self.baselineBand = baselineBand
        self.events = events
        self.overlays = overlays
        self.comparisonPeriodNoun = comparisonPeriodNoun
        self.defaultChartType = defaultChartType
        _chartType = State(initialValue: defaultChartType)
        self.onDismiss = onDismiss
        self.prepared = AtriaExpandedChartPreparedModel(points: points,
                                                        priorPoints: priorPoints,
                                                        baselineBand: baselineBand,
                                                        overlays: overlays,
                                                        explicitXDomain: xDomain)
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
                    } else if dataDayCount < Self.minimumDaysForExploration {
                        // Sparse-but-not-empty (2026-08-03): a couple of days
                        // spread across a landscape plot renders as a near-empty
                        // chart whose default brush lands on gaps ("No data in
                        // selection") — it reads as broken. Say plainly that
                        // history is still building, with the REAL day count.
                        buildingHistoryState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        if compareOn { compareStrip }
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
        .sheet(isPresented: $showCompareSheet) {
            AtriaGraphCompareSheet(compareOn: $compareOn,
                                   mode: $compareMode,
                                   availability: compareAvailability,
                                   delta: compareDelta,
                                   tint: tint)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEditSheet) {
            AtriaEditChartSheet(primaryTitle: title,
                                primaryTint: tint,
                                plotOptions: plotOptions,
                                activeOverlayTitle: $activeOverlayTitle,
                                chartType: $chartType,
                                chartTypeOptions: chartTypeOptions,
                                markJournalEvents: $markJournalEvents,
                                hasJournalEvents: visibleEventCount > 0)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// Compact compare readout above the plot: swatches plus the honest delta.
    @ViewBuilder private var compareStrip: some View {
        HStack(spacing: 12) {
            AtriaGraphCompareLegend(currentTitle: "This \(comparisonPeriodNoun)",
                                    currentTint: tint,
                                    comparisonTitle: compareMode.title)
            Spacer(minLength: 8)
            if let compareDelta {
                Text("\(compareDelta.deltaText) · \(compareDelta.scopeText)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text(compareAvailability.disabledNote(for: compareMode) ?? "Not enough data to compare")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
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
                showCompareSheet = true
            } label: {
                Image(systemName: compareOn ? "square.filled.on.square" : "square.on.square")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(compareOn ? tint : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Compare against another period")
            Button {
                showEditSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Edit chart: plot, chart type, journal markers")
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

    /// Below this many recorded days, the brushing/exploration UI has nothing to
    /// explore — show the building-history state instead of a near-empty plot.
    static let minimumDaysForExploration = 4

    /// The REAL number of distinct days with a recorded value (never a fabricated
    /// count) — drives the sparse-data gate and the "N days" copy.
    private var dataDayCount: Int {
        Set(points.map { Calendar.current.startOfDay(for: $0.day) }).count
    }

    private var buildingHistoryState: some View {
        VStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.title2)
                .foregroundStyle(tint.opacity(0.7))
            Text("Building your history")
                .font(.subheadline.weight(.semibold))
            Text(dataDayCount == 1
                 ? "1 day of \(title.lowercased()) recorded. The expanded view opens once there are a few days to explore."
                 : "\(dataDayCount) days of \(title.lowercased()) recorded. The expanded view opens once there are a few days to explore.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
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

            // Comparison overlay (pattern 2): only drawn when Compare is on and
            // the selected mode is one Atria actually has data for. The prior
            // series is the "previous period"; the other modes stay disabled in
            // the compare sheet rather than drawing a fabricated line.
            if compareOn, compareMode == .previousPeriod {
                ForEach(priorPoints) { point in
                    LineMark(x: .value("Day", point.day, unit: .day),
                             y: .value(title, point.value),
                             series: .value("Series", "prior-\(point.segment)"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(AtriaChartVisualGrammar.comparisonLine)
                }
            }

            if let overlay = activeOverlay {
                ForEach(overlay.points) { point in
                    LineMark(x: .value("Day", point.day, unit: .day),
                             y: .value(title, point.value),
                             series: .value("Series", "overlay-\(point.segment)"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(overlay.tint.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5,
                                               lineCap: .round,
                                               lineJoin: .round,
                                               dash: [6, 3]))
                }
            }

            // Current series, drawn per the selected chart type (pattern 4).
            currentSeriesMarks

            // Event lane: real saved activity pinned to the top of the plot.
            // Gated by the edit-chart "Mark journal events" toggle. Draws the
            // day-bucketed in-domain lane list so the rendered markers, the
            // footer count, and the edit sheet's availability all describe
            // the exact same events.
            if markJournalEvents {
                ForEach(laneEvents) { event in
                    PointMark(x: .value("Day", event.day, unit: .day),
                              y: .value(title, prepared.eventLaneY))
                        .symbol {
                            Image(systemName: event.systemImage)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(event.tint)
                        }
                }
            }

            if let start = brushStart, let end = brushEnd {
                RectangleMark(xStart: .value("Brush start", min(start, end)),
                              xEnd: .value("Brush end", max(start, end)))
                    .foregroundStyle(tint.opacity(0.14))
            }
        }
        .atriaGraphPlotSurface()
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: max(1, visibleDays) * 86_400)
        .chartXScale(domain: prepared.xDomain)
        .chartYScale(domain: barAwareYDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
                AxisTick().foregroundStyle(.secondary.opacity(0.55))
                if let date = value.as(Date.self) {
                    // Centred ONLY in bar form. A `unit: .day` bar occupies the
                    // whole day, so its date belongs in the middle of that
                    // span; line and range plot each point AT its date, where
                    // centring would shift every label half a day off its own
                    // point. This view can draw all three, so the flag follows
                    // whichever is showing.
                    AxisValueLabel(centered: effectiveChartType == .bars) {
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

    /// Only events the marker lane actually draws (the 2026-07-31 audit item
    /// 10 rule: never count what is not marked). Membership must use the same
    /// DAY-BUCKETED x the lane's `unit: .day` PointMark plots — the previous
    /// raw-timestamp domain test disagreed with the render, so an afternoon
    /// workout on the last plotted day drew a marker while counting as zero,
    /// which told the edit sheet there were no journal events to toggle
    /// (2026-08-20 expanded-activities report).
    private var laneEvents: [AtriaChartEvent] {
        Self.eventLaneEvents(events, xDomain: prepared.xDomain)
    }

    private var visibleEventCount: Int {
        laneEvents.count
    }

    /// Pure lane membership: an event marks iff its DAY (the lane renders
    /// day-bucketed marks) sits inside the x-domain. Half-open on the upper
    /// edge so a calendar-period domain ending at the NEXT period's midnight
    /// never admits the next period's first day.
    static func eventLaneEvents(_ events: [AtriaChartEvent],
                                xDomain: ClosedRange<Date>,
                                calendar: Calendar = .current) -> [AtriaChartEvent] {
        events.filter { event in
            let day = calendar.startOfDay(for: event.day)
            return day >= xDomain.lowerBound && day < xDomain.upperBound
        }
    }

    // MARK: Graph grammar slice 4 — chart-type + compare (2026-08-01)

    /// Current series drawn in the selected chart type. Line keeps the shipped
    /// area+line+points; Bars is a per-point bar; Range draws each bucket's real
    /// min–max as a thin bar (only where a band exists) with its value dotted.
    @ChartContentBuilder private var currentSeriesMarks: some ChartContent {
        switch effectiveChartType {
        case .line:
            ForEach(points) { point in
                // Subtle area fill beneath the current line (Apple Health idiom,
                // matching AtriaTrendChartCard). Purely decorative: the bounded
                // y-scale keeps it inside the plot, and no value is implied
                // beyond the real sampled line it sits under.
                AreaMark(x: .value("Day", point.day, unit: .day),
                         y: .value(title, point.value),
                         series: .value("Series", "current-fill-\(point.segment)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [tint.opacity(0.24), tint.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                LineMark(x: .value("Day", point.day, unit: .day),
                         y: .value(title, point.value),
                         series: .value("Series", "current-\(point.segment)"))
                    .interpolationMethod(.monotone)
                    .lineStyle(AtriaChartVisualGrammar.trendLine)
                    .foregroundStyle(tint)
                PointMark(x: .value("Day", point.day, unit: .day),
                          y: .value(title, point.value))
                    .foregroundStyle(point.tint)
                    .symbolSize(30)
            }
        case .bars:
            ForEach(points) { point in
                BarMark(x: .value("Day", point.day, unit: .day),
                        y: .value(title, point.value))
                    .foregroundStyle(tint.gradient)
                    .cornerRadius(3)
            }
        case .range:
            ForEach(points) { point in
                if let lower = point.bandLower, let upper = point.bandUpper, upper > lower {
                    BarMark(x: .value("Day", point.day, unit: .day),
                            yStart: .value("Min", lower),
                            yEnd: .value("Max", upper),
                            width: .fixed(6))
                        .foregroundStyle(tint.opacity(0.32))
                        .cornerRadius(3)
                }
                PointMark(x: .value("Day", point.day, unit: .day),
                          y: .value(title, point.value))
                    .foregroundStyle(point.tint)
                    .symbolSize(30)
            }
        }
    }

    /// Whether the plotted points carry a real min–max band; gates the Range
    /// chart type so it is never offered for band-less daily points.
    private var hasMinMaxBand: Bool {
        points.contains { $0.bandLower != nil && $0.bandUpper != nil }
    }

    private var chartTypeOptions: [AtriaGraphChartType] {
        AtriaGraphChartType.options(hasMinMaxBand: hasMinMaxBand)
    }

    /// Falls back to Line if a previously chosen type is no longer valid for
    /// the current data (e.g. Range after the band went away).
    private var effectiveChartType: AtriaGraphChartType {
        chartTypeOptions.contains(chartType) ? chartType : .line
    }

    /// `prepared.yDomain` pads 12% around min…max, which is right for a line —
    /// it shows a level in context. It is wrong for a bar, which draws from the
    /// zero baseline: with the floor above zero the bar is clipped at the plot
    /// edge (`atriaGraphPlotSurface` clips the plot area) and its rendered
    /// height becomes proportional to `value − domainLower` rather than to
    /// `value`. A sleep week of 5.5…8.0 h pads to 5.2…8.3, drawing a 1.45×
    /// difference as roughly 9×.
    ///
    /// The two inline surfaces already anchor bars at zero for this reason —
    /// `AtriaOverviewSections`' metric chart and `AtriaTrendChart.trendYDomain`.
    /// This is the same rule at the third surface, which now opens in bar form
    /// by default for once-a-day metrics.
    private var barAwareYDomain: ClosedRange<Double> {
        guard effectiveChartType == .bars else { return prepared.yDomain }
        return 0...max(prepared.yDomain.upperBound, 1)
    }

    /// Which comparison modes have real data. Only the previous-period series
    /// is passed into this chart; the other two stay honestly disabled.
    private var compareAvailability: AtriaGraphCompareAvailability {
        AtriaGraphCompareAvailability.make(currentCount: points.count,
                                           previousPeriodCount: priorPoints.count,
                                           samePeriodLastYearCount: 0)
    }

    /// The honest delta for the active compare mode, or nil when it can't be
    /// stated from real data.
    private var compareDelta: AtriaGraphCompareDelta? {
        guard compareMode == .previousPeriod else { return nil }
        return AtriaGraphCompareDelta(current: points.map(\.value),
                                      comparison: priorPoints.map(\.value),
                                      unit: unit,
                                      scopeText: AtriaGraphCompareDelta.scope(for: compareMode,
                                                                              noun: comparisonPeriodNoun))
    }

    /// Sibling overlays offered in the edit-chart plot list; each marked with
    /// whether it actually has data to draw.
    private var plotOptions: [AtriaEditChartPlotOption] {
        prepared.overlays.map {
            AtriaEditChartPlotOption(title: $0.title, tint: $0.tint, hasData: !$0.points.isEmpty)
        }
    }

    /// Honest summary of the brushed window: only real points inside it.
    private var brushSummaryText: String? {
        guard let start = brushStart, let end = brushEnd else { return nil }
        return prepared.brushSummary(start: start, end: end, unit: unit)
    }
}

struct AtriaExpandedChartPreparedOverlay: Identifiable {
    let title: String
    let unit: String
    let tint: Color
    let points: [AtriaDetailChartPoint]

    var id: String { title }
}

struct AtriaExpandedChartPreparedModel {
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
         overlays: [(title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])],
         explicitXDomain: ClosedRange<Date>? = nil,
         calendar: Calendar = .current) {
        let now = Date()
        dataStart = points.first?.day ?? now
        dataEnd = points.last?.day ?? now
        // The metric-detail route plots a calendar PERIOD: its inline chart's
        // x-domain is the full selected week/month, not just the sub-range
        // holding metric points. Deriving the expanded domain from points
        // alone CLIPPED the activity lane to that sub-range, silently
        // dropping markers for period days whose metric had not settled yet —
        // today's confirmed sleep or workout, exactly the records the inline
        // surfaces show (2026-08-20 expanded-activities report). An explicit
        // domain from the presenting chart therefore wins; the trend-card
        // route keeps the legacy data-derived window unchanged.
        if let explicitXDomain {
            xDomain = explicitXDomain
            spanDays = max(1, calendar.dateComponents([.day],
                                                      from: explicitXDomain.lowerBound,
                                                      to: explicitXDomain.upperBound).day ?? 1)
        } else {
            xDomain = dataStart.addingTimeInterval(-43_200)...dataEnd.addingTimeInterval(43_200)
            spanDays = max(1, calendar.dateComponents([.day], from: dataStart, to: dataEnd).day ?? 1)
        }

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
                                         tint: tint,
                                         segment: point.segment)
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
