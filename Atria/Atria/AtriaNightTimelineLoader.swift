import Foundation
import SwiftUI

/// One stored main sleep the timeline can be built for.
struct AtriaNightTimelineRequest: Equatable, Hashable, Sendable {
    let sleepID: String
    let start: Date
    let end: Date
    let eventTimeZoneIdentifier: String?

    /// Changes whenever the stored window is edited, so a re-edited night is
    /// re-analysed instead of served from a stale summary.
    var key: String {
        "\(sleepID)|\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))"
    }

    var timeZone: TimeZone {
        eventTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// Confirmed main sleeps only; naps never feed the night timeline or the
    /// personal baseline (a nap is not a night).
    static func mainSleeps(in history: SleepHistorySnapshot) -> [Self] {
        var seen = Set<String>()
        return (history.nights + history.additionalMainNights)
            .filter { $0.confirmed && !$0.isNapEvidence && $0.source != "resumed_sleep" }
            .compactMap { night -> Self? in
                guard let start = night.start, let end = night.end, end > start,
                      seen.insert(night.id).inserted else { return nil }
                return Self(sleepID: night.id, start: start, end: end,
                            eventTimeZoneIdentifier: night.eventTimeZoneIdentifier)
            }
            .sorted { $0.end > $1.end }
    }

    static func latestMainSleep(in history: SleepHistorySnapshot) -> Self? {
        guard let night = history.latestMainSleep,
              let start = night.start, let end = night.end, end > start else { return nil }
        return Self(sleepID: night.id, start: start, end: end,
                    eventTimeZoneIdentifier: night.eventTimeZoneIdentifier)
    }
}

/// Session-held samples for one window, captured on the main actor (cheap
/// filter) and processed off it.
struct AtriaNightSessionSamples: Sendable {
    var heartRate: [AtriaNightMinuteBuilder.HeartRateSample] = []
    var rr: [AtriaNightMinuteBuilder.RRSample] = []

    /// Live-session HR is the fallback when the exact archive read fails;
    /// RR only ever comes from sessions, and only with a known source
    /// (legacy source-less intervals fail every HRV gate in the app).
    static func from(_ sessions: [SavedSession], window: DateInterval) -> Self {
        var out = Self()
        for session in sessions where session.end > window.start && session.start < window.end {
            for point in session.points {
                let t = session.start.addingTimeInterval(point.t)
                if window.contains(t) { out.heartRate.append(.init(t: t, bpm: point.bpm)) }
            }
            for point in session.rrPoints ?? [] where point.source != nil {
                let t = session.start.addingTimeInterval(point.t)
                if window.contains(t) { out.rr.append(.init(t: t, ms: point.ms)) }
            }
        }
        return out
    }
}

/// A built night: the analyzed model plus how much of it had data.
struct AtriaNightTimelineLoaded: Equatable {
    let request: AtriaNightTimelineRequest
    let model: AtriaNightTimelineModel
    let coverage: AtriaNightMinuteBuilder.Coverage
    let summary: AtriaNightSummary?
}

enum AtriaNightTimelineLoader {
    /// Generous for a ≤ 18 h window of 1 Hz history plus live samples; the
    /// exact read fails closed (nil) rather than truncating.
    static let maximumHeartRatePoints = 160_000

