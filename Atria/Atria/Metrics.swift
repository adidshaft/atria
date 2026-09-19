import SwiftUI
import UIKit

/// MetricAuthority — the single-authority and fail-closed contract for every
/// user-facing metric. This block is the central policy the scattered
/// per-algorithm comments defer to; new metrics and new consumers must obey it.
///
/// **One authority per concept.** Each metric has exactly one canonical
/// calculation, and every surface (chart, ledger, detail sheet, accessibility
/// text, widget, intent, notification) consumes that one result:
/// - **Recovery**: `Metrics.recoveryV2` /
///   `AtriaAnalytics.Recovery.estimate(hrvSnapshot:...)`, or a
///   `FrozenRecoverySummary` minted by it and replayed verbatim. The deprecated
///   ungated estimators (`recovery(restingNow:)`, `recovery(hrvNow:)`) must
///   never reach a view; a guard test pins their call sites.
/// - **Strain**: kernel in `AtriaStrainLoadModel` (Banister TRIMP, HRR form);
///   whether a day total may present as exact is decided only by
///   `Metrics.StrainPresentation.resolve`.
/// - **Sleep Need**: `AtriaSleepBudget.sleepNeedComponents`; historical nights
///   read only their settlement-frozen `FrozenNeed` receipt — never a
///   recomputation with today's baseline, debt, or strain.
/// - **Sleep Consistency**: `AtriaSleepConsistency.result` is the only engine;
///   score, strip visual, trend, and copy all consume the same result object.
/// - **Heart-rate zones**: HRR boundaries
///   (`restingHR + fraction × (maxHR − restingHR)`), frozen per completed
///   workout via `AtriaHRRZoneBoundaries`; later profile edits never rewrite
///   a completed workout's boundaries.
/// - **Current cycle vs dated history**: owned by `AtriaHealthMetricAuthority`
///   (AtriaHealthScreen.swift).
///
/// **Fail-closed rules.** Missing evidence produces a gap, a limited-confidence
/// label, or no score — never a fabricated number:
/// - Never promote HRV from heart-rate-only data.
/// - Never display SpO2 or absolute skin temperature until the docs/14
///   validation protocol passes; display is gated by `AtriaResearchProbe`'s
///   validated-decoder flags, which are hard-false today.
/// - Never substitute population averages for a missing personal baseline.
/// - Never silently recompute frozen historical values (Recovery, Sleep Need,
///   zone boundaries) with later profile data.
///
/// **New metrics** must declare a confidence tier and provenance before they
/// ship; see docs/16-metric-authority-and-confidence-policy.md.
enum MetricAuthority {}

/// Industry-style headline metrics computed locally from strap data.
///
/// These are independent local metrics, not replicas of proprietary scores:
/// - **Strain** is Atria's personalized cardiovascular-load model, with
///   Banister TRIMP and Edwards zone load mapped onto Atria's 0–21 display.
/// - **Recovery** uses the user's own ready RR/HRV data once enough personal
///   baseline exists, and labels the result honestly until reference validated.
enum Metrics {

    // MARK: Daily aggregation

    typealias StrapStepSample = AtriaAnalytics.Daily.StrapStepSample
    typealias StrapStepSummary = AtriaAnalytics.Daily.StrapStepSummary
    typealias HeartRateEnergySample = AtriaAnalytics.Daily.HeartRateEnergySample

    static func stepsDaily(_ samples: [StrapStepSample]) -> StrapStepSummary {
        AtriaAnalytics.Daily.stepsDaily(samples)
    }

    static func dayCalories(_ samples: [HeartRateEnergySample],
                            rest: Int,
                            profile: AthleteProfile) -> Double? {
        AtriaAnalytics.Daily.dayCalories(samples, rest: rest, profile: profile)
    }

    // MARK: Strain (0–21)

