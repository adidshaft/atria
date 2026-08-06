import Foundation

/// Persisted ring of device lock/unlock and scene lifecycle observations.
///
/// Purpose (2026-08-06): the sleep detector's HR gates cannot distinguish a
/// still, low-HR wearer *using their unlocked phone* from a sleeping one.
/// The device being unlocked and in use is near-certain wakefulness, so
/// sleep-onset clamping consumes the sustained-use intervals derived here.
///
/// HONESTY CONSTRAINTS
/// - Events are only observable while this process is alive to receive the
///   UIKit notifications. Absence of journal data is NOT evidence of sleep —
///   it usually means Atria was not running or was suspended. Consumers must
///   treat "no coverage" as "unknown" and change nothing.
/// - An unlocked span whose closing `locked` event was never observed (the
///   process died or was suspended first) is truncated at the last recorded
///   event of any kind: use is never extrapolated beyond the final moment the
///   process provably observed the device.
enum AtriaDeviceUseJournal {
    enum Event: String, Codable, Equatable, Sendable {
        case unlocked
        case locked
        case sceneActive
        case sceneBackground
    }

    struct Entry: Codable, Equatable, Sendable {
        /// Unix timestamp (seconds since 1970).
        let t: TimeInterval
        let event: Event
    }

    static let maximumEntries = 800
    /// Two use spans separated by less than this are one continuous use
    /// episode (brief screen-off between checks, quick relock/unlock).
    static let mergeGapMaximum: TimeInterval = 60

    private static let stateKey = "atria.deviceUseJournal.v1"
    private static let stateLock = NSLock()

    static func note(_ event: Event,
                     at date: Date = Date(),
                     defaults: UserDefaults = .standard) {
        guard date.timeIntervalSince1970.isFinite else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        var entries = load(defaults: defaults)
        entries.append(.init(t: date.timeIntervalSince1970, event: event))
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        save(entries, defaults: defaults)
    }

    /// Sustained-use intervals intersecting `window`.
    ///
    /// Derivation: `unlocked` opens a primary use span and `locked` closes it.
    /// Scene events refine but never override the lock state — `sceneActive`
    /// opens a span only when none is open (foreground implies unlocked), and
    /// `sceneBackground` closes only a scene-opened span: a primary unlocked
    /// span survives app switching because the device is still in use, and its
    /// end is bounded by the later `locked` event or by observation truncation.
    /// Spans separated by gaps shorter than `mergeGapMaximum` are merged,
    /// spans shorter than `minimumDuration` (measured before window clipping)
    /// are dropped, and the survivors are clipped to `window`.
    ///
    /// An empty result means "no observed sustained use", never "asleep".
    static func intervalsOfSustainedUse(in window: DateInterval,
                                        minimumDuration: TimeInterval,
                                        defaults: UserDefaults = .standard) -> [DateInterval] {
        guard window.duration > 0 else { return [] }
        stateLock.lock()
        let entries = load(defaults: defaults)
        stateLock.unlock()
        return sustainedUseIntervals(entries: entries,
                                     window: window,
                                     minimumDuration: minimumDuration)
    }

    /// Pure derivation, exposed for deterministic tests.
    static func sustainedUseIntervals(entries: [Entry],
                                      window: DateInterval,
                                      minimumDuration: TimeInterval) -> [DateInterval] {
        guard window.duration > 0 else { return [] }
        var raw: [DateInterval] = []
        var openStart: TimeInterval?
        var openIsPrimary = false
        var lastObserved: TimeInterval?
        for entry in entries.sorted(by: { $0.t < $1.t }) {
            guard entry.t.isFinite else { continue }
            switch entry.event {
            case .unlocked:
                if let start = openStart {
                    // Already open (e.g. sceneActive first): keep the earlier
                    // start and promote to primary lock authority.
                    openStart = min(start, entry.t)
                } else {
                    openStart = entry.t
                }
                openIsPrimary = true
            case .sceneActive:
                if openStart == nil {
                    openStart = entry.t
                    openIsPrimary = false
                }
            case .locked:
                if let start = openStart, entry.t > start {
                    raw.append(interval(start, entry.t))
                }
                openStart = nil
                openIsPrimary = false
            case .sceneBackground:
                if let start = openStart, !openIsPrimary {
                    if entry.t > start {
                        raw.append(interval(start, entry.t))
                    }
                    openStart = nil
                }
                // A primary unlocked span stays open: backgrounding Atria does
                // not lock the device.
            }
            lastObserved = max(lastObserved ?? entry.t, entry.t)
        }
        // Observation truncation: never extrapolate an unclosed span past the
        // last event this process provably recorded.
        if let start = openStart, let last = lastObserved, last > start {
            raw.append(interval(start, last))
        }

        let merged = mergeIntervals(raw, maximumGap: mergeGapMaximum)
        return merged
            .filter { $0.duration >= minimumDuration }
            .compactMap { intersection($0, window) }
    }

    static func reset(defaults: UserDefaults = .standard) {
        stateLock.lock()
        defaults.removeObject(forKey: stateKey)
        stateLock.unlock()
    }

    // MARK: - Persistence

    private static func load(defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: stateKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func save(_ entries: [Entry], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: stateKey)
    }

    // MARK: - Interval helpers

    private static func interval(_ start: TimeInterval,
                                 _ end: TimeInterval) -> DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: start),
                     end: Date(timeIntervalSince1970: end))
    }

    private static func mergeIntervals(_ values: [DateInterval],
                                       maximumGap: TimeInterval) -> [DateInterval] {
        let sorted = values.filter { $0.end > $0.start }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var result: [DateInterval] = []
        for value in sorted {
            guard let last = result.last else {
                result.append(value)
                continue
            }
            if value.start.timeIntervalSince(last.end) < maximumGap {
                result[result.count - 1] = .init(
                    start: last.start,
                    end: max(last.end, value.end)
                )
            } else {
                result.append(value)
            }
        }
        return result
    }

    private static func intersection(_ lhs: DateInterval,
                                     _ rhs: DateInterval) -> DateInterval? {
        let start = max(lhs.start, rhs.start)
        let end = min(lhs.end, rhs.end)
        return end > start ? .init(start: start, end: end) : nil
    }
}
