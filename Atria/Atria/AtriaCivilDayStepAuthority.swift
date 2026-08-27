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
    }

    private let cacheURL: URL
    private let store: AtriaWhoop4MotionTickCompactStore
    private let queue = DispatchQueue(
        label: "atria.civil-day-steps",
        qos: .utility
    )
    private var records: [Double: DayRecord]?

    init(cacheURL: URL? = nil,
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
                .appendingPathComponent("civil-day-steps-v1.json")
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

    private func exactTotalsLocked(days: [Date],
                                   strapIdentifier: String,
                                   nonGaitExclusions: [DateInterval],
                                   now: Date) -> [Date: Int] {
        var loaded = records ?? Self.load(from: cacheURL)
        var exact: [Date: Int] = [:]
        var dirty = false

        for day in days {
            let dayEnd = day.addingTimeInterval(86_400)
            let readEnd = min(dayEnd, now)
            guard readEnd > day else { continue }
            // Fingerprint the WHOLE day's buckets even while the day is open,
            // so a row landing later today changes it.
            guard let fingerprint = store.sourceFingerprint(
                start: day, end: dayEnd, strapIdentifier: strapIdentifier
            ) else { continue }
            let exclusionPrint = Self.exclusionFingerprint(
                nonGaitExclusions, dayStart: day, dayEnd: dayEnd
            )
            if let record = loaded[day.timeIntervalSince1970],
               Self.isServable(record: record,
                               sourceFingerprint: fingerprint,
                               exclusionFingerprint: exclusionPrint,
                               now: now) {
                exact[day] = record.steps
                continue
            }
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
                // moment its shards (or a backfill) can answer it.
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
                dayWasComplete: dayComplete
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
        return Dictionary(uniqueKeysWithValues: list.map { ($0.dayStartUnix, $0) })
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
