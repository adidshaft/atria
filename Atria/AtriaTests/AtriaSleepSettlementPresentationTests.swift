import XCTest
import SwiftUI
@testable import Atria

/// State-machine tests for the wake-settlement row.
///
/// The invariant that matters most: `.saved` must be reachable only from a
/// persisted confirmation, because that is the one state that claims the night
/// is done.
final class AtriaSleepSettlementPresentationTests: XCTestCase {

    private let wake = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Processing window

    func testInsideTheSettlementWindowTheNightIsProcessing() {
        let state = AtriaSleepSettlementPresentation.state(
            confirmedSleepEnd: nil,
            confirmedSleepSavedAt: nil,
            candidateEnd: wake,
            now: wake.addingTimeInterval(5 * 60)
        )

        XCTAssertEqual(state, .processing(since: wake))
        XCTAssertEqual(state.title, "Sleep ended · processing")
        XCTAssertTrue(state.isSettling)
    }

    /// The boundary belongs to review-ready: the gate that withholds
    /// auto-confirmation uses `>=`, so the UI must flip at the same instant
    /// rather than a second later.
    func testTheSettlementBoundaryIsInclusive() {
        let justInside = AtriaSleepSettlementPresentation.state(
            confirmedSleepEnd: nil,
            confirmedSleepSavedAt: nil,
            candidateEnd: wake,
            now: wake.addingTimeInterval(AtriaSleepSettlementPresentation.settlementDelay - 1)
        )
        let atBoundary = AtriaSleepSettlementPresentation.state(
            confirmedSleepEnd: nil,
            confirmedSleepSavedAt: nil,
            candidateEnd: wake,
            now: wake.addingTimeInterval(AtriaSleepSettlementPresentation.settlementDelay)
        )

        XCTAssertEqual(justInside, .processing(since: wake))
        XCTAssertEqual(atBoundary, .reviewReady(since: wake))
    }

    func testSettlementDelayMatchesTheConfirmationGate() {
        // If this ever drifts from SessionStore's 30-minute gate, the row would
        // claim the night is review-ready while the engine still refuses to
        // confirm it.
        XCTAssertEqual(AtriaSleepSettlementPresentation.settlementDelay, 30 * 60)
    }

    /// A candidate that has not finished cannot be past a window it has not
    /// entered, so it settles rather than jumping to review-ready.
    func testACandidateEndingInTheFutureIsTreatedAsProcessing() {
        let state = AtriaSleepSettlementPresentation.state(
            confirmedSleepEnd: nil,
            confirmedSleepSavedAt: nil,
            candidateEnd: wake.addingTimeInterval(10 * 60),
            now: wake
        )

        XCTAssertTrue(state.isSettling)
    }

    // MARK: - Review ready

    func testPastTheWindowAndUnconfirmedIsReviewReady() {
        let state = AtriaSleepSettlementPresentation.state(
            confirmedSleepEnd: nil,
            confirmedSleepSavedAt: nil,
            candidateEnd: wake,
            now: wake.addingTimeInterval(90 * 60)
        )

        XCTAssertEqual(state, .reviewReady(since: wake))
        XCTAssertEqual(state.title, "Sleep detected · review ready")
        // Waiting on the user, not on the app.
        XCTAssertFalse(state.isSettling)
    }

    // MARK: - Saved

