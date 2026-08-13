import Foundation

/// One durable, review-only sleep candidate.
///
/// Detection is deliberately conservative and confirmation remains a user
/// decision. Durability only prevents an already-qualified candidate from
/// disappearing when the app relaunches or a later history generation briefly
/// rebuilds the in-memory sleep projection.
enum AtriaPendingSleepReviewStore {
    private struct Record: Codable {
        let schema: Int
        let id: String
        let day: Date
        let start: Date
        let end: Date
        let duration: TimeInterval
        let restingHR: Int?
        let hrv: Int?
        let hrvWindowCount: Int
        let respiratoryRate: Double?
        let sleepEfficiency: Double?
        let confidence: String
        let source: String
        let stageSegments: [SleepStageSegment]
        let eventTimeZoneIdentifier: String?
        let savedAt: Date
        /// Motion-validation provenance (2026-08-01, HR-only honesty).
        /// Optional so pre-existing schema-1 records keep decoding; nil falls
        /// back to the Night's confidence-based derivation, which fails
        /// closed to "needs motion data".
        let motionValidated: Bool?
        /// Handoff-11 degraded-lane provenance. All optional so schema-1
        /// records written before (and after, by the qualified lane) keep
        /// decoding in both directions. `motionBlocker` is the exact compact
        /// read failure that made motion unverifiable — "could not verify",
        /// never "absent". `evidenceFingerprint` deduplicates identical
        /// re-preparations across relaunches. `sourceStrapIdentifier` lets a
        /// re-pair invalidate the record at load.
        var motionBlocker: String? = nil
        var evidenceFingerprint: String? = nil
        var sourceStrapIdentifier: String? = nil
    }

    /// Handoff-11: what `saveDegradedReview` actually did, for the debug
    /// receipt and logs. `rejectedStrapChanged` is produced by the caller's
    /// identity re-check, kept here so the vocabulary lives in one place.
    enum DegradedSaveOutcome: String, Equatable {
        case saved
        case deduplicated
        case keptMotionValidated
        case rejected
        case rejectedStrapChanged
    }

    private static let schema = 1
    private static let key = "atria.sleepReview.pendingReceipt.v1"
    static let maximumAge: TimeInterval = 72 * 60 * 60

