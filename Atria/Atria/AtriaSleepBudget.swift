import Foundation

enum AtriaSleepBudget {
    /// Minimum independent five-minute RR windows required before a sleep
    /// observation can contribute HRV evidence to any product surface.
    static let minimumQualifiedHRVWindows = 3
    /// Itemized sleep-need math (2026-07-07 design-handoff ledger): the same
    /// four terms sleepNeed() always combined, exposed so UI can show its work.
    struct NeedComponents: Equatable {
        let baseHours: Double
        let strainAdderHours: Double
        let debtAdderHours: Double
        let napCreditHours: Double
        let totalHours: Double

        /// True when the 6-10h clamp changed the raw sum.
        var isClamped: Bool {
            abs((baseHours + strainAdderHours + debtAdderHours - napCreditHours) - totalHours) > 0.005
        }
    }

    /// Durable, Codable receipt for the Sleep Need that was shown when a
    /// main-sleep record settled.  Keeping the inputs alongside the total lets
    /// the ledger explain *that night's* target without recalculating with a
    /// later baseline, strain, or debt history.
    struct FrozenNeed: Codable, Equatable {
        let baseHours: Double
        let strainAdderHours: Double
        let debtAdderHours: Double
        let napCreditHours: Double
        let totalHours: Double

        init(_ components: NeedComponents) {
            baseHours = components.baseHours
            strainAdderHours = components.strainAdderHours
            debtAdderHours = components.debtAdderHours
            napCreditHours = components.napCreditHours
            totalHours = components.totalHours
        }

        var seconds: TimeInterval { totalHours * 3_600 }

        var components: NeedComponents {
            NeedComponents(baseHours: baseHours,
                           strainAdderHours: strainAdderHours,
                           debtAdderHours: debtAdderHours,
                           napCreditHours: napCreditHours,
                           totalHours: totalHours)
        }
    }

    static func sleepNeedComponents(baseHours: Double,
                                    yesterdayStrain: Double?,
                                    debtHours: Double,
                                    sameDayNapHours: Double) -> NeedComponents {
        let safeBase = min(max(baseHours, 6), 10)
        // Recent-strain sleep-need addition, continuous (WHOOP-style) instead of
        // the old binary "+30 min above strain 14" step. Anchored to WHOOP's
        // published "a 15.0 Day Strain adds ~37 min of Sleep Need": scale linearly
        // from ~0 at strain 8 (a light day needs no extra) up the 0–21 scale, so a
        // hard day (15) adds 37 min and an all-out day (21) adds ~69 min. The 8.0
        // floor tracks the recalibrated strain scale (light all-day ≈ 8–9).
        let strainAdder = max(0, min(yesterdayStrain ?? 0, 21) - 8.0) * (0.62 / 7.0)
        let debtAdder = max(0, debtHours) * 0.5
        let napCredit = max(0, sameDayNapHours) * 0.9
        let total = min(max(safeBase + strainAdder + debtAdder - napCredit, 6), 10)
        return NeedComponents(baseHours: safeBase,
                              strainAdderHours: strainAdder,
                              debtAdderHours: debtAdder,
                              napCreditHours: napCredit,
                              totalHours: total)
    }

    static func sleepNeed(baseHours: Double,
                          yesterdayStrain: Double?,
                          debtHours: Double,
                          sameDayNapHours: Double) -> Double {
        sleepNeedComponents(baseHours: baseHours,
                            yesterdayStrain: yesterdayStrain,
                            debtHours: debtHours,
                            sameDayNapHours: sameDayNapHours).totalHours
    }

    static func sleepDebt(nights: [(needed: Double, slept: Double)]) -> Double {
        let recent = nights.suffix(7)
        guard !recent.isEmpty else { return 0 }
        let count = recent.count
        return recent.enumerated().reduce(0) { total, item in
            let ageFromNewest = count - item.offset - 1
            let decay = pow(0.75, Double(ageFromNewest))
            let shortfall = max(0, item.element.needed - item.element.slept)
            return total + shortfall * decay
        }
    }

    static func performancePercent(slept: Double, needed: Double) -> Int {
        guard needed > 0 else { return 0 }
        return min(max(Int(((slept / needed) * 100).rounded()), 0), 100)
    }
}

