import Charts
import SwiftUI

/// One analyzed night: the per-minute input and the analyzer's result.
/// The view renders ONLY what `AtriaNightTimelineAnalyzer` returned — no
/// stages (deep/REM) are claimed, and nothing is interpolated.
struct AtriaNightTimelineModel: Equatable {
    let minutes: [AtriaNightTimelineAnalyzer.Minute]
    let result: AtriaNightTimelineAnalyzer.Result
    var timeZone: TimeZone = .current
    /// How much of the window had data (nil for synthetic fixtures).
    var coverage: AtriaNightMinuteBuilder.Coverage?
    /// The stored sleep this was built for; drawn when sleep can't be placed.
    var sleepWindow: DateInterval?

    init(minutes: [AtriaNightTimelineAnalyzer.Minute],
         lightsOff: Date? = nil,
         timeZone: TimeZone = .current,
         coverage: AtriaNightMinuteBuilder.Coverage? = nil,
         sleepWindow: DateInterval? = nil) {
        self.minutes = minutes
        self.result = AtriaNightTimelineAnalyzer.analyze(minutes, lightsOff: lightsOff)
        self.timeZone = timeZone
        self.coverage = coverage
        self.sleepWindow = sleepWindow
    }

    /// Why no timeline can be drawn, in one short line. nil when it can.
    var unavailableReason: String? {
        guard AtriaNightTimelinePresentation(self) == nil else { return nil }
        if let coverage {
            if coverage.heartRateMinutes == 0 && coverage.motionMinutes == 0 {
                return "No strap data for this night yet."
            }
            if coverage.hasNoMotion { return "No motion data for this night." }
        }
        return "Not enough still time to place sleep."
    }

    /// Motion covers under half the window: the timeline is drawn, flagged.
    var motionNote: String? {
        guard let coverage, coverage.motionIsPartial else { return nil }
        return "Motion missing for part of the night."
    }

    /// Stable identity for the night (used to key morning answers).
    var nightID: String {
        let anchor = result.onset ?? minutes.first?.start ?? .distantPast
        return "night-\(Int(anchor.timeIntervalSince1970))"
    }
}

/// Pure presentation of an analyzer result: plotted window, colored bands,
/// and at most three plain-language insight lines.
struct AtriaNightTimelinePresentation: Equatable {
    struct Band: Identifiable, Equatable {
        let kind: Lane
        let start: Date
        let end: Date
        var id: String { "\(kind.rawValue)-\(start.timeIntervalSince1970)" }
    }

    /// Episode lanes. `asleep` is the base between onset and wake; every
    /// analyzer episode draws on top of it.
    enum Lane: String, CaseIterable, Equatable {
        case asleep, settling, restless, up, notWorn, longestUndisturbed, awake

        init(_ kind: AtriaNightTimelineAnalyzer.Kind) {
            switch kind {
            case .settling: self = .settling
            case .restless: self = .restless
            case .up: self = .up
            case .notWorn: self = .notWorn
            case .longestUndisturbed: self = .longestUndisturbed
            case .awake: self = .awake
            }
        }

        var title: String {
            switch self {
            case .asleep: return "Asleep"
            case .settling: return "Settling"
            case .restless: return "Restless"
            case .up: return "Up"
            case .notWorn: return "Not worn"
            case .longestUndisturbed: return "Longest stretch"
            case .awake: return "Awake"
            }
        }

        var tint: Color {
            switch self {
            case .asleep: return Metrics.electricSleep.opacity(0.42)
            case .settling: return Color.secondary.opacity(0.28)
            case .restless: return Metrics.electricYellow
            case .up: return Metrics.electricStress
            case .notWorn: return Color.secondary.opacity(0.18)
            case .longestUndisturbed: return Metrics.electricSleep
            case .awake: return Color.secondary.opacity(0.28)
            }
        }

        /// Draw order: base first, then quiet context, then interruptions.
        var layer: Int {
            switch self {
            case .asleep: return 0
            case .settling, .awake, .longestUndisturbed: return 1
            case .notWorn, .restless: return 2
            case .up: return 3
            }
        }
    }

    let domain: ClosedRange<Date>
    let bands: [Band]
    let insights: [String]
    let legend: [Lane]

    /// How much of the post-wake tail is plotted; the rest of the morning is
    /// not part of the night.
    static let awakeTailLimit: TimeInterval = 30 * 60

