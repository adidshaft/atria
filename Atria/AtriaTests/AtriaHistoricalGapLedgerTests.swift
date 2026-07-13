import XCTest
@testable import Atria

final class AtriaHistoricalGapLedgerTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "AtriaHistoricalGapLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testDisconnectWindowPersistsUntilFirstAcceptedHeartRateClosesIt() throws {
        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 1_000)
            XCTAssertTrue(AtriaHistoricalGapLedger.beginGap(at: start,
                                                            reason: "disconnect",
                                                            defaults: defaults))
            XCTAssertTrue(AtriaHistoricalGapLedger.hasOpenWindow(defaults: defaults))

            XCTAssertTrue(AtriaHistoricalGapLedger.closeOpenGap(
                at: start.addingTimeInterval(61),
                defaults: defaults
            ))
            let window = try XCTUnwrap(AtriaHistoricalGapLedger.windows(defaults: defaults).first)
            XCTAssertEqual(window.start, start)
            XCTAssertEqual(window.end, start.addingTimeInterval(61))
            XCTAssertFalse(AtriaHistoricalGapLedger.hasOpenWindow(defaults: defaults))
        }
    }

    func testShortReconnectTransitionIsNotPersistedAsMissingCoverage() {
        withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 1_000)
            AtriaHistoricalGapLedger.beginGap(at: start,
                                              reason: "disconnect",
                                              defaults: defaults)
            XCTAssertFalse(AtriaHistoricalGapLedger.closeOpenGap(
                at: start.addingTimeInterval(10),
                defaults: defaults
            ))
            XCTAssertFalse(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))
        }
    }

    func testOnlyMetricRowsCoveringSeventyFivePercentResolveWindow() {
        withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 2_000)
            AtriaHistoricalGapLedger.recordObservedGap(start: start,
                                                       end: start.addingTimeInterval(60),
                                                       reason: "silent_link",
                                                       defaults: defaults)

            var result = AtriaHistoricalGapLedger.recordMetricUsableRow(
                at: start.addingTimeInterval(1), defaults: defaults
            )
            XCTAssertEqual(result.resolvedWindows, 0)
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(
                for: AtriaHistoricalGapLedger.windows(defaults: defaults)[0]
            ), 25)

            // A replay duplicate in the same 15-second bucket adds no coverage.
            result = AtriaHistoricalGapLedger.recordMetricUsableRow(
                at: start.addingTimeInterval(2), defaults: defaults
            )
            XCTAssertEqual(result.resolvedWindows, 0)
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(
                for: AtriaHistoricalGapLedger.windows(defaults: defaults)[0]
            ), 25)

            _ = AtriaHistoricalGapLedger.recordMetricUsableRow(
                at: start.addingTimeInterval(16), defaults: defaults
            )
            result = AtriaHistoricalGapLedger.recordMetricUsableRow(
                at: start.addingTimeInterval(31), defaults: defaults
            )
            XCTAssertEqual(result.resolvedWindows, 1)
            XCTAssertFalse(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))
        }
    }

    func testRowsOutsideExactWindowCannotResolveIt() {
        withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 3_000)
            AtriaHistoricalGapLedger.recordObservedGap(start: start,
                                                       end: start.addingTimeInterval(60),
                                                       reason: "silent_link",
                                                       defaults: defaults)
            for offset in stride(from: 61.0, through: 180.0, by: 15) {
                let result = AtriaHistoricalGapLedger.recordMetricUsableRow(
                    at: start.addingTimeInterval(offset), defaults: defaults
                )
                XCTAssertEqual(result.matchedWindows, 0)
            }
            XCTAssertTrue(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(
                for: AtriaHistoricalGapLedger.windows(defaults: defaults)[0]
            ), 0)
        }
    }

    func testLedgerIsBoundedToNewestSixteenWindows() {
        withDefaults { defaults in
            let origin = Date(timeIntervalSince1970: 4_000)
            for index in 0..<24 {
                let start = origin.addingTimeInterval(TimeInterval(index * 120))
                AtriaHistoricalGapLedger.recordObservedGap(
                    start: start,
                    end: start.addingTimeInterval(30),
                    reason: "gap_\(index)",
                    defaults: defaults
                )
            }
            let windows = AtriaHistoricalGapLedger.windows(defaults: defaults)
            XCTAssertEqual(windows.count, AtriaHistoricalGapLedger.maximumWindows)
            XCTAssertEqual(windows.first?.reason, "gap_8")
            XCTAssertEqual(windows.last?.reason, "gap_23")
        }
    }
}
