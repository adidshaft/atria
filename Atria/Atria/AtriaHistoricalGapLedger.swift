import Foundation

/// Durable, bounded bookkeeping for intervals where the live strap stream was
/// unavailable. The ledger deliberately stores coverage evidence only from
/// metric-usable historical rows; a successful BLE reconnect by itself never
/// claims that missing heart-rate data was recovered.
enum AtriaHistoricalGapLedger {
    struct Window: Codable, Equatable, Identifiable {
        let id: UUID
        var start: Date
        var end: Date?
        var reason: String
        var coveredBucketIndexes: [Int]

        init(id: UUID = UUID(),
             start: Date,
             end: Date? = nil,
             reason: String,
             coveredBucketIndexes: [Int] = []) {
            self.id = id
            self.start = start
            self.end = end
            self.reason = reason
            self.coveredBucketIndexes = coveredBucketIndexes
        }
    }

    struct MetricRowResult: Equatable {
        let matchedWindows: Int
        let resolvedWindows: Int
        let remainingWindows: Int
    }

    struct CloseResult: Equatable {
        let closedWindow: Bool
        let resolvedWindows: Int
        let remainingWindows: Int
    }

    static let defaultsKey = "atria.offlineSync.missingWindows.v1"
    /// A lightweight predecessor for the first accepted pulse after process
    /// restoration. The full active-session journal intentionally loads off the
    /// main actor; without this anchor a fresh CoreBluetooth notification can
    /// arrive first and make an otherwise recoverable suspension invisible.
    /// This stores a timestamp only. It is never treated as a heart-rate sample
    /// or coverage evidence.
    static let liveContinuityAnchorKey = "atria.offlineSync.lastAcceptedLiveMetricAt.v1"
    static let maximumWindows = 16
    static let coverageBucketSeconds: TimeInterval = 15
    static let minimumResolvedCoveragePercent = 75
    static let liveContinuityAnchorWriteInterval: TimeInterval = 15
    static let maximumRecoverableAnchorAge: TimeInterval = 18 * 60 * 60
    static let coalescedWindowReason = "coalesced_unresolved_history"

