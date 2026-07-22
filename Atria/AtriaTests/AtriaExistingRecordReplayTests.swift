import XCTest
@testable import Atria

/// Side-effect-free test harness for replaying a pulled `sessions.json` through
/// the production detector, confirmation, cycle, baseline, HRV and recovery
/// functions without supplying evidence absent from the saved records.
private enum AtriaExistingRecordReplay {
    struct Result {
        let decodedSessionCount: Int
        let candidateCount: Int
        let candidate: AggregateSleepCandidate?
        let confirmedSleep: UserConfirmedSleep?
        let usedPersistedConfirmation: Bool
        let physiologicalCycle: AtriaPhysiologicalCycle
        let baseline: PersonalBaseline
        let morningMetric: SavedDailyMetric?
        let qualifiedStandardRRSessionCount: Int
        let locallyQualifiedHRVSessionCount: Int
    }

    enum ReplayError: Error { case emptyArchive }

    static func run(sessionsJSON: Data,
                    confirmedSleepsJSON: Data? = nil,
                    restingBaseline: Int,
                    maxHR: Int,
                    now: Date,
                    calendar: Calendar) throws -> Result {
        let sessions = try JSONDecoder().decode([SavedSession].self, from: sessionsJSON)
        guard !sessions.isEmpty else { throw ReplayError.emptyArchive }
        let persistedSleeps = try confirmedSleepsJSON.map {
            try JSONDecoder().decode([UserConfirmedSleep].self, from: $0)
        } ?? []
        let candidates = SessionStore.aggregateSleepCandidates(in: sessions,
                                                                rest: restingBaseline,
                                                                maxHR: maxHR,
                                                                calendar: calendar,
                                                                historicalMotionPolicy: .sessionOnly)
        let persisted = persistedSleeps
            .filter { $0.end <= now && SessionStore.confirmedSleepIsPhysiologicalMainSleep($0) }
            .max { $0.end < $1.end }
        let candidate = candidates
            .filter { $0.end <= now }
            .filter { candidate in
                guard let persisted else { return true }
                let overlap = min(candidate.end, persisted.end)
                    .timeIntervalSince(max(candidate.start, persisted.start))
                return overlap > 0 && overlap / max(candidate.duration, persisted.duration) >= 0.70
            }
            .filter {
                persisted != nil || SessionStore.isAutoConfirmableMainSleepCandidate(
                    $0, baselineRestingIsTrusted: true
                )
            }
            .max { $0.end < $1.end }
        let confirmed = persisted.flatMap {
            SessionStore.requalifiedConfirmedSleepHRVRecords([$0], sessions: sessions).first
        }
            ?? candidate.map { autoConfirmed($0, sessions: sessions, now: now) }
        let confirmedSleeps = confirmed.map { [$0] } ?? []
        let baseline = SessionStore.rebuildBaseline(
            from: sessions,
            previousBaseline: PersonalBaseline(restingHR: Double(restingBaseline),
                                               updated: sessions.map(\.end).min()),
            profile: AthleteProfile(age: 30, measuredMaxHR: maxHR, maxHRSource: .measured,
                                    updated: nil, hasCompletedOnboarding: true),
            confirmedSleeps: confirmedSleeps
        )
        let cycle = AtriaPhysiologicalCycle.current(now: now,
                                                    confirmedSleeps: confirmedSleeps,
                                                    calendar: calendar)
        let snapshot = SleepHistorySnapshot(rollups: [], confirmedSleeps: confirmedSleeps,
                                            calendar: calendar)
        let day = confirmed.map {
            EventCivilTime.day(containing: $0.end,
                               eventTimeZoneIdentifier: $0.eventTimeZoneIdentifier,
                               outputCalendar: calendar)
        } ?? calendar.startOfDay(for: now)
        let metric = SessionStore.makeMorningFrozenDailyMetric(for: day,
                                                               computed: [],
                                                               sessions: sessions,
                                                               sleep: snapshot,
                                                               baseline: baseline,
                                                               maxHR: maxHR,
                                                               now: now,
                                                               calendar: calendar)
        return Result(decodedSessionCount: sessions.count,
                      candidateCount: candidates.count,
                      candidate: candidate,
                      confirmedSleep: confirmed,
                      usedPersistedConfirmation: persisted != nil,
                      physiologicalCycle: cycle,
                      baseline: baseline,
                      morningMetric: metric,
                      qualifiedStandardRRSessionCount: sessions.filter(\.hasQualifiedStandardRRProvenance).count,
                      locallyQualifiedHRVSessionCount: sessions.filter { $0.localRMSSD != nil }.count)
    }

