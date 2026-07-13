import XCTest
@testable import Atria

final class AtriaWorkoutReviewCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(endingAt end: Date) -> SavedSession {
        SavedSession(id: UUID(),
                     start: end.addingTimeInterval(-15 * 60),
                     end: end,
                     label: "Workout review cache test",
                     points: [SavedSession.Point(t: 0, bpm: 120),
                              SavedSession.Point(t: 15 * 60, bpm: 130)])
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

    func testCacheKeyInvalidatesForSessionConfirmationAndHRInputChanges() {
        let original = SessionStore.WorkoutReviewCacheKey(canonicalSessionsRevision: 4,
                                                          confirmedWorkoutsRevision: 2,
                                                          restingHR: 60,
                                                          maxHR: 190)
        XCTAssertNotEqual(original,
                          SessionStore.WorkoutReviewCacheKey(canonicalSessionsRevision: 5,
                                                             confirmedWorkoutsRevision: 2,
                                                             restingHR: 60,
                                                             maxHR: 190))
        XCTAssertNotEqual(original,
                          SessionStore.WorkoutReviewCacheKey(canonicalSessionsRevision: 4,
                                                             confirmedWorkoutsRevision: 3,
                                                             restingHR: 60,
                                                             maxHR: 190))
        XCTAssertNotEqual(original,
                          SessionStore.WorkoutReviewCacheKey(canonicalSessionsRevision: 4,
                                                             confirmedWorkoutsRevision: 2,
                                                             restingHR: 61,
                                                             maxHR: 190))
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
}
