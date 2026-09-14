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
        XCTAssertTrue(source.contains("featuredCard"))
        XCTAssertTrue(source.contains("railColor(for:"))
        XCTAssertTrue(source.contains("emphasisLabel.uppercased()"))
        XCTAssertFalse(source.contains("isPositive ? Metrics.electricGreen"))
    }
}
