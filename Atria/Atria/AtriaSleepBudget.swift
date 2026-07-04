import Foundation

enum AtriaSleepBudget {
    static func sleepNeed(baseHours: Double,
                          yesterdayStrain: Double?,
                          debtHours: Double,
                          sameDayNapHours: Double) -> Double {
        let safeBase = min(max(baseHours, 6), 10)
        let strainAdder = (yesterdayStrain ?? 0) >= 14.0 ? 0.5 : 0
        let debtAdder = max(0, debtHours) * 0.5
        let napCredit = max(0, sameDayNapHours) * 0.9
        return min(max(safeBase + strainAdder + debtAdder - napCredit, 6), 10)
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

enum AtriaNapRecovery {
    static let minimumNapHours = 0.75
    static let minimumQualifyingHRVWindows = 3

    struct Result: Equatable {
        let percent: Int?
        let lifted: Bool
    }

    static func adjustedRecovery(morningRecovery: Int?,
                                 morningLnRMSSD: Double?,
                                 napLnRMSSD: Double?,
                                 napDurationHours: Double,
                                 qualifyingHRVWindows: Int) -> Result {
        guard let morningRecovery else {
            return Result(percent: nil, lifted: false)
        }
        guard napDurationHours >= minimumNapHours,
              qualifyingHRVWindows >= minimumQualifyingHRVWindows,
              let morningLnRMSSD,
              let napLnRMSSD else {
            return Result(percent: morningRecovery, lifted: false)
        }

        let delta = napLnRMSSD - morningLnRMSSD
        guard delta > 0 else {
            return Result(percent: morningRecovery, lifted: false)
        }

        let lifted = min(99, max(morningRecovery, morningRecovery + Int((delta * 25.0).rounded())))
        return Result(percent: lifted, lifted: lifted > morningRecovery)
    }
}
