import Foundation

enum AtriaSleepBudget {
    /// Minimum independent five-minute RR windows required before a sleep
    /// observation can contribute HRV evidence to any product surface.
    static let minimumQualifiedHRVWindows = 3

    /// Upper bound (hours) on accumulated sleep debt fed into any downstream
    /// calculation. Set to ~one night's need: lost sleep is only partially
    /// recoverable, so debt must not grow without bound and inflate tonight's
    /// Sleep Need indefinitely across a long run of short nights.
    ///
    /// VALIDATION-GATED: 8.0h is an engineering cap, not a clinically validated
    /// recovery ceiling; it awaits calibration against real multi-night data.
    ///
    /// STRUCTURAL BASIS ONLY: WHOOP's sleep-need patent (US20240252121A1)
    /// describes a debt term that is scaled AND capped. Atria independently
    /// adopts the "capped" structure with its own value; it does NOT reproduce
    /// any undisclosed WHOOP coefficient.
    static let maxSleepDebtHours: Double = 8.0
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

    /// Assessment P1.8 (2026-08-14): raw daily TRIMP is the stored truth; the
    /// 0–21 number is a versioned display skin. The strain adder therefore
    /// consumes yesterday's TRIMP through the ONE display authority
    /// (AtriaStrainLoadModel.displayScore, calibration v3: S = 21(1−e^(−T/150)))
    /// and then the existing published anchor — 15.0 display strain ≈ +37 min
    /// (equivalent TRIMP anchor T₁₅ = −150·ln(1−15/21) ≈ 187.9, floor
    /// T₈ ≈ 71.9 → +0). The labeled 37-min-at-15 mapping is unchanged; only
    /// the input becomes truth-first. `yesterdayStrainFallback` exists solely
    /// for legacy rows whose dayTRIMP was never persisted — never reconstruct
    /// a missing TRIMP (same rule as a missing frozen need).
    static func sleepNeedComponents(baseHours: Double,
                                    yesterdayTRIMP: Double?,
                                    yesterdayStrainFallback: Double?,
                                    debtHours: Double,
                                    sameDayNapHours: Double) -> NeedComponents {
        let effectiveStrain = yesterdayTRIMP
            .flatMap { $0.isFinite && $0 > 0 ? AtriaStrainLoadModel.displayScore(fromLoad: $0) : nil }
            ?? yesterdayStrainFallback
        return sleepNeedComponents(baseHours: baseHours,
                                   yesterdayStrain: effectiveStrain,
                                   debtHours: debtHours,
                                   sameDayNapHours: sameDayNapHours)
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
        // Defensively clamp the debt input to the same cap the accumulator
        // applies, so a stale or externally supplied debt value can never
        // inflate the need beyond the validated-gated bound (see
        // `maxSleepDebtHours`).
        let debtAdder = min(max(0, debtHours), maxSleepDebtHours) * 0.5
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
        let accumulated = recent.enumerated().reduce(0.0) { total, item in
            let ageFromNewest = count - item.offset - 1
            let decay = pow(0.75, Double(ageFromNewest))
            let shortfall = max(0, item.element.needed - item.element.slept)
            return total + shortfall * decay
        }
        // Clamp the recency-decayed accumulation to the validated-gated cap so a
        // long run of short nights cannot compound into an unbounded debt.
        return min(accumulated, maxSleepDebtHours)
    }

    static func performancePercent(slept: Double, needed: Double) -> Int {
        guard needed > 0 else { return 0 }
        return min(max(Int(((slept / needed) * 100).rounded()), 0), 100)
    }
}

/// GAP-07 — the user's typical overnight range, overlaid behind the overnight
/// HR trace. It is the typical band of the resting heart rate Atria already
/// measures each night (an overnight-derived value), not an inferred per-minute
/// curve, and it stays hidden until a documented minimum of qualified nights.
enum AtriaOvernightTypical {
    /// Documented minimum qualified nights before a typical band is shown.
    static let minimumQualifiedNights = 14

    /// Mean ± 1 SD band of recent qualified nights' resting heart rate. Nil
    /// until `minimumNights` plausible values are available — never a band drawn
    /// from too little evidence.
    static func restingBand(restingHRs: [Int],
                            minimumNights: Int = minimumQualifiedNights) -> ClosedRange<Double>? {
        let values = restingHRs.filter { (30...120).contains($0) }.map(Double.init)
        guard values.count >= minimumNights else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let sd = variance.squareRoot()
        let low = max(30, mean - sd)
        let high = mean + sd
        guard high > low else { return nil }
        return low...high
    }
}