    static func windows(defaults: UserDefaults = .standard) -> [Window] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Window].self, from: data) else {
            return []
        }
        return bounded(decoded)
    }

    @discardableResult
    static func beginGap(at start: Date,
                         reason: String,
                         defaults: UserDefaults = .standard) -> Bool {
        var current = windows(defaults: defaults)
        if let openIndex = current.lastIndex(where: { $0.end == nil }) {
            if start < current[openIndex].start {
                current[openIndex].start = start
                // Bucket indexes are relative to `start`; rebasing them would
                // turn old evidence into the wrong timestamps. Fail closed.
                current[openIndex].coveredBucketIndexes = []
                persist(current, defaults: defaults)
            }
            return false
        }
        current.append(Window(start: start, reason: reason))
        persist(current, defaults: defaults)
        return true
    }

    /// Closes the newest open interval on the first accepted post-reconnect HR.
    /// Short transitions below the product's 15-second continuity boundary are
    /// discarded because they do not represent missing workout coverage.
    @discardableResult
    static func closeOpenGap(at end: Date,
                             minimumDuration: TimeInterval = coverageBucketSeconds,
                             defaults: UserDefaults = .standard) -> Bool {
        closeOpenGapWithResult(at: end,
                               minimumDuration: minimumDuration,
                               defaults: defaults).closedWindow
    }

    /// Closes the newest open interval and evaluates metric-usable buckets
    /// buffered while the link was down. An open interval can never resolve
    /// early, and buckets beyond the eventual reconnect boundary are discarded.
    @discardableResult
    static func closeOpenGapWithResult(
        at end: Date,
        minimumDuration: TimeInterval = coverageBucketSeconds,
        defaults: UserDefaults = .standard
    ) -> CloseResult {
        var current = windows(defaults: defaults)
        guard let index = current.lastIndex(where: { $0.end == nil }) else {
            return CloseResult(closedWindow: false,
                               resolvedWindows: 0,
                               remainingWindows: current.count)
        }
        let duration = end.timeIntervalSince(current[index].start)
        if duration <= minimumDuration {
            current.remove(at: index)
            persist(current, defaults: defaults)
            return CloseResult(closedWindow: false,
                               resolvedWindows: 0,
                               remainingWindows: current.count)
        }
        current[index].end = end
        let totalBuckets = bucketCount(start: current[index].start, end: end)
        current[index].coveredBucketIndexes = current[index].coveredBucketIndexes
            .filter { (0..<totalBuckets).contains($0) }
            .sorted()
        let resolved = coveragePercent(for: current[index]) >= minimumResolvedCoveragePercent
        if resolved {
            current.remove(at: index)
        }
        persist(current, defaults: defaults)
        return CloseResult(closedWindow: true,
                           resolvedWindows: resolved ? 1 : 0,
                           remainingWindows: current.count)
    }

    /// Records a gap observed from consecutive accepted HR timestamps, covering
    /// suspension/silent-link cases where CoreBluetooth emitted no disconnect.
    @discardableResult
    static func recordObservedGap(start: Date,
                                  end: Date,
                                  reason: String,
                                  minimumDuration: TimeInterval = coverageBucketSeconds,
                                  defaults: UserDefaults = .standard) -> Bool {
        guard end.timeIntervalSince(start) > minimumDuration else { return false }
        var current = windows(defaults: defaults).filter { $0.end != nil }
        let candidate = Window(start: start, end: end, reason: reason)
        if let last = current.last,
           let lastEnd = last.end,
           candidate.start <= lastEnd.addingTimeInterval(1) {
            current[current.count - 1].end = max(lastEnd, end)
            current[current.count - 1].coveredBucketIndexes = []
        } else {
            current.append(candidate)
        }
        persist(current, defaults: defaults)
        return true
    }

    /// Adds one historical row as coverage evidence. Rows received while a gap
    /// is open are buffered into timestamp buckets but cannot resolve it. A
    /// closed window resolves only after metric-usable rows occupy at least 75%
    /// of its 15-second buckets. Duplicate replay rows collapse to one bucket.
    @discardableResult
    static func recordMetricUsableRow(at timestamp: Date,
                                      defaults: UserDefaults = .standard) -> MetricRowResult {
        var current = windows(defaults: defaults)
        var matched = 0
        var resolved = 0
        var changed = false
        for index in current.indices.reversed() {
            guard timestamp >= current[index].start else { continue }
            if let end = current[index].end, timestamp > end { continue }
            matched += 1
            let offset = max(0, timestamp.timeIntervalSince(current[index].start))
            let bucket = Int(offset / coverageBucketSeconds)
            if !current[index].coveredBucketIndexes.contains(bucket) {
                current[index].coveredBucketIndexes.append(bucket)
                current[index].coveredBucketIndexes.sort()
                changed = true
            }
            if current[index].end != nil,
               coveragePercent(for: current[index]) >= minimumResolvedCoveragePercent {
                current.remove(at: index)
                resolved += 1
                changed = true
            }
        }
        if changed {
            persist(current, defaults: defaults)
        }
        return MetricRowResult(matchedWindows: matched,
                               resolvedWindows: resolved,
                               remainingWindows: current.count)
    }

    static func coveragePercent(for window: Window) -> Int {
        guard let end = window.end, end > window.start else { return 0 }
        let total = bucketCount(start: window.start, end: end)
        let covered = Set(window.coveredBucketIndexes.filter { (0..<total).contains($0) }).count
        return min(100, Int((Double(covered) / Double(total) * 100).rounded(.down)))
    }

    static func hasPendingWindows(defaults: UserDefaults = .standard) -> Bool {
        !windows(defaults: defaults).isEmpty
    }

    static func hasOpenWindow(defaults: UserDefaults = .standard) -> Bool {
        windows(defaults: defaults).contains { $0.end == nil }
    }

    /// Returns only a plausible, finite timestamp. A malformed or future value
    /// must not create a synthetic historical-recovery interval.
    static func liveContinuityAnchor(defaults: UserDefaults = .standard,
                                     now: Date = Date()) -> Date? {
        guard let raw = defaults.object(forKey: liveContinuityAnchorKey) as? Double,
              raw.isFinite,
              raw > 0,
              raw <= now.timeIntervalSince1970 + 5 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    /// Advances the durable predecessor at most once per coverage bucket. This
    /// bounds UserDefaults traffic while keeping the launch-race uncertainty no
    /// larger than the ledger's own 15-second resolution. It never moves
    /// backwards, including when delayed callbacks arrive out of order.
    @discardableResult
    static func advanceLiveContinuityAnchor(to timestamp: Date,
                                            force: Bool = false,
                                            defaults: UserDefaults = .standard) -> Bool {
        let raw = timestamp.timeIntervalSince1970
        guard raw.isFinite, raw > 0 else { return false }
        let priorRaw = defaults.object(forKey: liveContinuityAnchorKey) as? Double
        if let priorRaw, priorRaw.isFinite {
            guard raw > priorRaw else { return false }
            guard force || raw - priorRaw >= liveContinuityAnchorWriteInterval else {
                return false
            }
        }
        defaults.set(raw, forKey: liveContinuityAnchorKey)
        return true
    }

    /// Reconstructs only the missing *window* when the first accepted pulse in
    /// this process has no in-memory predecessor. No HR, RR, steps, calories or
    /// strain are created. Historical metric rows must still independently
    /// cover 75% of this exact interval before it can resolve.
    @discardableResult
    static func recordRestorationGapIfNeeded(firstAcceptedAt timestamp: Date,
                                             reason: String,
                                             minimumDuration: TimeInterval = coverageBucketSeconds,
                                             maximumAnchorAge: TimeInterval = maximumRecoverableAnchorAge,
                                             defaults: UserDefaults = .standard) -> Bool {
        defer {
            _ = advanceLiveContinuityAnchor(to: timestamp,
                                            force: true,
                                            defaults: defaults)
        }
        guard let anchor = liveContinuityAnchor(defaults: defaults, now: timestamp) else {
            // Replace malformed/future persisted state with this real accepted
            // observation. `advance` normally refuses to move backwards, so the
            // invalid value must be removed explicitly first.
            if defaults.object(forKey: liveContinuityAnchorKey) != nil {
                defaults.removeObject(forKey: liveContinuityAnchorKey)
            }
            return false
        }
        let anchorAge = timestamp.timeIntervalSince(anchor)
        // The throttled anchor proves only that a pulse existed at `anchor`;
        // another pulse may have arrived during the following write interval.
        // Start after that uncertainty band so a quick relaunch can never be
        // mislabeled as missing strap history. This deliberately under-recovers
        // at most one 15-second bucket rather than inventing an outage.
        let conservativeStart = anchor.addingTimeInterval(liveContinuityAnchorWriteInterval)
        guard timestamp.timeIntervalSince(conservativeStart) > minimumDuration,
              anchorAge <= maximumAnchorAge,
              !hasOpenWindow(defaults: defaults) else { return false }
        return recordObservedGap(start: conservativeStart,
                                 end: timestamp,
                                 reason: reason,
                                 minimumDuration: minimumDuration,
                                 defaults: defaults)
    }

    static func clearLiveContinuityAnchor(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: liveContinuityAnchorKey)
    }

    private static func bucketCount(start: Date, end: Date) -> Int {
        max(1, Int(ceil(max(0, end.timeIntervalSince(start)) / coverageBucketSeconds)))
    }

    /// Keeps the defaults payload bounded without silently forgetting the
    /// oldest unresolved outages. Once the cap is reached, the oldest prefix
    /// becomes one conservative envelope with no inherited bucket coverage.
    /// It can resolve only if verified metric rows cover that whole envelope;
    /// ordinary rows covering only the newest gaps can never erase it.
    private static func bounded(_ windows: [Window]) -> [Window] {
        let sorted = windows.sorted { $0.start < $1.start }
        guard sorted.count > maximumWindows else { return sorted }

        let mergeCount = sorted.count - maximumWindows + 1
        let prefix = Array(sorted.prefix(mergeCount))
        guard let first = prefix.first else { return Array(sorted.suffix(maximumWindows)) }
        let mergedEnd: Date? = prefix.contains(where: { $0.end == nil })
            ? nil
            : prefix.compactMap(\.end).max()
        let merged = Window(id: first.id,
                            start: first.start,
                            end: mergedEnd,
                            reason: coalescedWindowReason,
                            coveredBucketIndexes: [])
        return [merged] + Array(sorted.suffix(maximumWindows - 1))
    }

    private static func persist(_ windows: [Window], defaults: UserDefaults) {
        let boundedWindows = bounded(windows)
        guard !boundedWindows.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(boundedWindows) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
