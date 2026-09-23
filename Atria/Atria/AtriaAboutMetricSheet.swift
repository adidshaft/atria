import SwiftUI
import Charts

/// Canonical unavailable copy for blood oxygen (SpO2).
///
/// SpO2 has ONE honest story across the app: this strap's sensor can't produce a
/// validated reading, so Atria shows nothing rather than an estimate. The exact
/// phrasing had fragmented across ~15 hand-written strings. These states name
/// whether Atria lacks a verified decoder or the strap lacks the sensor, rather
/// than implying that waiting alone will produce a reading.
/// These constants are the single source of truth the design signed off on, so
/// any surface that wants the canonical wording can reference one place instead
/// of re-inventing it. Deliberately never renders a percentage.
enum AtriaSpO2Copy {
    /// Short honesty line.
    static let wontFakeAPercentage = "Atria won't fake a percentage."
    /// Short app-limitation state for straps that carry the sensor. Waiting is
    /// not the blocker: Atria has not verified a decoder for the signal.
    static let decoderNotVerified = "Decoder not verified"
    /// Short hardware state used only when the identified strap lacks SpO2.
    static let notAvailableOnStrap = "Sensor unavailable on this strap"
    /// Headline state shown on the SpO2 card for every strap while no validated
    /// reading exists: blood oxygen is not available on this strap. Honest whether
    /// the strap lacks the sensor entirely or carries it but broadcasts no
    /// decodable percentage — the detail/why-blank copy explains which.
    static let notAvailableOnThisStrap = "Not available on this strap"
    /// Long form for compact education/detail surfaces.
    static let longUnavailable = "Atria can't yet produce a validated SpO2 reading from this strap's sensor. Rather than estimate, it leaves this blank — and tells you why."
    /// Full "why it's blank" explanation shown when the user taps SpO2 to open the
    /// About sheet. Explains SpO2 is a derived (ratio-of-ratios) value, not a
    /// direct read, and the open decode-vs-calibrate question. 2026-08-01.
    static let whyBlank = "SpO\u{2082} isn't read directly — it's worked out from how much red versus infrared light your blood absorbs (a \u{201c}ratio of ratios\u{201d}). Atria doesn't yet know if this strap shares a ready-made value or only a raw waveform that would need a one-time calibration against a reference oximeter. Until it's sure, it shows nothing rather than guess a number you might act on."
}

/// The metrics that have an "About <metric>" education sheet.
///
/// Each case carries its real definition, a "how Atria computes it" description
/// that MUST match the actual algorithm (verified against HRV.swift,
/// AtriaStressMonitor.swift, AtriaAnalytics.swift, AtriaFitnessAge.swift,
/// Sessions.swift / AtriaSleepWakeResearch.swift on 2026-08-01), and an honesty
/// note. `bloodOxygen` has no verified app decoder: it has no compute
/// description because Atria cannot yet produce a defensible value, so it
/// carries the canonical unavailable copy instead.
enum AtriaAboutMetric: String, Identifiable, CaseIterable {
    case hrv
    case stress
    case recovery
    case restingHeartRate
    case respiration
    case sleep
    case vo2max
    case skinTemperature
    case bloodOxygen

    var id: String { rawValue }

    /// Body H1 (and, prefixed with "About", the sheet title).
    var title: String {
        switch self {
        case .hrv: return "HRV"
        case .stress: return "Stress"
        case .recovery: return "Recovery"
        case .restingHeartRate: return "Resting heart rate"
        case .respiration: return "Respiratory rate"
        case .sleep: return "Sleep"
        case .vo2max: return "Body Age & VO₂max"
        case .skinTemperature: return "Skin temperature"
        case .bloodOxygen: return "Blood oxygen (SpO₂)"
        }
    }

