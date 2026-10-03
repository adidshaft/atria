import Foundation

/// Exact per-calendar-day strap steps, computed from the compact motion shards
/// through the same evidence read the rest of the pipeline trusts —
/// `AtriaWhoop4MotionTickCompactStore.motionTickDayEvidenceRead` — instead of
/// folding cycle receipts onto days.
///
/// WHY (device audit, 2026-08-27, owner's real shards vs the shipped chart):
///
///     civil day   exact steps   the app showed
///     23 Aug            3,615                0     no receipt covered the day
///     24 Aug           ~7,000              505     receipt frozen under an old
///                                                  coverage-gating bug
///     26 Aug            7,629            2,893     evening ticks smeared onto
///     27 Aug              204            3,404     the next day by the open
///                                                  cycle's predominant-day fold
///
/// Receipts are cycle-scoped, frozen at publication, and can be missing
/// entirely — three independent error classes, all removed by computing each
/// calendar day directly from rows. Receipt folding remains the FALLBACK for
/// days whose shards have rotated out.
///
/// The read is expensive (a full day decodes ~90k rows), so results are cached
/// durably and invalidated by the store's own `sourceFingerprint`, which
/// changes exactly when a background drain lands new rows in a day's shard —
/// a backfilled day self-corrects on the next load.
final class AtriaCivilDayStepAuthority {

    static let shared = AtriaCivilDayStepAuthority()
    /// Wake-to-wake windows (owner 2026-10-01: the Steps headline and its
    /// bars both count since wake). A separate cache so a cycle that starts at
    /// midnight never overwrites that calendar day's record.
    static let cycles = AtriaCivilDayStepAuthority(cacheFileName: "cycle-steps-v1.json")

    /// Activity kinds whose confirmed windows are excluded from step credit.
    ///
    /// DELIBERATELY SHORT. Each entry needs its own evidence, because the
    /// failure mode of over-excluding is deleting real walking — the worse
    /// error. Strength is physically proven (2026-08-24: 5,232 counter ticks
    /// of pure arm work inside one labelled block); Cycling is validated by
    /// the same owner-checked day. Everything else keeps its ticks.
    static let nonGaitActivityKinds: Set<String> = ["Strength", "Cycling"]

    struct DayRecord: Codable, Equatable {
        let dayStartUnix: Double
        let steps: Int
        let ticks: Int
        let knownCoverageSeconds: Int
        let sourceFingerprint: String
        let exclusionFingerprint: String
        let computedAtUnix: Double
        let dayWasComplete: Bool
        /// End of the counted window. Nil on calendar-day records written
        /// before cycle windows existed; those are always one civil day.
        var windowEndUnix: Double? = nil
    }

    private let cacheURL: URL
    private let store: AtriaWhoop4MotionTickCompactStore
    private let queue = DispatchQueue(
        label: "atria.civil-day-steps",
        qos: .utility
    )
    private var records: [Double: DayRecord]?

    init(cacheURL: URL? = nil,
         cacheFileName: String = "civil-day-steps-v1.json",
         store: AtriaWhoop4MotionTickCompactStore = .shared) {
        if let cacheURL {
            self.cacheURL = cacheURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.cacheURL = support
                .appendingPathComponent("Atria/verified-step-evidence-v1")
                .appendingPathComponent(cacheFileName)
        }
        self.store = store
    }

    // MARK: - Pure policy, extracted for tests

    /// A cached day is served without re-reading when the shard fingerprint
    /// and exclusion set are unchanged AND the record is settled: either the
    /// day was complete when computed, or it was recomputed recently enough
    /// that an open day's growth is not visibly stale.
    static func isServable(record: DayRecord,
                           sourceFingerprint: String,
                           exclusionFingerprint: String,
                           now: Date,
                           openDayRefresh: TimeInterval = 5 * 60) -> Bool {
        guard record.sourceFingerprint == sourceFingerprint,
              record.exclusionFingerprint == exclusionFingerprint else {
            return false
        }
        if record.dayWasComplete { return true }
        return now.timeIntervalSince1970 - record.computedAtUnix < openDayRefresh
    }

    /// Share of a calendar day the strap's rows must cover before its total
    /// is shown as a whole day. Below it the bar is a partial "at least"
    /// count (strap off, charging, or history not yet drained). A coverage
    /// ratio, so it holds for every wearer; nothing here is per-person.
    static let wholeDayCoverageFraction = 0.8

    /// A day still open, or covered for under `wholeDayCoverageFraction` of
    /// its length (DST-aware via `dayLength`), is partial.
    static func isPartial(record: DayRecord, dayLength: TimeInterval) -> Bool {
        guard record.dayWasComplete, dayLength > 0 else { return true }
        return Double(record.knownCoverageSeconds) / dayLength < wholeDayCoverageFraction
    }

    /// Confirmed non-gait workout windows, for `excludedIntervals`.
    static func nonGaitExclusionWindows(
        workouts: [UserConfirmedWorkout]
    ) -> [DateInterval] {
        workouts.compactMap { workout in
            let kind = workout.activityType ?? workout.label
            guard nonGaitActivityKinds.contains(kind),
                  workout.end > workout.start else { return nil }
            return DateInterval(start: workout.start, end: workout.end)
        }
        .sorted { $0.start < $1.start }
    }

