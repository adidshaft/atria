import Foundation

/// What the reader chose last time they opened a chart, remembered PER METRIC.
///
/// The expanded chart's controls — time range, compare, chart form, journal
/// markers — were all `@State`, so every choice was discarded when the sheet
/// closed. Customisation that does not survive being closed is not
/// customisation; the reader re-makes the same four adjustments every time.
///
/// Keyed per metric on purpose. "Six weeks with compare on" is a sensible
/// standing choice for Sleep and a meaningless one for Blood oxygen, and a
/// chart FORM especially does not generalise — bars suit a once-a-day score,
/// a line suits a continuous one. One global preference would drag a choice
/// made for one metric onto every other.
///
/// Only preferences are stored. Nothing here decides what a number means, so a
/// corrupt or absent entry costs the reader a default view and nothing else —
/// every accessor falls back rather than throwing.
enum AtriaExpandedChartPreferences {
    private static let storageKey = "atria.expandedChart.preferences.v1"

    struct Stored: Codable, Equatable {
        var visibleDays: Int?
        var compareOn: Bool?
        var compareMode: String?
        var chartType: String?
        var markJournalEvents: Bool?
    }

    /// Metric titles are user-facing strings that can be re-worded; a rename
    /// simply loses that metric's stored preference and it starts from the
    /// default again. That is the right failure: preferences are conveniences,
    /// never data.
    static func load(
        metric: String,
        defaults: UserDefaults = .standard
    ) -> Stored {
        guard !metric.isEmpty,
              let data = defaults.data(forKey: storageKey),
              let all = try? JSONDecoder().decode([String: Stored].self, from: data),
              let stored = all[metric] else { return Stored() }
        return stored
    }

    @discardableResult
    static func save(
        _ stored: Stored,
        metric: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !metric.isEmpty else { return false }
        var all: [String: Stored] = [:]
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Stored].self, from: data) {
            all = decoded
        }
        all[metric] = stored
        // Bound the store so a long-lived install cannot accumulate an entry
        // for every metric title that ever existed. Preferences are cheap to
        // lose, so trimming is safe; keeping the map small keeps every read
        // fast because the whole thing is decoded on each open.
        if all.count > maximumRememberedMetrics {
            all = Dictionary(
                uniqueKeysWithValues: all.sorted { $0.key < $1.key }
                    .prefix(maximumRememberedMetrics)
                    .map { ($0.key, $0.value) }
            )
            all[metric] = stored
        }
        guard let encoded = try? JSONEncoder().encode(all) else { return false }
        defaults.set(encoded, forKey: storageKey)
        return true
    }

    static let maximumRememberedMetrics = 40

    /// Clears everything. Exposed so a "reset chart settings" affordance never
    /// has to reach into the defaults key directly.
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