    var glyph: String {
        switch self {
        case .hrv: return "waveform.path.ecg"
        case .stress: return "bolt.heart.fill"
        case .recovery: return "arrow.clockwise.heart.fill"
        case .restingHeartRate: return "heart.fill"
        case .respiration: return "lungs.fill"
        case .sleep: return "moon.stars.fill"
        case .vo2max: return "figure.run"
        case .skinTemperature: return "thermometer.medium"
        case .bloodOxygen: return "lungs.fill"
        }
    }

    /// Identity hue per metric, matching AtriaMetricDetailKind.tint and the
    /// Customize sheet (Metrics.electric*). `bloodOxygen` is intentionally
    /// neutral -- painting an unavailable metric in a confident hue would imply
    /// a reading exists.
    var tint: Color {
        switch self {
        case .hrv: return Metrics.electricHRV
        case .stress: return Metrics.electricStress
        case .recovery: return Metrics.electricGreen
        case .restingHeartRate: return Metrics.electricRHR
        case .respiration: return Metrics.electricRespiratory
        case .sleep: return Metrics.electricSleep
        case .vo2max: return Metrics.electricStrain
        case .skinTemperature: return .orange
        case .bloodOxygen: return .secondary
        }
    }

    var definition: String {
        switch self {
        case .hrv:
            return "The variation in time between heartbeats, measured overnight. Higher variation usually means more recovery capacity — but the \u{201c}right\u{201d} number is personal."
        case .stress:
            return "A 0–3 read of physiological stress from your heart's response: Calm (0–1), Moderate (1–2), High (2–3). It's physical load, not a psychological diagnosis."
        case .recovery:
            return "One readiness score blending overnight HRV, resting heart rate, sleep, and breathing rate against your own baseline. It answers \u{201c}how ready am I today,\u{201d} not a score to max out."
        case .restingHeartRate:
            return "Beats per minute at full rest, from overnight wear. Tracks fitness over months and daily strain in the short term."
        case .respiration:
            return "Breaths per minute while asleep. Normally stable night to night, so a shift from your usual range is often the first sign something's off."
        case .sleep:
            return "Time slept against your personal goal, plus how consistent your recent bedtimes have been. A duration and consistency estimate, not a clinical sleep study."
        case .vo2max:
            return "An estimate of cardiorespiratory fitness (VO₂max), and how old your heart data reads versus your calendar age. A fitness signal from everyday wear, not a lab test."
        case .skinTemperature:
            return "WHOOP 4 has a wrist-skin sensor meant for overnight trend tracking. Atria hasn't verified how to decode it yet, so it doesn't show a temperature value."
        case .bloodOxygen:
            return "Blood-oxygen saturation is the share of your hemoglobin carrying oxygen. Normally in the high 90s at rest."
        }
    }

    /// True when Atria has no verified value to compute or present. Supported
    /// WHOOP 4 hardware carries an optical sensor; the blocker is the decoder,
    /// not the absence of hardware, so keep that distinction in the API name.
    var showsWhyBlank: Bool {
        self == .bloodOxygen || self == .skinTemperature
    }

    /// Section label above the middle card.
    var computeCardTitle: String {
        showsWhyBlank ? "WHY IT'S BLANK" : "HOW ATRIA COMPUTES IT"
    }

