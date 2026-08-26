import XCTest
@testable import Atria

final class AtriaSleepReviewCacheTests: XCTestCase {
    /// Field report 2026-08-19, item 11 defect (2). `runResidentSleepReviewRefreshIfUseful`
    /// exists specifically to catch a daytime nap while the app stays
    /// backgrounded — its own comment cites the on-device 2026-08-01 case of a
    /// 14:05-16:40 nap that "produced no detection at all while the app stayed
    /// backgrounded". It then routed into a gate requiring BOTH the store-owned
    /// foreground authority and UIKit `.active`, so it was a no-op in exactly the
    /// scenario it was written for, and the notification could not fire until the
    /// user opened the app.
    func testResidentCheckpointMayProjectWhileBackgrounded() {
        func enqueue(reason: String,
                     foregroundAuthority: Bool,
                     active: Bool,
                     restoreBlocked: Bool = false) -> Bool {
            SessionStore.shouldEnqueueSleepReviewProjection(
                hasForegroundAuthority: foregroundAuthority,
                applicationIsActive: active,
                restoreInitializationBlocked: restoreBlocked,
                cacheMatchesInput: false,
                pendingMatchesInput: false,
                backgroundResidentAdmission:
                    SessionStore.sleepReviewProjectionBackgroundAdmission(
                        reason: reason,
                        restoreInitializationBlocked: restoreBlocked
                    )
            )
        }

        // THE FIELD CASE: backgrounded, no foreground authority, resident lane.
        XCTAssertTrue(enqueue(reason: SessionStore.residentSleepReviewRefreshReason,
                              foregroundAuthority: false, active: false),
                      "the resident nap-catcher must be able to run unattended")

        // Every other reason still requires BOTH foreground gates, so the
        // SwiftUI-scene/UIKit ABA race the authority closes stays closed.
        XCTAssertFalse(enqueue(reason: "ui_request", foregroundAuthority: false, active: false))
        XCTAssertFalse(enqueue(reason: "ui_request", foregroundAuthority: true, active: false))
        XCTAssertFalse(enqueue(reason: "ui_request", foregroundAuthority: false, active: true))
        XCTAssertTrue(enqueue(reason: "ui_request", foregroundAuthority: true, active: true))

        // A blocked restore refuses every lane, resident included.
        XCTAssertFalse(enqueue(reason: SessionStore.residentSleepReviewRefreshReason,
                               foregroundAuthority: false, active: false,
                               restoreBlocked: true))
    }

    /// The input-key dedupe is still the final authority, so an admitted
    /// background lane cannot spend CPU when nothing changed.
    func testBackgroundAdmissionStillRespectsTheInputKeyDedupe() {
        func enqueue(cacheMatches: Bool, pendingMatches: Bool) -> Bool {
            SessionStore.shouldEnqueueSleepReviewProjection(
                hasForegroundAuthority: false,
                applicationIsActive: false,
                restoreInitializationBlocked: false,
                cacheMatchesInput: cacheMatches,
                pendingMatchesInput: pendingMatches,
                backgroundResidentAdmission: true
            )
        }
        XCTAssertTrue(enqueue(cacheMatches: false, pendingMatches: false))
        XCTAssertFalse(enqueue(cacheMatches: true, pendingMatches: false))
        XCTAssertFalse(enqueue(cacheMatches: false, pendingMatches: true))
    }

    /// Only the resident reason earns unattended admission.
    func testOnlyTheResidentReasonEarnsBackgroundAdmission() {
        XCTAssertTrue(SessionStore.sleepReviewProjectionBackgroundAdmission(
            reason: SessionStore.residentSleepReviewRefreshReason,
            restoreInitializationBlocked: false))
        for reason in ["ui_request", "notification", "scene_active", "launch", ""] {
            XCTAssertFalse(SessionStore.sleepReviewProjectionBackgroundAdmission(
                reason: reason, restoreInitializationBlocked: false),
                "\(reason) must not run the projection unattended")
        }
    }

    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

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
                              // A generic cache fixture must be main-sleep-sized.
                              // The physically disproved 22:18–02:05 shape is
                              // now intentionally diagnostic-only.
                              durationHours: Int = 5,
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

    private func napReviewNight(id: String = "cached-nap") -> SleepHistorySnapshot.Night {
        let start = date(day: 10, hour: 14)
        return SleepHistorySnapshot.Night(id: id,
                                          day: calendar.startOfDay(for: start),
                                          start: start,
                                          end: start.addingTimeInterval(60 * 60),
                                          duration: 60 * 60,
                                          restingHR: 62,
                                          hrv: nil,
                                          respiratoryRate: nil,
                                          sleepEfficiency: 1,
                                          confidence: "review_needed",
                                          source: "nap_candidate",
                                          confirmed: false,
                                          stageSegments: [])
    }

    private func daytimeLowHRSession(start: Date,
                                     validatedMotion: Bool) -> SavedSession {
        let duration: TimeInterval = 60 * 60
        var session = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(duration),
            label: "Daytime low-HR evidence",
            points: stride(from: 0.0, through: duration, by: 60.0).map {
                SavedSession.Point(t: $0, bpm: 62)
            }
        )
        session.motionEvidenceSource = validatedMotion ? "validated_strap_motion" : "unavailable"
        session.motionEvidenceValidated = validatedMotion
        return session
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

    private func automaticSleep(start: Date, end: Date) -> UserConfirmedSleep {
        UserConfirmedSleep(id: "automatic-\(Int(start.timeIntervalSince1970))",
                           createdAt: end,
                           start: start,
                           end: end,
                           source: "auto_confirmed_sleep",
                           confidence: "high",
                           sessions: 1,
                           samples: 500,
                           avgHR: 58,
                           peakHR: 70,
                           restingHR: 55,
                           hrv: 48,
                           hrvWindowCount: 4,
                           duration: end.timeIntervalSince(start),
                           span: end.timeIntervalSince(start),
                           reason: "test",
                           motionSource: "strap_motion",
                           motionValidated: true,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: "UTC")
    }

    @MainActor
    func testResolutionDistinguishesColdCacheFromResolvedResult() async {
        let store = SessionStore()

        guard case .loading = store.sleepReviewResolutionForUI(rest: 60,
                                                               calendar: calendar,
                                                               source: "cold-cache-test") else {
            return XCTFail("a new revision must report loading instead of masquerading as no candidate")
        }

        // The full suite runs several utility-queue projections in parallel;
        // assert eventual bounded resolution without turning scheduler load
        // into a one-second product failure.
        for _ in 0..<250 {
            try? await Task.sleep(for: .milliseconds(20))
            if case .ready = store.sleepReviewResolutionForUI(rest: 60,
                                                              calendar: calendar,
                                                              source: "cold-cache-test-poll") {
                return
            }
        }
        XCTFail("the cold-cache projection did not publish a resolved result")
    }

    func testSleepDismissalRequiresSubstantialCandidateCoverage() {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let fullEnd = start.addingTimeInterval(6 * 60 * 60)
        let deletedNight = AtriaDismissedSleepCandidate(start: start,
                                                        end: fullEnd)
        XCTAssertTrue(deletedNight.suppresses(start: start.addingTimeInterval(5 * 60),
                                              end: fullEnd.addingTimeInterval(10 * 60)),
                      "a deleted full night stays suppressed across small boundary drift")

        let partialFalseWindow = AtriaDismissedSleepCandidate(
            start: start.addingTimeInterval(2 * 60 * 60),
            end: start.addingTimeInterval(2 * 60 * 60 + 10 * 60)
        )
        XCTAssertTrue(partialFalseWindow.overlaps(start: start, end: fullEnd))
        XCTAssertFalse(partialFalseWindow.suppresses(start: start, end: fullEnd),
                       "a tiny dismissed fragment must not hide a materially larger real night")
    }

    func testBothAutomaticPersistencePathsHonorDurableDismissals() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sessions = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift"), encoding: .utf8)

        let closedStart = try XCTUnwrap(sessions.range(of: "private func autoConfirmStrongSleepCandidates"))
        let closedEnd = try XCTUnwrap(sessions.range(of: "private func buildAutoConfirmedSleep", range: closedStart.upperBound..<sessions.endIndex))
        let closed = sessions[closedStart.lowerBound..<closedEnd.lowerBound]
        XCTAssertTrue(closed.contains("$0.suppresses(start: candidate.start, end: candidate.end)"))

