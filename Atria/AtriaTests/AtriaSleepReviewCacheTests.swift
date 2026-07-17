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
        XCTAssertTrue(observer.contains("scheduleConfirmedWorkoutArchiveRehydration"))
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
    func testUnchangedDetectedSleepSavePersistsWithoutFinishedSessionAndProjectsToActivity() throws {
        let store = SessionStore()
        let start = calendar.date(from: DateComponents(year: 2034,
                                                       month: 7,
                                                       day: 14,
                                                       hour: 3,
                                                       minute: 50))!
        let end = calendar.date(from: DateComponents(year: 2034,
                                                     month: 7,
                                                     day: 14,
                                                     hour: 11,
                                                     minute: 38))!
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

        let saved = try XCTUnwrap(store.saveSleepReviewNightForUI(
            review,
            start: start,
            end: end,
            isNap: false,
            rest: 55,
            source: marker
        ))
        defer { _ = store.deleteConfirmedSleep(id: saved.id) }

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
            selectedDay: calendar.startOfDay(for: start),
            calendar: calendar
        )
        XCTAssertEqual(activityRows.map(\.id), [saved.id],
                       "Activity must show the durable sleep and suppress a stale copy of its settled candidate")
    }

    @MainActor
    func testUnchangedAlreadyConfirmedSleepSaveReturnsCanonicalRecordWithoutSensorCoverage() throws {
        let store = SessionStore()
        let start = calendar.date(from: DateComponents(year: 2035,
                                                       month: 2,
                                                       day: 3,
                                                       hour: 2,
                                                       minute: 15))!
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
        let canonical = try XCTUnwrap(store.saveSleepReviewNightForUI(
            review,
            start: start,
            end: end,
            isNap: false,
            rest: 55,
            source: marker
        ))
        defer { _ = store.deleteConfirmedSleep(id: canonical.id) }

        let projected = try XCTUnwrap((store.sleepHistorySnapshot.nights
            + store.sleepHistorySnapshot.additionalMainNights
            + store.sleepHistorySnapshot.napNights).first { $0.id == canonical.id })
        XCTAssertTrue(projected.confirmed)
        let before = store.confirmedSleeps

        // There are deliberately no SavedSession samples in this future
        // window. Save must still be an idempotent read of canonical truth.
        let savedAgain = try XCTUnwrap(store.saveSleepReviewNightForUI(
            projected,
            start: canonical.start,
            end: canonical.end,
            isNap: projected.isNapEvidence,
            rest: 99,
            source: "must_not_rederive"
        ))

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

        XCTAssertTrue(card.contains("let onConfirmSleep: (SleepHistorySnapshot.Night) -> Bool"),
                      "Vitals must retain the durable confirmation result instead of treating every tap as success")
        XCTAssertTrue(card.contains("guard let latest = snapshot.latestReviewable"))
        XCTAssertTrue(card.contains("latest.confirmed == false"))
        XCTAssertTrue(card.contains("onConfirmSleep(latest)"))
        XCTAssertTrue(host.contains("confirmSleepCandidate(_ night: SleepHistorySnapshot.Night) -> Bool"))
        XCTAssertTrue(host.contains("confirmSleepHistoryNightForUI(night"))
        XCTAssertTrue(host.contains(") != nil"),
                      "The Vitals callback must report whether canonical persistence succeeded")
        XCTAssertTrue(card.contains("sleepConfirmationFailed = !onConfirmSleep(latest)"))
        XCTAssertTrue(card.contains("The suggestion is still here"),
                      "A failed Vitals save must leave an actionable, visible retry state")
        XCTAssertFalse(host.contains("latestMainSleep"),
                       "Confirm must never replace the displayed candidate with the physiological main sleep")
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
        XCTAssertEqual(result?.source, "sleep_window")
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
        XCTAssertFalse(SessionStore.shouldPublishSleepReviewCache(completedGeneration: 12,
                                                                  currentGeneration: 13))
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
        let journalLoad = try XCTUnwrap(implementation.range(of: "SessionStore.loadActiveJournalSessionIfFresh"))
        let mainPublication = try XCTUnwrap(implementation.range(of: "DispatchQueue.main.async"))

        XCTAssertLessThan(worker.lowerBound, journalLoad.lowerBound)
        XCTAssertLessThan(journalLoad.lowerBound, mainPublication.lowerBound)
        XCTAssertFalse(implementation[..<worker.lowerBound].contains("ActiveSessionJournal.load"))
        XCTAssertFalse(implementation[..<worker.lowerBound].contains("activeJournalSessionIfFresh"))
        XCTAssertFalse(implementation[mainPublication.lowerBound...].contains("ActiveSessionJournal.load"))
        XCTAssertFalse(implementation[mainPublication.lowerBound...].contains("activeJournalSessionIfFresh"))
        XCTAssertTrue(implementation.contains("Self.sleepReviewProjectionQueue.async(execute: workItem)"),
                      "Sleep review must not be starved behind unrelated global utility work")
    }
}
