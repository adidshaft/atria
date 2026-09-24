import Charts
import SwiftUI

/// Sleep detail: the latest confirmed main sleep's timeline, the personal
/// "ups and downs" comparison, then the optional "what was it?" prompt.
/// Loads off the main actor through `AtriaNightTimelineStore`.
struct AtriaNightTimelineSection: View {
    let sleepHistory: SleepHistorySnapshot
    /// Saved sessions overlapping a window (live HR fallback + RR).
    var sessions: ((DateInterval) -> [SavedSession])?
    @ObservedObject private var store = AtriaNightTimelineStore.shared

    private var request: AtriaNightTimelineRequest? {
        #if DEBUG
        if let fixture = AtriaNightTimelineFixture.requested() { return fixture.request }
        #endif
        return AtriaNightTimelineRequest.latestMainSleep(in: sleepHistory)
    }

    var body: some View {
        // A real container so `.task` always runs (a Group whose content is
        // empty, e.g. `.unavailable`, never reloads on a new night). Spacing
        // matches the detail template's own stack.
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.lg) {
            if let request {
                switch store.state(for: request) {
                case .loaded(let loaded):
                    AtriaNightTimelineCard(model: loaded.model)
                    if let report = store.baselines[request.key] {
                        AtriaNightBaselineCard(report: report, timeZone: loaded.model.timeZone)
                    }
                    AtriaNightInterruptionPromptCard(
                        episodes: AtriaNightTimelineAnalyzer.interruptionsToAsk(loaded.model.result),
                        timeZone: loaded.model.timeZone)
                case .idle, .loading:
                    AtriaNightTimelineLoadingCard()
                case .unavailable:
                    EmptyView()
                }
            }
        }
        .task(id: request?.key) { load() }
    }

    private func load() {
        #if DEBUG
        if let fixture = AtriaNightTimelineFixture.requested() {
            fixture.install(into: store)
            return
        }
        #endif
        guard let request else { return }
        store.ensureLoaded(request,
                           history: AtriaNightTimelineRequest.mainSleeps(in: sleepHistory),
                           sessions: sessions)
    }
}

/// Today: the morning "what was it?" card for the latest main sleep, shown
/// in the first hours after that sleep's wake (whatever the clock says).
struct AtriaNightMorningPromptHost: View {
    let sleepHistory: SleepHistorySnapshot
    var sessions: ((DateInterval) -> [SavedSession])?
    @ObservedObject private var store = AtriaNightTimelineStore.shared
    @State private var now = Date()

    private var request: AtriaNightTimelineRequest? {
        #if DEBUG
        if let fixture = AtriaNightTimelineFixture.requested() { return fixture.request }
        #endif
        guard let latest = AtriaNightTimelineRequest.latestMainSleep(in: sleepHistory),
              AtriaNightTimelineSource.morningPromptIsDue(wake: latest.end, now: now) else { return nil }
        return latest
    }

    var body: some View {
        // A VStack, not a Group: `.task` on a Group with no children never
        // runs, so the prompt could never load itself.
        VStack(spacing: 0) {
            if let loaded = store.loaded(for: request) {
                AtriaNightInterruptionPromptCard(
                    episodes: AtriaNightTimelineAnalyzer.interruptionsToAsk(loaded.model.result),
                    timeZone: loaded.model.timeZone)
            }
        }
        .task(id: request?.key) {
            now = Date()
            #if DEBUG
            if let fixture = AtriaNightTimelineFixture.requested() {
                fixture.install(into: store)
                return
            }
            #endif
            guard let request else { return }
            store.ensureLoaded(request,
                               history: AtriaNightTimelineRequest.mainSleeps(in: sleepHistory),
                               sessions: sessions)
        }
    }
}

private struct AtriaNightTimelineLoadingCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            Text("Night timeline").atriaEyebrow()
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricSleep)
        .accessibilityLabel("Night timeline loading")
    }
}

/// "Ups and downs": this night against the same person's own recent nights.
/// Chart first (time asleep per night, usual as a rule), then at most three
/// short lines. "Learning (n/5)" until five qualifying nights exist.
struct AtriaNightBaselineCard: View {
    let report: AtriaNightBaselineReport
    var timeZone: TimeZone = .current

    private struct Bar: Identifiable {
        let wake: Date
        let hours: Double
        let isTonight: Bool
        var id: Date { wake }
    }

    /// Oldest → newest, at most 14 nights including tonight.
    private var bars: [Bar] {
        let prior = report.prior.prefix(13).reversed().map {
            Bar(wake: $0.wake, hours: $0.asleepMinutes / 60, isTonight: false)
        }
        return prior + [Bar(wake: report.tonight.wake, hours: report.tonight.asleepMinutes / 60, isTonight: true)]
    }

