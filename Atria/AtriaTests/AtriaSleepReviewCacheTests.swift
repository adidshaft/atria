import XCTest
@testable import Atria

final class AtriaSleepReviewCacheTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: day, hour: hour))!
    }

    private func sleepSession(day: Int,
                              startHour: Int = 22,
                              durationHours: Int = 4,
                              bpm: Int = 55) -> SavedSession {
        let start = date(day: day, hour: startHour)
        let duration = TimeInterval(durationHours * 60 * 60)
        let points = stride(from: 0, through: Int(duration), by: 60).map {
            SavedSession.Point(t: TimeInterval($0), bpm: bpm)
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(duration),
                            label: "Sleep evidence",
                            points: points)
    }

    private func reviewNight(id: String, confirmed: Bool = false) -> SleepHistorySnapshot.Night {
        let start = date(day: 8, hour: 22)
        return SleepHistorySnapshot.Night(id: id,
                                          day: calendar.startOfDay(for: start),
                                          start: start,
                                          end: start.addingTimeInterval(4 * 60 * 60),
                                          duration: 4 * 60 * 60,
                                          restingHR: 54,
                                          hrv: nil,
                                          respiratoryRate: nil,
                                          sleepEfficiency: 1,
                                          confidence: "review_needed",
                                          source: "sleep_window",
                                          confirmed: confirmed,
                                          stageSegments: [])
    }

    private func confirmedSleep(overlapping session: SavedSession) -> UserConfirmedSleep {
        UserConfirmedSleep(id: "confirmed-overlap",
                           createdAt: session.end,
                           start: session.start,
                           end: session.end,
                           source: "manual_sleep",
                           confidence: "manual_user_entered",
                           sessions: 1,
                           samples: session.points.count,
                           avgHR: session.avg,
                           peakHR: session.peak,
                           restingHR: session.restingStable,
                           hrv: nil,
                           hrvWindowCount: 0,
                           duration: session.duration,
                           span: session.duration,
                           reason: "test",
                           motionSource: "manual",
                           motionValidated: false,
                           stageSegments: nil)
    }

    func testUnconfirmedSnapshotNightKeepsPriorityOverAggregatedSession() {
        let expected = reviewNight(id: "snapshot-wins")
        let snapshot = SleepHistorySnapshot(nights: [expected], confirmedCount: 0, candidateCount: 1)

        let result = SessionStore.makeSleepReviewNightForCache(snapshot: snapshot,
                                                               canonicalSessions: [sleepSession(day: 10)],
                                                               confirmedSleeps: [],
                                                               rest: 60,
                                                               maxHR: 190,
                                                               calendar: calendar)

        XCTAssertEqual(result, expected)
    }

    func testFragmentedSubThreeHourHROnlySnapshotDoesNotClaimSleep() {
        let start = calendar.date(from: DateComponents(year: 2027, month: 1, day: 8,
                                                        hour: 22, minute: 18))!
        let falseCandidate = SleepHistorySnapshot.Night(
            id: "quiet-awake-fragmented",
            day: calendar.startOfDay(for: start),
            start: start,
            end: start.addingTimeInterval(3 * 3_600 + 47 * 60),
            duration: 2 * 3_600 + 31 * 60,
            restingHR: 58,
            hrv: nil,
            respiratoryRate: nil,
            sleepEfficiency: 0.66,
            confidence: "review_needed",
            source: "aggregate_sleep",
            confirmed: false,
            stageSegments: []
        )
        let snapshot = SleepHistorySnapshot(nights: [falseCandidate],
                                            confirmedCount: 0,
                                            candidateCount: 1)

        XCTAssertNil(snapshot.latestReviewable)
        XCTAssertNil(SessionStore.makeSleepReviewNightForCache(snapshot: snapshot,
                                                                canonicalSessions: [],
                                                                confirmedSleeps: [],
                                                                rest: 60,
                                                                maxHR: 190,
                                                                calendar: calendar))
    }

    func testPhysiologicalReviewMergesBrokenMainSleepAndIgnoresOneSpike() throws {
        let recordingStart = date(day: 10, hour: 2)
        var points: [SavedSession.Point] = []
        func append(from startMinute: Int, through endMinute: Int, bpm: Int) {
            for minute in startMinute...endMinute {
                points.append(SavedSession.Point(t: TimeInterval(minute * 60), bpm: bpm))
            }
        }
        append(from: 0, through: 104, bpm: 78)       // awake until 03:44
        append(from: 110, through: 375, bpm: 60)     // 03:50–08:15
        append(from: 425, through: 440, bpm: 61)     // resumed 09:05–09:20
        append(from: 550, through: 620, bpm: 60)     // resumed 11:10–12:20
        points.append(SavedSession.Point(t: TimeInterval(600 * 60), bpm: 115))
        let session = SavedSession(id: UUID(),
                                   start: recordingStart,
                                   end: recordingStart.addingTimeInterval(621 * 60),
                                   label: "Fragmented all-day wear",
                                   points: points.sorted { $0.t < $1.t })

        let result = try XCTUnwrap(SessionStore.physiologicalSleepReviewNight(
            in: [session],
            rest: 61,
            calendar: calendar
        ))

        XCTAssertEqual(result.source, "sleep_episode_review")
        XCTAssertEqual(result.start, date(day: 10, hour: 3).addingTimeInterval(50 * 60))
        XCTAssertEqual(result.end, date(day: 10, hour: 12).addingTimeInterval(20 * 60))
        XCTAssertFalse(result.confirmed)
        XCTAssertLessThan(result.sleepEfficiency ?? 1, 0.8)
    }

    func testMotionReadyFragmentedCandidateRemainsReviewable() {
        let start = date(day: 8, hour: 22)
        let candidate = SleepHistorySnapshot.Night(
            id: "motion-ready-fragmented",
            day: calendar.startOfDay(for: start),
            start: start,
            end: start.addingTimeInterval(3.5 * 3_600),
            duration: 2.75 * 3_600,
            restingHR: 54,
            hrv: nil,
            respiratoryRate: nil,
            sleepEfficiency: 0.78,
            confidence: "ready",
            source: "validated_sleep_window",
            confirmed: false,
            stageSegments: []
        )

        XCTAssertEqual(SleepHistorySnapshot(nights: [candidate],
                                            confirmedCount: 0,
                                            candidateCount: 1).latestReviewable,
                       candidate)
    }

    func testAggregateSelectionUsesNewestReviewDayAndBuildsStagesOffMainInput() {
        let older = sleepSession(day: 8)
        let newer = sleepSession(day: 10)

        let result = SessionStore.makeSleepReviewNightForCache(snapshot: .empty,
                                                               canonicalSessions: [older, newer],
                                                               confirmedSleeps: [],
                                                               rest: 60,
                                                               maxHR: 190,
                                                               calendar: calendar)

        XCTAssertEqual(result?.start, newer.start)
        XCTAssertEqual(result?.end, newer.end)
        XCTAssertEqual(result?.source, "sleep_episode_review")
        XCTAssertFalse(result?.stageSegments.isEmpty ?? true)
    }

    func testOverlappingConfirmationSuppressesNewestCandidateWithoutOlderFallback() {
        let older = sleepSession(day: 8)
        let newer = sleepSession(day: 10)

        let result = SessionStore.makeSleepReviewNightForCache(
            snapshot: .empty,
            canonicalSessions: [older, newer],
            confirmedSleeps: [confirmedSleep(overlapping: newer)],
            rest: 60,
            maxHR: 190,
            calendar: calendar)

        XCTAssertNil(result)
    }

    func testGenerationGuardRejectsCancelledOrSupersededBuilds() {
        XCTAssertTrue(SessionStore.shouldPublishSleepReviewCache(completedGeneration: 12,
                                                                 currentGeneration: 12))
        XCTAssertFalse(SessionStore.shouldPublishSleepReviewCache(completedGeneration: 11,
                                                                  currentGeneration: 12))
    }

    func testSameCountReplacementCanAdvanceCacheRevision() {
        let before = SessionStore.SleepReviewCacheKey(canonicalSessionsRevision: 4,
                                                      confirmedSleepsRevision: 2,
                                                      sleepHistorySnapshotRevision: 8,
                                                      activeJournalID: nil,
                                                      activeJournalEndFiveMinuteBucket: nil,
                                                      restingHR: 60,
                                                      maxHR: 190,
                                                      calendarIdentifier: "gregorian",
                                                      timeZoneIdentifier: "GMT",
                                                      secondsFromGMT: 0)
        let after = SessionStore.SleepReviewCacheKey(canonicalSessionsRevision: 5,
                                                     confirmedSleepsRevision: 2,
                                                     sleepHistorySnapshotRevision: 8,
                                                     activeJournalID: nil,
                                                     activeJournalEndFiveMinuteBucket: nil,
                                                     restingHR: 60,
                                                     maxHR: 190,
                                                     calendarIdentifier: "gregorian",
                                                     timeZoneIdentifier: "GMT",
                                                     secondsFromGMT: 0)

        XCTAssertNotEqual(before, after)
    }

    func testActiveJournalAdvanceCanInvalidateSleepReviewCache() {
        let journalID = UUID()
        let before = SessionStore.SleepReviewCacheKey(canonicalSessionsRevision: 4,
                                                      confirmedSleepsRevision: 2,
                                                      sleepHistorySnapshotRevision: 8,
                                                      activeJournalID: journalID,
                                                      activeJournalEndFiveMinuteBucket: 100,
                                                      restingHR: 60,
                                                      maxHR: 190,
                                                      calendarIdentifier: "gregorian",
                                                      timeZoneIdentifier: "GMT",
                                                      secondsFromGMT: 0)
        let after = SessionStore.SleepReviewCacheKey(canonicalSessionsRevision: 4,
                                                     confirmedSleepsRevision: 2,
                                                     sleepHistorySnapshotRevision: 8,
                                                     activeJournalID: journalID,
                                                     activeJournalEndFiveMinuteBucket: 101,
                                                     restingHR: 60,
                                                     maxHR: 190,
                                                     calendarIdentifier: "gregorian",
                                                     timeZoneIdentifier: "GMT",
                                                     secondsFromGMT: 0)

        XCTAssertNotEqual(before, after)
    }

    func testSleepReviewPreparationUsesBoundedHistoricalMotion() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "nonisolated static func makeSleepReviewNightForCache"))
        let end = try XCTUnwrap(source.range(of: "nonisolated static func shouldPublishSleepReviewCache",
                                             range: start.lowerBound..<source.endIndex))
        let implementation = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(implementation.contains("historicalMotionPolicy: .boundedRecent"))
        XCTAssertFalse(implementation.contains("HistoricalArchive.motionWindowDiagnostics"))
    }
}
