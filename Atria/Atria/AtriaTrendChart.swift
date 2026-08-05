import Combine
import SwiftUI
import Charts

/// Native iOS 26 Swift Charts trend card with a segmented metric selector.
/// Renders recent saved-session history for resting HR, strain, or HRV so the
/// long text-only "Trend" line becomes a real, selectable graph. Performance:
/// the data points are derived once per input/metric/range change and the chart
/// itself draws static marks (no interactive glass, no per-frame work).
struct AtriaTrendChartCard: View {
    let points: [AtriaTrendPoint]
    let pointsRevision: Int?
    let baselineRestingHR: Int?
    /// Real saved activity for the expanded chart's marker lane. Optional so
    /// existing call sites/tests compile unchanged.
    var events: [AtriaChartEvent] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var metric: AtriaTrendMetric = .restingHR
    // This card plots ONE point per civil day (makeOverviewTrendPoints), so a
    // one-day window can never reach the 2-point line gate — a "D" segment
    // here was a permanently empty chart. Default to the shortest range that
    // can actually draw (2026-07-31 audit item 1).
    @State private var range: AtriaTrendRange = .week
    @State private var prepared = AtriaTrendPreparedSeries.empty
    // Tap-to-expand + drag-to-scrub (docs/24 §14 UI direction): the compact
    // card opens a large inspection sheet; both share native chartXSelection.
    @State private var scrubDate: Date?
    @State private var showExpandedChart = false
    @State private var periodReadout = AtriaTrendPeriodReadout.empty
    @State private var rangeCoverage: [AtriaTrendRange: Int] = [:]
    // Perf (handoff #5/#8): watching the full points array did a full equality
    // before the skip guard could help. Watch a cheap O(1) key instead;
    // store-backed data supplies a revision, previews fall back to endpoint
    // identity.
    @State private var preparedKey: PreparedKey?

    private struct PointsKey: Equatable {
        let revision: Int?
        let count: Int
        let firstID: UUID?
        let firstDate: Date?
        let firstRestingHR: Int?
        let firstStrain: Double?
        let firstHRV: Int?
        let lastID: UUID?
        let lastDate: Date?
        let lastRestingHR: Int?
        let lastStrain: Double?
        let lastHRV: Int?

        init(points: [AtriaTrendPoint], revision: Int?) {
            self.revision = revision
            count = points.count
            firstID = points.first?.id
            firstDate = points.first?.date
            firstRestingHR = points.first?.restingHR
            firstStrain = points.first?.strain
            firstHRV = points.first?.hrv
            lastID = points.last?.id
            lastDate = points.last?.date
            lastRestingHR = points.last?.restingHR
            lastStrain = points.last?.strain
            lastHRV = points.last?.hrv
        }
    }

    private struct PreparedKey: Equatable {
        let pointsKey: PointsKey
        let metric: AtriaTrendMetric
        let range: AtriaTrendRange
        let baselineRestingHR: Int?
    }
    // Real progressive disclosure: the compact card shows just the chart; the
    // stacked context sub-cards (range dock, report, balance map, glance board,
    // range lens, position band, dot strip) collapse behind this toggle so the
    // card is no longer a long "box inside box" accordion by default.
    @State private var showMoreInsights = false

    private var pointsKey: PointsKey {
        PointsKey(points: points, revision: pointsRevision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                // "N days" read as calendar coverage; the count is days WITH
                // data in the window (2026-07-31 audit item 13).
                AtriaPanelSectionHeader(title: "Trends", subtitle: "\(range.headerLabel) · \(prepared.series.count)d of data")
                Spacer(minLength: 0)
                // Expanding an empty series rendered a full-screen chart with
                // a fabricated 0…1 axis and "1 of 1 days visible". Mirror the
                // metric-detail rule: no expand until a real line exists.
                if prepared.series.count >= 2 {
                    Button {
                        showExpandedChart = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Expand chart")
                }
            }

            // Native-clean (design 2026-08-05): replaced two stacked segmented
            // pill bars with light plain-text selector rows (Apple-Stocks feel).
            // The range stays a fully-visible tappable selector -- not a Menu --
            // honoring the readability guard on AtriaTrendRange.
            VStack(spacing: 10) {
                AtriaTextSelector(items: AtriaTrendMetric.allCases,
                                  title: { $0.shortLabel },
                                  selection: $metric)
                AtriaTextSelector(items: AtriaTrendRange.trendCardSegments,
                                  title: { $0.segmentedLabel },
                                  selection: $range)
            }

            // Chart-first (2026-07-06): the trend chart was buried at the BOTTOM of
            // this card beneath ~8 stacked context sub-cards ("box inside box"), so
            // the primary visualization was the last thing the user reached. It now
            // sits directly under the pickers; the range dock, report, balance map,
            // glance board, range lens, position band and dot-strip context follow
            // below the chart as supporting detail.
            if prepared.series.count < 2 {
                emptyState
            } else {
                chart
                    .frame(height: 210)
                    // Clip the AreaMark gradient to the chart bounds. Without this
                    // the area fill bleeds below the 210pt frame; it was previously
                    // hidden because the chart sat at the card's bottom edge, but
                    // chart-first ordering now places content beneath it.
                    .clipped()
                if let ghostCaptionText {
                    Text(ghostCaptionText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if prepared.series.count >= 2 {
                Button {
                    showMoreInsights.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.black))
                            .rotationEffect(.degrees(showMoreInsights ? 180 : 0))
                        Text(showMoreInsights ? "Hide insights" : "More insights")
                            .font(.caption.weight(.bold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.primary.opacity(0.05), in: Capsule(style: .continuous))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showMoreInsights ? "Hide insights" : "More insights")
            }

            if showMoreInsights {
                // AtriaTrendRangeDock unmounted (dedup audit 2026-07-07):
                // it was a second control mutating the same $range as the
                // segmented picker, with the day counts shown a third way.
                // The struct stays for potential reuse of its coverage rail.

                if periodReadout.hasEnoughSignal {
                    AtriaTrendRangeReportCard(readout: periodReadout)
                    AtriaTrendPeriodBalanceMap(readout: periodReadout)
                    AtriaTrendGlanceBoard(readout: periodReadout)
                }

                AtriaTrendRangeLens(range: range,
                                    metric: metric,
                                    summary: prepared.summary,
                                    sampleCount: prepared.series.count)

                if let assessment = prepared.assessment, !periodReadout.hasEnoughSignal {
                    AtriaTrendRangeAssessmentCard(assessment: assessment)
                }

                if let action = prepared.action, !periodReadout.hasEnoughSignal {
                    AtriaTrendActionReadoutCard(action: action)
                } else if let summary = prepared.summary {
                    AtriaTrendRangeSummaryStrip(summary: summary, tint: metric.tint)
                }

                if prepared.series.count >= 3 {
                    AtriaTrendRangePositionBand(series: prepared.series,
                                                metric: metric)
                }

                if prepared.series.count >= 3 {
                    AtriaTrendSessionDotStrip(series: prepared.series,
                                              metric: metric)
                }
            }
        }
        .padding(16)
        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic), value: showMoreInsights)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
        // Metric/range controls already animate their own selection chrome. A
        // broad implicit animation here also animated every Chart mark and the
        // full report subtree, making data switches noticeably more expensive.
        .onChange(of: pointsKey, initial: true) { _, _ in refreshPreparedSeries() }
        .onChange(of: baselineRestingHR) { _, _ in refreshPreparedSeries() }
        .onChange(of: metric) { _, _ in refreshPreparedSeries() }
        .onChange(of: range) { _, _ in refreshPreparedSeries() }
        // Landscape expanded chart (user feedback 2026-07-07): replaces the
        // old portrait sheet with the shared zoom/brush/markers experience.
        .fullScreenCover(isPresented: $showExpandedChart) {
            AtriaExpandedChartView(title: "\(metric.shortLabel) trend",
                                   unit: expandedUnit,
                                   tint: metric.tint,
                                   points: expandedChartPoints,
                                   priorPoints: expandedPriorPoints,
                                   events: events,
                                   overlays: expandedChartOverlays,
                                   comparisonPeriodNoun: range.narrativeLabel,
                                   onDismiss: { showExpandedChart = false })
        }
    }

    private var expandedUnit: String {
        Self.expandedUnit(for: metric)
    }

    private static func expandedUnit(for metric: AtriaTrendMetric) -> String {
        switch metric {
        case .restingHR: return " bpm"
        case .strain: return ""
        case .hrv: return " ms"
        }
    }

    /// The focused metric's real daily values in the shared chart-point
    /// shape, limited to the range the compact card is showing — expanding a
    /// "last week" chart must not silently widen it to the full 92-day
    /// series. Days without a value are simply absent.
    private var expandedChartPoints: [AtriaDetailChartPoint] {
        chartPoints(for: metric)
    }

    private func chartPoints(for metric: AtriaTrendMetric) -> [AtriaDetailChartPoint] {
        let cutoff = range.cutoffDate()
        return points.compactMap { point in
            guard point.date >= cutoff else { return nil }
            return point.value(for: metric).map {
                AtriaDetailChartPoint(day: point.date, value: $0, tint: metric.tint)
            }
        }
        .sorted { $0.day < $1.day }
    }

    /// The prior-period series the compact card already draws as its dashed
    /// ghost (time-shifted onto the current window), passed through so the
    /// expanded chart's Compare keys on the real saved history instead of
    /// claiming none exists (2026-08-06 audit fix).
    private var expandedPriorPoints: [AtriaDetailChartPoint] {
        prepared.previousSeries.map {
            AtriaDetailChartPoint(day: $0.date, value: $0.value, tint: metric.tint)
        }
    }

