import XCTest
@testable import Atria

final class AtriaStrapStepLiveStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshValidatedCountIsPresentedAsLive() {
        let status = AtriaStrapStepLiveStatus.make(
            count: 842,
            validationState: "r10_live_validated",
            capturedAt: now.addingTimeInterval(-12),
            now: now
        )

        XCTAssertTrue(status.isLive)
        XCTAssertTrue(status.isValidated)
        XCTAssertEqual(status.tileValue, "842")
        XCTAssertEqual(status.tileDetail, "Live strap count")
        XCTAssertEqual(status.lastMotionText, "motion 12s ago")
    }

    func testFreshUnvalidatedCountIsClearlyEstimated() {
        let status = AtriaStrapStepLiveStatus.make(
            count: 842,
            validationState: "research_unvalidated",
            capturedAt: now.addingTimeInterval(-12),
            now: now
        )

        XCTAssertTrue(status.isLive)
        XCTAssertFalse(status.isValidated)
        XCTAssertEqual(status.tileValue, "~842")
        XCTAssertEqual(status.tileDetail, "Live estimate")
        XCTAssertTrue(status.accessibilityDetail(goal: 10_000).contains("estimated count"))
    }

    func testStaleCountIsNotPresentedAsCurrentOnTile() {
        let status = AtriaStrapStepLiveStatus.make(
            count: 842,
            validationState: "validated",
            capturedAt: now.addingTimeInterval(-180),
            now: now
        )

        XCTAssertFalse(status.isLive)
        XCTAssertEqual(status.freshness, .stale)
        XCTAssertEqual(status.tileValue, "--")
        XCTAssertEqual(status.tileDetail, "Not live · motion 3m ago")
        XCTAssertEqual(status.savedCountText, "842")
    }

    func testMissingMotionIsUnavailableWhenNoSavedCountExists() {
        let status = AtriaStrapStepLiveStatus.make(
            count: 0,
            validationState: "research_unvalidated",
            capturedAt: nil,
            now: now
        )

        XCTAssertEqual(status.freshness, .unavailable)
        XCTAssertEqual(status.tileValue, "--")
        XCTAssertEqual(status.tileDetail, "Not live · no motion")
    }

    func testImplausibleFutureMotionDoesNotBecomeLive() {
        let status = AtriaStrapStepLiveStatus.make(
            count: 842,
            validationState: "r10_live_validated",
            capturedAt: now.addingTimeInterval(30),
            now: now
        )

        XCTAssertEqual(status.freshness, .stale)
        XCTAssertEqual(status.tileValue, "--")
    }

    func testPersistedMotionDateReadsBLETimestamp() throws {
        let suiteName = "AtriaStrapStepLiveStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(now.timeIntervalSince1970,
                     forKey: AtriaStrapStepLiveStatus.persistedMotionKey)

        XCTAssertEqual(AtriaStrapStepLiveStatus.persistedMotionDate(defaults: defaults), now)
    }
}
