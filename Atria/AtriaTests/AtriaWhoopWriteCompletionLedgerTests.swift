import XCTest
@testable import Atria

final class AtriaWhoopWriteCompletionLedgerTests: XCTestCase {
    func testSecondWriteIsRejectedUntilFirstCallbackCompletes() {
        var ledger = AtriaWhoopWriteCompletionLedger()
        XCTAssertTrue(ledger.enqueue(sequence: 7, command: 0x03, payload: [0x00]))
        XCTAssertTrue(ledger.hasPendingWrite)
        XCTAssertFalse(ledger.enqueue(sequence: 8, command: 0x16, payload: [0x00]))

        XCTAssertEqual(ledger.completeNext(),
                       .init(sequence: 7, command: 0x03, payload: [0x00]))
        XCTAssertFalse(ledger.hasPendingWrite)
        XCTAssertTrue(ledger.enqueue(sequence: 8, command: 0x16, payload: [0x00]))
        XCTAssertEqual(ledger.completeNext(),
                       .init(sequence: 8, command: 0x16, payload: [0x00]))
    }

    func testResetDropsCallbacksFromPriorConnectionEpoch() {
        var ledger = AtriaWhoopWriteCompletionLedger()
        ledger.enqueue(sequence: 2, command: 0x17)
        ledger.reset()
        XCTAssertNil(ledger.completeNext())
    }
}