    /// The sibling metrics' real series over the same window, offered in the
    /// expanded chart's edit sheet — matching the metric-detail expand.
    private var expandedChartOverlays: [(title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])] {
        AtriaTrendMetric.allCases
            .filter { $0 != metric }
            .map { sibling in
                (title: sibling.shortLabel,
                 unit: Self.expandedUnit(for: sibling),
                 tint: sibling.tint,
                 points: chartPoints(for: sibling))
            }
    }

    private func refreshPreparedSeries(now: Date = Date()) {
        let key = PreparedKey(pointsKey: pointsKey, metric: metric, range: range, baselineRestingHR: baselineRestingHR)
        guard preparedKey != key else { return }
        preparedKey = key
        prepared = Self.prepareSeries(points: points,
                                      metric: metric,
                                      range: range,
                                      baselineRestingHR: baselineRestingHR,
                                      now: now)
        periodReadout = Self.preparePeriodReadout(points: points,
                                                  range: range,
                                                  now: now)
        rangeCoverage = Self.prepareRangeCoverage(points: points,
                                                  metric: metric,
                                                  now: now)
    }

    private static func prepareSeries(points: [AtriaTrendPoint],
                                      metric: AtriaTrendMetric,
                                      range: AtriaTrendRange,
                                      baselineRestingHR: Int?,
                                      now: Date) -> AtriaTrendPreparedSeries {
        let cutoff = range.cutoffDate(now: now)
        let previousCutoff = range.hasPriorPeriod
            ? cutoff.addingTimeInterval(-Double(range.days) * 86_400)
            : .distantFuture
        var samples: [AtriaTrendPoint.Sample] = []
        samples.reserveCapacity(points.count)
        var previousSamples: [AtriaTrendPoint.Sample] = []
        previousSamples.reserveCapacity(points.count)
        var domainValues: [Double] = []
        domainValues.reserveCapacity(points.count + 1)
        for point in points where point.date >= previousCutoff {
            guard let value = point.value(for: metric) else { continue }
            let sample = AtriaTrendPoint.Sample(date: point.date, value: value)
            if point.date >= cutoff {
                samples.append(sample)
                domainValues.append(value)
            } else {
                previousSamples.append(sample)
            }
        }
        // Time-shift the prior window forward onto the current window so it can
        // be drawn as a dashed ghost line sharing the same x-axis (this-N vs
        // previous-N, aligned by day-of-period rather than by date).
        let shift = Double(range.days) * 86_400
        let ghost: [AtriaTrendPoint.Sample] = range.hasPriorPeriod
            ? previousSamples.map { AtriaTrendPoint.Sample(date: $0.date.addingTimeInterval(shift), value: $0.value) }
            : []
        domainValues.append(contentsOf: ghost.map(\.value))
        let referenceValue = metric == .restingHR ? baselineRestingHR.map(Double.init) : nil
        if let referenceValue {
            domainValues.append(referenceValue)
        }
        return AtriaTrendPreparedSeries(series: samples,
                                        previousSeries: ghost,
                                        referenceValue: referenceValue,
                                        summary: AtriaTrendRangeSummary(series: samples,
                                                                        previousSeries: previousSamples,
                                                                        metric: metric),
                                        assessment: AtriaTrendRangeAssessment(series: samples,
                                                                              previousSeries: previousSamples,
                                                                              metric: metric,
                                                                              range: range),
                                        action: AtriaTrendActionReadout(series: samples,
                                                                        previousSeries: previousSamples,
                                                                        metric: metric),
                                        yDomain: AtriaTrendChartScale.domain(values: domainValues))
    }

    private static func preparePeriodReadout(points: [AtriaTrendPoint],
                                             range: AtriaTrendRange,
                                             now: Date) -> AtriaTrendPeriodReadout {
        let cutoff = range.cutoffDate(now: now)
        let previousCutoff = range.hasPriorPeriod
            ? cutoff.addingTimeInterval(-Double(range.days) * 86_400)
            : .distantFuture
        var currentHRV: [Double] = []
        var priorHRV: [Double] = []
        var currentRHR: [Double] = []
        var priorRHR: [Double] = []
        var currentStrain: [Double] = []
        var priorStrain: [Double] = []

        currentHRV.reserveCapacity(points.count)
        priorHRV.reserveCapacity(points.count)
        currentRHR.reserveCapacity(points.count)
        priorRHR.reserveCapacity(points.count)
        currentStrain.reserveCapacity(points.count)
        priorStrain.reserveCapacity(points.count)

        for point in points where point.date >= previousCutoff {
            let isCurrent = point.date >= cutoff
            if let hrv = point.hrv, hrv > 0 {
                isCurrent ? currentHRV.append(Double(hrv)) : priorHRV.append(Double(hrv))
            }
            if let restingHR = point.restingHR, restingHR > 0 {
                isCurrent ? currentRHR.append(Double(restingHR)) : priorRHR.append(Double(restingHR))
            }
            if let strain = point.strain, strain > 0 {
                isCurrent ? currentStrain.append(strain) : priorStrain.append(strain)
            }
        }

        return AtriaTrendPeriodReadout(rangeLabel: range.menuLabel,
                                       narrativeRangeLabel: range.narrativeLabel,
                                       hrv: AtriaTrendPeriodDelta(current: average(currentHRV),
                                                                  previous: average(priorHRV),
                                                                  metric: .hrv),
                                       restingHR: AtriaTrendPeriodDelta(current: average(currentRHR),
                                                                        previous: average(priorRHR),
                                                                        metric: .restingHR),
                                       strain: AtriaTrendPeriodDelta(current: average(currentStrain),
                                                                     previous: average(priorStrain),
                                                                     metric: .strain))
    }

    private static func prepareRangeCoverage(points: [AtriaTrendPoint],
                                             metric: AtriaTrendMetric,
                                             now: Date) -> [AtriaTrendRange: Int] {
        var output: [AtriaTrendRange: Int] = [:]
        for range in AtriaTrendRange.allCases {
            let cutoff = range.cutoffDate(now: now)
            output[range] = points.reduce(into: 0) { count, point in
                guard point.date >= cutoff,
                      point.value(for: metric) != nil else { return }
                count += 1
            }
        }
        return output
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Produces distinct, data-owned ticks instead of asking Charts to
    /// interpolate several instants inside a one-day domain. The latter
    /// rendered four identical "Jul 27" labels for a real Jul 27–28 series on
    /// the physical phone.
    nonisolated static func compactXAxisDates(
        _ dates: [Date],
        maximumCount: Int = 4
    ) -> [Date] {
        let ordered = Array(Set(dates)).sorted()
        let limit = max(2, maximumCount)
        guard ordered.count > limit else { return ordered }
        let finalIndex = ordered.count - 1
        let divisor = Double(limit - 1)
        let indices = Set((0..<limit).map { slot in
            Int((Double(slot) * Double(finalIndex) / divisor).rounded())
        })
        return indices.sorted().map { ordered[$0] }
    }

    private var chartXAxisDates: [Date] {
        Self.compactXAxisDates(prepared.series.map(\.date))
    }

    /// Visible text for each compact tick, deduped so two ticks that format to
    /// the same string can never render as side-by-side identical labels — the
    /// duplicated-axis-label defect from the 2026-07-31 History audit. A date
    /// absent from this map still draws its gridline, just without a label.
    nonisolated static func compactXAxisLabelTexts(_ dates: [Date]) -> [Date: String] {
        var output: [Date: String] = [:]
        var previous: String?
        for date in dates.sorted() {
            let label = date.formatted(.dateTime.month(.abbreviated).day())
            guard label != previous else { continue }
            output[date] = label
            previous = label
        }
        return output
    }

    private var chartXAxisLabels: [Date: String] {
        Self.compactXAxisLabelTexts(chartXAxisDates)
    }

    private var chart: some View {
        coreChart
    }

    private var coreChart: some View {
        Chart {
            if let referenceValue = prepared.referenceValue {
                RuleMark(y: .value("Baseline", referenceValue))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, alignment: .leading) {
                        Text("baseline \(Int(referenceValue))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }

            if showGhost {
                // Contiguous day-runs (2026-08-06 audit fix): one point per
                // civil day means a skipped wear night must render as a blank,
                // not a straight segment inventing readings — same rule as
                // the current line below.
                ForEach(prepared.previousSeries.contiguousDayRuns(), id: \.sample.date) { entry in
                    LineMark(
                        x: .value("Date", entry.sample.date),
                        y: .value("Prior \(metric.shortLabel)", entry.sample.value),
                        series: .value("Series", "prior-\(entry.runID)")
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    // Prior-period line in neutral gray, not the metric tint: a
                    // faint-tint ghost overlapped the solid tinted current line
                    // illegibly. Gray reads clearly as "before" against the tint.
                    .foregroundStyle(Color.secondary.opacity(0.55))
                }
            }

            // Contiguous day-runs so the line and its area fill BREAK at day
            // gaps instead of bridging days with no reading (2026-08-06 audit
            // fix — the chart-honesty rule the other daily charts follow).
            ForEach(prepared.series.contiguousDayRuns(), id: \.sample.date) { entry in
                AreaMark(
                    x: .value("Date", entry.sample.date),
                    y: .value(metric.shortLabel, entry.sample.value),
                    series: .value("Series", "current-area-\(entry.runID)")
                )
                .interpolationMethod(.linear)
                .foregroundStyle(
                    LinearGradient(
                        colors: [metric.tint.opacity(0.30), metric.tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                // Gradient on a multi-series mark must resolve against the
                // plot area, not each run's own bounding box.
                .alignsMarkStylesWithPlotArea()

                LineMark(
                    x: .value("Date", entry.sample.date),
                    y: .value(metric.shortLabel, entry.sample.value),
                    series: .value("Series", "current-\(entry.runID)")
                )
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .foregroundStyle(metric.tint)
            }

            if let latest = prepared.series.last {
                PointMark(
                    x: .value("Date", latest.date),
                    y: .value(metric.shortLabel, latest.value)
                )
                .symbolSize(70)
                .foregroundStyle(metric.tint)
            }

            if let scrubbed = scrubbedSample {
                RuleMark(x: .value("Selected", scrubbed.date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.secondary.opacity(0.5))
                PointMark(
                    x: .value("Date", scrubbed.date),
                    y: .value(metric.shortLabel, scrubbed.value)
                )
                .symbolSize(110)
                .foregroundStyle(metric.tint)
                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    VStack(spacing: 2) {
                        Text(metric.format(scrubbed.value))
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                        Text(scrubbed.date, format: .dateTime.month(.abbreviated).day())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    // Real Liquid Glass, per the handoff's "Graph Interactions"
                    // scrub callout. This is the one place glass genuinely pays
                    // off on Atria: the callout FLOATS OVER the chart, so it
                    // refracts the line and gridlines beneath it instead of the
                    // flat near-black/near-white page backdrop. It is also cheap
                    // — it exists only while a scrub is active, so this is not
                    // the dense always-on glass that costs scroll performance.
                    // Radius snapped off the stray 8 onto the chip token.
                    .atriaGlassCard(cornerRadius: AtriaDesignTokens.Radius.chip)
                }
            }
        }
        .chartXSelection(value: $scrubDate)
        // Keep the first and last observed dates inside the plot instead of
        // pinning their labels to its clipped edges. Swift Charts otherwise
        // suppresses the trailing label on a real two-day series even when
        // both distinct dates are supplied explicitly.
        .chartXScale(range: .plotDimension(startPadding: 18, endPadding: 18))
        .chartYScale(domain: prepared.yDomain)
        .chartXAxis {
            // Labels ride the SAME axis marks as the gridlines (2026-08-01):
            // the previous parallel Spacer-based HStack guessed a 34pt leading
            // inset and spread labels evenly regardless of where the gridlines
            // actually fell, so gappy/short series rendered duplicated or
            // misaligned date labels under true-position gridlines.
            AxisMarks(preset: .aligned, values: chartXAxisDates) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                if let date = value.as(Date.self), let label = chartXAxisLabels[date] {
                    AxisValueLabel(anchor: .top) {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel().font(.caption2)
            }
        }

        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartAccessibilityLabel)
    }

    /// Honest gating for the ghost overlay: only draw it when the prior window
    /// has enough points to be a fair comparison (never fabricate a line from
    /// a couple of stray samples), and never for `.all` (no prior period).
    private var showGhost: Bool {
        prepared.previousSeries.count >= max(3, prepared.series.count / 2)
    }

    private var chartAccessibilityLabel: String {
        let daysText = prepared.series.count == 1 ? "1 day of data" : "\(prepared.series.count) days of data"
        let base = "\(metric.shortLabel) trend, \(range.headerLabel.lowercased()), \(daysText)."
        var combined = base
        if let summary = prepared.summary {
            combined += " Latest \(summary.latestText), average \(summary.averageText), range \(summary.rangeText), \(summary.comparisonAccessibilityText)."
        }
        if showGhost {
            combined += " Prior \(range.narrativeLabel) shown as a dashed line."
        }
        return combined
    }

    /// Only surfaces new copy when the ghost line is actually drawn — the
    /// "current period only" honesty copy for the non-ghost case already
    /// lives in `AtriaTrendPeriodReadout.subtitle` / the comparison strip, and
    /// `.all` never claims a prior period at all.
    private var ghostCaptionText: String? {
        guard showGhost else { return nil }
        return "Dashed · prior \(range.narrativeLabel)"
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

private struct AtriaTrendPeriodReadout: Equatable {
    let rangeLabel: String
    let narrativeRangeLabel: String
    let hrv: AtriaTrendPeriodDelta
    let restingHR: AtriaTrendPeriodDelta
    let strain: AtriaTrendPeriodDelta

    static let empty = AtriaTrendPeriodReadout(rangeLabel: "",
                                               narrativeRangeLabel: "",
                                               hrv: .empty(metric: .hrv),
                                               restingHR: .empty(metric: .restingHR),
                                               strain: .empty(metric: .strain))

    var hasEnoughSignal: Bool {
        [hrv.current, restingHR.current, strain.current].compactMap { $0 }.count >= 2
    }

    var hasPriorSignal: Bool {
        hrv.hasPrevious || restingHR.hasPrevious || strain.hasPrevious
    }

    var title: String {
        if strain.deltaValue.map({ $0 >= 1.0 }) == true {
            return "Strain-heavy \(narrativeRangeLabel)"
        }
        if hrv.deltaValue.map({ $0 <= -3 }) == true
            || restingHR.deltaValue.map({ $0 >= 2 }) == true {
            return "Recovery needs care"
        }
        if hrv.deltaValue.map({ $0 >= 3 }) == true
            && restingHR.deltaValue.map({ $0 <= 1 }) != false {
            return "Recovery-led \(narrativeRangeLabel)"
        }
        return "Steady \(narrativeRangeLabel)"
    }

    var subtitle: String {
        if !hrv.hasPrevious && !restingHR.hasPrevious && !strain.hasPrevious {
            return "Current period only; prior comparison fills in with more saved days."
        }
        return "Compared with the prior \(narrativeRangeLabel)."
    }

    var tint: Color {
        if title.hasPrefix("Strain") { return Metrics.electricStrain }
        if title.hasPrefix("Recovery needs care") { return .cyan }
        return Metrics.electricGreen
    }

    var recoveryReserve: Double {
        let hrvScore = hrv.directionScore(positiveDeltaIsGood: true)
        let rhrScore = restingHR.directionScore(positiveDeltaIsGood: false)
        let available = [hrvScore, rhrScore].compactMap { $0 }
        guard !available.isEmpty else { return 0.5 }
        return min(max(available.reduce(0, +) / Double(available.count), 0), 1)
    }

    var loadPressure: Double {
        guard let strainCurrent = strain.current else { return 0.5 }
        let absoluteLoad = min(max(strainCurrent / 21.0, 0.08), 1)
        let movement = strain.directionScore(positiveDeltaIsGood: false) ?? 0.5
        return min(max((absoluteLoad * 0.7) + ((1 - movement) * 0.3), 0), 1)
    }

    var balanceCue: String {
        if loadPressure >= 0.62 && recoveryReserve < 0.48 { return "Protect" }
        if recoveryReserve >= 0.60 && loadPressure <= 0.58 { return "Ready" }
        if loadPressure >= 0.62 { return "Unload" }
        return "Hold"
    }
}

private struct AtriaTrendGlanceBoard: View, Equatable {
    let readout: AtriaTrendPeriodReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(readout.tint.opacity(0.15))
                    Image(systemName: heroSymbol)
                        .font(.title3.weight(.black))
                        .foregroundStyle(readout.tint)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(readout.title)
                        .font(.headline.weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(readout.rangeLabel)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(heroCue)
                    .font(.caption.weight(.black))
                    .foregroundStyle(readout.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(readout.tint.opacity(0.13), in: Capsule(style: .continuous))
            }

            // Reserve/Strain lanes removed (dedup audit 2026-07-07): the
            // balance map is the single owner of that pair; this board keeps
            // its unique per-metric delta gauges.
            HStack(spacing: 8) {
                metricGauge(label: "HRV", delta: readout.hrv, tint: .cyan)
                metricGauge(label: "RHR", delta: readout.restingHR, tint: .pink)
                metricGauge(label: "Strain", delta: readout.strain, tint: Metrics.electricStrain)
            }
        }
        .padding(13)
        .atriaInsetCard(cornerRadius: 22, tint: readout.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trend glance. \(readout.title). \(heroCue). Recovery \(Int((readout.recoveryReserve * 100).rounded())) percent, strain \(Int((readout.loadPressure * 100).rounded())) percent. HRV \(readout.hrv.currentText), resting heart rate \(readout.restingHR.currentText), strain \(readout.strain.currentText).")
    }

    private var heroSymbol: String {
        if readout.title.hasPrefix("Strain") { return "bolt.heart.fill" }
        if readout.title.hasPrefix("Recovery needs care") { return "waveform.path.ecg.rectangle" }
        return "scope"
    }

    private var heroCue: String {
        if readout.title.hasPrefix("Strain") { return "Recover" }
        if readout.title.hasPrefix("Recovery needs care") { return "Protect" }
        if readout.title.hasPrefix("Recovery-led") { return "Ready" }
        return "Steady"
    }

    private func glanceLane(title: String, value: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(Int((value * 100).rounded()))")
                    .font(.caption.monospacedDigit().weight(.black))
                    .foregroundStyle(tint)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.12))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.76))
                        .frame(width: max(8, width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    private func metricGauge(label: String, delta: AtriaTrendPeriodDelta, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: deltaArrowSymbol(delta))
                    .font(.caption2.weight(.black))
                    .foregroundStyle(tint)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.secondary.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(.secondary.opacity(delta.previous == nil ? 0.08 : 0.22))
                        .frame(width: max(7, width * delta.previousProgress))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(delta.current == nil ? 0.18 : 0.82))
                        .frame(width: max(8, width * delta.currentProgress))
                }
            }
            .frame(height: 9)
            .accessibilityHidden(true)

            Text(delta.currentText)
                .font(.caption.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func deltaArrowSymbol(_ delta: AtriaTrendPeriodDelta) -> String {
        switch delta.directionText {
        case "up": return "arrow.up"
        case "down": return "arrow.down"
        case "flat": return "arrow.right"
        default: return "ellipsis"
        }
    }
}

private struct AtriaTrendPeriodOrbit: View, Equatable {
    let readout: AtriaTrendPeriodReadout

    var body: some View {
        HStack(spacing: 10) {
            orbitGauge(label: "HRV",
                       value: readout.hrv.currentText,
                       delta: readout.hrv,
                       tint: .cyan,
                       positiveDeltaIsGood: true)
            orbitGauge(label: "RHR",
                       value: readout.restingHR.currentText,
                       delta: readout.restingHR,
                       tint: .pink,
                       positiveDeltaIsGood: false)
            orbitGauge(label: "Strain",
                       value: readout.strain.currentText,
                       delta: readout.strain,
                       tint: Metrics.electricStrain,
                       positiveDeltaIsGood: false)
        }
        .padding(10)
        .background(readout.tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(readout.tint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trend period orbit for \(readout.rangeLabel). HRV \(readout.hrv.currentText), \(readout.hrv.deltaText). Resting heart rate \(readout.restingHR.currentText), \(readout.restingHR.deltaText). Strain \(readout.strain.currentText), \(readout.strain.deltaText).")
    }

    private func orbitGauge(label: String,
                            value: String,
                            delta: AtriaTrendPeriodDelta,
                            tint: Color,
                            positiveDeltaIsGood: Bool) -> some View {
        let progress = delta.directionScore(positiveDeltaIsGood: positiveDeltaIsGood) ?? 0.5
        return VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.14), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0.08), 1))
                    .stroke(tint.opacity(delta.current == nil ? 0.24 : 0.86),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: orbitSymbol(for: delta))
                    .font(.caption.weight(.black))
                    .foregroundStyle(tint)
            }
            .frame(width: 42, height: 42)

            Text(label)
                .font(.caption2.weight(.black))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func orbitSymbol(for delta: AtriaTrendPeriodDelta) -> String {
        switch delta.directionText {
        case "up": return "arrow.up"
        case "down": return "arrow.down"
        case "flat": return "arrow.right"
        default: return "ellipsis"
        }
    }
}

private struct AtriaTrendSignalStack: View, Equatable {
    let readout: AtriaTrendPeriodReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Signal stack", systemImage: "waveform.path")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(readout.tint)
                Spacer(minLength: 8)
                Text(readout.rangeLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            signalLane(label: "HRV", delta: readout.hrv, tint: .cyan)
            signalLane(label: "RHR", delta: readout.restingHR, tint: .pink)
            signalLane(label: "Strain", delta: readout.strain, tint: Metrics.electricStrain)
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 18, tint: readout.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trend signal stack for \(readout.rangeLabel). HRV \(readout.hrv.currentText), \(readout.hrv.deltaText). Resting heart rate \(readout.restingHR.currentText), \(readout.restingHR.deltaText). Strain \(readout.strain.currentText), \(readout.strain.deltaText).")
    }

    private func signalLane(label: String,
                            delta: AtriaTrendPeriodDelta,
                            tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
                .frame(width: 54, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.secondary.opacity(0.10))
                    .frame(height: 8)
                Capsule(style: .continuous)
                    .fill(.secondary.opacity(delta.previous == nil ? 0.08 : 0.24))
                    .frame(width: 104 * delta.previousProgress, height: 8)
                Capsule(style: .continuous)
                    .fill(tint.opacity(delta.current == nil ? 0.16 : 0.82))
                    .frame(width: 104 * delta.currentProgress, height: 8)
            }
            .frame(width: 104, height: 12, alignment: .leading)

            Text(delta.currentText)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(delta.deltaText)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

private struct AtriaTrendPeriodBalanceMap: View, Equatable {
    let readout: AtriaTrendPeriodReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Balance map", systemImage: "circle.grid.cross")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(readout.tint)
                Spacer(minLength: 8)
                Text(readout.balanceCue)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(readout.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(readout.tint.opacity(0.12), in: Capsule(style: .continuous))
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let height = max(proxy.size.height, 1)
                let x = width * readout.loadPressure
                let y = height * (1 - readout.recoveryReserve)

                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(colors: [
                                .cyan.opacity(0.16),
                                Metrics.electricStrain.opacity(0.12)
                            ], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )

                    Path { path in
                        path.move(to: CGPoint(x: width / 2, y: 0))
                        path.addLine(to: CGPoint(x: width / 2, y: height))
                        path.move(to: CGPoint(x: 0, y: height / 2))
                        path.addLine(to: CGPoint(x: width, y: height / 2))
                    }
                    .stroke(.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    VStack {
                        HStack {
                            mapCorner("Ready", alignment: .leading)
                            Spacer()
                            mapCorner("Push", alignment: .trailing)
                        }
                        Spacer()
                        HStack {
                            mapCorner("Recover", alignment: .leading)
                            Spacer()
                            mapCorner("Protect", alignment: .trailing)
                        }
                    }
                    .padding(10)

                    Circle()
                        .fill(readout.tint)
                        .frame(width: 15, height: 15)
                        .shadow(color: readout.tint.opacity(0.35), radius: 8, x: 0, y: 3)
                        .position(x: min(max(x, 10), width - 10),
                                  y: min(max(y, 10), height - 10))
                }
            }
            .frame(height: 116)

            // Reserve/Load pills removed (dedup audit 2026-07-07): the map
            // dot IS the pair; the numbers live in its accessibility label.
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 20, tint: readout.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Balance map. Recovery reserve \(Int((readout.recoveryReserve * 100).rounded())) percent. Load pressure \(Int((readout.loadPressure * 100).rounded())) percent. Cue \(readout.balanceCue).")
    }

    private func mapCorner(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 72, alignment: alignment)
    }

    private func balancePill(_ title: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.12))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.72))
                        .frame(width: max(8, width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 7)
            Text("\(Int((value * 100).rounded()))")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AtriaTrendRangeReportCard: View, Equatable {
    let readout: AtriaTrendPeriodReadout

    private var strongestSignal: (title: String, value: String, tint: Color, symbol: String) {
        let hrvScore = readout.hrv.directionScore(positiveDeltaIsGood: true) ?? 0.5
        let rhrScore = readout.restingHR.directionScore(positiveDeltaIsGood: false) ?? 0.5
        if hrvScore >= rhrScore {
            return ("Best signal", readout.hrv.deltaText, .cyan, "waveform.path.ecg")
        }
        return ("Best signal", readout.restingHR.deltaText, .pink, "heart.text.square")
    }

    private var pressureSignal: (title: String, value: String, tint: Color, symbol: String) {
        if readout.loadPressure >= 0.62 {
            return ("Pressure", "Load", Metrics.electricStrain, "bolt.fill")
        }
        if readout.recoveryReserve < 0.48 {
            return ("Pressure", "Recovery", .cyan, "shield.lefthalf.filled")
        }
        return ("Pressure", "Low", .secondary, "checkmark.seal")
    }

    private var nextStep: (title: String, value: String, tint: Color, symbol: String) {
        switch readout.balanceCue {
        case "Ready":
            return ("Next", "Build", Metrics.electricGreen, "arrow.up.forward")
        case "Protect":
            return ("Next", "Recover", .cyan, "moon.zzz.fill")
        case "Unload":
            return ("Next", "Ease", Metrics.electricStrain, "arrow.down.forward")
        default:
            return ("Next", "Hold", readout.tint, "equal.circle")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Label("Range report", systemImage: "chart.xyaxis.line")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(readout.tint)
                Spacer(minLength: 8)
                Text(readout.rangeLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                reportTile(strongestSignal)
                reportTile(pressureSignal)
                reportTile(nextStep)
            }

            // Reserve/Load bars removed (dedup audit 2026-07-07): the
            // balance map below is the single owner of that pair.
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 20, tint: readout.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trend range report. Best signal \(strongestSignal.value). Pressure \(pressureSignal.value). Next \(nextStep.value).")
    }

    private func reportTile(_ item: (title: String, value: String, tint: Color, symbol: String)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: item.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(item.tint)
                .frame(width: 22, height: 22)
                .background(item.tint.opacity(0.12), in: Circle())
            Text(item.title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.value)
                .font(.caption.weight(.black).monospacedDigit())
                .foregroundStyle(item.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(item.tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(item.tint.opacity(0.12), lineWidth: 1)
        }
    }

    private func reportBar(label: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.11))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.76))
                        .frame(width: max(8, width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 7)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AtriaTrendPeriodLens: View, Equatable {
    let readout: AtriaTrendPeriodReadout

    var body: some View {
        HStack(spacing: 8) {
            lensChip(title: "Period",
                     value: readout.rangeLabel,
                     systemImage: "calendar",
                     tint: readout.tint)
            lensChip(title: "Cue",
                     value: readout.balanceCue,
                     systemImage: "scope",
                     tint: readout.tint)
            lensChip(title: "Compare",
                     value: readout.hasPriorSignal ? "Prior" : "Building",
                     systemImage: "arrow.left.arrow.right",
                     tint: readout.hasPriorSignal ? .cyan : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trend period lens. \(readout.rangeLabel). Cue \(readout.balanceCue). Prior comparison \(readout.hasPriorSignal ? "ready" : "building").")
    }

    private func lensChip(title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.11), lineWidth: 1)
        }
    }
}

private struct AtriaTrendPeriodHeroCard: View, Equatable {
    let readout: AtriaTrendPeriodReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(readout.tint.opacity(0.15))
                    Image(systemName: heroSymbol)
                        .font(.title3.weight(.black))
                        .foregroundStyle(readout.tint)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(readout.title)
                        .font(.headline.weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(readout.rangeLabel)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(heroCue)
                    .font(.caption.weight(.black))
                    .foregroundStyle(readout.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(readout.tint.opacity(0.13), in: Capsule(style: .continuous))
            }

            trendCueRail

            HStack(spacing: 8) {
                periodGauge(label: "HRV", delta: readout.hrv, tint: .cyan)
                periodGauge(label: "RHR", delta: readout.restingHR, tint: .pink)
                periodGauge(label: "Strain", delta: readout.strain, tint: Metrics.electricStrain)
            }
        }
        .padding(13)
        .atriaInsetCard(cornerRadius: 22, tint: readout.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Period report. \(readout.title). \(heroCue). Reserve \(Int((readout.recoveryReserve * 100).rounded())) percent. Load \(Int((readout.loadPressure * 100).rounded())) percent. HRV \(readout.hrv.currentText), resting heart rate \(readout.restingHR.currentText), strain \(readout.strain.currentText).")
    }

    private var heroSymbol: String {
        if readout.title.hasPrefix("Strain") { return "bolt.heart.fill" }
        if readout.title.hasPrefix("Recovery needs care") { return "waveform.path.ecg.rectangle" }
        return "scope"
    }

    private var heroCue: String {
        if readout.title.hasPrefix("Strain") { return "Recover" }
        if readout.title.hasPrefix("Recovery needs care") { return "Protect" }
        if readout.title.hasPrefix("Recovery-led") { return "Ready" }
        return "Steady"
    }

    private var trendCueRail: some View {
        HStack(spacing: 8) {
            cuePill(title: "Cue",
                    value: heroCue,
                    systemImage: heroSymbol,
                    tint: readout.tint)
            cuePill(title: "Reserve",
                    value: "\(Int((readout.recoveryReserve * 100).rounded()))",
                    systemImage: "battery.75percent",
                    tint: .cyan)
            cuePill(title: "Load",
                    value: "\(Int((readout.loadPressure * 100).rounded()))",
                    systemImage: "bolt.fill",
                    tint: Metrics.electricStrain)
        }
        .accessibilityHidden(true)
    }

    private func cuePill(title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func periodGauge(label: String,
                             delta: AtriaTrendPeriodDelta,
                             tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: deltaArrowSymbol(delta))
                    .font(.caption2.weight(.black))
                    .foregroundStyle(tint)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.secondary.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(.secondary.opacity(delta.previous == nil ? 0.08 : 0.22))
                        .frame(width: max(7, width * delta.previousProgress))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(delta.current == nil ? 0.18 : 0.82))
                        .frame(width: max(8, width * delta.currentProgress))
                }
            }
            .frame(height: 9)
            .accessibilityHidden(true)

            Text(delta.currentText)
                .font(.caption.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func deltaArrowSymbol(_ delta: AtriaTrendPeriodDelta) -> String {
        switch delta.directionText {
        case "up": return "arrow.up"
        case "down": return "arrow.down"
        case "flat": return "arrow.right"
        default: return "ellipsis"
        }
    }
}

private struct AtriaTrendRangeDock: View, Equatable {
    @Binding var selectedRange: AtriaTrendRange
    let coverage: [AtriaTrendRange: Int]
    let tint: Color

    // Perf (docs/26 follow-up): custom Equatable + `.equatable()` at the call
    // site lets SwiftUI skip this 7-node GeometryReader dock during scrub/anim
    // frames when its inputs are unchanged. The @Binding closure is excluded
    // from equality (its source is stable parent @State); the sibling
    // value-input subviews already get this via automatic structural comparison,
    // which a @Binding defeats — hence the explicit conformance here.
    static func == (lhs: AtriaTrendRangeDock, rhs: AtriaTrendRangeDock) -> Bool {
        lhs.selectedRange == rhs.selectedRange &&
        lhs.coverage == rhs.coverage &&
        lhs.tint == rhs.tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Ranges", systemImage: "calendar.badge.clock")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(selectedReadinessText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                ForEach(AtriaTrendRange.allCases) { range in
                    Button {
                        withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                            selectedRange = range
                        }
                    } label: {
                        rangeNode(for: range)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(range.menuLabel) trend range, \(rangeStatusText(for: range))")
                }
            }
        }
        .padding(9)
        .atriaInsetCard(cornerRadius: 18, tint: tint)
        .accessibilityElement(children: .contain)
    }

    private var selectedReadinessText: String {
        rangeStatusText(for: selectedRange)
    }

    private func rangeNode(for range: AtriaTrendRange) -> some View {
        let count = coverage[range, default: 0]
        let progress = confidenceProgress(for: range)
        let selected = selectedRange == range
        return VStack(spacing: 6) {
            Text(range.segmentedLabel)
                .font(.caption2.weight(.black))
                .foregroundStyle(selected ? tint : .secondary)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    Capsule(style: .continuous)
                        .fill((selected ? tint : Color.secondary).opacity(selected ? 0.82 : 0.30))
                        .frame(width: max(8, width * progress))
                }
            }
            .frame(height: selected ? 9 : 7)

            Text(countText(count))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(selected ? tint : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .background((selected ? tint : Color.secondary).opacity(selected ? 0.11 : 0.045),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func confidenceProgress(for range: AtriaTrendRange) -> CGFloat {
        let count = coverage[range, default: 0]
        guard count > 0 else { return 0.12 }
        return CGFloat(min(Double(count) / Double(range.confidenceTargetPoints), 1))
    }

    private func rangeStatusText(for range: AtriaTrendRange) -> String {
        let count = coverage[range, default: 0]
        if count >= range.confidenceTargetPoints { return "\(count) days in view" }
        if count >= max(2, range.confidenceTargetPoints / 2) { return "\(count) days forming" }
        return count == 1 ? "1 day started" : "\(count) days started"
    }

    private func countText(_ count: Int) -> String {
        count > 0 ? "\(count)d" : "0d"
    }
}

private struct AtriaTrendPeriodDelta: Equatable {
    let current: Double?
    let previous: Double?
    let metric: AtriaTrendMetric

    static func empty(metric: AtriaTrendMetric) -> AtriaTrendPeriodDelta {
        AtriaTrendPeriodDelta(current: nil, previous: nil, metric: metric)
    }

    var hasPrevious: Bool { previous != nil }

    var deltaValue: Double? {
        guard let current, let previous else { return nil }
        return current - previous
    }

    var currentText: String {
        guard let current else { return "Building" }
        switch metric {
        case .hrv: return AtriaMetricFormat.hrv(current)
        case .restingHR: return AtriaMetricFormat.restingHeartRate(current)
        case .strain: return AtriaMetricFormat.strain(current)
        }
    }

    var deltaText: String {
        guard let deltaValue else { return "prior pending" }
        return metric.changeText(deltaValue)
    }

    var directionText: String {
        guard let deltaValue else { return "learning" }
        if abs(deltaValue) < 0.5 { return "flat" }
        return deltaValue > 0 ? "up" : "down"
    }

    func directionScore(positiveDeltaIsGood: Bool) -> Double? {
        guard let deltaValue else { return current == nil ? nil : 0.5 }
        let scale: Double
        switch metric {
        case .hrv: scale = 10
        case .restingHR: scale = 6
        case .strain: scale = 4
        }
        let normalized = min(abs(deltaValue) / scale, 1)
        if abs(deltaValue) < 0.5 { return 0.5 }
        let improving = positiveDeltaIsGood ? deltaValue > 0 : deltaValue < 0
        return improving ? 0.5 + (normalized * 0.5) : 0.5 - (normalized * 0.5)
    }

    var currentProgress: Double {
        progress(for: current)
    }

    var previousProgress: Double {
        progress(for: previous)
    }

    private func progress(for value: Double?) -> Double {
        guard let value else { return 0.08 }
        let scale = max(current ?? 0, previous ?? 0, metric.periodComparisonFloor)
        return min(max(value / scale, 0.08), 1)
    }
}

private struct AtriaTrendPeriodReadoutCard: View {
    let readout: AtriaTrendPeriodReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(readout.tint.opacity(0.14))
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(readout.tint)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(readout.title)
                        .font(.headline.weight(.semibold))
                    Text(readout.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
            }

            AtriaTrendPeriodComparisonStrip(readout: readout)

            HStack(spacing: 8) {
                deltaChip(label: "HRV", delta: readout.hrv, tint: .cyan)
                deltaChip(label: "RHR", delta: readout.restingHR, tint: .pink)
                deltaChip(label: "Strain", delta: readout.strain, tint: Metrics.electricStrain)
            }
        }
        .padding(14)
        .background(readout.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(readout.tint.opacity(0.13), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(readout.title). \(readout.subtitle) HRV \(readout.hrv.currentText), \(readout.hrv.deltaText). Resting heart rate \(readout.restingHR.currentText), \(readout.restingHR.deltaText). Strain \(readout.strain.currentText), \(readout.strain.deltaText).")
    }

    private func deltaChip(label: String,
                           delta: AtriaTrendPeriodDelta,
                           tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(delta.currentText)
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(delta.deltaText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("\(label), \(delta.currentText), \(delta.directionText), \(delta.deltaText)")
    }
}

private struct AtriaTrendPeriodComparisonStrip: View, Equatable {
    let readout: AtriaTrendPeriodReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Now vs prior", systemImage: "rectangle.split.3x1")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(readout.rangeLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(readout.tint)
            }

            comparisonRow(label: "HRV", delta: readout.hrv, tint: .cyan)
            comparisonRow(label: "RHR", delta: readout.restingHR, tint: .pink)
            comparisonRow(label: "Strain", delta: readout.strain, tint: Metrics.electricStrain)
        }
        .padding(10)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now versus prior \(readout.rangeLabel). HRV \(readout.hrv.currentText), \(readout.hrv.deltaText). Resting heart rate \(readout.restingHR.currentText), \(readout.restingHR.deltaText). Strain \(readout.strain.currentText), \(readout.strain.deltaText).")
    }

    private func comparisonRow(label: String,
                               delta: AtriaTrendPeriodDelta,
                               tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let currentWidth = max(6, width * delta.currentProgress)
                let priorWidth = max(4, width * delta.previousProgress)
                VStack(alignment: .leading, spacing: 3) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(delta.current == nil ? 0.10 : 0.70))
                        .frame(width: currentWidth, height: 6)
                    Capsule(style: .continuous)
                        .fill(.secondary.opacity(delta.previous == nil ? 0.08 : 0.24))
                        .frame(width: priorWidth, height: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 13)

            Text(delta.deltaText)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 72, alignment: .trailing)
        }
    }
}