    init?(_ model: AtriaNightTimelineModel) {
        let result = model.result
        guard let onset = result.onset, let wake = result.wake, wake > onset else { return nil }
        let settlingStart = result.episodes.first { $0.kind == .settling }?.start
        let lower = min(settlingStart ?? onset, onset)
        let upper = wake.addingTimeInterval(
            result.episodes.contains { $0.kind == .awake } ? Self.awakeTailLimit : 0)
        domain = lower...upper

        var bands = [Band(kind: .asleep, start: onset, end: wake)]
        for episode in result.episodes {
            let start = max(episode.start, lower)
            let end = min(episode.end, upper)
            guard end > start else { continue }
            bands.append(Band(kind: Lane(episode.kind), start: start, end: end))
        }
        self.bands = bands.sorted {
            $0.kind.layer == $1.kind.layer ? $0.start < $1.start : $0.kind.layer < $1.kind.layer
        }
        let present = Set(bands.map(\.kind))
        legend = Lane.allCases.filter { present.contains($0) }
        insights = Self.insights(result, timeZone: model.timeZone)
    }

    /// At most three lines, each derived only from the analyzer result:
    /// 1. onset and wake, 2. the main interruption, 3. the longest stretch.
    static func insights(_ result: AtriaNightTimelineAnalyzer.Result,
                         timeZone: TimeZone,
                         locale: Locale = .current) -> [String] {
        guard let onset = result.onset, let wake = result.wake else { return [] }
        let clock = clockFormatter(timeZone, locale: locale)
        func span(_ e: AtriaNightTimelineAnalyzer.Episode) -> String {
            "\(clock.string(from: e.start))–\(clock.string(from: e.end))"
        }
        func longest(_ kind: AtriaNightTimelineAnalyzer.Kind) -> AtriaNightTimelineAnalyzer.Episode? {
            result.episodes
                .filter { $0.kind == kind && $0.start >= onset && $0.end <= wake }
                .max { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) }
        }
        func count(_ kind: AtriaNightTimelineAnalyzer.Kind) -> Int {
            result.episodes.filter { $0.kind == kind && $0.start >= onset && $0.end <= wake }.count
        }

        var lines = ["Asleep \(clock.string(from: onset)) · woke \(clock.string(from: wake))"]
        if let up = longest(.up) {
            let n = count(.up)
            lines.append(n > 1 ? "Up \(n) times · longest \(span(up))" : "Up \(span(up))")
        } else if let off = longest(.notWorn) {
            lines.append("Not worn \(span(off))")
        } else if let restless = longest(.restless) {
            let n = count(.restless)
            lines.append(n > 1 ? "Restless \(n) times · longest \(span(restless))"
                               : "Restless \(span(restless))")
        } else {
            lines.append("No interruptions found")
        }
        if let stretch = result.episodes.first(where: { $0.kind == .longestUndisturbed }) {
            lines.append("Longest undisturbed stretch \(span(stretch))")
        }
        return lines
    }

    /// Clock times follow the user's locale ("23:41" or "11:41 PM").
    static func clockFormatter(_ timeZone: TimeZone, locale: Locale = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }
}

/// Night timeline card: episode lane, HR line above it, 1–3 insight lines.
struct AtriaNightTimelineCard: View {
    let model: AtriaNightTimelineModel

    private struct HRPoint: Identifiable {
        let date: Date
        let bpm: Double
        let segment: Int
        var id: Date { date }
    }

