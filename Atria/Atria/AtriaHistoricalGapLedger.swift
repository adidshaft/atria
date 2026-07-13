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

    static let defaultsKey = "atria.offlineSync.missingWindows.v1"
    static let maximumWindows = 16
    static let coverageBucketSeconds: TimeInterval = 15
    static let minimumResolvedCoveragePercent = 75

    static func windows(defaults: UserDefaults = .standard) -> [Window] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Window].self, from: data) else {
            return []
        }
        return Array(decoded.sorted { $0.start < $1.start }.suffix(maximumWindows))
    }

    @discardableResult
    static func beginGap(at start: Date,
                         reason: String,
                         defaults: UserDefaults = .standard) -> Bool {
        var current = windows(defaults: defaults)
        if let openIndex = current.lastIndex(where: { $0.end == nil }) {
            if start < current[openIndex].start {
                current[openIndex].start = start
                persist(current, defaults: defaults)
            }
            return false
        }
        current.append(Window(start: start, reason: reason))
        persist(Array(current.suffix(maximumWindows)), defaults: defaults)
        return true
    }

    /// Closes the newest open interval on the first accepted post-reconnect HR.
    /// Short transitions below the product's 15-second continuity boundary are
    /// discarded because they do not represent missing workout coverage.
    @discardableResult
    static func closeOpenGap(at end: Date,
                             minimumDuration: TimeInterval = coverageBucketSeconds,
                             defaults: UserDefaults = .standard) -> Bool {
        var current = windows(defaults: defaults)
        guard let index = current.lastIndex(where: { $0.end == nil }) else { return false }
        let duration = end.timeIntervalSince(current[index].start)
        if duration <= minimumDuration {
            current.remove(at: index)
            persist(current, defaults: defaults)
            return false
        }
        current[index].end = end
        persist(current, defaults: defaults)
        return true
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
        persist(Array(current.suffix(maximumWindows)), defaults: defaults)
        return true
    }

    /// Adds one historical row as coverage evidence. A closed window resolves
    /// only after metric-usable rows occupy at least 75% of its 15-second
    /// buckets. Duplicate replay rows collapse to the same bucket.
    @discardableResult
    static func recordMetricUsableRow(at timestamp: Date,
                                      defaults: UserDefaults = .standard) -> MetricRowResult {
        var current = windows(defaults: defaults)
        var matched = 0
        var resolved = 0
        for index in current.indices.reversed() {
            guard let end = current[index].end,
                  timestamp >= current[index].start,
                  timestamp <= end else { continue }
            matched += 1
            let totalBuckets = bucketCount(start: current[index].start, end: end)
            let offset = max(0, timestamp.timeIntervalSince(current[index].start))
            let bucket = min(totalBuckets - 1, Int(offset / coverageBucketSeconds))
            if !current[index].coveredBucketIndexes.contains(bucket) {
                current[index].coveredBucketIndexes.append(bucket)
                current[index].coveredBucketIndexes.sort()
            }
            if coveragePercent(for: current[index]) >= minimumResolvedCoveragePercent {
                current.remove(at: index)
                resolved += 1
            }
        }
        if matched > 0 {
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

    private static func bucketCount(start: Date, end: Date) -> Int {
        max(1, Int(ceil(max(0, end.timeIntervalSince(start)) / coverageBucketSeconds)))
    }

    private static func persist(_ windows: [Window], defaults: UserDefaults) {
        guard !windows.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(Array(windows.suffix(maximumWindows))) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