    /// Middle card body. For every computed metric this describes the REAL
    /// algorithm; for blood oxygen it is the canonical long-form unavailable copy.
    var computeCardBody: String {
        switch self {
        case .hrv:
            // HRV.swift: RR accepted 300–2000 ms; beats whose deviation from the
            // ±2-beat local median exceeds 20% are dropped; RMSSD over the window;
            // baseline prefers overnight/sleep samples.
            return "Atria uses clean overnight beats (300–2000 ms, with outliers more than 20% off their neighbors dropped) and measures the variation over your most stable stretch of sleep."
        case .stress:
            // AtriaPhysiologicalStressModel.swift: overlapping five-minute
            // windows, evaluated once per minute. HR reserve drives a sigmoid;
            // qualified ln-RMSSD is compared with the rolling personal median
            // and robust MAD, with HR weighted more near rest. Qualified
            // activity attenuates rather than erases elevation; EMA half-life
            // is three minutes and telemetry gaps remain gaps.
            return "Every minute, Atria compares your heart rate and beat-to-beat timing with your own rest-to-max range. Confirmed movement can lower an exercise-related spike, but never erase it. If beat timing is unavailable, Atria still shows a heart-rate-only estimate, labeled lower confidence."
        case .recovery:
            // AtriaAnalytics.swift: z-blend HRV 0.60 / RHR 0.20 (inverted) / sleep
            // 0.15 / respiration 0.05, logistic → 1–99%.
            return "HRV, resting heart rate, sleep, and breathing rate are each compared with your own baseline, weighted (about 60/20/15/5%) and combined into a 1–99% score. It starts appearing after about 4 nights and steadies as your baseline matures."
        case .restingHeartRate:
            // Sessions.swift: 10th percentile (5th during a sleep window), not a
            // single lowest beat; Insights.swift EMA α 0.1, step-bounded ±2 bpm,
            // up to 90 nights, trusted after 14.
            return "Taken as a low percentile of your overnight heart rate, not the single lowest beat, so one odd reading can't skew it. Your baseline is a rolling average of up to 90 nights, trusted after 14."
        case .respiration:
            // AtriaAnalytics.RespRateRsa: RSA from RR, 90 s window, 9–30 bpm band,
            // dominant peak must clear an SNR gate, fail-closed on gaps.
            return "Derived from the breathing rhythm visible in your overnight heartbeat timing — no extra sensor needed. Atria only reports a value when that rhythm is clear; noisy nights are simply left blank."
        case .sleep:
            // AtriaSleepWakeResearch.swift: HR delta/trend/variability + validated
            // motion stillness vs resting HR; 20-min gap tolerance; HR-only shows
            // no hypnogram; manual add has no stages.
            return "Detected from overnight heart rate, and — when motion data is available — heart-rate trend and stillness refine the stage estimate. Short dropouts of up to 20 minutes between clearly-asleep stretches still count; longer gaps don't."
        case .vo2max:
            // AtriaAnalytics.swift: 15.3 * maxHR/rest clamped 20–80 (Uth–Sørensen);
            // AtriaFitnessAge.swift: five factors → age offset clamped ±12; pace =
            // slope of the weekly offset.
            return "VO₂max comes from your measured maximum-to-resting heart-rate ratio. Body Age blends five factors — VO₂max, resting HR, HRV, weekly hard-effort minutes, and sleep consistency — into an age offset from your calendar age."
        case .skinTemperature:
            return "Atria can see sensor bytes but has not verified which ones represent wrist temperature, so it won't turn raw values into degrees. Once confirmed, it will show your reading as a change from your own baseline."
        case .bloodOxygen:
            return AtriaSpO2Copy.whyBlank
        }
    }

    var honestyNote: String {
        switch self {
        case .hrv:
            // Corrected from the design's sample copy (which said "last 60 days"
            // and "4 clean nights"): the real HRV baseline is trusted after 14
            // distinct overnight readings and holds up to 90 nights.
            return "Compared with your own recent overnight nights — never a population norm. Needs about 14 clean nights before HRV appears at all."
        case .stress:
            return "A physiological estimate, not a diagnosis. It learns from your own history; missing heart rate stays blank, and heart-rate-only values are labeled lower confidence."
        case .recovery:
            return "Scored against your own baseline, never a population norm. Confidence reaches full strength after 14 trusted nights; missing essentials show Learning rather than a guess."
        case .restingHeartRate:
            return "Compared only with your own normal, not age tables. Shows Learning until 14 trusted nights exist."
        case .respiration:
            return "Compared with your own typical nights only. A missing night stays missing — Atria never fills in a guess."
        case .sleep:
            return "A duration and timing-consistency estimate from heart-rate evidence, not a clinical sleep study or a measurement of circadian phase. On heart-rate-only nights the stage timeline is labeled an estimate. Manually added sleep has no stage breakdown, and unworn time is never counted as sleep."
        case .vo2max:
            // AtriaFitnessAge.swift footnote + thresholds; VO2max needs a measured
            // HRmax. There is no "Medium" confidence literal in source, so this
            // states the real early/confident day thresholds instead.
            return "An estimate from heart data, not a medical measurement. Needs about 14 days for an early read and 28 for a confident one, and stays \u{201c}preliminary\u{201d} until you've recorded an effort that reaches your real max heart rate."
        case .skinTemperature:
            return "Decoder not verified. If it ships, it stays a sleep-only relative signal — not a fever check — kept on your device and never written to Health."
        case .bloodOxygen:
            return "\(AtriaSpO2Copy.wontFakeAPercentage) \(AtriaSpO2Copy.decoderNotVerified)."
        }
    }
}

