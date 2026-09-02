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
    /// The detected activity's real window (2026-07-07, design backlog:
    /// actionable workout rows). Optional and additive — events logged by
    /// older builds decode without them and stay read-only.
    var windowStart: Date? = nil
    var windowEnd: Date? = nil

    init(kind: String, reason: String? = nil, date: Date = Date(), detail: String,
         windowStart: Date? = nil, windowEnd: Date? = nil) {
        self.id = UUID()
        self.kind = kind
        self.reason = reason
        self.date = date
        self.detail = detail
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}

/// UserDefaults-persisted JSON ring buffer (last 20 events) -- no new store,
/// no CoreData, not `@Published`. Best-effort: `append` is `try?`-guarded so
/// it can never throw into a detection decision path.
enum DetectionEventLog {
    static let storageKey = "atria.detections.ring.v1"
    static let revisionKey = "atria.detections.revision"
    static let capacity = 20
    /// A deferred session load can re-evaluate the same absent-sleep state a
    /// number of times while its source is still settling. Those retries are
    /// useful as one audit record, but retaining every retry can evict an
    /// actionable workout detection from this deliberately small user-facing
    /// ring. This affects logging only; it never suppresses or changes a
    /// detection decision.
    static let sleepSkipRetryCoalescingInterval: TimeInterval = 60 * 60

    /// Inserts `event` newest-first, trims to `capacity`, and bumps the
    /// revision counter so a memoized History subtree can detect the write
    /// without wiring a `@Published` through the whole tree. Never throws.
    static func append(_ event: DetectionEvent, store: UserDefaults = .standard) {
        var events = load(store: store)
        if shouldCoalesceSleepSkipRetry(event, with: events) {
            return
        }
        events.insert(event, at: 0)
        if events.count > capacity {
            events.removeLast(events.count - capacity)
        }
        guard let data = try? JSONEncoder().encode(events) else { return }
        store.set(data, forKey: storageKey)
        store.set(store.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }

    private static func shouldCoalesceSleepSkipRetry(_ event: DetectionEvent,
                                                      with events: [DetectionEvent]) -> Bool {
        guard event.kind == "sleepCandidateSkipped" else { return false }
        return events.contains { prior in
            guard prior.kind == event.kind,
                  prior.reason == event.reason else { return false }
            let elapsed = event.date.timeIntervalSince(prior.date)
            return elapsed >= 0 && elapsed < sleepSkipRetryCoalescingInterval
        }
    }

    static func load(store: UserDefaults = .standard) -> [DetectionEvent] {
        guard let data = store.data(forKey: storageKey),
              let events = try? JSONDecoder().decode([DetectionEvent].self, from: data) else {
            return []
        }
        return events
    }
}

/// A private, bounded audit trail for the exact strain inputs present when a
/// workout becomes canonical. This is intentionally separate from
/// `DetectionEventLog`: it must not create a new user-facing History item or
/// influence any score, eligibility gate, or presentation.
struct AtriaStrainConfirmationAuditRecord: Codable, Equatable {
    let workoutID: String
    let recordedAt: Date
    let rawTRIMP: Double
    let integratedObservedSeconds: TimeInterval
    let droppedGapSeconds: TimeInterval
    let restingHR: Int
    let maxHR: Int
    let strainScore: Double?
    let result: String
    let coveragePercent: Int
}

enum AtriaStrainConfirmationAuditLog {
    static let storageKey = "atria.strain.confirmation.audit.v1"
    static let capacity = 40

