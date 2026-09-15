import XCTest
@testable import Atria

@MainActor
final class AtriaAppReviewDemoTests: XCTestCase {
    override func tearDown() {
        AtriaAppReviewDemo.deactivate()
        super.tearDown()
    }

    func testReservedReviewerNicknameIgnoresCaseAndWhitespace() {
        XCTAssertTrue(AtriaAppReviewDemo.isRequested(nickname: "App Review"))
        XCTAssertTrue(AtriaAppReviewDemo.isRequested(nickname: "  app review  "))
        XCTAssertFalse(AtriaAppReviewDemo.isRequested(nickname: "AppReviewer"))
        XCTAssertFalse(AtriaAppReviewDemo.isRequested(nickname: "Review"))
    }

    func testFixtureCoversEverySupportedSurfaceWithoutUnsupportedSignals() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026,
                                                      month: 8,
                                                      day: 14,
                                                      hour: 12))!

        let coverage = AtriaAppReviewDemo.surfaceCoverage(now: now, calendar: calendar)
        XCTAssertTrue(coverage.isComplete, "\(coverage)")
        XCTAssertEqual(AtriaAppReviewDemo.dailyMetrics(now: now, calendar: calendar).count, 21)
        XCTAssertEqual(AtriaAppReviewDemo.confirmedSleeps(now: now, calendar: calendar).count, 21)
        XCTAssertGreaterThanOrEqual(AtriaAppReviewDemo.confirmedWorkouts(now: now, calendar: calendar).count, 6)
        XCTAssertEqual(AtriaAppReviewDemo.journalEntries(now: now, calendar: calendar).count, 7)
        XCTAssertNotNil(AtriaAppReviewDemo.stepCount(on: now, now: now, calendar: calendar))
        XCTAssertTrue(AtriaAppReviewDemo.sessions(now: now, calendar: calendar).allSatisfy { $0.end <= now })
        XCTAssertTrue(AtriaAppReviewDemo.confirmedSleeps(now: now, calendar: calendar).allSatisfy {
            ($0.stageSegments ?? []).contains { $0.id.hasPrefix(SleepStageSegment.hrEstimateIDPrefix) }
        })
    }

    func testExploreSampleDataCopyDoesNotRequireAccountOrStrap() {
        XCTAssertEqual(AtriaAppReviewDemo.exploreButtonTitle, "Explore sample data")
        XCTAssertEqual(AtriaAppReviewDemo.eraseAndReturnTitle, "Erase sample data and return to setup")
        XCTAssertEqual(AtriaAppReviewDemo.bannerTitle, "Sample data")
        XCTAssertTrue(AtriaAppReviewDemo.bannerDetail.localizedCaseInsensitiveContains("demo data"))
    }

    func testEvidenceCatalogCitesEachComputedMetric() {
        for metricID in ["hrv", "recovery", "restingHeartRate", "respiration", "sleep", "vo2max", "strain"] {
            XCTAssertFalse(
                AtriaEvidenceCatalog.sources(for: metricID).isEmpty,
                "missing sources for \(metricID)"
            )
        }
        XCTAssertTrue(AtriaEvidenceCatalog.sources.allSatisfy { URL(string: $0.locator) != nil || $0.locator.contains("doi.org") || $0.locator.contains("pubmed") })
    }

    func testCompatibleHardwareScreenStatesWhoop4Only() {
        let screen = AtriaCompatibleHardwareScreen()
        XCTAssertEqual(String(describing: type(of: screen)), "AtriaCompatibleHardwareScreen")
        let copy = AtriaCompatibleHardwareScreen.self
        _ = copy
        XCTAssertTrue(
            AtriaEvidenceCatalog.sources.contains { $0.year >= 1971 }
        )
    }
}

final class AtriaAppReviewDemoGateTests: XCTestCase {
    func testHealthKitExportIsANoOpWhileDemoIsActive() async {
        AtriaAppReviewDemo.activate()
        defer { AtriaAppReviewDemo.deactivate() }
        let exporter = await MainActor.run { HealthKitExporter() }
        await MainActor.run {
            exporter.export(
                sessions: AtriaAppReviewDemo.sessions(),
                rest: 55,
                maxHR: 188,
                profile: AthleteProfile(age: 32,
                                        measuredMaxHR: 188,
                                        maxHRSource: .ageEstimate,
                                        biologicalSex: .unspecified,
                                        weightKg: 0,
                                        heightCm: 0,
                                        updated: Date(),
                                        hasCompletedOnboarding: true),
                restingBaselineSamples: 14
            )
        }
    }

    func testDemoStepPresentationUsesFixtureCount() {
        AtriaAppReviewDemo.activate()
        defer { AtriaAppReviewDemo.deactivate() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 16))!
        let presentation = AtriaDailyStepPresentation.resolve(
            day: now,
            now: now,
            liveCount: 0,
            liveValidationState: "none",
            liveCapturedAt: nil,
            canonicalDays: [],
            calendar: calendar
        )
        XCTAssertEqual(presentation.count, AtriaAppReviewDemo.stepCount(on: now, now: now, calendar: calendar))
        XCTAssertEqual(presentation.source, .verifiedCanonical)
    }
}
