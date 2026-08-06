import XCTest
@testable import Atria

/// Design-parity slice 1 (2026-08-01): pure math behind the sleep-need
/// ledger bar (6a), the 7-night need-vs-slept debt chart (6b), and the
/// Smart Wake axis (6c). All inputs are the real model types — no UI.
final class AtriaSleepPlannerChartsTests: XCTestCase {

    // MARK: - Ledger bar segments (6a)

    func testLedgerSegmentsStackRealComponentsOnTenHourAxis() {
        let comps = AtriaSleepBudget.sleepNeedComponents(baseHours: 8,
                                                         yesterdayStrain: 15,
                                                         debtHours: 1.1,
                                                         sameDayNapHours: 0.33)
        let segments = AtriaSleepNeedLedgerPresentation.segments(for: comps)
        XCTAssertEqual(segments.map(\.term), [.baseline, .strain, .debt, .napCredit])

        // Baseline starts at 0 and spans 8h of the 10h axis.
        XCTAssertEqual(segments[0].startFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[0].widthFraction, 0.8, accuracy: 0.0001)

        // Strain and debt stack end-to-end after the baseline.
        XCTAssertEqual(segments[1].startFraction, 0.8, accuracy: 0.0001)
        XCTAssertEqual(segments[1].widthFraction, comps.strainAdderHours / 10, accuracy: 0.0001)
        XCTAssertEqual(segments[2].startFraction,
                       0.8 + comps.strainAdderHours / 10,
                       accuracy: 0.0001)

        // The nap credit hatches the LAST napCredit-worth of the stack.
        let grossFraction = (comps.baseHours + comps.strainAdderHours + comps.debtAdderHours) / 10
        XCTAssertEqual(segments[3].startFraction + segments[3].widthFraction,
                       grossFraction,
                       accuracy: 0.0001)
        XCTAssertEqual(segments[3].widthFraction, comps.napCreditHours / 10, accuracy: 0.0001)
    }

    func testLedgerDropsZeroTermsAndNeverOverflowsAxis() {
        // No strain, no debt, no nap: only the baseline segment renders.
        let quiet = AtriaSleepBudget.sleepNeedComponents(baseHours: 8,
                                                         yesterdayStrain: nil,
                                                         debtHours: 0,
                                                         sameDayNapHours: 0)
        XCTAssertEqual(AtriaSleepNeedLedgerPresentation.segments(for: quiet).map(\.term),
                       [.baseline])

        // Pathological gross sum beyond 10h stays clipped to the axis.
        let heavy = AtriaSleepBudget.sleepNeedComponents(baseHours: 10,
                                                         yesterdayStrain: 21,
                                                         debtHours: 6,
                                                         sameDayNapHours: 0)
        let segments = AtriaSleepNeedLedgerPresentation.segments(for: heavy)
        let end = segments.map { $0.startFraction + $0.widthFraction }.max() ?? 0
        XCTAssertLessThanOrEqual(end, 1.0 + 0.0001)
        // The clamped total is where "Tonight's need" lands.
        XCTAssertEqual(AtriaSleepNeedLedgerPresentation.netFraction(for: heavy),
                       1.0,
                       accuracy: 0.0001)
    }

    func testLedgerAxisAndMinuteTexts() {
        XCTAssertEqual(AtriaSleepNeedLedgerPresentation.axisTicks.map(\.label),
                       ["0h", "4h", "8h", "10h"])
        XCTAssertEqual(AtriaSleepNeedLedgerPresentation.minutesText(hours: 0.45, sign: "+"), "+27m")
        XCTAssertEqual(AtriaSleepNeedLedgerPresentation.minutesText(hours: 0, sign: "+"), "0m")
        XCTAssertEqual(AtriaSleepNeedLedgerPresentation.minutesText(hours: 0.3, sign: "\u{2212}"),
                       "\u{2212}18m")
    }

    // MARK: - Debt chart night selection (6b)

