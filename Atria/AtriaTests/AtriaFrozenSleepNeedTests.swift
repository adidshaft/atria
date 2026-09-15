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

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        DateComponents(calendar: calendar,
                       timeZone: calendar.timeZone,
                       year: year, month: month, day: day, hour: hour, minute: minute).date!
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
        // Prior 7h night pulls typical to 7h; adapted base is the midpoint of
        // the configured 8h and that typical.
        XCTAssertEqual(try XCTUnwrap(mintedNight?.frozenSleepNeed).baseHours, 7.5, accuracy: 0.001)
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

        let typical = try XCTUnwrap(AtriaSleepBudget.typicalSleepHours(fromSlept: [6, 6.5]))
        XCTAssertEqual(typical, 6.5, accuracy: 0.001)
        // 6h and 6.5h both sit within 10% of typical, so recovered nights
        // add no debt. Strain and nap credit still move the receipt.
        let expected = AtriaSleepBudget.sleepNeedComponents(baseHours: 8,
                                                            yesterdayStrain: 15,
                                                            debtHours: 0,
                                                            sameDayNapHours: 1,
                                                            typicalSleepHours: typical)
        let minted = settled.first { $0.id == "tonight" }?.frozenSleepNeed
        XCTAssertEqual(minted, AtriaSleepBudget.FrozenNeed(expected),
                       "tonight's receipt uses typical-sleep debt, yesterday's strain, and the same-day nap credit")
        XCTAssertEqual(expected.debtAdderHours, 0, accuracy: 0.001)
        XCTAssertGreaterThan(expected.napCreditHours, 0)
        XCTAssertGreaterThan(expected.strainAdderHours, 0)
        XCTAssertEqual(expected.baseHours, 7.25, accuracy: 0.001)
    }

    func testRecoveredSixHourNightsDoNotFreezeTenHourNeed() throws {
        let crash = mainSleep(id: "crash", start: day(2026, 9, 3, hour: 7), hours: 2.3)
        let prior = (0..<3).map { offset in
            mainSleep(id: "prior-\(offset)",
                      start: day(2026, 9, 4 + offset, hour: 23),
                      hours: 6.5)
        }
        let tonight = mainSleep(id: "tonight", start: day(2026, 9, 7, hour: 21), hours: 6.4)

        let settled = try XCTUnwrap(SessionStore.freezingAdaptiveSleepNeed(
            in: [crash] + prior + [tonight],
            freezableSleepIDs: ["tonight"],
            dailyMetrics: [],
            baseNeedHours: 8,
            calendar: calendar
        ))

        let minted = try XCTUnwrap(settled.first { $0.id == "tonight" }?.frozenSleepNeed)
        XCTAssertEqual(minted.debtAdderHours, 0, accuracy: 0.01,
                       "crash nights under 5h must not inflate later targets")
        XCTAssertEqual(minted.totalHours, 7.25, accuracy: 0.05)
        XCTAssertLessThan(minted.totalHours, 8.5)
    }

    // MARK: assessment P1.7+8 — TRIMP is truth; the need adder consumes it

    func testNeedAdderConsumesYesterdayTRIMPThroughTheDisplayAuthority() {
        // Equivalent TRIMP anchor for the published 15.0-display-strain point.
        let t15 = -150.0 * log(1.0 - 15.0 / 21.0)
        let fromTRIMP = AtriaSleepBudget.sleepNeedComponents(baseHours: 8,
                                                             yesterdayTRIMP: t15,
                                                             yesterdayStrainFallback: nil,
                                                             debtHours: 0,
                                                             sameDayNapHours: 0)
        let fromSkin = AtriaSleepBudget.sleepNeedComponents(baseHours: 8,
                                                            yesterdayStrain: 15,
                                                            debtHours: 0,
                                                            sameDayNapHours: 0)
        XCTAssertEqual(fromTRIMP.strainAdderHours, fromSkin.strainAdderHours, accuracy: 0.0001,
                       "TRIMP passes through the one display authority — the 37-min-at-15 anchor is unchanged")
        XCTAssertEqual(fromTRIMP.strainAdderHours, 0.62, accuracy: 0.0001)

        // Truth wins over the skin when both exist; the skin is only a legacy fallback.
        let truthWins = AtriaSleepBudget.sleepNeedComponents(baseHours: 8,
                                                             yesterdayTRIMP: t15,
                                                             yesterdayStrainFallback: 5,
                                                             debtHours: 0,
                                                             sameDayNapHours: 0)
        XCTAssertEqual(truthWins.strainAdderHours, 0.62, accuracy: 0.0001)
        let fallback = AtriaSleepBudget.sleepNeedComponents(baseHours: 8,
                                                            yesterdayTRIMP: nil,
                                                            yesterdayStrainFallback: 15,
                                                            debtHours: 0,
                                                            sameDayNapHours: 0)
        XCTAssertEqual(fallback.strainAdderHours, 0.62, accuracy: 0.0001)
    }

    func testDayTRIMPTruthSurvivesMetricAndRollupRoundTrips() throws {
        let metric = SavedDailyMetric(day: day(2026, 8, 10),
                                      recoveryPercent: 60,
                                      recoveryConfidence: "personal baseline",
                                      hrv: 60,
                                      restingHR: 50,
                                      respiratoryRate: nil,
                                      sleepDuration: 7 * 3_600,
                                      sleepSpan: 7 * 3_600,
                                      sleepStart: nil,
                                      sleepEnd: nil,
                                      sleepSource: "manual_sleep",
                                      sleepStageSegments: [],
                                      sleepConsistencyPercent: 80,
                                      strain: 12.4,
                                      dayTRIMP: 132.5)
        let restoredMetric = try JSONDecoder().decode(SavedDailyMetric.self,
                                                      from: JSONEncoder().encode(metric))
        XCTAssertEqual(restoredMetric.dayTRIMP ?? 0, 132.5, accuracy: 0.001)

        let entry = DailyRollupStoreEntry(day: day(2026, 8, 10),
                                          strain: 12.4,
                                          trimp: 132.5,
                                          calendar: calendar)
        let restoredEntry = try JSONDecoder().decode(DailyRollupStoreEntry.self,
                                                     from: JSONEncoder().encode(entry))
        XCTAssertEqual(restoredEntry.trimp ?? 0, 132.5, accuracy: 0.001)
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

    // MARK: rollup overlay

    func testOverlayFrozenSleepNeedFillsMeasuredNightsThatOmitNeed() {
        let frozen = AtriaSleepBudget.FrozenNeed(
            AtriaSleepBudget.sleepNeedComponents(
                baseHours: 7.65,
                yesterdayStrain: nil,
                debtHours: 0,
                sameDayNapHours: 0
            )
        )
        let night = mainSleep(
            id: "sep15",
            start: day(2026, 9, 14, hour: 23),
            hours: 4.359,
            frozen: frozen
        )
        let wakeDay = EventCivilTime.day(
            containing: night.end,
            eventTimeZoneIdentifier: night.eventTimeZoneIdentifier,
            outputCalendar: calendar
        )
        let missingNeed = DailyRollupStoreEntry(
            day: wakeDay,
            recovery: 48,
            sleepSeconds: 15_693,
            bedtimeMinutes: 1_401,
            calendar: calendar
        )
        let alreadyStored = DailyRollupStoreEntry(
            day: calendar.date(byAdding: .day, value: -1, to: wakeDay)!,
            sleepSeconds: 17_349,
            sleepNeedSeconds: 28_000,
            calendar: calendar
        )
        let noSleep = DailyRollupStoreEntry(
            day: calendar.date(byAdding: .day, value: 1, to: wakeDay)!,
            recovery: 65,
            rhr: 55,
            calendar: calendar
        )
        let filled = SessionStore.overlayFrozenSleepNeed(
            onto: [missingNeed, alreadyStored, noSleep],
            confirmedSleeps: [night],
            calendar: calendar
        )
        XCTAssertEqual(filled[0].sleepNeedSeconds ?? 0, frozen.seconds, accuracy: 0.001)
        XCTAssertEqual(filled[1].sleepNeedSeconds ?? 0, 28_000, accuracy: 0.001)
        XCTAssertNil(filled[2].sleepNeedSeconds)
    }

    func testOverlayFrozenSleepNeedLatestEndWinsOnTheSameWakeDay() {
        let earlier = AtriaSleepBudget.FrozenNeed(
            AtriaSleepBudget.sleepNeedComponents(
                baseHours: 8,
                yesterdayStrain: nil,
                debtHours: 0,
                sameDayNapHours: 0
            )
        )
        let later = AtriaSleepBudget.FrozenNeed(
            AtriaSleepBudget.sleepNeedComponents(
                baseHours: 7.65,
                yesterdayStrain: nil,
                debtHours: 0,
                sameDayNapHours: 0
            )
        )
        let first = mainSleep(
            id: "first",
            start: day(2026, 9, 14, hour: 22),
            hours: 7,
            frozen: earlier
        )
        let second = mainSleep(
            id: "second",
            start: day(2026, 9, 14, hour: 23, minute: 30),
            hours: 7,
            frozen: later
        )
        let wakeDay = EventCivilTime.day(
            containing: second.end,
            eventTimeZoneIdentifier: second.eventTimeZoneIdentifier,
            outputCalendar: calendar
        )
        XCTAssertEqual(
            wakeDay,
            EventCivilTime.day(
                containing: first.end,
                eventTimeZoneIdentifier: first.eventTimeZoneIdentifier,
                outputCalendar: calendar
            )
        )
        let filled = SessionStore.overlayFrozenSleepNeed(
            onto: [DailyRollupStoreEntry(day: wakeDay, sleepSeconds: 25_200, calendar: calendar)],
            confirmedSleeps: [first, second],
            calendar: calendar
        )
        XCTAssertEqual(filled.first?.sleepNeedSeconds ?? 0, later.seconds, accuracy: 0.001)
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