private struct AtriaTrendRangeSummary: Equatable {
    let latestText: String
    let averageText: String
    let rangeText: String
    let changeText: String
    let priorAverageText: String?
    let comparisonAccessibilityText: String

    init?(series: [AtriaTrendPoint.Sample], previousSeries: [AtriaTrendPoint.Sample], metric: AtriaTrendMetric) {
        guard let latest = series.last else { return nil }
        let values = series.map(\.value)
        guard let low = values.min(), let high = values.max() else { return nil }
        let average = values.reduce(0, +) / Double(max(values.count, 1))
        let change = latest.value - (series.first?.value ?? latest.value)
        let previousValues = previousSeries.map(\.value)
        self.latestText = metric.format(latest.value)
        self.averageText = metric.format(average)
        self.rangeText = metric.rangeText(low: low, high: high)
        self.changeText = metric.changeText(change)
        if !previousValues.isEmpty {
            let previousAverage = previousValues.reduce(0, +) / Double(previousValues.count)
            let priorAverageText = metric.changeText(average - previousAverage)
            self.priorAverageText = priorAverageText
            self.comparisonAccessibilityText = "prior change \(priorAverageText)"
        } else {
            self.priorAverageText = nil
            self.comparisonAccessibilityText = "change \(changeText)"
        }
    }
}

