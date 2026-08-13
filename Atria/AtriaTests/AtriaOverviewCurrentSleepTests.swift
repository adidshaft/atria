import XCTest
@testable import Atria

final class AtriaOverviewCurrentSleepTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year,
                                           month: month,
                                           day: day,
                                           hour: hour,
                                           minute: minute))!
    }

    private func snapshot(wake: Date) -> SleepHistorySnapshot {
        let start = wake.addingTimeInterval(-(7 * 3_600 + 48 * 60))
        let night = SleepHistorySnapshot.Night(id: "manual-july-14",
                                               day: calendar.startOfDay(for: wake),
                                               start: start,
                                               end: wake,
                                               duration: wake.timeIntervalSince(start),
                                               restingHR: 55,
                                               hrv: 49,
                                               respiratoryRate: nil,
                                               sleepEfficiency: nil,
                                               confidence: "user_confirmed",
                                               source: "manual_sleep",
                                               confirmed: true,
                                               stageSegments: [],
                                               eventTimeZoneIdentifier: "Asia/Kolkata")
        return SleepHistorySnapshot(nights: [night], confirmedCount: 1, candidateCount: 0)
    }

    func testOverviewDoesNotReuseOlderManualSleepAfterNoSleepBoundary() {
        let july14Wake = date(2026, 7, 14, 11, 38)
        let july18Morning = date(2026, 7, 18, 9, 0)

        XCTAssertNil(AtriaOverviewCurrentSleep.resolve(from: snapshot(wake: july14Wake),
                                                       now: july18Morning,
                                                       calendar: calendar))
    }

    func testOverviewKeepsCompletedSleepDuringItsWakeToWakeCycle() {
        let wake = date(2026, 7, 18, 8, 15)
        let sameMorning = date(2026, 7, 18, 9, 0)

        XCTAssertEqual(AtriaOverviewCurrentSleep.resolve(from: snapshot(wake: wake),
                                                         now: sameMorning,
                                                         calendar: calendar)?.id,
                       "manual-july-14")
    }

    func testOverviewDoesNotShowSleepWhoseWakeIsInTheFuture() {
        let futureWake = date(2026, 7, 18, 10, 0)
        let now = date(2026, 7, 18, 9, 0)

        XCTAssertNil(AtriaOverviewCurrentSleep.resolve(from: snapshot(wake: futureWake),
                                                       now: now,
                                                       calendar: calendar))
    }

    func testActiveTodayRingUsesCurrentCycleResolver() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let todayURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift")
        let source = try String(contentsOf: todayURL, encoding: .utf8)

        XCTAssertTrue(source.contains("AtriaOverviewCurrentSleep.resolve("))
        XCTAssertTrue(source.contains("AtriaOverviewCurrentSleep.resolveDisplayEvidence("))
        XCTAssertTrue(source.contains("let latest = latestSleep"))
        XCTAssertTrue(source.contains("latest == nil, latestDisplaySleep != nil"),
                      "review-only sleep must not inherit an older night's need/performance")
        // Handoff-10 CP1: the primary value must come from the CURRENT-day
        // gated evidence (a fresh first night ending today still renders its
        // measured duration through `currentDaySleep`); the day-agnostic
        // newest-rollup fallback is gone.
        XCTAssertTrue(source.contains("let value = currentDaySleep?.durationText"),
                      "fresh first-night evidence should render its measured duration")
        XCTAssertTrue(source.contains("sleepIsCurrentDayPrimary"),
                      "the Today ring must gate its primary on the wake's civil day")
        XCTAssertFalse(source.contains("latestRollup?.sleepSeconds"),
                       "the day-agnostic newest-rollup sleep fallback must stay deleted")
        XCTAssertTrue(source.contains("evidence.isNapEvidence ? \"Review nap\" : \"Review sleep\""))
        XCTAssertFalse(source.contains("let latest = sleepHistory.latestMainSleep"))
    }

    func testTodayShareCannotExportRetainedPriorNightAfterRollover() throws {
        let staleWake = date(2026, 7, 17, 8, 0)
        let afterRollover = date(2026, 7, 18, 8, 31)
        XCTAssertNil(AtriaOverviewCurrentSleep.resolveDisplayEvidence(
            from: snapshot(wake: staleWake),
            now: afterRollover,
            calendar: calendar
        ), "the sleep authority shared by Today/Home must reject the retained prior night")

        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let homeURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift")
        let source = try String(contentsOf: homeURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func makeTodayShareSnapshot()"))
        let end = try XCTUnwrap(source.range(of: "private func pendingShareValue",
                                             range: start.upperBound..<source.endIndex))
        let shareBuilder = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(shareBuilder.contains("AtriaOverviewCurrentSleep.resolveDisplayEvidence("))
        XCTAssertTrue(shareBuilder.contains("pendingReview: store.pendingSleepReviewNightForUI"))
        XCTAssertTrue(shareBuilder.contains("let sleepValue = sleep?.durationText ?? \"\""))
        XCTAssertTrue(shareBuilder.contains("let sleepDetail = sleep?.confirmationText ?? \"No sleep this cycle\""))
        XCTAssertFalse(shareBuilder.contains("sleepHistorySnapshot.latestMainSleep"))
        XCTAssertFalse(shareBuilder.contains("model.snapshotStore.state.sleepValue"))
        XCTAssertFalse(shareBuilder.contains("model.snapshotStore.state.sleepDetail"))
    }

    func testHealthCurrentSleepEvidenceSharesTodayRolloverAuthority() {
        let wake = date(2026, 7, 18, 8, 0)
        let staleNow = date(2026, 7, 19, 8, 31)
        let currentNow = date(2026, 7, 18, 18, 0)
        let history = snapshot(wake: wake)

        XCTAssertNotNil(AtriaHealthCurrentSleepEvidence.resolve(from: history,
                                                                now: currentNow,
                                                                calendar: calendar))
        XCTAssertNil(AtriaHealthCurrentSleepEvidence.resolve(from: history,
                                                             now: staleNow,
                                                             calendar: calendar),
                     "Vitals must not reuse an old confirmed night after Today rolls over")
    }

    func testHealthPreviousSleepContextIsExplicitlyHistorical() {
        let wake = date(2026, 7, 18, 8, 0)
        let history = snapshot(wake: wake)

        XCTAssertEqual(
            AtriaHealthPreviousSleepEvidence.resolve(from: history)?.id,
            "manual-july-14"
        )
    }

    func testHealthScreenCannotReadUnfilteredLatestMainSleep() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let healthURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHealthScreen.swift")
        let source = try String(contentsOf: healthURL, encoding: .utf8)

        XCTAssertTrue(source.contains("AtriaHealthCurrentSleepEvidence.resolve("))
        XCTAssertTrue(source.contains("No sleep this cycle"))
        XCTAssertTrue(source.contains("Last saved sleep"))
        XCTAssertFalse(source.contains(".latestMainSleep"),
                       "current Vitals duration, stages, performance, and respiration must use the physiological resolver")
    }

    func testVitalsCurrentMetricsKeepHeroAuthorityAcrossCivilMidnight() {
        let hero = AtriaHealthMetricAuthority.CurrentCycle(
            recoveryPercent: 72,
            recoveryDetail: "personal baseline",
            restingHeartRateText: "54",
            hrvValue: "47",
            hrvDetail: "sleep signal"
        )
        let newCivilDay = DailyRollupStoreEntry(
            day: date(2026, 7, 19, 0, 0),
            recovery: 12,
            lnRMSSD: log(99),
            rhr: 88,
            calendar: calendar
        )

        let current = AtriaHealthMetricAuthority.resolve(.currentCycle(hero))
        let dated = AtriaHealthMetricAuthority.resolve(.datedHistory(newCivilDay))

        XCTAssertEqual(current.recoveryPercent, 72)
        XCTAssertEqual(current.restingHeartRate, 54)
        XCTAssertEqual(current.hrvMS, 47)
        XCTAssertEqual(dated.recoveryPercent, 12)
        XCTAssertEqual(dated.restingHeartRate, 88)
        XCTAssertEqual(dated.hrvMS, 99)
    }

    func testVitalsNoSleepRolloverKeepsHeroLimitedRecoveryInsteadOfCivilRow() {
        let hero = AtriaHealthMetricAuthority.CurrentCycle(
            recoveryPercent: 46,
            recoveryDetail: "Previous sleep score · awaiting today’s sleep",
            restingHeartRateText: "73",
            hrvValue: "Learning",
            hrvDetail: "needs qualified sleep"
        )
        let civilRow = DailyRollupStoreEntry(
            day: date(2026, 7, 19, 0, 0),
            recovery: 99,
            lnRMSSD: log(91),
            rhr: 42,
            calendar: calendar
        )

        let current = AtriaHealthMetricAuthority.resolve(.currentCycle(hero))
        _ = AtriaHealthMetricAuthority.resolve(.datedHistory(civilRow))

        XCTAssertEqual(current.recoveryValue, "46%")
        XCTAssertEqual(current.recoveryDetail,
                       "Previous sleep score · awaiting today’s sleep")
        XCTAssertEqual(current.restingHeartRate, 73)
        // 2026-07-28 deterministic-presentation pass: the authority's
        // normaliser now maps any pending input onto the app-wide no-value
        // token instead of passing "Learning" straight through. That is the
        // point of it -- it previously rewrote "--" INTO "Learning", which
        // silently undid the token upstream and left Health Monitor speaking a
        // different vocabulary from the row beside it.
        //
        // The invariant this test is NAMED for is untouched and still asserted
        // above: the hero's 46% wins over the civil row's 99%.
        XCTAssertEqual(current.hrvValue, AtriaCompactMetricPresentation.noValue)
    }

    func testVitalsLiveCardHasNoCivilLatestRollupAuthority() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let healthURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHealthScreen.swift")
        let source = try String(contentsOf: healthURL, encoding: .utf8)

        XCTAssertTrue(source.contains(
            "AtriaHealthMetricAuthority.resolve(.currentCycle("
        ))
        XCTAssertFalse(source.contains("private var latestRollup:"),
                       "civil-day lookup must not drive current Recovery, RHR, or HRV")
        XCTAssertTrue(source.contains("case datedHistory(DailyRollupStoreEntry)"),
                      "civil rollups remain available only through explicitly dated context")
    }

    func testMetricDetailCurrentPeriodReplacesStaleCivilRecoveryAndStrain() {
        let now = date(2026, 7, 30, 2, 0)
        let cycleStart = date(2026, 7, 29, 14, 35)
        let current = AtriaHealthMetricAuthority.resolve(.currentCycle(.init(
            recoveryPercent: 46,
            recoveryDetail: "Limited",
            restingHeartRateText: "61",
            hrvValue: "38",
            hrvDetail: "sleep signal",
            strain: 3.8536,
            strainDetail: "local",
            cycleStart: cycleStart,
            projectedAt: now
        )))

        for range in [
            AtriaTrendRange.day,
            AtriaTrendRange.week,
            AtriaTrendRange.month,
        ] {
            let projection = AtriaHealthMetricAuthority.detailProjection(
                currentCycle: current,
                historicalRecoveryPercent: 38,
                historicalStrain: 0.7296,
                range: range,
                periodAnchor: cycleStart,
                calendar: calendar
            )
            XCTAssertTrue(projection.usesCurrentCycle)
            XCTAssertEqual(projection.recoveryPercent, 46)
            XCTAssertEqual(projection.strain ?? -1, 3.8536, accuracy: 0.000_001)
        }
    }

    func testMetricDetailAfterMidnightKeysCurrentCycleToWakeDayNotCivilToday() {
        let now = date(2026, 7, 30, 2, 0)
        let cycleStart = date(2026, 7, 29, 14, 35)
        let current = AtriaHealthMetricAuthority.resolve(.currentCycle(.init(
            recoveryPercent: 46,
            recoveryDetail: "Limited",
            restingHeartRateText: "61",
            hrvValue: "38",
            hrvDetail: "sleep signal",
            strain: 3.8536,
            strainDetail: "local",
            cycleStart: cycleStart,
            projectedAt: now
        )))

        let wakeDay = AtriaHealthMetricAuthority.detailProjection(
            currentCycle: current,
            historicalRecoveryPercent: 38,
            historicalStrain: 0.7296,
            range: .day,
            periodAnchor: cycleStart,
            calendar: calendar
        )
        XCTAssertTrue(wakeDay.usesCurrentCycle)
        XCTAssertEqual(wakeDay.recoveryPercent, 46)
        XCTAssertEqual(wakeDay.strain ?? -1, 3.8536, accuracy: 0.000_001)

        let nextCivilDay = AtriaHealthMetricAuthority.detailProjection(
            currentCycle: current,
            historicalRecoveryPercent: 38,
            historicalStrain: 0.7296,
            range: .day,
            periodAnchor: now,
            calendar: calendar
        )
        XCTAssertFalse(nextCivilDay.usesCurrentCycle)
        XCTAssertEqual(nextCivilDay.recoveryPercent, 38)
        XCTAssertEqual(nextCivilDay.strain ?? -1, 0.7296, accuracy: 0.000_001)
    }

    func testMetricDetailHistoricalNavigationDoesNotUseCurrentCycle() {
        let now = date(2026, 7, 30, 2, 0)
        let current = AtriaHealthMetricAuthority.resolve(.currentCycle(.init(
            recoveryPercent: 46,
            recoveryDetail: "Limited",
            restingHeartRateText: "61",
            hrvValue: "38",
            hrvDetail: "sleep signal",
            strain: 3.8536,
            strainDetail: "local",
            cycleStart: date(2026, 7, 29, 14, 35),
            projectedAt: now
        )))
        let priorDay = date(2026, 7, 28, 12, 0)

        let projection = AtriaHealthMetricAuthority.detailProjection(
            currentCycle: current,
            historicalRecoveryPercent: 61,
            historicalStrain: 7.2,
            range: .day,
            periodAnchor: priorDay,
            calendar: calendar
        )

        XCTAssertFalse(projection.usesCurrentCycle)
        XCTAssertEqual(projection.recoveryPercent, 61)
        XCTAssertEqual(projection.strain, 7.2)
    }

    func testMetricDetailCurrentNoValueWithholdsStaleCivilRecovery() {
        let now = date(2026, 7, 30, 2, 0)
        let cycleStart = date(2026, 7, 29, 14, 35)
        let current = AtriaHealthMetricAuthority.resolve(.currentCycle(.init(
            recoveryPercent: nil,
            recoveryDetail: "HRV pending",
            restingHeartRateText: "61",
            hrvValue: "--",
            hrvDetail: "HRV settling",
            strain: 1.4,
            strainDetail: "partial-day wear",
            strainIsPartial: true,
            cycleStart: cycleStart,
            projectedAt: now
        )))

        let projection = AtriaHealthMetricAuthority.detailProjection(
            currentCycle: current,
            historicalRecoveryPercent: 99,
            historicalStrain: 0.2,
            range: .day,
            periodAnchor: cycleStart,
            calendar: calendar
        )

        XCTAssertTrue(projection.usesCurrentCycle)
        XCTAssertNil(projection.recoveryPercent)
        XCTAssertEqual(projection.strain, 1.4)
    }

    func testPartialCurrentCycleStrainRemainsLowerBoundButNotExactTrendData() {
        let partial = AtriaHealthMetricAuthority.resolve(.currentCycle(.init(
            recoveryPercent: 46,
            recoveryDetail: "Limited",
            restingHeartRateText: "61",
            hrvValue: "38",
            hrvDetail: "sleep signal",
            strain: 3.8,
            strainDetail: "partial-day wear",
            strainIsPartial: true
        )))
        let truth = AtriaHealthMetricAuthority.strainTrendTruth(partial)

        XCTAssertEqual(truth.heroLowerBound, 3.8)
        XCTAssertNil(truth.exactTrendValue)
        XCTAssertTrue(truth.isPartial)

        let settledWeek = [7.0, 8.0]
            + [truth.exactTrendValue].compactMap { $0 }
        XCTAssertEqual(
            settledWeek.reduce(0, +) / Double(settledWeek.count),
            7.5,
            accuracy: 0.000_001,
            "A partial live lower bound must not alter exact W/M aggregates"
        )
    }

    func testAllMetricDetailRoutesPassTheSharedCurrentCycleAuthority() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceRoot = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        for file in [
            "AtriaTodayScreen.swift",
            "AtriaHealthScreen.swift",
            "AtriaVitalsCollectionSections.swift",
            "AtriaOverviewSections.swift",
        ] {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(file),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("currentCycleAuthority:"))
            XCTAssertTrue(source.contains(
                "AtriaHealthMetricAuthority.currentCycleProjection("
            ), "\(file) must pass the shared wake-to-wake authority into metric detail")
        }

        let overview = try String(
            contentsOf: sourceRoot.appendingPathComponent("AtriaOverviewSections.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(overview.contains(
            ".disabled(nextMetricPeriodIsUnavailable)"
        ), "Recovery/strain detail must not navigate past the current physiological day")
    }

    func testFreshCandidateCanDisplayDurationWithoutBecomingCurrentMainSleep() {
        let now = date(2026, 7, 18, 9, 0)
        let start = date(2026, 7, 18, 2, 0)
        let end = date(2026, 7, 18, 8, 0)
        let candidate = SleepHistorySnapshot.Night(id: "review",
                                                   day: calendar.startOfDay(for: end),
                                                   start: start,
                                                   end: end,
                                                   duration: end.timeIntervalSince(start),
                                                   restingHR: 55,
                                                   hrv: nil,
                                                   respiratoryRate: nil,
                                                   sleepEfficiency: 1,
                                                   confidence: "review_needed",
                                                   source: "sleep_candidate",
                                                   confirmed: false,
                                                   stageSegments: [])
        let snapshot = SleepHistorySnapshot(nights: [candidate],
                                            confirmedCount: 0,
                                            candidateCount: 1)

        XCTAssertNil(AtriaOverviewCurrentSleep.resolve(from: snapshot,
                                                       now: now,
                                                       calendar: calendar))
        XCTAssertEqual(AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: snapshot,
                                                                        now: now,
                                                                        calendar: calendar)?.id,
                       candidate.id)
    }

    func testResidentReviewDisplaysWhenDailySnapshotIsEmptyWithoutBecomingCurrentSleep() {
        let now = date(2026, 7, 18, 9, 0)
        let start = date(2026, 7, 18, 2, 15)
        let end = date(2026, 7, 18, 8, 20)
        let pending = SleepHistorySnapshot.Night(id: "resident-review",
                                                 day: calendar.startOfDay(for: end),
                                                 start: start,
                                                 end: end,
                                                 duration: end.timeIntervalSince(start),
                                                 restingHR: 55,
                                                 hrv: nil,
                                                 respiratoryRate: nil,
                                                 sleepEfficiency: 1,
                                                 confidence: "review_needed",
                                                 source: "sleep_candidate",
                                                 confirmed: false,
                                                 stageSegments: [])

        XCTAssertNil(AtriaOverviewCurrentSleep.resolve(from: .empty,
                                                       now: now,
                                                       calendar: calendar))
        let displayed = AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: .empty,
                                                                          pendingReview: pending,
                                                                          now: now,
                                                                          calendar: calendar)
        XCTAssertEqual(displayed?.id, pending.id)
        XCTAssertEqual(displayed?.durationText, pending.durationText)
        XCTAssertFalse(displayed?.confirmed ?? true,
                       "overview projection must not confirm a pending review")
    }

    func testFreshResidentReviewOutranksStaleDailyCandidateForDisplay() {
        let now = date(2026, 7, 18, 9, 0)
        let staleEnd = date(2026, 7, 16, 8, 0)
        let stale = SleepHistorySnapshot.Night(id: "stale-snapshot-review",
                                               day: calendar.startOfDay(for: staleEnd),
                                               start: staleEnd.addingTimeInterval(-6 * 3_600),
                                               end: staleEnd,
                                               duration: 6 * 3_600,
                                               restingHR: 55,
                                               hrv: nil,
                                               respiratoryRate: nil,
                                               sleepEfficiency: 1,
                                               confidence: "review_needed",
                                               source: "sleep_candidate",
                                               confirmed: false,
                                               stageSegments: [])
        let freshEnd = date(2026, 7, 18, 8, 10)
        let fresh = SleepHistorySnapshot.Night(id: "fresh-resident-review",
                                               day: calendar.startOfDay(for: freshEnd),
                                               start: freshEnd.addingTimeInterval(-5 * 3_600),
                                               end: freshEnd,
                                               duration: 5 * 3_600,
                                               restingHR: 56,
                                               hrv: nil,
                                               respiratoryRate: nil,
                                               sleepEfficiency: 1,
                                               confidence: "review_needed",
                                               source: "sleep_candidate",
                                               confirmed: false,
                                               stageSegments: [])
        let staleSnapshot = SleepHistorySnapshot(nights: [stale],
                                                 confirmedCount: 0,
                                                 candidateCount: 1)

        XCTAssertEqual(AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: staleSnapshot,
                                                                         pendingReview: fresh,
                                                                         now: now,
                                                                         calendar: calendar)?.id,
                       fresh.id)
    }

    func testStaleCandidateCannotLeakIntoCurrentOverview() {
        let now = date(2026, 7, 18, 9, 0)
        let end = date(2026, 7, 16, 8, 0)
        let candidate = SleepHistorySnapshot.Night(id: "stale-review",
                                                   day: calendar.startOfDay(for: end),
                                                   start: end.addingTimeInterval(-6 * 3_600),
                                                   end: end,
                                                   duration: 6 * 3_600,
                                                   restingHR: 55,
                                                   hrv: nil,
                                                   respiratoryRate: nil,
                                                   sleepEfficiency: 1,
                                                   confidence: "review_needed",
                                                   source: "sleep_candidate",
                                                   confirmed: false,
                                                   stageSegments: [])
        let snapshot = SleepHistorySnapshot(nights: [candidate],
                                            confirmedCount: 0,
                                            candidateCount: 1)

        XCTAssertNil(AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: snapshot,
                                                                      now: now,
                                                                      calendar: calendar))
    }
}
