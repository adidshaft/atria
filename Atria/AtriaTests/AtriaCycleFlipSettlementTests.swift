import XCTest
@testable import Atria

/// W3-A (2026-08-20): recovery settlement at the cycle flip.
///
/// A shifted-schedule sleeper confirms a sleep whose measured wake is still
/// minutes in the future (~19:15 daily on this device). Diagnosis: the save
/// path minted the frozen metric for YESTERDAY's wake day and nothing re-ran
/// the minter, so widgets/trend/HealthKit waited for the next launch while
/// only Home's provisional bridge stayed honest. The fix set:
///   P0-1  the save transaction arms the rollover timer at the confirmed
///         sleep's own end + 1s;
///   P0-2  the rollover handler settles the wake-day frozen metric when it is
///         missing or fails the exact three-way identity proof;
///   P0-3  a direct minter call inside the near-future window defers to a
///         one-shot retry at end + 1s instead of silently settling the
///         previous wake day.
/// The `completedBy: now` / `end <= now` honesty gates are never loosened —
/// every fix re-triggers the minter after its precondition becomes true; a
/// metric is never minted from an unfinished night.
final class AtriaCycleFlipSettlementTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Fixture anchors are post-2026-08-06 per repo rules (the host's
    /// persisted device-use journal contaminates earlier time-anchored
    /// windows).
    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: day, hour: hour, minute: minute
        ))!
    }

    private func confirmedSleep(
        id: String = "w3a-main-sleep",
        start: Date,
        end: Date,
        createdAt: Date? = nil,
        source: String = "manual_sleep",
        restingHR: Int = 52,
        hrv: Int? = 48,
        respiratoryRate: Double? = 15.2
    ) -> UserConfirmedSleep {
        let duration = end.timeIntervalSince(start)
        return UserConfirmedSleep(id: id,
                                  createdAt: createdAt ?? end,
                                  start: start,
                                  end: end,
                                  source: source,
                                  confidence: "manual_user_entered",
                                  sessions: 1,
                                  samples: 1_000,
                                  avgHR: 60,
                                  peakHR: 90,
                                  restingHR: restingHR,
                                  hrv: hrv,
                                  hrvWindowCount: 4,
                                  respiratoryRate: respiratoryRate,
                                  duration: duration,
                                  span: duration,
                                  reason: "fixture",
                                  motionSource: "manual",
                                  motionValidated: false,
                                  stageSegments: nil,
                                  eventTimeZoneIdentifier: "UTC")
    }

    private func profile() -> AthleteProfile {
        AthleteProfile(age: 35,
                       measuredMaxHR: 185,
                       maxHRSource: .measured,
                       biologicalSex: .male,
                       weightKg: 75,
                       heightCm: 178,
                       updated: nil,
                       hasCompletedOnboarding: true)
    }

    private func prepare(
        desired: [UserConfirmedSleep],
        now: Date
    ) -> SessionStore.ConfirmedSleepSavePreparation? {
        SessionStore.prepareConfirmedSleepSave(
            base: [],
            desired: desired,
            authoritativeCurrent: [],
            previous: [],
            dailyMetrics: [],
            baseNeedHours: 8,
            calendar: calendar,
            usesRecoveredRebase: false,
            rebuildsBaselineOffMain: false,
            baselineSessions: [],
            previousBaseline: PersonalBaseline(restingHR: nil, hrvEMA: nil),
            profile: profile(),
            preparationNow: now,
            shouldContinue: { true }
        )
    }

    // MARK: - P0-1: the save transaction arms the settlement edge

    /// The device-observed daily shape: confirm at ~19:15, measured wake at
    /// ~19:21 (end = now + 6 min). The prepared boundary must be the sleep's
    /// own end + 1s — not the no-sleep rollover a day out — so the existing
    /// rollover timer wakes right after the honesty gates become satisfiable.
    func testFutureEndConfirmArmsRolloverBoundaryAtSleepEndPlusOneSecond() throws {
        let now = date(day: 19, hour: 19, minute: 15)
        let end = now.addingTimeInterval(6 * 60)
        let sleep = confirmedSleep(
            start: end.addingTimeInterval(-6 * 3_600),
            end: end,
            createdAt: now
        )
        let preparation = try XCTUnwrap(prepare(desired: [sleep], now: now))
        XCTAssertEqual(
            preparation.nextRolloverBoundary,
            end.addingTimeInterval(1),
            "a future-end confirm must arm the settlement edge at its own end + 1s"
        )
    }

    /// A confirm whose wake is already in the past keeps today's behavior
    /// byte-identical: the boundary is exactly the shared kernel's next
    /// no-sleep rollover.
    func testCompletedEndKeepsNoSleepRolloverBoundaryUnchanged() throws {
        let now = date(day: 19, hour: 19, minute: 15)
        let end = now.addingTimeInterval(-3_600)
        let sleep = confirmedSleep(
            start: end.addingTimeInterval(-6 * 3_600),
            end: end,
            createdAt: end
        )
        let preparation = try XCTUnwrap(prepare(desired: [sleep], now: now))
        XCTAssertEqual(
            preparation.nextRolloverBoundary,
            AtriaPhysiologicalCycle.nextNoSleepRollover(
                now: now,
                confirmedSleeps: [sleep],
                calendar: calendar
            ),
            "a completed wake must not change the armed boundary"
        )
    }

    func testSettlementArmedRolloverBoundaryTakesTheEarlierEdge() {
        let now = date(day: 19, hour: 19, minute: 15)
        let futureEnd = now.addingTimeInterval(360)
        let distantRollover = now.addingTimeInterval(24 * 3_600)

        XCTAssertEqual(
            SessionStore.settlementArmedRolloverBoundary(
                noSleepRollover: distantRollover,
                newestSettledMainSleepEnd: futureEnd,
                preparationNow: now
            ),
            futureEnd.addingTimeInterval(1),
            "the settlement edge wins against a distant no-sleep boundary"
        )
        let earlierRollover = now.addingTimeInterval(120)
        XCTAssertEqual(
            SessionStore.settlementArmedRolloverBoundary(
                noSleepRollover: earlierRollover,
                newestSettledMainSleepEnd: futureEnd,
                preparationNow: now
            ),
            earlierRollover,
            "min(existing, end+1s): an earlier no-sleep boundary still fires first"
        )
        XCTAssertEqual(
            SessionStore.settlementArmedRolloverBoundary(
                noSleepRollover: nil,
                newestSettledMainSleepEnd: futureEnd,
                preparationNow: now
            ),
            futureEnd.addingTimeInterval(1),
            "with no no-sleep boundary the settlement edge stands alone"
        )
        XCTAssertEqual(
            SessionStore.settlementArmedRolloverBoundary(
                noSleepRollover: distantRollover,
                newestSettledMainSleepEnd: now.addingTimeInterval(-60),
                preparationNow: now
            ),
            distantRollover,
            "a completed end changes nothing"
        )
        XCTAssertEqual(
            SessionStore.settlementArmedRolloverBoundary(
                noSleepRollover: distantRollover,
                newestSettledMainSleepEnd: nil,
                preparationNow: now
            ),
            distantRollover
        )
    }

    // MARK: - P0-2: the rollover handler settles, not just refreshes steps

    /// The flip invokes the minter exactly when the wake-day frozen metric is
    /// missing or fails `deferredLaunchCardSettlementMatches`; a matching,
    /// already-settled day is left byte-identical.
    func testCycleRolloverSettlesWhenWakeDayMetricMissingAndSkipsWhenSettled() {
        let end = date(day: 19, hour: 19, minute: 21)
        let sleep = confirmedSleep(
            start: end.addingTimeInterval(-6 * 3_600),
            end: end,
            createdAt: end
        )
        XCTAssertTrue(
            SessionStore.cycleRolloverSettlementRequired(
                sleep: sleep,
                metric: nil,
                rollup: nil,
                calendar: calendar
            ),
            "a missing wake-day frozen metric must invoke the minter at the flip"
        )

        let day = calendar.startOfDay(for: sleep.end)
        let metric = SavedDailyMetric(day: day,
                                      recoveryPercent: 71,
                                      recoveryConfidence: "personal_baseline",
                                      hrv: sleep.hrv,
                                      restingHR: sleep.restingHR,
                                      respiratoryRate: sleep.respiratoryRate,
                                      sleepDuration: sleep.duration,
                                      sleepSpan: sleep.span,
                                      sleepStart: sleep.start,
                                      sleepEnd: sleep.end,
                                      sleepSource: sleep.source,
                                      sleepStageSegments: [],
                                      sleepConsistencyPercent: 84,
                                      strain: 3.4)
        let rollup = DailyRollupStoreEntry(day: day,
                                           recovery: 71,
                                           lnRMSSD: sleep.hrv.map { log(Double($0)) },
                                           rhr: sleep.restingHR,
                                           sleepSeconds: sleep.duration,
                                           sleepPerformance: 93,
                                           bedtimeMinutes: 795,
                                           strain: 3.4,
                                           respiratoryRate: sleep.respiratoryRate,
                                           calendar: calendar)
        XCTAssertFalse(
            SessionStore.cycleRolloverSettlementRequired(
                sleep: sleep,
                metric: metric,
                rollup: rollup,
                calendar: calendar
            ),
            "an already-settled matching day must not be re-minted at the flip"
        )

        let stale = SavedDailyMetric(day: day,
                                     recoveryPercent: 71,
                                     recoveryConfidence: "personal_baseline",
                                     hrv: sleep.hrv,
                                     restingHR: sleep.restingHR,
                                     respiratoryRate: sleep.respiratoryRate,
                                     sleepDuration: sleep.duration,
                                     sleepSpan: sleep.span,
                                     sleepStart: sleep.start,
                                     sleepEnd: sleep.end.addingTimeInterval(-3_600),
                                     sleepSource: sleep.source,
                                     sleepStageSegments: [],
                                     sleepConsistencyPercent: 84,
                                     strain: 3.4)
        XCTAssertTrue(
            SessionStore.cycleRolloverSettlementRequired(
                sleep: sleep,
                metric: stale,
                rollup: rollup,
                calendar: calendar
            ),
            "a frozen row describing a different night is re-minted at the flip"
        )
    }

    // MARK: - P0-3: near-future deferral instead of settling yesterday

    func testNearFutureRetryDateCoversTheObservedConfirmShapeOnly() {
        let now = date(day: 19, hour: 19, minute: 15)
        XCTAssertEqual(
            SessionStore.morningSettlementNearFutureRetryDate(
                newestConfirmedMainSleepEnd: now.addingTimeInterval(360),
                now: now
            ),
            now.addingTimeInterval(361),
            "the device-observed ~6-minute future-end confirm re-runs at end + 1s"
        )
        let window = SessionStore.morningSettlementNearFutureRetryWindow
        XCTAssertEqual(
            SessionStore.morningSettlementNearFutureRetryDate(
                newestConfirmedMainSleepEnd: now.addingTimeInterval(window),
                now: now
            ),
            now.addingTimeInterval(window + 1),
            "the window edge is inclusive"
        )
        XCTAssertNil(
            SessionStore.morningSettlementNearFutureRetryDate(
                newestConfirmedMainSleepEnd: now,
                now: now
            ),
            "a completed night never defers the minter"
        )
        XCTAssertNil(
            SessionStore.morningSettlementNearFutureRetryDate(
                newestConfirmedMainSleepEnd: now.addingTimeInterval(-3_600),
                now: now
            )
        )
        XCTAssertNil(
            SessionStore.morningSettlementNearFutureRetryDate(
                newestConfirmedMainSleepEnd: now.addingTimeInterval(window + 60),
                now: now
            ),
            "a distant future end belongs to the armed rollover boundary, not the retry"
        )
        XCTAssertNil(
            SessionStore.morningSettlementNearFutureRetryDate(
                newestConfirmedMainSleepEnd: nil,
                now: now
            )
        )
    }

    // MARK: - Wiring pins (source scan, repo precedent)

    private func sessionsSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    /// Pins the flip wiring: receipt refresh → settlement check → boundary
    /// re-arm; the settle helper mints via the shared minter under the exact
    /// identity proof and publishes on durable success; the minter's
    /// near-future deferral runs BEFORE the previous completed night is
    /// resolved; and the honesty gates survive verbatim.
    func testCycleFlipWiringInvokesMinterAndKeepsHonestyGates() throws {
        let source = try sessionsSource()

        let handlerStart = try XCTUnwrap(source.range(
            of: "private func handlePhysiologicalCycleRollover(reason: String) {"
        ))
        let handlerEnd = try XCTUnwrap(source.range(
            of: "private func settleWakeDayFrozenMetricAtCycleRolloverIfNeeded",
            range: handlerStart.upperBound..<source.endIndex
        ))
        let handler = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])
        let refresh = try XCTUnwrap(handler.range(
            of: "refreshCurrentCycleStrapStepReceipt("
        ))
        let settleCheck = try XCTUnwrap(handler.range(
            of: "settleWakeDayFrozenMetricAtCycleRolloverIfNeeded()"
        ))
        let rearm = try XCTUnwrap(handler.range(
            of: "schedulePhysiologicalCycleRolloverCheck(reason: reason)"
        ))
        XCTAssertLessThan(refresh.lowerBound, settleCheck.lowerBound)
        XCTAssertLessThan(settleCheck.lowerBound, rearm.lowerBound)

        let requiredStart = try XCTUnwrap(source.range(
            of: "nonisolated static func cycleRolloverSettlementRequired",
            range: handlerEnd.upperBound..<source.endIndex
        ))
        let settleHelper = String(
            source[handlerEnd.lowerBound..<requiredStart.lowerBound]
        )
        XCTAssertTrue(settleHelper.contains("latestCompletedMainSleep("))
        XCTAssertTrue(settleHelper.contains("Self.cycleRolloverSettlementRequired("))
        XCTAssertTrue(settleHelper.contains("reason: \"cycle_rollover_settlement\""))
        XCTAssertTrue(settleHelper.contains("publishDashboardRevision()"))

        let minterStart = try XCTUnwrap(source.range(
            of: "private func settleConfirmedMorningAuthority("
        ))
        let minterHead = String(source[minterStart.lowerBound...].prefix(6_000))
        let nearFuture = try XCTUnwrap(minterHead.range(
            of: "morningSettlementNearFutureRetryDate("
        ))
        let previousNight = try XCTUnwrap(minterHead.range(
            of: "latestCompletedMainSleep("
        ))
        XCTAssertLessThan(
            nearFuture.lowerBound,
            previousNight.lowerBound,
            "the near-future deferral must run before the previous night is resolved"
        )
        XCTAssertTrue(minterHead.contains("scheduleMorningSettlementNearFutureRetry("))

        // NEVER loosen: the boundary-eligibility end<=now filter and the
        // morning minter's completedBy:now gate stay verbatim — the fixes
        // re-trigger the minter, they do not weaken its honesty gates.
        XCTAssertTrue(source.contains(
            ".filter { $0.end <= now && !nonPrimaryMainIDs.contains($0.id) }"
        ))
        XCTAssertTrue(source.contains("completedBy now: Date,"))
        XCTAssertTrue(source.contains("completedBy: now,"))
    }

    // MARK: - DailyRollupStore contract pin (no DailyRollupStore source change)

    /// Between confirm and freeze the anchored-cycle summary stays nil, so
    /// consumers show the freshly evaluated provisional projection — the
    /// designed bridge. A stale same-civil-day metric (here: the earlier
    /// night's freeze on a two-sleep day) must never masquerade as the newly
    /// confirmed sleep's frozen result, and no tolerance may be added to the
    /// exact-input identity.
    func testAnchoredCycleSummaryStaysNilBetweenConfirmAndFreeze() throws {
        let newWake = date(day: 19, hour: 19, minute: 21)
        let newStart = newWake.addingTimeInterval(-6 * 3_600)
        let night = SleepHistorySnapshot.Night(
            id: "w3a-new-night",
            day: newWake,
            start: newStart,
            end: newWake,
            duration: 6 * 3_600,
            restingHR: 52,
            hrv: 48,
            respiratoryRate: 15.2,
            sleepEfficiency: 0.9,
            confidence: "confirmed",
            source: "user_adjusted_sleep",
            confirmed: true,
            stageSegments: []
        )
        let cycle = AtriaPhysiologicalCycle(
            start: newWake,
            boundaryKind: .mainSleep,
            anchorSleepID: night.id,
            expectedInterval: 24 * 3_600
        )
        let civilDay = calendar.startOfDay(for: newWake)

        // The persisted freeze still describes the earlier night that ended
        // at 05:30 on the same civil day.
        let staleEstimate = Metrics.RecoveryEstimate(
            percent: 64,
            confidence: .unverified,
            usesHRV: true,
            detail: "frozen earlier night",
            contributors: []
        )
        let staleFrozen = try XCTUnwrap(FrozenRecoverySummary(
            estimate: staleEstimate,
            scoredDay: civilDay
        ))
        let staleEnd = date(day: 19, hour: 5, minute: 30)
        let staleMetric = SavedDailyMetric(
            day: civilDay,
            recoveryPercent: 64,
            recoveryConfidence: staleEstimate.confidence.rawValue,
            hrv: 44,
            restingHR: 55,
            respiratoryRate: 14.8,
            sleepDuration: 6 * 3_600,
            sleepSpan: 6.5 * 3_600,
            sleepStart: staleEnd.addingTimeInterval(-6.5 * 3_600),
            sleepEnd: staleEnd,
            sleepSource: "overnight_sleep",
            sleepStageSegments: [],
            sleepConsistencyPercent: nil,
            strain: nil,
            recoverySummary: staleFrozen
        )
        let staleRollup = DailyRollupStoreEntry(
            day: civilDay,
            recoverySummary: staleFrozen,
            calendar: calendar
        )
        XCTAssertNil(
            DailyRecoveryResolver.summary(
                rollups: [staleRollup],
                metrics: [staleMetric],
                physiologicalCycle: cycle,
                anchorSleep: night,
                calendar: calendar
            ),
            "confirm→freeze handoff: the stale same-civil-day freeze must not resolve; the provisional projection is the designed bridge"
        )

        // Control: once the new freeze lands with exact overnight inputs the
        // resolver returns it.
        let freshEstimate = Metrics.RecoveryEstimate(
            percent: 71,
            confidence: .unverified,
            usesHRV: true,
            detail: "frozen confirmed night",
            contributors: []
        )
        let freshFrozen = try XCTUnwrap(FrozenRecoverySummary(
            estimate: freshEstimate,
            scoredDay: civilDay
        ))
        let freshMetric = SavedDailyMetric(
            day: civilDay,
            recoveryPercent: 71,
            recoveryConfidence: freshEstimate.confidence.rawValue,
            hrv: 48,
            restingHR: 52,
            respiratoryRate: 15.2,
            sleepDuration: 6 * 3_600,
            sleepSpan: newWake.timeIntervalSince(newStart),
            sleepStart: newStart,
            sleepEnd: newWake,
            sleepSource: night.source,
            sleepStageSegments: [],
            sleepConsistencyPercent: nil,
            strain: nil,
            recoverySummary: freshFrozen
        )
        let freshRollup = DailyRollupStoreEntry(
            day: civilDay,
            recoverySummary: freshFrozen,
            calendar: calendar
        )
        XCTAssertEqual(
            DailyRecoveryResolver.summary(
                rollups: [freshRollup],
                metrics: [freshMetric],
                physiologicalCycle: cycle,
                anchorSleep: night,
                calendar: calendar
            )?.score,
            71,
            "the exact-input freeze resolves once it lands"
        )
    }
}
