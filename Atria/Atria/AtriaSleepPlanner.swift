import Foundation

/// Sleep Planner (2026-07-07, WHOOP-research adaptation): works backwards
/// from the wake-by time to an "in bed by" recommendation for a chosen
/// performance goal.
///
/// Honesty rules: the sleep-need input is the app's existing ledger math
/// (never recomputed here), the efficiency assumption comes from the user's
/// own confirmed nights (population default only while learning, and labeled
/// as such), and with no wake-by time configured there is no recommendation.
enum AtriaSleepPlannerGoal: String, Codable, CaseIterable, Identifiable {
    case peak, perform, getBy

    var id: String { rawValue }

    /// Fraction of tonight's sleep need the goal aims to cover (WHOOP's
    /// public Peak/Perform/Get By tiers).
    var needFraction: Double {
        switch self {
        case .peak: return 1.0
        case .perform: return 0.85
        case .getBy: return 0.70
        }
    }

    var title: String {
        switch self {
        case .peak: return "Peak"
        case .perform: return "Perform"
        case .getBy: return "Get by"
        }
    }

    var detail: String {
        switch self {
        case .peak: return "100% of need"
        case .perform: return "85% of need"
        case .getBy: return "70% of need"
        }
    }
}

struct AtriaSleepPlan: Equatable {
    let targetSleepHours: Double
    /// Minutes-of-day (0..<1440) to be in bed by; can wrap past midnight
    /// into the previous evening.
    let inBedByMinutes: Int
    let assumedEfficiency: Double
    /// True while the efficiency assumption is the population default rather
    /// than learned from the user's own nights.
    let efficiencyIsDefault: Bool

    var inBedByText: String {
        let hour = inBedByMinutes / 60
        let minute = inBedByMinutes % 60
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

enum AtriaSleepPlanner {
    static let defaultEfficiency = 0.90
    static let minimumNightsForLearnedEfficiency = 5

    /// Median efficiency across the user's confirmed nights, or the labeled
    /// population default while fewer than 5 real nights exist.
    static func assumedEfficiency(nightEfficiencies: [Double]) -> (value: Double, isDefault: Bool) {
        let usable = nightEfficiencies.filter { $0 > 0.5 && $0 <= 1.0 }.sorted()
        guard usable.count >= minimumNightsForLearnedEfficiency else {
            return (defaultEfficiency, true)
        }
        let median = usable[usable.count / 2]
        return (median, false)
    }

    /// The recommendation. `needHours` is tonight's need from the existing
    /// ledger; `wakeByMinutes` is the configured wake-by time in minutes of
    /// day. Time in bed = target sleep / efficiency, clamped to sane bounds.
    static func plan(needHours: Double,
                     goal: AtriaSleepPlannerGoal,
                     wakeByMinutes: Int,
                     nightEfficiencies: [Double]) -> AtriaSleepPlan {
        let efficiency = assumedEfficiency(nightEfficiencies: nightEfficiencies)
        let targetSleep = min(max(needHours * goal.needFraction, 3), 12)
        let timeInBedMinutes = Int((targetSleep / efficiency.value * 60).rounded())
        var inBedBy = wakeByMinutes - timeInBedMinutes
        while inBedBy < 0 { inBedBy += 24 * 60 }
        return AtriaSleepPlan(targetSleepHours: targetSleep,
                              inBedByMinutes: inBedBy % (24 * 60),
                              assumedEfficiency: efficiency.value,
                              efficiencyIsDefault: efficiency.isDefault)
    }
}