    var body: some View {
        if let presentation = AtriaNightTimelinePresentation(model) {
            content(presentation)
        } else {
            VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
                Text("Night timeline").atriaEyebrow()
                // Keep the heart-rate chart whenever there is heart rate:
                // an honest night without motion still has a shape.
                if let window = model.sleepWindow,
                   !hrPoints(in: window.start...window.end).isEmpty {
                    heartRateChart(domain: window.start...window.end, offWrist: [])
                    timeAxis(domain: window.start...window.end)
                }
                Text(model.unavailableReason ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .atriaInsetCard(tint: Metrics.electricSleep)
        }
    }

    private func content(_ p: AtriaNightTimelinePresentation) -> some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Night timeline").atriaEyebrow()
                Spacer(minLength: 0)
                if let hr = model.result.sleepingHeartRate {
                    Text("Sleeping HR \(Int(hr.rounded())) bpm")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            heartRateChart(domain: p.domain, offWrist: model.result.episodes
                .filter { $0.kind == .notWorn }
                .map { DateInterval(start: $0.start, end: $0.end) })
            episodeLane(p, axisDigits: heartRateAxisDigits(p))
            legend(p)
            if let note = model.motionNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(p.insights.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(index == 0 ? .subheadline.weight(.semibold) : .footnote)
                        .foregroundStyle(index == 0 ? .primary : .secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricSleep)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Night timeline. " + p.insights.joined(separator: ". "))
    }

    private func hrPoints(in domain: ClosedRange<Date>) -> [HRPoint] {
        var segment = 0
        var previous: Date?
        var output: [HRPoint] = []
        for minute in model.minutes where domain.contains(minute.start) {
            guard let bpm = minute.heartRate, bpm > 0 else { continue }
            if let previous,
               minute.start.timeIntervalSince(previous) > AtriaChartVisualGrammar.traceDisplayContinuityGap {
                segment += 1
            }
            previous = minute.start
            output.append(HRPoint(date: minute.start, bpm: bpm, segment: segment))
        }
        return output
    }

    private func heartRateDomain(_ points: [HRPoint]) -> ClosedRange<Double> {
        let bpms = points.map(\.bpm)
        let low = (bpms.min() ?? 50) - 4
        return low...max((bpms.max() ?? 80) + 4, low + 20)
    }

    /// Width of the HR axis labels, so the lane's invisible axis matches it
    /// and both plots start at the same x.
    private func heartRateAxisDigits(_ p: AtriaNightTimelinePresentation) -> Int {
        String(Int(heartRateDomain(hrPoints(in: p.domain)).upperBound)).count
    }

    /// Not-worn episodes are proven off-wrist evidence for the HR gaps.
    private func heartRateChart(domain xDomain: ClosedRange<Date>,
                                offWrist: [DateInterval]) -> some View {
        let points = hrPoints(in: xDomain)
        let domain = heartRateDomain(points)
        let low = domain.lowerBound
        let high = domain.upperBound
        let gapBands = AtriaChartNoDataBands.bands(
            sampleDates: points.map(\.date),
            domain: xDomain,
            evidence: AtriaChartGapEvidence(offWristSpans: offWrist))
        return Chart {
            AtriaNoDataBandMarks(bands: gapBands, domain: xDomain)
            ForEach(points) { point in
                LineMark(x: .value("Time", point.date),
                         y: .value("Heart rate", point.bpm),
                         series: .value("Run", point.segment))
                    .interpolationMethod(.monotone)
                    .lineStyle(AtriaChartVisualGrammar.traceLine)
                    .foregroundStyle(Metrics.heartRateIntensityGradient)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: low...high)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(AtriaChartVisualGrammar.axisGridOpacity))
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel().font(AtriaChartVisualGrammar.axisLabelFont).foregroundStyle(AtriaChartVisualGrammar.axisLabelColor)
            }
        }
        .atriaGraphPlotSurface()
        .frame(height: 92)
        .environment(\.timeZone, model.timeZone)
        .accessibilityHidden(true)
    }

    private func episodeLane(_ p: AtriaNightTimelinePresentation, axisDigits: Int) -> some View {
        Chart {
            ForEach(p.bands) { band in
                RectangleMark(xStart: .value("Start", band.start),
                              xEnd: .value("End", band.end),
                              yStart: .value("Floor", 0),
                              yEnd: .value("Ceiling", 1))
                    .foregroundStyle(band.kind.tint)
                    .cornerRadius(3)
            }
        }
        .chartXScale(domain: p.domain)
        .chartYScale(domain: 0...1)
        .chartYAxis {
            // Invisible leading axis so the lane lines up under the HR plot.
            AxisMarks(position: .leading, values: [0.5]) { _ in
                AxisValueLabel {
                    Text(String(repeating: "0", count: max(2, axisDigits)))
                        .font(AtriaChartVisualGrammar.axisLabelFont)
                        .hidden()
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: AtriaChartVisualGrammar.intradayTimeTickCount)) { _ in
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(AtriaChartVisualGrammar.axisLabelFont)
                    .foregroundStyle(AtriaChartVisualGrammar.axisLabelColor)
            }
        }
        .frame(height: 46)
        .environment(\.timeZone, model.timeZone)
        .accessibilityHidden(true)
    }