private struct AtriaTrendRangeAssessment: Equatable {
    let title: String
    let averageText: String
    let movementText: String
    let consistencyText: String
    let averageProgress: Double
    let movementProgress: Double
    let consistencyProgress: Double
    let tint: Color
    let symbol: String
    let accessibilityText: String

    init?(series: [AtriaTrendPoint.Sample], previousSeries: [AtriaTrendPoint.Sample], metric: AtriaTrendMetric, range: AtriaTrendRange) {
        guard series.count >= 3,
              let first = series.first,
              let latest = series.last else { return nil }
        let values = series.map(\.value)
        let average = values.reduce(0, +) / Double(values.count)
        let previousAverage = Self.average(previousSeries.map(\.value))
        let movement = previousAverage.map { average - $0 } ?? (latest.value - first.value)
        let spread = Self.standardDeviation(values, average: average)
        let consistency = Self.consistencyScore(spread: spread, average: average, metric: metric)

        self.tint = metric.tint
        self.symbol = metric.actionSymbol
        self.averageText = metric.format(average)
        self.movementText = metric.changeText(movement)
        self.consistencyText = consistency.label
        self.averageProgress = Self.averageProgress(average, metric: metric)
        self.movementProgress = Self.movementProgress(movement, metric: metric)
        self.consistencyProgress = consistency.score
        self.title = "\(range.menuLabel) assessment"
        self.accessibilityText = "\(title). Average \(averageText), change \(movementText), consistency \(consistencyText)."
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double], average: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let variance = values.reduce(0) { partial, value in
            let delta = value - average
            return partial + delta * delta
        } / Double(values.count)
        return sqrt(variance)
    }

    private static func consistencyScore(spread: Double, average: Double, metric: AtriaTrendMetric) -> (label: String, score: Double) {
        let normalized: Double
        switch metric {
        case .restingHR:
            normalized = 1 - min(spread / 8, 1)
        case .strain:
            normalized = 1 - min(spread / 5, 1)
        case .hrv:
            normalized = 1 - min(spread / max(average * 0.35, 8), 1)
        }
        let score = min(max(normalized, 0.12), 1)
        let label: String
        switch score {
        case 0.72...:
            label = "steady"
        case 0.42..<0.72:
            label = "mixed"
        default:
            label = "variable"
        }
        return (label, score)
    }

    private static func averageProgress(_ average: Double, metric: AtriaTrendMetric) -> Double {
        switch metric {
        case .restingHR:
            return min(max((average - 45) / 45, 0.08), 1)
        case .strain:
            return min(max(average / 21, 0.08), 1)
        case .hrv:
            return min(max(average / 120, 0.08), 1)
        }
    }

    private static func movementProgress(_ movement: Double, metric: AtriaTrendMetric) -> Double {
        let scale: Double
        switch metric {
        case .restingHR: scale = 8
        case .strain: scale = 5
        case .hrv: scale = 20
        }
        return min(max(abs(movement) / scale, 0.08), 1)
    }
}