/// P7 (2026-08-20 sleep-stage design, Track 2 §2.1) — per-stage "typical
/// range" baseline for the WHOOP-style stage rows: for each display stage,
/// the mean ± 1 SD band of that stage's per-night duration across the user's
/// recent qualified nights.
///
/// ±1 SD is a deliberate choice, documented here at the definition: it
/// matches the sleep-surface precedent directly above
/// (`AtriaOvernightTypical.restingBand`, also mean ± 1 SD) rather than the
/// vitals ±1.5 SD grammar — these bands render on the same sleep detail
/// surfaces as the resting band, and "typical" must mean one thing there.
///
/// Baseline honesty (binding):
/// - Only nights that are `.confirmed`, are main sleep (`!isNapEvidence`),
///   and carry validated motion evidence may seed the baseline.
/// - HR-only ESTIMATE nights NEVER seed it: estimated stage boundaries must
///   not become the yardstick later nights are measured against. This is
///   enforced beyond the motion-evidence predicate — a night whose evidence
///   resolved to `.hrOnlyEstimate` (estimate-prefixed segment ids) is
///   excluded even when a contradictory legacy record also claims
///   `motionValidated == true`.
/// - Hidden below `minimumQualifiedNights` qualified nights — the same
///   documented 14-night floor as `AtriaOvernightTypical`, referenced (not
///   re-typed) so the sleep surfaces keep exactly one such constant.
/// - Pure and read-only over `Night` values: it never touches stored
///   records, and in particular never reads or rewrites the frozen
///   sleep-need receipts (`AtriaSleepBudget.FrozenNeed` stays untouched).
enum AtriaStageTypicalRange {
    /// Documented minimum qualified nights before any typical band is shown
    /// (the existing sleep-surface constant precedent, AtriaOvernightTypical).
    static let minimumQualifiedNights = AtriaOvernightTypical.minimumQualifiedNights

    /// The baseline looks back over at most this many most-recent nights of
    /// history, so a months-old sleep pattern ages out of "typical".
    static let recencyWindowNights = 30

    /// Whether one night may seed the baseline. See the honesty rules at the
    /// type definition; the `.hrOnlyEstimate` exclusion is what keeps a
    /// contradictory `motionValidated == true` flag on an estimate-provenance
    /// night from smuggling estimated durations into the yardstick. A night
    /// with no displayed stage timeline (e.g. a motion-ready rollup that never
    /// staged) also cannot seed — counting it as zero minutes of every stage
    /// would silently drag the baseline down.
    static func qualifies(_ night: SleepHistorySnapshot.Night) -> Bool {
        night.confirmed
            && !night.isNapEvidence
            && night.hasValidatedMotionEvidence
            && night.stageEvidence != .hrOnlyEstimate
            && !night.displayStageSegments.isEmpty
    }

    /// Per-display-stage typical bands (seconds) over the qualified nights
    /// inside the recent-`recencyWindowNights` window, or nil while fewer
    /// than `minimumNights` qualified nights exist — never a band drawn from
    /// too little evidence. Recency is applied first, qualification second
    /// (the window is the user's last 30 nights of history; only the
    /// qualified ones inside it seed). Snapshot producers differ on array
    /// order (some are newest-first), so recency sorts explicitly instead of
    /// trusting input order. A stage whose band is degenerate (identical on
    /// every seeding night, SD 0) is omitted rather than drawn zero-width.
    static func ranges(nights: [SleepHistorySnapshot.Night],
                       minimumNights: Int = minimumQualifiedNights)
        -> [SleepStageKind: ClosedRange<TimeInterval>]? {
        let recent = nights
            .sorted { $0.reviewReferenceDate < $1.reviewReferenceDate }
            .suffix(recencyWindowNights)
        let qualified = recent.filter(qualifies)
        guard qualified.count >= minimumNights else { return nil }
        var ranges: [SleepStageKind: ClosedRange<TimeInterval>] = [:]
        for stage in SleepStageKind.displayOrder {
            // `stageDuration` reads the night's display durations, which are
            // already SWS→deep folded — the Deep band includes stored SWS.
            if let band = band(values: qualified.map { $0.stageDuration(stage) }) {
                ranges[stage] = band
            }
        }
        return ranges.isEmpty ? nil : ranges
    }

    /// Mean ± 1 SD (population SD — the same estimator as
    /// `AtriaOvernightTypical.restingBand`), floored at zero because a stage
    /// duration cannot be negative. Nil when degenerate (SD 0).
    static func band(values: [TimeInterval]) -> ClosedRange<TimeInterval>? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let sd = variance.squareRoot()
        let low = max(0, mean - sd)
        let high = mean + sd
        guard high > low else { return nil }
        return low...high
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

    /// The ONLY production entry point (GAP-06). The overnight-load slot is
    /// pinned nil at the API level: until the GAP-10 validation program
    /// passes, no call site can even offer the unvalidated HR-only projection
    /// to the composite. `make(validatedOvernightLoadPercent:)` remains for
    /// the future validated model and for tests.
    static func provisional(sufficiencyPercent: Double?,
                            consistencyPercent: Double?,
                            efficiencyPercent: Double?) -> AtriaSleepScore {
        make(sufficiencyPercent: sufficiencyPercent,
             consistencyPercent: consistencyPercent,
             efficiencyPercent: efficiencyPercent,
             validatedOvernightLoadPercent: nil)
    }
}