    /// Reads the stores for one night and builds it. MUST run off the main
    /// actor: the motion store asserts it, and the archive read is file I/O.
    /// Uses only the catalog-bounded exact-window HR read — never the
    /// `metricHeartRatePoints(since:limit:)` tail facade, which rescans the
    /// whole archive per call (the 144 s CPU trap).
    static func load(_ request: AtriaNightTimelineRequest,
                     sessionSamples: AtriaNightSessionSamples,
                     strapIdentifier: String?) -> AtriaNightTimelineLoaded? {
        precondition(!Thread.isMainThread, "night timeline store reads run off the main thread")
        guard let window = AtriaNightMinuteBuilder.window(sleepStart: request.start,
                                                          sleepEnd: request.end) else { return nil }
        var heartRate: [AtriaNightMinuteBuilder.HeartRateSample]
        if let read = HistoricalArchive.metricHeartRatePoints(start: window.start,
                                                             end: window.end,
                                                             maximumPoints: maximumHeartRatePoints),
           !read.points.isEmpty {
            heartRate = read.points.map { .init(t: $0.t, bpm: $0.bpm) }
        } else {
            heartRate = sessionSamples.heartRate
        }
        if heartRate.isEmpty { heartRate = sessionSamples.heartRate }

        var motion: [AtriaNightMinuteBuilder.MotionSample] = []
        if let strapIdentifier, !strapIdentifier.isEmpty {
            motion = AtriaWhoop4MotionTickCompactStore.shared
                .decodedPoints(start: window.start, end: window.end, strapIdentifier: strapIdentifier)
                .map { .init(timestamp: $0.timestamp, tick: $0.tick, scalar: $0.unknownMotionScalar32) }
        }
        return assemble(request, window: window, heartRate: heartRate, motion: motion,
                        rr: sessionSamples.rr)
    }

    /// Pure tail of `load`, exposed for tests.
    static func assemble(_ request: AtriaNightTimelineRequest,
                         window: DateInterval,
                         heartRate: [AtriaNightMinuteBuilder.HeartRateSample],
                         motion: [AtriaNightMinuteBuilder.MotionSample],
                         rr: [AtriaNightMinuteBuilder.RRSample]) -> AtriaNightTimelineLoaded {
        let build = AtriaNightMinuteBuilder.build(window: window, heartRate: heartRate,
                                                  motion: motion, rr: rr)
        let model = AtriaNightTimelineModel(minutes: build.minutes,
                                            timeZone: request.timeZone,
                                            coverage: build.coverage,
                                            sleepWindow: DateInterval(start: request.start, end: request.end))
        return AtriaNightTimelineLoaded(
            request: request, model: model, coverage: build.coverage,
            summary: AtriaNightSummary.from(model.result, minutes: build.minutes))
    }
}

/// Durable per-night summaries so the personal baseline never re-reads old
/// nights. Private to this phone (UserDefaults), bounded, keyed by the stored
/// window so an edited night is recomputed.
enum AtriaNightSummaryStore {
    static let defaultsKey = "atria.nightSummaries.v1"
    static let maximumEntries = 60
    /// Bump when the builder or analyzer changes meaning.
    static let builderVersion = 1

    struct Entry: Codable, Equatable {
        let key: String
        let sleepID: String
        /// nil = analysed, but sleep could not be placed (still recorded so
        /// the night is not re-read on every visit).
        let summary: AtriaNightSummary?
        let builderVersion: Int
        /// When the night was analysed (nil on entries from older builds).
        var analysedAt: Date?
        var nightEnd: Date?

        /// Strap history can land days after a night (drain lag). An entry
        /// that did not qualify is retried once a day while its night is
        /// recent enough for missing rows still to arrive.
        func isWorthRetrying(now: Date) -> Bool {
            if let summary, summary.coverage >= AtriaNightBaseline.minimumCoverage { return false }
            guard let analysedAt, let nightEnd else { return false }
            return now.timeIntervalSince(analysedAt) >= AtriaNightSummaryStore.retryAfter
                && now.timeIntervalSince(nightEnd) <= AtriaNightSummaryStore.retryWindow
        }
    }

    static let retryAfter: TimeInterval = 24 * 3_600
    static let retryWindow: TimeInterval = 7 * 24 * 3_600

    static func all(defaults: UserDefaults = .standard) -> [Entry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.filter { $0.builderVersion == builderVersion }
    }