private struct AtriaTrendRangeLens: View, Equatable {
    let range: AtriaTrendRange
    let metric: AtriaTrendMetric
    let summary: AtriaTrendRangeSummary?
    let sampleCount: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(metric.tint.opacity(0.14), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: coverageProgress)
                    .stroke(metric.tint.opacity(0.82),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(range.segmentedLabel)
                    .font(.caption.weight(.black).monospacedDigit())
                    .foregroundStyle(metric.tint)
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(range.menuLabel)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)

                    Text(coverageLabel)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.08), in: Capsule(style: .continuous))

                    Spacer(minLength: 4)
                }

                GeometryReader { proxy in
                    let width = max(proxy.size.width, 1)
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(metric.tint.opacity(0.12))
                        Capsule(style: .continuous)
                            .fill(metric.tint.opacity(0.78))
                            .frame(width: max(10, width * coverageProgress))
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
            }

            Spacer(minLength: 6)
            // Latest-number block removed (dedup audit 2026-07-07): the
            // chart's end annotation and the position band own "latest";
            // this lens keeps its coverage role only.
        }
        .padding(12)
        .background(metric.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(metric.tint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trend period rail. \(range.menuLabel), \(coverageLabel), latest \(metric.shortLabel) \(summary?.latestText ?? "not ready").")
    }

    private var coverageProgress: Double {
        min(max(Double(sampleCount) / Double(range.confidenceTargetPoints), 0.08), 1)
    }

    private var coverageLabel: String {
        // "in view" implied visible calendar days; the count is data samples
        // (2026-07-31 audit item 13).
        if sampleCount >= range.confidenceTargetPoints {
            return "\(sampleCount)d of data"
        }
        if sampleCount >= max(2, range.confidenceTargetPoints / 2) {
            return "\(sampleCount)d forming"
        }
        return sampleCount == 1 ? "1d started" : "\(sampleCount)d started"
    }
}

