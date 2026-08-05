import Foundation

/// Persisted attribution of motion-bank *unarmed* time by gate reason.
///
/// Coverage %% is the bank-armed duty cycle (§15.42): windows exist only
/// while `69/01` is armed on a live link. This diagnostic splits each day
/// into buckets keyed by the last observed gate state so a single plist
/// pull can answer "where did the unarmed hours go" — governor/battery,
/// offload-first deferral, link-down, sync/cutover — before any offload
/// or arming policy is tuned. It is a diagnostic only: never an input to
/// arming, coverage, or step decisions.
enum AtriaMotionBankDutyCycleDiag {
    static let stateKey = "atria.debug.motionBankDutyCycle.v1"
    static let previousDayKey = "atria.debug.motionBankDutyCycle.yesterday.v1"
    /// Elapsed time beyond this since the previous note cannot be safely
    /// attributed to the last reason (process death, long suspension); the
    /// excess lands in "unsampled" so buckets stay honest.
    static let maximumAttributableGap: TimeInterval = 900

    struct State: Codable, Equatable {
        var day: String
        var lastReason: String
        var lastAt: TimeInterval
        var buckets: [String: TimeInterval]
    }

    static func note(
        _ reason: String,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let day = dayKey(for: now)
        let nowSeconds = now.timeIntervalSince1970
        var state = load(defaults: defaults) ?? State(
            day: day,
            lastReason: reason,
            lastAt: nowSeconds,
            buckets: [:]
        )
        if state.day != day {
            if let snapshot = try? JSONEncoder().encode(state),
               let text = String(data: snapshot, encoding: .utf8) {
                defaults.set(text, forKey: previousDayKey)
            }
            // Keep lastAt: the cross-midnight delta then flows through the
            // normal cap-to-unsampled attribution into the new day instead
            // of vanishing.
            state = State(day: day,
                          lastReason: state.lastReason,
                          lastAt: state.lastAt,
                          buckets: [:])
        }
        let delta = nowSeconds - state.lastAt
        if delta > 0 {
            let attributed = min(delta, maximumAttributableGap)
            state.buckets[state.lastReason, default: 0] += attributed
            if delta > attributed {
                state.buckets["unsampled", default: 0] += delta - attributed
            }
        }
        state.lastReason = reason
        state.lastAt = nowSeconds
        save(state, defaults: defaults)
    }

    static func load(defaults: UserDefaults = .standard) -> State? {
        guard let text = defaults.string(forKey: stateKey),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private static func save(_ state: State, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: stateKey)
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
