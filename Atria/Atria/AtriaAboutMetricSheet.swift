import SwiftUI

/// Canonical hardware-unavailable copy for blood oxygen (SpO2).
///
/// SpO2 has ONE honest story across the app: this strap's sensor can't produce a
/// validated reading, so Atria shows nothing rather than an estimate. The exact
/// phrasing had fragmented across ~15 hand-written strings (some framed by time
/// -- "Not available yet" -- some by hardware -- "Not available on this strap").
/// These constants are the single source of truth the design signed off on, so
/// any surface that wants the canonical wording can reference one place instead
/// of re-inventing it. Deliberately never renders a percentage.
enum AtriaSpO2Copy {
    /// Short honesty line.
    static let wontFakeAPercentage = "Atria won't fake a percentage."
    /// Short state line. 2026-08-01: reframed from "Not available on this strap"
    /// to an APP-limitation, because the WHOOP 4 strap DOES carry the SpO2 sensor
    /// (`AtriaBLEManager.AtriaStrapModel.supportsSpO2 == true`) — Atria simply has
    /// no validated decoder for it yet (`AtriaResearchProbe.validatedSpO2Decoder-
    /// Available == false`). Saying "not on this strap" over-claimed a hardware
    /// gap that isn't real. Constant name kept for reference stability; the value
    /// is the source of truth. See the SpO2-decoder research task.
    static let notAvailableOnStrap = "Not available in Atria yet."
    /// Long form for education/detail surfaces.
    static let longUnavailable = "Atria can't yet produce a validated SpO2 reading from this strap's sensor. Rather than estimate, it leaves this blank — and tells you why."
}