private struct AtriaTrendRangeAssessmentCard: View, Equatable {
    let assessment: AtriaTrendRangeAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: assessment.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(assessment.tint)
                    .frame(width: 26, height: 26)
                    .background(assessment.tint.opacity(0.12), in: Circle())

                Text(assessment.title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(assessment.consistencyText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(assessment.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(assessment.tint.opacity(0.12), in: Capsule(style: .continuous))
            }

            HStack(spacing: 8) {
                assessmentBar(label: "Avg",
                              value: assessment.averageText,
                              progress: assessment.averageProgress)
                assessmentBar(label: "Change",
                              value: assessment.movementText,
                              progress: assessment.movementProgress)
                assessmentBar(label: "Rhythm",
                              value: assessment.consistencyText,
                              progress: assessment.consistencyProgress)
            }
        }
        .padding(12)
        .background(assessment.tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(assessment.tint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(assessment.accessibilityText)
    }

    private func assessmentBar(label: String, value: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(assessment.tint.opacity(0.12))
                    Capsule(style: .continuous)
                        .fill(assessment.tint.opacity(0.72))
                        .frame(width: max(8, width * min(max(progress, 0), 1)))
                }
            }
            .frame(height: 7)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AtriaTrendActionReadout: Equatable {
    let headline: String
    let detail: String
    let symbol: String
    let tint: Color
    let direction: Direction

    enum Direction: Equatable {
        case up
        case down
        case steady

        var symbol: String {
            switch self {
            case .up: return "arrow.up.right"
            case .down: return "arrow.down.right"
            case .steady: return "arrow.right"
            }
        }
    }

    init?(series: [AtriaTrendPoint.Sample], previousSeries: [AtriaTrendPoint.Sample], metric: AtriaTrendMetric) {
        guard let first = series.first, let latest = series.last else { return nil }
        guard let currentAverage = Self.average(series.map(\.value)) else { return nil }
        let previousAverage = Self.average(previousSeries.map(\.value))
        let movement = previousAverage.map { currentAverage - $0 } ?? (latest.value - first.value)
        var resolvedDirection = Self.direction(for: movement, metric: metric)

        self.tint = metric.tint
        self.symbol = metric.actionSymbol

        switch metric {
        case .hrv:
            switch resolvedDirection {
            case .up:
                headline = "HRV lifting"
                detail = "Recovery signal is improving. Keep the sleep routine boring."
            case .down:
                headline = "HRV dipping"
                detail = "Ease strain and protect tonight's sleep window."
            case .steady:
                headline = "HRV steady"
                detail = "No major swing. Let the plan card drive today."
            }
        case .restingHR:
            switch resolvedDirection {
            case .down:
                headline = "RHR easing"
                detail = "Lower resting load is a good sign. Build gradually."
            case .up:
                headline = "RHR elevated"
                detail = "Treat it as load pressure. Avoid stacking hard days."
            case .steady:
                headline = "RHR steady"
                detail = "Stable base. Watch HRV and sleep before pushing."
            }
        case .strain:
            if currentAverage >= 14 {
                headline = "High-load range"
                detail = "Good work, but recovery needs space before more intensity."
                resolvedDirection = .up
            } else if currentAverage >= 10 {
                headline = "Moderate load"
                detail = "Training is moving. Hold unless recovery says push."
            } else {
                headline = resolvedDirection == .up ? "Load building" : "Light-load range"
                detail = resolvedDirection == .up
                    ? "Strain is rising. Keep the next jump deliberate."
                    : "Plenty of room if recovery is ready."
            }
        }
        self.direction = resolvedDirection
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func direction(for movement: Double, metric: AtriaTrendMetric) -> Direction {
        switch metric {
        case .hrv:
            guard abs(movement) >= 3 else { return .steady }
            return movement > 0 ? .up : .down
        case .restingHR:
            guard abs(movement) >= 2 else { return .steady }
            return movement > 0 ? .up : .down
        case .strain:
            guard abs(movement) >= 0.8 else { return .steady }
            return movement > 0 ? .up : .down
        }
    }
}

private struct AtriaTrendPreparedSeries {
    let series: [AtriaTrendPoint.Sample]
    /// Prior equal-length window, time-shifted forward onto the current
    /// window's x-axis so it can be drawn as a dashed ghost line. Empty when
    /// there is no prior period (`.all`) or no prior samples exist.
    let previousSeries: [AtriaTrendPoint.Sample]
    let referenceValue: Double?
    let summary: AtriaTrendRangeSummary?
    let assessment: AtriaTrendRangeAssessment?
    let action: AtriaTrendActionReadout?
    let yDomain: ClosedRange<Double>

    static let empty = AtriaTrendPreparedSeries(series: [],
                                                previousSeries: [],
                                                referenceValue: nil,
                                                summary: nil,
                                                assessment: nil,
                                                action: nil,
                                                yDomain: 0...1)
}

private struct AtriaTrendActionReadoutCard: View {
    let action: AtriaTrendActionReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(action.tint.opacity(0.14))
                    Image(systemName: action.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(action.tint)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(action.headline)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(action.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }

                Spacer(minLength: 6)

                Image(systemName: action.direction.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(action.tint)
                    .frame(width: 24, height: 24)
                    .background(action.tint.opacity(0.10), in: Circle())
            }
            actionRail
        }
        .padding(12)
        .background(action.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(action.tint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(action.headline). \(action.detail). Direction \(directionText), signal \(signalText), next \(nextText).")
    }

    private var actionRail: some View {
        HStack(spacing: 7) {
            actionChip(title: "Direction",
                       value: directionText,
                       systemImage: action.direction.symbol)
            actionChip(title: "Signal",
                       value: signalText,
                       systemImage: action.symbol)
            actionChip(title: "Next",
                       value: nextText,
                       systemImage: "figure.walk.motion")
        }
        .accessibilityHidden(true)
    }

    private var directionText: String {
        switch action.direction {
        case .up: return "Rising"
        case .down: return "Dropping"
        case .steady: return "Steady"
        }
    }

    private var signalText: String {
        if action.headline.localizedCaseInsensitiveContains("high-load")
            || action.headline.localizedCaseInsensitiveContains("elevated")
            || action.headline.localizedCaseInsensitiveContains("dipping") {
            return "Pressure"
        }
        if action.headline.localizedCaseInsensitiveContains("lifting")
            || action.headline.localizedCaseInsensitiveContains("easing") {
            return "Support"
        }
        return "Stable"
    }

    private var nextText: String {
        switch signalText {
        case "Pressure": return "Ease"
        case "Support": return "Build"
        default: return "Hold"
        }
    }

    private func actionChip(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(action.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(action.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct AtriaTrendRangeSummaryStrip: View {
    let summary: AtriaTrendRangeSummary
    let tint: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)],
                  spacing: 8) {
            // Latest + Range pills removed (dedup audit 2026-07-07): the
            // position band below states both with position context.
            summaryPill(label: "Avg", value: summary.averageText)
            if let priorAverageText = summary.priorAverageText {
                summaryPill(label: "Prior", value: priorAverageText)
            } else {
                summaryPill(label: "Change", value: summary.changeText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trend summary. Average \(summary.averageText), \(summary.comparisonAccessibilityText).")
    }

    private func summaryPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.64)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct AtriaTrendRangePositionBand: View, Equatable {
    let series: [AtriaTrendPoint.Sample]
    let metric: AtriaTrendMetric

    private struct RangeStats {
        let low: Double?
        let high: Double?
        let latest: Double?
        let latestPosition: Double
    }

    private static func rangeStats(for series: [AtriaTrendPoint.Sample]) -> RangeStats {
        let values = series.map(\.value)
        let low = values.min()
        let high = values.max()
        let latest = series.last?.value
        let latestPosition: Double
        if let low, let high, let latest, high > low {
            latestPosition = min(max((latest - low) / (high - low), 0), 1)
        } else {
            latestPosition = 0.5
        }
        return RangeStats(low: low,
                          high: high,
                          latest: latest,
                          latestPosition: latestPosition)
    }

    private func positionText(for latestPosition: Double) -> String {
        switch latestPosition {
        case ..<0.34:
            return metric.lowPositionText
        case ..<0.67:
            return "middle of range"
        default:
            return metric.highPositionText
        }
    }

    var body: some View {
        let stats = Self.rangeStats(for: series)
        let positionText = positionText(for: stats.latestPosition)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Current position")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(positionText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(metric.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.primary.opacity(0.08))
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(colors: [metric.tint.opacity(0.22),
                                                    metric.tint.opacity(0.78)],
                                           startPoint: .leading,
                                           endPoint: .trailing)
                        )
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: metric.tint.opacity(0.32), radius: 5, x: 0, y: 0)
                        .offset(x: min(max(width * stats.latestPosition - 7, 0), max(width - 14, 0)))
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)

            HStack {
                bandLabel("Low", value: stats.low)
                Spacer(minLength: 8)
                bandLabel("Now", value: stats.latest)
                Spacer(minLength: 8)
                bandLabel("High", value: stats.high)
            }
        }
        .padding(12)
        .background(metric.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(metric.tint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current position. Latest \(stats.latest.map(metric.format) ?? "not ready"), low \(stats.low.map(metric.format) ?? "not ready"), high \(stats.high.map(metric.format) ?? "not ready"), \(positionText).")
    }

    private func bandLabel(_ label: String, value: Double?) -> some View {
        VStack(alignment: label == "High" ? .trailing : .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value.map(metric.format) ?? "--")
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct AtriaTrendSessionDotStrip: View, Equatable {
    let series: [AtriaTrendPoint.Sample]
    let metric: AtriaTrendMetric

    private var visibleSamples: [AtriaTrendPoint.Sample] {
        Array(series.suffix(28))
    }

    private static func domain(for samples: [AtriaTrendPoint.Sample]) -> ClosedRange<Double> {
        let values = samples.map(\.value)
        guard let low = values.min(), let high = values.max(), high > low else {
            return 0...1
        }
        return low...high
    }

    var body: some View {
        let samples = visibleSamples
        let domain = Self.domain(for: samples)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Day pattern")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(samples.count)d of data")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(samples) { sample in
                    let normalized = Self.normalized(sample.value, domain: domain)
                    Capsule(style: .continuous)
                        .fill(metric.tint.opacity(Self.opacity(for: normalized)))
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.height(for: normalized))
                        .accessibilityLabel("\(metric.shortLabel) \(metric.format(sample.value))")
                }
            }
            .frame(height: 24, alignment: .bottom)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(metric.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(metric.tint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Day pattern for \(metric.shortLabel), \(samples.count) days of data.")
    }

    private static func normalized(_ value: Double, domain: ClosedRange<Double>) -> Double {
        let span = max(domain.upperBound - domain.lowerBound, 0.01)
        return min(max((value - domain.lowerBound) / span, 0), 1)
    }

    private static func height(for normalized: Double) -> CGFloat {
        6 + CGFloat(normalized) * 18
    }

    private static func opacity(for normalized: Double) -> Double {
        0.22 + normalized * 0.66
    }
}

enum AtriaTrendChartScale {
    static func domain(values: [Double], paddingRatio: Double = 0.16) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        return domain(low: low, high: high, paddingRatio: paddingRatio)
    }

    static func domain(low: Double, high: Double, paddingRatio: Double = 0.16) -> ClosedRange<Double> {
        let span = max(high - low, max(abs(high), 1) * 0.08)
        let padding = max(span * paddingRatio, 0.5)
        return (low - padding)...(high + padding)
    }
}

/// Renders cached trend points from the store. Session filtering, sorting, and
/// TRIMP work stay out of SwiftUI render paths.
struct AtriaOverviewTrendChartHost: View {
    let store: SessionStore
    @StateObject private var projectionStore: AtriaTrendChartProjectionStore

    init(store: SessionStore) {
        self.store = store
        _projectionStore = StateObject(wrappedValue: AtriaTrendChartProjectionStore(store: store))
    }

    var body: some View {
        let fixturePoints = debugFixtureTrendPoints
        let projection = projectionStore.state
        AtriaTrendChartCard(points: fixturePoints ?? projection.points,
                            pointsRevision: fixturePoints == nil ? projection.pointsRevision : nil,
                            baselineRestingHR: fixturePoints == nil ? projection.baselineRestingHR : 58,
                            events: projection.events)
    }

    #if DEBUG
    static var debugShowsTrendFixture: Bool {
        debugFixtureTrendPoints(arguments: ProcessInfo.processInfo.arguments) != nil
    }

    private var debugFixtureTrendPoints: [AtriaTrendPoint]? {
        Self.debugFixtureTrendPoints(arguments: ProcessInfo.processInfo.arguments)
    }

    private static func debugFixtureTrendPoints(arguments: [String]) -> [AtriaTrendPoint]? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        switch arguments[valueIndex] {
        case "trend-prior-comparison":
            return AtriaTrendPoint.priorComparisonSampleData(now: Date())
        case "trend-recovery-care":
            return AtriaTrendPoint.recoveryCareSampleData(now: Date())
        default:
            return nil
        }
    }
    #else
    static var debugShowsTrendFixture: Bool { false }
    private var debugFixtureTrendPoints: [AtriaTrendPoint]? { nil }
    #endif
}

struct AtriaTrendChartProjectionState: Equatable {
    let points: [AtriaTrendPoint]
    let pointsRevision: Int
    let baselineRestingHR: Int?
    let events: [AtriaChartEvent]
}

@MainActor
final class AtriaTrendChartProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaTrendChartProjectionState

    private weak var store: SessionStore?
    private var confirmedWorkoutsRevision: Int
    private var sleepHistoryRevision: Int
    private var cachedEvents: [AtriaChartEvent]
    private var cancellables = Set<AnyCancellable>()

    init(store: SessionStore) {
        self.store = store
        confirmedWorkoutsRevision = store.confirmedWorkoutsRevision
        sleepHistoryRevision = store.sleepHistorySnapshotRevision
        cachedEvents = Self.makeEvents(store: store)
        state = AtriaTrendChartProjectionState(points: store.overviewTrendPoints,
                                               pointsRevision: store.overviewTrendPointsRevision,
                                               baselineRestingHR: store.baseline.restingInt,
                                               events: cachedEvents)
        bind(to: store)
    }

    init(state: AtriaTrendChartProjectionState) {
        self.state = state
        confirmedWorkoutsRevision = 0
        sleepHistoryRevision = 0
        cachedEvents = state.events
    }

    @discardableResult
    func refresh(_ next: AtriaTrendChartProjectionState) -> Bool {
        guard next != state else { return false }
        state = next
        return true
    }

    private func bind(to store: SessionStore) {
        Publishers.Merge3(
            store.$overviewTrendPoints.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$baseline.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$sleepHistorySnapshot.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in self?.refreshFromStore() }
        .store(in: &cancellables)

        store.$dashboardRevision
            .dropFirst()
            .sink { [weak self, weak store] _ in
                guard let self, let store,
                      store.confirmedWorkoutsRevision != self.confirmedWorkoutsRevision else { return }
                self.refreshFromStore()
            }
            .store(in: &cancellables)
    }

    private func refreshFromStore() {
        guard let store else { return }
        let nextWorkoutRevision = store.confirmedWorkoutsRevision
        let nextSleepRevision = store.sleepHistorySnapshotRevision
        if nextWorkoutRevision != confirmedWorkoutsRevision || nextSleepRevision != sleepHistoryRevision {
            confirmedWorkoutsRevision = nextWorkoutRevision
            sleepHistoryRevision = nextSleepRevision
            cachedEvents = Self.makeEvents(store: store)
        }
        refresh(AtriaTrendChartProjectionState(points: store.overviewTrendPoints,
                                               pointsRevision: store.overviewTrendPointsRevision,
                                               baselineRestingHR: store.baseline.restingInt,
                                               events: cachedEvents))
    }

    private static func makeEvents(store: SessionStore) -> [AtriaChartEvent] {
        var events = store.confirmedWorkouts.map { workout in
            AtriaChartEvent(id: "workout-\(workout.id)",
                            day: workout.start,
                            label: workout.activitySubtype ?? workout.activityType ?? "Workout",
                            systemImage: "flame.fill",
                            tint: Metrics.electricStrain)
        }
        events.append(contentsOf: store.sleepHistorySnapshot.nights.filter(\.confirmed).map { night in
            AtriaChartEvent(id: "sleep-\(night.id)",
                            day: night.day,
                            label: "Sleep",
                            systemImage: "bed.double.fill",
                            tint: Metrics.electricSleep)
        })
        return events
    }
}

enum AtriaTrendRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case quarter
    case sixMonths
    case year
    case all

    var id: String { rawValue }

    /// Interactive selectors expose only Day/Week/Month — the daily/weekly/monthly
    /// model the app is built around. The deeper cases (quarter/sixMonths/year/all)
    /// stay in the enum and `allCases`: both per-range data-prep loops
    /// (AtriaTrendChart.swift + AtriaOverviewSections.swift) and the internal `.all`
    /// read still key off the full set — they are just not offered in the range bar
    /// (2026-07-08: declutter the range bar to D/W/M per user request; the range
    /// selector stays a segmented control, never a Menu, per the readability guard).
    static let primarySegments: [AtriaTrendRange] = [.day, .week, .month]

    /// The Trends card aggregates to one point per civil day, so `.day` can
    /// never form a line there (its chart requires ≥2 points). Day stays in
    /// `primarySegments` for the calendar-period metric-detail surfaces,
    /// where a single-day view is real and navigable (2026-07-31 audit).
    static let trendCardSegments: [AtriaTrendRange] = [.week, .month]

    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .sixMonths: return 180
        case .year: return 365
        case .all: return 100_000
        }
    }

