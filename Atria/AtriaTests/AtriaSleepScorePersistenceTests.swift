import XCTest
@testable import Atria

/// WP-6 follow-up — the night's provisional Sleep Score persists on the daily
/// rollup as a receipt derived only from frozen inputs, so a settled night can
/// never drift as the rolling consistency window moves.
final class AtriaSleepScorePersistenceTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    private func day(_ dayOfMonth: Int) -> Date {
        DateComponents(calendar: calendar,
                       timeZone: calendar.timeZone,
                       year: 2026, month: 8, day: dayOfMonth).date!
    }

    private func settledMetric(dayOfMonth: Int,
                               needHours: Double = 8,
                               sleptHours: Double = 7,
                               consistency: Int? = 82) -> SavedDailyMetric {
        let wake = day(dayOfMonth).addingTimeInterval(6 * 3_600)
        return SavedDailyMetric(day: day(dayOfMonth),
                                recoveryPercent: 60,
                                recoveryConfidence: "personal baseline",
                                hrv: 60,
                                restingHR: 50,
                                respiratoryRate: nil,
                                sleepDuration: sleptHours * 3_600,
                                sleepNeedSeconds: needHours * 3_600,
                                sleepSpan: sleptHours * 3_600,
                                sleepStart: wake.addingTimeInterval(-sleptHours * 3_600),
                                sleepEnd: wake,
                                sleepSource: "manual_sleep",
                                sleepStageSegments: [],
                                sleepConsistencyPercent: consistency,
                                strain: 10)
    }

    func testMintDerivesTheReceiptFromFrozenInputsOnly() throws {
        let metric = settledMetric(dayOfMonth: 10)
        let efficiencyByDay = [calendar.startOfDay(for: day(10)): 0.93]

        let entry = try XCTUnwrap(SessionStore.makeDailyRollupStoreEntries(
            metrics: [metric],
            displaySleepEfficiencyByDay: efficiencyByDay,
            calendar: calendar
        ).first)

        let expectedSufficiency = AtriaSleepBudget.performancePercent(slept: 7, needed: 8)
        let expected = AtriaSleepScore.provisional(sufficiencyPercent: Double(expectedSufficiency),
                                                   consistencyPercent: 82,
                                                   efficiencyPercent: 93)
        XCTAssertEqual(entry.sleepScore, expected,
                       "the stored receipt must be exactly the provisional composite of the frozen inputs")
        XCTAssertEqual(entry.sleepScore?.presentComponents,
                       [.sufficiency, .consistency, .efficiency])
    }

    func testRemintIsDeterministicAndLaterNightsCannotDriftASettledScore() throws {
        let settled = settledMetric(dayOfMonth: 10)
        let efficiencyByDay = [calendar.startOfDay(for: day(10)): 0.93]

        let first = try XCTUnwrap(SessionStore.makeDailyRollupStoreEntries(
            metrics: [settled],
            displaySleepEfficiencyByDay: efficiencyByDay,
            calendar: calendar
        ).first)

        // Days later: new nights exist with wildly different consistency. The
        // settled day's metric carries ITS morning's frozen consistency, so
        // the re-minted receipt is byte-identical.
        let laterNights = [settledMetric(dayOfMonth: 11, consistency: 12),
                           settledMetric(dayOfMonth: 12, consistency: 5)]
        let remint = try XCTUnwrap(SessionStore.makeDailyRollupStoreEntries(
            metrics: [settled] + laterNights,
            displaySleepEfficiencyByDay: efficiencyByDay,
            calendar: calendar
        ).first { calendar.isDate($0.day, inSameDayAs: day(10)) })

        XCTAssertEqual(remint.sleepScore, first.sleepScore,
                       "a settled night's receipt must not move when later nights land")
    }

    func testSingleComponentNightsStoreNoReceipt() throws {
        // No frozen consistency and no qualified efficiency → Sufficiency
        // alone → the composite is withheld and nothing is stored.
        let metric = settledMetric(dayOfMonth: 10, consistency: nil)
        let entry = try XCTUnwrap(SessionStore.makeDailyRollupStoreEntries(
            metrics: [metric],
            calendar: calendar
        ).first)
        XCTAssertNil(entry.sleepScore)

        // The entry initializer itself refuses a score-nil receipt.
        let withheld = AtriaSleepScore.provisional(sufficiencyPercent: 90,
                                                   consistencyPercent: nil,
                                                   efficiencyPercent: nil)
        let direct = DailyRollupStoreEntry(day: day(10), sleepScore: withheld, calendar: calendar)
        XCTAssertNil(direct.sleepScore)
    }

    func testReceiptSurvivesRollupEntryJSONRoundTrip() throws {
        let metric = settledMetric(dayOfMonth: 10)
        let entry = try XCTUnwrap(SessionStore.makeDailyRollupStoreEntries(
            metrics: [metric],
            displaySleepEfficiencyByDay: [calendar.startOfDay(for: day(10)): 0.93],
            calendar: calendar
        ).first)
        XCTAssertNotNil(entry.sleepScore)

        let restored = try JSONDecoder().decode(DailyRollupStoreEntry.self,
                                                from: JSONEncoder().encode(entry))
        XCTAssertEqual(restored.sleepScore, entry.sleepScore,
                       "the receipt must survive the rollup store's JSON encoding")
        XCTAssertEqual(restored, entry)
    }

    func testEfficiencyMapCarriesOnlyMotionQualifiedNights() throws {
        let motionValidated = UserConfirmedSleep(id: "validated",
                                                 createdAt: day(10),
                                                 start: day(10).addingTimeInterval(-7 * 3_600),
                                                 end: day(10),
                                                 source: "manual_sleep",
                                                 confidence: "user_adjusted_motion_validated",
                                                 sessions: 1,
                                                 samples: 100,
                                                 avgHR: 52,
                                                 peakHR: 60,
                                                 restingHR: 50,
                                                 hrv: 60,
                                                 hrvWindowCount: 4,
                                                 duration: 6.5 * 3_600,
                                                 span: 7 * 3_600,
                                                 reason: "test",
                                                 motionSource: "strap_motion",
                                                 motionValidated: true,
                                                 stageSegments: nil,
                                                 eventTimeZoneIdentifier: calendar.timeZone.identifier)
        let hrOnly = UserConfirmedSleep(id: "hr-only",
                                        createdAt: day(11),
                                        start: day(11).addingTimeInterval(-7 * 3_600),
                                        end: day(11),
                                        source: "manual_sleep",
                                        confidence: "user_adjusted_hr_only",
                                        sessions: 1,
                                        samples: 100,
                                        avgHR: 52,
                                        peakHR: 60,
                                        restingHR: 50,
                                        hrv: 60,
                                        hrvWindowCount: 4,
                                        duration: 7 * 3_600,
                                        span: 7 * 3_600,
                                        reason: "test",
                                        motionSource: "manual",
                                        motionValidated: false,
                                        stageSegments: nil,
                                        eventTimeZoneIdentifier: calendar.timeZone.identifier)
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [motionValidated, hrOnly],
                                            calendar: calendar)
        let map = SessionStore.displaySleepEfficiencyByMorningDay(sleep: snapshot,
                                                                  calendar: calendar)

        XCTAssertNil(map[calendar.startOfDay(for: day(11))],
                     "an HR-only night's span coverage must never enter the efficiency component")
        if let night = snapshot.nights.first(where: { $0.id == "validated" }),
           night.displaySleepEfficiency != nil {
            XCTAssertNotNil(map[calendar.startOfDay(for: night.day)])
        }
    }

    /// The Health screen must prefer the persisted receipt for a settled night
    /// and compute live only before the rollup lands.
    func testHealthScreenPrefersTheStoredReceipt() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHealthScreen.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("if let stored = vitalsStore.state.dailyRollupHistory"))
        XCTAssertTrue(source.contains(".sleepScore {"))
        XCTAssertTrue(source.contains("return stored.score == nil ? nil : stored"))
    }
}
