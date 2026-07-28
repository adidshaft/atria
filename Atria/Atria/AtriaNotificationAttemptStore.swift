import Foundation

/// Durable record of what happened the last time a notification was attempted.
///
/// Every early return in the scheduler previously wrote an `AtriaDebugLog` line
/// and returned. Logs are not durable and the UI cannot read them, so four
/// distinct situations -- toggle off, journal inactive, authorization denied,
/// scheduling failed -- were indistinguishable from "the app did nothing", both
/// to the user and to anyone diagnosing a silent morning afterwards.
///
/// This records the outcome where the UI can see it, so a morning with no
/// notification can say WHY instead of just being quiet.
struct AtriaNotificationAttempt: Codable, Equatable {
    enum Outcome: String, Codable, CaseIterable {
        /// Handed to UNUserNotificationCenter successfully.
        case scheduled
        /// The user turned this notification kind off. Not a fault.
        case blockedByToggle
        /// System authorization is not granted, so nothing can be delivered.
        /// This is the case that needs an in-app fallback.
        case blockedByAuthorization
        /// Deliberately skipped -- e.g. the journal has been unused long enough
        /// that a nudge would be noise.
        case skippedInactive
        /// Waiting on something that has not happened yet; expected to retry.
        case deferred
        /// The scheduling call itself threw.
        case failed

        /// Whether the app owes the user an in-app equivalent because the
        /// system route cannot deliver. A toggle the user set themselves does
        /// NOT qualify -- honouring it is the point.
        var needsInAppFallback: Bool {
            switch self {
            case .blockedByAuthorization, .failed: return true
            case .scheduled, .blockedByToggle, .skippedInactive, .deferred: return false
            }
        }
    }

    let kind: String
    let outcome: Outcome
    /// Machine-readable reason, mirroring what the debug log already emitted.
    let reason: String
    let at: Date
}

enum AtriaNotificationAttemptStore {
    static let defaultsKeyPrefix = "atria.notification.attempt."

    static func key(for kind: String) -> String { defaultsKeyPrefix + kind }

    /// Records the outcome, overwriting the previous one for this kind. Only the
    /// latest matters: this answers "why is there nothing this morning", not
    /// "what is the history of every attempt", and an unbounded history would be
    /// another ring buffer to age out at the wrong moment.
    static func record(kind: String,
                       outcome: AtriaNotificationAttempt.Outcome,
                       reason: String,
                       at: Date = Date(),
                       defaults: UserDefaults = .standard) {
        let attempt = AtriaNotificationAttempt(kind: kind, outcome: outcome, reason: reason, at: at)
        guard let data = try? JSONEncoder().encode(attempt) else { return }
        defaults.set(data, forKey: key(for: kind))
    }

    static func latest(kind: String,
                       defaults: UserDefaults = .standard) -> AtriaNotificationAttempt? {
        guard let data = defaults.data(forKey: key(for: kind)) else { return nil }
        return try? JSONDecoder().decode(AtriaNotificationAttempt.self, from: data)
    }

    static func clear(kind: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: kind))
    }

    /// Whether the app should show its own prompt because the system route
    /// cannot. Scoped to the same civil day so a denial from last week does not
    /// keep raising a prompt about this morning.
    static func needsInAppFallback(kind: String,
                                   now: Date = Date(),
                                   calendar: Calendar = .current,
                                   defaults: UserDefaults = .standard) -> Bool {
        guard let attempt = latest(kind: kind, defaults: defaults),
              attempt.outcome.needsInAppFallback else { return false }
        return calendar.isDate(attempt.at, inSameDayAs: now)
    }
}
