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
            || $0.headline.contains("take it easy")
            || $0.headline.contains("Today: recover") })
        XCTAssertTrue(insights.allSatisfy { !$0.headline.isEmpty && $0.detail.count > 20 })
    }

    func testRestingHRDriftUsesFullSentences() {
        let today = calendar.startOfDay(for: now)
        let rollups = (0..<5).map { offset -> DailyRollupStoreEntry in
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                rhr: offset == 0 ? 62 : 54,
                calendar: calendar
            )
        }
        let insights = AtriaLearnedInsights.insights(rollups: rollups, now: now)
        let rhr = insights.first { $0.kind == .restingHRDrift }
        XCTAssertEqual(rhr?.headline, "Resting HR is 8 bpm above usual")
        XCTAssertTrue(rhr?.detail.contains("62 bpm") == true)
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
        XCTAssertTrue(source.contains("Earlier reads"))
        XCTAssertTrue(source.contains("case compactBar"))
        XCTAssertTrue(source.contains("private var compactBar"))
        XCTAssertTrue(source.contains("AtriaLearnedInsightsSheet"))
        XCTAssertTrue(source.contains(".buttonStyle(.glass)"))
        XCTAssertTrue(source.contains("AtriaInsightPictureRing"))
        XCTAssertTrue(source.contains("ringHero("))
        XCTAssertTrue(source.contains("showsRingHero: true"))
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
        XCTAssertTrue(weekly?.headline.contains("sleep debt this week") == true)
        XCTAssertTrue(weekly?.detail.contains("7h 39m") == true)
        XCTAssertFalse(weekly?.detail.contains("Bank sleep") == true)
        XCTAssertGreaterThanOrEqual(
            Set(insights.map(\.kind)).count,
            5,
            "this week's rollups must yield at least five distinct insight kinds"
        )
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
            rhr: 65,
            strain: 0.01,
            calendar: calendar
        )
        let nights = [0, 1, 2, 3, 5, 6].map { offset -> DailyRollupStoreEntry in
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                recovery: offset == 0 ? 46 : 60,
                rhr: offset == 0 ? 65 : 58,
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
        XCTAssertTrue(insights.contains { $0.kind == .restingHRDrift })
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
        XCTAssertTrue(source.contains("refreshLearnedInsights()"))
        XCTAssertTrue(source.contains("didSet {\n            backupCanonicalRevision &+= 1\n            refreshLearnedInsights()"))
    }
}
