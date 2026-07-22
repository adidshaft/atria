import XCTest
@testable import Atria

final class AtriaActiveJournalCheckpointPolicyTests: XCTestCase {
    func testFirstDirtySampleDeadlineIsFiveSecondsAndCannotBePostponed() {
        let firstDirty = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            AtriaBLEManager.activeJournalCheckpointDelay(
                firstDirtyAcceptedSampleAt: firstDirty,
                now: firstDirty
            ),
            5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            AtriaBLEManager.activeJournalCheckpointDelay(
                firstDirtyAcceptedSampleAt: firstDirty,
                now: firstDirty.addingTimeInterval(4)
            ),
            1,
            accuracy: 0.000_001,
            "later samples reuse the original deadline instead of restarting it"
        )
        XCTAssertEqual(
            AtriaBLEManager.activeJournalCheckpointDelay(
                firstDirtyAcceptedSampleAt: firstDirty,
                now: firstDirty.addingTimeInterval(5)
            ),
            0,
            accuracy: 0.000_001
        )
    }

    func testCheckpointPolicyCoalescesFourSamplesButForcesTheFifth() {
        let firstDirty = Date(timeIntervalSince1970: 20_000)

        XCTAssertFalse(AtriaBLEManager.shouldCheckpointActiveJournal(
            unpersistedSamples: 4,
            firstDirtyAcceptedSampleAt: firstDirty,
            now: firstDirty.addingTimeInterval(4.999)
        ))
        XCTAssertTrue(AtriaBLEManager.shouldCheckpointActiveJournal(
            unpersistedSamples: 5,
            firstDirtyAcceptedSampleAt: firstDirty,
            now: firstDirty.addingTimeInterval(1)
        ))
    }

    func testCheckpointPolicyForcesSparseTailAtFiveSecondsAndFailsSafeOnClockRegression() {
        let firstDirty = Date(timeIntervalSince1970: 30_000)

        XCTAssertTrue(AtriaBLEManager.shouldCheckpointActiveJournal(
            unpersistedSamples: 1,
            firstDirtyAcceptedSampleAt: firstDirty,
            now: firstDirty.addingTimeInterval(5)
        ))
        XCTAssertTrue(AtriaBLEManager.shouldCheckpointActiveJournal(
            unpersistedSamples: 1,
            firstDirtyAcceptedSampleAt: firstDirty,
            now: firstDirty.addingTimeInterval(-1)
        ))
        XCTAssertFalse(AtriaBLEManager.shouldCheckpointActiveJournal(
            unpersistedSamples: 0,
            firstDirtyAcceptedSampleAt: firstDirty,
            now: firstDirty.addingTimeInterval(60)
        ))
    }

    func testFasterCheckpointCadenceDoesNotChangeJournalStorageBounds() {
        XCTAssertEqual(AtriaBLEManager.activeJournalCheckpointMaximumUnpersistedSamples, 5)
        XCTAssertEqual(AtriaBLEManager.activeJournalCheckpointMaximumAge, 5)
        XCTAssertEqual(AtriaBLEManager.activeJournalCheckpointRetryDelay, 1)
        XCTAssertEqual(ActiveSessionJournal.maximumSegmentChainCount, 64)
        XCTAssertEqual(ActiveSessionJournal.maximumSegmentChainBytes, 24 * 1_024 * 1_024)
    }

    func testSaveCompletionKeepsSamplesThatArrivedWhileWriteWasInFlightDirty() {
        XCTAssertEqual(AtriaBLEManager.activeJournalUnpersistedTailCount(
            currentSampleCount: 105,
            checkpointSourceSampleCount: 100
        ), 5)
        XCTAssertEqual(AtriaBLEManager.activeJournalUnpersistedTailCount(
            currentSampleCount: 100,
            checkpointSourceSampleCount: 100
        ), 0)
        XCTAssertEqual(AtriaBLEManager.activeJournalUnpersistedTailCount(
            currentSampleCount: 99,
            checkpointSourceSampleCount: 100
        ), 0)
    }

    func testForcedCheckpointIntentCannotBeDowngradedWhileWriterIsInFlight() {
        XCTAssertTrue(AtriaBLEManager.mergedActiveJournalForcedIntent(
            pendingForced: false,
            requestedForce: true
        ))
        XCTAssertTrue(AtriaBLEManager.mergedActiveJournalForcedIntent(
            pendingForced: true,
            requestedForce: false
        ))
        XCTAssertFalse(AtriaBLEManager.mergedActiveJournalForcedIntent(
            pendingForced: false,
            requestedForce: false
        ))
    }
}