/// The last-30-days mini-trend shown inside an About sheet (chart backlog P1).
///
/// Built from the same daily rollups the metric detail charts read, with the
/// identical value transforms (HRV = e^lnRMSSD, sleep in hours, …), so the
/// mini-trend can never disagree with the full chart. `make` returns nil below
/// 5 real readings in the window — the sheet simply omits the card rather than
/// plot a shape that isn't there. Stress and blood oxygen have no persisted
/// daily history, so they never produce a trend.
struct AtriaAboutMetricTrend {
    let points: [AtriaDetailChartPoint]
    /// The full 30-day frame, so sparse points sit at their true position in
    /// the month instead of being stretched to fill the plot.
    let window: ClosedRange<Date>
    /// Real observed count + range ("12 nights · 54–88 ms") — the honest
    /// substitute for a y-axis on a plot this small.
    let caption: String

    var yDomain: ClosedRange<Double> {
        let lo = points.map(\.value).min() ?? 0
        let hi = points.map(\.value).max() ?? 1
        let pad = Swift.max((hi - lo) * 0.18, 0.5)
        return (lo - pad)...(hi + pad)
    }

    static func make(for metric: AtriaAboutMetric,
                     rollups: [DailyRollupStoreEntry],
                     referenceDate: Date = Date(),
                     calendar: Calendar = .current) -> AtriaAboutMetricTrend? {
        let end = calendar.startOfDay(for: referenceDate)
        guard let start = calendar.date(byAdding: .day, value: -29, to: end) else { return nil }

        func value(_ entry: DailyRollupStoreEntry) -> Double? {
            switch metric {
            case .hrv: return entry.lnRMSSD.map { exp($0).rounded() }
            case .restingHeartRate: return entry.rhr.map(Double.init)
            case .recovery: return entry.recovery.map(Double.init)
            case .respiration: return entry.respiratoryRate
            case .sleep: return entry.sleepSeconds.flatMap { $0 > 0 ? $0 / 3_600 : nil }
            case .skinTemperature: return entry.skinTemperatureDeviationCelsius
            case .vo2max: return entry.fitnessAgeDelta.map(Double.init)
            case .stress, .bloodOxygen: return nil
            }
        }

        var seen = Set<Date>()
        let points: [AtriaDetailChartPoint] = rollups.compactMap { entry -> AtriaDetailChartPoint? in
            let day = calendar.startOfDay(for: entry.day)
            guard day >= start, day <= end, let value = value(entry),
                  seen.insert(day).inserted else { return nil }
            return AtriaDetailChartPoint(day: day, value: value, tint: metric.tint)
        }
        .sorted { $0.day < $1.day }

        guard points.count >= 5,
              let lo = points.map(\.value).min(),
              let hi = points.map(\.value).max() else { return nil }
        return AtriaAboutMetricTrend(points: points,
                                     window: start...end,
                                     caption: caption(for: metric, count: points.count, lo: lo, hi: hi))
    }

