import XCTest
@testable import Atria

/// WP-1 / GAP-01 — each night's adaptive Sleep Need freezes at settlement and
/// is never recomputed with later baselines, debt, strain, or profile edits.
final class AtriaFrozenSleepNeedTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        DateComponents(calendar: calendar,
                       timeZone: calendar.timeZone,
                       year: year, month: month, day: day, hour: hour).date!
    }

    private func mainSleep(id: String,
                           start: Date,
                           hours: Double,
                           source: String = "manual_sleep",
                           frozen: AtriaSleepBudget.FrozenNeed? = nil) -> UserConfirmedSleep {
        UserConfirmedSleep(id: id,
                           createdAt: start,
                           start: start,
                           end: start.addingTimeInterval(hours * 3_600),
                           source: source,
                           confidence: "manual_user_entered",
                           sessions: 1,
                           samples: 100,
                           avgHR: 52,
                           peakHR: 60,
                           restingHR: 50,
                           hrv: 60,
                           hrvWindowCount: 4,
                           duration: hours * 3_600,
                           span: hours * 3_600,
                           reason: "test",
                           motionSource: "manual",
                           motionValidated: false,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: calendar.timeZone.identifier,
                           frozenSleepNeed: frozen)
    }

    private func nap(id: String, start: Date, hours: Double) -> UserConfirmedSleep {
        UserConfirmedSleep(id: id,
                           createdAt: start,
                           start: start,
                           end: start.addingTimeInterval(hours * 3_600),
                           source: "manual_nap",
                           confidence: "manual_user_entered",
                           sessions: 1,
                           samples: 20,
                           avgHR: 56,
                           peakHR: 62,
                           restingHR: 52,
                           hrv: nil,
                           hrvWindowCount: nil,
                           duration: hours * 3_600,
                           span: hours * 3_600,
                           reason: "test",
                           motionSource: "manual",
                           motionValidated: false,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: calendar.timeZone.identifier)
    }

    // MARK: freezingAdaptiveSleepNeed

    func testFreezingMintsReceiptOnlyForFreezableNewMainSleeps() throws {
        let night = mainSleep(id: "new-main", start: day(2026, 8, 10, hour: 23), hours: 7)
        let existing = mainSleep(id: "old-main", start: day(2026, 8, 9, hour: 23), hours: 7)
        let shortRest = nap(id: "nap", start: day(2026, 8, 10, hour: 14), hours: 1)

        let settled = try XCTUnwrap(SessionStore.freezingAdaptiveSleepNeed(
            in: [night, existing, shortRest],
            freezableSleepIDs: ["new-main", "nap"],
            dailyMetrics: [],
            baseNeedHours: 8,
            calendar: calendar
        ))

        let mintedNight = settled.first { $0.id == "new-main" }
        XCTAssertNotNil(mintedNight?.frozenSleepNeed,
                        "a genuinely new main sleep mints an itemized receipt at settlement")
        XCTAssertEqual(mintedNight?.frozenSleepNeed?.baseHours, 8)
        XCTAssertNil(settled.first { $0.id == "old-main" }?.frozenSleepNeed,
                     "a record outside the freezable set must not be back-minted")
        XCTAssertNil(settled.first { $0.id == "nap" }?.frozenSleepNeed,
                     "a nap never owns a nightly need receipt")
    }

    func testExistingFrozenNeedIsNeverRemintedWithALaterBase() throws {
        let originalComponents = AtriaSleepBudget.sleepNeedComponents(baseHours: 7,
                                                                      yesterdayStrain: 15,
                                                                      debtHours: 2,
                                                                      sameDayNapHours: 0)
        let frozen = AtriaSleepBudget.FrozenNeed(originalComponents)
        let night = mainSleep(id: "frozen-main",
                              start: day(2026, 8, 10, hour: 23),
                              hours: 7,
                              frozen: frozen)

        let settled = try XCTUnwrap(SessionStore.freezingAdaptiveSleepNeed(
            in: [night],
            freezableSleepIDs: ["frozen-main"],
            dailyMetrics: [],
            baseNeedHours: 10,   // a later, different profile base
            calendar: calendar
        ))

        XCTAssertEqual(settled.first?.frozenSleepNeed, frozen,
                       "an already-frozen need must survive re-settlement byte-identically")
        XCTAssertEqual(settled.first?.sleepNeedSeconds, frozen.seconds)
    }

    func testMintedNeedUsesPriorFrozenNightsDebtAndNapCredit() throws {
        // Two prior settled nights with frozen needs and real shortfalls.
        let priorA = mainSleep(id: "prior-a",
                               start: day(2026, 8, 8, hour: 23),
                               hours: 6,
                               frozen: .init(AtriaSleepBudget.sleepNeedComponents(
                                   baseHours: 8, yesterdayStrain: nil, debtHours: 0, sameDayNapHours: 0)))
        let priorB = mainSleep(id: "prior-b",
                               start: day(2026, 8, 9, hour: 23),
                               hours: 6.5,
                               frozen: .init(AtriaSleepBudget.sleepNeedComponents(
                                   baseHours: 8, yesterdayStrain: nil, debtHours: 0, sameDayNapHours: 0)))
        // A nap after the previous main wake and before tonight's start.
        let sameDayNap = nap(id: "afternoon-nap", start: day(2026, 8, 10, hour: 15), hours: 1)
        let tonight = mainSleep(id: "tonight", start: day(2026, 8, 10, hour: 23), hours: 7)
        let yesterdayMetric = SavedDailyMetric(day: day(2026, 8, 10),
                                               recoveryPercent: 60,
                                               recoveryConfidence: "personal baseline",
                                               hrv: 60,
                                               restingHR: 50,
                                               respiratoryRate: nil,
                                               sleepDuration: nil,
                                               sleepSpan: nil,
                                               sleepStart: nil,
                                               sleepEnd: nil,
                                               sleepSource: nil,
                                               sleepStageSegments: [],
                                               sleepConsistencyPercent: nil,
                                               strain: 15)

        let settled = try XCTUnwrap(SessionStore.freezingAdaptiveSleepNeed(
            in: [priorA, priorB, sameDayNap, tonight],
            freezableSleepIDs: ["tonight"],
            dailyMetrics: [yesterdayMetric],
            baseNeedHours: 8,
            calendar: calendar
        ))

        let expectedDebt = AtriaSleepBudget.sleepDebt(nights: [
            (needed: priorA.frozenSleepNeed!.totalHours, slept: 6),
            (needed: priorB.frozenSleepNeed!.totalHours, slept: 6.5),
        ])
        let expected = AtriaSleepBudget.sleepNeedComponents(baseHours: 8,
                                                            yesterdayStrain: 15,
                                                            debtHours: expectedDebt,
                                                            sameDayNapHours: 1)
        let minted = settled.first { $0.id == "tonight" }?.frozenSleepNeed
        XCTAssertEqual(minted, AtriaSleepBudget.FrozenNeed(expected),
                       "tonight's receipt must be built from prior frozen nights' debt, yesterday's strain, and the same-day nap credit")
        XCTAssertGreaterThan(expected.debtAdderHours, 0)
        XCTAssertGreaterThan(expected.napCreditHours, 0)
        XCTAssertGreaterThan(expected.strainAdderHours, 0)
    }

    // MARK: edit-path receipt preservation (source-pinned)

    /// A bound edit mints a new record id, so only the confirmSleepWindow carry
    /// can preserve the receipt; a same-id rebuild must keep the full itemized
    /// receipt, not just the scalar. These pins keep both carries in place.
    func testEditPathsCarryTheFrozenReceiptForward() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8)

        // confirmSleepWindow: edits preserve the previously saved receipt.
        XCTAssertTrue(source.contains("carriedFrozenNeed = previouslySaved.frozenSleepNeed"))
        XCTAssertTrue(source.contains("sleepNeedSeconds: carriedNeedSeconds"))
        XCTAssertTrue(source.contains("frozenSleepNeed: carriedFrozenNeed"))

        // prepareConfirmedSleepSave: a same-id rebuild upgrades to the stored
        // receipt instead of downgrading to a bare scalar.
        XCTAssertTrue(source.contains("(need: need, receipt: sleep.frozenSleepNeed)"))
        XCTAssertTrue(source.contains("preserved = sleep.replacingFrozenSleepNeed(receipt)"))
    }

    // MARK: chart gap grammar

    func testHoursVsNeedRunsBreakAtMissingNights() {
        func slot(_ dayOffset: Int, slept: Double?, need: Double?) -> AtriaSleepDebtChartPresentation.NightSlot {
            .init(day: day(2026, 8, 1 + dayOffset),
                  dayLetter: "D",
                  sleptHours: slept,
                  needHours: need)
        }
        let slots = [
            slot(0, slept: 7, need: 8),
            slot(1, slept: 6.5, need: 8.2),
            slot(2, slept: 7.2, need: nil),   // receiptless night → need gap
            slot(3, slept: nil, need: 8.1),   // unconfirmed night → slept gap
            slot(4, slept: 7.4, need: 8.05),
        ]

        let needRuns = AtriaSleepDebtChartPresentation.valueRuns(slots, value: \.needHours)
        XCTAssertEqual(needRuns.count, 2, "the need line must break at the receiptless night")
        XCTAssertEqual(needRuns[0].map(\.hours), [8, 8.2])
        XCTAssertEqual(needRuns[1].map(\.hours), [8.1, 8.05])

        let sleptRuns = AtriaSleepDebtChartPresentation.valueRuns(slots, value: \.sleptHours)
        XCTAssertEqual(sleptRuns.count, 2, "the slept line must break at the unconfirmed night")
        XCTAssertEqual(sleptRuns[0].map(\.hours), [7, 6.5, 7.2])
        XCTAssertEqual(sleptRuns[1].map(\.hours), [7.4])

        XCTAssertTrue(AtriaSleepDebtChartPresentation.valueRuns([], value: \.needHours).isEmpty)
        XCTAssertEqual(
            AtriaSleepDebtChartPresentation.valueRuns([slot(0, slept: nil, need: nil)],
                                                      value: \.needHours).count,
            0,
            "an all-missing window draws no invented line at all")
    }
}