    var label: String {
        switch self {
        case .day: return "today"
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "3 months"
        case .sixMonths: return "6 months"
        case .year: return "12 months"
        case .all: return "all history"
        }
    }

    var menuLabel: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .quarter: return "3M"
        case .sixMonths: return "6M"
        case .year: return "1Y"
        case .all: return "All"
        }
    }

    var segmentedLabel: String {
        switch self {
        case .day: return "D"
        case .week: return "W"
        case .month: return "M"
        case .quarter: return "3M"
        case .sixMonths: return "6M"
        case .year: return "1Y"
        case .all: return "All"
        }
    }

    var confidenceTargetPoints: Int {
        switch self {
        case .day: return 1
        case .week: return 4
        case .month: return 12
        case .quarter: return 24
        case .sixMonths: return 36
        case .year: return 48
        case .all: return 60
        }
    }

    var headerLabel: String {
        switch self {
        case .day: return "Today"
        case .all: return "All history"
        default: return "Last \(label)"
        }
    }

    var narrativeLabel: String {
        switch self {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .quarter: return "3 months"
        case .sixMonths: return "6 months"
        case .year: return "year"
        case .all: return "all history"
        }
    }

    /// Whether this range has a meaningful equal-length "prior period" to
    /// compare against. `.all` spans everything available, so there is no
    /// earlier window left to overlay or diff against.
    var hasPriorPeriod: Bool {
        switch self {
        case .all: return false
        default: return true
        }
    }

    func cutoffDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .day:
            return calendar.startOfDay(for: now)
        case .week, .month, .quarter, .sixMonths, .year:
            return calendar.startOfDay(for: now.addingTimeInterval(-Double(days) * 86_400))
        case .all:
            return .distantPast
        }
    }

    /// Calendar-aligned period used by metric detail navigation. This is
    /// deliberately separate from the legacy rolling `cutoffDate` contract:
    /// choosing Week or Month in a navigable sheet means an inspectable
    /// calendar week/month, not an unlabelled trailing number of seconds.
    func periodInterval(
        containing anchor: Date,
        calendar: Calendar = .current
    ) -> DateInterval {
        switch self {
        case .day:
            let start = calendar.startOfDay(for: anchor)
            return DateInterval(
                start: start,
                end: calendar.date(byAdding: .day, value: 1, to: start)
                    ?? start.addingTimeInterval(86_400)
            )
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: anchor)
                ?? DateInterval(
                    start: calendar.startOfDay(for: anchor),
                    duration: 7 * 86_400
                )
        case .month:
            return calendar.dateInterval(of: .month, for: anchor)
                ?? DateInterval(
                    start: calendar.startOfDay(for: anchor),
                    duration: 30 * 86_400
                )
        case .quarter, .sixMonths, .year, .all:
            let start = cutoffDate(now: anchor, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: 1,
                                    to: calendar.startOfDay(for: anchor))
                ?? anchor
            return DateInterval(start: start, end: end)
        }
    }

    func adjacentPeriodAnchor(
        from anchor: Date,
        offset: Int,
        calendar: Calendar = .current
    ) -> Date {
        let component: Calendar.Component
        switch self {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .quarter: component = .quarter
        case .sixMonths: component = .month
        case .year: component = .year
        case .all: return anchor
        }
        let amount = self == .sixMonths ? offset * 6 : offset
        return calendar.date(byAdding: component, value: amount, to: anchor)
            ?? anchor
    }

    func periodLabel(
        containing anchor: Date,
        calendar: Calendar = .current
    ) -> String {
        let interval = periodInterval(containing: anchor, calendar: calendar)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch self {
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
            return formatter.string(from: interval.start)
        case .week:
            let end = interval.end.addingTimeInterval(-1)
            let startMonth = calendar.component(.month, from: interval.start)
            let endMonth = calendar.component(.month, from: end)
            formatter.setLocalizedDateFormatFromTemplate(
                startMonth == endMonth ? "d" : "d MMM"
            )
            let startText = formatter.string(from: interval.start)
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
            return "\(startText)–\(formatter.string(from: end))"
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return formatter.string(from: interval.start)
        default:
            formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
            return formatter.string(from: interval.start)
        }
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
        case .strain: return Metrics.electricStrain
        case .hrv: return .cyan
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .restingHR: return AtriaMetricFormat.restingHeartRate(value)
        case .strain: return AtriaMetricFormat.strain(value)
        case .hrv: return AtriaMetricFormat.hrv(value)
        }
    }

    func rangeText(low: Double, high: Double) -> String {
        switch self {
        case .restingHR: return AtriaMetricFormat.range(low: low, high: high, metric: .restingHeartRate)
        case .strain: return AtriaMetricFormat.range(low: low, high: high, metric: .strain)
        case .hrv: return AtriaMetricFormat.range(low: low, high: high, metric: .hrv)
        }
    }

    func changeText(_ value: Double) -> String {
        switch self {
        case .restingHR: return AtriaMetricFormat.change(value, metric: .restingHeartRate)
        case .strain: return AtriaMetricFormat.change(value, metric: .strain)
        case .hrv: return AtriaMetricFormat.change(value, metric: .hrv)
        }
    }

    var actionSymbol: String {
        switch self {
        case .restingHR: return "heart"
        case .strain: return "bolt.fill"
        case .hrv: return "waveform.path.ecg"
        }
    }

    var lowPositionText: String {
        switch self {
        case .restingHR: return "easier side"
        case .strain: return "light side"
        case .hrv: return "low side"
        }
    }

    var highPositionText: String {
        switch self {
        case .restingHR: return "loaded side"
        case .strain: return "high side"
        case .hrv: return "high side"
        }
    }

    var periodComparisonFloor: Double {
        switch self {
        case .restingHR: return 90
        case .strain: return 21
        case .hrv: return 120
        }
    }

    /// Honest "how to read this trend" knowledge, shown in the expanded chart so
    /// tapping to expand delivers understanding, not just a bigger chart. Trend-and-
    /// baseline framing, never a single-day claim (matches Atria's honesty voice).
    var trendExplainer: String {
        switch self {
        case .restingHR:
            return "A lower resting heart rate over weeks usually means better cardiovascular fitness or good recovery. A sustained rise can flag fatigue, illness, or poor sleep. Read the trend against your own baseline — not any single day."
        case .strain:
            return "Strain is your daily cardiovascular load on a 0–21 scale, built from time spent in each heart-rate zone. Rising strain means harder days; healthy progress balances it with recovery rather than climbing every day."
        case .hrv:
            return "Higher heart-rate variability generally reflects better recovery and readiness. HRV is naturally noisy night to night, so the direction of the trend and your personal baseline matter far more than any single reading."
        }
    }
}

