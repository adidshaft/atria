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

    /// Regression for the 2026-08-10 P0 deadlock: an off-main defaults write
    /// (a BLE callback persisting a diagnostic) must not synchronously wait for
    /// MainActor. With the previous `queue: .main` observer, the background
    /// writer blocked until the main thread drained its main queue; while
    /// MainActor was itself blocked inside `centralEventFence.retire`'s
    /// `delegateQueue.sync`, that lock inversion is what iOS killed with
    /// 0x8BADF00D. The `queue: nil` observer runs on the posting thread and only
    /// hops the coalesced refresh onto MainActor, so the writer returns at once.
    func testBackgroundDefaultsWriteDoesNotBlockOnBusyMainActor() async throws {
        let suiteName = "AtriaDefaultDeadlockTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let key = "atria.test.ble.diagnostic"
        let box = AtriaDefaultBox<Int>(key: key, fallback: 0, store: store)
        let center = AtriaDefaultChangeCenter.center(for: store)

        let bleQueue = DispatchQueue(
            label: "com.adidshaft.atria.tests.ble-central-like"
        )
        let writerReturned = DispatchSemaphore(value: 0)

        // A BLE-like serial background queue writes a diagnostics default,
        // posting `UserDefaults.didChangeNotification` off-main.
        bleQueue.async {
            store.set(99, forKey: key)
            writerReturned.signal()
        }

        // Stand in for the synchronous fence drain that owned MainActor during
        // the deadlock: block this main test thread with a BOUNDED wait. The
        // off-main writer must return well before it expires; the old
        // `queue: .main` observer times out here.
        XCTAssertEqual(
            writerReturned.wait(timeout: .now() + .milliseconds(250)),
            .success,
            "off-main defaults write must not wait for MainActor"
        )

        // Release MainActor, let the coalesced external refresh hop run, flush
        // it, and confirm the box observed the external value.
        for _ in 0..<20 where box.value != 99 {
            await Task.yield()
            center.flushPendingExternalRefreshForTesting()
        }
        XCTAssertEqual(box.value, 99)
    }

    /// A keyed (in-process) write refreshes only its own key and never leaves a
    /// pending broad pass, even after yielding MainActor and flushing. If the
    /// main-thread suppression were deferred and observed after
    /// `isPerformingKeyedWrite` reset, a broad pass would leak through here.
    func testKeyedWriteProducesNoBroadRefreshEvenAfterFlush() async throws {
        let suiteName = "AtriaDefaultKeyedFlushTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let box = AtriaDefaultBox<Int>(key: "target", fallback: 0, store: store)
        let center = AtriaDefaultChangeCenter.center(for: store)
        let initialBroad = center.refreshPassCount
        let initialKeyed = center.keyedRefreshPassCount

        box.set(11)

        XCTAssertEqual(box.value, 11)
        XCTAssertEqual(center.keyedRefreshPassCount, initialKeyed + 1)
        XCTAssertEqual(center.refreshPassCount, initialBroad)

        await Task.yield()
        center.flushPendingExternalRefreshForTesting()

        XCTAssertEqual(
            center.refreshPassCount,
            initialBroad,
            "a keyed write must not leave a pending broad refresh"
        )
        XCTAssertEqual(box.value, 11)
    }
}