    private func night(id: String,
                       day: Date,
                       hours: Double,
                       confirmed: Bool = true,
                       source: String = "sensor") -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: id,
                                   day: day,
                                   duration: hours * 3_600,
                                   restingHR: nil,
                                   hrv: nil,
                                   respiratoryRate: nil,
                                   sleepEfficiency: nil,
                                   confidence: "ready",
                                   source: source,
                                   confirmed: confirmed,
                                   stageSegments: [])
    }

    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    private func day(_ offset: Int, from anchor: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: anchor)!
    }

    private func frozenNeeds(_ nights: [SleepHistorySnapshot.Night], hours: Double) -> [Date: TimeInterval] {
        Dictionary(uniqueKeysWithValues: nights.map {
            (calendar.startOfDay(for: $0.day), hours * 3_600)
        })
    }

    func testDebtChartSlotsKeepEmptyMorningsEmpty() {
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_785_000_000))
        // Confirmed nights on days -6, -3, -1, 0; nothing on -5, -4, -2.
        let nights = [
            night(id: "a", day: anchor, hours: 7.5),
            night(id: "b", day: day(-1, from: anchor), hours: 5.5),
            night(id: "c", day: day(-3, from: anchor), hours: 8.2),
            night(id: "d", day: day(-6, from: anchor), hours: 8.0)
        ]
        let slots = AtriaSleepDebtChartPresentation.slots(
            nights: nights,
            frozenNeedSecondsByDay: frozenNeeds(nights, hours: 8)
        )
        XCTAssertEqual(slots.count, 7)
        XCTAssertEqual(slots.last?.day, anchor)
        XCTAssertEqual(AtriaSleepDebtChartPresentation.realNightCount(slots), 4)
        // Oldest-first ordering; empty mornings carry nil, never a number.
        XCTAssertEqual(slots.map { $0.sleptHours != nil },
                       [true, false, false, true, false, true, true])
        // Shortfall flags: 5.5h against an 8h need is short; empty is not.
        XCTAssertEqual(slots[5].sleptHours ?? 0, 5.5, accuracy: 0.0001)
        XCTAssertTrue(slots[5].shortfall)
        XCTAssertFalse(slots[1].shortfall)
        XCTAssertFalse(slots[3].shortfall)
        // Need per slot is the clamped base need the debt math scores against.
        XCTAssertEqual(slots.compactMap(\.needHours).count, 4)
        XCTAssertTrue(slots.compactMap(\.needHours).allSatisfy { abs($0 - 8) < 0.0001 })
    }

    func testDebtChartSlotsIgnoreNapsAndUnconfirmedNights() {
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_785_000_000))
        let nights = [
            night(id: "main", day: anchor, hours: 7.0),
            night(id: "candidate", day: day(-1, from: anchor), hours: 6.0, confirmed: false),
            night(id: "nap", day: day(-2, from: anchor), hours: 1.0, source: "manual_nap")
        ]
        let slots = AtriaSleepDebtChartPresentation.slots(
            nights: nights,
            frozenNeedSecondsByDay: frozenNeeds(nights, hours: 8)
        )
        XCTAssertEqual(AtriaSleepDebtChartPresentation.realNightCount(slots), 1)
        XCTAssertNil(slots[5].sleptHours)
        XCTAssertNil(slots[4].sleptHours)
    }

    func testWeekAgoDebtNeedsThreeRealNightsAndUsesTheSameMath() {
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_785_000_000))
        // Three nights at/before the -7d cutoff, each 1h short of an 8h need.
        var nights = [
            night(id: "now", day: anchor, hours: 8.0),
            night(id: "p1", day: day(-7, from: anchor), hours: 7.0),
            night(id: "p2", day: day(-8, from: anchor), hours: 7.0),
            night(id: "p3", day: day(-9, from: anchor), hours: 7.0)
        ]
        let debt = AtriaSleepDebtChartPresentation.weekAgoDebtHours(nights: nights,
                                                                    baseNeedHours: 8)
        let expected = AtriaSleepBudget.sleepDebt(nights: [(8, 7), (8, 7), (8, 7)])
        XCTAssertEqual(debt ?? -1, expected, accuracy: 0.0001)

        // Two past nights only: honestly nil, so no delta line renders.
        nights.removeLast()
        XCTAssertNil(AtriaSleepDebtChartPresentation.weekAgoDebtHours(nights: nights,
                                                                      baseNeedHours: 8))
        XCTAssertNil(AtriaSleepDebtChartPresentation.weekDeltaText(currentDebtHours: 1,
                                                                   weekAgoDebtHours: nil))
        XCTAssertEqual(AtriaSleepDebtChartPresentation.weekDeltaText(currentDebtHours: 1.0,
                                                                     weekAgoDebtHours: 1.4),
                       "Down 24m from last week")
        XCTAssertEqual(AtriaSleepDebtChartPresentation.weekDeltaText(currentDebtHours: 1.4,
                                                                     weekAgoDebtHours: 1.0),
                       "Up 24m from last week")
        XCTAssertEqual(AtriaSleepDebtChartPresentation.weekDeltaText(currentDebtHours: 1.0,
                                                                     weekAgoDebtHours: 1.02),
                       "About even with last week")
    }

    // MARK: - Smart wake axis (6c)

    func testSmartWakeAxisEndsAtWakeByWithRealWindow() {
        let wakeBy = 7 * 60 + 30
        let ticks = AtriaSmartWakePresentation.ticks(wakeByMinutes: wakeBy)
        XCTAssertEqual(ticks.last, AtriaSmartWakePresentation.Tick(fraction: 1, label: "7:30a"))
        // Interior ticks are whole clock hours inside the 9h span.
        for tick in ticks.dropLast() {
            XCTAssertGreaterThan(tick.fraction, 0)
            XCTAssertLessThan(tick.fraction, 0.88)
        }
        // The band is the planner's real 30-minute window ending at wake-by.
        let window = AtriaSmartWakePresentation.windowFractions
        XCTAssertEqual(window.end, 1.0, accuracy: 0.0001)
        XCTAssertEqual((window.end - window.start) * Double(AtriaSmartWakePresentation.axisSpanMinutes),
                       AtriaWakeAlarmPlanner.smartWindowDuration / 60,
                       accuracy: 0.0001)
    }

    func testSmartWakeClockLabelsWrapMidnightAndKeepMinutes() {
        XCTAssertEqual(AtriaSmartWakePresentation.clockLabel(minutesOfDay: 23 * 60), "11p")
        XCTAssertEqual(AtriaSmartWakePresentation.clockLabel(minutesOfDay: -60), "11p")
        XCTAssertEqual(AtriaSmartWakePresentation.clockLabel(minutesOfDay: 0), "12a")
        XCTAssertEqual(AtriaSmartWakePresentation.clockLabel(minutesOfDay: 6 * 60 + 5), "6:05a")
    }
}