    /// Banister TRIMP over a series of (secondsFromStart, bpm) samples, using
    /// the legacy male parameters when biological sex is unavailable.
    static func trimp(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> Double {
        AtriaAnalytics.Strain.trimp(series, rest: rest, max: max)
    }

    static func trimp(_ series: [(t: Double, bpm: Int)],
                      rest: Int,
                      max: Int,
                      sex: AthleteProfile.BiologicalSex) -> Double {
        AtriaAnalytics.Strain.trimp(series, rest: rest, max: max, sex: sex)
    }

    static func dailyLoadTRIMP(_ series: [(t: Double, bpm: Int)],
                               rest: Int,
                               max: Int,
                               sex: AthleteProfile.BiologicalSex) -> Double {
        AtriaAnalytics.Strain.dailyTRIMP(series, rest: rest, max: max, sex: sex)
    }

    static func edwardsLoad(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> Double {
        AtriaAnalytics.Strain.edwardsLoad(series, rest: rest, max: max)
    }

    static func activeCalories(_ samples: [HRSample], rest: Int, profile: AthleteProfile) -> Double? {
        AtriaAnalytics.Strain.activeCalories(samples, rest: rest, profile: profile)
    }

    typealias MaxHeartRateZoneSeconds = AtriaAnalytics.Strain.MaxHeartRateZoneSeconds

    static func maxHeartRateZoneSeconds(_ series: [(t: Double, bpm: Int)],
                                        maxHR: Int,
                                        restingHR: Int? = nil,
                                        maxGap: TimeInterval = AtriaAnalytics.Strain.maximumLoadEvidenceGap) -> MaxHeartRateZoneSeconds {
        AtriaAnalytics.Strain.maxHeartRateZoneSeconds(series, maxHR: maxHR, restingHR: restingHR, maxGap: maxGap)
    }

    typealias StrainZoneSummary = AtriaAnalytics.Strain.ZoneSummary

    /// HR-reserve zone seconds for auditing Strain behavior across rest to max.
    /// Buckets: z0 <30%, z1 30-50%, z2 50-70%, z3 70-85%, z4 >=85% HR reserve.
    static func strainZoneSummary(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> StrainZoneSummary {
        AtriaAnalytics.Strain.zoneSummary(series, rest: rest, max: max)
    }

    struct HeartRateZone: Equatable, Identifiable {
        let index: Int
        let title: String
        let shortLabel: String
        let name: String
        let reserveFraction: Double
        let tint: Color

        var id: Int { index }
        /// Compact zone text for a pill: "Below Z1" at rest, else "Z3 Aerobic",
        /// the live-workout grammar. The Today pill used to print
        /// "Zone Z0" (phone 2026-09-02): the word and the letter said the
        /// same thing twice.
        var compactLabel: String { index == 0 ? "Below Z1" : "\(shortLabel) \(name)" }
        /// The same zone for VoiceOver, in words.
        var spokenLabel: String { index == 0 ? "Below zone 1" : "Zone \(index), \(name)" }
    }

    static func heartRateZone(bpm: Int, rest: Int, max: Int) -> HeartRateZone? {
        guard bpm > 0, max > rest else { return nil }
        // GAP-03: every user-visible zone derives from heart-rate reserve
        // (restingHR + fraction × HRR) via the same HRZone boundaries the live
        // workout screen, Live Activity, widget, and haptics use — one BPM can
        // never display different zones on different surfaces, and the zone
        // index always agrees with the load model's HRR lens.
        let rawReserveFraction = Double(bpm - rest) / Double(max - rest)
        let reserveFraction = Swift.min(Swift.max(rawReserveFraction, 0), 1)
        let zone = HRZone.zone(for: bpm, maxHR: max, restingHR: rest)
        let index = zone.rawValue
        return HeartRateZone(index: index,
                             title: "Zone \(index)",
                             shortLabel: "Z\(index)",
                             name: zone.name,
                             reserveFraction: reserveFraction,
                             tint: heartRateZoneTint(index))
    }

    static func heartRateZoneTint(_ index: Int) -> Color {
        switch index {
        case 0: return .secondary
        case 1: return electricStrain
        case 2: return electricGreen
        case 3: return electricYellow
        case 4: return .orange
        default: return electricRed
        }
    }

    /// Map cumulative cardiovascular load through Atria's monotonic, bounded
    /// 0–21 display calibration. This is not WHOOP's proprietary equation.
    static func strain(fromTRIMP trimp: Double) -> Double {
        AtriaAnalytics.Strain.score(fromTRIMP: trimp)
    }

    static func strain(fromEdwardsLoad load: Double) -> Double {
        AtriaAnalytics.Strain.score(fromEdwardsLoad: load)
    }

    // MARK: Recovery (0–100 %)

    typealias RecoveryEstimate = AtriaAnalytics.Recovery.Estimate

    /// HR-only recovery: at/below baseline reads high; elevated resting reads low.
    /// Deprecated: returns a bare percent with no confidence tier or honesty
    /// gating. Production surfaces must use `recoveryV2`, which fails closed
    /// on missing baselines and labels every estimate's confidence.
    @available(*, deprecated, message: "Use recoveryV2 — this legacy path has no confidence tier or honesty gating")
    static func recovery(restingNow: Int, baseline: Int) -> Int {
        AtriaAnalytics.Recovery.restingOnly(restingNow: restingNow, baseline: baseline)
    }

    /// HRV-driven recovery (the primary signal), blended with resting HR.
    /// HRV above your norm → high recovery; elevated resting HR penalizes it.
    /// Deprecated: same ungated-legacy caveat as `recovery(restingNow:baseline:)`.
    @available(*, deprecated, message: "Use recoveryV2 — this legacy path has no confidence tier or honesty gating")
    static func recovery(hrvNow: Int, hrvBaseline: Int, restingNow: Int, restingBaseline: Int) -> Int {
        AtriaAnalytics.Recovery.estimate(hrvNow: hrvNow,
                                         hrvBaseline: hrvBaseline,
                                         restingNow: restingNow,
                                         restingBaseline: restingBaseline)
    }

    /// Recovery v2: lnRMSSD z-score against a personal rolling baseline, blended
    /// with resting-HR z-score and saved sleep evidence. Recovery displays after
    /// local data sufficiency; external reference validation upgrades the
    /// confidence tier and HealthKit writes, but does not block in-app display.
    static func recoveryV2(hrvSnapshot: HRVSnapshot?, fallbackRMSSD: Int?,
                           restingNow: Int?, baseline: PersonalBaseline,
                           hrvReferenceValidated: Bool = false,
                           sleepEfficiency: Double? = nil,
                           sleepDurationHours: Double? = nil,
                           sleepBaseline: AtriaAnalytics.Recovery.SleepBaselineStats? = nil,
                           respiratoryRate: Double? = nil,
                           respiratoryBaseline: (mean: Double, sd: Double, count: Int)? = nil,
                           now: Date = Date()) -> RecoveryEstimate {
        AtriaAnalytics.Recovery.estimate(hrvSnapshot: hrvSnapshot,
                                         fallbackRMSSD: fallbackRMSSD,
                                         restingNow: restingNow,
                                         baseline: baseline,
                                         hrvReferenceValidated: hrvReferenceValidated,
                                         sleepEfficiency: sleepEfficiency,
                                         sleepDurationHours: sleepDurationHours,
                                         sleepBaseline: sleepBaseline,
                                         respiratoryRate: respiratoryRate,
                                         respiratoryBaseline: respiratoryBaseline,
                                         now: now)
    }

    /// One authority for deciding whether cumulative strain may be presented as
    /// an exact day total. Strain is an integral over observed strap HR, so a
    /// result with missing time remains useful as a lower bound but is not an
    /// exact whole-day value.
    enum StrainEvidenceQuality: String, Codable, Equatable, Sendable {
        case exact
        case partial
        case unavailable
    }

    /// WHOOP's published strain vocabulary (support docs, fetched 2026-08-05):
    /// Light 0–9 · Moderate 10–13 · High 14–17 · All Out 18–21. Shared so the
    /// detail sheet, coach copy and any future band chip agree.
    static func strainBandName(_ strain: Double) -> String {
        switch strain {
        case ..<10: return "Light"
        case ..<14: return "Moderate"
        case ..<18: return "High"
        default: return "All Out"
        }
    }

    struct StrainPresentation: Equatable {
        /// Missing less than five percent is the strongest practical coverage
        /// tier. This matches the product's ~95% real-world accuracy target
        /// without treating ordinary sub-second packet loss as a failed day.
        static let strongCoverageThreshold = 0.95

        let value: Double?
        let coverageFraction: Double?
        let quality: StrainEvidenceQuality
        let confidence: String

        static func resolve(value: Double?,
                            coverageFraction: Double?,
                            baseConfidence: String,
                            additionalIncompleteEvidence: Bool = false,
                            persistedQuality: StrainEvidenceQuality? = nil) -> Self {
            let normalizedCoverage = coverageFraction.map { min(1, max(0, $0)) }
            let computable = value.map { $0.isFinite && $0 >= 0 } == true
                && !baseConfidence.localizedCaseInsensitiveContains("learning")
                && !baseConfidence.localizedCaseInsensitiveContains("standby")
            guard computable else {
                return Self(value: nil,
                            coverageFraction: normalizedCoverage,
                            quality: .unavailable,
                            confidence: baseConfidence)
            }

            // A legacy persisted number has no proof that its full day was
            // observed. Preserve it as a lower bound instead of silently
            // upgrading it to exact after relaunch.
            let quality: StrainEvidenceQuality
            if persistedQuality == .unavailable {
                quality = .unavailable
            } else if persistedQuality == .partial
                        || additionalIncompleteEvidence
                        || normalizedCoverage.map({ $0 < strongCoverageThreshold }) == true {
                quality = .partial
            } else if persistedQuality == .exact
                        || normalizedCoverage.map({ $0 >= strongCoverageThreshold }) == true
                        || normalizedCoverage == nil {
                quality = .exact
            } else {
                quality = .partial
            }

            let resolvedConfidence: String
            if quality == .partial,
               !baseConfidence.localizedCaseInsensitiveContains("partial") {
                resolvedConfidence = baseConfidence + " · partial"
            } else {
                resolvedConfidence = baseConfidence
            }
            return Self(value: quality == .unavailable ? nil : value,
                        coverageFraction: normalizedCoverage,
                        quality: quality,
                        confidence: resolvedConfidence)
        }

        var valueText: String {
            guard let value else { return AtriaCompactMetricPresentation.noValue }
            // The "≥" lower-bound marker was removed 2026-08-27 at the owner's
            // request, matching the decision already made for steps. Partialness
            // is still stated in words: `coverageText` below prints
            // "Partial · N% tracked", and `quality`/`confidence` remain the
            // machine-readable truth for every consumer.
            return String(format: "%.1f", value)
        }

        var coverageText: String? {
            guard quality == .partial, let coverageFraction else { return nil }
            return "Partial · \(Int((coverageFraction * 100).rounded()))% tracked"
        }
    }

    /// WHOOP-style electric readiness palette. Vivid on dark (where WHOOP lives),
    /// deepened on light so the same band stays legible — Atria supports both modes.
    private static func adaptive(dark: (Double, Double, Double),
                                 light: (Double, Double, Double)) -> Color {
        Color(UIColor { trait in
            let c = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// Electric green (#16EC06 on dark), the "in the green" readiness signal.
    static let electricGreen = adaptive(dark: (0.086, 0.925, 0.024), light: (0.039, 0.60, 0.0))
    /// Electric amber (#FFDE00 on dark), deepened to gold on light for contrast.
    static let electricYellow = adaptive(dark: (1.0, 0.871, 0.0), light: (0.72, 0.52, 0.0))
    /// Electric red (#FF0026 on dark).
    static let electricRed = adaptive(dark: (1.0, 0.0, 0.149), light: (0.83, 0.0, 0.13))
    /// Electric strain blue (#0093E7) — effort is always cool, never warm, so a hard
    /// session can't be misread as poor recovery.
    static let electricStrain = adaptive(dark: (0.0, 0.576, 0.906), light: (0.0, 0.46, 0.75))
    /// Electric sleep indigo — sleep owns purple so it stays distinct from strain.
    static let electricSleep = adaptive(dark: (0.51, 0.35, 1.0), light: (0.39, 0.25, 0.78))

    /// "Close your rings" achievement coloring (2026-07-08, user request): a
    /// progress ring warms from orange → yellow → green as it fills, landing on
    /// green the moment it reaches its target so a completed day reads as a
    /// win. `fill` is progress toward the metric's OWN target (>= 1.0 = reached);
    /// nil = not computed yet (neutral). Recovery keeps its own %-band green,
    /// which uses the same green, so an all-good day shows three green rings.
    static func ringAchievementTint(fill: Double?) -> Color {
        guard let fill else { return .secondary }
        if fill >= 1 { return .green }
        if fill >= 0.6 { return .yellow }
        return .orange
    }

    // Secondary-vital identity hues. Each metric owns ONE hue (the "one hue per
    // metric" rule) drawn from the design-handoff palette, and — like the bands
    // above — is deepened on light so a tinted chip/number stays legible on
    // white (raw SwiftUI `.pink`/`.teal`/`.orange` wash out there). Before this,
    // HRV+RHR both rendered `.pink` and respiration+skin-temp both `.teal`, so
    // distinct vitals were indistinguishable and low-contrast in light mode.
    /// Resting-HR sky blue (#64D2FF on dark) — cool, distinct from HRV's rose.
    static let electricRHR = adaptive(dark: (0.392, 0.824, 1.0), light: (0.0, 0.44, 0.68))
    /// HRV rose/magenta — warm heart-derived hue, clearly apart from RHR blue.
    static let electricHRV = adaptive(dark: (1.0, 0.36, 0.62), light: (0.80, 0.09, 0.40))
    /// Respiration teal (#00C7BE on dark) — also carries skin temperature.
    static let electricRespiratory = adaptive(dark: (0.0, 0.78, 0.745), light: (0.0, 0.49, 0.46))
    /// Stress amber (#FF9F0A on dark), deepened to a readable amber on light.
    static let electricStress = adaptive(dark: (1.0, 0.624, 0.039), light: (0.80, 0.42, 0.0))

    /// Heart-rate traces encode LEVEL in the stroke: cool at the bottom of the
    /// plot, warm at the top. Shared so every HR chart in the app speaks one
    /// visual language — the Vitals timeline used this ramp while the Activity
    /// live monitor hardcoded a flat red→orange, so the same metric read as
    /// two different things depending on the tab (owner report 2026-08-25).
    static let heartRateIntensityGradient = LinearGradient(stops: [
        .init(color: .cyan, location: 0),
        .init(color: .green, location: 0.38),
        .init(color: .orange, location: 0.68),
        .init(color: .red, location: 1)
    ], startPoint: .bottom, endPoint: .top)

    static let heartRateIntensityAreaGradient = LinearGradient(stops: [
        .init(color: .cyan.opacity(0.12), location: 0),
        .init(color: .green.opacity(0.10), location: 0.38),
        .init(color: .orange.opacity(0.08), location: 0.68),
        .init(color: .red.opacity(0.12), location: 1)
    ], startPoint: .bottom, endPoint: .top)

    static func recoveryColor(_ pct: Int) -> Color {
        switch pct {
        case 67...: return electricGreen
        case 34..<67: return electricYellow
        default: return electricRed
        }
    }

    static func strainColor(_ s: Double) -> Color {
        // Effort is one cool electric blue at every intensity — never warm or red, so
        // a hard session can't be misread as poor recovery (recovery owns the
        // green/amber/red axis). Magnitude is conveyed by the ring fill, not the hue.
        electricStrain
    }
}
