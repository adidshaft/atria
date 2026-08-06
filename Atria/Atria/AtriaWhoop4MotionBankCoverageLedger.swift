import Foundation

/// Durable coverage authority for WHOOP 4 historical-IMU banking.
///
/// A `69/01` write is not itself step evidence. It only opens a time interval
/// in which later, clock-corrected v24 counter endpoints may be admitted.
/// Closing the bank seals that interval; a process relaunch preserves an
/// already-open interval instead of silently resetting its beginning.
enum AtriaWhoop4MotionBankCoverageLedger {
    static let algorithmVersion = "whoop4-motion-bank-coverage-v1"
    static let didResolveOffloadNotification = Notification.Name(
        "AtriaWhoop4MotionBankCoverageLedger.didResolveOffload"
    )
    /// Published when a pending ticket leaves the transport queue, whether it
    /// was exactly verified or honestly exhausted after bounded retries.
    /// Consumers must recompute from durable rows + retained bank intervals;
    /// this notification is never itself step or coverage authority.
    static let didFinalizeOffloadNotification = Notification.Name(
        "AtriaWhoop4MotionBankCoverageLedger.didFinalizeOffload"
    )

    struct Interval: Codable, Equatable, Sendable {
        let start: Date
        let end: Date?
    }

    /// Stable identity of the coverage facts that can change daily projection.
    /// The open interval contributes its start but deliberately not `now`: wall
    /// clock advancement without a new raw source is not new motion evidence.
    struct ProjectionAuthority: Codable, Equatable, Sendable {
        let algorithmVersion: String
        let strapIdentifier: String
        let closed: [Interval]
        let openStart: Date?

