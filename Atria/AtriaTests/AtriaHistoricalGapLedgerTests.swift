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

    func testRowsReceivedWhileGapIsOpenResolveOnlyAfterReconnectClosesIt() {
        withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 2_500)
            AtriaHistoricalGapLedger.beginGap(at: start,
                                              reason: "disconnect",
                                              defaults: defaults)
            for offset in [1.0, 16.0, 31.0] {
                let result = AtriaHistoricalGapLedger.recordMetricUsableRow(
                    at: start.addingTimeInterval(offset),
                    defaults: defaults
                )
                XCTAssertEqual(result.resolvedWindows, 0)
            }
            XCTAssertTrue(AtriaHistoricalGapLedger.hasOpenWindow(defaults: defaults))

            let close = AtriaHistoricalGapLedger.closeOpenGapWithResult(
                at: start.addingTimeInterval(60),
                defaults: defaults
            )
            XCTAssertTrue(close.closedWindow)
            XCTAssertEqual(close.resolvedWindows, 1)
            XCTAssertEqual(close.remainingWindows, 0)
        }
    }

    func testOpenGapRowsBeyondReconnectBoundaryArePrunedBeforeCoverageEvaluation() throws {
        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 2_700)
            AtriaHistoricalGapLedger.beginGap(at: start,
                                              reason: "disconnect",
                                              defaults: defaults)
            for offset in [61.0, 76.0, 91.0] {
                _ = AtriaHistoricalGapLedger.recordMetricUsableRow(
                    at: start.addingTimeInterval(offset),
                    defaults: defaults
                )
            }

            let close = AtriaHistoricalGapLedger.closeOpenGapWithResult(
                at: start.addingTimeInterval(60),
                defaults: defaults
            )
            XCTAssertTrue(close.closedWindow)
            XCTAssertEqual(close.resolvedWindows, 0)
            let window = try XCTUnwrap(AtriaHistoricalGapLedger.windows(defaults: defaults).first)
            XCTAssertEqual(window.coveredBucketIndexes, [])
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(for: window), 0)
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

    func testLedgerCompactsOldestWindowsWithoutForgettingUnresolvedHistory() throws {
        try withDefaults { defaults in
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
            let compacted = try XCTUnwrap(windows.first)
            XCTAssertEqual(compacted.reason, AtriaHistoricalGapLedger.coalescedWindowReason)
            XCTAssertEqual(compacted.start, origin,
                           "bounding the ledger must retain the oldest unresolved timestamp")
            XCTAssertEqual(compacted.end, origin.addingTimeInterval(8 * 120 + 30))
            XCTAssertEqual(compacted.coveredBucketIndexes, [],
                           "coverage from differently-based windows cannot survive compaction")
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(for: compacted), 0)
            XCTAssertEqual(windows.last?.reason, "gap_23")
            XCTAssertTrue(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))
        }
    }

    func testRepeatedCompactionKeepsOriginalOldestBoundary() throws {
        try withDefaults { defaults in
            let origin = Date(timeIntervalSince1970: 40_000)
            for index in 0..<(AtriaHistoricalGapLedger.maximumWindows * 3) {
                let start = origin.addingTimeInterval(TimeInterval(index * 60))
                AtriaHistoricalGapLedger.recordObservedGap(
                    start: start,
                    end: start.addingTimeInterval(20),
                    reason: "gap_\(index)",
                    defaults: defaults
                )
            }
            let windows = AtriaHistoricalGapLedger.windows(defaults: defaults)
            XCTAssertEqual(windows.count, AtriaHistoricalGapLedger.maximumWindows)
            let compacted = try XCTUnwrap(windows.first)
            XCTAssertEqual(compacted.start, origin)
            XCTAssertEqual(compacted.reason, AtriaHistoricalGapLedger.coalescedWindowReason)
            XCTAssertEqual(compacted.coveredBucketIndexes, [])
        }
    }

    func testDurableContinuityAnchorRecoversProcessRestoreGapWithoutInventingCoverage() throws {
        try withDefaults { defaults in
            let first = Date(timeIntervalSince1970: 10_000)
            XCTAssertTrue(AtriaHistoricalGapLedger.advanceLiveContinuityAnchor(
                to: first,
                defaults: defaults
            ))
            XCTAssertFalse(AtriaHistoricalGapLedger.advanceLiveContinuityAnchor(
                to: first.addingTimeInterval(5),
                defaults: defaults
            ), "the anchor write cadence must remain bounded")

            let restoredPulse = first.addingTimeInterval(95)
            XCTAssertTrue(AtriaHistoricalGapLedger.recordRestorationGapIfNeeded(
                firstAcceptedAt: restoredPulse,
                reason: "process_restore",
                defaults: defaults
            ))

            let window = try XCTUnwrap(AtriaHistoricalGapLedger.windows(defaults: defaults).first)
            XCTAssertEqual(window.start, first.addingTimeInterval(
                AtriaHistoricalGapLedger.liveContinuityAnchorWriteInterval
            ))
            XCTAssertEqual(window.end, restoredPulse)
            XCTAssertEqual(window.coveredBucketIndexes, [],
                           "a durable timestamp is not historical metric evidence")
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(for: window), 0)
            XCTAssertEqual(AtriaHistoricalGapLedger.liveContinuityAnchor(
                defaults: defaults,
                now: restoredPulse
            ), restoredPulse)
        }
    }

    func testRestorationAnchorFailsClosedForOpenFutureAndExpiredRanges() {
        withDefaults { defaults in
            let now = Date(timeIntervalSince1970: 20_000)

            defaults.set(now.addingTimeInterval(60).timeIntervalSince1970,
                         forKey: AtriaHistoricalGapLedger.liveContinuityAnchorKey)
            XCTAssertFalse(AtriaHistoricalGapLedger.recordRestorationGapIfNeeded(
                firstAcceptedAt: now,
                reason: "future_anchor",
                defaults: defaults
            ))
            XCTAssertFalse(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))

            defaults.set(now.addingTimeInterval(-19 * 60 * 60).timeIntervalSince1970,
                         forKey: AtriaHistoricalGapLedger.liveContinuityAnchorKey)
            XCTAssertFalse(AtriaHistoricalGapLedger.recordRestorationGapIfNeeded(
                firstAcceptedAt: now,
                reason: "expired_anchor",
                defaults: defaults
            ))
            XCTAssertFalse(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))

            let openStart = now.addingTimeInterval(-120)
            AtriaHistoricalGapLedger.beginGap(at: openStart,
                                              reason: "disconnect",
                                              defaults: defaults)
            defaults.set(openStart.timeIntervalSince1970,
                         forKey: AtriaHistoricalGapLedger.liveContinuityAnchorKey)
            XCTAssertFalse(AtriaHistoricalGapLedger.recordRestorationGapIfNeeded(
                firstAcceptedAt: now,
                reason: "must_not_duplicate_open_gap",
                defaults: defaults
            ))
            XCTAssertEqual(AtriaHistoricalGapLedger.windows(defaults: defaults).count, 1)
            XCTAssertTrue(AtriaHistoricalGapLedger.hasOpenWindow(defaults: defaults))
        }
    }

    func testAnchorWriteUncertaintyCannotTurnQuickRelaunchIntoFalseGap() {
        withDefaults { defaults in
            let durablePulse = Date(timeIntervalSince1970: 25_000)
            AtriaHistoricalGapLedger.advanceLiveContinuityAnchor(to: durablePulse,
                                                                 defaults: defaults)
            XCTAssertFalse(AtriaHistoricalGapLedger.recordRestorationGapIfNeeded(
                firstAcceptedAt: durablePulse.addingTimeInterval(25),
                reason: "quick_process_restore",
                defaults: defaults
            ))
            XCTAssertFalse(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))
        }
    }

    func testZeroContactAnchorClearPreventsFalseOffWristRecovery() {
        withDefaults { defaults in
            let timestamp = Date(timeIntervalSince1970: 30_000)
            AtriaHistoricalGapLedger.advanceLiveContinuityAnchor(to: timestamp,
                                                                 defaults: defaults)
            AtriaHistoricalGapLedger.clearLiveContinuityAnchor(defaults: defaults)
            XCTAssertNil(AtriaHistoricalGapLedger.liveContinuityAnchor(
                defaults: defaults,
                now: timestamp.addingTimeInterval(3_600)
            ))
            XCTAssertFalse(AtriaHistoricalGapLedger.recordRestorationGapIfNeeded(
                firstAcceptedAt: timestamp.addingTimeInterval(3_600),
                reason: "off_wrist",
                defaults: defaults
            ))
        }
    }
}