/// The metrics that have an "About <metric>" education sheet.
///
/// Each case carries its real definition, a "how Atria computes it" description
/// that MUST match the actual algorithm (verified against HRV.swift,
/// AtriaStressMonitor.swift, AtriaAnalytics.swift, AtriaFitnessAge.swift,
/// Sessions.swift / AtriaSleepWakeResearch.swift on 2026-08-01), and an honesty
/// note. `bloodOxygen` is the hardware-unavailable case: it has no compute
/// description because there is nothing computed -- it carries the canonical
/// unavailable copy instead.
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
            return "The variation in the time between consecutive heartbeats, measured overnight from the beat-to-beat timing of your heart. Higher variation generally reflects more recovery capacity, but the \u{201c}right\u{201d} number is deeply individual."
        case .stress:
            return "A live estimate of autonomic load right now, read from your heart rate and beat-to-beat timing — not a lab cortisol measurement. Treat it as a rough Calm / Low / Medium / High signal for how activated your system currently is."
        case .recovery:
            return "One readiness read that blends your overnight HRV, resting heart rate, sleep, and respiration against your own baseline. It answers \u{201c}how ready am I today,\u{201d} not a score to max out every day."
        case .restingHeartRate:
            return "How many times your heart beats per minute at full rest, taken from overnight wear. It tracks cardiovascular fitness over months and day-to-day strain in the short term."
        case .respiration:
            return "How many breaths you take per minute while asleep. It is normally stable night to night, so shifts outside your own usual range are often the first sign something is off."
        case .sleep:
            return "How long you slept against your personal goal, plus how consistent your recent sleep timing has been. It is a duration and consistency estimate, not a clinical sleep study."
        case .vo2max:
            return "An estimate of your cardiorespiratory fitness (VO₂max) and how old your heart data reads versus your calendar age. It is a fitness signal from everyday wear, not a lab test."
        case .skinTemperature:
            return "A relative wrist-skin temperature signal measured while you sleep. It shows how tonight compares with your own recent nights — never an absolute or core body temperature."
        case .bloodOxygen:
            return "Blood-oxygen saturation is the percentage of your hemoglobin carrying oxygen. It normally sits in the high 90s at rest."
        }
    }

    /// True when there is nothing to compute because the hardware can't produce a
    /// validated reading. The compute card becomes an honest "why it's blank"
    /// card carrying the canonical copy.
    var isHardwareUnavailable: Bool { self == .bloodOxygen }

    /// Section label above the middle card.
    var computeCardTitle: String {
        isHardwareUnavailable ? "WHY IT'S BLANK" : "HOW ATRIA COMPUTES IT"
    }

    /// Middle card body. For every computed metric this describes the REAL
    /// algorithm; for blood oxygen it is the canonical long-form unavailable copy.
    var computeCardBody: String {
        switch self {
        case .hrv:
            // HRV.swift: RR accepted 300–2000 ms; beats whose deviation from the
            // ±2-beat local median exceeds 20% are dropped; RMSSD over the window;
            // baseline prefers overnight/sleep samples.
            return "Clean beat-to-beat intervals from overnight wear — 300–2000 ms, with any beat more than 20% off its neighbors dropped — then the beat-to-beat variation is measured over the most stable stretch of sleep."
        case .stress:
            // AtriaStressMonitor.swift: 0.6*HR + 0.4*HRV activation z-scores vs
            // resting patterns → Calm/Low/Medium/High; HR-only capped at Medium;
            // noSignal when contact is lost.
            return "A short rolling window of heart rate and beat-to-beat variability is compared with your own resting patterns as z-scores, weighted about 60% heart rate and 40% variability, then mapped to a Calm / Low / Medium / High band. Without a trusted variability baseline it is capped at Medium — \u{201c}High\u{201d} needs the HRV signal to corroborate. It needs continuous, well-seated contact: a loose fit, movement noise, or the strap being off pauses the read as \u{201c}No signal\u{201d} rather than guessing."
        case .recovery:
            // AtriaAnalytics.swift: z-blend HRV 0.60 / RHR 0.20 (inverted) / sleep
            // 0.15 / respiration 0.05, logistic → 1–99%.
            return "Overnight HRV, resting heart rate, sleep, and respiration are each turned into a z-score against your own baseline, blended (weighted about 60% HRV, 20% resting HR, 15% sleep, 5% respiration) and mapped through a logistic curve to a 1–99% score. It starts appearing after about 4 nights of calibration and steadies as the baseline matures."
        case .restingHeartRate:
            // Sessions.swift: 10th percentile (5th during a sleep window), not a
            // single lowest beat; Insights.swift EMA α 0.1, step-bounded ±2 bpm,
            // up to 90 nights, trusted after 14.
            return "Read from the strap's heart-rate stream at rest, preferring overnight windows, as a low percentile of the session (the 10th, or 5th during a detected sleep window) rather than a single lowest beat. Your baseline is a step-bounded rolling average of up to 90 nights, trusted after 14 — one odd night can't yank it."
        case .respiration:
            // AtriaAnalytics.RespRateRsa: RSA from RR, 90 s window, 9–30 bpm band,
            // dominant peak must clear an SNR gate, fail-closed on gaps.
            return "Derived from the breathing rhythm (respiratory sinus arrhythmia) visible in your overnight beat-to-beat timing — no extra sensor. Atria scans a 90-second window for the strongest cycle in the 9–30 breaths-per-minute band and reports it only when that peak clearly dominates. Nights without a clean overnight window simply don't produce a value."
        case .sleep:
            // AtriaSleepWakeResearch.swift: HR delta/trend/variability + validated
            // motion stillness vs resting HR; 20-min gap tolerance; HR-only shows
            // no hypnogram; manual add has no stages.
            return "Detected from continuous overnight heart-rate evidence, and — when trusted motion data is present — heart-rate trend, variability, and stillness are used to estimate stages relative to your resting heart rate. Brief sensor dropouts of up to 20 minutes between clearly-asleep stretches count toward duration; longer gaps are honestly excluded."
        case .vo2max:
            // AtriaAnalytics.swift: 15.3 * maxHR/rest clamped 20–80 (Uth–Sørensen);
            // AtriaFitnessAge.swift: five factors → age offset clamped ±12; pace =
            // slope of the weekly offset.
            return "VO₂max is estimated from the ratio of your measured maximum to resting heart rate (about 15.3 × maxHR ÷ resting HR), then bounded to a plausible range. Body Age combines five factors — VO₂max, resting HR, HRV, weekly zone-2-and-up minutes, and sleep consistency — into an age offset against your calendar age. Pace of aging is the trend of that offset over recent weeks."
        case .skinTemperature:
            // Sessions.swift: mean skin-temp over a sleep session minus the mean of
            // prior sleep nights; needs ≥3 prior nights; ±0.5 °C typical.
            return "Averaged from the strap's skin-temperature sensor across a night's sleep, then compared with the mean of your prior sleep nights to give a deviation in °C. It needs at least 3 prior nights before a delta appears, and reads within about ±0.5 °C as typical."
        case .bloodOxygen:
            return AtriaSpO2Copy.longUnavailable
        }
    }

    var honestyNote: String {
        switch self {
        case .hrv:
            // Corrected from the design's sample copy (which said "last 60 days"
            // and "4 clean nights"): the real HRV baseline is trusted after 14
            // distinct overnight readings and holds up to 90 nights.
            return "\u{201c}Personal baseline\u{201d} means compared with your own recent overnight nights — never a population norm. A trusted baseline needs about 14 clean overnight readings before HRV appears at all."
        case .stress:
            return "Not a medical stress diagnosis — a same-day, relative signal from your own resting patterns."
        case .recovery:
            return "Scored against your own baseline, never a population norm. Early scores are labeled as such; confidence reaches personal-baseline after 14 trusted nights, and missing essentials keep it Learning rather than guessing."
        case .restingHeartRate:
            return "Compared only with your own normal, not age tables. Until 14 trusted nights exist it shows Learning instead of a guessed range."
        case .respiration:
            return "Compared with your own typical nights only. A missing night stays missing — no interpolated breaths."
        case .sleep:
            return "A duration and consistency estimate from heart-rate evidence, not a clinical sleep study. Stage labels are estimates — with heart rate alone Atria shows no hypnogram, and manually added sleep has no stage breakdown. Unworn time is never counted as sleep."
        case .vo2max:
            // AtriaFitnessAge.swift footnote + thresholds; VO2max needs a measured
            // HRmax. There is no "Medium" confidence literal in source, so this
            // states the real early/confident day thresholds instead.
            return "An estimate from heart data — not a medical measurement. It needs about 14 days before an early read appears and 28 for a confident baseline, and VO₂max stays \u{201c}preliminary\u{201d} until you've recorded a hard effort that measures your maximum heart rate."
        case .skinTemperature:
            return "A sleep-only relative signal, not core temperature and not a fever check. It is experimental, kept on your device, and never written to Health."
        case .bloodOxygen:
            return "\(AtriaSpO2Copy.wontFakeAPercentage) \(AtriaSpO2Copy.notAvailableOnStrap)"
        }
    }
}

/// The "About <metric>" education sheet (design spec §20).
///
/// A reusable template: a tinted glyph tile, an H1, a definition paragraph, a
/// "HOW ATRIA COMPUTES IT" card, and a "HONESTY NOTE" card tinted in the metric
/// hue. For a hardware-unavailable metric (blood oxygen) the middle card becomes
/// an honest "WHY IT'S BLANK" card carrying the canonical unavailable copy.
///
/// Self-contained so any metric detail surface can present it with local state,
/// and so it can be rendered straight to an image in a test.
struct AtriaAboutMetricSheet: View {
    let metric: AtriaAboutMetric
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
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

    private var glyphTile: some View {
        Image(systemName: metric.glyph)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(metric.tint)
            .frame(width: 52, height: 52)
            .background(AtriaIconTileBackground(cornerRadius: 16, tint: metric.tint))
            .accessibilityHidden(true)
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