    /// Stable identity for the exclusion set clipped to one day, so adding a
    /// labelled workout invalidates exactly the day it touches.
    static func exclusionFingerprint(_ exclusions: [DateInterval],
                                     dayStart: Date,
                                     dayEnd: Date) -> String {
        exclusions
            .compactMap { interval -> String? in
                let lo = max(interval.start, dayStart)
                let hi = min(interval.end, dayEnd)
                guard hi > lo else { return nil }
                return "\(Int(lo.timeIntervalSince1970))-\(Int(hi.timeIntervalSince1970))"
            }
            .sorted()
            .joined(separator: "|")
    }

    /// Exact values override the receipt fallback; days the shards cannot
    /// answer keep the fallback number rather than going blank.
    static func overlay(fallback: [Date: Int],
                        exact: [Date: Int]) -> [Date: Int] {
        fallback.merging(exact) { _, exactValue in exactValue }
    }

    /// End of the civil day that starts at `dayStart`: the next local
    /// midnight. A fixed 86,400 s is wrong twice a year wherever clocks
    /// change — the spring-forward day is 23 h (the fixed end reads an hour
    /// of the next day into this one) and the fall-back day is 25 h (its last
    /// hour belongs to no day at all). 2026-09-24 code review.
    static func civilDayEnd(after dayStart: Date,
                            calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
    }

    /// After compact IMU shards rotate (four UTC days), `sourceFingerprint`
    /// is nil. A closed day's cached total is still the last exact count.
    static func shouldKeepCompleteDayAfterShardsRotate(_ record: DayRecord) -> Bool {
        record.dayWasComplete
    }

    /// A completed day's cached exact count, for when a fresh read cannot
    /// qualify. The cycle-scoped receipt fold is never closer than this.
    static func lastExactCompleteDayTotal(_ record: DayRecord?) -> Int? {
        guard let record, record.dayWasComplete else { return nil }
        return record.steps
    }

    // MARK: - The read

