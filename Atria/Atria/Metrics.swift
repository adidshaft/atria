import SwiftUI

/// Industry-style headline metrics computed locally from strap data.
///
/// These are honest approximations of the proprietary scores:
/// - **Strain** uses Banister's TRIMP (training impulse) mapped to the 0–21 scale.
/// - **Recovery** uses the user's own ready RR/HRV data once enough personal
///   baseline exists, and labels the result honestly until reference validated.
enum Metrics {

    // MARK: Strain (0–21)

    /// Banister TRIMP over a series of (secondsFromStart, bpm) samples.
    /// Each sample contributes dt · HRr · 0.64 · e^(1.92·HRr).
    static func trimp(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> Double {
        AtriaAnalytics.Strain.trimp(series, rest: rest, max: max)
    }

    static func activeCalories(_ samples: [HRSample], rest: Int, profile: AthleteProfile) -> Double? {
        AtriaAnalytics.Strain.activeCalories(samples, rest: rest, profile: profile)
    }

    typealias StrainZoneSummary = AtriaAnalytics.Strain.ZoneSummary

    /// HR-reserve zone seconds for auditing Strain behavior across rest to max.
    /// Buckets: z0 <30%, z1 30-50%, z2 50-70%, z3 70-85%, z4 >=85% HR reserve.
    static func strainZoneSummary(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> StrainZoneSummary {
        AtriaAnalytics.Strain.zoneSummary(series, rest: rest, max: max)
    }

    /// Map cumulative TRIMP to the 0–21 strain scale (saturating exponential).
    static func strain(fromTRIMP trimp: Double) -> Double {
        AtriaAnalytics.Strain.score(fromTRIMP: trimp)
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

    static func recoveryColor(_ pct: Int) -> Color {
        switch pct {
        case 67...: return .green
        case 34..<67: return .yellow
        default: return .red
        }
    }

    static func strainColor(_ s: Double) -> Color {
        switch s {
        case ..<8: return .blue
        case 8..<14: return .teal
        case 14..<18: return .orange
        default: return .red
        }
    }
}
