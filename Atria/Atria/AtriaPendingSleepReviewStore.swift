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
            savedAt: now
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(
        now: Date = Date(),
        confirmedSleeps: [UserConfirmedSleep],
        dismissedCandidates: [AtriaDismissedSleepCandidate],
        defaults: UserDefaults = .standard
    ) -> SleepHistorySnapshot.Night? {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schema == schema,
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
            eventTimeZoneIdentifier: record.eventTimeZoneIdentifier
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