    /// Sleep-efficiency trend from confirmed-night evidence (P3, 2026-08-04).
    /// Rollups do not persist efficiency, but every confirmed Night carries
    /// its own honest value (displaySleepEfficiency is nil for HR-only nights
    /// whose stored number is span coverage, and those nights are skipped —
    /// same fail-closed rule as the tile). Gate matches the rollup trends:
    /// at least 5 qualified nights inside the 30-day window.
    static func makeSleepEfficiency(nights: [SleepHistorySnapshot.Night],
                                    referenceDate: Date = Date(),
                                    calendar: Calendar = .current) -> AtriaAboutMetricTrend? {
        let end = calendar.startOfDay(for: referenceDate)
        guard let start = calendar.date(byAdding: .day, value: -29, to: end) else { return nil }
        var seen = Set<Date>()
        let points: [AtriaDetailChartPoint] = nights.compactMap { night -> AtriaDetailChartPoint? in
            let day = calendar.startOfDay(for: night.day)
            guard day >= start, day <= end,
                  let efficiency = night.displaySleepEfficiency,
                  seen.insert(day).inserted else { return nil }
            return AtriaDetailChartPoint(day: day,
                                         value: (efficiency * 100).rounded(),
                                         tint: .cyan)
        }
        .sorted { $0.day < $1.day }
        guard points.count >= 5,
              let lo = points.map(\.value).min(),
              let hi = points.map(\.value).max() else { return nil }
        let noun = points.count == 1 ? "night" : "nights"
        let range = lo == hi ? "steady at \(Int(lo))%" : "\(Int(lo))–\(Int(hi))%"
        return AtriaAboutMetricTrend(points: points,
                                     window: start...end,
                                     caption: "\(points.count) \(noun) · \(range)")
    }

    private static func caption(for metric: AtriaAboutMetric,
                                count: Int, lo: Double, hi: Double) -> String {
        let noun: String
        switch metric {
        case .vo2max: noun = count == 1 ? "day" : "days"
        default: noun = count == 1 ? "night" : "nights"
        }
        let range = rangeText(for: metric, lo: lo, hi: hi)
        return "\(count) \(noun) · \(range)"
    }

    private static func rangeText(for metric: AtriaAboutMetric,
                                  lo: Double, hi: Double) -> String {
        func plain(_ v: Double, decimals: Int) -> String {
            String(format: "%.\(decimals)f", v)
        }
        func signed(_ v: Double, decimals: Int) -> String {
            let magnitude = plain(abs(v), decimals: decimals)
            return v < 0 ? "−\(magnitude)" : "+\(magnitude)"
        }
        switch metric {
        case .hrv:
            return lo == hi ? "steady at \(Int(lo)) ms" : "\(Int(lo))–\(Int(hi)) ms"
        case .restingHeartRate:
            return lo == hi ? "steady at \(Int(lo)) bpm" : "\(Int(lo))–\(Int(hi)) bpm"
        case .recovery:
            return lo == hi ? "steady at \(Int(lo))%" : "\(Int(lo))–\(Int(hi))%"
        case .respiration:
            return lo == hi
                ? "steady at \(plain(lo, decimals: 1)) breaths/min"
                : "\(plain(lo, decimals: 1))–\(plain(hi, decimals: 1)) breaths/min"
        case .sleep:
            return lo == hi
                ? "steady at \(plain(lo, decimals: 1)) h"
                : "\(plain(lo, decimals: 1))–\(plain(hi, decimals: 1)) h"
        case .skinTemperature:
            return "\(signed(lo, decimals: 1)) to \(signed(hi, decimals: 1)) °C vs your baseline"
        case .vo2max:
            return "\(signed(lo, decimals: 0)) to \(signed(hi, decimals: 0)) yr vs calendar age"
        case .stress, .bloodOxygen:
            return ""
        }
    }
}

