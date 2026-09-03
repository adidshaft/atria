import Foundation

/// Calendar-month analog of `WeeklyReport` (see AtriaWeeklyReport.swift). Aggregates
/// `DailyRollupStoreEntry` rows that fall within a calendar month rather than an ISO week.
///
/// Honesty gate: a month needs at least `MonthlyReport.minimumDaysForStats` rollup days
/// (any metric present) before any stat is computed. Below that threshold every stat is
/// `nil` and `isBuilding` is `true` — callers must render "Building" copy, never a guess.
struct MonthlyReport: Codable, Equatable {
    struct WeekSummary: Codable, Equatable {
        let weekStart: Date
        let totalStrain: Double?
    }

    static let minimumDaysForStats = 14

    let year: Int
    let month: Int
    let generatedAt: Date
    let daysWithData: Int
    let isBuilding: Bool

    let recoveryAvg: Int?
    let recoveryDeltaVsPriorMonth: Int?

    let totalStrain: Double?
    let hardestWeek: WeekSummary?
    /// 2026-09-02: the strain row compares like its neighbours, but as a
    /// daily average, never total against total: a partial month's sum
    /// cannot be compared to a full one.
    let strainDailyAverage: Double?
    let strainDailyAverageDeltaVsPriorMonth: Double?

    let sleepPerformanceAvg: Int?
    let sleepPerformanceDeltaVsPriorMonth: Int?

    let rhrAvg: Int?
    let rhrDeltaVsPriorMonth: Int?

    let hrvAvgMs: Double?
    let hrvDeltaVsPriorMonthMs: Double?

    let consistencyScore: Int?

    init(rollups: [DailyRollupStoreEntry],
         sleepNights: [SleepHistorySnapshot.Night] = [],
         now: Date = Date(),
         calendar: Calendar = MonthlyReportCalendar.gregorian,
         cycleStrainByDisplayDay: [Date: Double] = [:]) {
        let components = calendar.dateComponents([.year, .month], from: now)
        let year = components.year ?? 0
        let month = components.month ?? 0
        self.year = year
        self.month = month
        generatedAt = now

        // Same overlay the weekly report, strain chart, and Trends card use
        // (2026-08-30 / 2026-09-03): a shifted sleeper's civil rollup shreds
        // one wake-to-wake day across two bars. An empty map leaves every
        // civil value untouched.
        let currentMonth = Self.applyingCycleStrain(
            Self.entries(rollups, year: year, month: month, calendar: calendar),
            cycleStrainByDisplayDay,
            calendar: calendar)
        let (priorYear, priorMonth) = Self.priorMonth(year: year, month: month)
        let priorMonthEntries = Self.applyingCycleStrain(
            Self.entries(rollups, year: priorYear, month: priorMonth, calendar: calendar),
            cycleStrainByDisplayDay,
            calendar: calendar)

        let dataDayCount = currentMonth.filter { entry in
            entry.recovery != nil || entry.strain != nil || entry.sleepSeconds != nil
        }.count
        daysWithData = dataDayCount
        let building = dataDayCount < Self.minimumDaysForStats
        isBuilding = building

        if building {
            recoveryAvg = nil
            recoveryDeltaVsPriorMonth = nil
            totalStrain = nil
            hardestWeek = nil
            strainDailyAverage = nil
            strainDailyAverageDeltaVsPriorMonth = nil
            sleepPerformanceAvg = nil
            sleepPerformanceDeltaVsPriorMonth = nil
            rhrAvg = nil
            rhrDeltaVsPriorMonth = nil
            hrvAvgMs = nil
            hrvDeltaVsPriorMonthMs = nil
            consistencyScore = nil
            return
        }

        let currentRecoveries = currentMonth.compactMap(\.recovery)
        let priorRecoveries = priorMonthEntries.compactMap(\.recovery)
        let currentRecoveryAvg = Self.roundedAverage(currentRecoveries)
        let priorRecoveryAvg = Self.roundedAverage(priorRecoveries)
        recoveryAvg = currentRecoveryAvg
        recoveryDeltaVsPriorMonth = currentRecoveryAvg.flatMap { current in
            priorRecoveryAvg.map { current - $0 }
        }

        let strains = currentMonth.compactMap(\.strain)
        totalStrain = strains.isEmpty ? nil : strains.reduce(0, +)
        let strainAverage = strains.isEmpty ? nil : strains.reduce(0, +) / Double(strains.count)
        let priorStrains = priorMonthEntries.compactMap(\.strain)
        let priorStrainAverage = priorStrains.isEmpty ? nil : priorStrains.reduce(0, +) / Double(priorStrains.count)
        strainDailyAverage = strainAverage
        strainDailyAverageDeltaVsPriorMonth = strainAverage.flatMap { current in priorStrainAverage.map { current - $0 } }
        hardestWeek = Self.hardestWeek(in: currentMonth, calendar: calendar)

        let currentSleepPerformances = currentMonth.compactMap(\.sleepPerformance)
        let priorSleepPerformances = priorMonthEntries.compactMap(\.sleepPerformance)
        let currentSleepPerformanceAvg = Self.roundedAverage(currentSleepPerformances)
        let priorSleepPerformanceAvg = Self.roundedAverage(priorSleepPerformances)
        sleepPerformanceAvg = currentSleepPerformanceAvg
        sleepPerformanceDeltaVsPriorMonth = currentSleepPerformanceAvg.flatMap { current in
            priorSleepPerformanceAvg.map { current - $0 }
        }

        let currentRHRs = currentMonth.compactMap(\.rhr)
        let priorRHRs = priorMonthEntries.compactMap(\.rhr)
        let currentRHRAvg = Self.roundedAverage(currentRHRs)
        let priorRHRAvg = Self.roundedAverage(priorRHRs)
        rhrAvg = currentRHRAvg
        rhrDeltaVsPriorMonth = currentRHRAvg.flatMap { current in
            priorRHRAvg.map { current - $0 }
        }

        let currentHRVs = currentMonth.compactMap(\.lnRMSSD).map { exp($0) }
        let priorHRVs = priorMonthEntries.compactMap(\.lnRMSSD).map { exp($0) }
        let currentHRVAvg = Self.average(currentHRVs)
        let priorHRVAvg = Self.average(priorHRVs)
        hrvAvgMs = currentHRVAvg
        hrvDeltaVsPriorMonthMs = currentHRVAvg.flatMap { current in
            priorHRVAvg.map { current - $0 }
        }

        // Never collapse a bed-to-wake consistency measure back into a
        // bedtime-only rollup score. Without qualified sleep windows this is
        // intentionally nil ("Schedule building" in the report UI).
        let monthNights = sleepNights.filter { night in
            guard let start = night.start else { return false }
            let parts = calendar.dateComponents([.year, .month], from: start)
            return parts.year == year && parts.month == month
        }
        consistencyScore = AtriaSleepConsistency.result(from: monthNights).combinedPercent
    }