        var stableIdentifier: String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            return try? encoder.encode(self).base64EncodedString()
        }
    }

    struct OffloadTicket: Codable, Equatable, Sendable {
        let id: String
        let strapIdentifier: String
        let start: Date
        let end: Date
        let armedConnectionStartedAt: Date?
        var attempts: Int
        var lastAttemptAt: Date?
    }

    private struct State: Codable, Equatable {
        let schema: Int
        var strapIdentifier: String
        var closed: [Interval]
        var openStart: Date?
        var pendingOffloads: [OffloadTicket]?
    }

    private static let schema = 2
    private static let stateKey = "atria.workoutHistoricalMotionBank.coverage.v2"
    private static let maximumClosedIntervals = 512
    /// Two v24 endpoints are required to classify any motion. Windows shorter
    /// than this cannot produce a reliable step delta at the observed ~1 Hz
    /// history cadence and previously flooded the durable queue during link
    /// churn. They remain honest missing coverage, but are not scheduled as
    /// impossible BLE recovery jobs.
    static let minimumRecoverableOffloadDuration: TimeInterval = 10

    static func open(
        at date: Date,
        strapIdentifier: String,
        defaults: UserDefaults = .standard
    ) {
        guard date.timeIntervalSince1970.isFinite,
              !strapIdentifier.isEmpty else { return }
        var state = load(defaults: defaults)
        if state.strapIdentifier != strapIdentifier {
            state = .init(schema: schema,
                          strapIdentifier: strapIdentifier,
                          closed: [],
                          openStart: nil,
                          pendingOffloads: [])
        }
        if let existing = state.openStart {
            state.openStart = min(existing, date)
        } else {
            state.openStart = date
        }
        save(state, defaults: defaults)
    }

    static func close(
        at date: Date,
        strapIdentifier: String,
        armedConnectionStartedAt: Date? = nil,
        defaults: UserDefaults = .standard
    ) {
        var state = load(defaults: defaults)
        guard state.strapIdentifier == strapIdentifier else { return }
        guard let start = state.openStart else { return }
        state.openStart = nil
        if date > start {
            state.closed.append(.init(start: start, end: date))
            state.closed = merged(state.closed)
            if state.closed.count > maximumClosedIntervals {
                state.closed.removeFirst(state.closed.count - maximumClosedIntervals)
            }
            // The firmware bank may have been collecting ordinary all-day
            // motion before a manual workout began. A workout boundary is
            // only the trigger that closes the bank; it must never truncate
            // the recovery request to the later workout start or the earlier
            // autonomous steps become permanently unreachable.
            //
            // Exact workout projection can still crop the recovered full-bank
            // rows to its own start/end. Transport authority always owns the
            // complete physical bank interval.
            if date.timeIntervalSince(start)
                >= minimumRecoverableOffloadDuration {
                let id = [
                    strapIdentifier,
                    String(Int64((start.timeIntervalSince1970 * 1_000).rounded())),
                    String(Int64((date.timeIntervalSince1970 * 1_000).rounded())),
                ].joined(separator: "|")
                var tickets = state.pendingOffloads ?? []
                if !tickets.contains(where: { $0.id == id }) {
                    tickets.append(.init(
                        id: id,
                        strapIdentifier: strapIdentifier,
                        start: start,
                        end: date,
                        armedConnectionStartedAt: armedConnectionStartedAt,
                        attempts: 0,
                        lastAttemptAt: nil
                    ))
                }
                state.pendingOffloads = tickets
            }
        }
        save(state, defaults: defaults)
    }

    /// Repairs coverage written by builds that preserved one open bank across
    /// a physical BLE disconnect. WHOOP 4 drops the historical-IMU bank with
    /// that connection, so time before the ticket's recorded connection epoch
    /// is not bank authority and must never depress or inflate a daily receipt.
    ///
    /// A repaired ticket starts at the only durable connection boundary we
    /// can prove. Its prior attempts targeted an impossible wider interval, so
    /// the corrected exact window receives one fresh attempt. No raw row,
    /// step, or coverage second is manufactured.
    @discardableResult
    static func repairCrossConnectionCoverage(
        defaults: UserDefaults = .standard
    ) -> Int {
        var state = load(defaults: defaults)
        guard let existingTickets = state.pendingOffloads,
              !existingTickets.isEmpty else { return 0 }

        var repairedCount = 0
        var repairedTickets: [OffloadTicket] = []
        var closed = state.closed

        for ticket in existingTickets {
            guard let epoch = ticket.armedConnectionStartedAt,
                  epoch > ticket.start else {
                repairedTickets.append(ticket)
                continue
            }

            repairedCount += 1
            let invalidPrefixEnd = min(epoch, ticket.end)
            closed = subtract(
                DateInterval(
                    start: ticket.start,
                    end: invalidPrefixEnd
                ),
                from: closed
            )

            guard epoch < ticket.end else { continue }
            let repairedID = [
                ticket.strapIdentifier,
                String(
                    Int64(
                        (epoch.timeIntervalSince1970 * 1_000).rounded()
                    )
                ),
                String(
                    Int64(
                        (ticket.end.timeIntervalSince1970 * 1_000).rounded()
                    )
                ),
            ].joined(separator: "|")
            repairedTickets.append(
                .init(
                    id: repairedID,
                    strapIdentifier: ticket.strapIdentifier,
                    start: epoch,
                    end: ticket.end,
                    armedConnectionStartedAt: epoch,
                    attempts: 0,
                    lastAttemptAt: nil
                )
            )
            closed.append(.init(start: epoch, end: ticket.end))
        }

        guard repairedCount > 0 else { return 0 }
        var uniqueTickets: [String: OffloadTicket] = [:]
        for ticket in repairedTickets {
            if let existing = uniqueTickets[ticket.id] {
                uniqueTickets[ticket.id] =
                    existing.attempts <= ticket.attempts ? existing : ticket
            } else {
                uniqueTickets[ticket.id] = ticket
            }
        }
        state.closed = merged(closed)
        state.pendingOffloads = Array(
            uniqueTickets.values.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            }.suffix(128)
        )
        save(state, defaults: defaults)
        return repairedCount
    }

    /// Repairs tickets written by builds that closed an already-running
    /// all-day bank at a later workout boundary but requested only the workout
    /// suffix. The durably closed interval is the authority: expanding back to
    /// its exact start recovers no invented time and is the only way to make
    /// the autonomous prefix requestable from the strap.
    ///
    /// Run this before cross-connection repair so a bank that truly crossed a
    /// BLE epoch is still clipped to its independently recorded connection
    /// boundary afterward.
    @discardableResult
    static func repairWorkoutTruncatedOffloadCoverage(
        defaults: UserDefaults = .standard
    ) -> Int {
        var state = load(defaults: defaults)
        guard let tickets = state.pendingOffloads,
              !tickets.isEmpty else { return 0 }

        var repairedCount = 0
        var repaired: [OffloadTicket] = []
        for ticket in tickets {
            let authority = state.closed
                .compactMap { interval -> DateInterval? in
                    guard let end = interval.end,
                          abs(end.timeIntervalSince(ticket.end)) < 0.001,
                          interval.start < ticket.start else {
                        return nil
                    }
                    return DateInterval(start: interval.start, end: end)
                }
                .max { $0.start < $1.start }
            guard let authority else {
                repaired.append(ticket)
                continue
            }
            repairedCount += 1
            repaired.append(
                .init(
                    id: [
                        ticket.strapIdentifier,
                        String(
                            Int64(
                                (authority.start.timeIntervalSince1970
                                    * 1_000).rounded()
                            )
                        ),
                        String(
                            Int64(
                                (authority.end.timeIntervalSince1970
                                    * 1_000).rounded()
                            )
                        ),
                    ].joined(separator: "|"),
                    strapIdentifier: ticket.strapIdentifier,
                    start: authority.start,
                    end: authority.end,
                    armedConnectionStartedAt:
                        ticket.armedConnectionStartedAt,
                    attempts: ticket.attempts,
                    lastAttemptAt: ticket.lastAttemptAt
                )
            )
        }
        guard repairedCount > 0 else { return 0 }
        var unique: [String: OffloadTicket] = [:]
        for ticket in repaired {
            if let existing = unique[ticket.id] {
                unique[ticket.id] =
                    existing.attempts <= ticket.attempts
                        ? existing : ticket
            } else {
                unique[ticket.id] = ticket
            }
        }
        state.pendingOffloads = Array(
            unique.values.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            }.suffix(128)
        )
        save(state, defaults: defaults)
        return repairedCount
    }

    /// A process cannot prove that a persisted open bank survived its Core
    /// Bluetooth owner. Close the orphan only through the last durably observed
    /// HR packet, then let the new process open a fresh connection epoch.
    ///
    /// This intentionally loses any unproven tail between the last persisted
    /// packet and process death. It never bridges that tail into the new link.
    @discardableResult
    static func retireOrphanedOpenCoverage(
        lastObservedAt: Date?,
        strapIdentifier: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        var state = load(defaults: defaults)
        guard state.strapIdentifier == strapIdentifier,
              let start = state.openStart else { return false }
        state.openStart = nil

        if let end = lastObservedAt, end > start {
            state.closed.append(.init(start: start, end: end))
            state.closed = merged(state.closed)
            let id = [
                strapIdentifier,
                String(
                    Int64(
                        (start.timeIntervalSince1970 * 1_000).rounded()
                    )
                ),
                String(
                    Int64(
                        (end.timeIntervalSince1970 * 1_000).rounded()
                    )
                ),
            ].joined(separator: "|")
            var tickets = state.pendingOffloads ?? []
            if !tickets.contains(where: { $0.id == id }) {
                tickets.append(
                    .init(
                        id: id,
                        strapIdentifier: strapIdentifier,
                        start: start,
                        end: end,
                        armedConnectionStartedAt: start,
                        attempts: 0,
                        lastAttemptAt: nil
                    )
                )
            }
            state.pendingOffloads = tickets
        }

        save(state, defaults: defaults)
        return true
    }

    static func nextPendingOffload(
        strapIdentifier: String,
        defaults: UserDefaults = .standard
    ) -> OffloadTicket? {
        let state = load(defaults: defaults)
        guard state.strapIdentifier == strapIdentifier else { return nil }
        return (state.pendingOffloads ?? []).sorted {
            // A newly completed workout must get one prompt offload attempt
            // before old failed/partial tickets consume another long drain.
            // Once every ticket has been attempted, resume oldest-first retry
            // order so historical work still converges without starvation.
            let lhsUnattempted = $0.attempts == 0
            let rhsUnattempted = $1.attempts == 0
            if lhsUnattempted != rhsUnattempted {
                return lhsUnattempted
            }
            let lhsRecoverable =
                $0.end.timeIntervalSince($0.start)
                    >= minimumRecoverableOffloadDuration
            let rhsRecoverable =
                $1.end.timeIntervalSince($1.start)
                    >= minimumRecoverableOffloadDuration
            if lhsRecoverable != rhsRecoverable {
                return lhsRecoverable
            }
            if lhsUnattempted {
                let lhsDuration = $0.end.timeIntervalSince($0.start)
                let rhsDuration = $1.end.timeIntervalSince($1.start)
                if lhsDuration != rhsDuration {
                    // One full history drain can satisfy every covered ticket.
                    // Bind it to the largest new coverage gain instead of a
                    // seconds-long reconnect fragment.
                    return lhsDuration > rhsDuration
                }
            }
            if $0.end != $1.end {
                return lhsUnattempted ? $0.end > $1.end : $0.end < $1.end
            }
            return $0.id < $1.id
        }.first
    }

    static func pendingOffloads(
        strapIdentifier: String,
        defaults: UserDefaults = .standard
    ) -> [OffloadTicket] {
        let state = load(defaults: defaults)
        guard state.strapIdentifier == strapIdentifier else { return [] }
        return (state.pendingOffloads ?? []).filter {
            $0.strapIdentifier == strapIdentifier
        }
    }

    static func pendingOffload(
        id: String,
        strapIdentifier: String,
        defaults: UserDefaults = .standard
    ) -> OffloadTicket? {
        let state = load(defaults: defaults)
        guard state.strapIdentifier == strapIdentifier else { return nil }
        return (state.pendingOffloads ?? []).first {
            $0.id == id && $0.strapIdentifier == strapIdentifier
        }
    }

    @discardableResult
    static func markOffloadAttempt(
        id: String,
        at date: Date,
        defaults: UserDefaults = .standard
    ) -> OffloadTicket? {
        var state = load(defaults: defaults)
        guard var tickets = state.pendingOffloads,
              let index = tickets.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        tickets[index].attempts += 1
        tickets[index].lastAttemptAt = date
        state.pendingOffloads = tickets
        save(state, defaults: defaults)
        return tickets[index]
    }

    static func resolveOffload(
        id: String,
        defaults: UserDefaults = .standard
    ) {
        resolveOffloads(ids: [id], defaults: defaults)
    }

    /// Resolves every ticket proven by one durable compact generation and
    /// publishes one refresh boundary. Posting once prevents a successful full
    /// history drain from scheduling dozens of duplicate Home/widget scans.
    static func resolveOffloads(
        ids: Set<String>,
        defaults: UserDefaults = .standard
    ) {
        resolveOffloads(ids: Array(ids), defaults: defaults)
    }

    private static func resolveOffloads(
        ids: [String],
        defaults: UserDefaults
    ) {
        let requested = Set(ids)
        guard !requested.isEmpty else { return }
        var state = load(defaults: defaults)
        let resolved = (state.pendingOffloads ?? []).filter {
            requested.contains($0.id)
        }
        guard !resolved.isEmpty else { return }
        state.pendingOffloads?.removeAll { requested.contains($0.id) }
        save(state, defaults: defaults)
        // Archive-update notifications can arrive while history transport
        // still owns the link, so SessionStore correctly defers them. This
        // terminal receipt is the first point at which the exact bank window
        // is both durably present and safe to project into the daily step
        // authority. Publish after the defaults transaction commits.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: didResolveOffloadNotification,
                object: resolved.count == 1
                    ? resolved[0].id
                    : resolved.map(\.id)
            )
            NotificationCenter.default.post(
                name: didFinalizeOffloadNotification,
                object: resolved.count == 1
                    ? resolved[0].id
                    : resolved.map(\.id)
            )
        }
    }

    /// Stops an exact-window retry from blocking future all-day collection
    /// after the bounded transport budget is exhausted. The closed interval is
    /// deliberately retained, so daily projection continues to report its
    /// missing/partial coverage; only the impossible BLE work item is removed.
    /// This is not resolution and never emits `didResolveOffloadNotification`.
    @discardableResult
    static func exhaustOffload(
        id: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        var state = load(defaults: defaults)
        guard let exhausted = state.pendingOffloads?.first(where: {
            $0.id == id
        }) else { return false }
        state.pendingOffloads?.removeAll { $0.id == id }
        save(state, defaults: defaults)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: didFinalizeOffloadNotification,
                object: exhausted.id
            )
        }
        return true
    }

    /// Retires transport jobs that are too old to keep blocking present-day
    /// capture. Their closed bank intervals remain durable missing-coverage
    /// facts, and later generic history ingestion may still populate those
    /// intervals. This only removes exact-window retry work; it never marks a
    /// row, second, or step as recovered.
    @discardableResult
    static func exhaustOffloads(
        endingAtOrBefore cutoff: Date,
        strapIdentifier: String,
        defaults: UserDefaults = .standard
    ) -> [String] {
        var state = load(defaults: defaults)
        let exhausted = (state.pendingOffloads ?? []).filter {
            $0.strapIdentifier.caseInsensitiveCompare(strapIdentifier)
                == .orderedSame
                && $0.end <= cutoff
        }
        guard !exhausted.isEmpty else { return [] }
        let exhaustedIDs = Set(exhausted.map(\.id))
        state.pendingOffloads?.removeAll {
            exhaustedIDs.contains($0.id)
        }
        save(state, defaults: defaults)
        let orderedIDs = exhausted.map(\.id)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: didFinalizeOffloadNotification,
                object: orderedIDs.count == 1
                    ? orderedIDs[0]
                    : orderedIDs
            )
        }
        return orderedIDs
    }

    /// Removes only tickets that are physically too short to contain the two
    /// v24 endpoints required for a step delta. Their closed intervals stay in
    /// projection authority and therefore continue to lower coverage; no
    /// second, row, or step is fabricated.
    @discardableResult
    static func pruneUnrecoverableShortOffloads(
        defaults: UserDefaults = .standard
    ) -> Int {
        var state = load(defaults: defaults)
        guard let tickets = state.pendingOffloads else { return 0 }
        let retained = tickets.filter {
            $0.end.timeIntervalSince($0.start)
                >= minimumRecoverableOffloadDuration
        }
        let removed = tickets.count - retained.count
        guard removed > 0 else { return 0 }
        state.pendingOffloads = retained
        save(state, defaults: defaults)
        return removed
    }

    /// Repairs tickets cleared by the retired transport-only verifier. The
    /// caller must supply a factual unresolved R10 range; this method refuses
    /// to invent a ticket unless that exact range is contained by a durably
    /// closed 0x69 bank interval for the same strap.
    @discardableResult
    static func restorePendingOffloadIfCovered(
        start: Date,
        end: Date,
        strapIdentifier: String,
        defaults: UserDefaults = .standard
    ) -> OffloadTicket? {
        guard end > start, !strapIdentifier.isEmpty else { return nil }
        var state = load(defaults: defaults)
        guard state.strapIdentifier == strapIdentifier else { return nil }
        let id = [
            strapIdentifier,
            String(Int64((start.timeIntervalSince1970 * 1_000).rounded())),
            String(Int64((end.timeIntervalSince1970 * 1_000).rounded())),
        ].joined(separator: "|")
        if let existing = state.pendingOffloads?.first(where: { $0.id == id }) {
            return existing
        }
        guard state.closed.contains(where: { interval in
            guard let intervalEnd = interval.end else { return false }
            return interval.start <= start && intervalEnd >= end
        }) else { return nil }
        let restored = OffloadTicket(
            id: id,
            strapIdentifier: strapIdentifier,
            start: start,
            end: end,
            armedConnectionStartedAt: nil,
            attempts: 0,
            lastAttemptAt: nil
        )
        var tickets = state.pendingOffloads ?? []
        tickets.append(restored)
        state.pendingOffloads = Array(tickets.suffix(128))
        save(state, defaults: defaults)
        return restored
    }

    static func intervals(
        intersecting window: DateInterval,
        strapIdentifier: String,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> [DateInterval] {
        guard window.end > window.start,
              !strapIdentifier.isEmpty else { return [] }
        let state = load(defaults: defaults)
        guard state.strapIdentifier == strapIdentifier else { return [] }
        var values = state.closed.compactMap { item -> DateInterval? in
            guard let end = item.end else { return nil }
            return intersection(.init(start: item.start, end: end), window)
        }
        if let openStart = state.openStart {
            let openEnd = min(now, window.end)
            if openEnd > openStart,
               let clipped = intersection(.init(start: openStart, end: openEnd), window) {
                values.append(clipped)
            }
        }
        return mergeIntervals(values)
    }

    static func projectionAuthority(
        intersecting window: DateInterval,
        strapIdentifier: String,
        defaults: UserDefaults = .standard
    ) -> ProjectionAuthority? {
        guard window.end > window.start,
              !strapIdentifier.isEmpty else { return nil }
        let state = load(defaults: defaults)
        guard state.strapIdentifier == strapIdentifier else { return nil }
        let closed = mergeIntervals(state.closed.compactMap { item in
            guard let end = item.end else { return nil }
            return intersection(.init(start: item.start, end: end), window)
        }).map {
            Interval(start: $0.start, end: $0.end)
        }
        let openStart = state.openStart.flatMap { start -> Date? in
            guard start < window.end else { return nil }
            return max(start, window.start)
        }
        return .init(
            algorithmVersion: algorithmVersion,
            strapIdentifier: strapIdentifier,
            closed: closed,
            openStart: openStart
        )
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: stateKey)
        if defaults === UserDefaults.standard {
            cacheLock.lock()
            cachedStandardState = nil
            cacheLock.unlock()
        }
    }

    /// The 1 Hz accepted-HR path reads this ledger up to ~10 times per
    /// second from the main actor, and every read previously decoded the
    /// full JSON blob (512-interval / 128-ticket cap). Memoize the decoded
    /// state for the standard-defaults instance only — the app process is
    /// its sole writer, tests inject their own suites and bypass the cache,
    /// and `State` is a value type so callers always get copies.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedStandardState: State?

    private static func load(defaults: UserDefaults) -> State {
        let cacheable = defaults === UserDefaults.standard
        if cacheable {
            cacheLock.lock()
            let cached = cachedStandardState
            cacheLock.unlock()
            if let cached { return cached }
        }
        let loaded = decodeState(defaults: defaults)
        if cacheable {
            cacheLock.lock()
            cachedStandardState = loaded
            cacheLock.unlock()
        }
        return loaded
    }

    private static func decodeState(defaults: UserDefaults) -> State {
        guard let data = defaults.data(forKey: stateKey),
              let decoded = try? JSONDecoder().decode(State.self, from: data),
              decoded.schema == schema else {
            return .init(schema: schema,
                         strapIdentifier: "",
                         closed: [],
                         openStart: nil,
                         pendingOffloads: [])
        }
        return .init(schema: schema,
                     strapIdentifier: decoded.strapIdentifier,
                     closed: decoded.closed.filter {
                        guard let end = $0.end else { return false }
                        return end > $0.start
                     },
                     openStart: decoded.openStart,
                     pendingOffloads: (decoded.pendingOffloads ?? []).filter {
                         $0.end > $0.start
                             && $0.strapIdentifier
                                 == decoded.strapIdentifier
                     })
    }

    private static func save(_ state: State, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
        if defaults === UserDefaults.standard {
            cacheLock.lock()
            cachedStandardState = state
            cacheLock.unlock()
        }
    }

    private static func merged(_ values: [Interval]) -> [Interval] {
        mergeIntervals(values.compactMap {
            guard let end = $0.end, end > $0.start else { return nil }
            return DateInterval(start: $0.start, end: end)
        }).map { .init(start: $0.start, end: $0.end) }
    }

    private static func subtract(
        _ removed: DateInterval,
        from intervals: [Interval]
    ) -> [Interval] {
        guard removed.end > removed.start else { return intervals }
        return intervals.flatMap { interval -> [Interval] in
            guard let end = interval.end, end > interval.start else {
                return []
            }
            let source = DateInterval(start: interval.start, end: end)
            guard source.intersects(removed) else { return [interval] }
            var fragments: [Interval] = []
            if source.start < removed.start {
                fragments.append(
                    .init(start: source.start, end: removed.start)
                )
            }
            if source.end > removed.end {
                fragments.append(
                    .init(start: removed.end, end: source.end)
                )
            }
            return fragments
        }
    }

    private static func mergeIntervals(_ values: [DateInterval]) -> [DateInterval] {
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
            if value.start <= last.end {
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

    private static func intersection(
        _ lhs: DateInterval,
        _ rhs: DateInterval
    ) -> DateInterval? {
        let start = max(lhs.start, rhs.start)
        let end = min(lhs.end, rhs.end)
        return end > start ? .init(start: start, end: end) : nil
    }
}
