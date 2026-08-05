import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaTodaySleepReviewProjectionTests: XCTestCase {
    func testUnchangedStateDoesNotPublish() {
        let initial = state()
        let projection = AtriaTodaySleepReviewProjectionStore(state: initial)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(initial))
        XCTAssertFalse(projection.refresh(initial))
        XCTAssertEqual(publications, 0)

        withExtendedLifetime(cancellable) {}
    }

    func testEachRenderedInputPublishesImmediatelyAndEqualityGatesRepeats() {
        let initial = state()
        let projection = AtriaTodaySleepReviewProjectionStore(state: initial)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        let night = reviewNight(id: "review")
        let snapshot = SleepHistorySnapshot(nights: [night], confirmedCount: 0, candidateCount: 1)
        let snapshotState = state(snapshot: snapshot)
        XCTAssertTrue(projection.refresh(snapshotState))
        XCTAssertFalse(projection.refresh(snapshotState))

        let pendingState = state(snapshot: snapshot, pendingReview: reviewNight(id: "pending"))
        XCTAssertTrue(projection.refresh(pendingState))
        XCTAssertFalse(projection.refresh(pendingState))

        let bannerState = state(
            snapshot: snapshot,
            pendingReview: reviewNight(id: "pending"),
            banner: AutoSleepLoggedBanner(
                id: "banner",
                start: Date(timeIntervalSince1970: 1_000),
                end: Date(timeIntervalSince1970: 2_000),
                duration: 1_000,
                sleepID: "sleep"
            )
        )
        XCTAssertTrue(projection.refresh(bannerState))
        XCTAssertFalse(projection.refresh(bannerState))
        XCTAssertEqual(publications, 3)

        withExtendedLifetime(cancellable) {}
    }

    func testResidentJournalReviewOutranksStaleFirstWakeSnapshotForSameEpisode() throws {
        let snapshotNight = reviewNight(id: "first-wake",
                                        start: 10_000,
                                        end: 31_540) // 03:16-09:15 shape
        let residentNight = reviewNight(id: "resident-resumed",
                                        start: 23_140,
                                        end: 42_360) // conservative 06:55-12:15
        let snapshot = SleepHistorySnapshot(nights: [snapshotNight],
                                            confirmedCount: 0,
                                            candidateCount: 1)

        let selected = try XCTUnwrap(AtriaTodaySleepReviewProjectionState.preferredReview(
            snapshot: snapshot,
            pending: residentNight
        ))

        XCTAssertEqual(selected.id, residentNight.id)
        XCTAssertEqual(selected.end, residentNight.end)
        XCTAssertFalse(selected.confirmed,
                       "growing the review across resumed sleep must not auto-confirm it")
    }

    func testBriefWakeContinuationCanReplaceEarlierSnapshotButUnrelatedEpisodeCannot() throws {
        let snapshotNight = reviewNight(id: "first-fragment",
                                        start: 10_000,
                                        end: 23_000)
        let snapshot = SleepHistorySnapshot(nights: [snapshotNight],
                                            confirmedCount: 0,
                                            candidateCount: 1)
        let resumed = reviewNight(id: "brief-wake-continuation",
                                  start: 23_600,
                                  end: 36_000)
        XCTAssertEqual(AtriaTodaySleepReviewProjectionState.preferredReview(
            snapshot: snapshot,
            pending: resumed
        )?.id, resumed.id)

        let unrelated = reviewNight(id: "unrelated-later-episode",
                                    start: 40_000,
                                    end: 53_000)
        XCTAssertEqual(AtriaTodaySleepReviewProjectionState.preferredReview(
            snapshot: snapshot,
            pending: unrelated,
            maximumSameEpisodeGap: 60 * 60
        )?.id, snapshotNight.id)
    }

    func testMateriallyLaterCorrectedOnsetSupersedesSnapshotAtSameWakeBoundary() throws {
        let snapshotNight = reviewNight(id: "untrimmed-rollup",
                                        start: 10_000,
                                        end: 43_000)
        let corrected = reviewNight(id: "physiological-onset",
                                    start: 31_600,
                                    end: 43_000)
        let snapshot = SleepHistorySnapshot(nights: [snapshotNight],
                                            confirmedCount: 0,
                                            candidateCount: 1)

        let selected = try XCTUnwrap(AtriaTodaySleepReviewProjectionState.preferredReview(
            snapshot: snapshot,
            pending: corrected
        ))

        XCTAssertEqual(selected.id, corrected.id)
        XCTAssertEqual(selected.start, corrected.start)
        XCTAssertEqual(selected.end, snapshotNight.end,
                       "an onset correction must retain the established wake boundary")
        XCTAssertFalse(selected.confirmed)
    }

    func testOnsetCorrectionCannotRegressWakeBoundaryOrCrossWakeDay() {
        let wakeDay = Date(timeIntervalSince1970: 86_400)
        let snapshotNight = reviewNight(id: "established",
                                        start: 10_000,
                                        end: 43_000,
                                        day: wakeDay)
        let snapshot = SleepHistorySnapshot(nights: [snapshotNight],
                                            confirmedCount: 0,
                                            candidateCount: 1)
        let truncated = reviewNight(id: "truncated",
                                    start: 31_600,
                                    end: 42_000,
                                    day: wakeDay)
        XCTAssertEqual(AtriaTodaySleepReviewProjectionState.preferredReview(
            snapshot: snapshot,
            pending: truncated
        )?.id, snapshotNight.id,
        "a materially earlier wake boundary must not masquerade as onset correction")

        let differentWakeDay = reviewNight(id: "different-wake-day",
                                           start: 31_600,
                                           end: 43_000,
                                           day: wakeDay.addingTimeInterval(86_400))
        XCTAssertEqual(AtriaTodaySleepReviewProjectionState.preferredReview(
            snapshot: snapshot,
            pending: differentWakeDay
        )?.id, snapshotNight.id,
        "an overlapping record owned by another wake day must not replace this night")

        let marginal = reviewNight(id: "marginal-shift",
                                   start: 10_000 + 29 * 60,
                                   end: 43_000,
                                   day: wakeDay)
        XCTAssertEqual(AtriaTodaySleepReviewProjectionState.preferredReview(
            snapshot: snapshot,
            pending: marginal
        )?.id, snapshotNight.id,
        "checkpoint jitter below the material correction threshold must stay stable")
    }

    func testTodayChainUsesOnlyTheNarrowProjection() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let hostStart = try XCTUnwrap(source.range(of: "private struct AtriaSleepReviewHost: View"))
        let bannerStart = try XCTUnwrap(
            source.range(of: "private struct AtriaAutoSleepLoggedBanner: View", range: hostStart.upperBound..<source.endIndex)
        )
        let syncStart = try XCTUnwrap(
            source.range(of: "private struct AtriaSleepSyncNeededHost: View", range: bannerStart.upperBound..<source.endIndex)
        )
        let sectionStart = try XCTUnwrap(source.range(of: "struct AtriaTodaySleepReviewSection: View"))
        // 2026-08-06: audit fix — dead twin deleted. The chain slice used to end
        // at AtriaOverviewLeadingSection; that legacy Overview struct is gone, so
        // the boundary is now the next surviving declaration.
        let leadingStart = try XCTUnwrap(
            source.range(of: "enum AtriaOverviewCurrentSleep", range: sectionStart.upperBound..<source.endIndex)
        )
        let chain = String(source[hostStart.lowerBound..<bannerStart.lowerBound])
            + String(source[bannerStart.lowerBound..<syncStart.lowerBound])
            + String(source[sectionStart.lowerBound..<leadingStart.lowerBound])

        XCTAssertFalse(chain.contains("@ObservedObject var store: SessionStore"))
        XCTAssertTrue(chain.contains("@StateObject private var projectionStore: AtriaTodaySleepReviewProjectionStore"))
        XCTAssertTrue(chain.contains("guard stable != state else { return false }"))
        XCTAssertTrue(chain.contains("store.$sleepHistorySnapshot"))
        XCTAssertTrue(chain.contains("store.$pendingSleepReviewNightForUI"))
        XCTAssertTrue(chain.contains("store.$autoSleepLoggedBanner"))
        XCTAssertFalse(chain.contains("store.$dashboardRevision"))
        XCTAssertFalse(chain.contains("store.objectWillChange"))
        XCTAssertTrue(chain.contains("return state.preferredReview"),
                      "Today must resolve a stale snapshot against the growing resident-journal review")
        // 2026-08-06: audit fix — dead twin deleted. The prioritizesPendingReview:
        // false mount lived only in the removed AtriaOverviewLeadingSection; the
        // live mount (AtriaHomeView) uses the section's default argument.

        let stateStart = try XCTUnwrap(source.range(of: "struct AtriaTodaySleepReviewProjectionState: Equatable"))
        let stateEnd = try XCTUnwrap(
            source.range(of: "@MainActor\nfinal class AtriaTodaySleepReviewProjectionStore", range: stateStart.upperBound..<source.endIndex)
        )
        let projectedState = String(source[stateStart.lowerBound..<stateEnd.lowerBound])
        XCTAssertEqual(projectedState.components(separatedBy: "\n    let ").count - 1, 3)
    }

    func testTransientRetryNilKeepsExactPublishedHROnlyReview() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let candidate = reviewNight(id: "real-hr-only",
                                    start: now.timeIntervalSince1970 - 8 * 60 * 60,
                                    end: now.timeIntervalSince1970 - 20 * 60)
        let previous = state(pendingReview: candidate)
        let incoming = state()

        let stable = AtriaTodaySleepReviewProjectionState.preservingRealReviewAcrossTransientLoss(
            previous: previous,
            incoming: incoming,
            dismissedCandidates: [],
            now: now
        )

        let retained = try XCTUnwrap(stable.preferredReview)
        XCTAssertEqual(retained, candidate,
                       "a retry must not erase a real review between evidence revisions")
        XCTAssertEqual(retained.confidence, "review_needed")
        XCTAssertEqual(retained.source, "sleep_candidate")
        XCTAssertFalse(retained.confirmed,
                       "continuity is presentation-only and must never auto-confirm or fabricate motion")
    }

    func testContinuityHoldClearsForDurableDismissal() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let candidate = reviewNight(id: "dismissed",
                                    start: now.timeIntervalSince1970 - 8 * 60 * 60,
                                    end: now.timeIntervalSince1970 - 20 * 60)
        let dismissal = AtriaDismissedSleepCandidate(start: candidate.start!, end: candidate.end!)

        let stable = AtriaTodaySleepReviewProjectionState.preservingRealReviewAcrossTransientLoss(
            previous: state(pendingReview: candidate),
            incoming: state(),
            dismissedCandidates: [dismissal],
            now: now
        )

        XCTAssertNil(stable.preferredReview,
                     "a user dismissal must win over transient-loss continuity")
    }

    func testContinuityHoldClearsWhenCandidateWasConfirmed() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let candidate = reviewNight(id: "pending",
                                    start: now.timeIntervalSince1970 - 8 * 60 * 60,
                                    end: now.timeIntervalSince1970 - 20 * 60)
        var confirmed = candidate
        confirmed = SleepHistorySnapshot.Night(
            id: "confirmed",
            day: candidate.day,
            start: candidate.start,
            end: candidate.end,
            duration: candidate.duration,
            restingHR: candidate.restingHR,
            hrv: candidate.hrv,
            respiratoryRate: candidate.respiratoryRate,
            sleepEfficiency: candidate.sleepEfficiency,
            confidence: "confirmed",
            source: "user_confirmed",
            confirmed: true,
            stageSegments: []
        )
        let incoming = state(snapshot: SleepHistorySnapshot(nights: [confirmed],
                                                            confirmedCount: 1,
                                                            candidateCount: 0))

        let stable = AtriaTodaySleepReviewProjectionState.preservingRealReviewAcrossTransientLoss(
            previous: state(pendingReview: candidate),
            incoming: incoming,
            dismissedCandidates: [],
            now: now
        )

        XCTAssertNil(stable.preferredReview)
    }

    private func state(snapshot: SleepHistorySnapshot = .empty,
                       pendingReview: SleepHistorySnapshot.Night? = nil,
                       banner: AutoSleepLoggedBanner? = nil) -> AtriaTodaySleepReviewProjectionState {
        AtriaTodaySleepReviewProjectionState(
            sleepHistorySnapshot: snapshot,
            pendingSleepReviewNight: pendingReview,
            autoSleepLoggedBanner: banner
        )
    }

    private func reviewNight(id: String,
                             start: TimeInterval = 1_000,
                             end: TimeInterval = 2_000,
                             day: Date = Date(timeIntervalSince1970: 0)) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(
            id: id,
            day: day,
            start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: end),
            duration: end - start,
            restingHR: 55,
            hrv: 70,
            respiratoryRate: 14,
            sleepEfficiency: 0.9,
            confidence: "review_needed",
            source: "sleep_candidate",
            confirmed: false,
            stageSegments: []
        )
    }
}
