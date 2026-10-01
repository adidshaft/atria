import Foundation

/// Day-load (TRIMP) of closed wake-to-wake cycles, remembered while the
/// cycle's sessions were still resident (2026-10-01).
///
/// The closed-cycle strain series recomputes the last 66 cycles on every
/// rollup preparation, but the resident session store keeps only a few days;
/// older sessions move to the full-fidelity cold store. Recomputing an aged
/// cycle from what is left collapsed it (device: Sep 28 with two logged
/// workouts went 8.7 -> 0.5). A closed cycle's load does not change once its
/// data is complete, so it is remembered here and reused once its sessions
/// age out. The key carries the exact cycle bounds and the confirmed
/// workouts inside it, so editing either recomputes the cycle.
final class AtriaClosedCycleStrainStore: @unchecked Sendable {
    static let shared = AtriaClosedCycleStrainStore(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("atria-closed-cycle-strain-v1.json")
    )
    static let maximumEntries = 120

    struct Entry: Codable, Equatable {
        let start: Double
        let end: Double
        let workoutsKey: String
        let trimp: Double
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [Entry]?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func workoutsKey(_ workouts: [UserConfirmedWorkout], in interval: DateInterval) -> String {
        workouts
            .filter { $0.end > interval.start && $0.start < interval.end }
            .map { "\($0.id):\(Int((($0.strain ?? 0) * 100).rounded()))" }
            .sorted()
            .joined(separator: ",")
    }

    func trimp(for interval: DateInterval, workoutsKey: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return loadedLocked().first {
            $0.start == interval.start.timeIntervalSince1970
                && $0.end == interval.end.timeIntervalSince1970
                && $0.workoutsKey == workoutsKey
        }?.trimp
    }

    func record(trimp: Double, for interval: DateInterval, workoutsKey: String) {
        lock.lock()
        defer { lock.unlock() }
        let start = interval.start.timeIntervalSince1970
        let end = interval.end.timeIntervalSince1970
        var current = loadedLocked()
        let entry = Entry(start: start, end: end, workoutsKey: workoutsKey, trimp: trimp)
        if current.contains(entry) { return }
        current.removeAll { $0.start == start }
        current.append(entry)
        current.sort { $0.start > $1.start }
        entries = Array(current.prefix(Self.maximumEntries))
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func loadedLocked() -> [Entry] {
        if let entries { return entries }
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = loaded
        return loaded
    }
}
