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
