import XCTest
@testable import Atria

final class AtriaWorkoutReviewCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(endingAt end: Date,
                         kind: String? = nil,
                         sleepWakeResearchState: String? = nil) -> SavedSession {
        SavedSession(id: UUID(),
                     start: end.addingTimeInterval(-15 * 60),
                     end: end,
                     label: "Workout review cache test",
                     points: [SavedSession.Point(t: 0, bpm: 120),
                              SavedSession.Point(t: 15 * 60, bpm: 130)],
                     sleepWakeResearchState: sleepWakeResearchState,
                     kind: kind)
    }

    private func candidate(endingAt end: Date) -> WorkoutReviewCandidate {
        WorkoutReviewCandidate(id: "candidate",
                               start: end.addingTimeInterval(-20 * 60),
                               end: end,
                               kind: .workout,
                               confidence: .medium,
                               duration: 20 * 60,
                               avgHR: 125,
                               peakHR: 140,
                               streamCoveragePercent: 100,
                               observedDuration: 20 * 60,
                               droppedGapSeconds: 0,
                               maxSampleGap: 1,
                               gapCount: 0,
                               reason: "ready")
    }

    func testHorizonFilterRunsBeforePointHeavyCandidatePreparation() {
        let expired = session(endingAt: now.addingTimeInterval(-(24 * 60 * 60) - 1))
        let boundary = session(endingAt: now.addingTimeInterval(-24 * 60 * 60))
        let recent = session(endingAt: now.addingTimeInterval(-60 * 60))

        let filtered = SessionStore.workoutReviewSessionsWithinHorizon([expired, boundary, recent],
                                                                       now: now)

        XCTAssertEqual(Set(filtered.map(\.id)), Set([boundary.id, recent.id]))
    }

    func testWorkoutReviewBoundaryExcludesExplicitSleepAndBreathwork() {
        let active = session(endingAt: now.addingTimeInterval(-60))
        let sleep = session(endingAt: now.addingTimeInterval(-120),
                            sleepWakeResearchState: "sleep_research")
        let breathwork = session(endingAt: now.addingTimeInterval(-180), kind: "breathwork")

        let filtered = SessionStore.workoutReviewSessionsWithinHorizon([active, sleep, breathwork],
                                                                       now: now)

        XCTAssertEqual(filtered.map(\.id), [active.id])
        XCTAssertNil(sleep.detectedActivity(rest: 60, maxHR: 190))
        XCTAssertNil(breathwork.detectedActivity(rest: 60, maxHR: 190))
    }

    func testCacheKeyInvalidatesForFinalizedSessionConfirmationAndHRInputChanges() {
        let original = SessionStore.WorkoutReviewCacheKey(sourceSessionsRevision: 4,
                                                          confirmedWorkoutsRevision: 2,
                                                          liveFiveMinuteBucket: 10,
                                                          restingHR: 60,
                                                          maxHR: 190)
        XCTAssertNotEqual(original,
                          SessionStore.WorkoutReviewCacheKey(sourceSessionsRevision: 5,
                                                             confirmedWorkoutsRevision: 2,
                                                             liveFiveMinuteBucket: 10,
                                                             restingHR: 60,
                                                             maxHR: 190))
        XCTAssertNotEqual(original,
                          SessionStore.WorkoutReviewCacheKey(sourceSessionsRevision: 4,
                                                             confirmedWorkoutsRevision: 3,
                                                             liveFiveMinuteBucket: 10,
                                                             restingHR: 60,
                                                             maxHR: 190))
        XCTAssertNotEqual(original,
                          SessionStore.WorkoutReviewCacheKey(sourceSessionsRevision: 4,
                                                             confirmedWorkoutsRevision: 2,
                                                             liveFiveMinuteBucket: 10,
                                                             restingHR: 61,
                                                             maxHR: 190))
        XCTAssertNotEqual(original,
                          SessionStore.WorkoutReviewCacheKey(sourceSessionsRevision: 4,
                                                             confirmedWorkoutsRevision: 2,
                                                             liveFiveMinuteBucket: 11,
                                                             restingHR: 60,
                                                             maxHR: 190))
    }

    func testLiveCheckpointChurnCannotInvalidateWithinBoundedJournalBucket() {
        let bucketStart = Date(timeIntervalSince1970:
            floor(now.timeIntervalSince1970 / 300) * 300)
        let admitted = SessionStore.workoutReviewCacheKey(
            sourceSessionsRevision: 4,
            confirmedWorkoutsRevision: 2,
            now: bucketStart.addingTimeInterval(1),
            restingHR: 60,
            maxHR: 190
        )
        // Hundreds of raw canonical checkpoint revisions are intentionally
        // absent from this key. Until finalized/load authority or the journal
        // bucket advances, the long-running replay is allowed to converge.
        let afterCheckpointChurn = SessionStore.workoutReviewCacheKey(
            sourceSessionsRevision: 4,
            confirmedWorkoutsRevision: 2,
            now: bucketStart.addingTimeInterval(299),
            restingHR: 60,
            maxHR: 190
        )
        let nextJournalBucket = SessionStore.workoutReviewCacheKey(
            sourceSessionsRevision: 4,
            confirmedWorkoutsRevision: 2,
            now: bucketStart.addingTimeInterval(300),
            restingHR: 60,
            maxHR: 190
        )
        let finalizedSource = SessionStore.workoutReviewCacheKey(
            sourceSessionsRevision: 5,
            confirmedWorkoutsRevision: 2,
            now: bucketStart.addingTimeInterval(299),
            restingHR: 60,
            maxHR: 190
        )

        XCTAssertEqual(admitted, afterCheckpointChurn)
        XCTAssertNotEqual(admitted, nextJournalBucket)
        XCTAssertNotEqual(admitted, finalizedSource)
    }

    func testStaleCompletionRetriesOnceThenConvergesOnStableAuthority() {
        let requested = SessionStore.WorkoutReviewCacheKey(
            sourceSessionsRevision: 4,
            confirmedWorkoutsRevision: 2,
            liveFiveMinuteBucket: 10,
            restingHR: 60,
            maxHR: 190
        )
        let newerAuthority = SessionStore.WorkoutReviewCacheKey(
            sourceSessionsRevision: 5,
            confirmedWorkoutsRevision: 2,
            liveFiveMinuteBucket: 10,
            restingHR: 60,
            maxHR: 190
        )

        XCTAssertEqual(
            SessionStore.workoutReviewCacheCompletionAction(
                completedGeneration: 8,
                currentGeneration: 8,
                requestedKey: requested,
                currentKey: newerAuthority
            ),
            .retryLatest
        )
        XCTAssertEqual(
            SessionStore.workoutReviewCacheCompletionAction(
                completedGeneration: 9,
                currentGeneration: 9,
                requestedKey: newerAuthority,
                currentKey: newerAuthority
            ),
            .publish
        )
        XCTAssertEqual(
            SessionStore.workoutReviewCacheCompletionAction(
                completedGeneration: 8,
                currentGeneration: 9,
                requestedKey: requested,
                currentKey: newerAuthority
            ),
            .discardSuperseded
        )
    }

    func testWorkoutReviewInvalidationStormKeepsOneActiveAndOneLatestTrailing() throws {
        func key(_ revision: Int) -> SessionStore.WorkoutReviewCacheKey {
            SessionStore.WorkoutReviewCacheKey(
                sourceSessionsRevision: revision,
                confirmedWorkoutsRevision: 2,
                liveFiveMinuteBucket: 10,
                restingHR: 60,
                maxHR: 190
            )
        }

        var gate = AtriaWorkoutReviewRefreshGate<
            SessionStore.WorkoutReviewCacheKey
        >()
        let activeKey = key(1)
        XCTAssertEqual(gate.request(activeKey), .start)
        var launchCount = 1
        var maximumActiveExecutions = gate.activeKey == nil ? 0 : 1

        for revision in 2...100 {
            gate.invalidate()
            XCTAssertEqual(
                gate.request(key(revision)),
                .coalescedTrailing
            )
            maximumActiveExecutions = max(
                maximumActiveExecutions,
                gate.activeKey == nil ? 0 : 1
            )
            XCTAssertEqual(gate.outstandingWorkUpperBound, 2,
                           "the storm may retain only active + latest trailing")
        }

        let staleCompletion = try XCTUnwrap(
            gate.finish(completedKey: activeKey)
        )
        XCTAssertEqual(staleCompletion.trailingKey, key(100))
        XCTAssertNil(gate.activeKey,
                     "completion releases the sentinel before the trailing launch")
        if let trailingKey = staleCompletion.trailingKey {
            XCTAssertEqual(gate.request(trailingKey), .start)
            launchCount += 1
            maximumActiveExecutions = max(
                maximumActiveExecutions,
                gate.activeKey == nil ? 0 : 1
            )
            _ = gate.finish(completedKey: trailingKey)
        }

        XCTAssertEqual(maximumActiveExecutions, 1)
        XCTAssertEqual(launchCount, 2,
                       "one active worker is followed by exactly one latest replay")
        XCTAssertEqual(gate.outstandingWorkUpperBound, 0)
    }

    func testStaleWorkoutReviewWorkerFinishesBeforeLatestRequestPublishes() throws {
        let staleKey = SessionStore.WorkoutReviewCacheKey(
            sourceSessionsRevision: 4,
            confirmedWorkoutsRevision: 2,
            liveFiveMinuteBucket: 10,
            restingHR: 60,
            maxHR: 190
        )
        let latestKey = SessionStore.WorkoutReviewCacheKey(
            sourceSessionsRevision: 9,
            confirmedWorkoutsRevision: 3,
            liveFiveMinuteBucket: 11,
            restingHR: 61,
            maxHR: 191
        )
        var gate = AtriaWorkoutReviewRefreshGate<
            SessionStore.WorkoutReviewCacheKey
        >()
        XCTAssertEqual(gate.request(staleKey), .start)
        gate.invalidate()
        XCTAssertEqual(gate.request(latestKey), .coalescedTrailing)

        XCTAssertEqual(
            SessionStore.workoutReviewCacheCompletionAction(
                completedGeneration: 8,
                currentGeneration: 9,
                requestedKey: staleKey,
                currentKey: latestKey
            ),
            .discardSuperseded
        )
        let staleCompletion = try XCTUnwrap(
            gate.finish(completedKey: staleKey)
        )
        XCTAssertTrue(staleCompletion.activeWasInvalidated)
        XCTAssertEqual(staleCompletion.trailingKey, latestKey)

        XCTAssertEqual(gate.request(latestKey), .start)
        XCTAssertEqual(
            SessionStore.workoutReviewCacheCompletionAction(
                completedGeneration: 10,
                currentGeneration: 10,
                requestedKey: latestKey,
                currentKey: latestKey
            ),
            .publish
        )
        let latestCompletion = try XCTUnwrap(
            gate.finish(completedKey: latestKey)
        )
        XCTAssertNil(latestCompletion.trailingKey)
        XCTAssertEqual(latestCompletion.completedKey, latestKey)
        XCTAssertEqual(gate.outstandingWorkUpperBound, 0)
    }

    func testRetainedRestoreBlockPreservesNonCancellableWorkoutReviewSentinel() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )

        let latestStart = try XCTUnwrap(source.range(
            of: "func latestWorkoutReviewCandidate("
        ))
        let latestBody = String(source[latestStart.lowerBound...].prefix(1_200))
        XCTAssertTrue(latestBody.contains("!restoreInitializationBlocked"))

        let listStart = try XCTUnwrap(source.range(
            of: "func workoutReviewCandidatesForUI("
        ))
        let listBody = String(source[listStart.lowerBound...].prefix(1_000))
        XCTAssertTrue(listBody.contains("!restoreInitializationBlocked"))

        let schedulerStart = try XCTUnwrap(source.range(
            of: "private func scheduleWorkoutReviewCacheRefresh("
        ))
        let schedulerBody = String(
            source[schedulerStart.lowerBound...].prefix(7_000)
        )
        XCTAssertTrue(schedulerBody.contains(
            "guard !restoreInitializationBlocked else { return }"
        ))
        XCTAssertTrue(schedulerBody.contains("rest: trailingRequest.restingHR"))
        XCTAssertTrue(schedulerBody.contains("maxHR: trailingRequest.maxHR"))
        XCTAssertTrue(schedulerBody.contains("now: Date()"),
                      "trailing work must take a fresh horizon at admission")
        XCTAssertFalse(schedulerBody.contains("now: trailingRequest.now"))

        let restoreStart = try XCTUnwrap(source.range(
            of: "private func enterRetainedRestoreMarkerBlock()"
        ))
        let restoreBody = String(source[restoreStart.lowerBound...].prefix(2_000))
        XCTAssertTrue(restoreBody.contains("invalidateWorkoutReviewCache()"))
        XCTAssertFalse(restoreBody.contains(
            "pendingWorkoutReviewCacheWorkItem?.cancel()"
        ))
        XCTAssertFalse(restoreBody.contains(
            "pendingWorkoutReviewCacheWorkItem = nil"
        ))
        XCTAssertFalse(restoreBody.contains("workoutReviewRefreshGate.cancel()"))
    }

    func testSupersededGenerationCannotPublish() {
        XCTAssertTrue(SessionStore.shouldPublishWorkoutReviewCache(completedGeneration: 8,
                                                                   currentGeneration: 8))
        XCTAssertFalse(SessionStore.shouldPublishWorkoutReviewCache(completedGeneration: 7,
                                                                    currentGeneration: 8))
    }

    func testCachedCandidateFailsClosedUntilSettledAndAfterHorizon() {
        let settling = candidate(endingAt: now.addingTimeInterval(-(10 * 60) + 1))
        let settled = candidate(endingAt: now.addingTimeInterval(-10 * 60))
        let boundary = candidate(endingAt: now.addingTimeInterval(-24 * 60 * 60))
        let stale = candidate(endingAt: now.addingTimeInterval(-(24 * 60 * 60) - 1))

        XCTAssertNil(SessionStore.freshWorkoutReviewCandidate(settling, now: now))
        XCTAssertEqual(SessionStore.freshWorkoutReviewCandidate(settled, now: now), settled)
        XCTAssertEqual(SessionStore.freshWorkoutReviewCandidate(boundary, now: now), boundary)
        XCTAssertNil(SessionStore.freshWorkoutReviewCandidate(stale, now: now))
    }

    func testUnsettledStrongestCandidateCannotHideOlderSettledEffort() {
        let unsettled = candidate(endingAt: now.addingTimeInterval(-2 * 60))
        let settled = WorkoutReviewCandidate(
            id: "older-settled",
            start: now.addingTimeInterval(-35 * 60),
            end: now.addingTimeInterval(-15 * 60),
            kind: .activityCandidate,
            confidence: .medium,
            duration: 20 * 60,
            avgHR: 126,
            peakHR: 145,
            streamCoveragePercent: 98,
            observedDuration: 19 * 60,
            droppedGapSeconds: 0,
            maxSampleGap: 1,
            gapCount: 0,
            reason: "ready"
        )

        XCTAssertEqual(
            SessionStore.preferredFreshWorkoutReviewCandidate(
                primary: unsettled,
                candidates: [unsettled, settled],
                now: now
            ),
            settled
        )
    }

    func testFreshActiveJournalReplacesOlderCanonicalCheckpointForWorkoutReview() {
        let id = UUID()
        let start = now.addingTimeInterval(-20 * 60)
        let canonical = SavedSession(
            id: id,
            start: start,
            end: start.addingTimeInterval(10 * 60),
            label: "Canonical checkpoint",
            points: [
                SavedSession.Point(t: 0, bpm: 120),
                SavedSession.Point(t: 10 * 60, bpm: 130)
            ]
        )
        let journal = SavedSession(
            id: id,
            start: start,
            end: now,
            label: "Active journal",
            points: [
                SavedSession.Point(t: 0, bpm: 120),
                SavedSession.Point(t: 10 * 60, bpm: 130),
                SavedSession.Point(t: 20 * 60, bpm: 135)
            ]
        )

        let source = SessionStore.workoutReviewSourceSessions(
            canonicalSessions: [canonical],
            activeJournalSession: journal
        )

        XCTAssertEqual(source.count, 1)
        XCTAssertEqual(source.first?.id, id)
        XCTAssertEqual(source.first?.points.count, 3)
        XCTAssertEqual(source.first?.end, now)
    }

    func testWorkoutReviewCacheIsWiredToPersistedJournalAndBoundedAuthority() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )
        let keyStart = try XCTUnwrap(source.range(of: "private func workoutReviewKey("))
        let keyBody = String(source[keyStart.lowerBound...].prefix(900))
        XCTAssertTrue(keyBody.contains(
            "sourceSessionsRevision: biologicalAgeSourceSessionsRevision"
        ))
        XCTAssertFalse(keyBody.contains(
            "sourceSessionsRevision: canonicalSessionsRevision"
        ))

        let checkpointStart = try XCTUnwrap(source.range(
            of: "func checkpoint(_ s: SavedSession) -> Bool"
        ))
        let checkpointBody = String(source[checkpointStart.lowerBound...].prefix(4_500))
        XCTAssertTrue(checkpointBody.contains(
            "advancesBiologicalAgeSourceGeneration: false"
        ))

        let refreshStart = try XCTUnwrap(source.range(
            of: "private func scheduleWorkoutReviewCacheRefresh("
        ))
        let refreshBody = String(source[refreshStart.lowerBound...].prefix(6_500))
        XCTAssertTrue(refreshBody.contains(
            "Self.loadActiveJournalSessionIfFresh(now: now)"
        ))
        XCTAssertTrue(refreshBody.contains("Self.workoutReviewSourceSessions("))
        XCTAssertTrue(refreshBody.contains("workoutReviewCacheCompletionAction("))
        XCTAssertTrue(refreshBody.contains(
            "source: \"stale_\\(trailingRequest.source)\""
        ))

        let completionRelease = try XCTUnwrap(refreshBody.range(
            of: "workoutReviewRefreshGate.finish("
        ))
        let trailingLaunch = try XCTUnwrap(refreshBody.range(
            of: "scheduleWorkoutReviewCacheRefresh(",
            range: completionRelease.upperBound..<refreshBody.endIndex
        ))
        XCTAssertLessThan(
            refreshBody.distance(from: refreshBody.startIndex,
                                 to: completionRelease.lowerBound),
            refreshBody.distance(from: refreshBody.startIndex,
                                 to: trailingLaunch.lowerBound),
            "the running sentinel must clear before the trailing launch"
        )

        let invalidationStart = try XCTUnwrap(source.range(
            of: "private func invalidateWorkoutReviewCache()"
        ))
        let invalidationBody = String(
            source[invalidationStart.lowerBound...].prefix(900)
        )
        XCTAssertTrue(invalidationBody.contains(
            "workoutReviewRefreshGate.invalidate()"
        ))
        XCTAssertFalse(invalidationBody.contains(
            "pendingWorkoutReviewCacheWorkItem?.cancel()"
        ))
        XCTAssertFalse(invalidationBody.contains(
            "pendingWorkoutReviewCacheWorkItem = nil"
        ))

        let journalStart = try XCTUnwrap(source.range(
            of: "private func handleActiveJournalSleepReviewIdentity("
        ))
        let journalBody = String(source[journalStart.lowerBound...].prefix(1_400))
        XCTAssertTrue(journalBody.contains("invalidateWorkoutReviewCache()"))
        XCTAssertTrue(journalBody.contains("dashboardRevision &+= 1"))
    }
}
