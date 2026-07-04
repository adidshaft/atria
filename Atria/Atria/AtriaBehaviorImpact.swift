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
        let latest = referenceDate
            ?? (days.map(\.day) + journalEntries.map(\.day)).max()
            ?? Date()
        let referenceDay = calendar.startOfDay(for: latest)
        let windowStart = calendar.date(byAdding: .day,
                                        value: -trailingWindowDays,
                                        to: referenceDay)
            ?? referenceDay.addingTimeInterval(TimeInterval(-trailingWindowDays * 24 * 60 * 60))

        let recoveryByDay = Dictionary(uniqueKeysWithValues: days.compactMap { day -> (Date, Double)? in
            let key = calendar.startOfDay(for: day.day)
            guard key >= windowStart, key <= referenceDay, let recovery = day.recoveryPercent else {
                return nil
            }
            return (key, Double(recovery))
        })
        guard !recoveryByDay.isEmpty else { return [] }

        let entriesByDay = Dictionary(grouping: journalEntries.filter {
            let day = calendar.startOfDay(for: $0.day)
            return day >= windowStart && day <= referenceDay
        }) { calendar.startOfDay(for: $0.day) }

        return BehaviorJournalEntry.Tag.allCases.compactMap { tag in
            let loggedDayKeys = Set(entriesByDay.compactMap { day, entries in
                entries.contains { $0.tags.contains(tag) } ? day : nil
            })
            let logged = recoveryByDay
                .filter { loggedDayKeys.contains($0.key) }
                .map(\.value)
            let comparison = recoveryByDay
                .filter { !loggedDayKeys.contains($0.key) }
                .map(\.value)

            guard logged.count >= minimumLoggedDays,
                  comparison.count >= minimumComparisonDays else {
                return nil
            }

            let impact = mean(logged) - mean(comparison)
            guard abs(impact) >= minimumImpact else { return nil }

            let pValue = welchTwoSidedPValue(logged, comparison)
            guard pValue < maximumPValue else { return nil }

            return BehaviorImpactSummary(tag: tag,
                                         loggedDays: logged.count,
                                         comparisonDays: comparison.count,
                                         impact: impact,
                                         pValue: pValue)
        }
        .sorted {
            if abs($0.impact) != abs($1.impact) { return abs($0.impact) > abs($1.impact) }
            if $0.loggedDays != $1.loggedDays { return $0.loggedDays > $1.loggedDays }
            return $0.tag.rawValue < $1.tag.rawValue
        }
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
