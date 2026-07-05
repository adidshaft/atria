import Foundation

/// One entry in the visible Detections ring buffer: a record of a
/// detection-pipeline decision (sleep auto-confirm, workout candidate, etc.)
/// surfaced to the user so "when detection happens, it clearly shows."
///
/// Flat `Codable` struct by design -- `kind` + `reason` instead of an
/// enum-with-payload, so `Codable` conformance stays trivial and stable
/// across app versions.
struct DetectionEvent: Codable, Equatable, Identifiable {
    let id: UUID
    /// One of "sleepAutoConfirmed", "sleepCandidateSkipped", "workoutDetected",
    /// "workoutSuppressed".
    let kind: String
    /// Machine reason code, e.g. "already_saved_or_overlapping". `nil` when
    /// the event has no distinct reason beyond its kind.
    let reason: String?
    let date: Date
    /// Short human summary (window + duration, peak_over_rest, etc.) -- never
    /// fabricated, only ever built from real fields already computed at the
    /// call site.
    let detail: String

    init(kind: String, reason: String? = nil, date: Date = Date(), detail: String) {
        self.id = UUID()
        self.kind = kind
        self.reason = reason
        self.date = date
        self.detail = detail
    }
}

/// UserDefaults-persisted JSON ring buffer (last 20 events) -- no new store,
/// no CoreData, not `@Published`. Best-effort: `append` is `try?`-guarded so
/// it can never throw into a detection decision path.
enum DetectionEventLog {
    static let storageKey = "atria.detections.ring.v1"
    static let revisionKey = "atria.detections.revision"
    static let capacity = 20

    /// Inserts `event` newest-first, trims to `capacity`, and bumps the
    /// revision counter so a memoized History subtree can detect the write
    /// without wiring a `@Published` through the whole tree. Never throws.
    static func append(_ event: DetectionEvent, store: UserDefaults = .standard) {
        var events = load(store: store)
        events.insert(event, at: 0)
        if events.count > capacity {
            events.removeLast(events.count - capacity)
        }
        guard let data = try? JSONEncoder().encode(events) else { return }
        store.set(data, forKey: storageKey)
        store.set(store.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }

    static func load(store: UserDefaults = .standard) -> [DetectionEvent] {
        guard let data = store.data(forKey: storageKey),
              let events = try? JSONDecoder().decode([DetectionEvent].self, from: data) else {
            return []
        }
        return events
    }
}

/// Honest, non-fabricated copy for each machine reason code / kind. Never
/// invent a reason not already produced by the detection pipeline itself.
enum DetectionReasonCopy {
    static func text(for event: DetectionEvent) -> String {
        if let reason = event.reason, let mapped = byReasonCode[reason] {
            return mapped
        }
        return byKind[event.kind] ?? event.detail
    }

    private static let byReasonCode: [String: String] = [
        "already_saved_or_overlapping": "Sleep already logged for that window",
        "no_strong_candidate": "No confident sleep window overnight yet",
        "contact_compromised_stitched": "Workout candidate suppressed — sensor contact was unreliable",
        "peak_over_rest_zero_rr_artifact": "Workout candidate suppressed — heart-rate spike without a steady beat-to-beat signal (likely contact artifact)",
        "window_ended_over_24h_ago": "Old workout candidate ignored — more than a day ago",
        "candidate_not_review_worthy": "Activity seen but not strong enough to count yet",
        "wake_boundary_no_wake_detected": "Still tracking — no clear wake-up detected yet",
        "wake_boundary_overlaps_saved": "Sleep already logged for that window"
    ]

    private static let byKind: [String: String] = [
        "sleepAutoConfirmed": "Sleep auto-logged from overnight heart rate",
        "workoutDetected": "Workout candidate ready to review"
    ]
}
