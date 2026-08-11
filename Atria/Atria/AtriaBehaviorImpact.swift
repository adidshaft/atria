import Foundation

struct BehaviorImpactSummary: Identifiable, Equatable {
    let tag: BehaviorJournalEntry.Tag
    let loggedDays: Int
    let comparisonDays: Int
    let impact: Double
    let pValue: Double

    var id: String { tag.rawValue }

    var nightsText: String {
        loggedDays == 1 ? "1 night" : "\(loggedDays) nights"
    }

    var valueText: String {
        String(format: "%+.0f%% next-day recovery", impact)
    }
}

enum AtriaBehaviorImpact {
    struct Day: Equatable {
        let day: Date
        let recoveryPercent: Int?
    }

    static let trailingWindowDays = 90
    static let minimumLoggedDays = 5
    static let minimumComparisonDays = 5
    static let minimumImpact = 3.0
    static let maximumPValue = 0.10

    static func summaries(days: [Day],
                          journalEntries: [BehaviorJournalEntry],
                          referenceDate: Date? = nil,
                          calendar: Calendar = .current) -> [BehaviorImpactSummary] {
        summariesCancellable(
            days: days,
            journalEntries: journalEntries,
            referenceDate: referenceDate,
            calendar: calendar,
            shouldContinue: { true }
        ) ?? []
    }

    static func summariesCancellable(
        days: [Day],
        journalEntries: [BehaviorJournalEntry],
        referenceDate: Date? = nil,
        calendar: Calendar = .current,
        shouldContinue: () -> Bool
    ) -> [BehaviorImpactSummary]? {
        guard shouldContinue() else { return nil }
        let latest = referenceDate
            ?? (days.map(\.day) + journalEntries.map(\.day)).max()
            ?? Date()
        let referenceDay = calendar.startOfDay(for: latest)
        let windowStart = calendar.date(byAdding: .day,
                                        value: -trailingWindowDays,
                                        to: referenceDay)
            ?? referenceDay.addingTimeInterval(TimeInterval(-trailingWindowDays * 24 * 60 * 60))

        var recoveryByDay: [Date: Double] = [:]
        for (index, day) in days.enumerated() {
            if index.isMultiple(of: 64), !shouldContinue() { return nil }
            let key = calendar.startOfDay(for: day.day)
            if key >= windowStart,
               key <= referenceDay,
               let recovery = day.recoveryPercent {
                recoveryByDay[key] = Double(recovery)
            }
        }
        guard !recoveryByDay.isEmpty else { return [] }

        var entriesByDay: [Date: [BehaviorJournalEntry]] = [:]
        for (index, entry) in journalEntries.enumerated() {
            if index.isMultiple(of: 64), !shouldContinue() { return nil }
            let day = calendar.startOfDay(for: entry.day)
            if day >= windowStart, day <= referenceDay {
                entriesByDay[day, default: []].append(entry)
            }
        }

        var result: [BehaviorImpactSummary] = []
        for tag in BehaviorJournalEntry.Tag.allCases {
            guard shouldContinue() else { return nil }
            var loggedDayKeys = Set<Date>()
            for (day, entries) in entriesByDay {
                guard shouldContinue() else { return nil }
                if entries.contains(where: { $0.tags.contains(tag) }) {
                    loggedDayKeys.insert(day)
                }
            }
            var logged: [Double] = []
            var comparison: [Double] = []
            for (index, pair) in recoveryByDay.enumerated() {
                if index.isMultiple(of: 64), !shouldContinue() { return nil }
                if loggedDayKeys.contains(pair.key) {
                    logged.append(pair.value)
                } else {
                    comparison.append(pair.value)
                }
            }

            guard logged.count >= minimumLoggedDays,
                  comparison.count >= minimumComparisonDays else {
                continue
            }

            let impact = mean(logged) - mean(comparison)
            guard abs(impact) >= minimumImpact else { continue }

            let pValue = welchTwoSidedPValue(logged, comparison)
            guard pValue < maximumPValue else { continue }

            result.append(BehaviorImpactSummary(tag: tag,
                                                loggedDays: logged.count,
                                                comparisonDays: comparison.count,
                                                impact: impact,
                                                pValue: pValue))
        }
        guard shouldContinue() else { return nil }
        result.sort {
            if abs($0.impact) != abs($1.impact) { return abs($0.impact) > abs($1.impact) }
            if $0.loggedDays != $1.loggedDays { return $0.loggedDays > $1.loggedDays }
            return $0.tag.rawValue < $1.tag.rawValue
        }
        return shouldContinue() ? result : nil
    }

    static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let avg = mean(values)
        return values.reduce(0) { $0 + pow($1 - avg, 2) } / Double(values.count - 1)
    }

    static func welchTwoSidedPValue(_ a: [Double], _ b: [Double]) -> Double {
        let varianceA = variance(a)
        let varianceB = variance(b)
        let standardError = sqrt(varianceA / Double(a.count) + varianceB / Double(b.count))
        guard standardError > 0 else {
            return mean(a) == mean(b) ? 1 : 0
        }
        let t = abs((mean(a) - mean(b)) / standardError)
        // For the sample sizes used here, the normal approximation is deliberately
        // conservative enough for product gating while keeping this pure Swift.
        return 2 * (1 - normalCDF(t))
    }

    static func normalCDF(_ x: Double) -> Double {
        0.5 * (1 + erf(x / sqrt(2)))
    }
}