    func testAPersistedConfirmationIsSaved() {
        let savedAt = wake.addingTimeInterval(31 * 60)
        let state = AtriaSleepSettlementPresentation.state(
            confirmedSleepEnd: wake,
            confirmedSleepSavedAt: savedAt,
            candidateEnd: nil,
            now: savedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(state, .saved(at: savedAt))
        XCTAssertEqual(state.title, "Sleep saved · journal ready")
    }

    /// The candidate that produced a confirmation usually remains in the
    /// snapshot. Without this precedence the row would re-report a saved night
    /// as still settling.
    func testConfirmationWinsOverALingeringCandidate() {
        let savedAt = wake.addingTimeInterval(31 * 60)
        let state = AtriaSleepSettlementPresentation.state(
            confirmedSleepEnd: wake,
            confirmedSleepSavedAt: savedAt,
            candidateEnd: wake,
            now: savedAt
        )

        XCTAssertEqual(state, .saved(at: savedAt))
    }

    /// Nothing but a persisted confirmation may reach `.saved`.
    func testNoCandidateStateEverClaimsSaved() {
        for minutes in [0, 5, 29, 30, 31, 120, 1_000] {
            let state = AtriaSleepSettlementPresentation.state(
                confirmedSleepEnd: nil,
                confirmedSleepSavedAt: nil,
                candidateEnd: wake,
                now: wake.addingTimeInterval(Double(minutes) * 60)
            )

            if case .saved = state {
                XCTFail("unconfirmed night claimed saved at \(minutes)m")
            }
        }
    }

    // MARK: - Waiting for data

    func testNoCandidateAndNoConfirmationWaitsForData() {
        let state = AtriaSleepSettlementPresentation.state(
            confirmedSleepEnd: nil,
            confirmedSleepSavedAt: nil,
            candidateEnd: nil,
            now: wake
        )

        XCTAssertEqual(state, .waitingForData)
        XCTAssertEqual(state.title, "Still waiting for enough strap data")
        XCTAssertNil(state.since, "no event behind this state, so no stamp")
    }

    // MARK: - Status colour

    /// Green is backed by a persisted confirmation and nothing else. This is the
    /// colour equivalent of the `.saved` invariant: no amount of elapsed time on
    /// an unconfirmed night may turn the row green.
    func testOnlyAPersistedConfirmationReadsGreen() {
        XCTAssertEqual(AtriaSleepSettlementState.saved(at: wake).statusTint,
                       AtriaMetricZoneLevel.green.tint)

        for state: AtriaSleepSettlementState in [.processing(since: wake),
                                                 .reviewReady(since: wake),
                                                 .waitingForData] {
            XCTAssertNotEqual(state.statusTint, AtriaMetricZoneLevel.green.tint,
                              "\(state) must not read as a completed night")
        }
    }

    /// The one state genuinely waiting on the user is the one that wants
    /// attention.
    func testReviewReadyIsTheOnlyAmberState() {
        XCTAssertEqual(AtriaSleepSettlementState.reviewReady(since: wake).statusTint,
                       AtriaMetricZoneLevel.yellow.tint)
    }

    /// Working, or nothing to judge. Neither is a status the user must act on,
    /// and neither has earned a colour.
    func testInProgressAndUnknownStatesStayNeutral() {
        XCTAssertNil(AtriaSleepSettlementState.processing(since: wake).statusTint)
        XCTAssertNil(AtriaSleepSettlementState.waitingForData.statusTint)
    }

    /// Sleep settlement is not a health grade, so it must not borrow the colour
    /// reserved for a genuinely poor measured value.
    func testSettlementNeverBorrowsThePoorValueRed() {
        for state: AtriaSleepSettlementState in [.processing(since: wake),
                                                 .reviewReady(since: wake),
                                                 .saved(at: wake),
                                                 .waitingForData] {
            XCTAssertNotEqual(state.statusTint, AtriaMetricZoneLevel.red.tint,
                              "\(state) must not read as a poor measurement")
        }
    }

    // MARK: - Freshness

    func testFreshnessReadsInTheLargestSensibleUnit() {
        let state = AtriaSleepSettlementState.processing(since: wake)

        XCTAssertEqual(AtriaSleepSettlementPresentation.freshnessText(for: state, now: wake),
                       "just now")
        XCTAssertEqual(AtriaSleepSettlementPresentation.freshnessText(
            for: state, now: wake.addingTimeInterval(2 * 60)), "2m ago")
        XCTAssertEqual(AtriaSleepSettlementPresentation.freshnessText(
            for: state, now: wake.addingTimeInterval(3 * 3600)), "3h ago")
        XCTAssertEqual(AtriaSleepSettlementPresentation.freshnessText(
            for: state, now: wake.addingTimeInterval(2 * 86_400)), "2d ago")
    }

    func testWaitingForDataHasNoFreshnessStamp() {
        XCTAssertNil(AtriaSleepSettlementPresentation.freshnessText(
            for: .waitingForData, now: wake))
    }

    /// Clock skew must not produce "-3m ago".
    func testFutureStampsDegradeToJustNow() {
        let state = AtriaSleepSettlementState.saved(at: wake.addingTimeInterval(60))

        XCTAssertEqual(AtriaSleepSettlementPresentation.freshnessText(for: state, now: wake),
                       "just now")
    }

    /// The row is a single line, so every stamp has to stay short.
    func testEveryFreshnessStampStaysShort() {
        let state = AtriaSleepSettlementState.reviewReady(since: wake)
        let offsets: [TimeInterval] = [0, 59, 60, 3_599, 3_600, 86_399, 86_400, 86_400 * 400]
        for seconds in offsets {
            let text = AtriaSleepSettlementPresentation.freshnessText(
                for: state, now: wake.addingTimeInterval(seconds))
            XCTAssertNotNil(text)
            XCTAssertLessThanOrEqual(text?.count ?? 0, 10, "stamp too long: \(text ?? "")")
        }
    }
}