    /// Per-day totals for `days`, exact where shards can answer, `fallback`
    /// elsewhere. Safe to call from the main actor; the shard work runs on a
    /// utility queue (the store's read preconditions off-main).
    func dailyTotals(days: [Date],
                     strapIdentifier: String,
                     nonGaitExclusions: [DateInterval],
                     fallback: [Date: Int],
                     now: Date = Date()) async -> [Date: Int] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let exact = exactTotalsLocked(
                    days: days,
                    strapIdentifier: strapIdentifier,
                    nonGaitExclusions: nonGaitExclusions,
                    now: now
                )
                continuation.resume(
                    returning: Self.overlay(fallback: fallback, exact: exact)
                )
            }
        }
    }

    /// `dailyTotals` plus the days whose count is only partial: today (still
    /// open), exact days under the coverage floor, and days the shards could
    /// not answer (receipt fallback only). Never inflates a count; only
    /// labels it.
    func dailyTotalsAndPartialDays(days: [Date],
                                   strapIdentifier: String,
                                   nonGaitExclusions: [DateInterval],
                                   fallback: [Date: Int],
                                   now: Date = Date(),
                                   calendar: Calendar = .current) async -> (totals: [Date: Int], partial: Set<Date>) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let exact = exactTotalsLocked(
                    days: days,
                    strapIdentifier: strapIdentifier,
                    nonGaitExclusions: nonGaitExclusions,
                    now: now
                )
                let totals = Self.overlay(fallback: fallback, exact: exact)
                var partial = Set<Date>()
                for day in totals.keys {
                    guard exact[day] != nil,
                          let record = records?[day.timeIntervalSince1970],
                          let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else {
                        partial.insert(day)
                        continue
                    }
                    if Self.isPartial(record: record, dayLength: dayEnd.timeIntervalSince(day)) {
                        partial.insert(day)
                    }
                }
                continuation.resume(returning: (totals, partial))
            }
        }
    }

    private func exactTotalsLocked(days: [Date],
                                   strapIdentifier: String,
                                   nonGaitExclusions: [DateInterval],
                                   now: Date) -> [Date: Int] {
        exactTotalsLocked(
            windows: days.map { DateInterval(start: $0, end: Self.civilDayEnd(after: $0)) },
            strapIdentifier: strapIdentifier,
            nonGaitExclusions: nonGaitExclusions,
            now: now
        )
    }

    /// A cached record answers a window only when it was computed for that
    /// same end; legacy records (no end) are whole civil days.
    static func record(_ record: DayRecord, matchesWindowEnd end: Date) -> Bool {
        guard let recorded = record.windowEndUnix else {
            return civilDayEnd(after: Date(timeIntervalSince1970: record.dayStartUnix))
                == end
        }
        return abs(recorded - end.timeIntervalSince1970) < 1
    }

    /// Exact totals for arbitrary windows (wake-to-wake cycles), keyed by
    /// window start, plus the windows whose count is only partial: still open,
    /// under the coverage floor, or answered from `fallback` alone.
    func windowTotalsAndPartial(windows: [DateInterval],
                                strapIdentifier: String,
                                nonGaitExclusions: [DateInterval],
                                fallback: [Date: Int],
                                now: Date = Date()) async -> (totals: [Date: Int], partial: Set<Date>) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let exact = exactTotalsLocked(
                    windows: windows,
                    strapIdentifier: strapIdentifier,
                    nonGaitExclusions: nonGaitExclusions,
                    now: now
                )
                let totals = Self.overlay(fallback: fallback, exact: exact)
                var partial = Set<Date>()
                for window in windows where totals[window.start] != nil {
                    guard exact[window.start] != nil,
                          let record = records?[window.start.timeIntervalSince1970],
                          Self.record(record, matchesWindowEnd: window.end),
                          !Self.isPartial(record: record, dayLength: window.duration) else {
                        partial.insert(window.start)
                        continue
                    }
                }
                continuation.resume(returning: (totals, partial))
            }
        }
    }

    private func exactTotalsLocked(windows: [DateInterval],
                                   strapIdentifier: String,
                                   nonGaitExclusions: [DateInterval],
                                   now: Date) -> [Date: Int] {
        var loaded = records ?? Self.load(from: cacheURL)
        var exact: [Date: Int] = [:]
        var dirty = false

        for window in windows {
            let day = window.start
            let dayEnd = window.end
            let readEnd = min(dayEnd, now)
            guard readEnd > day else { continue }
            // Fingerprint the WHOLE day's buckets even while the day is open,
            // so a row landing later today changes it. A nil fingerprint means
            // those shards have rotated out of the four-day window — a finished
            // day's cached total is still the last exact answer.
            let fingerprint = store.sourceFingerprint(
                start: day, end: dayEnd, strapIdentifier: strapIdentifier
            )
            let exclusionPrint = Self.exclusionFingerprint(
                nonGaitExclusions, dayStart: day, dayEnd: dayEnd
            )
            if let record = loaded[day.timeIntervalSince1970],
               Self.record(record, matchesWindowEnd: dayEnd) {
                if let fingerprint,
                   Self.isServable(record: record,
                                   sourceFingerprint: fingerprint,
                                   exclusionFingerprint: exclusionPrint,
                                   now: now) {
                    exact[day] = record.steps
                    continue
                }
                if fingerprint == nil, Self.shouldKeepCompleteDayAfterShardsRotate(record) {
                    exact[day] = record.steps
                    continue
                }
            }
            guard let fingerprint else { continue }
            let dayComplete = now >= dayEnd
            let read = store.motionTickDayEvidenceRead(
                start: day,
                end: readEnd,
                bankCoverage: [],
                strapIdentifier: strapIdentifier,
                allowOpenTail: !dayComplete,
                excludedIntervals: nonGaitExclusions
            )
            guard case .qualified(let evidence) = read else {
                // Not cached: an unanswerable day must stay eligible for the
                // moment its shards (or a backfill) can answer it. Meanwhile a
                // finished day keeps its last exact total (device 2026-09-30:
                // Mon showed the cycle fold 8,407+ over a cached exact 5,064
                // after new rows changed its fingerprint).
                if let cached = loaded[day.timeIntervalSince1970],
                   Self.record(cached, matchesWindowEnd: dayEnd),
                   let kept = Self.lastExactCompleteDayTotal(cached) {
                    exact[day] = kept
                }
                continue
            }
            exact[day] = evidence.steps
            loaded[day.timeIntervalSince1970] = DayRecord(
                dayStartUnix: day.timeIntervalSince1970,
                steps: evidence.steps,
                ticks: evidence.motionTicks,
                knownCoverageSeconds: evidence.knownCoverageSeconds,
                sourceFingerprint: fingerprint,
                exclusionFingerprint: exclusionPrint,
                computedAtUnix: now.timeIntervalSince1970,
                dayWasComplete: dayComplete,
                windowEndUnix: dayEnd.timeIntervalSince1970
            )
            dirty = true
        }

        records = loaded
        if dirty { Self.persist(loaded, to: cacheURL) }
        return exact
    }

    // MARK: - Storage (tolerant: a bad file is an empty cache, never a throw)

    private static func load(from url: URL) -> [Double: DayRecord] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([DayRecord].self, from: data)
        else { return [:] }
        // uniquingKeysWith, not uniqueKeysWithValues: a file with a repeated
        // day must degrade like any other bad file, not trap (2026-09-24 review).
        return Dictionary(list.map { ($0.dayStartUnix, $0) },
                          uniquingKeysWith: { _, last in last })
    }

    private static func persist(_ records: [Double: DayRecord], to url: URL) {
        // Bound the file: the week chart needs 7 days; 60 covers regressions.
        let bounded = records.values
            .sorted { $0.dayStartUnix > $1.dayStartUnix }
            .prefix(60)
        guard let data = try? JSONEncoder().encode(Array(bounded)) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