    static func save(
        _ night: SleepHistorySnapshot.Night,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard !night.confirmed,
              let start = night.start,
              let end = night.end,
              valid(start: start,
                    end: end,
                    duration: night.duration,
                    savedAt: now,
                    now: now) else { return }
        let record = Record(
            schema: schema,
            id: night.id,
            day: night.day,
            start: start,
            end: end,
            duration: night.duration,
            restingHR: night.restingHR,
            hrv: night.hrv,
            hrvWindowCount: night.hrvWindowCount,
            respiratoryRate: night.respiratoryRate,
            sleepEfficiency: night.sleepEfficiency,
            confidence: night.confidence,
            source: night.source,
            stageSegments: night.stageSegments,
            eventTimeZoneIdentifier: night.eventTimeZoneIdentifier,
            savedAt: now,
            motionValidated: night.motionValidated
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    /// Handoff-11 Checkpoint 4: persist one degraded HR/RR review-only
    /// candidate with its provenance. Same validity gates as `save`, plus:
    /// an identical evidence fingerprint deduplicates (the existing record,
    /// including its `savedAt`, survives untouched), and a degraded record
    /// never replaces a still-valid motion-validated candidate for an
    /// overlapping window — weaker provenance must not erase stronger.
    static func saveDegradedReview(
        _ night: SleepHistorySnapshot.Night,
        motionBlocker: String,
        evidenceFingerprint: String,
        sourceStrapIdentifier: String?,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> DegradedSaveOutcome {
        guard !night.confirmed,
              let start = night.start,
              let end = night.end,
              valid(start: start,
                    end: end,
                    duration: night.duration,
                    savedAt: now,
                    now: now) else { return .rejected }
        if let data = defaults.data(forKey: key),
           let existing = try? JSONDecoder().decode(Record.self, from: data),
           existing.schema == schema,
           valid(start: existing.start,
                 end: existing.end,
                 duration: existing.duration,
                 savedAt: existing.savedAt,
                 now: now) {
            if existing.evidenceFingerprint == evidenceFingerprint {
                return .deduplicated
            }
            if existing.motionValidated == true,
               night.motionValidated != true,
               min(existing.end, end) > max(existing.start, start) {
                return .keptMotionValidated
            }
        }
        let record = Record(
            schema: schema,
            id: night.id,
            day: night.day,
            start: start,
            end: end,
            duration: night.duration,
            restingHR: night.restingHR,
            hrv: night.hrv,
            hrvWindowCount: night.hrvWindowCount,
            respiratoryRate: night.respiratoryRate,
            sleepEfficiency: night.sleepEfficiency,
            confidence: night.confidence,
            source: night.source,
            stageSegments: night.stageSegments,
            eventTimeZoneIdentifier: night.eventTimeZoneIdentifier,
            savedAt: now,
            motionValidated: night.motionValidated,
            motionBlocker: motionBlocker,
            evidenceFingerprint: evidenceFingerprint,
            sourceStrapIdentifier: sourceStrapIdentifier
        )
        guard let data = try? JSONEncoder().encode(record) else {
            return .rejected
        }
        defaults.set(data, forKey: key)
        return .saved
    }

    static func load(
        now: Date = Date(),
        confirmedSleeps: [UserConfirmedSleep],
        dismissedCandidates: [AtriaDismissedSleepCandidate],
        // Handoff-11: re-pairing invalidates a record that names its source
        // strap. Nil (legacy records, or callers without the identity) keeps
        // the previous behavior.
        currentStrapIdentifier: String? = nil,
        defaults: UserDefaults = .standard
    ) -> SleepHistorySnapshot.Night? {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schema == schema,
              recordMatchesStrap(record.sourceStrapIdentifier,
                                 current: currentStrapIdentifier),
              valid(start: record.start,
                    end: record.end,
                    duration: record.duration,
                    savedAt: record.savedAt,
                    now: now),
              !confirmedSleeps.contains(where: {
                  overlapFraction(
                    recordStart: record.start,
                    recordEnd: record.end,
                    otherStart: $0.start,
                    otherEnd: $0.end
                  ) >= 0.70
              }),
              !dismissedCandidates.contains(where: {
                  $0.suppresses(start: record.start, end: record.end)
              }) else {
            return nil
        }
        return SleepHistorySnapshot.Night(
            id: record.id,
            day: record.day,
            start: record.start,
            end: record.end,
            duration: record.duration,
            restingHR: record.restingHR,
            hrv: record.hrv,
            hrvWindowCount: record.hrvWindowCount,
            respiratoryRate: record.respiratoryRate,
            sleepEfficiency: record.sleepEfficiency,
            confidence: record.confidence,
            source: record.source,
            confirmed: false,
            stageSegments: record.stageSegments,
            eventTimeZoneIdentifier: record.eventTimeZoneIdentifier,
            motionValidated: record.motionValidated
        )
    }

    static func clear(
        overlappingStart start: Date,
        end: Date,
        defaults: UserDefaults = .standard
    ) {
        guard end > start,
              let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              min(record.end, end) > max(record.start, start) else { return }
        defaults.removeObject(forKey: key)
    }

    private static func recordMatchesStrap(
        _ recorded: String?,
        current: String?
    ) -> Bool {
        guard let recorded, let current else { return true }
        return recorded.caseInsensitiveCompare(current) == .orderedSame
    }

    private static func valid(
        start: Date,
        end: Date,
        duration: TimeInterval,
        savedAt: Date,
        now: Date
    ) -> Bool {
        end > start
            && duration > 0
            && duration <= end.timeIntervalSince(start) + 60
            && end <= now.addingTimeInterval(5 * 60)
            && end >= now.addingTimeInterval(-maximumAge)
            && savedAt <= now.addingTimeInterval(5 * 60)
            && savedAt >= end.addingTimeInterval(-24 * 60 * 60)
    }

    private static func overlapFraction(
        recordStart: Date,
        recordEnd: Date,
        otherStart: Date,
        otherEnd: Date
    ) -> Double {
        let duration = recordEnd.timeIntervalSince(recordStart)
        guard duration > 0 else { return 0 }
        return max(
            0,
            min(recordEnd, otherEnd).timeIntervalSince(
                max(recordStart, otherStart)
            )
        ) / duration
    }
}