        let wakeStart = try XCTUnwrap(sessions.range(of: "private func commitPreparedWakeBoundarySleepIfUseful"))
        let wakeEnd = try XCTUnwrap(sessions.range(of: "private func applySleepExtend", range: wakeStart.upperBound..<sessions.endIndex))
        let wake = sessions[wakeStart.lowerBound..<wakeEnd.lowerBound]
        XCTAssertTrue(wake.contains("$0.suppresses(start: candidate.start, end: candidate.end)"))
    }

    func testArchiveStatusNotificationsCannotStarveSleepReviewResolution() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sessions = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift"), encoding: .utf8)

        let observerStart = try XCTUnwrap(sessions.range(of:
            "HistoricalArchive.didUpdateNotification"))
        let observerEnd = try XCTUnwrap(sessions.range(of:
            "self.systemTimeZoneObserver",
            range: observerStart.upperBound..<sessions.endIndex))
        let observer = sessions[observerStart.lowerBound..<observerEnd.lowerBound]
        XCTAssertFalse(observer.contains("invalidateSleepReviewCache"))
        XCTAssertTrue(observer.contains("handleAutomaticRecoveredArchiveDidUpdate"))
        let archiveHandlerStart = try XCTUnwrap(sessions.range(of:
            "private func handleAutomaticRecoveredArchiveDidUpdate"))
        let archiveHandlerEnd = try XCTUnwrap(sessions.range(of:
            "private func requestRecoveredDataRecomputation",
            range: archiveHandlerStart.upperBound..<sessions.endIndex))
        let archiveHandler = sessions[archiveHandlerStart.lowerBound..<archiveHandlerEnd.lowerBound]
        XCTAssertTrue(archiveHandler.contains("requestRecoveredDataRecomputation"))
        let recoveredRequestStart = try XCTUnwrap(sessions.range(of:
            "private func requestRecoveredDataRecomputation"))
        let recoveredRequestEnd = try XCTUnwrap(sessions.range(of:
            "private func beginRecoveredDataMutationTransaction",
            range: recoveredRequestStart.upperBound..<sessions.endIndex))
        let recoveredRequest = sessions[recoveredRequestStart.lowerBound..<recoveredRequestEnd.lowerBound]
        XCTAssertTrue(recoveredRequest.contains("scheduleConfirmedWorkoutArchiveRehydration"))
        XCTAssertTrue(sessions.contains(
            "@Published private(set) var historicalArchiveStatus = HistoricalArchiveStatus.empty"
        ))
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

    func testStaleCachedNapDoesNotSurviveActiveLowHRWithoutValidatedMotion() throws {
        let cachedNap = napReviewNight()
        let snapshot = SleepHistorySnapshot(nights: [cachedNap], confirmedCount: 0, candidateCount: 1)
        let activeLowHR = daytimeLowHRSession(start: try XCTUnwrap(cachedNap.start),
                                               validatedMotion: false)

        let result = SessionStore.makeSleepReviewNightForCache(
            snapshot: snapshot,
            canonicalSessions: [activeLowHR],
            confirmedSleeps: [],
            rest: 62,
            maxHR: 190,
            calendar: calendar
        )

        XCTAssertNil(result,
                     "a stale cached nap must not outlive a fresh active/low-HR pass without strap motion proof")
    }

    func testCachedNapSurvivesFreshOverlappingValidatedMotionEvidence() throws {
        let cachedNap = napReviewNight(id: "motion-backed-cached-nap")
        let snapshot = SleepHistorySnapshot(nights: [cachedNap], confirmedCount: 0, candidateCount: 1)
        let motionBackedNap = daytimeLowHRSession(start: try XCTUnwrap(cachedNap.start),
                                                   validatedMotion: true)

        let result = SessionStore.makeSleepReviewNightForCache(
            snapshot: snapshot,
            canonicalSessions: [motionBackedNap],
            confirmedSleeps: [],
            rest: 62,
            maxHR: 190,
            calendar: calendar
        )

        XCTAssertEqual(result, cachedNap)
    }

    // MARK: - Nap detection rows (2026-08-01)

    func testNapCandidateBecomesNapReviewNight() throws {
        let napStart = date(day: 12, hour: 14)
        let nap = daytimeLowHRSession(start: napStart, validatedMotion: true)

        let rows = SessionStore.makeNapReviewNightsForCache(
            canonicalSessions: [nap],
            confirmedSleeps: [],
            rest: 62,
            maxHR: 190,
            calendar: calendar
        )

        let row = try XCTUnwrap(rows.first, "a review-worthy nap must surface as its own review night")
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(row.isNapEvidence, "the row must read as a nap")
        XCTAssertFalse(row.confirmed, "nap rows are review-only, never auto-confirmed")
        XCTAssertEqual(row.source, "nap_candidate")
    }

    func testHROnlyNapNightReadsAsAReviewableNap() {
        // Naps are review-only: the surfacing helper imposes no extra motion
        // gate, so an HR-only nap (confidence "review_needed", no validated
        // motion) must still read as a nap needing review — never a confident
        // sleep. This is the presentation contract the nap rows depend on.
        let start = date(day: 12, hour: 14)
        let hrOnlyNap = SleepHistorySnapshot.Night(id: "hr-only-nap",
                                                   day: calendar.startOfDay(for: start),
                                                   start: start,
                                                   end: start.addingTimeInterval(40 * 60),
                                                   duration: 40 * 60,
                                                   restingHR: 62,
                                                   hrv: nil,
                                                   respiratoryRate: nil,
                                                   sleepEfficiency: 1,
                                                   confidence: "review_needed",
                                                   source: "nap_candidate",
                                                   confirmed: false,
                                                   stageSegments: [],
                                                   motionValidated: false)

        XCTAssertTrue(hrOnlyNap.isNapEvidence)
        XCTAssertFalse(hrOnlyNap.confirmed)
        XCTAssertFalse(hrOnlyNap.hasValidatedMotionEvidence)
        XCTAssertEqual(hrOnlyNap.confirmationText, "Nap candidate")
        XCTAssertEqual(AtriaActivitySleepStatusPresentation.badge(
            confirmed: hrOnlyNap.confirmed,
            confidence: hrOnlyNap.confidence
        ), "Review")
    }

    func testDismissedNapExcludedFromNapReviewNights() throws {
        let napStart = date(day: 12, hour: 14)
        let nap = daytimeLowHRSession(start: napStart, validatedMotion: true)
        let dismissal = AtriaDismissedSleepCandidate(start: nap.start, end: nap.end)

        let rows = SessionStore.makeNapReviewNightsForCache(
            canonicalSessions: [nap],
            confirmedSleeps: [],
            dismissedCandidates: [dismissal],
            rest: 62,
            maxHR: 190,
            calendar: calendar
        )

        XCTAssertTrue(rows.isEmpty, "a dismissed nap must stay gone")
    }

    func testConfirmedNapExcludedFromNapReviewNights() throws {
        let napStart = date(day: 12, hour: 14)
        let nap = daytimeLowHRSession(start: napStart, validatedMotion: true)
        let confirmed = confirmedSleep(overlapping: nap)

        let rows = SessionStore.makeNapReviewNightsForCache(
            canonicalSessions: [nap],
            confirmedSleeps: [confirmed],
            rest: 62,
            maxHR: 190,
            calendar: calendar
        )

        XCTAssertTrue(rows.isEmpty, "a confirmed nap must not resurface as a review row")
    }

    func testMainSleepDoesNotBecomeNapReviewNight() {
        // A full overnight main sleep must never leak into the nap rows; main
        // sleep keeps its own single review card.
        let mainSleep = sleepSession(day: 12, startHour: 23, durationHours: 6, bpm: 52)

        let rows = SessionStore.makeNapReviewNightsForCache(
            canonicalSessions: [mainSleep],
            confirmedSleeps: [],
            rest: 55,
            maxHR: 190,
            calendar: calendar
        )

        XCTAssertTrue(rows.allSatisfy { $0.isNapEvidence },
                      "only naps may appear in the nap review rows")
        XCTAssertFalse(rows.contains { $0.duration >= AggregateSleepCandidate.strictMinimumDuration },
                       "a main-sleep-sized window must not appear as a nap row")
    }

    func testGrowingResidentJournalAggregateReplacesFirstWakeSnapshot() throws {
        let staleStart = date(day: 10, hour: 3).addingTimeInterval(16 * 60)
        let staleEnd = date(day: 10, hour: 9).addingTimeInterval(15 * 60)
        let stale = SleepHistorySnapshot.Night(
            id: "first-wake-snapshot",
            day: calendar.startOfDay(for: staleEnd),
            start: staleStart,
            end: staleEnd,
            duration: staleEnd.timeIntervalSince(staleStart),
            restingHR: 58,
            hrv: nil,
            respiratoryRate: nil,
            sleepEfficiency: 1,
            confidence: "review_needed",
            source: "sleep_window",
            confirmed: false,
            stageSegments: []
        )
        let snapshot = SleepHistorySnapshot(nights: [stale],
                                            confirmedCount: 0,
                                            candidateCount: 1)
        let firstStart = date(day: 10, hour: 6).addingTimeInterval(55 * 60)
        let rollover = date(day: 10, hour: 9).addingTimeInterval(55 * 60)
        let finalEnd = date(day: 10, hour: 12).addingTimeInterval(15 * 60)
        func session(start: Date, end: Date, briefWakeAt: Date? = nil) -> SavedSession {
            let duration = end.timeIntervalSince(start)
            let points = stride(from: 0.0, through: duration, by: 60).map { offset in
                let date = start.addingTimeInterval(offset)
                let isBriefWake = briefWakeAt.map {
                    date >= $0 && date < $0.addingTimeInterval(5 * 60)
                } ?? false
                return SavedSession.Point(t: offset, bpm: isBriefWake ? 88 : 58)
            }
            return SavedSession(id: UUID(),
                                start: start,
                                end: end,
                                label: "Resident all-day journal",
                                points: points)
        }
        let beforeRollover = session(start: firstStart, end: rollover)
        let activeJournal = session(start: rollover.addingTimeInterval(1),
                                    end: finalEnd,
                                    briefWakeAt: date(day: 10, hour: 10))

        let result = try XCTUnwrap(SessionStore.makeSleepReviewNightForCache(
            snapshot: snapshot,
            canonicalSessions: [beforeRollover, activeJournal],
            confirmedSleeps: [],
            rest: 59,
            maxHR: 190,
            calendar: calendar
        ))

        XCTAssertEqual(result.start, firstStart)
        XCTAssertEqual(result.end, finalEnd)
        XCTAssertEqual(result.source, "aggregate_sleep")
        XCTAssertFalse(result.confirmed,
                       "resident-journal growth must remain review-only without validated motion")
    }

    func testGrowingReviewDoesNotReplaceWithUnrelatedSameDayEpisode() {
        let current = reviewNight(id: "morning-sleep")
        let laterStart = try! XCTUnwrap(current.end).addingTimeInterval(3 * 60 * 60)
        let unrelated = SleepHistorySnapshot.Night(
            id: "afternoon-nap",
            day: current.day,
            start: laterStart,
            end: laterStart.addingTimeInterval(90 * 60),
            duration: 90 * 60,
            restingHR: 55,
            hrv: nil,
            respiratoryRate: nil,
            sleepEfficiency: 1,
            confidence: "review_needed",
            source: "nap_candidate",
            confirmed: false,
            stageSegments: []
        )

        XCTAssertNil(SessionStore.preferredGrowingSleepReview(
            replacing: current,
            with: [unrelated],
            calendar: calendar
        ))
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

    func testPhysiologicalReviewSurfacesResumedSleepAfterAutomaticFirstWakeSave() throws {
        let recordingStart = date(day: 10, hour: 2)
        var points: [SavedSession.Point] = []
        func append(from startMinute: Int, through endMinute: Int, bpm: Int) {
            for minute in startMinute...endMinute {
                points.append(SavedSession.Point(t: TimeInterval(minute * 60), bpm: bpm))
            }
        }
        append(from: 110, through: 394, bpm: 58) // 03:50–08:34 first sleep
        append(from: 410, through: 578, bpm: 59) // brief wake, then sleep to 11:38
        let session = SavedSession(id: UUID(),
                                   start: recordingStart,
                                   end: recordingStart.addingTimeInterval(579 * 60),
                                   label: "Resumed sleep",
                                   points: points)
        let firstWake = automaticSleep(start: recordingStart.addingTimeInterval(110 * 60),
                                       end: recordingStart.addingTimeInterval(394 * 60))

        let result = try XCTUnwrap(SessionStore.physiologicalSleepReviewNight(
            in: [session],
            confirmedSleeps: [firstWake],
            rest: 60,
            calendar: calendar
        ))

        XCTAssertEqual(result.source, "sleep_episode_review")
        XCTAssertEqual(result.start, firstWake.start)
        XCTAssertGreaterThanOrEqual(result.end ?? .distantPast,
                                    firstWake.end.addingTimeInterval(2.5 * 60 * 60))
        XCTAssertFalse(result.confirmed)
    }

    func testPhysiologicalReviewDoesNotReplaceUserAuthoredFirstSleep() {
        let session = sleepSession(day: 10, startHour: 2, durationHours: 9, bpm: 55)
        let manual = confirmedSleep(overlapping: session)

        XCTAssertNil(SessionStore.physiologicalSleepReviewNight(
            in: [session],
            confirmedSleeps: [manual],
            rest: 60,
            calendar: calendar
        ))
    }

    func testPhysiologicalHRFallbackDoesNotSurfaceDaytimeFalseNap() {
        let start = date(day: 10, hour: 14)
        let duration: TimeInterval = 60 * 60
        // Mirrors the physical false-positive shape: abundant low-HR samples
        // with a brief active-wear excursion, but no motion/stillness proof.
        var points = stride(from: 0.0, to: duration, by: 60.0).map {
            SavedSession.Point(t: $0, bpm: 62)
        }
        points[points.count / 2] = SavedSession.Point(t: duration / 2, bpm: 105)
        let activeWear = SavedSession(id: UUID(),
                                      start: start,
                                      end: start.addingTimeInterval(duration),
                                      label: "Active daytime wear",
                                      points: points)

        XCTAssertNil(SessionStore.physiologicalSleepReviewNight(
            in: [activeWear],
            rest: 62,
            calendar: calendar
        ))
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

    @MainActor
    func testUnchangedDetectedSleepSavePersistsWithoutFinishedSessionAndProjectsToActivity() async throws {
        let store = SessionStore()
        let fixtureStart = calendar.date(from: DateComponents(year: 2034,
                                                              month: 7,
                                                              day: 14,
                                                              hour: 3,
                                                              minute: 50))!
        let fixtureEnd = calendar.date(from: DateComponents(year: 2034,
                                                            month: 7,
                                                            day: 14,
                                                            hour: 11,
                                                            minute: 38))!
        // This test exercises persistence without SavedSession coverage. Give
        // it a boundary that cannot alias another durable suite fixture;
        // canonical sleep IDs are window-derived, not review-marker-derived.
        // The adjacent idempotency test runs in parallel and also leases a
        // window after the latest durable wake, so each test needs a distinct
        // offset even when both read the same initial ledger generation.
        let start = max(
            fixtureStart,
            store.confirmedSleeps.map(\.end).max()?.addingTimeInterval(7 * 24 * 60 * 60)
                ?? .distantPast
        )
        let end = start.addingTimeInterval(fixtureEnd.timeIntervalSince(fixtureStart))
        let marker = "atomic-review-\(UUID().uuidString)"
        let review = SleepHistorySnapshot.Night(
            id: marker,
            day: calendar.startOfDay(for: end),
            start: start,
            end: end,
            duration: 7 * 3_600 + 38 * 60,
            restingHR: 51,
            hrv: 68,
            hrvWindowCount: 4,
            respiratoryRate: nil,
            sleepEfficiency: 0.98,
            confidence: "review_needed",
            source: "sleep_episode_review",
            confirmed: false,
            stageSegments: [],
            eventTimeZoneIdentifier: "UTC"
        )

        let savedResult = await store.saveSleepReviewNightForUI(
            review,
            start: start,
            end: end,
            isNap: false,
            rest: 55,
            source: marker
        )
        let saved = try XCTUnwrap(savedResult)
        addTeardownBlock { @MainActor in
            _ = await store.deleteConfirmedSleep(id: saved.id)
        }

        XCTAssertEqual(saved.start, start)
        XCTAssertEqual(saved.end, end)
        XCTAssertEqual(saved.hrv, 68,
                       "confirming must retain exact-window review HRV instead of changing recovery provenance")
        XCTAssertEqual(saved.restingHR, review.restingHR,
                       "confirmation must retain the resting-HR input shown before Save")
        let beforeRecovery = Metrics.recoveryV2(
            hrvSnapshot: nil,
            fallbackRMSSD: review.hrv,
            restingNow: review.restingHR,
            baseline: store.baseline,
            hrvReferenceValidated: false,
            sleepEfficiency: review.sleepEfficiency,
            sleepDurationHours: review.durationHours,
            respiratoryRate: review.respiratoryRate,
            respiratoryBaseline: nil
        )
        let projected = try XCTUnwrap(store.sleepHistorySnapshot.nights.first { $0.id == saved.id })
        let afterRecovery = Metrics.recoveryV2(
            hrvSnapshot: nil,
            fallbackRMSSD: projected.hrv,
            restingNow: projected.restingHR,
            baseline: store.baseline,
            hrvReferenceValidated: false,
            sleepEfficiency: projected.sleepEfficiency,
            sleepDurationHours: projected.durationHours,
            respiratoryRate: projected.respiratoryRate,
            respiratoryBaseline: nil
        )
        XCTAssertEqual(afterRecovery.percent, beforeRecovery.percent,
                       "Save must not change recovery when the reviewed physiological inputs are unchanged")
        XCTAssertEqual(afterRecovery.confidence, beforeRecovery.confidence)
        XCTAssertTrue(store.confirmedSleeps.contains { $0.id == saved.id })
        XCTAssertTrue((store.sleepHistorySnapshot.nights
            + store.sleepHistorySnapshot.additionalMainNights
            + store.sleepHistorySnapshot.napNights).contains { $0.id == saved.id },
                      "a successful Save must be visible to Activity immediately")

        let activityRows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: store.sleepHistorySnapshot,
            pendingReview: review,
            selectedDay: calendar.startOfDay(for: end),
            calendar: calendar
        )
        XCTAssertEqual(activityRows.map(\.id), [saved.id],
                       "Activity must show the durable sleep on its final-wake day and suppress a stale copy of its settled candidate")
        if !calendar.isDate(start, inSameDayAs: end) {
            let bedtimeDayRows = AtriaActivitySelectedDaySleeps.overlapping(
                snapshot: store.sleepHistorySnapshot,
                pendingReview: review,
                selectedDay: calendar.startOfDay(for: start),
                calendar: calendar
            )
            XCTAssertFalse(bedtimeDayRows.contains { $0.id == saved.id },
                           "confirmed main sleep must not appear on both its bedtime day and final-wake day")
        }
    }

    @MainActor
    func testUnchangedAlreadyConfirmedSleepSaveReturnsCanonicalRecordWithoutSensorCoverage() async throws {
        let store = SessionStore()
        // The durable writer preserves records created by other SessionStore
        // instances. Use a ledger-unique window so this idempotency test cannot
        // accidentally resolve a canonical record from an earlier suite test
        // that used the same historical fixture boundary.
        let start = max(
            calendar.date(from: DateComponents(year: 2035,
                                               month: 2,
                                               day: 3,
                                               hour: 2,
                                               minute: 15))!,
            // Deliberately differs from the seven-day lease used by the
            // unchanged detected-sleep test above. Parallel tests can observe
            // the same maximum before either write becomes durable.
            store.confirmedSleeps.map(\.end).max()?.addingTimeInterval(14 * 24 * 60 * 60)
                ?? .distantPast
        )
        let end = start.addingTimeInterval(7 * 3_600 + 20 * 60)
        let marker = "canonical-idempotent-\(UUID().uuidString)"
        let review = SleepHistorySnapshot.Night(
            id: marker,
            day: calendar.startOfDay(for: end),
            start: start,
            end: end,
            duration: end.timeIntervalSince(start),
            restingHR: 49,
            hrv: 73,
            hrvWindowCount: 5,
            respiratoryRate: nil,
            sleepEfficiency: 0.96,
            confidence: "review_needed",
            source: "sleep_episode_review",
            confirmed: false,
            stageSegments: [],
            eventTimeZoneIdentifier: "UTC"
        )
        let canonicalResult = await store.saveSleepReviewNightForUI(
            review,
            start: start,
            end: end,
            isNap: false,
            rest: 55,
            source: marker
        )
        let canonical = try XCTUnwrap(canonicalResult)
        XCTAssertNotNil(canonical.frozenSleepNeed,
                        "A new main sleep must return its persistence-frozen need receipt")
        addTeardownBlock { @MainActor in
            _ = await store.deleteConfirmedSleep(id: canonical.id)
        }

        let projected = try XCTUnwrap((store.sleepHistorySnapshot.nights
            + store.sleepHistorySnapshot.additionalMainNights
            + store.sleepHistorySnapshot.napNights).first { $0.id == canonical.id })
        XCTAssertTrue(projected.confirmed)
        let before = store.confirmedSleeps

        // There are deliberately no SavedSession samples in this future
        // window. Save must still be an idempotent read of canonical truth.
        let savedAgainResult = await store.saveSleepReviewNightForUI(
            projected,
            start: canonical.start,
            end: canonical.end,
            isNap: projected.isNapEvidence,
            rest: 99,
            source: "must_not_rederive"
        )
        let savedAgain = try XCTUnwrap(savedAgainResult)

        XCTAssertEqual(savedAgain, canonical)
        XCTAssertEqual(store.confirmedSleeps, before)
        XCTAssertEqual(savedAgain.createdAt, canonical.createdAt)
        XCTAssertEqual(savedAgain.reason, canonical.reason)
        XCTAssertEqual(savedAgain.motionSource, canonical.motionSource)
        XCTAssertEqual(savedAgain.hrv, 73)
        XCTAssertEqual(savedAgain.restingHR, 49)
    }

    func testVitalsConfirmBindsTheExactDisplayedReviewCandidate() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaVitalsCollectionSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let cardStart = try XCTUnwrap(source.range(of: "private struct AtriaSleepHistoryCard: View"))
        let cardEnd = try XCTUnwrap(source.range(of: "private struct AtriaSleepContextLens: View",
                                                 range: cardStart.upperBound..<source.endIndex))
        let card = String(source[cardStart.lowerBound..<cardEnd.lowerBound])
        let hostStart = try XCTUnwrap(source.range(of: "private func confirmSleepCandidate("))
        let hostEnd = try XCTUnwrap(source.range(of: "#if DEBUG",
                                                 range: hostStart.upperBound..<source.endIndex))
        let host = String(source[hostStart.lowerBound..<hostEnd.lowerBound])

        XCTAssertTrue(card.contains("let onConfirmSleep: (SleepHistorySnapshot.Night) async -> Bool"),
                      "Vitals must retain the durable confirmation result instead of treating every tap as success")
        XCTAssertTrue(card.contains("guard let latest = snapshot.latestReviewable"))
        XCTAssertTrue(card.contains("latest.confirmed == false"))
        XCTAssertTrue(card.contains("onConfirmSleep(latest)"))
        XCTAssertTrue(host.contains("confirmSleepCandidate(_ night: SleepHistorySnapshot.Night) async -> Bool"))
        XCTAssertTrue(host.contains("confirmSleepHistoryNightForUI("))
        XCTAssertTrue(host.contains("\n            night,"))
        XCTAssertTrue(host.contains(") != nil"),
                      "The Vitals callback must report whether canonical persistence succeeded")
        XCTAssertTrue(card.contains("sleepConfirmationFailed = !(await onConfirmSleep(latest))"))
        XCTAssertTrue(card.contains("The suggestion is still here"),
                      "A failed Vitals save must leave an actionable, visible retry state")
        XCTAssertFalse(host.contains("latestMainSleep"),
                       "Confirm must never replace the displayed candidate with the physiological main sleep")
    }

    func testTodayAndOverviewConfirmKeepRetryFeedbackWhenPersistenceFails() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let hostStart = try XCTUnwrap(source.range(of: "private struct AtriaSleepReviewHost: View"))
        let hostEnd = try XCTUnwrap(source.range(of: "private struct AtriaAutoSleepLoggedBanner: View",
                                                 range: hostStart.upperBound..<source.endIndex))
        let host = String(source[hostStart.lowerBound..<hostEnd.lowerBound])
        XCTAssertTrue(host.contains("store.confirmSleepHistoryNightForUI(night,"))
        XCTAssertTrue(host.contains("source: \"overview_sleep_review\") != nil"),
                      "Today must pass canonical persistence success back to the displayed review card")

        let cardStart = try XCTUnwrap(source.range(of: "private struct AtriaSleepReviewCard: View"))
        let cardEnd = try XCTUnwrap(source.range(of: "struct AtriaTodaySleepReviewSection: View",
                                                 range: cardStart.upperBound..<source.endIndex))
        let card = String(source[cardStart.lowerBound..<cardEnd.lowerBound])
        XCTAssertTrue(card.contains("let onConfirm: () async -> Bool"))
        XCTAssertTrue(card.contains("sleepConfirmationFailed = !(await onConfirm())"))
        XCTAssertTrue(card.contains("The suggestion is still here"),
                      "A failed Today save must remain visible and retryable")
        XCTAssertTrue(card.contains(".onChange(of: night.id)"),
                      "Failure feedback must not leak onto the next candidate")
        XCTAssertTrue(card.contains("night.source == \"resumed_sleep_candidate\""))
        XCTAssertTrue(card.contains("Possible resumed sleep"))
        // 2026-08-25: the copy was shortened because it cropped on device and
        // its "Confirm to …" half only restated the Confirm button beneath it.
        // Both load-bearing facts survive, which is what this assertion is for.
        XCTAssertTrue(card.contains("Links to your earlier sleep"),
                      "a resumed block must say confirmation creates one episode")
        XCTAssertTrue(card.contains("awake time excluded"),
                      "a resumed block must say awake time is not credited")

        let journalHostStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewMorningJournalHost: View"))
        let journalCardEnd = try XCTUnwrap(source.range(of: "private struct AtriaJournalTodayTagStrip: View",
                                                        range: journalHostStart.upperBound..<source.endIndex))
        let journal = String(source[journalHostStart.lowerBound..<journalCardEnd.lowerBound])
        XCTAssertTrue(journal.contains("let onConfirmSleep: () async -> Bool"))
        XCTAssertTrue(journal.contains("source: \"morning_journal\""))
        XCTAssertTrue(journal.contains(") != nil"),
                      "Overview morning journal must retain canonical persistence success")
        XCTAssertTrue(journal.contains("sleepConfirmationFailed = !(await onConfirmSleep())"))
        XCTAssertTrue(journal.contains("The suggestion is still here"),
                      "A failed Overview save must remain visible and retryable")
        XCTAssertTrue(journal.contains(".onChange(of: latestNight?.id)"))
    }

    func testReviewSaveRoutesUnchangedWindowToConfirmationAndEditedWindowToRederivation() {
        let review = reviewNight(id: "routing")
        let start = review.start!
        let end = review.end!

        XCTAssertTrue(SessionStore.sleepReviewSaveIsUnchanged(night: review,
                                                               start: start,
                                                               end: end,
                                                               isNap: review.isNapEvidence))
        XCTAssertFalse(SessionStore.sleepReviewSaveIsUnchanged(night: review,
                                                                start: start.addingTimeInterval(5 * 60),
                                                                end: end,
                                                                isNap: review.isNapEvidence))
        XCTAssertFalse(SessionStore.sleepReviewSaveIsUnchanged(night: review,
                                                                start: start,
                                                                end: end,
                                                                isNap: !review.isNapEvidence))
    }

    func testAggregateSelectionUsesNewestReviewDayAndFailsClosedOnHROnlyStages() {
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
        XCTAssertEqual(result?.source, "sleep_window")
        XCTAssertNotNil(result, "the newest qualified review window must still be selected")
        XCTAssertTrue(result?.stageSegments.isEmpty == true,
                      "HR-only evidence must not publish REM/light/deep stages without validated motion")
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
        XCTAssertFalse(SessionStore.shouldPublishSleepReviewCache(completedGeneration: 12,
                                                                  currentGeneration: 13))
    }

    func testProjectionPublicationRequiresCurrentForegroundAuthority() {
        func admits(
            cancelled: Bool = false,
            completed: Int = 12,
            current: Int = 12,
            pendingMatches: Bool = true,
            authority: Bool = true,
            active: Bool = true,
            restoreBlocked: Bool = false
        ) -> Bool {
            SessionStore.shouldPublishSleepReviewProjection(
                isCancelled: cancelled,
                completedGeneration: completed,
                currentGeneration: current,
                pendingGenerationMatches: pendingMatches,
                hasForegroundAuthority: authority,
                applicationIsActive: active,
                restoreInitializationBlocked: restoreBlocked
            )
        }

        XCTAssertTrue(admits())
        XCTAssertFalse(admits(cancelled: true))
        XCTAssertFalse(admits(completed: 11))
        XCTAssertFalse(admits(pendingMatches: false))
        XCTAssertFalse(admits(authority: false))
        XCTAssertFalse(admits(active: false))
        XCTAssertFalse(admits(restoreBlocked: true))
    }

    func testProjectionAdmissionRequiresActiveAndCoalescesMatchingInput() {
        XCTAssertTrue(SessionStore.shouldEnqueueSleepReviewProjection(
            hasForegroundAuthority: true,
            applicationIsActive: true,
            restoreInitializationBlocked: false,
            cacheMatchesInput: false,
            pendingMatchesInput: false
        ))
        XCTAssertFalse(SessionStore.shouldEnqueueSleepReviewProjection(
            hasForegroundAuthority: true,
            applicationIsActive: false,
            restoreInitializationBlocked: false,
            cacheMatchesInput: false,
            pendingMatchesInput: false
        ))
        XCTAssertFalse(SessionStore.shouldEnqueueSleepReviewProjection(
            hasForegroundAuthority: true,
            applicationIsActive: true,
            restoreInitializationBlocked: false,
            cacheMatchesInput: true,
            pendingMatchesInput: false
        ))
        XCTAssertFalse(SessionStore.shouldEnqueueSleepReviewProjection(
            hasForegroundAuthority: true,
            applicationIsActive: true,
            restoreInitializationBlocked: false,
            cacheMatchesInput: false,
            pendingMatchesInput: true
        ))
        XCTAssertFalse(SessionStore.shouldEnqueueSleepReviewProjection(
            hasForegroundAuthority: false,
            applicationIsActive: true,
            restoreInitializationBlocked: false,
            cacheMatchesInput: false,
            pendingMatchesInput: false
        ))
        XCTAssertFalse(SessionStore.shouldEnqueueSleepReviewProjection(
            hasForegroundAuthority: true,
            applicationIsActive: true,
            restoreInitializationBlocked: true,
            cacheMatchesInput: false,
            pendingMatchesInput: false
        ))
    }

    @MainActor
    func testRetainedRestoreBlockSynchronouslySupersedesReviewPublication() {
        let store = SessionStore()
        let before = store.sleepReviewProjectionStateForTesting

        store.enterRetainedRestoreMarkerBlockForTesting()

        let after = store.sleepReviewProjectionStateForTesting
        XCTAssertTrue(store.restoreInitializationBlocked)
        XCTAssertEqual(after.generation, before.generation &+ 1)
        XCTAssertFalse(after.hasForegroundAuthority)
        XCTAssertTrue(after.isDeferred)
        XCTAssertFalse(after.hasPendingProjection)
        XCTAssertFalse(SessionStore.shouldPublishSleepReviewCache(
            completedGeneration: before.generation,
            currentGeneration: after.generation
        ))
        XCTAssertFalse(SessionStore.shouldEnqueueSleepReviewProjection(
            hasForegroundAuthority: true,
            applicationIsActive: true,
            restoreInitializationBlocked: store.restoreInitializationBlocked,
            cacheMatchesInput: false,
            pendingMatchesInput: false
        ))
        XCTAssertFalse(LocalNotificationScheduler
            .sleepReviewNotificationAdmission(
                restoreInitializationBlocked:
                    store.restoreInitializationBlocked
            ))
        XCTAssertNil(store.persistedPendingSleepReviewForNotification())
    }

    @MainActor
    func testJournalCacheWarmSupersedesColdGenerationAndRetriesOnce() {
        let store = SessionStore()
        let before = store.sleepReviewProjectionStateForTesting
        var scheduled = 0
        let event = ActiveSessionJournal.SleepReviewCacheWarmEvent(
            generation: UInt64.max - 1,
            containsRecord: true
        )

        store.handleActiveJournalSleepReviewCacheWarmForTesting(
            event,
            applicationIsActive: true,
            scheduleRefresh: { scheduled += 1 }
        )
        let afterWarm = store.sleepReviewProjectionStateForTesting
        store.handleActiveJournalSleepReviewCacheWarmForTesting(
            event,
            applicationIsActive: true,
            scheduleRefresh: { scheduled += 1 }
        )
        let afterDuplicate = store.sleepReviewProjectionStateForTesting

        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(afterWarm.generation, before.generation &+ 1)
        XCTAssertEqual(afterDuplicate.generation, afterWarm.generation)
        XCTAssertFalse(SessionStore.shouldPublishSleepReviewCache(
            completedGeneration: before.generation,
            currentGeneration: afterWarm.generation
        ))
    }

    @MainActor
    func testJournalCacheWarmDefersWithoutBackgroundEnqueue() {
        let store = SessionStore()
        store.suspendSleepReviewProjectionForBackground(
            reason: "warm-event-background-test"
        )
        let before = store.sleepReviewProjectionStateForTesting
        var scheduled = 0

        store.handleActiveJournalSleepReviewCacheWarmForTesting(
            .init(generation: UInt64.max - 1, containsRecord: false),
            applicationIsActive: false,
            scheduleRefresh: { scheduled += 1 }
        )

        let after = store.sleepReviewProjectionStateForTesting
        XCTAssertEqual(scheduled, 0)
        XCTAssertEqual(after.generation, before.generation &+ 1)
        XCTAssertFalse(after.hasForegroundAuthority)
        XCTAssertTrue(after.isDeferred)
        XCTAssertFalse(after.hasPendingProjection)
    }

    func testNotificationUnavailableReasonUsesPreparedStateOnly() {
        XCTAssertEqual(
            LocalNotificationScheduler.sleepReviewUnavailableReason(
                snapshotCandidateCount: 0,
                preparedIsLoading: true
            ),
            "sleep_review_projection_deferred"
        )
        XCTAssertEqual(
            LocalNotificationScheduler.sleepReviewUnavailableReason(
                snapshotCandidateCount: 2,
                preparedIsLoading: true
            ),
            "sleep_candidate_not_reviewable"
        )
        XCTAssertEqual(
            LocalNotificationScheduler.sleepReviewUnavailableReason(
                snapshotCandidateCount: 0,
                preparedIsLoading: false
            ),
            "no_unconfirmed_sleep_candidate"
        )
        let snapshotCandidate = reviewNight(id: "withheld-snapshot")
        XCTAssertNil(LocalNotificationScheduler.sleepReviewSnapshotFallback(
            preparedIsLoading: false,
            snapshotNight: snapshotCandidate
        ))
        XCTAssertEqual(
            LocalNotificationScheduler.sleepReviewSnapshotFallback(
                preparedIsLoading: true,
                snapshotNight: snapshotCandidate
            ),
            snapshotCandidate
        )
    }

    func testProjectionCancellationTripsSharedDeadline() throws {
        let cancellation = AtriaSleepReviewProjectionCancellation()
        let deadline = AtriaSleepSettlementDeadline(
            uptimeNanoseconds: 100,
            monotonicNow: { cancellation.isCancelled ? .max : 0 }
        )
        XCTAssertNoThrow(try deadline.checkpoint())
        cancellation.cancel()
        XCTAssertThrowsError(try deadline.checkpoint()) {
            XCTAssertEqual(
                $0 as? AtriaSleepSettlementAbort,
                .deadlineExceeded
            )
        }
    }

    func testBoundedProjectionPropagatesCooperativeCancellation() {
        let cancellation = AtriaSleepReviewProjectionCancellation()
        let clock = StepClock()
        let deadline = AtriaSleepSettlementDeadline(
            uptimeNanoseconds: 100,
            monotonicNow: {
                let step = clock.next()
                if step == 6 {
                    cancellation.cancel()
                }
                return cancellation.isCancelled ? .max : 0
            }
        )
        XCTAssertThrowsError(try SessionStore
            .makeBoundedSleepReviewCacheProjection(
                snapshot: .empty,
                canonicalSessions: [sleepSession(day: 8)],
                confirmedSleeps: [],
                rest: 60,
                maxHR: 190,
                calendar: calendar,
                cooperativeDeadline: deadline
            )) {
            XCTAssertEqual(
                $0 as? AtriaSleepSettlementAbort,
                .deadlineExceeded
            )
        }
    }

    func testBusyResidentJournalLookupDefersInsteadOfPublishingEmpty() throws {
        let deadline = AtriaSleepSettlementDeadline(
            uptimeNanoseconds: .max,
            monotonicNow: { 0 }
        )
        XCTAssertThrowsError(try SessionStore
            .loadCachedResidentJournalSessionForSleepReview(
                now: Date(timeIntervalSince1970: 1_900_000_000),
                cooperativeDeadline: deadline,
                cachedRecord: { .busy }
            )) {
            XCTAssertEqual(
                $0 as? AtriaSleepSettlementAbort,
                .deadlineExceeded
            )
        }
        XCTAssertThrowsError(try SessionStore
            .loadCachedResidentJournalSessionForSleepReview(
                now: Date(timeIntervalSince1970: 1_900_000_000),
                cooperativeDeadline: deadline,
                cachedRecord: { .cold }
            )) {
            XCTAssertEqual(
                $0 as? AtriaSleepSettlementAbort,
                .deadlineExceeded
            )
        }
        XCTAssertNil(try SessionStore
            .loadCachedResidentJournalSessionForSleepReview(
                now: Date(timeIntervalSince1970: 1_900_000_000),
                cooperativeDeadline: deadline,
                cachedRecord: { .knownAbsent }
            ))
    }

    func testBoundedProjectionAbortsHugeRRFixtureDeterministically() {
        var session = sleepSession(day: 8)
        session.rrPoints = (0..<20_000).map {
            SavedSession.RRPoint(
                t: Double($0) * 0.8,
                ms: 800 + ($0 % 7),
                source: .standardHeartRateMeasurement2A37
            )
        }
        let clock = StepClock()
        let deadline = AtriaSleepSettlementDeadline(
            uptimeNanoseconds: 24,
            monotonicNow: { clock.next() }
        )
        XCTAssertThrowsError(try SessionStore
            .makeBoundedSleepReviewCacheProjection(
                snapshot: .empty,
                canonicalSessions: [session],
                confirmedSleeps: [],
                rest: 60,
                maxHR: 190,
                calendar: calendar,
                cooperativeDeadline: deadline
            )) {
            XCTAssertEqual(
                $0 as? AtriaSleepSettlementAbort,
                .deadlineExceeded
            )
        }
    }

    func testBoundedProjectionMatchesNormalMainAndNapFixtures() throws {
        let mainSession = sleepSession(day: 8)
        let napSession = daytimeLowHRSession(
            start: date(day: 10, hour: 14),
            validatedMotion: true
        )
        let sessions = [mainSession, napSession]
        let legacyMain = SessionStore.makeSleepReviewNightForCache(
            snapshot: .empty,
            canonicalSessions: sessions,
            confirmedSleeps: [],
            rest: 60,
            maxHR: 190,
            calendar: calendar
        )
        let legacyNaps = SessionStore.makeNapReviewNightsForCache(
            canonicalSessions: sessions,
            confirmedSleeps: [],
            rest: 60,
            maxHR: 190,
            calendar: calendar
        )
        let bounded = try SessionStore.makeBoundedSleepReviewCacheProjection(
            snapshot: .empty,
            canonicalSessions: sessions,
            confirmedSleeps: [],
            rest: 60,
            maxHR: 190,
            calendar: calendar,
            cooperativeDeadline: .init(
                uptimeNanoseconds: .max,
                monotonicNow: { 0 }
            )
        )

        XCTAssertEqual(bounded.main?.id, legacyMain?.id)
        XCTAssertEqual(bounded.main?.start, legacyMain?.start)
        XCTAssertEqual(bounded.main?.end, legacyMain?.end)
        XCTAssertEqual(bounded.main?.source, legacyMain?.source)
        XCTAssertEqual(bounded.main?.hrv, legacyMain?.hrv)
        XCTAssertEqual(
            bounded.main?.hrvWindowCount,
            legacyMain?.hrvWindowCount
        )
        XCTAssertEqual(
            bounded.main?.respiratoryRate,
            legacyMain?.respiratoryRate
        )
        XCTAssertEqual(
            bounded.main?.stageSegments,
            legacyMain?.stageSegments
        )
        XCTAssertEqual(bounded.naps.map(\.id), legacyNaps.map(\.id))
    }

    func testEightHourDenseReviewPublishesParityStagesWithinSharedDeadline()
        throws
    {
        try assertDenseReviewStages(hours: 8)
    }

    func testTwelveHourDenseReviewPublishesParityStagesWithinSharedDeadline()
        throws
    {
        try assertDenseReviewStages(hours: 12)
    }

    private func assertDenseReviewStages(
        hours: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let start = date(day: 8, hour: 20)
        let duration = TimeInterval(hours * 60 * 60)
        var session = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(duration),
            label: "Dense \(hours)-hour sleep review",
            points: (0...Int(duration)).map {
                // Deliberately enter the physiological HR-only branch while
                // motion also produces an aggregate candidate. Selection must
                // finish before the single winning recipe invokes staging.
                .init(t: Double($0), bpm: 58 + (($0 / 300) % 3))
            }
        )
        session.recoveredMotionEpochs = stride(
            from: 0.0,
            to: duration,
            by: 30.0
        ).map { offset in
            let epochStart = start.addingTimeInterval(offset)
            return AtriaRecoveredMotionEpoch(
                start: epochStart,
                end: min(
                    session.end,
                    epochStart.addingTimeInterval(30)
                ),
                rows: 6,
                validatedRows: 6,
                stillnessRatio: 0.94,
                movementIntensity: 0.02,
                p95VectorDelta: 0.03,
                maximumGapSeconds: 5,
                measurementValidated: true,
                lowMotionQualified: true,
                reason: "dense_review_stage_fixture"
            )
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = startedAt
            + UInt64(SessionStore.sleepReviewProjectionDeadlineSeconds
                * 1_000_000_000)
        let cancellation = AtriaSleepReviewProjectionCancellation()
        let sharedDeadline = AtriaSleepSettlementDeadline(
            uptimeNanoseconds: deadline,
            monotonicNow: {
                cancellation.isCancelled
                    ? .max
                    : DispatchTime.now().uptimeNanoseconds
            }
        )
        let reviewSlice = try SessionStore.compactLatestNightSessionSlice(
            from: [session],
            now: session.end,
            deadlineUptimeNanoseconds: deadline,
            cooperativeDeadline: sharedDeadline,
            preserveAttachedMotion: true
        ).get()
        let stageInvocations = AtriaSleepReviewStageInvocationCounter()
        let result = try SessionStore.makeBoundedSleepReviewCacheProjection(
            snapshot: .empty,
            canonicalSessions: reviewSlice.sessions,
            confirmedSleeps: [],
            rest: 60,
            maxHR: 190,
            calendar: calendar,
            cooperativeDeadline: sharedDeadline,
            mainStageInvocationCounter: stageInvocations
        )
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000_000
        print("ATRIA_DENSE_REVIEW_SECONDS hours=\(hours) elapsed=\(elapsed)")
        let main = try XCTUnwrap(result.main)
        let mainStart = try XCTUnwrap(main.start)
        let mainEnd = try XCTUnwrap(main.end)
        let restingHR = try XCTUnwrap(main.restingHR)
        XCTAssertEqual(
            stageInvocations.physiologicalDraftCount,
            1,
            "the low-HR review must exercise the physiological draft",
            file: file,
            line: line
        )
        XCTAssertEqual(
            stageInvocations.value,
            1,
            "physiological/aggregate overlap must stage only the selected draft",
            file: file,
            line: line
        )
        XCTAssertEqual(
            main.source,
            "sleep_window",
            "validated motion must also produce and select the aggregate draft",
            file: file,
            line: line
        )
        let legacy = AtriaSleepWakeResearch.stageSegments(
            samples: session.points.map {
                .init(
                    t: session.start.addingTimeInterval(max(0, $0.t)),
                    bpm: $0.bpm
                )
            },
            start: mainStart,
            end: mainEnd,
            restingHR: restingHR,
            isNap: false,
            motionValidated: true,
            motionEpochs: session.recoveredMotionEpochs ?? []
        )
        XCTAssertFalse(main.stageSegments.isEmpty, file: file, line: line)
        XCTAssertEqual(main.stageSegments, legacy, file: file, line: line)
        XCTAssertTrue(AtriaSleepStageIntegrity.validates(
            main.stageSegments,
            start: mainStart,
            end: mainEnd,
            duration: main.duration,
            span: mainEnd.timeIntervalSince(mainStart)
        ), file: file, line: line)
        XCTAssertGreaterThan(
            session.points.count,
            SessionStore.compactLatestNightMaximumStagingRows,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            session.points.count,
            SessionStore.sleepReviewMaximumStagingRows,
            file: file,
            line: line
        )
        XCTAssertLessThan(
            elapsed,
            SessionStore.sleepReviewProjectionDeadlineSeconds,
            file: file,
            line: line
        )
    }

    func testRelevantAuthorityOverflowFailsClosedBeforeRepeatedScans() {
        let session = sleepSession(day: 8)
        let confirmed = (0...SessionStore
            .sleepReviewMaximumRelevantAuthorityRows).map { index in
            UserConfirmedSleep(
                id: "overlap-\(index)",
                createdAt: session.end,
                start: session.start,
                end: session.end,
                source: "auto_confirmed_sleep",
                confidence: "high",
                sessions: 1,
                samples: session.points.count,
                avgHR: session.avg,
                peakHR: session.peak,
                restingHR: session.restingStable,
                hrv: nil,
                hrvWindowCount: 0,
                respiratoryRate: nil,
                duration: session.duration,
                span: session.duration,
                reason: "test",
                motionSource: "strap",
                motionValidated: true,
                stageSegments: nil
            )
        }
        XCTAssertThrowsError(try SessionStore
            .makeBoundedSleepReviewCacheProjection(
                snapshot: .empty,
                canonicalSessions: [session],
                confirmedSleeps: confirmed,
                rest: 60,
                maxHR: 190,
                calendar: calendar,
                cooperativeDeadline: .init(
                    uptimeNanoseconds: .max,
                    monotonicNow: { 0 }
                )
            )) {
            XCTAssertEqual(
                $0 as? AtriaSleepSettlementAbort,
                .deadlineExceeded
            )
        }
    }

    @MainActor
    func testColdCacheNotificationReadsDurablePendingReceiptWithoutProjection()
        throws
    {
        let suiteName = "AtriaSleepReviewCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let night = reviewNight(id: "cold-notification-receipt")
        let now = try XCTUnwrap(night.end).addingTimeInterval(60)
        AtriaPendingSleepReviewStore.save(
            night,
            now: now,
            defaults: defaults
        )

        let store = SessionStore()
        let restored = store.persistedPendingSleepReviewForNotification(
            now: now,
            defaults: defaults
        )

        XCTAssertEqual(restored, night)
    }

    func testInputRevisionKeyMakesEverySleepEvidenceMutationStale() {
        let current = SessionStore.SleepReviewCacheInputKey(
            canonicalSessionsRevision: 4,
            confirmedSleepsRevision: 2,
            sleepHistorySnapshotRevision: 8,
            activeJournalID: nil,
            activeJournalEndFiveMinuteBucket: nil,
            restingHR: 60,
            maxHR: 190,
            calendarIdentifier: "gregorian",
            timeZoneIdentifier: "GMT",
            secondsFromGMT: 0
        )

        XCTAssertNotEqual(current, SessionStore.SleepReviewCacheInputKey(
            canonicalSessionsRevision: 5,
            confirmedSleepsRevision: 2,
            sleepHistorySnapshotRevision: 8,
            activeJournalID: nil,
            activeJournalEndFiveMinuteBucket: nil,
            restingHR: 60,
            maxHR: 190,
            calendarIdentifier: "gregorian",
            timeZoneIdentifier: "GMT",
            secondsFromGMT: 0
        ))
        XCTAssertNotEqual(current, SessionStore.SleepReviewCacheInputKey(
            canonicalSessionsRevision: 4,
            confirmedSleepsRevision: 3,
            sleepHistorySnapshotRevision: 8,
            activeJournalID: nil,
            activeJournalEndFiveMinuteBucket: nil,
            restingHR: 60,
            maxHR: 190,
            calendarIdentifier: "gregorian",
            timeZoneIdentifier: "GMT",
            secondsFromGMT: 0
        ))
        XCTAssertNotEqual(current, SessionStore.SleepReviewCacheInputKey(
            canonicalSessionsRevision: 4,
            confirmedSleepsRevision: 2,
            sleepHistorySnapshotRevision: 9,
            activeJournalID: nil,
            activeJournalEndFiveMinuteBucket: nil,
            restingHR: 60,
            maxHR: 190,
            calendarIdentifier: "gregorian",
            timeZoneIdentifier: "GMT",
            secondsFromGMT: 0
        ))
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

    func testJournalOnlyAdvanceInvalidatesSleepReviewInput() {
        let journalID = UUID()
        let before = SessionStore.SleepReviewCacheInputKey(
            canonicalSessionsRevision: 4,
            confirmedSleepsRevision: 2,
            sleepHistorySnapshotRevision: 8,
            activeJournalID: journalID,
            activeJournalEndFiveMinuteBucket: 100,
            restingHR: 60,
            maxHR: 190,
            calendarIdentifier: "gregorian",
            timeZoneIdentifier: "GMT",
            secondsFromGMT: 0
        )
        let after = SessionStore.SleepReviewCacheInputKey(
            canonicalSessionsRevision: 4,
            confirmedSleepsRevision: 2,
            sleepHistorySnapshotRevision: 8,
            activeJournalID: journalID,
            activeJournalEndFiveMinuteBucket: 101,
            restingHR: 60,
            maxHR: 190,
            calendarIdentifier: "gregorian",
            timeZoneIdentifier: "GMT",
            secondsFromGMT: 0
        )

        XCTAssertNotEqual(before, after)
    }

    func testPersistedJournalIdentityUsesBoundedFiveMinuteCadence() {
        let journalID = UUID()
        let first = ActiveSessionJournal.SleepReviewCacheIdentity(
            id: journalID,
            latestHRSampleAt: Date(timeIntervalSince1970: 30_001),
            persistedHRSampleCount: 100,
            latestRRSampleAt: nil,
            persistedRRSampleCount: 0
        )
        let sameBucket = ActiveSessionJournal.SleepReviewCacheIdentity(
            id: journalID,
            latestHRSampleAt: Date(timeIntervalSince1970: 30_299),
            persistedHRSampleCount: 120,
            latestRRSampleAt: nil,
            persistedRRSampleCount: 0
        )
        let nextBucket = ActiveSessionJournal.SleepReviewCacheIdentity(
            id: journalID,
            latestHRSampleAt: Date(timeIntervalSince1970: 30_300),
            persistedHRSampleCount: 121,
            latestRRSampleAt: nil,
            persistedRRSampleCount: 0
        )

        XCTAssertEqual(first, sameBucket,
                       "one-minute journal checkpoints must not rebuild the sleep projection")
        XCTAssertNotEqual(first, nextBucket,
                          "journal-only evidence must invalidate a previously empty/old result")
    }

    func testUnchangedCheckpointDoesNotAdvanceJournalSleepReviewIdentity() {
        let journalID = UUID()
        let latestHR = Date(timeIntervalSince1970: 30_100)
        let latestRR = Date(timeIntervalSince1970: 30_102)
        let before = ActiveSessionJournal.SleepReviewCacheIdentity(
            id: journalID,
            latestHRSampleAt: latestHR,
            persistedHRSampleCount: 200,
            latestRRSampleAt: latestRR,
            persistedRRSampleCount: 80
        )
        // A forced lifecycle checkpoint can occur much later, but because no
        // evidence clock/count changed it must publish the identical key.
        let afterMetadataOnlyCheckpoint = ActiveSessionJournal.SleepReviewCacheIdentity(
            id: journalID,
            latestHRSampleAt: latestHR,
            persistedHRSampleCount: 200,
            latestRRSampleAt: latestRR,
            persistedRRSampleCount: 80
        )

        XCTAssertEqual(before, afterMetadataOnlyCheckpoint)
    }

    func testNewPersistedRREvidenceAdvancesJournalIdentityAtFiveMinuteBoundary() {
        let journalID = UUID()
        let latestHR = Date(timeIntervalSince1970: 30_100)
        let before = ActiveSessionJournal.SleepReviewCacheIdentity(
            id: journalID,
            latestHRSampleAt: latestHR,
            persistedHRSampleCount: 200,
            latestRRSampleAt: Date(timeIntervalSince1970: 30_110),
            persistedRRSampleCount: 80
        )
        let after = ActiveSessionJournal.SleepReviewCacheIdentity(
            id: journalID,
            latestHRSampleAt: latestHR,
            persistedHRSampleCount: 200,
            latestRRSampleAt: Date(timeIntervalSince1970: 30_301),
            persistedRRSampleCount: 81
        )

        XCTAssertNotEqual(before, after)
    }

    func testEvidenceClockRequiresPersistedEvidenceCount() {
        let empty = ActiveSessionJournal.SleepReviewCacheIdentity(
            id: UUID(),
            latestHRSampleAt: Date(timeIntervalSince1970: 30_301),
            persistedHRSampleCount: 0,
            latestRRSampleAt: Date(timeIntervalSince1970: 30_302),
            persistedRRSampleCount: 0
        )
        XCTAssertNil(empty.endFiveMinuteBucket)
    }

    func testJournalPublisherUsesPersistedEvidenceInsteadOfCheckpointWallClock() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of:
            "ActiveSessionJournal.publishSleepReviewCacheIdentity("))
        let end = try XCTUnwrap(source.range(of: ")",
                                             range: start.upperBound..<source.endIndex))
        let call = source[start.lowerBound...end.lowerBound]

        XCTAssertTrue(call.contains("latestHRSampleAt: finalSample.t"))
        XCTAssertTrue(call.contains("persistedHRSampleCount: saveResult.sampleCount"))
        XCTAssertTrue(call.contains("latestRRSampleAt: latestPersistedRREvidenceAt"))
        XCTAssertTrue(call.contains("persistedRRSampleCount: saveResult.rrSampleCount"))
        XCTAssertFalse(call.contains("record.updatedAt"))
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

    func testSleepReviewJournalProjectionRunsBeforeMainActorPublication() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func scheduleSleepReviewCacheRefresh"))
        let end = try XCTUnwrap(source.range(of: "nonisolated static func makeSleepReviewNightForCache",
                                             range: start.lowerBound..<source.endIndex))
        let implementation = String(source[start.lowerBound..<end.lowerBound])
        let worker = try XCTUnwrap(implementation.range(of: "let workItem = DispatchWorkItem"))
        let journalLoad = try XCTUnwrap(implementation.range(of:
            "loadCachedResidentJournalSessionForSleepReview"))
        let mainPublication = try XCTUnwrap(implementation.range(of: "DispatchQueue.main.async"))

        XCTAssertLessThan(worker.lowerBound, journalLoad.lowerBound)
        XCTAssertLessThan(journalLoad.lowerBound, mainPublication.lowerBound)
        XCTAssertFalse(implementation[..<worker.lowerBound].contains("ActiveSessionJournal.load"))
        XCTAssertFalse(implementation[..<worker.lowerBound].contains("activeJournalSessionIfFresh"))
        XCTAssertFalse(implementation[mainPublication.lowerBound...].contains("ActiveSessionJournal.load"))
        XCTAssertFalse(implementation[mainPublication.lowerBound...].contains("activeJournalSessionIfFresh"))
        XCTAssertTrue(implementation.contains("shouldEnqueueSleepReviewProjection"))
        XCTAssertTrue(implementation.contains("cooperativeDeadline"))
        XCTAssertTrue(implementation.contains("compactLatestNightSessionSlice"))
        XCTAssertFalse(implementation.contains("stale_\\(reason)"))
        XCTAssertTrue(implementation.contains("sleepReviewProjectionQueue.async(execute: workItem)"),
                      "Sleep review must not be starved behind unrelated global utility work")
        XCTAssertFalse(source.contains("private static let sleepReviewProjectionQueue"),
                       "An inactive store must not head-of-line block the active store's sleep review")
    }

    func testBackgroundAndNotificationEntryPointsAreReadOnlyOrDeferred() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourceRoot = testsDirectory.deletingLastPathComponent()
        let sessions = try String(contentsOf: sourceRoot
            .appendingPathComponent("Atria/Sessions.swift"), encoding: .utf8)
        let app = try String(contentsOf: sourceRoot
            .appendingPathComponent("Atria/AtriaApp.swift"), encoding: .utf8)
        let notifications = try String(contentsOf: sourceRoot
            .appendingPathComponent("Atria/LocalNotificationScheduler.swift"),
            encoding: .utf8)
        let journal = try String(contentsOf: sourceRoot
            .appendingPathComponent("Atria/ActiveSessionJournal.swift"),
            encoding: .utf8)

        XCTAssertTrue(sessions.contains(
            "sleepReviewRefreshDeferredUntilForeground = true"
        ))
        XCTAssertTrue(sessions.contains(
            "pendingSleepReviewProjectionCancellation?.cancel()"
        ))
        let revokeStart = try XCTUnwrap(sessions.range(of:
            "private func revokeSleepReviewProjection"))
        let revokeEnd = try XCTUnwrap(sessions.range(of:
            "func suspendSleepReviewProjectionForBackground",
            range: revokeStart.upperBound..<sessions.endIndex))
        let revoke = sessions[revokeStart.lowerBound..<revokeEnd.lowerBound]
        let authorityRevocation = try XCTUnwrap(revoke.range(of:
            "sleepReviewProjectionForegroundAuthority = false"))
        let pendingGuard = try XCTUnwrap(revoke.range(of:
            "guard hadPendingProjection || forceGenerationSupersession else"))
        XCTAssertLessThan(authorityRevocation.lowerBound, pendingGuard.lowerBound)
        XCTAssertTrue(sessions.contains(
            "hasForegroundAuthority:\n                sleepReviewProjectionForegroundAuthority"
        ))
        XCTAssertTrue(sessions.contains(
            "sleepReviewRefreshDeferredUntilForeground = true"
        ))
        XCTAssertTrue(app.contains(
            "suspendSleepReviewProjectionForBackground("
        ))
        XCTAssertTrue(app.contains(
            "resumeDeferredSleepReviewProjectionIfNeeded("
        ))
        XCTAssertTrue(notifications.contains(
            "store.preparedSleepReviewResolution("
        ))
        XCTAssertTrue(notifications.contains(
            ".persistedPendingSleepReviewForNotification("
        ))
        XCTAssertFalse(notifications.contains(
            "store.sleepReviewResolutionForUI(rest: rest"
        ))
        XCTAssertFalse(notifications.contains("for attempt in 0..<250"))
        XCTAssertTrue(notifications.contains("guard !Task.isCancelled"))
        let notificationDecisionStart = try XCTUnwrap(notifications.range(of:
            "private static func makeSleepReviewDecision"))
        let notificationDecisionEnd = try XCTUnwrap(notifications.range(of:
            "private static func makeWorkoutReviewDecision",
            range: notificationDecisionStart.upperBound..<notifications.endIndex))
        let notificationDecision = notifications[
            notificationDecisionStart.lowerBound..<notificationDecisionEnd.lowerBound
        ]
        XCTAssertFalse(notificationDecision.contains("sleepEvidenceStatusFast"))
        XCTAssertFalse(notificationDecision.contains("aggregateSleepCandidates"))
        XCTAssertFalse(notificationDecision.contains("HistoricalArchive"))
        let boundedStart = try XCTUnwrap(sessions.range(of:
            "nonisolated static func makeBoundedSleepReviewCacheProjection"))
        let boundedEnd = try XCTUnwrap(sessions.range(of:
            "nonisolated static func makeSleepReviewNightForCache",
            range: boundedStart.upperBound..<sessions.endIndex))
        let bounded = sessions[boundedStart.lowerBound..<boundedEnd.lowerBound]
        XCTAssertTrue(bounded.contains(
            "historicalMotionPolicy: .attachedCompactOnly"
        ))
        XCTAssertFalse(bounded.contains(
            "historicalMotionPolicy: .sessionOnly"
        ))
        let cacheStart = try XCTUnwrap(journal.range(of:
            "static func cachedRecordForSleepReview()"))
        let cacheEnd = try XCTUnwrap(journal.range(of:
            "private static func loadLocked()",
            range: cacheStart.upperBound..<journal.endIndex))
        let cacheRead = journal[cacheStart.lowerBound..<cacheEnd.lowerBound]
        XCTAssertTrue(cacheRead.contains("guard ioLock.try() else"))
        XCTAssertFalse(cacheRead.contains("ioLock.lock()"))
        XCTAssertTrue(cacheRead.contains("return .busy"))
        XCTAssertTrue(cacheRead.contains("? .knownAbsent : .cold"))
        let journalLoadStart = try XCTUnwrap(journal.range(of:
            "static func load() -> ActiveSessionJournalRecord?"))
        let journalLoadEnd = try XCTUnwrap(journal.range(of:
            "enum CachedSleepReviewRecord",
            range: journalLoadStart.upperBound..<journal.endIndex))
        let journalLoad = journal[journalLoadStart.lowerBound..<journalLoadEnd.lowerBound]
        let journalUnlock = try XCTUnwrap(journalLoad.range(of: "ioLock.unlock()"))
        let warmPost = try XCTUnwrap(journalLoad.range(of:
            "didWarmSleepReviewCacheNotification"))
        XCTAssertLessThan(journalUnlock.lowerBound, warmPost.lowerBound)
        let warmObserverStart = try XCTUnwrap(sessions.range(of:
            "self.activeJournalSleepReviewCacheWarmObserver ="))
        let warmObserverEnd = try XCTUnwrap(sessions.range(of:
            "let documentsDirectory =",
            range: warmObserverStart.upperBound..<sessions.endIndex))
        let warmObserver = sessions[
            warmObserverStart.lowerBound..<warmObserverEnd.lowerBound
        ]
        XCTAssertTrue(warmObserver.contains("queue: nil"),
                      "A journal load must not synchronously wait for MainActor notification delivery")
        XCTAssertFalse(warmObserver.contains("queue: .main"))
        XCTAssertTrue(warmObserver.contains("Task { @MainActor in"),
                      "SessionStore mutation must still hop to MainActor")
        let restoreBlockStart = try XCTUnwrap(sessions.range(of:
            "private func enterRetainedRestoreMarkerBlock()"))
        let restoreBlockEnd = try XCTUnwrap(sessions.range(of:
            "private func restoreSessionBackup",
            range: restoreBlockStart.upperBound..<sessions.endIndex))
        let restoreBlock = sessions[
            restoreBlockStart.lowerBound..<restoreBlockEnd.lowerBound
        ]
        let restoreRevoke = try XCTUnwrap(restoreBlock.range(of:
            "revokeSleepReviewProjection("))
        let setBlocked = try XCTUnwrap(restoreBlock.range(of:
            "restoreInitializationBlocked = true"))
        XCTAssertLessThan(restoreRevoke.lowerBound, setBlocked.lowerBound)
        XCTAssertGreaterThanOrEqual(
            journal.components(separatedBy:
                "sleepReviewCacheKnownAbsent = false").count - 1,
            3,
            "initial cold state and both durable write paths must revoke a prior known-absent result"
        )
    }
}
