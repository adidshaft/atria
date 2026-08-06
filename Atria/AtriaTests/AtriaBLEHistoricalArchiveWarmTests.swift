import XCTest
@testable import Atria

final class AtriaBLEHistoricalArchiveWarmTests: XCTestCase {
    func testCompletedWarmupPassesImmediately() {
        let group = DispatchGroup()

        XCTAssertTrue(
            AtriaBLEManager.waitForHistoricalArchiveWarm(group, timeout: 0)
        )
    }

    func testIncompleteWarmupTimesOutWithoutWaitingForever() {
        let group = DispatchGroup()
        group.enter()
        defer { group.leave() }

        XCTAssertFalse(
            AtriaBLEManager.waitForHistoricalArchiveWarm(group, timeout: 0)
        )
        XCTAssertEqual(AtriaBLEManager.historicalArchiveWarmReplayWaitLimit, 8)
    }
}