    private static func metrics(_ candidate: AggregateSleepCandidate,
                                sessions: [SavedSession])
        -> (sessions: Int, samples: Int, avgHR: Int, peakHR: Int, restingHR: Int,
            hrv: Int?, hrvWindowCount: Int) {
        SessionStore.confirmedSleepWindowMetrics(from: sessions,
                                                 start: candidate.start,
                                                 end: candidate.end,
                                                 rest: candidate.restingHR)
    }

    private static func autoConfirmed(_ candidate: AggregateSleepCandidate,
                                      sessions: [SavedSession], now: Date) -> UserConfirmedSleep {
        let classification = SessionStore.autoSleepClassification(for: candidate)
        let value = metrics(candidate, sessions: sessions)
        return UserConfirmedSleep(
            id: "existing-record-\(Int(candidate.start.timeIntervalSince1970))-\(Int(candidate.end.timeIntervalSince1970))",
            createdAt: now, start: candidate.start, end: candidate.end,
            source: classification.source, confidence: classification.confidence,
            sessions: value.sessions, samples: value.samples, avgHR: value.avgHR,
            peakHR: value.peakHR, restingHR: value.restingHR, hrv: value.hrv,
            hrvWindowCount: value.hrvWindowCount, duration: candidate.duration, span: candidate.span,
            reason: "deterministic_existing_record_replay; \(candidate.reason)",
            motionSource: classification.motionSource,
            motionValidated: classification.motionValidated, stageSegments: nil,
            eventTimeZoneIdentifier: SessionStore.autoSleepEventTimeZoneIdentifier(for: candidate)
        )
    }

}

final class AtriaExistingRecordReplayTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return value
    }

    private var pulledSessionsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("logs/live-device/morning-verification-20260718T080323Z/sessions.json")
    }

    private var pulledPreferencesURL: URL {
        pulledSessionsURL.deletingLastPathComponent().appendingPathComponent("preferences.plist")
    }

    private func persistedConfirmedSleepsJSON() throws -> Data {
        let plist = try Data(contentsOf: pulledPreferencesURL)
        let object = try PropertyListSerialization.propertyList(from: plist, format: nil)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(dictionary["atria.confirmedSleeps.v1"] as? Data)
    }

    private func capturedOvernightSessions(endingYear year: Int,
                                           month: Int,
                                           day: Int) throws -> [SavedSession] {
        let data = try Data(contentsOf: pulledSessionsURL)
        let all = try JSONDecoder().decode([SavedSession].self, from: data)
        let localNoon = try XCTUnwrap(calendar.date(from: DateComponents(year: year,
                                                                         month: month,
                                                                         day: day,
                                                                         hour: 12)))
        let previousEvening = try XCTUnwrap(calendar.date(byAdding: .hour,
                                                         value: -18,
                                                         to: localNoon))
        // Use only complete, authoritative records contained by the evening-to-noon
        // audit interval. Do not clip a session at either edge, because doing so
        // would manufacture a record shape that was never persisted on the phone.
        return all.filter { $0.start >= previousEvening && $0.end <= localNoon }
    }

    private func assertHonestRejectedNight(year: Int,
                                           month: Int,
                                           day: Int,
                                           expectedSessionCount: Int,
                                           expectedStandardRRPointCount: Int,
                                           expectedLegacyRRPointCount: Int,
                                           expectedQualifiedStandardRRSessionCount: Int,
                                           expectedLocallyQualifiedHRVSessionCount: Int,
                                           expectedMorningHRV: Int?,
                                           expectedLimitedRecovery: Int? = nil,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) throws {
        let sessions = try capturedOvernightSessions(endingYear: year, month: month, day: day)
        XCTAssertEqual(sessions.count, expectedSessionCount, file: file, line: line)
        XCTAssertTrue(sessions.allSatisfy { $0.motionEvidenceValidated != true },
                      "the pulled night contains no validated motion evidence",
                      file: file,
                      line: line)

        let rrPoints = sessions.flatMap { $0.rrPoints ?? [] }
        XCTAssertEqual(rrPoints.filter {
            $0.source == .standardHeartRateMeasurement2A37
        }.count, expectedStandardRRPointCount, file: file, line: line)
        XCTAssertEqual(rrPoints.filter { $0.source == nil }.count,
                       expectedLegacyRRPointCount,
                       file: file,
                       line: line)

        let result = try AtriaExistingRecordReplay.run(
            sessionsJSON: JSONEncoder().encode(sessions),
            restingBaseline: 54,
            maxHR: 190,
            now: try XCTUnwrap(sessions.map(\.end).max()).addingTimeInterval(60 * 60),
            calendar: calendar
        )

        XCTAssertEqual(result.decodedSessionCount, expectedSessionCount, file: file, line: line)
        XCTAssertFalse(result.usedPersistedConfirmation, file: file, line: line)
        XCTAssertNil(result.confirmedSleep,
                     "recorded evidence must not be promoted into confirmed sleep",
                     file: file,
                     line: line)
        XCTAssertNotEqual(result.physiologicalCycle.boundaryKind, .mainSleep,
                          file: file,
                          line: line)
        XCTAssertNil(result.morningMetric?.sleepDuration, file: file, line: line)
        XCTAssertEqual(result.morningMetric?.hrv, expectedMorningHRV, file: file, line: line)
        XCTAssertEqual(result.morningMetric?.recoveryPercent,
                       expectedLimitedRecovery,
                       file: file,
                       line: line)
        if expectedLimitedRecovery != nil {
            XCTAssertEqual(result.morningMetric?.recoveryConfidence,
                           Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
                           "a day-one RHR-only score must remain visibly limited-confidence",
                           file: file,
                           line: line)
            let summary = try XCTUnwrap(result.morningMetric?.recoverySummary,
                                        file: file,
                                        line: line)
            XCTAssertFalse(summary.usesHRV,
                           "RR outside a confirmed main sleep cannot influence Recovery",
                           file: file,
                           line: line)
            XCTAssertTrue(summary.detail.contains("Limited confidence"), file: file, line: line)
            XCTAssertTrue(summary.detail.contains("sleep and HRV unavailable"), file: file, line: line)
            XCTAssertEqual(summary.contributors.first(where: { $0.kind == "restingHeartRate" })?.weight,
                           0.20,
                           "RHR must retain its normal model weight instead of being promoted to full certainty",
                           file: file,
                           line: line)
            XCTAssertEqual(summary.contributors.first(where: { $0.kind == "hrv" })?.weight,
                           0,
                           file: file,
                           line: line)
            XCTAssertEqual(summary.contributors.first(where: { $0.kind == "sleep" })?.weight,
                           0,
                           file: file,
                           line: line)
        }
        XCTAssertEqual(result.baseline.hrvSampleCount, 0,
                       "qualified RR outside confirmed main sleep cannot advance the overnight HRV baseline",
                       file: file,
                       line: line)
        XCTAssertEqual(result.qualifiedStandardRRSessionCount,
                       expectedQualifiedStandardRRSessionCount,
                       file: file,
                       line: line)
        XCTAssertEqual(result.locallyQualifiedHRVSessionCount,
                       expectedLocallyQualifiedHRVSessionCount,
                       file: file,
                       line: line)
    }

    func testPulledArchiveReplaysDeterministicallyWithoutExternalMotion() throws {
        let data = try Data(contentsOf: pulledSessionsURL)
        let sessions = try JSONDecoder().decode([SavedSession].self, from: data)
        let now = Date(timeIntervalSinceReferenceDate: 805_702_080 + 60 * 60)

        let first = try AtriaExistingRecordReplay.run(sessionsJSON: data,
                                                      confirmedSleepsJSON: try persistedConfirmedSleepsJSON(),
                                                      restingBaseline: 54,
                                                      maxHR: 190,
                                                      now: now,
                                                      calendar: calendar)
        let second = try AtriaExistingRecordReplay.run(sessionsJSON: data,
                                                       confirmedSleepsJSON: try persistedConfirmedSleepsJSON(),
                                                       restingBaseline: 54,
                                                       maxHR: 190,
                                                       now: now,
                                                       calendar: calendar)

        XCTAssertEqual(first.decodedSessionCount, sessions.count)
        XCTAssertEqual(first.candidateCount, second.candidateCount)
        XCTAssertEqual(first.confirmedSleep?.id, second.confirmedSleep?.id)
        XCTAssertEqual(first.confirmedSleep?.hrv, second.confirmedSleep?.hrv)
        XCTAssertEqual(first.physiologicalCycle, second.physiologicalCycle)
        XCTAssertEqual(first.morningMetric, second.morningMetric)
    }

    func testPulledConfirmedBoundaryAnchorsAndShowsLimitedRecoveryWithoutUnqualifiedHRV() throws {
        let data = try Data(contentsOf: pulledSessionsURL)
        _ = try JSONDecoder().decode([SavedSession].self, from: data)
        let now = Date(timeIntervalSinceReferenceDate: 805_702_080 + 60 * 60)
        let result = try AtriaExistingRecordReplay.run(sessionsJSON: data,
                                                       confirmedSleepsJSON: try persistedConfirmedSleepsJSON(),
                                                       restingBaseline: 54,
                                                       maxHR: 190,
                                                       now: now,
                                                       calendar: calendar)

        let sleep = try XCTUnwrap(result.confirmedSleep)
        XCTAssertTrue(result.usedPersistedConfirmation)
        XCTAssertEqual(sleep.start.timeIntervalSinceReferenceDate, 805_674_000, accuracy: 0.001)
        XCTAssertEqual(sleep.end.timeIntervalSinceReferenceDate, 805_702_080, accuracy: 0.001)
        XCTAssertEqual(result.physiologicalCycle.boundaryKind, .mainSleep)
        XCTAssertEqual(result.physiologicalCycle.anchorSleepID, sleep.id)
        XCTAssertEqual(result.morningMetric?.sleepStart, sleep.start)
        XCTAssertEqual(result.morningMetric?.sleepEnd, sleep.end)
        XCTAssertNil(sleep.hrv, "legacy scalar HRV must be removed when raw qualified RR cannot reproduce it")
        XCTAssertNil(result.morningMetric?.hrv)
        XCTAssertNotNil(result.morningMetric?.recoveryPercent,
                        "confirmed measured sleep should still produce an honest day-one recovery")
        XCTAssertEqual(result.morningMetric?.recoveryConfidence,
                       Metrics.RecoveryEstimate.Confidence.unverified.rawValue)
        XCTAssertEqual(result.morningMetric?.recoverySummary?.usesHRV, false)
        XCTAssertTrue(result.morningMetric?.recoverySummary?.detail.contains("HRV unavailable") == true)
        XCTAssertEqual(result.baseline.hrvSampleCount, 0)
    }

    func testJuly8IsolatedLegacyMotionFragmentCannotValidateWholeSleep() throws {
        let data = try Data(contentsOf: pulledSessionsURL)
        let recordedEnd = Date(timeIntervalSinceReferenceDate: 805_179_279.049116)
        let result = try AtriaExistingRecordReplay.run(
            sessionsJSON: data,
            restingBaseline: 60,
            maxHR: 190,
            now: recordedEnd.addingTimeInterval(60 * 60),
            calendar: calendar
        )

        XCTAssertNil(result.candidate)
        XCTAssertNil(result.confirmedSleep)
        XCTAssertFalse(result.usedPersistedConfirmation)
        XCTAssertNotEqual(result.physiologicalCycle.boundaryKind, .mainSleep)
        XCTAssertNil(result.physiologicalCycle.anchorSleepID)
    }

    func testRemovingRRDoesNotManufactureHRVOrRecoveryInput() throws {
        let data = try Data(contentsOf: pulledSessionsURL)
        var sessions = try JSONDecoder().decode([SavedSession].self, from: data)
        sessions = sessions.map { session in
            var copy = session
            copy.rrPoints = nil
            copy.hrv = nil
            return copy
        }
        let stripped = try JSONEncoder().encode(sessions)
        let now = try XCTUnwrap(sessions.map(\.end).max()).addingTimeInterval(60 * 60)
        let result = try AtriaExistingRecordReplay.run(sessionsJSON: stripped,
                                                       restingBaseline: 54,
                                                       maxHR: 190,
                                                       now: now,
                                                       calendar: calendar)

        XCTAssertNil(result.confirmedSleep?.hrv)
        XCTAssertEqual(result.baseline.hrvSampleCount, 0)
        XCTAssertNil(result.morningMetric?.hrv)
    }

    func testLatestJuly18AwakeRecordsDoNotAutoConfirmAsSleep() throws {
        let data = try Data(contentsOf: pulledSessionsURL)
        let all = try JSONDecoder().decode([SavedSession].self, from: data)
        let recent = all.filter { $0.start.timeIntervalSinceReferenceDate >= 806_006_000 }
        let recentData = try JSONEncoder().encode(recent)
        let now = try XCTUnwrap(recent.map(\.end).max()).addingTimeInterval(60 * 60)
        let result = try AtriaExistingRecordReplay.run(sessionsJSON: recentData,
                                                       restingBaseline: 54,
                                                       maxHR: 190,
                                                       now: now,
                                                       calendar: calendar)

        XCTAssertFalse(result.usedPersistedConfirmation)
        XCTAssertNil(result.confirmedSleep, "July 18 awake/fragmented wear must remain rejected")
        XCTAssertNotEqual(result.physiologicalCycle.boundaryKind, .mainSleep)
        XCTAssertNil(result.morningMetric?.sleepDuration)
        XCTAssertGreaterThan(result.qualifiedStandardRRSessionCount, 0)
        XCTAssertGreaterThan(result.locallyQualifiedHRVSessionCount, 0,
                             "real July 17/18 2A37 RR must pass local HRV qualification without becoming sleep")
    }

    func testJuly15CapturedNightCannotRecoverFromLegacyRRAndUnvalidatedMotion() throws {
        try assertHonestRejectedNight(year: 2026,
                                      month: 7,
                                      day: 15,
                                      expectedSessionCount: 6,
                                      expectedStandardRRPointCount: 0,
                                      expectedLegacyRRPointCount: 19_515,
                                      expectedQualifiedStandardRRSessionCount: 0,
                                      expectedLocallyQualifiedHRVSessionCount: 0,
                                      expectedMorningHRV: nil,
                                      expectedLimitedRecovery: 72)
    }

    func testJuly16CapturedNightDoesNotPromoteSparseQualifiedRRWithoutSleepEvidence() throws {
        try assertHonestRejectedNight(year: 2026,
                                      month: 7,
                                      day: 16,
                                      expectedSessionCount: 8,
                                      expectedStandardRRPointCount: 168,
                                      expectedLegacyRRPointCount: 0,
                                      expectedQualifiedStandardRRSessionCount: 6,
                                      expectedLocallyQualifiedHRVSessionCount: 0,
                                      expectedMorningHRV: nil)
    }

    func testJuly17CapturedNightKeepsQualifiedHRVSeparateFromRejectedSleep() throws {
        try assertHonestRejectedNight(year: 2026,
                                      month: 7,
                                      day: 17,
                                      expectedSessionCount: 9,
                                      expectedStandardRRPointCount: 14_029,
                                      expectedLegacyRRPointCount: 0,
                                      expectedQualifiedStandardRRSessionCount: 9,
                                      expectedLocallyQualifiedHRVSessionCount: 2,
                                      expectedMorningHRV: nil,
                                      expectedLimitedRecovery: 63)
    }

    func testJuly18CapturedNightKeepsQualifiedHRVSeparateFromFragmentedWear() throws {
        try assertHonestRejectedNight(year: 2026,
                                      month: 7,
                                      day: 18,
                                      expectedSessionCount: 6,
                                      expectedStandardRRPointCount: 4_424,
                                      expectedLegacyRRPointCount: 0,
                                      expectedQualifiedStandardRRSessionCount: 5,
                                      expectedLocallyQualifiedHRVSessionCount: 1,
                                      expectedMorningHRV: 74,
                                      expectedLimitedRecovery: 65)
    }
}