    /// Best-effort diagnostics only. A failure to write the audit trail must
    /// never interrupt a confirmed-workout save.
    static func append(_ record: AtriaStrainConfirmationAuditRecord,
                       store: UserDefaults = .standard) {
        var records = load(store: store)
        records.insert(record, at: 0)
        if records.count > capacity {
            records.removeLast(records.count - capacity)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        store.set(data, forKey: storageKey)
    }

    static func load(store: UserDefaults = .standard) -> [AtriaStrainConfirmationAuditRecord] {
        guard let data = store.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([AtriaStrainConfirmationAuditRecord].self,
                                                       from: data) else {
            return []
        }
        return records
    }
}

/// Honest, non-fabricated copy for each machine reason code / kind. Never
/// invent a reason not already produced by the detection pipeline itself.
enum DetectionReasonCopy {
    static func text(for event: DetectionEvent) -> String {
        if let reason = event.reason, let mapped = byReasonCode[reason] {
            return mapped
        }
        return byKind[event.kind] ?? sanitizedDetail(event.detail)
    }

    /// The raw detail is a pipeline sentence that also carries provenance
    /// tokens such as "(source: foreground_edge)" for the developer log.
    /// Those tokens explain nothing to a reader of the Vitals sleep card or
    /// the History list, so the fallback drops them and keeps the sentence
    /// (2026-09-02). Nothing is added — only the token is removed.
    static func sanitizedDetail(_ detail: String) -> String {
        var text = detail
        while let open = text.range(of: "(source:") {
            let close = text[open.lowerBound...].firstIndex(of: ")").map { text.index(after: $0) }
                ?? text.endIndex
            text.removeSubrange(open.lowerBound..<close)
        }
        text = text.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, last == "," || last == "-" || last == "\u{2014}" || last == " " {
            text.removeLast()
        }
        return text.isEmpty ? detail : text
    }

    private static let byReasonCode: [String: String] = [
        "already_saved_or_overlapping": "Sleep already logged for that window",
        // NOT "overnight". This owner's main sleep runs ~13:00-20:30, and the
        // word quietly asserts the very assumption that is refusing it — a
        // reader seeing "no confident sleep window overnight" on a day they
        // slept seven hours in the afternoon learns nothing except that the app
        // disagrees with them.
        "no_strong_candidate": "No confident sleep window found yet",
        "contact_compromised_stitched": "Workout candidate suppressed — sensor contact was unreliable",
        "peak_over_rest_zero_rr_artifact": "Workout candidate suppressed — heart-rate spike without a steady beat-to-beat signal (likely contact artifact)",
        "window_ended_over_24h_ago": "Old workout candidate ignored — more than a day ago",
        "candidate_not_review_worthy": "Activity seen but not strong enough to count yet",
        "wake_boundary_no_wake_detected": "Still tracking — no clear wake-up detected yet",
        "wake_boundary_overlaps_saved": "Sleep already logged for that window",
        // 2026-09-02: every remaining sleep-skip code the pipeline emits, each
        // a plain restatement of that event's own detail sentence.
        "candidate_not_settled": "Sleep candidate still settling — nearby quiet spells may join it",
        "daytime_quiescence_no_strap": "Motion-quiet check is waiting for a strap identity",
        "daytime_quiescence_insufficient_motion": "Too little motion data in the last 26 h for the motion-quiet check",
        "daytime_quiescence_hr_read_incomplete": "Motion-quiet check could not read the full heart-rate window",
        "daytime_quiescence_no_candidate": "Motion-quiet check found no reviewable daytime sleep",
        "daytime_quiescence_slot_held": "Another sleep suggestion is already waiting for review",
        "review_only_classification": "Sleep evidence needs your review before it counts",
        "wake_boundary_review_only_classification": "Wake-up evidence needs your review before it counts",
        "compact_materialization_stale_or_missing": "Sleep physiology is being rebuilt for the current classification",
        "compact_wake_materialization_stale_or_missing": "Wake physiology is being rebuilt for the current classification",
        "baseline_trust_changed": "Sleep candidate no longer clears the current evidence gates",
        "wake_boundary_dismissed": "Wake-boundary suggestion matches one you dismissed",
        "save_time_dismissal_suppressed": "Auto-confirmation dropped after a dismissal mid-save"
    ]

    private static let byKind: [String: String] = [
        "sleepAutoConfirmed": "Sleep auto-logged from heart rate",
        "workoutDetected": "Workout candidate ready to review"
    ]
}
