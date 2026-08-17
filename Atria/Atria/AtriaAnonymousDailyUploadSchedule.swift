import Foundation

/// Pure daily-upload schedule for opted-in anonymous research sharing.
///
/// Due/not-due is a function of (opted in, preferred local minutes, now,
/// last-run civil day). Default clock time is 03:00 local. Persistence lives
/// next to the other `atria.dataSharing.*` keys; callers inject clocks so
/// tests never touch the filesystem or a real calendar.
enum AtriaAnonymousDailyUploadSchedule {
    static let preferredLocalMinutesKey = "atria.dataSharing.dailyUploadMinutes"
    static let lastRunCivilDayKey = "atria.research.upload.lastRunDay"
    static let defaultPreferredLocalMinutes = 3 * 60
    static let minutesPerDay = 24 * 60

    static func clampMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 0), minutesPerDay - 1)
    }

    /// `nil` (unset) resolves to 03:00. A stored `0` is midnight, not unset.
    static func resolvedPreferredLocalMinutes(_ stored: Int?) -> Int {
        guard let stored else { return defaultPreferredLocalMinutes }
        return clampMinutes(stored)
    }

    static func preferredLocalMinutes(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: preferredLocalMinutesKey) as? Int
        return resolvedPreferredLocalMinutes(stored)
    }

    static func setPreferredLocalMinutes(_ minutes: Int, defaults: UserDefaults = .standard) {
        defaults.set(clampMinutes(minutes), forKey: preferredLocalMinutesKey)
    }

    static func lastRunCivilDay(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    static func minutes(from date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return clampMinutes((components.hour ?? 0) * 60 + (components.minute ?? 0))
    }

    static func dateRepresenting(minutes: Int,
                                 now: Date = Date(),
                                 calendar: Calendar = .current) -> Date {
        let clamped = clampMinutes(minutes)
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = clamped / 60
        components.minute = clamped % 60
        components.second = 0
        components.nanosecond = 0
        return calendar.date(from: components) ?? now
    }

    /// True only when sharing is on, local clock is at or after the configured
    /// time, and this local civil day has not already produced an upload.
    static func isDue(optedIn: Bool,
                      preferredLocalMinutes: Int,
                      now: Date,
                      lastRunCivilDay: String?,
                      calendar: Calendar) -> Bool {
        guard optedIn else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        guard nowMinutes >= clampMinutes(preferredLocalMinutes) else { return false }
        return lastRunCivilDay != Self.lastRunCivilDay(for: now, calendar: calendar)
    }
}
