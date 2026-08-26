import XCTest
@testable import Atria

/// Anti-flicker contract for status/metric surfaces (owner report
/// 2026-08-24: "a metric momentarily vanishing then returning makes the
/// product look unreliable").
final class AtriaHoldLastGoodPresentationTests: XCTestCase {

    private enum Fake: String, AtriaHoldableStatus {
        case populated
        case partial
        case waiting

        var atriaHoldRank: Int {
            switch self {
            case .populated: return 2
            case .partial: return 1
            case .waiting: return 0
            }
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_787_580_000)

    func testFirstValueRendersImmediately() {
        let r = AtriaHoldLastGoodPresentation.resolve(
            incoming: Fake.waiting,
            state: .initial,
            now: t0
        )
        XCTAssertEqual(r.value, .waiting,
                       "with nothing shown yet there is nothing to hold")
        XCTAssertFalse(r.isHoldingLastGood)
    }

    func testTransientDowngradeIsHeldThenTellsTheTruth() {
        var state = AtriaHoldLastGoodPresentation.State<Fake>.initial

        let first = AtriaHoldLastGoodPresentation.resolve(
            incoming: .populated, state: state, now: t0
        )
        XCTAssertEqual(first.value, .populated)
        state = first.state

        // 1s later the surface recomputes to "waiting". The user must NOT see
        // the populated value disappear.
        let blip = AtriaHoldLastGoodPresentation.resolve(
            incoming: .waiting, state: state, now: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(blip.value, .populated, "a transient gap must not blank")
        XCTAssertTrue(blip.isHoldingLastGood)
        state = blip.state

        // Still down at 5s — still held (grace is 6s).
        let stillDown = AtriaHoldLastGoodPresentation.resolve(
            incoming: .waiting, state: state, now: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(stillDown.value, .populated)
        state = stillDown.state

        // Past the grace window the honest state renders. Grace is a
        // debounce, never a freshness claim.
        let honest = AtriaHoldLastGoodPresentation.resolve(
            incoming: .waiting, state: state, now: t0.addingTimeInterval(7)
        )
        XCTAssertEqual(honest.value, .waiting,
                       "a sustained outage must surface honestly")
        XCTAssertFalse(honest.isHoldingLastGood)
    }

    func testGraceIsMeasuredFromTheFirstDowngradeNotTheLatest() {
        var state = AtriaHoldLastGoodPresentation.State<Fake>.initial
        state = AtriaHoldLastGoodPresentation.resolve(
            incoming: .populated, state: state, now: t0
        ).state

        // A run of downgrades 1s apart must not renew the window each time.
        for offset in [1.0, 2.0, 3.0, 4.0, 5.0] {
            let r = AtriaHoldLastGoodPresentation.resolve(
                incoming: .waiting,
                state: state,
                now: t0.addingTimeInterval(offset)
            )
            XCTAssertEqual(r.value, .populated, "held at +\(offset)s")
            state = r.state
        }
        // Anchored at the FIRST downgrade (t0+1), so the window closes at
        // t0+7 — not at t0+11, which is where a window renewed by the latest
        // downgrade (t0+5) would land.
        let stillHeld = AtriaHoldLastGoodPresentation.resolve(
            incoming: .waiting, state: state, now: t0.addingTimeInterval(6.5)
        )
        XCTAssertEqual(stillHeld.value, .populated,
                       "6.5s after t0 is only 5.5s into a window that opened "
                           + "at t0+1 — still inside the grace")
        state = stillHeld.state

        let expired = AtriaHoldLastGoodPresentation.resolve(
            incoming: .waiting, state: state, now: t0.addingTimeInterval(7.5)
        )
        XCTAssertEqual(expired.value, .waiting,
                       "repeated downgrades must not extend the hold forever")
        XCTAssertFalse(expired.isHoldingLastGood)
    }

    func testRecoveryWithinGraceClearsTheHoldAndRendersImmediately() {
        var state = AtriaHoldLastGoodPresentation.State<Fake>.initial
        state = AtriaHoldLastGoodPresentation.resolve(
            incoming: .populated, state: state, now: t0
        ).state
        state = AtriaHoldLastGoodPresentation.resolve(
            incoming: .waiting, state: state, now: t0.addingTimeInterval(1)
        ).state

        let back = AtriaHoldLastGoodPresentation.resolve(
            incoming: .populated, state: state, now: t0.addingTimeInterval(2)
        )
        XCTAssertEqual(back.value, .populated)
        XCTAssertFalse(back.isHoldingLastGood, "the hold must clear on recovery")

        // And a fresh downgrade after recovery gets its own full window.
        let freshDowngrade = AtriaHoldLastGoodPresentation.resolve(
            incoming: .waiting,
            state: back.state,
            now: t0.addingTimeInterval(3)
        )
        XCTAssertEqual(freshDowngrade.value, .populated)
    }

    func testUpgradeRendersImmediatelyAndIsNeverHeld() {
        var state = AtriaHoldLastGoodPresentation.State<Fake>.initial
        state = AtriaHoldLastGoodPresentation.resolve(
            incoming: .waiting, state: state, now: t0
        ).state

        let up = AtriaHoldLastGoodPresentation.resolve(
            incoming: .populated, state: state, now: t0.addingTimeInterval(0.1)
        )
        XCTAssertEqual(up.value, .populated,
                       "better information must never be delayed")
        XCTAssertFalse(up.isHoldingLastGood)
    }

    func testPartialDowngradeFromPopulatedIsAlsoHeld() {
        // The exact Home banner flip: "Recovery partial · 40 saved" is itself
        // a downgrade from a populated/syncing state and flickers back.
        var state = AtriaHoldLastGoodPresentation.State<Fake>.initial
        state = AtriaHoldLastGoodPresentation.resolve(
            incoming: .populated, state: state, now: t0
        ).state

        let r = AtriaHoldLastGoodPresentation.resolve(
            incoming: .partial, state: state, now: t0.addingTimeInterval(0.5)
        )
        XCTAssertEqual(r.value, .populated)
        XCTAssertTrue(r.isHoldingLastGood)
    }

    func testBackwardsClockFailsHonestRatherThanHoldingForever() {
        var state = AtriaHoldLastGoodPresentation.State<Fake>.initial
        state = AtriaHoldLastGoodPresentation.resolve(
            incoming: .populated, state: state, now: t0
        ).state
        state = AtriaHoldLastGoodPresentation.resolve(
            incoming: .waiting, state: state, now: t0.addingTimeInterval(2)
        ).state

        let backwards = AtriaHoldLastGoodPresentation.resolve(
            incoming: .waiting, state: state, now: t0.addingTimeInterval(-60)
        )
        XCTAssertEqual(backwards.value, .waiting,
                       "a clock jump must not pin a stale value on screen")
    }

    // MARK: - Banner state after a finished recovery generation

    func testOngoingBacklogReadsAsSyncingNotTerminalPartial() {
        // Device 2026-08-24: once the drain became default-on it runs
        // continuously, so every generation ended `.partial` and the next set
        // `.syncing` — the banner alternated once per ~40s slice.
        XCTAssertEqual(
            AtriaBLEManager.historicalRecoveryPresentationAfterGeneration(
                rangeLossResolved: false,
                savedRecords: 1080,
                strapBacklogPending: true
            ),
            .syncing(savedRecords: 1080),
            "another slice is already coming — that is still syncing"
        )
    }

    func testUnprovenGapSettlesToPartialOnlyWhenNoBacklogRemains() {
        XCTAssertEqual(
            AtriaBLEManager.historicalRecoveryPresentationAfterGeneration(
                rangeLossResolved: false,
                savedRecords: 1080,
                strapBacklogPending: false
            ),
            .partial(savedRecords: 1080),
            "with nothing left to drain, an unresolved gap is honestly partial"
        )
    }

    func testResolvedRangeLossStillWinsOverEverything() {
        XCTAssertEqual(
            AtriaBLEManager.historicalRecoveryPresentationAfterGeneration(
                rangeLossResolved: true,
                savedRecords: 0,
                strapBacklogPending: true
            ),
            .verified
        )
    }

    func testAGenerationThatSavedNothingNeverClaimsProgress() {
        for pending in [true, false] {
            XCTAssertEqual(
                AtriaBLEManager.historicalRecoveryPresentationAfterGeneration(
                    rangeLossResolved: false,
                    savedRecords: 0,
                    strapBacklogPending: pending
                ),
                .needsAttention,
                "zero saved rows must not read as syncing progress"
            )
        }
    }

    func testDefaultGraceIsBoundedAndShort() {
        XCTAssertEqual(AtriaHoldLastGoodPresentation.defaultGrace, 6)
        XCTAssertLessThanOrEqual(
            AtriaHoldLastGoodPresentation.defaultGrace, 10,
            "grace must stay well inside a glance so it cannot read as freshness"
        )
    }
}
