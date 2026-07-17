import XCTest
@testable import Atria

@MainActor
final class AtriaDefaultCoalescingTests: XCTestCase {
    func testWrappedWriteRefreshesOnlyBoxesForItsKey() throws {
        let suiteName = "AtriaDefaultKeyedTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let first = AtriaDefaultBox<Int>(key: "target", fallback: 0, store: store)
        let second = AtriaDefaultBox<Int>(key: "target", fallback: 0, store: store)
        let unrelated = AtriaDefaultBox<Int>(key: "unrelated", fallback: 0, store: store)
        let center = AtriaDefaultChangeCenter.center(for: store)
        let initialBroadPasses = center.refreshPassCount
        let initialKeyedPasses = center.keyedRefreshPassCount

        store.set(7, forKey: "unrelated")
        first.set(42)

        XCTAssertEqual(first.value, 42)
        XCTAssertEqual(second.value, 42)
        XCTAssertEqual(unrelated.value, 0)
        XCTAssertEqual(center.keyedRefreshPassCount, initialKeyedPasses + 1)
        XCTAssertEqual(center.refreshPassCount, initialBroadPasses)
    }

    func testRapidExternalWritesCoalesceIntoOneBroadRefreshPass() async throws {
        let suiteName = "AtriaDefaultCoalescingTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let key = "atria.test.coalesced"
        let first = AtriaDefaultBox<Int>(key: key, fallback: 0, store: store)
        let second = AtriaDefaultBox<Int>(key: key, fallback: 0, store: store)
        let center = AtriaDefaultChangeCenter.center(for: store)
        let initialPasses = center.refreshPassCount

        for value in 1...20 {
            store.set(value, forKey: key)
        }
        await Task.yield()
        center.flushPendingExternalRefreshForTesting()

        XCTAssertEqual(first.value, 20)
        XCTAssertEqual(second.value, 20)
        XCTAssertEqual(center.refreshPassCount, initialPasses + 1)
    }

    func testExternalRefreshWindowExceedsBLEPersistenceCadence() {
        XCTAssertGreaterThanOrEqual(
            AtriaDefaultChangeCenter.externalRefreshInterval,
            Duration.seconds(2.5)
        )
    }
}
