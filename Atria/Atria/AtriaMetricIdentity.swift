import SwiftUI

// One metric, one glyph, one hue — everywhere.
//
// `AtriaTodayMetric` (AtriaOverviewSections.swift) is the identity authority:
// it is the widest metric enum in the app (22 cases), it keys on the persisted
// card identity, and it already owns `label` and `systemImage`. This file adds
// the missing tint axis beside it and lets the two narrower tables —
// `AtriaMetricDetailKind` (14 cases) and `AtriaAboutMetric` (9) — delegate
// rather than restate.
//
// Why this exists (audit 2026-08-28, ten separate confirmed findings): three
// parallel tables covered symbol OR tint but never both, so screens drifted.
// Respiration and VO2max shared one glyph inside a single Vitals grid; Recovery
// wore the `heart.fill` that means Resting HR everywhere else; Resting HR was
// painted in HRV's warm family on four surfaces although Metrics.swift declares
// "RHR blue, clearly apart from HRV rose".
//
// Nothing here invents a look: every literal is the dominant one already on
// screen, or resolves a collision by moving the metric that had an alternative.
//
// Two axes, two rules:
//   * `systemImage` — a glyph is owned by exactly ONE metric.
//   * `identityTint` — the metric's IDENTITY hue, never its value. The two
//     metrics whose displayed hue legitimately encodes their reading declare it
//     through `usesValueGradedTint` instead of quietly diverging.
extension AtriaTodayMetric {

    /// The one identity hue per metric. `accent` supplies the user's chosen
    /// accent for the cards that are not metrics at all (`.insights`) and is
    /// ignored by every real metric.
    func identityTint(accent: Color = Metrics.electricGreen) -> Color {
        switch self {
        // Readiness green. Recovery's DISPLAYED hue is its 0-100 grade (see
        // `usesValueGradedTint`); this is its identity hue for legends,
        // settings headers and education sheets.
        case .recovery: return Metrics.electricGreen

        // Effort is always cool blue, never warm — a hard day must never read
        // as poor recovery (Metrics.swift).
        case .strain, .strainCompare, .load, .hrZones, .calories:
            return Metrics.electricStrain

        // Sleep owns purple so it stays distinct from strain.
        case .sleep, .sleepHistory, .sleepEfficiency, .sleepPerformance:
            return Metrics.electricSleep

        case .hrv: return Metrics.electricHRV
        // RHR blue — the documented rule the drifted surfaces broke.
        case .rhr, .trend: return Metrics.electricRHR

        // Respiration teal also carries skin temperature, by design.
        case .respiratoryRate, .bodyTemp: return Metrics.electricRespiratory

        case .stress: return Metrics.electricStress

        case .vo2max, .bioAge: return Metrics.electricGreen

        // Steps' displayed hue is its completeness grade
        // (`usesValueGradedTint`); green is its identity.
        case .steps: return Metrics.electricGreen

        case .workouts: return .mint

        // No verified decoder, so no confident hue: painting an unavailable
        // metric would imply a reading exists.
        case .bloodOxygen: return .secondary

        case .insights: return accent
        }
    }

    /// True for the metrics whose ON-SCREEN hue is their value, not their
    /// identity. Every OTHER surface must paint `identityTint` unchanged; a
    /// third member of this set is a bug, and the pin test says so.
    ///
    ///  * `.recovery` — its hue IS its 0-100 grade (red / yellow / green).
    ///  * `.steps` — its hue IS its coverage completeness; a partial count must
    ///    not wear a confident hue.
    var usesValueGradedTint: Bool {
        self == .recovery || self == .steps
    }
}

// MARK: - Bridges (the narrower tables delegate; they do not restate)

extension AtriaMetricDetailKind {
    /// The metric identity this detail route is a view of.
    var identity: AtriaTodayMetric {
        switch self {
        case .recovery: return .recovery
        case .hrv: return .hrv
        case .restingHeartRate: return .rhr
        case .respiratoryRate: return .respiratoryRate
        case .sleep: return .sleep
        case .strain: return .strain
        case .stress: return .stress
        case .vo2max: return .vo2max
        case .sleepPerformance: return .sleepPerformance
        case .sleepEfficiency: return .sleepEfficiency
        case .skinTemperature: return .bodyTemp
        case .fitnessAge: return .bioAge
        case .hrZones: return .hrZones
        case .bloodOxygen: return .bloodOxygen
        }
    }

    /// The glyph the card that opens this sheet already shows.
    var identitySystemImage: String { identity.systemImage }
}

extension AtriaAboutMetric {
    var identity: AtriaTodayMetric {
        switch self {
        case .hrv: return .hrv
        case .stress: return .stress
        case .recovery: return .recovery
        case .restingHeartRate: return .rhr
        case .respiration: return .respiratoryRate
        case .sleep: return .sleep
        case .vo2max: return .vo2max
        case .skinTemperature: return .bodyTemp
        case .bloodOxygen: return .bloodOxygen
        }
    }
}

// MARK: - Device chrome (state-keyed, deliberately NOT metrics)

/// Battery identity. State-keyed by design: the glyph names the charge level.
/// Both existing copies of this ladder were byte-identical, so this is a
/// de-duplication, not a re-look.
enum AtriaBatteryIdentity {
    static func systemImage(percent: Int, isCharging: Bool = false) -> String {
        if isCharging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Charge level is graded, never identity-tinted: green only while powered.
    static func tint(percent: Int, isPowered: Bool) -> Color {
        guard isPowered else { return .secondary }
        return percent < 13 ? .red : (percent < 38 ? .orange : .green)
    }
}