/// Shared mini-trend card: gap-broken shape-preserving line + a dot per real reading,
/// framed on the trend's full window. Axes are hidden — the caption carries the
/// real observed count and range instead, so nothing on the plot is fabricated
/// (honesty-first chart rules, 2026-08-03). Used by the About sheets and the
/// sleep-efficiency detail; self-contained for render tests.
struct AtriaMiniTrendCard: View {
    let trend: AtriaAboutMetricTrend
    let tint: Color
    let title: String
    /// What the values are, for VoiceOver ("HRV", "Sleep efficiency").
    let subject: String

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Chart {
                ForEach(trend.points.contiguousDayRuns(), id: \.point.day) { entry in
                    LineMark(x: .value("Day", entry.point.day, unit: .day),
                             y: .value(subject, entry.point.value),
                             series: .value("Run", "r\(entry.runID)"))
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                        .lineStyle(AtriaChartVisualGrammar.trendLine)
                }
                // A dot per real reading so single-day runs (no line segment)
                // are still visible instead of silently disappearing.
                ForEach(trend.points) { point in
                    PointMark(x: .value("Day", point.day, unit: .day),
                              y: .value(subject, point.value))
                        .foregroundStyle(tint)
                        .symbolSize(18)
                }
            }
            .atriaGraphPlotSurface()
            .chartXScale(domain: trend.window)
            .chartYScale(domain: trend.yDomain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 72)
            // Full-bleed plot inside the card (2026-08-05 width audit): the
            // axis-less sparkline needs no inset; title and caption keep it.
            .padding(.horizontal, -AtriaDesignTokens.Spacing.lg)
            Text(trend.caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(cornerRadius: AtriaDesignTokens.Radius.tile, emphasis: .soft)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title.capitalized) of \(subject): \(trend.caption)")
    }
}

/// The "About <metric>" education sheet (design spec §20).
///
/// A reusable template: a tinted glyph tile, an H1, a definition paragraph, a
/// "HOW ATRIA COMPUTES IT" card, and a "HONESTY NOTE" card tinted in the metric
/// hue. For an unverified experimental signal the middle card becomes
/// an honest "WHY IT'S BLANK" card carrying the canonical unavailable copy.
///
/// Self-contained so any metric detail surface can present it with local state,
/// and so it can be rendered straight to an image in a test.
struct AtriaAboutMetricSheet: View {
    let metric: AtriaAboutMetric
    /// Optional last-30-days mini-trend (P1). nil — because the surface has no
    /// rollup history in scope, or the metric has under 5 readings — simply
    /// omits the card; the education copy stands alone.
    var trend: AtriaAboutMetricTrend? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                sheetContent
            }
            .navigationTitle("About \(metric.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The sheet's scroll content, extracted so a render test can compose it
    /// directly — ImageRenderer can't draw the UIKit-backed NavigationStack and
    /// yields the error placeholder if handed the full sheet.
    var sheetContent: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.xl) {
            glyphTile
            Text(metric.title)
                .font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(metric.definition)
                .font(.system(size: 14.5))
                .foregroundStyle(.secondary)
                .lineSpacing(8)
                .fixedSize(horizontal: false, vertical: true)

            if let trend {
                trendCard(trend)
            }
            computeCard
            honestyCard

            Text("General guidance, not medical advice.")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.xl)
    }

    private var glyphTile: some View {
        Image(systemName: metric.glyph)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(metric.tint)
            .frame(width: 52, height: 52)
            .background(AtriaIconTileBackground(cornerRadius: 16, tint: metric.tint))
            .accessibilityHidden(true)
    }

    private func trendCard(_ trend: AtriaAboutMetricTrend) -> some View {
        AtriaMiniTrendCard(trend: trend,
                           tint: metric.tint,
                           title: "YOUR LAST 30 DAYS",
                           subject: metric.title)
    }

    private var computeCard: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            Text(metric.computeCardTitle)
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(metric.computeCardBody)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(cornerRadius: AtriaDesignTokens.Radius.tile, emphasis: .soft)
    }

    private var honestyCard: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            Label("HONESTY NOTE", systemImage: "checkmark.shield.fill")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(metric.tint)
            Text(metric.honestyNote)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.tile,
                        tint: metric.tint,
                        hueTinted: true)
    }
}
