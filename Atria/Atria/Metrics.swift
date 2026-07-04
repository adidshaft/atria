import SwiftUI
import UIKit

/// Industry-style headline metrics computed locally from strap data.
///
/// These are honest approximations of the proprietary scores:
/// - **Strain** supports Banister TRIMP and Edwards zone-weighted load,
///   each mapped to the 0–21 scale.
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

    /// Banister TRIMP over a series of (secondsFromStart, bpm) samples.
    /// Each sample contributes dt · HRr · 0.64 · e^(1.92·HRr).
    static func trimp(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> Double {
        AtriaAnalytics.Strain.trimp(series, rest: rest, max: max)
    }

    static func trimp(_ series: [(t: Double, bpm: Int)],
                      rest: Int,
                      max: Int,
                      sex: AthleteProfile.BiologicalSex) -> Double {
        AtriaAnalytics.Strain.trimp(series, rest: rest, max: max, sex: sex)
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
                                        maxGap: TimeInterval = 5 * 60) -> MaxHeartRateZoneSeconds {
        AtriaAnalytics.Strain.maxHeartRateZoneSeconds(series, maxHR: maxHR, maxGap: maxGap)
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
    }

    static func heartRateZone(bpm: Int, rest: Int, max: Int) -> HeartRateZone? {
        guard bpm > 0, max > rest else { return nil }
        let rawFraction = Double(bpm - rest) / Double(max - rest)
        let fraction = Swift.min(Swift.max(rawFraction, 0), 1)
        let index: Int
        switch fraction {
        case ..<0.30: index = 0
        case ..<0.50: index = 1
        case ..<0.70: index = 2
        case ..<0.80: index = 3
        case ..<0.90: index = 4
        default: index = 5
        }
        let names = ["Recovery", "Easy", "Endurance", "Tempo", "Hard", "Max"]
        return HeartRateZone(index: index,
                             title: "Zone \(index)",
                             shortLabel: "Z\(index)",
                             name: names[index],
                             reserveFraction: fraction,
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

    /// Map cumulative TRIMP to the 0–21 strain scale (saturating exponential).
    static func strain(fromTRIMP trimp: Double) -> Double {
        AtriaAnalytics.Strain.score(fromTRIMP: trimp)
    }

    static func strain(fromEdwardsLoad load: Double) -> Double {
        AtriaAnalytics.Strain.score(fromEdwardsLoad: load)
    }

    // MARK: Recovery (0–100 %)

    typealias RecoveryEstimate = AtriaAnalytics.Recovery.Estimate

    /// HR-only recovery: at/below baseline reads high; elevated resting reads low.
    static func recovery(restingNow: Int, baseline: Int) -> Int {
        AtriaAnalytics.Recovery.restingOnly(restingNow: restingNow, baseline: baseline)
    }

    /// HRV-driven recovery (the primary signal), blended with resting HR.
    /// HRV above your norm → high recovery; elevated resting HR penalizes it.
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
                           respiratoryRate: Double? = nil,
                           respiratoryBaseline: (mean: Double, sd: Double, count: Int)? = nil) -> RecoveryEstimate {
        AtriaAnalytics.Recovery.estimate(hrvSnapshot: hrvSnapshot,
                                         fallbackRMSSD: fallbackRMSSD,
                                         restingNow: restingNow,
                                         baseline: baseline,
                                         hrvReferenceValidated: hrvReferenceValidated,
                                         sleepEfficiency: sleepEfficiency,
                                         sleepDurationHours: sleepDurationHours,
                                         respiratoryRate: respiratoryRate,
                                         respiratoryBaseline: respiratoryBaseline)
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