    /// "8.0 a day · +4.0 vs last month"; the comparison clause only once a
    /// prior month exists, and "same as last month" within a tenth.
    static func strainDetailText(dailyAverage: Double?, delta: Double?) -> String {
        guard let dailyAverage else { return "Daily strain summed across the month" }
        let average = String(format: "%.1f a day", dailyAverage)
        guard let delta else { return average }
        if abs(delta) < 0.05 { return "\(average) · same as last month" }
        return "\(average) · \(delta < 0 ? "\u{2212}" : "+")\(String(format: "%.1f", abs(delta))) vs last month"
    }

    /// Prefer Calendar.current, which is how SessionStore keys the map and
    /// how the strain chart looks it up. Fall back to the report calendar
    /// and the stored day itself so a test that keys on civil midnight still
    /// hits, and a pre-normalized rollup day hits without a second convert.
    static func applyingCycleStrain(_ entries: [DailyRollupStoreEntry],
                                    _ cycleStrainByDisplayDay: [Date: Double],
                                    calendar: Calendar) -> [DailyRollupStoreEntry] {
        guard !cycleStrainByDisplayDay.isEmpty else { return entries }
        return entries.map { entry in
            let cycleStrain = cycleStrainByDisplayDay[Calendar.current.startOfDay(for: entry.day)]
                ?? cycleStrainByDisplayDay[calendar.startOfDay(for: entry.day)]
                ?? cycleStrainByDisplayDay[entry.day]
            guard let cycleStrain, cycleStrain != entry.strain else { return entry }
            var copy = entry
            copy.strain = cycleStrain
            return copy
        }
    }

    private static func entries(_ rollups: [DailyRollupStoreEntry],
                                 year: Int,
                                 month: Int,
                                 calendar: Calendar) -> [DailyRollupStoreEntry] {
        rollups.filter { entry in
            let components = calendar.dateComponents([.year, .month], from: entry.day)
            return components.year == year && components.month == month
        }
    }

    private static func priorMonth(year: Int, month: Int) -> (year: Int, month: Int) {
        month <= 1 ? (year - 1, 12) : (year, month - 1)
    }

    private static func roundedAverage(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let total = values.reduce(0, +)
        return Int((Double(total) / Double(values.count)).rounded())
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func hardestWeek(in month: [DailyRollupStoreEntry], calendar: Calendar) -> WeekSummary? {
        var byWeekStart: [Date: Double] = [:]
        for entry in month {
            guard let strain = entry.strain else { continue }
            guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: entry.day) else { continue }
            byWeekStart[weekInterval.start, default: 0] += strain
        }
        guard let hardest = byWeekStart.max(by: { $0.value < $1.value }) else { return nil }
        return WeekSummary(weekStart: hardest.key, totalStrain: hardest.value)
    }

}

final class MonthlyReportStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        if let directory {
            self.directory = directory
        } else {
            let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directory = documents
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func report(year: Int, month: Int) -> MonthlyReport? {
        let url = urlForReport(year: year, month: month)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(MonthlyReport.self, from: data)
    }

    func save(_ report: MonthlyReport) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(report)
            try data.write(to: urlForReport(year: report.year, month: report.month), options: .atomic)
            AtriaDebugLog("ATRIADBG monthly_report_store_save status=ok year=%d month=%d",
                          report.year,
                          report.month)
        } catch {
            AtriaDebugLog("ATRIADBG monthly_report_store_save status=failed error=%@",
                          error.localizedDescription)
        }
    }

    private func urlForReport(year: Int, month: Int) -> URL {
        directory.appendingPathComponent("monthly-report-\(year)-M\(month).json")
    }
}

private enum MonthlyReportCalendar {
    static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