    private var usualHours: Double? {
        guard report.learningText == nil else { return nil }
        return AtriaNightBaseline.median(report.prior.map(\.asleepMinutes)) / 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your usual").atriaEyebrow()
                Spacer(minLength: 0)
                if let learning = report.learningText {
                    Text(learning)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            chart
            if report.learningText != nil {
                Text("Comparisons start after five full nights.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(report.lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(index == 0 ? .subheadline.weight(.semibold) : .footnote)
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .atriaInsetCard(tint: Metrics.electricSleep)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Compared with your usual. "
            + (report.learningText ?? report.lines.joined(separator: ". ")))
    }

    private var chart: some View {
        Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("Night", bar.wake, unit: .day),
                        y: .value("Asleep", bar.hours))
                    .foregroundStyle(bar.isTonight ? Metrics.electricSleep : Metrics.electricSleep.opacity(0.35))
                    .cornerRadius(3)
            }
            if let usualHours {
                RuleMark(y: .value("Usual", usualHours))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(AtriaChartVisualGrammar.axisGridOpacity))
                AxisValueLabel {
                    if let hours = value.as(Double.self) { Text("\(Int(hours))h") }
                }
                .font(AtriaChartVisualGrammar.axisLabelFont)
                .foregroundStyle(AtriaChartVisualGrammar.axisLabelColor)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(AtriaChartVisualGrammar.axisLabelFont)
                    .foregroundStyle(AtriaChartVisualGrammar.axisLabelColor)
            }
        }
        .frame(height: 96)
        .environment(\.timeZone, timeZone)
        .accessibilityHidden(true)
    }
}

#if DEBUG
/// `--atria-ui-fixture night-timeline` (Sleep detail) / `night-interruptions`
/// (Today) / `night-timeline-no-motion` (the honest no-motion state).
/// Synthetic data only; no user data.
struct AtriaNightTimelineFixture {
    let request: AtriaNightTimelineRequest
    let loaded: AtriaNightTimelineLoaded
    let report: AtriaNightBaselineReport?

    /// Built once per launch: views ask for it on every body pass.
    private static let launchFixture: Self? = resolve(ProcessInfo.processInfo.arguments, now: Date())

    static func requested() -> Self? { launchFixture }

    static func resolve(_ arguments: [String], now: Date) -> Self? {
        guard let index = arguments.firstIndex(of: "--atria-ui-fixture"),
              arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case "night-timeline", "night-interruptions": return make(now: now, motion: true)
        case "night-timeline-no-motion": return make(now: now, motion: false)
        default: return nil
        }
    }

    @MainActor
    func install(into store: AtriaNightTimelineStore) {
        store.installForFixture(loaded, baseline: report)
    }

    static func make(now: Date, motion: Bool) -> Self {
        let synthetic = AtriaNightTimelineSource.debugSyntheticNight(now: now)
        let minutes = synthetic.minutes.map { minute -> AtriaNightTimelineAnalyzer.Minute in
            var copy = minute
            if !motion { copy.motion = nil; copy.steps = 0; copy.offWrist = false }
            return copy
        }
        let first = minutes.first?.start ?? now
        let last = minutes.last?.start.addingTimeInterval(60) ?? now
        let request = AtriaNightTimelineRequest(sleepID: "fixture-night", start: first.addingTimeInterval(30 * 60),
                                                end: last.addingTimeInterval(-30 * 60),
                                                eventTimeZoneIdentifier: nil)
        let coverage = AtriaNightMinuteBuilder.Coverage(
            totalMinutes: minutes.count,
            heartRateMinutes: minutes.filter { $0.heartRate != nil }.count,
            motionMinutes: minutes.filter { $0.motion != nil }.count)
        let model = AtriaNightTimelineModel(minutes: minutes,
                                            lightsOff: motion ? first : nil,
                                            coverage: coverage,
                                            sleepWindow: DateInterval(start: request.start, end: request.end))
        let summary = AtriaNightSummary.from(model.result, minutes: minutes)
        let loaded = AtriaNightTimelineLoaded(request: request, model: model,
                                              coverage: coverage, summary: summary)
        // Nine synthetic prior nights: a little longer and ~4 bpm higher, so
        // the fixture shows real "lower than usual" / "less than usual" lines.
        let report = summary.map { tonight -> AtriaNightBaselineReport in
            let prior = (1...9).map { k -> AtriaNightSummary in
                let shift = Double(k) * 86_400
                let wobble = Double((k * 7) % 5) - 2
                var night = tonight
                night.night = tonight.night.addingTimeInterval(-shift + wobble * 300)
                night.onset = night.night
                night.wake = tonight.wake.addingTimeInterval(-shift + wobble * 240)
                night.asleepMinutes = tonight.asleepMinutes + 55 + wobble * 6
                night.disturbedMinutes = max(0, tonight.disturbedMinutes - 40 + wobble * 3)
                night.sleepingHeartRate = tonight.sleepingHeartRate.map { $0 + 5 + wobble * 0.5 }
                night.coverage = 1
                return night
            }
            return AtriaNightBaselineReport(tonight: tonight, history: prior)
        }
        return Self(request: request, loaded: loaded, report: report)
    }
}
#endif
