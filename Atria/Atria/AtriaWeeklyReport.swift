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
         now: Date = Date(),
         calendar: Calendar = WeeklyReportCalendar.iso) {
        let ordered = rollups.sorted { $0.day > $1.day }
        let currentWeek = Array(ordered.prefix(7))
        let priorWeek = Array(ordered.dropFirst(7).prefix(7))
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
        sleepConsistencyPct = Self.sleepConsistencyPercent(from: currentWeek.compactMap(\.bedtimeMinutes))
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

    private static func roundedAverage(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let total = values.reduce(0, +)
        return Int((Double(total) / Double(values.count)).rounded())
    }

    private static func sleepConsistencyPercent(from bedtimes: [Int]) -> Int? {
        guard bedtimes.count >= 2 else { return nil }
        let normalized = bedtimes.map { minute -> Double in
            let wrapped = ((minute % 1_440) + 1_440) % 1_440
            return Double(wrapped < 720 ? wrapped + 1_440 : wrapped)
        }
        let mean = normalized.reduce(0, +) / Double(normalized.count)
        let variance = normalized.reduce(0) { partial, value in
            let delta = value - mean
            return partial + delta * delta
        } / Double(normalized.count)
        let sdMinutes = sqrt(variance)
        return Int((100 - min(100, sdMinutes / 1.2)).rounded()).clamped(to: 0...100)
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
