import Foundation

/// Sustained wrist-counter activity that nothing explains — no confirmed
/// workout, no detected sleep — surfaced for the wearer to arbitrate.
///
/// WHY THIS EXISTS (device evidence, 2026-08-27). The flash tick counter
/// advances during ANY repetitive arm activity, and no drained-data classifier
/// can separate that from walking:
///   - the owner's provably-no-walking evening held two 14-minute runs at
///     60-74 ticks/min — a meal's shape, walking's rate;
///   - gravity aliasing certifies FREE-ARM walking (|dG| 0.11-0.23) but
///     constrained-arm walking (phone in hand) measures 0.31-0.37, identical
///     to the meal (0.23-0.38 — one no-walk run scored BELOW a walk segment);
///   - gating on it cut the owner's verified 7-8k active day to 1,565 — the
///     same refutation the July v6 scalar gate earned by deleting real walks.
///
/// The two truths — "my active day was 7-8k" and "my idle day must not show
/// 4,900" — are the same statistical population in this channel and only the
/// wearer can tell them apart. So: DETECT the unexplained clusters, DISCLOSE
/// them inside the count, and let one tap per cluster answer Walking /
/// Not walking. A "Not walking" answer feeds the existing non-gait exclusion
/// machinery; nothing is ever silently deleted, per the governing asymmetry —
/// over-excluding deletes real walking, the worse error.
enum AtriaUnattributedMotionRuns {

    /// A minute must advance the counter at least this much to count as
    /// active. Sleep idles at ~0.7 ticks/min and sedentary drift under ~15;
    /// sustained activity (walking OR arm work) runs 45-100.
    static let activeMinuteMinimumTicks = 25
    /// Active minutes closer than this join one cluster: a meal or a chore
    /// session pauses and resumes, and prompting per fragment would turn one
    /// question into six.
    static let clusterJoinGap: TimeInterval = 20 * 60
    /// A cluster below either floor is not worth a question. ~250 ticks is
    /// about 210 steps.
    static let minimumClusterTicks = 250
    static let minimumClusterActiveMinutes = 3

    struct Cluster: Equatable, Identifiable {
        let start: Date
        let end: Date
        let ticks: Int
        let activeMinutes: Int

        var id: Date { start }
        var estimatedSteps: Int {
            Int((Double(ticks) * 132.0 / 155.0).rounded())
        }
        var window: DateInterval { DateInterval(start: start, end: end) }
    }

    /// Per-minute counter advance, using the SAME per-pair sanity bound the
    /// sequence reducer applies, so a reset/wrap can never inflate a minute.
    static func minuteTickTotals(
        _ points: [AtriaWhoop4MotionTickCompactStore.Point]
    ) -> [Int: Int] {
        var totals: [Int: Int] = [:]
        let ordered = points.sorted { $0.timestamp < $1.timestamp }
        for (before, after) in zip(ordered, ordered.dropFirst()) {
            let duration = after.timestamp - before.timestamp
            // Up to 90 s between rows still credits the delta (to the earlier
            // minute). Real drained rows arrive at ~1 Hz, but drains and radio
            // modes can thin them — an earlier 5 s cap here silently zeroed
            // whole windows of sparser data, caught when 12 s-spaced fixtures
            // produced no minutes at all while the 1 Hz real-shard test kept
            // passing around the hole.
            guard duration > 0, duration <= 90 else { continue }
            let delta = after.tick >= before.tick
                ? after.tick - before.tick
                : after.tick + 65_536 - before.tick
            guard delta > 0, Double(delta) <= max(12, duration * 12) else { continue }
            totals[Int(before.timestamp / 60), default: 0] += delta
        }
        return totals
    }

    /// Clusters of sustained, unexplained counter activity.
    ///
    /// `explained` carries every window that already accounts for arm motion:
    /// confirmed workouts (footfall or not — a labelled block is answered),
    /// detected sleep, and previously arbitrated runs.
    static func clusters(minuteTicks: [Int: Int],
                         explained: [DateInterval]) -> [Cluster] {
        let active = minuteTicks
            .filter { $0.value >= activeMinuteMinimumTicks }
            .keys
            .sorted()
            .filter { minute in
                let mid = Date(timeIntervalSince1970: Double(minute) * 60 + 30)
                return !explained.contains { $0.contains(mid) }
            }
        guard !active.isEmpty else { return [] }

        var clusters: [[Int]] = [[active[0]]]
        for minute in active.dropFirst() {
            if Double(minute - clusters[clusters.count - 1].last!) * 60
                <= clusterJoinGap {
                clusters[clusters.count - 1].append(minute)
            } else {
                clusters.append([minute])
            }
        }

        return clusters.compactMap { minutes in
            let ticks = minutes.reduce(0) { $0 + (minuteTicks[$1] ?? 0) }
            guard ticks >= minimumClusterTicks,
                  minutes.count >= minimumClusterActiveMinutes else { return nil }
            return Cluster(
                start: Date(timeIntervalSince1970: Double(minutes.first!) * 60),
                end: Date(timeIntervalSince1970: Double(minutes.last! + 1) * 60),
                ticks: ticks,
                activeMinutes: minutes.count
            )
        }
    }
}

/// The wearer's answers, durable. "Not walking" windows join the non-gait
/// exclusion set everywhere steps are computed; "Walking" windows simply stop
/// being asked about. Answers are the ONLY thing persisted — clusters are
/// recomputed from rows, so a drain landing more history refines them.
final class AtriaNonGaitArbitrationStore {

    static let shared = AtriaNonGaitArbitrationStore()

    enum Verdict: String, Codable { case walking, notWalking }

    struct Answer: Codable, Equatable, Identifiable {
        let start: Date
        let end: Date
        let verdict: Verdict
        let decidedAt: Date

        var id: Date { start }
        var window: DateInterval { DateInterval(start: start, end: end) }
    }

    static let didChangeNotification =
        Notification.Name("atria.nonGaitArbitration.didChange")

    private let url: URL
    private let queue = DispatchQueue(label: "atria.non-gait-arbitration")
    private var cached: [Answer]?

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.url = support
                .appendingPathComponent("Atria/verified-step-evidence-v1")
                .appendingPathComponent("non-gait-arbitration-v1.json")
        }
    }

    func answers() -> [Answer] {
        queue.sync {
            if let cached { return cached }
            let loaded = (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode([Answer].self, from: $0) }
                ?? []
            cached = loaded
            return loaded
        }
    }

    /// Windows the wearer has said were NOT walking — the exclusion feed.
    func notWalkingWindows() -> [DateInterval] {
        answers().filter { $0.verdict == .notWalking }.map(\.window)
    }

    /// Every arbitrated window, either verdict — the "stop asking" feed.
    func arbitratedWindows() -> [DateInterval] {
        answers().map(\.window)
    }

    func record(window: DateInterval, verdict: Verdict, now: Date = Date()) {
        queue.sync {
            var current = cached ?? ((try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode([Answer].self, from: $0) }
                ?? [])
            current.removeAll { $0.window == window }
            current.append(Answer(start: window.start, end: window.end,
                                  verdict: verdict, decidedAt: now))
            // Bound the file; two months of answers is ample history.
            current.sort { $0.start > $1.start }
            current = Array(current.prefix(200))
            cached = current
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = try? JSONEncoder().encode(current) {
                try? data.write(to: url, options: .atomic)
            }
        }
        NotificationCenter.default.post(
            name: Self.didChangeNotification, object: nil
        )
    }
}