    static func record(_ summary: AtriaNightSummary?,
                       for request: AtriaNightTimelineRequest,
                       now: Date = Date(),
                       defaults: UserDefaults = .standard) {
        var entries = all(defaults: defaults).filter { $0.sleepID != request.sleepID }
        entries.append(Entry(key: request.key, sleepID: request.sleepID,
                             summary: summary, builderVersion: builderVersion,
                             analysedAt: now, nightEnd: request.end))
        if entries.count > maximumEntries {
            entries = Array(entries.sorted { ($0.nightEnd ?? .distantPast) < ($1.nightEnd ?? .distantPast) }
                .suffix(maximumEntries))
        }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: defaultsKey) }
    }

    /// Requests to (re)analyse: never analysed or edited since first, then
    /// recent nights whose earlier analysis lacked data.
    static func missing(_ requests: [AtriaNightTimelineRequest],
                        now: Date = Date(),
                        defaults: UserDefaults = .standard) -> [AtriaNightTimelineRequest] {
        let byKey = Dictionary(all(defaults: defaults).map { ($0.key, $0) },
                               uniquingKeysWith: { _, latest in latest })
        let never = requests.filter { byKey[$0.key] == nil }
        let retry = requests.filter { byKey[$0.key]?.isWorthRetrying(now: now) == true }
        return never + retry
    }

    /// Summaries for nights that still exist as confirmed main sleeps, with
    /// their current window. Deleted or edited nights drop out.
    static func history(for requests: [AtriaNightTimelineRequest],
                        defaults: UserDefaults = .standard) -> [AtriaNightSummary] {
        let keys = Set(requests.map(\.key))
        return all(defaults: defaults).filter { keys.contains($0.key) }.compactMap(\.summary)
    }
}

/// Shared, main-actor owner of built nights for the Sleep detail card and the
/// Today morning prompt. All store reads happen on a utility queue.
@MainActor
final class AtriaNightTimelineStore: ObservableObject {
    static let shared = AtriaNightTimelineStore()

    enum State: Equatable {
        case idle
        case loading
        case loaded(AtriaNightTimelineLoaded)
        case unavailable
    }

    @Published private(set) var states: [String: State] = [:]
    /// Personal-baseline comparison for each loaded night (by request key).
    @Published private(set) var baselines: [String: AtriaNightBaselineReport] = [:]

    /// Nights analysed per backfill pass, so opening Sleep never queues a
    /// month of reads at once. The baseline fills in over a few visits.
    static let backfillPerPass = 4

    private let queue = DispatchQueue(label: "atria.night-timeline", qos: .utility)
    private var inFlight = Set<String>()
    private var loadedAt: [String: Date] = [:]
    /// A night with gaps is re-read after this long: strap history drains
    /// late, and the card should fill in without an app relaunch.
    static let incompleteReloadAfter: TimeInterval = 15 * 60

    func state(for request: AtriaNightTimelineRequest) -> State {
        states[request.key] ?? .idle
    }

    func loaded(for request: AtriaNightTimelineRequest?) -> AtriaNightTimelineLoaded? {
        guard let request, case .loaded(let loaded) = state(for: request) else { return nil }
        return loaded
    }