    /// Bare time axis under the HR chart when there is no episode lane.
    private func timeAxis(domain: ClosedRange<Date>) -> some View {
        let digits = String(Int(heartRateDomain(hrPoints(in: domain)).upperBound)).count
        return Chart { RuleMark(y: .value("Base", 0)).foregroundStyle(.clear) }
            .chartXScale(domain: domain)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0]) { _ in
                    AxisValueLabel {
                        Text(String(repeating: "0", count: max(2, digits)))
                            .font(AtriaChartVisualGrammar.axisLabelFont)
                            .hidden()
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: AtriaChartVisualGrammar.intradayTimeTickCount)) { _ in
                    AxisTick().foregroundStyle(.clear)
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(AtriaChartVisualGrammar.axisLabelFont)
                        .foregroundStyle(AtriaChartVisualGrammar.axisLabelColor)
                }
            }
            .frame(height: 20)
            .environment(\.timeZone, model.timeZone)
            .accessibilityHidden(true)
    }

    private func legend(_ p: AtriaNightTimelinePresentation) -> some View {
        // Wrapping legend: only the lanes this night actually has.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { legendItems(p) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) { legendItems(p, range: 0..<min(3, p.legend.count)) }
                HStack(spacing: 10) { legendItems(p, range: min(3, p.legend.count)..<p.legend.count) }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func legendItems(_ p: AtriaNightTimelinePresentation, range: Range<Int>? = nil) -> some View {
        let lanes = range.map { Array(p.legend[$0]) } ?? p.legend
        ForEach(lanes, id: \.self) { lane in
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(lane.tint)
                    .frame(width: 10, height: 10)
                Text(lane.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Source

/// Where the Sleep detail and Today get an analysed night.
///
/// Production: `AtriaNightTimelineStore` builds minutes for the latest
/// confirmed main sleep from the phone's own stores (HR archive, v24 motion
/// history, session RR; see `AtriaNightMinuteBuilder`). DEBUG builds render a
/// synthetic night with `--atria-ui-fixture night-timeline`.
enum AtriaNightTimelineSource {
    /// The morning question is asked in the first hours of the person's own
    /// day, i.e. after THEIR wake, not between fixed clock hours. A shifted
    /// sleeper who wakes at 19:15 gets it that evening (the old 04:00-13:00
    /// clock gate never showed it to them).
    static let morningPromptWindow: TimeInterval = 12 * 3_600

    static func morningPromptIsDue(wake: Date, now: Date) -> Bool {
        now >= wake && now.timeIntervalSince(wake) < morningPromptWindow
    }

    #if DEBUG
    static func debugFixtureRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard let index = arguments.firstIndex(of: "--atria-ui-fixture"),
              arguments.indices.contains(index + 1) else { return false }
        return ["night-timeline", "night-interruptions", "night-timeline-no-motion"].contains(arguments[index + 1])
    }

    /// Synthetic night (no user data): lights off 22:50, settles ~23:40, a
    /// 45-minute walk ~01:43, a restless patch ~04:00, 15 minutes off wrist
    /// ~05:30, wakes ~07:40. Anchored to the most recent such night.
    static func debugSyntheticNight(now: Date = Date(),
                                    calendar: Calendar = .current) -> AtriaNightTimelineModel {
        let today = calendar.startOfDay(for: now)
        let evening = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let start = evening.addingTimeInterval(22 * 3_600 + 50 * 60)
        let count = 9 * 60 + 20
        var minutes: [AtriaNightTimelineAnalyzer.Minute] = []
        minutes.reserveCapacity(count)
        for i in 0..<count {
            let t = start.addingTimeInterval(Double(i) * 60)
            // Deterministic pseudo-noise so the fixture is stable.
            let wobble = Double((i * 37) % 11) / 10.0
            var hr: Double? = 58 + 6 * cos(Double(i) / 90) + wobble
            var motion: Double? = 0.006 + Double((i * 13) % 5) * 0.0005
            var steps = 0
            var offWrist = false
            switch i {
            case 0..<50: // settling in bed
                motion = 0.05 + Double(i % 4) * 0.02; hr = 68 - Double(i) / 10 + wobble
            case 173..<218: // up ~01:43–02:28, walking
                motion = 0.6; steps = 70; hr = 88 + wobble
            case 310..<322: // restless ~04:00
                motion = 0.12; hr = 64 + wobble
            case 400..<415: // off wrist ~05:30
                offWrist = true; hr = nil; motion = nil
            case 530...: // awake after ~07:40
                motion = 0.3; steps = i % 3 == 0 ? 12 : 0; hr = 72 + wobble
            default: break
            }
            // An honest HR hole with no reason: 03:05–03:25 no samples.
            if (255..<275).contains(i) { hr = nil }
            minutes.append(.init(start: t, heartRate: hr, motion: motion, steps: steps,
                                 rrIntervals: [], offWrist: offWrist))
        }
        return AtriaNightTimelineModel(minutes: minutes, lightsOff: start)
    }
    #endif
}
