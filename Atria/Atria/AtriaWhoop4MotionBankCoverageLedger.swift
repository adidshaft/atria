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
        offloadStart: Date? = nil,
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
            let requestedStart = max(start, offloadStart ?? start)
            if date > requestedStart {
                let id = [
                    strapIdentifier,
                    String(Int64((requestedStart.timeIntervalSince1970 * 1_000).rounded())),
                    String(Int64((date.timeIntervalSince1970 * 1_000).rounded())),
                ].joined(separator: "|")
                var tickets = state.pendingOffloads ?? []
                if !tickets.contains(where: { $0.id == id }) {
                    tickets.append(.init(
                        id: id,
                        strapIdentifier: strapIdentifier,
                        start: requestedStart,
                        end: date,
                        armedConnectionStartedAt: armedConnectionStartedAt,
                        attempts: 0,
                        lastAttemptAt: nil
                    ))
                }
                state.pendingOffloads = Array(tickets.suffix(128))
            }
        }
        save(state, defaults: defaults)
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
            if $0.end != $1.end {
                return lhsUnattempted ? $0.end > $1.end : $0.end < $1.end
            }
            return $0.id < $1.id
        }.first
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
        var state = load(defaults: defaults)
        let resolved = state.pendingOffloads?.first { $0.id == id }
        state.pendingOffloads?.removeAll { $0.id == id }
        save(state, defaults: defaults)
        guard resolved != nil else { return }
        // Archive-update notifications can arrive while history transport
        // still owns the link, so SessionStore correctly defers them. This
        // terminal receipt is the first point at which the exact bank window
        // is both durably present and safe to project into the daily step
        // authority. Publish after the defaults transaction commits.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: didResolveOffloadNotification,
                object: id
            )
        }
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
    }

    private static func load(defaults: UserDefaults) -> State {
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
    }

    private static func merged(_ values: [Interval]) -> [Interval] {
        mergeIntervals(values.compactMap {
            guard let end = $0.end, end > $0.start else { return nil }
            return DateInterval(start: $0.start, end: end)
        }).map { .init(start: $0.start, end: $0.end) }
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
