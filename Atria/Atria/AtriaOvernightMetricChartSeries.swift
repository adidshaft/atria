import Foundation

/// One overnight series for diagnosis and metric-detail charts.
///
/// Civil days are taken from the plot calendar, not the persisted instant, so a
/// night stored as IST midnight cannot fall out of a trailing Week/Month window
/// that the same calendar just built. Newest rollup wins when two rows share a
/// day; a newer row without a value does not hide an older night that has one.
enum AtriaOvernightMetricChartSeries {
    struct Night: Equatable, Sendable {
        let day: Date
        let value: Double
    }

    static func nights<Entry>(
        from entries: [Entry],
        interval: DateInterval,
        calendar: Calendar,
        day: (Entry) -> Date,
        value: (Entry) -> Double?
    ) -> [Night] {
        var byDay: [Date: Double] = [:]
        byDay.reserveCapacity(min(entries.count, 32))
        for entry in entries {
            let civil = calendar.startOfDay(for: day(entry))
            guard civil >= interval.start, civil < interval.end else { continue }
            guard byDay[civil] == nil else { continue }
            guard let next = value(entry), next.isFinite else { continue }
            byDay[civil] = next
        }
        return byDay.keys.sorted().map { Night(day: $0, value: byDay[$0]!) }
    }
}
