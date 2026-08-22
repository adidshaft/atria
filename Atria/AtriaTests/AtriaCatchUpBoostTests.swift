import XCTest
@testable import Atria

final class AtriaCatchUpBoostTests: XCTestCase {
    private let threshold = AtriaCatchUpBoost.suggestBehindThreshold // 4h
    private let caughtUp = AtriaCatchUpBoost.caughtUpWithin          // 12m

    // OFF + far behind + backlog → offer the one-tap boost.
    func testSuggestsWhenHoursBehindWithBacklog() {
        let d = AtriaCatchUpBoost.decide(behindSeconds: 6 * 3600,
                                         backlogPending: true,
                                         boostActive: false)
        XCTAssertEqual(d, .suggest)
    }

    // OFF + backlog but only slightly behind → stay idle (short lag self-heals).
    func testDoesNotSuggestForSmallLag() {
        let d = AtriaCatchUpBoost.decide(behindSeconds: 20 * 60,
                                         backlogPending: true,
                                         boostActive: false)
        XCTAssertEqual(d, .idle)
    }

    // OFF + far behind but NO backlog signal → idle (nothing to catch up).
    func testDoesNotSuggestWithoutBacklog() {
        let d = AtriaCatchUpBoost.decide(behindSeconds: 8 * 3600,
                                         backlogPending: false,
                                         boostActive: false)
        XCTAssertEqual(d, .idle)
    }

    // OFF + unknown frontier → never spuriously suggests.
    func testUnknownFrontierDoesNotSuggest() {
        let d = AtriaCatchUpBoost.decide(behindSeconds: nil,
                                         backlogPending: true,
                                         boostActive: false)
        XCTAssertEqual(d, .idle)
    }

    // Exactly at the threshold suggests (boundary inclusive).
    func testAtThresholdSuggests() {
        let d = AtriaCatchUpBoost.decide(behindSeconds: threshold,
                                         backlogPending: true,
                                         boostActive: false)
        XCTAssertEqual(d, .suggest)
    }

    // ON + still behind with backlog → keep boosting.
    func testActiveWhileBacklogRemains() {
        let d = AtriaCatchUpBoost.decide(behindSeconds: 3 * 3600,
                                         backlogPending: true,
                                         boostActive: true)
        XCTAssertEqual(d, .active)
    }

    // ON + backlog cleared → auto-revert (even if frontier unknown), so it can
    // never latch on forever.
    func testAutoRevertWhenBacklogClears() {
        let d = AtriaCatchUpBoost.decide(behindSeconds: nil,
                                         backlogPending: false,
                                         boostActive: true)
        XCTAssertEqual(d, .autoRevert)
    }

    // ON + frontier within the caught-up window → auto-revert.
    func testAutoRevertWhenFrontierCaughtUp() {
        let d = AtriaCatchUpBoost.decide(behindSeconds: caughtUp - 1,
                                         backlogPending: true,
                                         boostActive: true)
        XCTAssertEqual(d, .autoRevert)
    }

    // ON + frontier unknown + backlog still pending → keep boosting (don't
    // revert on ignorance).
    func testActiveKeepsBoostingWhenFrontierUnknownButBacklogPending() {
        let d = AtriaCatchUpBoost.decide(behindSeconds: nil,
                                         backlogPending: true,
                                         boostActive: true)
        XCTAssertEqual(d, .active)
    }

    func testBehindDescriptionHoursAndNilBelowThreshold() {
        XCTAssertEqual(AtriaCatchUpBoost.behindDescription(behindSeconds: 6 * 3600),
                       "~6h behind")
        XCTAssertNil(AtriaCatchUpBoost.behindDescription(behindSeconds: 30 * 60))
        XCTAssertNil(AtriaCatchUpBoost.behindDescription(behindSeconds: nil))
    }
}
