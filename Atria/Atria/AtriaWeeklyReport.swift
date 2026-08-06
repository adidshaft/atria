import Foundation

struct WeeklyReport: Codable, Equatable {
    struct DaySummary: Codable, Equatable {
        let day: Date
        let recovery: Int?
        let strain: Double?
    }

    let isoYear: Int
    let isoWeek: Int
    let generatedAt: Date
    let recoveryAvg: Int?
    let recoveryDeltaVsPriorWeek: Int?
    let sleepConsistencyPct: Int?
    let bestDay: DaySummary?
    let hardestDay: DaySummary?
    let strainRecoveryNote: String?
    // 2026-07-07 design handoff headline averages + human date range.
    // Optional so previously saved reports keep decoding (nil = regenerate).
    let strainAvg: Double?
    let sleepAvgSeconds: TimeInterval?
    let weekStart: Date?
    let weekEnd: Date?
    /// Current week's per-day summaries (ascending by day) for the report's
    /// recovery sparkline. Only days that exist in the rollups appear -- a
    /// missing day is simply absent, never interpolated.
    let recoverySeries: [DaySummary]?

    static let strainRecoveryNoteText = "You trained hardest on your lowest-recovery day"

    init(rollups: [DailyRollupStoreEntry],
         sleepNights: [SleepHistorySnapshot.Night] = [],
         now: Date = Date(),
         calendar: Calendar = WeeklyReportCalendar.iso) {
        let recent = Self.recentRollups(rollups, limit: 14)
        let currentWeek = Array(recent.prefix(7))
        let priorWeek = Array(recent.dropFirst(7).prefix(7))
        let currentRecoveries = currentWeek.compactMap(\.recovery)
        let priorRecoveries = priorWeek.compactMap(\.recovery)
        let currentAverage = Self.roundedAverage(currentRecoveries)
        let priorAverage = Self.roundedAverage(priorRecoveries)
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)

        isoYear = components.yearForWeekOfYear ?? components.year ?? 0
        isoWeek = components.weekOfYear ?? 0
        generatedAt = now
        recoveryAvg = currentAverage
        recoveryDeltaVsPriorWeek = currentAverage.flatMap { current in
            priorAverage.map { current - $0 }
        }
        // Bedtime-only rollups cannot answer whether wake time was steady.
        // Reuse the single night-window authority whenever the caller has the
        // evidence; otherwise keep this field building rather than producing a
        // second, incompatible schedule score.
        let weekNights: [SleepHistorySnapshot.Night]
        if let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
            weekNights = sleepNights.filter { night in
                guard let start = night.start else { return false }
                return interval.contains(start)
            }
        } else {
            weekNights = sleepNights
        }
        sleepConsistencyPct = AtriaSleepConsistency.result(from: weekNights).combinedPercent
        bestDay = currentWeek
            .filter { $0.recovery != nil }
            .max { ($0.recovery ?? Int.min) < ($1.recovery ?? Int.min) }
            .map { DaySummary(day: $0.day, recovery: $0.recovery, strain: $0.strain) }
        hardestDay = currentWeek
            .filter { $0.strain != nil }
            .max { ($0.strain ?? -.infinity) < ($1.strain ?? -.infinity) }
            .map { DaySummary(day: $0.day, recovery: $0.recovery, strain: $0.strain) }
        strainRecoveryNote = Self.strainRecoveryNote(for: currentWeek)
        let strains = currentWeek.compactMap(\.strain)
        strainAvg = strains.isEmpty ? nil : strains.reduce(0, +) / Double(strains.count)
        let sleeps = currentWeek.compactMap(\.sleepSeconds)
        sleepAvgSeconds = sleeps.isEmpty ? nil : sleeps.reduce(0, +) / Double(sleeps.count)
        weekStart = currentWeek.map(\.day).min()
        weekEnd = currentWeek.map(\.day).max()
        recoverySeries = currentWeek
            .sorted { $0.day < $1.day }
            .map { DaySummary(day: $0.day, recovery: $0.recovery, strain: $0.strain) }
    }

    private static func recentRollups(_ rollups: [DailyRollupStoreEntry],
                                      limit: Int) -> [DailyRollupStoreEntry] {
        guard limit > 0 else { return [] }
        var recent: [DailyRollupStoreEntry] = []

        for rollup in rollups {
            if recent.count < limit {
                insertRecentRollup(rollup, into: &recent)
            } else if let oldest = recent.last, rollup.day > oldest.day {
                recent.removeLast()
                insertRecentRollup(rollup, into: &recent)
            }
        }

        return recent
    }

    private static func insertRecentRollup(_ rollup: DailyRollupStoreEntry,
                                           into recent: inout [DailyRollupStoreEntry]) {
        let index = recent.firstIndex { $0.day < rollup.day } ?? recent.endIndex
        recent.insert(rollup, at: index)
    }

    private static func roundedAverage(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let total = values.reduce(0, +)
        return Int((Double(total) / Double(values.count)).rounded())
    }

    private static func strainRecoveryNote(for week: [DailyRollupStoreEntry]) -> String? {
        guard let hardest = week.filter({ $0.strain != nil }).max(by: {
            ($0.strain ?? -.infinity) < ($1.strain ?? -.infinity)
        }), hardest.recovery != nil else {
            return nil
        }

        let lowestRecoveryDays = Set(week.compactMap { entry -> Date? in
            guard entry.recovery != nil else { return nil }
            return entry.day
        }.sorted { first, second in
            let firstRecovery = week.first { $0.day == first }?.recovery ?? Int.max
            let secondRecovery = week.first { $0.day == second }?.recovery ?? Int.max
            return firstRecovery < secondRecovery
        }.prefix(2))

        return lowestRecoveryDays.contains(hardest.day) ? strainRecoveryNoteText : nil
    }
}

final class WeeklyReportStore {
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

    func report(isoYear: Int, isoWeek: Int) -> WeeklyReport? {
        let url = urlForReport(isoYear: isoYear, isoWeek: isoWeek)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(WeeklyReport.self, from: data)
    }

    func save(_ report: WeeklyReport) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(report)
            try data.write(to: urlForReport(isoYear: report.isoYear, isoWeek: report.isoWeek), options: .atomic)
            AtriaDebugLog("ATRIADBG weekly_report_store_save status=ok isoYear=%d isoWeek=%d",
                          report.isoYear,
                          report.isoWeek)
        } catch {
            AtriaDebugLog("ATRIADBG weekly_report_store_save status=failed error=%@",
                          error.localizedDescription)
        }
    }

    private func urlForReport(isoYear: Int, isoWeek: Int) -> URL {
        directory.appendingPathComponent("weekly-report-\(isoYear)-W\(isoWeek).json")
    }
}

private enum WeeklyReportCalendar {
    static let iso: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }()
}
