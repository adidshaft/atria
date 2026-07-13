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
        let leadingStart = try XCTUnwrap(
            source.range(of: "struct AtriaOverviewLeadingSection: View", range: sectionStart.upperBound..<source.endIndex)
        )
        let chain = String(source[hostStart.lowerBound..<bannerStart.lowerBound])
            + String(source[bannerStart.lowerBound..<syncStart.lowerBound])
            + String(source[sectionStart.lowerBound..<leadingStart.lowerBound])

        XCTAssertFalse(chain.contains("@ObservedObject var store: SessionStore"))
        XCTAssertTrue(chain.contains("@StateObject private var projectionStore: AtriaTodaySleepReviewProjectionStore"))
        XCTAssertTrue(chain.contains("guard next != state else { return false }"))
        XCTAssertTrue(chain.contains("store.$sleepHistorySnapshot"))
        XCTAssertTrue(chain.contains("store.$pendingSleepReviewNightForUI"))
        XCTAssertTrue(chain.contains("store.$autoSleepLoggedBanner"))
        XCTAssertFalse(chain.contains("store.$dashboardRevision"))
        XCTAssertFalse(chain.contains("store.objectWillChange"))
        XCTAssertTrue(source.contains("AtriaTodaySleepReviewSection(store: store, prioritizesPendingReview: false)"))

        let stateStart = try XCTUnwrap(source.range(of: "struct AtriaTodaySleepReviewProjectionState: Equatable"))
        let stateEnd = try XCTUnwrap(
            source.range(of: "@MainActor\nfinal class AtriaTodaySleepReviewProjectionStore", range: stateStart.upperBound..<source.endIndex)
        )
        let projectedState = String(source[stateStart.lowerBound..<stateEnd.lowerBound])
        XCTAssertEqual(projectedState.components(separatedBy: "\n    let ").count - 1, 3)
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

    private func reviewNight(id: String) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(
            id: id,
            day: Date(timeIntervalSince1970: 0),
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            duration: 1_000,
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
