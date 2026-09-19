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

    /// ASKING is rarer than COUNTING. Owner feedback (2026-08-28): a full
    /// wear day produced a long list of small stretches nobody can remember —
    /// "it is not guaranteed that the users will remember when they walked".
    /// Only major, confident motion earns a question; minor clusters stay
    /// included in the count and are disclosed in aggregate, never itemised.
    static let askableMinimumSteps = 800
    static let askableMinimumActiveMinutes = 10
    static let maximumQuestionsPerDay = 3

    struct Partition: Equatable {
        /// Worth a question: major, unanswered, capped at
        /// `maximumQuestionsPerDay`, biggest first.
        let askable: [Cluster]
        /// Auto-answered from the wearer's own repeated explicit answers.
        let autoResolved: [(cluster: Cluster, verdict: AtriaNonGaitArbitrationStore.Verdict)]
        /// Included in the count, disclosed in aggregate only.
        let minorSteps: Int

        static func == (lhs: Partition, rhs: Partition) -> Bool {
            lhs.askable == rhs.askable
                && lhs.minorSteps == rhs.minorSteps
                && lhs.autoResolved.map(\.cluster) == rhs.autoResolved.map(\.cluster)
                && lhs.autoResolved.map(\.verdict) == rhs.autoResolved.map(\.verdict)
        }
    }

    /// Split detected clusters into questions, learned answers, and minor
    /// noise. Learned answers are RECORDED (auto-flagged) so every step
    /// surface picks them up through the store, and the sheet can show them
    /// with an undo.
    static func partition(
        clusters: [Cluster],
        store: AtriaNonGaitArbitrationStore,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Partition {
        var askable: [Cluster] = []
        var auto: [(Cluster, AtriaNonGaitArbitrationStore.Verdict)] = []
        var minor = 0
        for cluster in clusters {
            if let learned = store.learnedVerdict(startingAt: cluster.start,
                                                  calendar: calendar) {
                store.record(window: cluster.window, verdict: learned,
                             auto: true, now: now)
                auto.append((cluster, learned))
                continue
            }
            if cluster.estimatedSteps >= askableMinimumSteps,
               cluster.activeMinutes >= askableMinimumActiveMinutes {
                askable.append(cluster)
            } else {
                minor += cluster.estimatedSteps
            }
        }
        askable.sort { $0.estimatedSteps > $1.estimatedSteps }
        let overflow = askable.dropFirst(maximumQuestionsPerDay)
        minor += overflow.reduce(0) { $0 + $1.estimatedSteps }
        return Partition(askable: Array(askable.prefix(maximumQuestionsPerDay)),
                         autoResolved: auto,
                         minorSteps: minor)
    }

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
        /// True when the app applied a learned verdict rather than the wearer
        /// tapping. Auto answers never feed learning (no self-compounding)
        /// and always carry an undo in the sheet. Optional so legacy files
        /// decode; nil means explicit.
        var auto: Bool?

        var id: Date { start }
        var window: DateInterval { DateInterval(start: start, end: end) }
        var isAuto: Bool { auto == true }
    }

    /// The wearer's pattern, learned from EXPLICIT answers only: three
    /// consistent verdicts for clusters starting in the same 3-hour local
    /// band, with none contrary, auto-resolve future clusters in that band.
    /// One contrary answer anywhere in the band disables learning for it —
    /// ambiguity goes back to the wearer.
    static let learningMinimumConsistentAnswers = 3

    func learnedVerdict(startingAt start: Date,
                        calendar: Calendar = .current) -> Verdict? {
        let band = calendar.component(.hour, from: start) / 3
        let explicit = answers().filter {
            !$0.isAuto
                && calendar.component(.hour, from: $0.start) / 3 == band
        }
        let walking = explicit.filter { $0.verdict == .walking }.count
        let notWalking = explicit.filter { $0.verdict == .notWalking }.count
        if notWalking >= Self.learningMinimumConsistentAnswers, walking == 0 {
            return .notWalking
        }
        if walking >= Self.learningMinimumConsistentAnswers, notWalking == 0 {
            return .walking
        }
        return nil
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

    func record(window: DateInterval, verdict: Verdict,
                auto: Bool = false, now: Date = Date()) {
        queue.sync {
            var current = cached ?? ((try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode([Answer].self, from: $0) }
                ?? [])
            // An explicit answer always replaces an auto one; an auto answer
            // never replaces an explicit one — the wearer outranks the model.
            if auto, current.contains(where: { $0.window == window && !$0.isAuto }) {
                return
            }
            current.removeAll { $0.window == window }
            current.append(Answer(start: window.start, end: window.end,
                                  verdict: verdict, decidedAt: now,
                                  auto: auto ? true : nil))
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
