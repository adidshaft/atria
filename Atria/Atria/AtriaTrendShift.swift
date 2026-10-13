import Foundation

/// Weekly trend-change detection (#5): has the last week moved away from the
/// three weeks before it, by more than noise?
///
/// The week (latest 7 civil days with a value) is compared with the 21 days
/// before it — non-overlapping windows, so one bad night cannot be on both
/// sides. A shift surfaces only when BOTH hold:
/// - Welch's test rejects "same mean" at p < 0.05 (the same gate the tag
///   insights use, `AtriaBehaviorImpact.welchTwoSidedPValue`), and
/// - the change is at least the metric's minimum meaningful effect,
/// with at least 5 days in the week and 14 in the baseline. Anything else
/// says nothing — no "maybe" and no confidence label.
enum AtriaTrendShift {
    enum Metric: String, CaseIterable, Sendable {
        case restingHeartRate
        case hrv
        case respiratoryRate
        case sleepDuration
    }

    struct Shift: Equatable, Sendable {
        let metric: Metric
        let weekMean: Double
        let baselineMean: Double
        let pValue: Double
        let weekDays: Int
        let baselineDays: Int

        var delta: Double { weekMean - baselineMean }

        /// Effect size in units of the metric's minimum meaningful change,
        /// used to pick the most notable shift when several pass.
        var magnitude: Double { abs(delta) / AtriaTrendShift.minimumEffect(metric) }

        /// Lower resting HR / breathing rate and higher HRV / sleep are the
        /// favourable directions.
        var isFavourable: Bool {
            switch metric {
            case .restingHeartRate, .respiratoryRate: return delta < 0
            case .hrv, .sleepDuration: return delta > 0
            }
        }

        var headline: String {
            let direction = delta > 0 ? "up" : "down"
            switch metric {
            case .restingHeartRate:
                return "Resting HR \(direction) \(Int(abs(delta).rounded())) bpm this week"
            case .hrv:
                return "HRV \(direction) \(Int(abs(delta).rounded())) ms this week"
            case .respiratoryRate:
                return String(format: "Breathing rate %@ %.1f/min this week", direction, abs(delta))
            case .sleepDuration:
                return "Sleep \(direction) \(Int((abs(delta) * 60).rounded())) min a night this week"
            }
        }

        var detail: String {
            switch metric {
            case .restingHeartRate:
                return "\(Int(weekMean.rounded())) bpm vs \(Int(baselineMean.rounded())) over the prior 3 weeks."
            case .hrv:
                return "\(Int(weekMean.rounded())) ms vs \(Int(baselineMean.rounded())) over the prior 3 weeks."
            case .respiratoryRate:
                return String(format: "%.1f vs %.1f over the prior 3 weeks.", weekMean, baselineMean)
            case .sleepDuration:
                return "\(Self.hoursText(weekMean)) vs \(Self.hoursText(baselineMean)) over the prior 3 weeks."
            }
        }

        private static func hoursText(_ hours: Double) -> String {
            let minutes = Int((hours * 60).rounded())
            return "\(minutes / 60)h \(minutes % 60)m"
        }
    }

    static let weekDays = 7
    static let baselineDays = 21
    static let minimumWeekSamples = 5
    static let minimumBaselineSamples = 14
    static let significance = 0.05

    /// Smallest change worth a sentence, in the metric's display unit.
    static func minimumEffect(_ metric: Metric) -> Double {
        switch metric {
        case .restingHeartRate: return 2       // bpm
        case .hrv: return 5                    // ms
        case .respiratoryRate: return 0.5      // breaths/min
        case .sleepDuration: return 0.5        // hours
        }
    }

    /// The daily value in display units, or nil when the day has none.
    static func value(_ metric: Metric, in entry: DailyRollupStoreEntry) -> Double? {
        switch metric {
        case .restingHeartRate:
            return entry.rhr.flatMap { $0 > 0 ? Double($0) : nil }
        case .hrv:
            return entry.lnRMSSD.flatMap { $0.isFinite ? exp($0) : nil }
        case .respiratoryRate:
            return entry.respiratoryRate.flatMap { $0 > 0 ? $0 : nil }
        case .sleepDuration:
            return entry.sleepSeconds.flatMap { $0 > 0 ? $0 / 3600 : nil }
        }
    }

    /// Every metric whose last week differs from its prior three weeks.
    /// `rollups` may be in any order; windows are civil days ending at the
    /// most recent day that has any rollup on or before `now`.
    static func shifts(rollups: [DailyRollupStoreEntry],
                       now: Date,
                       calendar: Calendar = .current) -> [Shift] {
        let today = calendar.startOfDay(for: now)
        guard let weekStart = calendar.date(byAdding: .day, value: -(weekDays - 1), to: today),
              let baselineStart = calendar.date(byAdding: .day, value: -baselineDays, to: weekStart)
        else { return [] }
        var byDay: [Date: DailyRollupStoreEntry] = [:]
        for entry in rollups {
            let day = calendar.startOfDay(for: entry.day)
            guard day <= today, day >= baselineStart else { continue }
            byDay[day] = entry
        }
        var results: [Shift] = []
        for metric in Metric.allCases {
            var week: [Double] = []
            var baseline: [Double] = []
            for (day, entry) in byDay {
                guard let value = value(metric, in: entry) else { continue }
                if day >= weekStart { week.append(value) } else { baseline.append(value) }
            }
            guard week.count >= minimumWeekSamples,
                  baseline.count >= minimumBaselineSamples else { continue }
            let weekMean = week.reduce(0, +) / Double(week.count)
            let baselineMean = baseline.reduce(0, +) / Double(baseline.count)
            guard abs(weekMean - baselineMean) >= minimumEffect(metric) else { continue }
            let p = AtriaBehaviorImpact.welchTwoSidedPValue(week, baseline)
            guard p < significance else { continue }
            results.append(Shift(metric: metric,
                                 weekMean: weekMean,
                                 baselineMean: baselineMean,
                                 pValue: p,
                                 weekDays: week.count,
                                 baselineDays: baseline.count))
        }
        return results.sorted { $0.magnitude > $1.magnitude }
    }
}