    /// Builds `request` (if needed), then backfills a few earlier main sleeps
    /// for the baseline. `sessions` supplies live-session HR/RR per window.
    func ensureLoaded(_ request: AtriaNightTimelineRequest,
                      history: [AtriaNightTimelineRequest],
                      sessions: ((DateInterval) -> [SavedSession])?) {
        guard !inFlight.contains(request.key) else { return }
        if case .loaded(let loaded) = state(for: request) {
            let complete = loaded.coverage.heartRateFraction >= 0.9 && loaded.coverage.motionFraction >= 0.9
            let age = loadedAt[request.key].map { Date().timeIntervalSince($0) } ?? .infinity
            if complete || age < Self.incompleteReloadAfter {
                refreshBaseline(for: request, history: history)
                return
            }
        }
        let prior = Array(history.filter { $0.end < request.end }
            .prefix(AtriaNightBaseline.maximumNights))
        let backfill = Array(AtriaNightSummaryStore.missing(prior).prefix(Self.backfillPerPass))
        let jobs = [request] + backfill
        var samples: [String: AtriaNightSessionSamples] = [:]
        for job in jobs {
            guard let window = AtriaNightMinuteBuilder.window(sleepStart: job.start, sleepEnd: job.end),
                  let sessions else { continue }
            samples[job.key] = AtriaNightSessionSamples.from(sessions(window), window: window)
        }
        let strap = AtriaWhoop4MotionTickDailyStore.persistedStrapIdentifiers().first
        inFlight.insert(request.key)
        if loaded(for: request) == nil { states[request.key] = .loading }
        queue.async { [weak self] in
            var results: [(AtriaNightTimelineRequest, AtriaNightTimelineLoaded?)] = []
            for job in jobs {
                let loaded = AtriaNightTimelineLoader.load(job,
                                                           sessionSamples: samples[job.key] ?? .init(),
                                                           strapIdentifier: strap)
                results.append((job, loaded))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (job, loaded) in results {
                    AtriaNightSummaryStore.record(loaded?.summary, for: job)
                    if job.key == request.key {
                        self.states[job.key] = loaded.map { .loaded($0) } ?? .unavailable
                        self.loadedAt[job.key] = Date()
                    }
                }
                self.inFlight.remove(request.key)
                self.refreshBaseline(for: request, history: history)
            }
        }
    }

    private func refreshBaseline(for request: AtriaNightTimelineRequest,
                                 history: [AtriaNightTimelineRequest]) {
        guard let tonight = loaded(for: request)?.summary else {
            baselines[request.key] = nil
            return
        }
        let prior = AtriaNightSummaryStore.history(for: history.filter { $0.key != request.key })
        baselines[request.key] = AtriaNightBaselineReport(tonight: tonight, history: prior)
    }

    #if DEBUG
    /// UI fixtures: install a built night and its baseline without any reads.
    func installForFixture(_ loaded: AtriaNightTimelineLoaded, baseline: AtriaNightBaselineReport?) {
        states[loaded.request.key] = .loaded(loaded)
        baselines[loaded.request.key] = baseline
    }
    #endif
}

/// The baseline comparison plus the nights it was computed from (for the
/// chart). Built only from the same person's own stored nights.
struct AtriaNightBaselineReport: Equatable {
    let tonight: AtriaNightSummary
    /// Qualifying prior nights, newest first (what `compare` used).
    let prior: [AtriaNightSummary]
    let outcome: AtriaNightBaseline.Outcome

    init(tonight: AtriaNightSummary, history: [AtriaNightSummary]) {
        self.tonight = tonight
        self.prior = history
            .filter { $0.coverage >= AtriaNightBaseline.minimumCoverage && $0.night < tonight.night }
            .sorted { $0.night > $1.night }
            .prefix(AtriaNightBaseline.maximumNights)
            .map { $0 }
        self.outcome = AtriaNightBaseline.compare(tonight: tonight, history: history)
    }

    /// At most three short lines: notable/unusual first (largest effect
    /// first), otherwise one "typical" line plus sleeping heart rate.
    var lines: [String] {
        guard case .compared(let comparisons) = outcome else { return [] }
        let flagged = comparisons.filter { $0.severity != .typical }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity == .unusual }
                return abs(lhs.delta) / AtriaNightBaseline.minimumEffect(lhs.metric)
                    > abs(rhs.delta) / AtriaNightBaseline.minimumEffect(rhs.metric)
            }
        if !flagged.isEmpty { return Array(flagged.prefix(3).map(\.sentence)) }
        var out = ["A typical night for you."]
        if let hr = comparisons.first(where: { $0.metric == .sleepingHeartRate }) { out.append(hr.sentence) }
        return out
    }

    /// "Learning (n/5)" until enough of the person's own nights exist.
    var learningText: String? {
        guard case .learning(let n, let needed) = outcome else { return nil }
        return "Learning (\(n)/\(needed))"
    }
}