/// GAP-06 — the current-generation composite Atria Sleep Score.
///
/// It is INTENTIONALLY and permanently provisional under the current model:
/// WHOOP does not publish its weights and Atria has not validated its own, and
/// the overnight physiological-load component (GAP-10) is not validated, so it
/// never contributes. The result must always be presented in an explicit
/// provisional state — never as an equivalent to a validated four-component
/// score.
///
/// Honesty rules enforced here (from the handoff's qualification behavior):
/// - A component contributes only when it is independently displayable for the
///   night. A `nil` input is treated as missing, never as a population constant.
/// - Missing components are reported so the UI can show them as missing.
/// - The composite requires at least `minimumPresentComponents` present
///   components; with only Sufficiency, callers keep showing "Sleep
///   Sufficiency", not a composite relabelled from a single number.
/// - The final score and every component value are retained so the result is
///   reproducible from frozen inputs.
struct AtriaSleepScore: Equatable, Codable {
    enum Component: String, Codable, CaseIterable {
        case sufficiency
        case consistency
        case efficiency
        case overnightLoad

        /// Provisional, unvalidated weight. These are engineering placeholders,
        /// not a validated model, and must be surfaced as provisional.
        var provisionalWeight: Double {
            switch self {
            case .sufficiency: return 0.50
            case .consistency: return 0.25
            case .efficiency: return 0.15
            case .overnightLoad: return 0.10
            }
        }

        var label: String {
            switch self {
            case .sufficiency: return "Sufficiency"
            case .consistency: return "Consistency"
            case .efficiency: return "Efficiency"
            case .overnightLoad: return "Overnight load"
            }
        }
    }

    struct ComponentValue: Equatable, Codable {
        let component: Component
        /// 0...100 when the component is independently displayable for this
        /// night, else nil (missing — never substituted with a constant).
        let percent: Double?
        var isPresent: Bool { percent != nil }
    }

    /// Minimum present components before any composite is shown. Below this,
    /// callers keep showing Sleep Sufficiency on its own rather than relabelling
    /// a single number as a composite.
    static let minimumPresentComponents = 2

    let components: [ComponentValue]
    /// Provisional composite (0...100). Nil when fewer than
    /// `minimumPresentComponents` components are present for the night.
    let score: Int?
    /// Always true under the current model (weights unvalidated; overnight-load
    /// model unvalidated). A validated model would set this false.
    let isProvisional: Bool

    var presentComponents: [Component] { components.filter(\.isPresent).map(\.component) }
    var missingComponents: [Component] { components.filter { !$0.isPresent }.map(\.component) }

    /// Builds the composite from independently-displayable component percents.
    /// Pass nil for any component that is not displayable for this night; a nil
    /// is treated as missing and can never influence the score.
    ///
    /// `validatedOvernightLoadPercent` exists for when GAP-10 is validated; it
    /// must stay nil until then so the unvalidated HR-only projection can never
    /// silently enter the score.
    static func make(sufficiencyPercent: Double?,
                     consistencyPercent: Double?,
                     efficiencyPercent: Double?,
                     validatedOvernightLoadPercent: Double?) -> AtriaSleepScore {
        func clamp(_ value: Double?) -> Double? { value.map { min(max($0, 0), 100) } }
        let values: [ComponentValue] = [
            ComponentValue(component: .sufficiency, percent: clamp(sufficiencyPercent)),
            ComponentValue(component: .consistency, percent: clamp(consistencyPercent)),
            ComponentValue(component: .efficiency, percent: clamp(efficiencyPercent)),
            ComponentValue(component: .overnightLoad, percent: clamp(validatedOvernightLoadPercent))
        ]
        let present = values.filter(\.isPresent)
        let score: Int?
        if present.count >= minimumPresentComponents {
            // Renormalize the provisional weights over only the present
            // components. This is an explicitly provisional presentation, not a
            // claim of equivalence to the full four-component score.
            let totalWeight = present.reduce(0.0) { $0 + $1.component.provisionalWeight }
            let weighted = present.reduce(0.0) { $0 + ($1.percent ?? 0) * $1.component.provisionalWeight }
            score = totalWeight > 0 ? Int((weighted / totalWeight).rounded()) : nil
        } else {
            score = nil
        }
        return AtriaSleepScore(components: values, score: score, isProvisional: true)
    }
}
