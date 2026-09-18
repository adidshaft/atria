import XCTest
@testable import Atria

final class AtriaLearnedInsightsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testRecoveryFortyNineProducesAnActionableReadWithoutTags() {
        let today = calendar.startOfDay(for: now)
        let rollup = DailyRollupStoreEntry(
            day: today,
            recovery: 49,
            sleepSeconds: 4.8 * 3_600,
            sleepNeedSeconds: 8 * 3_600,
            strain: 0.5,
            calendar: calendar
        )
        let insights = AtriaLearnedInsights.insights(rollups: [rollup], now: now)
        XCTAssertFalse(insights.isEmpty, "rollups must produce readable insights without journal tags")
        XCTAssertTrue(insights.contains { $0.headline.contains("under your need")
            || $0.headline.contains("yellow morning")
            || $0.headline.contains("Recovery signals are low") })
        XCTAssertTrue(insights.allSatisfy { !$0.headline.isEmpty && $0.detail.count > 20 })
    }

    func testRestingHRDriftUsesFullSentences() {
        let today = calendar.startOfDay(for: now)
        let rollups = (0..<5).map { offset -> DailyRollupStoreEntry in
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                rhr: offset == 0 ? 62 : 54,
                sleepSeconds: 7 * 3_600,
                calendar: calendar
            )
        }
        let insights = AtriaLearnedInsights.insights(rollups: rollups, now: now)
        let rhr = insights.first { $0.kind == .restingHRDrift }
        XCTAssertEqual(rhr?.headline, "Resting HR is 8 bpm above usual")
        XCTAssertTrue(rhr?.detail.contains("62 bpm") == true)
    }

    func testRestingHRDriftIgnoresDaytimeWearWithoutSleep() {
        let today = calendar.startOfDay(for: now)
        let daytime = DailyRollupStoreEntry(
            day: today,
            rhr: 84,
            strain: 0.2,
            calendar: calendar
        )
        let nights = (1...4).map { offset -> DailyRollupStoreEntry in
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                rhr: offset == 1 ? 55 : 61,
                sleepSeconds: 7 * 3_600,
                calendar: calendar
            )
        }
        let insights = AtriaLearnedInsights.insights(rollups: [daytime] + nights, now: now)
        let rhr = insights.first { $0.kind == .restingHRDrift }
        XCTAssertEqual(rhr?.headline, "Resting HR is 6 bpm below usual")
        XCTAssertTrue(rhr?.detail.contains("55 bpm") == true, rhr?.detail ?? "missing")
        XCTAssertFalse(rhr?.detail.contains("84 bpm") == true, rhr?.detail ?? "missing")
    }

    func testDaySnapshotFiresWhenNothingElseQualifies() {
        let today = calendar.startOfDay(for: now)
        let rollup = DailyRollupStoreEntry(
            day: today,
            recovery: 55,
            strain: 4.2,
            calendar: calendar
        )
        let insights = AtriaLearnedInsights.insights(rollups: [rollup], now: now)
        XCTAssertTrue(insights.contains { $0.kind == .readiness || $0.kind == .daySnapshot
            || $0.kind == .recoveryDrift })
        XCTAssertFalse(insights.contains { $0.headline == "HRV N ms higher" })
    }

    func testDurableStoreRoundTripsAndLivesOutsideRawRetention() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-insights-v1-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let insight = AtriaLearnedInsight(
            id: "sleep-debt",
            kind: .sleepDebt,
            headline: "Last night was 2h under your need",
            detail: "You slept 5h against a 7h need. That gap is tonight's first recovery lever.",
            isPositive: false,
            asOf: now
        )
        XCTAssertTrue(AtriaDurableInsightStore.save([insight], at: url, now: now))
        XCTAssertEqual(AtriaDurableInsightStore.load(from: url), [insight])
        XCTAssertEqual(AtriaDurableInsightStore.filename, "learned-insights-v1.json")
        XCTAssertFalse(url.path.contains("atria-historical"))
        XCTAssertTrue(AtriaDurableInsightStore.supportedSchemas.contains(1))
        XCTAssertTrue(AtriaDurableInsightStore.supportedSchemas.contains(2))
    }

    func testDurableStoreKeepsATwentyOneDayLedgerAcrossRefresh() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-insights-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let today = calendar.startOfDay(for: now)
        let older = AtriaLearnedInsight(
            id: "day-read-1",
            kind: .daySnapshot,
            headline: "Mon 1 Jan · recovery 62%",
            detail: "recovery 62% · strain 8.1 · sleep 7h 10m.",
            isPositive: true,
            asOf: calendar.date(byAdding: .day, value: -12, to: today)!
        )
        let current = AtriaLearnedInsight(
            id: "sleep-debt",
            kind: .sleepDebt,
            headline: "Last night was 2h under your need",
            detail: "You slept 5h against a 7h need. That gap is tonight's first recovery lever.",
            isPositive: false,
            asOf: now
        )
        XCTAssertTrue(AtriaDurableInsightStore.save([current], ledger: [older], at: url, now: now))
        XCTAssertEqual(AtriaDurableInsightStore.load(from: url), [current])
        XCTAssertEqual(AtriaDurableInsightStore.loadLedger(from: url), [older])

        let incoming = AtriaLearnedInsights.dailyReads(
            rollups: [
                DailyRollupStoreEntry(
                    day: today,
                    recovery: 51,
                    sleepSeconds: 5 * 3_600,
                    strain: 4.2,
                    calendar: calendar
                )
            ],
            now: now,
            calendar: calendar
        )
        let merged = AtriaDurableInsightStore.mergeLedger(
            existing: AtriaDurableInsightStore.loadLedger(from: url),
            incoming: incoming,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(merged.contains { $0.id == older.id })
        XCTAssertTrue(merged.contains { $0.headline.contains("recovery 51%") })
        XCTAssertGreaterThanOrEqual(merged.count, 2)
    }

    func testDailyReadsUseOvernightHRVMillisecondsAndIgnoreDaytimeRHR() throws {
        let today = calendar.startOfDay(for: now)
        let overnight = DailyRollupStoreEntry(
            day: calendar.date(byAdding: .day, value: -1, to: today)!,
            lnRMSSD: log(77),
            rhr: 55,
            sleepSeconds: 7 * 3_600,
            calendar: calendar
        )
        let daytime = DailyRollupStoreEntry(
            day: today,
            rhr: 84,
            strain: 0.2,
            calendar: calendar
        )
        let reads = AtriaLearnedInsights.dailyReads(
            rollups: [daytime, overnight],
            now: now,
            calendar: calendar
        )
        let todayRead = try XCTUnwrap(reads.first { calendar.isDate($0.asOf, inSameDayAs: today) })
        XCTAssertFalse(todayRead.detail.contains("RHR 84"), todayRead.detail)
        let nightRead = try XCTUnwrap(reads.first { calendar.isDate($0.asOf, inSameDayAs: overnight.day) })
        XCTAssertTrue(nightRead.detail.contains("HRV 77"), nightRead.detail)
        XCTAssertTrue(nightRead.detail.contains("RHR 55"), nightRead.detail)
        XCTAssertFalse(nightRead.detail.contains("HRV 4"), nightRead.detail)
    }

    func testRecoveryInsightsIgnoreDaytimeWearWithoutSleep() {
        let today = calendar.startOfDay(for: now)
        let daytime = DailyRollupStoreEntry(
            day: today,
            recovery: 38,
            rhr: 84,
            strain: 0.2,
            calendar: calendar
        )
        let nights = (1...4).map { offset -> DailyRollupStoreEntry in
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                recovery: offset == 1 ? 79 : 61,
                rhr: offset == 1 ? 55 : 61,
                sleepSeconds: 7 * 3_600,
                calendar: calendar
            )
        }
        let insights = AtriaLearnedInsights.insights(rollups: [daytime] + nights, now: now)
        XCTAssertFalse(insights.contains { $0.detail.contains("38%") }, insights.map(\.detail).joined(separator: " | "))
        XCTAssertFalse(insights.contains { $0.headline.contains("38%") })
        let recovery = insights.first { $0.kind == .recoveryDrift }
        XCTAssertEqual(recovery?.headline, "Recovery is 18 points above your week")
        XCTAssertTrue(recovery?.detail.contains("79%") == true, recovery?.detail ?? "missing")
        let reads = AtriaLearnedInsights.dailyReads(
            rollups: [daytime] + nights,
            now: now,
            calendar: calendar
        )
        let todayRead = reads.first { calendar.isDate($0.asOf, inSameDayAs: today) }
        XCTAssertFalse(todayRead?.detail.contains("recovery 38%") == true, todayRead?.detail ?? "missing")
        let nightRead = reads.first { calendar.isDate($0.asOf, inSameDayAs: nights[0].day) }
        XCTAssertTrue(nightRead?.detail.contains("recovery 79%") == true, nightRead?.detail ?? "missing")
    }

    func testZeroHeartRateWorkoutsBecomeAnInsightAndLedgerLine() {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let strengthStart = yesterday.addingTimeInterval(16 * 3_600 + 31 * 60)
        let walkingStart = yesterday.addingTimeInterval(17 * 3_600 + 37 * 60)
        let rollup = DailyRollupStoreEntry(
            day: yesterday,
            recovery: 78,
            lnRMSSD: log(77),
            rhr: 55,
            sleepSeconds: 7 * 3_600,
            strain: 0.47,
            calendar: calendar
        )
        let workouts = [
            noHeartRateWorkout(id: "strength",
                               label: "Strength",
                               start: strengthStart,
                               duration: 66 * 60),
            noHeartRateWorkout(id: "walk",
                               label: "Walking",
                               start: walkingStart,
                               duration: 28 * 60)
        ]
        let insights = AtriaLearnedInsights.insights(
            rollups: [rollup],
            now: now,
            calendar: calendar,
            workouts: workouts
        )
        let missing = insights.first { $0.kind == .workoutWithoutHeartRate }
        XCTAssertEqual(missing?.headline, "Yesterday's workouts have no heart rate")
        XCTAssertTrue(missing?.detail.contains("Strength (1h 6m)") == true, missing?.detail ?? "missing")
        XCTAssertTrue(missing?.detail.contains("Walking (28m)") == true, missing?.detail ?? "missing")
        XCTAssertTrue(missing?.detail.contains("missing, not reconstructed") == true, missing?.detail ?? "missing")
        XCTAssertEqual(missing?.kind, .workoutWithoutHeartRate)
        XCTAssertTrue(insights.first?.kind == .workoutWithoutHeartRate)

        let reads = AtriaLearnedInsights.dailyReads(
            rollups: [rollup],
            now: now,
            calendar: calendar,
            workouts: workouts
        )
        let nightRead = reads.first { calendar.isDate($0.asOf, inSameDayAs: yesterday) }
        XCTAssertTrue(nightRead?.detail.contains("recovery 78%") == true, nightRead?.detail ?? "missing")
        XCTAssertTrue(nightRead?.detail.contains("HRV 77") == true, nightRead?.detail ?? "missing")
        XCTAssertTrue(
            nightRead?.detail.contains("Strength and Walking saved without strap HR") == true,
            nightRead?.detail ?? "missing"
        )
    }

    func testOlderZeroHeartRateWorkoutsDoNotStayOnTheCurrentBoard() {
        let today = calendar.startOfDay(for: now)
        let older = calendar.date(byAdding: .day, value: -3, to: today)!
        let insights = AtriaLearnedInsights.insights(
            rollups: [
                DailyRollupStoreEntry(
                    day: today,
                    recovery: 70,
                    sleepSeconds: 7 * 3_600,
                    calendar: calendar
                )
            ],
            now: now,
            calendar: calendar,
            workouts: [
                noHeartRateWorkout(id: "old",
                                   label: "Running",
                                   start: older.addingTimeInterval(17 * 3_600),
                                   duration: 40 * 60)
            ]
        )
        XCTAssertFalse(insights.contains { $0.kind == .workoutWithoutHeartRate })
    }

    private func noHeartRateWorkout(
        id: String,
        label: String,
        start: Date,
        duration: TimeInterval
    ) -> UserConfirmedWorkout {
        UserConfirmedWorkout(
            id: id,
            createdAt: start,
            start: start,
            end: start.addingTimeInterval(duration),
            label: label,
            source: "live_workout_window",
            confidence: "user_confirmed_no_hr",
            sessions: 1,
            samples: 0,
            avgHR: 0,
            peakHR: 0,
            p95HR: 0,
            p99HR: 0,
            thresholdHR: 0,
            streamCoveragePercent: 0,
            observedDuration: duration,
            reason: "no_strap_hr_samples",
            activityType: label
        )
    }

    func testWeeklyStrainAndBedtimeSpreadAreSpecific() {
        let today = calendar.startOfDay(for: now)
        let rollups = (0..<14).map { offset -> DailyRollupStoreEntry in
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                bedtimeMinutes: offset < 7 ? (offset.isMultiple(of: 2) ? 22 * 60 : 1 * 60) : 23 * 60,
                strain: offset < 7 ? 14 : 8,
                calendar: calendar
            )
        }
        let insights = AtriaLearnedInsights.insights(rollups: rollups, now: now)
        XCTAssertTrue(insights.contains { $0.kind == .weeklyStrain })
        XCTAssertTrue(insights.contains { $0.kind == .bedtimeSpread })
        XCTAssertTrue(insights.contains { $0.detail.count > 40 })
        XCTAssertFalse(insights.contains { $0.detail.contains("Bank sleep") })
    }

    func testStackedRecoveryAndYesterdayStrainAreSpecific() {
        let today = calendar.startOfDay(for: now)
        let todayRollup = DailyRollupStoreEntry(
            day: today,
            recovery: 42,
            sleepSeconds: 5 * 3_600,
            sleepNeedSeconds: 8 * 3_600,
            strain: 0.5,
            calendar: calendar
        )
        let yesterday = DailyRollupStoreEntry(
            day: calendar.date(byAdding: .day, value: -1, to: today)!,
            strain: 12.4,
            calendar: calendar
        )
        let insights = AtriaLearnedInsights.insights(
            rollups: [todayRollup, yesterday],
            now: now
        )
        XCTAssertTrue(insights.contains { $0.kind == .stackedRecovery })
        XCTAssertTrue(insights.contains { $0.kind == .yesterdayStrain })
        XCTAssertEqual(
            insights.first { $0.kind == .stackedRecovery }?.emphasisLabel,
            "Stack"
        )
    }

    func testLearnedInsightsBoardIsTheSharedSurface() throws {
        let source = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaLearnedInsightsBoard.swift")
                .path,
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("What moved you"))
        XCTAssertTrue(source.contains("nakedRow"))
        XCTAssertTrue(source.contains("Captured read"))
        XCTAssertTrue(source.contains("AtriaInsightLookback"))
        XCTAssertTrue(source.contains("case compactBar"))
        XCTAssertTrue(source.contains("private var compactBar"))
        XCTAssertTrue(source.contains("ringHeroInsights(from: insights)"),
                      "Today's compact read uses Sleep / Recovery / Strain rings, not wrapping paragraphs")
        XCTAssertTrue(source.contains("emphasisLabel"))
        XCTAssertTrue(source.contains("AtriaLearnedInsightsSheet"))
        XCTAssertTrue(source.contains(".buttonStyle(.glass)"))
        XCTAssertTrue(source.contains("AtriaInsightPictureRing"))
        XCTAssertTrue(source.contains("ringHero("))
        XCTAssertTrue(source.contains("showsRingHero: lookback == .day"))
        XCTAssertFalse(source.contains("isPositive ? Metrics.electricGreen"))
        XCTAssertFalse(source.contains("featuredCard"))
        XCTAssertFalse(source.contains("railColor(for:"))
        XCTAssertFalse(source.contains("Capsule()"))
    }

    func testRingHeroPicksSleepRecoveryAndStrainInTodayOrder() {
        let recovery = AtriaLearnedInsight(
            id: "rec",
            kind: .recoveryDrift,
            headline: "Recovery is down",
            detail: "Today's recovery sits below the last week.",
            isPositive: false,
            asOf: now
        )
        let sleep = AtriaLearnedInsight(
            id: "sleep",
            kind: .sleepDebt,
            headline: "Last night was short",
            detail: "Sleep landed under your need.",
            isPositive: false,
            asOf: now
        )
        let strain = AtriaLearnedInsight(
            id: "strain",
            kind: .yesterdayStrain,
            headline: "Yesterday was a heavy load day",
            detail: "Strain stayed high into this morning.",
            isPositive: false,
            asOf: now
        )
        let extra = AtriaLearnedInsight(
            id: "bed",
            kind: .bedtimeSpread,
            headline: "Bedtime is swinging",
            detail: "Nights are landing at very different hours.",
            isPositive: false,
            asOf: now
        )
        XCTAssertEqual(sleep.ringFamily, .sleep)
        XCTAssertEqual(recovery.ringFamily, .recovery)
        XCTAssertEqual(strain.ringFamily, .strain)
        XCTAssertEqual(sleep.pictureSystemImage, "moon.stars.fill")
        let hero = AtriaLearnedInsight.ringHeroInsights(from: [extra, strain, sleep, recovery])
        XCTAssertEqual(hero.map(\.ringFamily), [.recovery, .sleep, .strain])
        XCTAssertEqual(hero.map(\.id), ["rec", "sleep", "strain"])
    }

    func testTodayPinsCompactReadBarAndInsightsKeepsFullBoard() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let today = try String(
            contentsOf: testsDirectory.appendingPathComponent("Atria/AtriaTodayScreen.swift"),
            encoding: .utf8
        )
        let journal = try String(
            contentsOf: testsDirectory.appendingPathComponent("Atria/AtriaJournalTab.swift"),
            encoding: .utf8
        )
        let insights = try String(
            contentsOf: testsDirectory.appendingPathComponent("Atria/AtriaOverviewSections.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(today.contains("style: .compactBar"))
        XCTAssertTrue(today.contains("todayFirstScreenSavedWorkouts"))
        let recap = try XCTUnwrap(today.range(of: "if !recentSavedWorkouts.isEmpty"))
        let compactRead = try XCTUnwrap(today.range(of: "style: .compactBar"))
        XCTAssertLessThan(compactRead.lowerBound, recap.lowerBound,
                          "Compact read first, then one recap row, so a stack of workouts cannot sit under the tab")
        XCTAssertTrue(today.contains("AtriaActivityWorkoutDetailSheetHost("))
        XCTAssertTrue(today.contains("showInsights = true"))
        XCTAssertTrue(today.contains("AtriaLearnedInsightsSheet("))
        XCTAssertTrue(today.contains("ledger: sessionProjectionStore.state.learnedInsightLedger"))
        XCTAssertFalse(journal.contains("AtriaLearnedInsightsBoard"))
        XCTAssertFalse(journal.contains("AtriaLearnedInsightsHost"))
        XCTAssertTrue(
            insights.contains("AtriaPanelSectionHeader(title: \"Insights\", subtitle: \"What moved you\")")
        )
        XCTAssertTrue(insights.contains("showsHeader: false"))
        XCTAssertTrue(insights.contains("usesOwnCard: false"))
        XCTAssertFalse(insights.contains("style: .compactBar"))
    }

    func testWeeklySleepDebtUsesStoredNeedAcrossShortNightsWithoutOne() {
        let today = calendar.startOfDay(for: now)
        let rollups: [DailyRollupStoreEntry] = [
            DailyRollupStoreEntry(
                day: today,
                recovery: 53,
                sleepSeconds: 15_693,
                sleepNeedSeconds: 27_519,
                sleepPerformance: 57,
                bedtimeMinutes: 1_401,
                strain: 0.6,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -1, to: today)!,
                recovery: 54,
                sleepSeconds: 17_349,
                bedtimeMinutes: 1_478,
                strain: 0.5,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -2, to: today)!,
                strain: 1.7,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -3, to: today)!,
                strain: 0.6,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -4, to: today)!,
                strain: 0.3,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -5, to: today)!,
                recovery: 78,
                sleepSeconds: 20_398,
                bedtimeMinutes: 1_448,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -6, to: today)!,
                recovery: 94,
                sleepSeconds: 26_876,
                bedtimeMinutes: 1_290,
                calendar: calendar
            )
        ]
        let insights = AtriaLearnedInsights.insights(rollups: rollups, now: now)
        let weekly = insights.first { $0.kind == .weeklySleepDebt }
        XCTAssertNotNil(weekly, "four short nights versus the stored 7h 39m need must surface")
        XCTAssertTrue(weekly?.headline.contains("sleep debt across recent nights") == true)
        XCTAssertTrue(weekly?.detail.contains("7h 39m") == true)
        XCTAssertFalse(weekly?.detail.contains("Bank sleep") == true)
        XCTAssertGreaterThanOrEqual(
            Set(insights.map(\.kind)).count,
            5,
            "this week's rollups must yield at least five distinct insight kinds"
        )
        let easyLoad = insights.first { $0.kind == .easyLoadSleepDebt }
        XCTAssertEqual(easyLoad?.headline, "Sleep debt is from nights, not load")
        XCTAssertTrue(easyLoad?.detail.contains("Easy days are not paying that down") == true)
    }

    func testEasyLoadSleepDebtFiresWhenStrainIsQuietAndNightsAreShort() {
        let today = calendar.startOfDay(for: now)
        let rollups = (0..<5).map { offset -> DailyRollupStoreEntry in
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                sleepSeconds: 5 * 3_600,
                sleepNeedSeconds: 8 * 3_600,
                strain: 0.3,
                calendar: calendar
            )
        }
        let insights = AtriaLearnedInsights.insights(rollups: rollups, now: now)
        let easyLoad = insights.first { $0.kind == .easyLoadSleepDebt }
        XCTAssertNotNil(easyLoad)
        XCTAssertTrue(easyLoad?.detail.contains("0.3") == true)
        XCTAssertTrue(easyLoad?.headline.contains("nights, not load") == true)
    }

    func testFrozenSleepNeedFallbackSurfacesWeeklyDebtWhenRollupsOmitNeed() {
        let today = calendar.startOfDay(for: now)
        let rollups: [DailyRollupStoreEntry] = [
            DailyRollupStoreEntry(
                day: today,
                recovery: 65,
                rhr: 55,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -1, to: today)!,
                recovery: 47,
                rhr: 61,
                sleepSeconds: 15_693,
                bedtimeMinutes: 1_401,
                strain: 0.7,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -2, to: today)!,
                recovery: 49,
                rhr: 61,
                sleepSeconds: 17_349,
                bedtimeMinutes: 1_478,
                strain: 0.5,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -3, to: today)!,
                strain: 1.8,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -4, to: today)!,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -5, to: today)!,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -6, to: today)!,
                recovery: 74,
                rhr: 74,
                sleepSeconds: 20_398,
                bedtimeMinutes: 1_448,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -7, to: today)!,
                recovery: 93,
                rhr: 93,
                sleepSeconds: 26_876,
                bedtimeMinutes: 1_290,
                calendar: calendar
            )
        ]
        let insights = AtriaLearnedInsights.insights(
            rollups: rollups,
            now: now,
            sleepNeedFallbackSeconds: 27_519
        )
        let kinds = Set(insights.filter { $0.kind != .daySnapshot }.map(\.kind))
        XCTAssertTrue(kinds.contains(.weeklySleepDebt), "kinds=\(kinds)")
        XCTAssertTrue(kinds.contains(.sleepDebt), "kinds=\(kinds)")
        XCTAssertTrue(kinds.contains(.bedtimeSpread), "kinds=\(kinds)")
        XCTAssertGreaterThanOrEqual(kinds.count, 5, "kinds=\(kinds)")
        let sleep = insights.first { $0.kind == .sleepDebt }
        XCTAssertTrue(sleep?.headline.contains("under your need") == true)
    }

    func testShortSleepAgainstNeedProducesAFeaturedRead() {
        let today = calendar.startOfDay(for: now)
        let rollup = DailyRollupStoreEntry(
            day: today,
            recovery: 51,
            rhr: 61,
            sleepSeconds: 17_349,
            sleepNeedSeconds: 28_307,
            sleepPerformance: 61,
            strain: 0.56,
            calendar: calendar
        )
        let insights = AtriaLearnedInsights.insights(rollups: [rollup], now: now)
        XCTAssertTrue(insights.contains { $0.kind == .sleepDebt })
        XCTAssertTrue(insights.contains { $0.headline.contains("under your need") })
        XCTAssertFalse(insights.isEmpty)
    }

    func testYesterdaySleepWithoutNeedStillProducesAShortNightRead() {
        let today = calendar.startOfDay(for: now)
        let todayRollup = DailyRollupStoreEntry(
            day: today,
            recovery: 46,
            rhr: 84,
            strain: 0.01,
            calendar: calendar
        )
        let nights = [0, 1, 2, 3, 5, 6].map { offset -> DailyRollupStoreEntry in
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                recovery: offset == 0 ? 46 : 60,
                rhr: offset == 0 ? 84 : (offset == 1 ? 65 : 58),
                sleepSeconds: offset == 0 ? nil : (offset == 1 ? 17_349 : 18_500),
                calendar: calendar
            )
        }
        let insights = AtriaLearnedInsights.insights(
            rollups: [todayRollup] + nights.dropFirst(),
            now: now
        )
        XCTAssertTrue(insights.contains { $0.kind == .sleepDebt })
        XCTAssertTrue(insights.contains { $0.headline.contains("4h 49m")
            || $0.headline.contains("under your usual")
            || $0.headline.contains("only") })
        XCTAssertTrue(insights.contains { $0.kind == .stackedRecovery || $0.kind == .recoveryDrift
            || $0.kind == .readiness })
        let rhr = insights.first { $0.kind == .restingHRDrift }
        XCTAssertEqual(rhr?.headline, "Resting HR is 7 bpm above usual")
        XCTAssertTrue(rhr?.detail.contains("65 bpm") == true, rhr?.detail ?? "missing")
        XCTAssertFalse(rhr?.detail.contains("84 bpm") == true, rhr?.detail ?? "missing")
        XCTAssertTrue(insights.allSatisfy { $0.detail.count > 20 })
    }

    func testLearnedInsightsRefreshFromRollupsNotJournalEngine() throws {
        let source = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift")
                .path,
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("func refreshLearnedInsights(now: Date = Date())"))
        XCTAssertTrue(source.contains("Self.overlayFrozenSleepNeed("))
        XCTAssertTrue(source.contains("refreshLearnedInsights()"))
        XCTAssertTrue(source.contains("workouts: confirmedWorkouts"))
        XCTAssertTrue(source.contains("didSet {\n            backupCanonicalRevision &+= 1\n            refreshLearnedInsights()"))
    }

    func testLedgerRowsFillMissingWeekDaysAndKeepToday() {
        let today = calendar.startOfDay(for: now)
        let captured = AtriaLearnedInsight(
            id: "day-read-today",
            kind: .daySnapshot,
            headline: "Today · recovery 70%",
            detail: "recovery 70%.",
            isPositive: true,
            asOf: today
        )
        let week = AtriaLearnedInsights.ledgerRows(
            ledger: [captured],
            lookback: .week,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.first?.id, captured.id)
        XCTAssertEqual(week.filter { $0.detail.contains("No captured read") }.count, 6)

        let month = AtriaLearnedInsights.ledgerRows(
            ledger: [captured],
            lookback: .month,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(month.count, 30)

        let day = AtriaLearnedInsights.ledgerRows(
            ledger: [captured],
            lookback: .day,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(day.map(\.id), [captured.id])
    }

    func testLearnedInsightsWithholdUncitedPrescriptions() throws {
        let source = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaLearnedInsights.swift")
                .path,
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("Keep today's load easy"))
        XCTAssertFalse(source.contains("You can train"))
        XCTAssertFalse(source.contains("Easy movement only"))
        XCTAssertFalse(source.contains("Today: you can push"))
        XCTAssertFalse(source.contains("room to train"))
        XCTAssertFalse(source.contains("Keep the day's load"))
        XCTAssertFalse(source.contains("Keep strain light"))
        XCTAssertFalse(source.contains("Keep the work inside"))
    }
}
