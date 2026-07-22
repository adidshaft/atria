import XCTest
@testable import Atria

final class AtriaBLEOrderedCallbackBufferTests: XCTestCase {
    func testOutOfOrderTaskArrivalReplaysDelegateOrder() {
        var buffer = AtriaBLEOrderedCallbackBuffer<String>()

        XCTAssertTrue(buffer.enqueue(ticket: 2, element: "history-data").isEmpty)
        XCTAssertEqual(buffer.enqueue(ticket: 1, element: "history-end"),
                       ["history-end", "history-data"])
        XCTAssertEqual(buffer.nextExpectedTicket, 3)
    }

    func testDuplicateAndStaleTicketsCannotReplayCallbacks() {
        var buffer = AtriaBLEOrderedCallbackBuffer<Int>()

        XCTAssertEqual(buffer.enqueue(ticket: 1, element: 10), [10])
        XCTAssertTrue(buffer.enqueue(ticket: 1, element: 11).isEmpty)
        XCTAssertTrue(buffer.enqueue(ticket: 3, element: 30).isEmpty)
        XCTAssertTrue(buffer.enqueue(ticket: 3, element: 31).isEmpty)
        XCTAssertEqual(buffer.enqueue(ticket: 2, element: 20), [20, 30])
    }
}
