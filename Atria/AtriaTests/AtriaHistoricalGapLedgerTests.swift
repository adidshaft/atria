import XCTest
@testable import Atria

final class AtriaHistoricalGapLedgerTests: XCTestCase {
    func testProductionRecoveryRequiresAtLeastNinetyPercentDensity() {
        XCTAssertEqual(AtriaHistoricalGapLedger.minimumResolvedDensityPercent, 90)
        XCTAssertEqual(
            AtriaHistoricalFullDrainCoveragePolicy.Configuration.production
                .minimumDensityPercent,
            90
        )
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "AtriaHistoricalGapLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            AtriaHistoricalGapLedger.resetStorageForTesting(defaults: defaults)
            defaults.removePersistentDomain(forName: suite)
        }
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

    func testSparseBucketOccupancyCannotResolveWindowButDenseOneHertzCan() {
        withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 2_000)
            AtriaHistoricalGapLedger.recordObservedGap(start: start,
                                                       end: start.addingTimeInterval(60),
                                                       reason: "silent_link",
                                                       defaults: defaults)

            var result = AtriaHistoricalGapLedger.recordMetricUsableRows(
                at: stride(from: 0.0, to: 60.0, by: 15).map {
                    start.addingTimeInterval($0)
                },
                defaults: defaults
            )
            XCTAssertEqual(result.resolvedWindows, 0)
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(
                for: AtriaHistoricalGapLedger.windows(defaults: defaults)[0]
            ), 6)
            let sparse = AtriaHistoricalGapLedger.continuity(
                for: AtriaHistoricalGapLedger.windows(defaults: defaults)[0]
            )
            XCTAssertFalse(sparse.continuous)
            XCTAssertEqual(sparse.maximumGapSeconds, 15)

            result = AtriaHistoricalGapLedger.recordMetricUsableRows(
                at: (0..<60).map { start.addingTimeInterval(Double($0)) },
                defaults: defaults
            )
            XCTAssertEqual(result.resolvedWindows, 1)
            XCTAssertFalse(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))
        }
    }

    func testDenseCoverageAllowsRareIsolatedLossButRejectsRepeatedCadenceHoles() throws {
        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 2_200)
            let end = start.addingTimeInterval(120)
            AtriaHistoricalGapLedger.recordObservedGap(start: start,
                                                       end: end,
                                                       reason: "isolated_loss",
                                                       defaults: defaults)
            let isolatedLoss = (0..<120).filter { ![30, 75].contains($0) }
            var result = AtriaHistoricalGapLedger.recordMetricUsableRows(
                at: isolatedLoss.map { start.addingTimeInterval(Double($0)) },
                defaults: defaults
            )
            XCTAssertEqual(result.resolvedWindows, 1)

            AtriaHistoricalGapLedger.recordObservedGap(start: start,
                                                       end: end,
                                                       reason: "repeated_holes",
                                                       defaults: defaults)
            let repeatedHoles = (0..<120).filter { $0 % 10 != 0 }
            result = AtriaHistoricalGapLedger.recordMetricUsableRows(
                at: repeatedHoles.map { start.addingTimeInterval(Double($0)) },
                defaults: defaults
            )
            XCTAssertEqual(result.resolvedWindows, 0)
            let window = try XCTUnwrap(AtriaHistoricalGapLedger.windows(defaults: defaults).first)
            let continuity = AtriaHistoricalGapLedger.continuity(for: window)
            XCTAssertEqual(continuity.densityPercent, 90)
            XCTAssertEqual(continuity.maximumGapSeconds, 2)
            XCTAssertEqual(continuity.p95GapSeconds, 2)
            XCTAssertFalse(continuity.continuous)
        }
    }

    func testLegacyBucketOnlyCoverageDecodesButCannotAuthorizeRecovery() throws {
        struct LegacyWindow: Codable {
            let id: UUID
            let start: Date
            let end: Date
            let reason: String
            let coveredBucketIndexes: [Int]
        }

        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 2_400)
            let legacy = LegacyWindow(id: UUID(),
                                      start: start,
                                      end: start.addingTimeInterval(60),
                                      reason: "legacy_sparse",
                                      coveredBucketIndexes: [0, 1, 2, 3])
            defaults.set(try JSONEncoder().encode([legacy]),
                         forKey: AtriaHistoricalGapLedger.defaultsKey)
            let window = try XCTUnwrap(AtriaHistoricalGapLedger.windows(
                defaults: defaults
            ).first)
            XCTAssertNil(window.coveredSecondBits)
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(for: window), 0)
            XCTAssertFalse(AtriaHistoricalGapLedger.continuity(for: window).continuous)
        }
    }

    func testMalformedCompactCoverageKeepsWindowPendingAndFailsClosed() throws {
        struct MalformedWindow: Codable {
            let id: UUID
            let start: Date
            let end: Date
            let reason: String
            let coveredSecondBitsBase64: String
        }

        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 2_425)
            let malformed = MalformedWindow(
                id: UUID(),
                start: start,
                end: start.addingTimeInterval(60),
                reason: "corrupt_compact_evidence",
                coveredSecondBitsBase64: "%%%not-base64%%%"
            )
            defaults.set(try JSONEncoder().encode([malformed]),
                         forKey: AtriaHistoricalGapLedger.defaultsKey)

            let window = try XCTUnwrap(AtriaHistoricalGapLedger.windows(
                defaults: defaults
            ).first)
            XCTAssertNil(window.coveredSecondBits)
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(for: window), 0)
            XCTAssertTrue(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))
        }
    }

    func testOneDayOpenGapCoverageUsesExactlyOneBitPerSecond() throws {
        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 2_450)
            AtriaHistoricalGapLedger.beginGap(at: start,
                                              reason: "bounded_state",
                                              defaults: defaults)
            let seconds = 24 * 60 * 60
            let result = AtriaHistoricalGapLedger.recordMetricUsableRows(
                at: (0..<seconds).map { start.addingTimeInterval(Double($0)) },
                defaults: defaults
            )
            XCTAssertEqual(result.resolvedWindows, 0)
            let window = try XCTUnwrap(AtriaHistoricalGapLedger.windows(
                defaults: defaults
            ).first)
            XCTAssertEqual(window.coveredSecondBits?.count, seconds / 8)
            let encoded = try Data(contentsOf:
                AtriaHistoricalGapLedger.durableStateURLForTesting(defaults: defaults))
            XCTAssertLessThan(encoded.count, 16_000)
            let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            XCTAssertTrue(json.contains("coveredSecondBitsBase64"))
            XCTAssertFalse(json.contains("coveredSecondBits\":["),
                           "one-byte-per-JSON-number encoding would double ledger storage")
        }
    }

    func testRowsReceivedWhileGapIsOpenResolveOnlyAfterReconnectClosesIt() {
        withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 2_500)
            AtriaHistoricalGapLedger.beginGap(at: start,
                                              reason: "disconnect",
                                              defaults: defaults)
            let result = AtriaHistoricalGapLedger.recordMetricUsableRows(
                at: (0..<60).map { start.addingTimeInterval(Double($0)) },
                defaults: defaults
            )
            XCTAssertEqual(result.resolvedWindows, 0)
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
            XCTAssertNil(window.coveredSecondBits)
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

    func testRecoveryCandidateRequiresClosedGapAndBindsLedgerSnapshot() throws {
        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 3_500)
            AtriaHistoricalGapLedger.beginGap(at: start,
                                              reason: "open",
                                              defaults: defaults)
            XCTAssertNil(AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate(
                defaults: defaults
            ))
            XCTAssertTrue(AtriaHistoricalGapLedger.closeOpenGap(
                at: start.addingTimeInterval(60),
                defaults: defaults
            ))
            let candidate = try XCTUnwrap(
                AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate(
                    defaults: defaults
                )
            )
            XCTAssertEqual(candidate.window.start, start)
            XCTAssertGreaterThan(candidate.ledgerGeneration, 0)
            XCTAssertEqual(candidate.ledgerSnapshotSHA256.count, 64)
        }
    }

    func testStagedDenseRowsRemainPendingUntilExplicitConsumerSettlement() throws {
        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 3_700)
            AtriaHistoricalGapLedger.recordObservedGap(
                start: start,
                end: start.addingTimeInterval(60),
                reason: "disconnect",
                defaults: defaults
            )
            let candidate = try XCTUnwrap(
                AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate(
                    defaults: defaults
                )
            )
            let staged = AtriaHistoricalGapLedger.stageMetricUsableRows(
                at: (0..<60).map { start.addingTimeInterval(Double($0)) },
                forWindowID: candidate.window.id,
                defaults: defaults
            )
            XCTAssertEqual(staged.resolvedWindows, 1)
            XCTAssertTrue(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults),
                          "positive coverage cannot outrun terminal consumers")
            XCTAssertTrue(AtriaHistoricalGapLedger.commitResolvedWindow(
                id: candidate.window.id,
                defaults: defaults
            ))
            XCTAssertFalse(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))
        }
    }

    func testSelectedGapStagingDoesNotMutateOtherGapOrUseOutsideRows() throws {
        try withDefaults { defaults in
            let first = Date(timeIntervalSince1970: 4_000)
            let second = Date(timeIntervalSince1970: 5_000)
            AtriaHistoricalGapLedger.recordObservedGap(
                start: first,
                end: first.addingTimeInterval(60),
                reason: "first",
                defaults: defaults
            )
            AtriaHistoricalGapLedger.recordObservedGap(
                start: second,
                end: second.addingTimeInterval(60),
                reason: "second",
                defaults: defaults
            )
            let candidate = try XCTUnwrap(
                AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate(
                    defaults: defaults
                )
            )
            _ = AtriaHistoricalGapLedger.stageMetricUsableRows(
                at: (0..<60).map { second.addingTimeInterval(Double($0)) },
                forWindowID: candidate.window.id,
                defaults: defaults
            )
            let windows = AtriaHistoricalGapLedger.windows(defaults: defaults)
            XCTAssertEqual(windows.map { AtriaHistoricalGapLedger.coveragePercent(for: $0) },
                           [0, 0])
            XCTAssertFalse(AtriaHistoricalGapLedger.commitResolvedWindow(
                id: candidate.window.id,
                defaults: defaults
            ))
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
            XCTAssertNotNil(compacted.expectedSecondBits,
                            "compaction must retain the exact disjoint missing-time union")
            XCTAssertNil(compacted.coveredSecondBits,
                           "no metric coverage was recorded for the compacted gaps")
            XCTAssertEqual(AtriaHistoricalGapLedger.continuity(for: compacted).expectedSeconds,
                           9 * 30,
                           "the six live minutes between gaps must not become missing time")
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(for: compacted), 0)
            XCTAssertEqual(windows.last?.reason, "gap_23")
            XCTAssertTrue(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))

            let liveOnlyRows = (0..<(8 * 120 + 30)).filter { offset in
                (offset % 120) >= 30
            }.map { origin.addingTimeInterval(Double($0)) }
            let liveOnly = AtriaHistoricalGapLedger.stageMetricUsableRows(
                at: liveOnlyRows,
                forWindowID: compacted.id,
                defaults: defaults
            )
            XCTAssertEqual(liveOnly.matchedWindows, 0,
                           "rows from intervening live spans are not gap coverage")

            let missingRows = (0..<9).flatMap { gap in
                (0..<30).map { second in
                    origin.addingTimeInterval(Double(gap * 120 + second))
                }
            }
            let recovered = AtriaHistoricalGapLedger.stageMetricUsableRows(
                at: missingRows,
                forWindowID: compacted.id,
                defaults: defaults
            )
            XCTAssertEqual(recovered.resolvedWindows, 1)
            let staged = try XCTUnwrap(AtriaHistoricalGapLedger.windows(
                defaults: defaults
            ).first(where: { $0.id == compacted.id }))
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(for: staged), 100)
            XCTAssertTrue(AtriaHistoricalGapLedger.continuity(for: staged).continuous)
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
            XCTAssertNotNil(compacted.expectedSecondBits)
            XCTAssertNil(compacted.coveredSecondBits)
            XCTAssertEqual(AtriaHistoricalGapLedger.continuity(for: compacted).expectedSeconds,
                           (AtriaHistoricalGapLedger.maximumWindows * 2 + 1) * 20)
        }
    }

    func testLegacyCoalescedEnvelopeFailsClosedUntilExactIntervalsAreMigrated() throws {
        struct LegacyCoalescedWindow: Codable {
            let id: UUID
            let start: Date
            let end: Date
            let reason: String
            let coveredSecondBitsBase64: String?
        }

        try withDefaults { defaults in
            let id = UUID()
            let origin = Date(timeIntervalSince1970: 70_000)
            let legacy = LegacyCoalescedWindow(
                id: id,
                start: origin,
                end: origin.addingTimeInterval(150),
                reason: AtriaHistoricalGapLedger.coalescedWindowReason,
                coveredSecondBitsBase64: nil
            )
            defaults.set(try JSONEncoder().encode([legacy]),
                         forKey: AtriaHistoricalGapLedger.defaultsKey)

            let ambiguous = try XCTUnwrap(AtriaHistoricalGapLedger.windows(
                defaults: defaults
            ).first)
            XCTAssertTrue(AtriaHistoricalGapLedger.isLegacyCoalescedWindow(ambiguous))
            XCTAssertFalse(AtriaHistoricalGapLedger.continuity(for: ambiguous).continuous)
            XCTAssertNil(AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate(
                defaults: defaults
            ), "an envelope that includes unknown live spans must not drive recovery")
            XCTAssertEqual(AtriaHistoricalGapLedger.recordMetricUsableRows(
                at: (0..<150).map { origin.addingTimeInterval(Double($0)) },
                defaults: defaults
            ).matchedWindows, 0)

            XCTAssertTrue(AtriaHistoricalGapLedger.migrateLegacyCoalescedWindow(
                id: id,
                exactIntervals: [
                    (origin, origin.addingTimeInterval(30), "migrated_0"),
                    (origin.addingTimeInterval(120),
                     origin.addingTimeInterval(150),
                     "migrated_1")
                ],
                defaults: defaults
            ))
            let migrated = AtriaHistoricalGapLedger.windows(defaults: defaults)
            XCTAssertEqual(migrated.count, 2)
            XCTAssertEqual(migrated.map { AtriaHistoricalGapLedger.continuity(for: $0)
                .expectedSeconds }, [30, 30])
            XCTAssertTrue(migrated.allSatisfy { !$0.reason.contains("coalesced") })
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
                to: first.addingTimeInterval(0.5),
                defaults: defaults
            ), "the anchor write cadence must remain bounded")

            let restoredPulse = first.addingTimeInterval(95)
            XCTAssertTrue(AtriaHistoricalGapLedger.recordRestorationGapIfNeeded(
                firstAcceptedAt: restoredPulse,
                reason: "process_restore",
                defaults: defaults
            ))

            let window = try XCTUnwrap(AtriaHistoricalGapLedger.windows(defaults: defaults).first)
            XCTAssertEqual(window.start, first)
            XCTAssertEqual(window.end, restoredPulse)
            XCTAssertNil(window.coveredSecondBits,
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

            AtriaHistoricalGapLedger.clearLiveContinuityAnchor(defaults: defaults)
            defaults.set(now.addingTimeInterval(-14 * 24 * 60 * 60).timeIntervalSince1970,
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
            AtriaHistoricalGapLedger.clearLiveContinuityAnchor(defaults: defaults)
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

    func testShortRelaunchGapRetainsTheActualDurableBoundary() throws {
        try withDefaults { defaults in
            let durablePulse = Date(timeIntervalSince1970: 25_000)
            AtriaHistoricalGapLedger.advanceLiveContinuityAnchor(to: durablePulse,
                                                                 defaults: defaults)
            XCTAssertTrue(AtriaHistoricalGapLedger.recordRestorationGapIfNeeded(
                firstAcceptedAt: durablePulse.addingTimeInterval(25),
                reason: "quick_process_restore",
                defaults: defaults
            ))
            let gap = try XCTUnwrap(AtriaHistoricalGapLedger.windows(defaults: defaults).first)
            XCTAssertEqual(gap.start, durablePulse)
            XCTAssertEqual(gap.end, durablePulse.addingTimeInterval(25))
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

    func testLegacyDefaultsMigratesOnlyAfterAtomicFileVerification() throws {
        struct LegacyWindow: Codable {
            let id: UUID
            let start: Date
            let end: Date
            let reason: String
        }

        try withDefaults { defaults in
            let legacy = LegacyWindow(id: UUID(),
                                      start: Date(timeIntervalSince1970: 40_000),
                                      end: Date(timeIntervalSince1970: 40_060),
                                      reason: "legacy_pending")
            defaults.set(try JSONEncoder().encode([legacy]),
                         forKey: AtriaHistoricalGapLedger.defaultsKey)
            defaults.set(7, forKey: AtriaHistoricalGapLedger.generationKey)

            let migrated = AtriaHistoricalGapLedger.windows(defaults: defaults)
            XCTAssertEqual(migrated.map(\.id), [legacy.id])
            XCTAssertNil(defaults.data(forKey: AtriaHistoricalGapLedger.defaultsKey))
            let durable = try Data(contentsOf:
                AtriaHistoricalGapLedger.durableStateURLForTesting(defaults: defaults))
            XCTAssertFalse(durable.isEmpty)
            XCTAssertEqual(AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate(
                defaults: defaults
            )?.ledgerGeneration, 7)
        }
    }

    func testWholeLedgerCorruptionNeverDecodesAsNoPendingGap() throws {
        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 50_000)
            XCTAssertTrue(AtriaHistoricalGapLedger.recordObservedGap(
                start: start,
                end: start.addingTimeInterval(60),
                reason: "must_survive_corruption",
                defaults: defaults
            ))
            // Corrupt both generations so backup recovery is unavailable.
            let invalid = Data("not-json".utf8)
            try invalid.write(to:
                AtriaHistoricalGapLedger.durableStateURLForTesting(defaults: defaults))
            try invalid.write(to:
                AtriaHistoricalGapLedger.durableBackupURLForTesting(defaults: defaults))

            let quarantined = AtriaHistoricalGapLedger.windows(defaults: defaults)
            XCTAssertEqual(quarantined.count, 1)
            XCTAssertTrue(quarantined[0].reason.hasPrefix("durable_gap_ledger_corrupt_"))
            XCTAssertTrue(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))
            XCTAssertNil(AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate(
                defaults: defaults
            ))
        }
    }

    func testCorruptSentinelCannotBeClosedOrEvaluatedAsSyntheticCoverage() throws {
        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 55_000)
            XCTAssertTrue(AtriaHistoricalGapLedger.recordObservedGap(
                start: start,
                end: start.addingTimeInterval(60),
                reason: "primary",
                defaults: defaults
            ))
            XCTAssertTrue(AtriaHistoricalGapLedger.recordObservedGap(
                start: start.addingTimeInterval(120),
                end: start.addingTimeInterval(180),
                reason: "creates_backup",
                defaults: defaults
            ))
            let invalid = Data("corrupt-primary-and-backup".utf8)
            try invalid.write(to:
                AtriaHistoricalGapLedger.durableStateURLForTesting(defaults: defaults))
            try invalid.write(to:
                AtriaHistoricalGapLedger.durableBackupURLForTesting(defaults: defaults))

            let sentinel = try XCTUnwrap(
                AtriaHistoricalGapLedger.windows(defaults: defaults).first
            )
            var syntheticClosed = sentinel
            syntheticClosed.end = Date(timeIntervalSince1970: 1_800_000_000)
            XCTAssertFalse(AtriaHistoricalGapLedger.continuity(
                for: syntheticClosed
            ).continuous)
            let close = AtriaHistoricalGapLedger.closeOpenGapWithResult(
                at: Date(timeIntervalSince1970: 1_800_000_000),
                defaults: defaults
            )
            XCTAssertFalse(close.closedWindow)
            XCTAssertEqual(close.remainingWindows, 1)
            XCTAssertFalse(AtriaHistoricalGapLedger.durableStateIsValid(
                defaults: defaults
            ))
            XCTAssertTrue(AtriaHistoricalGapLedger.windows(defaults: defaults)[0]
                .reason.hasPrefix("durable_gap_ledger_corrupt_"))
        }
    }

    func testCorruptPrimaryRestoresLastFsyncedBackup() throws {
        try withDefaults { defaults in
            let first = Date(timeIntervalSince1970: 60_000)
            XCTAssertTrue(AtriaHistoricalGapLedger.recordObservedGap(
                start: first,
                end: first.addingTimeInterval(60),
                reason: "first",
                defaults: defaults
            ))
            XCTAssertTrue(AtriaHistoricalGapLedger.recordObservedGap(
                start: first.addingTimeInterval(120),
                end: first.addingTimeInterval(180),
                reason: "second",
                defaults: defaults
            ))
            try Data("torn-primary".utf8).write(to:
                AtriaHistoricalGapLedger.durableStateURLForTesting(defaults: defaults))

            let restored = AtriaHistoricalGapLedger.windows(defaults: defaults)
            XCTAssertEqual(restored.count, 1)
            XCTAssertEqual(restored[0].reason, "first")
            XCTAssertTrue(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))
        }
    }

    func testResolvedCASIsDurablyAbsentOnImmediateReread() throws {
        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 70_000)
            XCTAssertTrue(AtriaHistoricalGapLedger.recordObservedGap(
                start: start,
                end: start.addingTimeInterval(30),
                reason: "durable_cas",
                defaults: defaults
            ))
            let candidate = try XCTUnwrap(
                AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate(defaults: defaults)
            )
            _ = AtriaHistoricalGapLedger.stageMetricUsableRows(
                at: (0..<30).map { start.addingTimeInterval(Double($0)) },
                forWindowID: candidate.window.id,
                defaults: defaults
            )
            XCTAssertTrue(AtriaHistoricalGapLedger.commitResolvedWindow(
                candidate: candidate,
                defaults: defaults
            ))
            XCTAssertTrue(AtriaHistoricalGapLedger.windows(defaults: defaults).isEmpty)
            XCTAssertNil(AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate(
                defaults: defaults
            ))
        }
    }

    func testResolvedCandidateRejectsNewContainedOutageInSameEnvelope() throws {
        try withDefaults { defaults in
            let start = Date(timeIntervalSince1970: 75_000)
            var expected = Data(repeating: 0, count: 4)
            for second in (0..<10).map({ $0 }) + (20..<30).map({ $0 }) {
                expected[second / 8] |= UInt8(1 << (second % 8))
            }
            let original = AtriaHistoricalGapLedger.Window(
                start: start,
                end: start.addingTimeInterval(30),
                reason: AtriaHistoricalGapLedger.coalescedWindowReason,
                expectedSecondBits: expected
            )
            defaults.set(try JSONEncoder().encode([original]),
                         forKey: AtriaHistoricalGapLedger.defaultsKey)
            let candidate = try XCTUnwrap(
                AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate(defaults: defaults)
            )
            _ = AtriaHistoricalGapLedger.stageMetricUsableRows(
                at: ((0..<10).map { start.addingTimeInterval(Double($0)) }
                    + (20..<30).map { start.addingTimeInterval(Double($0)) }),
                forWindowID: candidate.window.id,
                defaults: defaults
            )

            XCTAssertTrue(AtriaHistoricalGapLedger.recordObservedGap(
                start: start.addingTimeInterval(10),
                end: start.addingTimeInterval(20),
                reason: "contained_new_outage",
                minimumDuration: 0,
                defaults: defaults
            ))
            _ = AtriaHistoricalGapLedger.stageMetricUsableRows(
                at: (10..<20).map { start.addingTimeInterval(Double($0)) },
                forWindowID: candidate.window.id,
                defaults: defaults
            )
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(
                for: try XCTUnwrap(AtriaHistoricalGapLedger.windows(
                    defaults: defaults
                ).first)
            ), 100)
            XCTAssertFalse(AtriaHistoricalGapLedger.commitResolvedWindow(
                candidate: candidate,
                defaults: defaults
            ))
            XCTAssertTrue(AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults))
        }
    }

    func testConcurrentGapAndCoverageTransactionsDoNotLoseEitherUpdate() throws {
        try withDefaults { defaults in
            let base = Date(timeIntervalSince1970: 77_000)
            XCTAssertTrue(AtriaHistoricalGapLedger.recordObservedGap(
                start: base,
                end: base.addingTimeInterval(60),
                reason: "coverage_target",
                defaults: defaults
            ))
            let target = try XCTUnwrap(
                AtriaHistoricalGapLedger.oldestClosedRecoveryCandidate(defaults: defaults)
            )
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "gap-ledger-rmw", attributes: .concurrent)
            for batch in 0..<6 {
                group.enter()
                queue.async {
                    _ = AtriaHistoricalGapLedger.stageMetricUsableRows(
                        at: (0..<10).map {
                            base.addingTimeInterval(Double(batch * 10 + $0))
                        },
                        forWindowID: target.window.id,
                        defaults: defaults
                    )
                    group.leave()
                }
                group.enter()
                queue.async {
                    let gapStart = base.addingTimeInterval(Double(120 + batch * 30))
                    _ = AtriaHistoricalGapLedger.recordObservedGap(
                        start: gapStart,
                        end: gapStart.addingTimeInterval(20),
                        reason: "concurrent_\(batch)",
                        minimumDuration: 0,
                        defaults: defaults
                    )
                    group.leave()
                }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
            let windows = AtriaHistoricalGapLedger.windows(defaults: defaults)
            XCTAssertEqual(windows.count, 7)
            let retained = try XCTUnwrap(windows.first { $0.id == target.window.id })
            XCTAssertEqual(AtriaHistoricalGapLedger.coveragePercent(for: retained), 100)
            for batch in 0..<6 {
                XCTAssertTrue(windows.contains {
                    $0.reason == "concurrent_\(batch)"
                })
            }
        }
    }

    func testShortGapAndAnchorSurviveIndependentDefaultsRelaunch() throws {
        let suite = "AtriaHistoricalGapLedgerTests.relaunch.\(UUID().uuidString)"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            AtriaHistoricalGapLedger.resetStorageForTesting(defaults: firstDefaults)
            firstDefaults.removePersistentDomain(forName: suite)
        }
        let lastPulse = Date(timeIntervalSince1970: 80_000)
        XCTAssertTrue(AtriaHistoricalGapLedger.advanceLiveContinuityAnchor(
            to: lastPulse,
            defaults: firstDefaults
        ))

        let relaunchedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(AtriaHistoricalGapLedger.liveContinuityAnchor(
            defaults: relaunchedDefaults,
            now: lastPulse.addingTimeInterval(40)
        ), lastPulse)
        XCTAssertTrue(AtriaHistoricalGapLedger.recordRestorationGapIfNeeded(
            firstAcceptedAt: lastPulse.addingTimeInterval(40),
            reason: "process_kill_restore",
            defaults: relaunchedDefaults
        ))
        let restored = try XCTUnwrap(AtriaHistoricalGapLedger.windows(
            defaults: relaunchedDefaults
        ).first)
        XCTAssertEqual(restored.start, lastPulse)
        XCTAssertEqual(restored.end, lastPulse.addingTimeInterval(40))
    }
}