extension Array where Element == AtriaTrendPoint.Sample {
    /// Same contiguous day-run split as `[AtriaDetailChartPoint].contiguousDayRuns()`
    /// (AtriaStrainRecoveryComboChart): the run id increments whenever
    /// consecutive samples are more than a day apart; feed it to
    /// `LineMark(series:)` so a charted line BREAKS at day gaps instead of
    /// drawing a straight segment across days with no reading (2026-08-06
    /// audit fix).
    func contiguousDayRuns(calendar: Calendar = .current)
        -> [(runID: Int, sample: AtriaTrendPoint.Sample)] {
        let sorted = self.sorted { $0.date < $1.date }
        var out: [(Int, AtriaTrendPoint.Sample)] = []
        var run = 0
        var previous: Date?
        for sample in sorted {
            if let previous {
                let days = calendar.dateComponents([.day], from: previous, to: sample.date).day ?? 1
                if days > 1 { run += 1 }
            }
            out.append((run, sample))
            previous = sample.date
        }
        return out
    }
}

/// One day's trend-relevant values, prepared on the main-actor store side so
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

    struct Sample: Identifiable, Equatable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    #if DEBUG
    /// Deterministic sample series for previews and on-device visual checks.
    /// DEBUG-only: demo series must have a compile-time barrier from Release.
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
    /// Longer deterministic series for screenshotting current-vs-prior trend summaries.
    static func priorComparisonSampleData(now: Date) -> [AtriaTrendPoint] {
        (0..<70).map { index in
            let wave = sin(Double(index) * 0.55)
            let trainingWave = cos(Double(index) * 0.42)
            let recentLift = index >= 40 ? 1.15 : 0
            return AtriaTrendPoint(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1)) ?? UUID(),
                date: now.addingTimeInterval(Double(index - 69) * 86_400),
                restingHR: Int((63.0 - Double(index) * 0.055 + wave * 1.4).rounded()),
                strain: 8.8 + recentLift + trainingWave * 1.9 + Double(index % 5) * 0.18,
                hrv: Int((44.0 + Double(index) * 0.20 - wave * 2.6).rounded())
            )
        }
    }

    static func recoveryCareSampleData(now: Date) -> [AtriaTrendPoint] {
        (0..<70).map { index in
            let recent = index >= 40
            let wave = sin(Double(index) * 0.47)
            return AtriaTrendPoint(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", index + 1)) ?? UUID(),
                date: now.addingTimeInterval(Double(index - 69) * 86_400),
                restingHR: Int(((recent ? 61.0 : 56.0) + wave * 0.8).rounded()),
                strain: (recent ? 8.4 : 8.2) + cos(Double(index) * 0.35) * 0.35,
                hrv: Int(((recent ? 54.0 : 62.0) - wave * 1.1).rounded())
            )
        }
    }
    #endif
}

#if DEBUG
#Preview("Trend chart") {
    AtriaTrendChartCard(points: AtriaTrendPoint.sampleData(now: Date()),
                        pointsRevision: nil,
                        baselineRestingHR: 58)
        .padding()
        .background(Color.black)
}
#endif

extension AtriaTrendChartCard {
    /// Nearest prepared sample to the scrubbed x-position.
    var scrubbedSample: AtriaTrendPoint.Sample? {
        guard let scrubDate, !prepared.series.isEmpty else { return nil }
        return prepared.series.min {
            abs($0.date.timeIntervalSince(scrubDate)) < abs($1.date.timeIntervalSince(scrubDate))
        }
    }
}
