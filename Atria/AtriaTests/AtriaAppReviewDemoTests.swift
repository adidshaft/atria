import HealthKit
import XCTest
@testable import Atria

@MainActor
final class AtriaAppReviewDemoTests: XCTestCase {
    override func tearDown() {
        AtriaAppReviewDemo.deactivate()
        super.tearDown()
    }

    func testHealthKitIsBlockedOnlyWhileSampleDataIsActive() {
        AtriaAppReviewDemo.deactivate()
        XCTAssertFalse(HealthKitExporter.appReviewDemoBlocks("test"))
        AtriaAppReviewDemo.activate()
        XCTAssertTrue(HealthKitExporter.appReviewDemoBlocks("test"))
        // Leaving sample data restores normal HealthKit behaviour.
        AtriaAppReviewDemo.deactivate()
        XCTAssertFalse(HealthKitExporter.appReviewDemoBlocks("test"))
    }

    /// App Review 2.1(a), 1.0 (101): the Health controls must reach HealthKit
    /// in sample mode. The sample-mode export request asks for every type a
    /// real export writes, so the reviewer sees the same access sheet.
    func testSampleModeExportRequestCoversEveryExportedType() {
        let types = HealthKitExporter().exportAuthorizationTypes
        let share = Set(types.share.map(\.identifier))
        for identifier: HKQuantityTypeIdentifier in [.heartRate, .restingHeartRate, .heartRateVariabilitySDNN,
                                                     .respiratoryRate, .activeEnergyBurned, .vo2Max] {
            XCTAssertTrue(share.contains(identifier.rawValue), identifier.rawValue)
        }
        XCTAssertTrue(share.contains(HKObjectType.workoutType().identifier))
        XCTAssertTrue(share.contains(HKCategoryTypeIdentifier.sleepAnalysis.rawValue))
        XCTAssertTrue(types.read.contains(HKQuantityType(.heartRate)))
    }

    /// App Store / TestFlight / simulator installs have no embedded profile.
    /// Reading that as "entitlement missing" silently disabled every Health
    /// request for reviewers (2.1(a), 1.0 (101)).
    func testHealthKitEntitlementOnlyMissingWhenAProfileProvesIt() throws {
        func bundle(profile: String?) throws -> Bundle {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("hk-entitlement-\(UUID().uuidString).bundle")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
            if let profile {
                try Data(profile.utf8).write(to: dir.appendingPathComponent("embedded.mobileprovision"))
            }
            return try XCTUnwrap(Bundle(url: dir))
        }

        XCTAssertTrue(HealthKitExporter.hasHealthKitEntitlement(bundle: try bundle(profile: nil)),
                      "No profile means an Apple-signed or simulator install")
        XCTAssertFalse(HealthKitExporter.hasHealthKitEntitlement(
            bundle: try bundle(profile: "<key>aps-environment</key>")))
        XCTAssertTrue(HealthKitExporter.hasHealthKitEntitlement(
            bundle: try bundle(profile: "<key>com.apple.developer.healthkit</key><true/>")))
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

    func testSampleDataBlocksResearchSharingAndDailyPreparation() {
        AtriaAppReviewDemo.activate()
        defer { AtriaAppReviewDemo.deactivate() }

        AtriaResearchSharing.grantConsent(now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertFalse(AtriaResearchSharing.isAvailable)
        XCTAssertFalse(AtriaResearchSharing.isOptedIn)
        XCTAssertNil(AtriaResearchSharing.pseudonym)

        let defaults = UserDefaults.standard
        let originalOptIn = defaults.object(forKey: AtriaResearchSharing.optInKey)
        defer {
            if let originalOptIn {
                defaults.set(originalOptIn, forKey: AtriaResearchSharing.optInKey)
            } else {
                defaults.removeObject(forKey: AtriaResearchSharing.optInKey)
            }
        }
        defaults.set(true, forKey: AtriaResearchSharing.optInKey)
        XCTAssertFalse(
            AtriaResearchUploadQueue.isDailyUploadDue(
                now: Date(timeIntervalSince1970: 1_780_000_000),
                defaults: defaults
            ),
            "Sample data must not prepare a daily research bundle"
        )
    }

    func testSampleDataSettingsHideResearchSharingControl() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaSettingsView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private var privacySettingsPage: some View"))
        let end = try XCTUnwrap(source.range(of: "private var developerSettingsPage", range: start.upperBound..<source.endIndex))
        let page = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(page.contains("if !AtriaAppReviewDemo.isActive"))
        XCTAssertTrue(page.contains("Research sharing is unavailable while you explore sample data."))
    }

    func testEvidenceCatalogCitesEachComputedMetric() {
        for metricID in ["hrv", "recovery", "restingHeartRate", "respiration", "sleep", "vo2max", "strain", "stress", "sleepNeed", "fitnessAge", "skinTemperature", "bloodOxygen"] {
            XCTAssertFalse(
                AtriaEvidenceCatalog.sources(for: metricID).isEmpty,
                "missing sources for \(metricID)"
            )
        }
        XCTAssertTrue(AtriaEvidenceCatalog.sources.allSatisfy { URL(string: $0.locator) != nil || $0.locator.contains("doi.org") || $0.locator.contains("pubmed") })
        XCTAssertFalse(AtriaEvidenceCatalog.sources(for: "steps").isEmpty)
        XCTAssertFalse(AtriaEvidenceCatalog.sources(for: "calories").isEmpty)
    }

    func testCompatibleHardwareScreenStatesWhoop4Only() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaCompatibleHardwareScreen.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("WHOOP 4.0"))
        XCTAssertTrue(source.contains("manufactured and sold by WHOOP, Inc."))
        XCTAssertTrue(source.contains("Atria does not manufacture, sell, or service WHOOP hardware."))
        XCTAssertFalse(source.contains("WHOOP 5"))
    }

    func testCoachCopyWithholdsUncitedPrescriptions() {
        let low = Coach.guide(recovery: 20, strain: 4)
        let high = Coach.guide(recovery: 80, strain: 6)
        for text in [low.headline, low.detail, high.headline, high.detail] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("prioritize rest"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("ease off"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("room to push"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("safely add"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("hard strain is not"))
        }
        for metric in AtriaMetricDetailKind.allCases {
            let copy = AtriaMetricMeaningCopy.coaching(
                metric: metric,
                guidance: Coach.guide(recovery: 50, strain: 8)
            )
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("favor easier"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("buy back time"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("earlier bedtime"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("zone 2"))
        }
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

    func testAsyncRawExportGuardsDemoMode() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "func exportRawDataPackageAsync() async -> URL? {"))
        let slice = source[start.lowerBound...]
        let header = String(slice.prefix(280))
        XCTAssertTrue(
            header.contains("guard !AtriaAppReviewDemo.isActive else { return nil }"),
            "async export must refuse demo-mode sample packages"
        )
    }
}
