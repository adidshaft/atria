import XCTest
@testable import Atria

/// Codable back-compat coverage for `DailyRollupStoreEntry.fitnessAgeDelta` —
/// the additive optional field that persists the pace-of-aging input (see
/// AtriaFitnessAge.PaceOfAging). Old rollup JSON written before this field
/// existed must keep decoding without error.
final class AtriaDailyRollupStoreTests: XCTestCase {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func testProjectedConfirmedSleepPersistsSleepAndLnRMSSD() throws {
        let day = try XCTUnwrap(Self.calendar.date(from: DateComponents(year: 2027, month: 1, day: 16)))
        let metric = SavedDailyMetric(day: day,
                                      recoveryPercent: 74,
                                      recoveryConfidence: "local",
                                      hrv: 63,
                                      restingHR: 49,
                                      respiratoryRate: 14.2,
                                      sleepDuration: 7 * 3_600,
                                      sleepSpan: 8 * 3_600,
                                      sleepStart: day.addingTimeInterval(-8 * 3_600),
                                      sleepEnd: day,
                                      sleepSource: "manual_sleep",
                                      sleepStageSegments: [],
                                      sleepConsistencyPercent: nil,
                                      strain: 6)

        let entry = try XCTUnwrap(SessionStore.makeDailyRollupStoreEntries(metrics: [metric],
                                                                           calendar: Self.calendar).first)

        XCTAssertEqual(entry.recovery, 74)
        XCTAssertEqual(entry.sleepSeconds, 7 * 3_600)
        XCTAssertEqual(entry.lnRMSSD ?? 0, log(63), accuracy: 0.000_001)
        XCTAssertEqual(entry.rhr, 49)
    }

    func testDailyRollupEntryDecodesLegacyJSONWithoutFitnessAgeDelta() throws {
        // Snapshot of a rollup row as persisted before fitnessAgeDelta existed —
        // no "fitnessAgeDelta" key present at all.
        let legacyJSON = """
        {
            "day": "2026-06-01",
            "tzOffsetMinutes": 0,
            "recovery": 62,
            "lnRMSSD": 3.4,
            "rhr": 54,
            "sleepSeconds": 25200,
            "sleepPerformance": 88,
            "bedtimeMinutes": 1380,
            "strain": 9.2,
            "respiratoryRate": 14.5
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(DailyRollupStoreEntry.self, from: data)

        XCTAssertNil(decoded.fitnessAgeDelta)
        XCTAssertNil(decoded.skinTemperatureDeviationCelsius)
        XCTAssertEqual(decoded.recovery, 62)
        XCTAssertEqual(decoded.rhr, 54)
    }

    func testDailyRollupEntryRoundTripsFitnessAgeDelta() throws {
        let entry = DailyRollupStoreEntry(day: Date(timeIntervalSince1970: 1_780_000_000),
                                          recovery: 70,
                                          rhr: 50,
                                          strain: 11.0,
                                          skinTemperatureDeviationCelsius: 0.4,
                                          fitnessAgeDelta: -3)
        XCTAssertEqual(entry.fitnessAgeDelta, -3)
        XCTAssertEqual(entry.skinTemperatureDeviationCelsius, 0.4)

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DailyRollupStoreEntry.self, from: data)

        XCTAssertEqual(decoded.fitnessAgeDelta, -3)
        XCTAssertEqual(decoded.skinTemperatureDeviationCelsius, 0.4)
        XCTAssertEqual(decoded.day, entry.day)
    }

    func testDailyRollupStoreUpsertPreservesFitnessAgeDeltaThroughNormalization() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-rollups-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = DailyRollupStore(url: tempURL, calendar: Self.calendar)
        let day = Self.calendar.startOfDay(for: Date())
        let entry = DailyRollupStoreEntry(day: day,
                                          recovery: 65,
                                          skinTemperatureDeviationCelsius: -0.2,
                                          fitnessAgeDelta: 2,
                                          calendar: Self.calendar)
        store.upsert(entry)

        let fetched = store.rollup(for: day)
        XCTAssertEqual(fetched?.fitnessAgeDelta, 2)
        XCTAssertEqual(fetched?.skinTemperatureDeviationCelsius, -0.2)
    }

    func testDailyRollupStoreBatchUpsertReplacesMatchingDaysAndKeepsOthers() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-rollups-batch-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = DailyRollupStore(url: tempURL, calendar: Self.calendar)
        let base = Self.calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let previousDay = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -1, to: base))
        let nextDay = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: 1, to: base))

        store.upsertMany([
            DailyRollupStoreEntry(day: previousDay, recovery: 60, fitnessAgeDelta: -1, calendar: Self.calendar),
            DailyRollupStoreEntry(day: base, recovery: 61, fitnessAgeDelta: 1, calendar: Self.calendar)
        ])

        store.upsertMany([
            DailyRollupStoreEntry(day: base, recovery: 75, fitnessAgeDelta: 3, calendar: Self.calendar),
            DailyRollupStoreEntry(day: nextDay, recovery: 80, fitnessAgeDelta: -2, calendar: Self.calendar)
        ])

        XCTAssertEqual(store.rollup(for: previousDay)?.recovery, 60)
        XCTAssertEqual(store.rollup(for: previousDay)?.fitnessAgeDelta, -1)
        XCTAssertEqual(store.rollup(for: base)?.recovery, 75)
        XCTAssertEqual(store.rollup(for: base)?.fitnessAgeDelta, 3)
        XCTAssertEqual(store.rollup(for: nextDay)?.recovery, 80)
    }

    func testDailyRollupStoreRepeatedUpsertKeepsOneRowPerDayAndNewestOrder() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-rollups-index-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = DailyRollupStore(url: tempURL, calendar: Self.calendar)
        let base = Self.calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let previousDay = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -1, to: base))
        let nextDay = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: 1, to: base))

        store.upsertMany([
            DailyRollupStoreEntry(day: previousDay, recovery: 60, calendar: Self.calendar),
            DailyRollupStoreEntry(day: base, recovery: 61, calendar: Self.calendar)
        ])
        store.upsert(DailyRollupStoreEntry(day: base, recovery: 72, calendar: Self.calendar))
        store.upsert(DailyRollupStoreEntry(day: base, recovery: 75, calendar: Self.calendar))
        store.upsert(DailyRollupStoreEntry(day: nextDay, recovery: 80, calendar: Self.calendar))

        let allRollups = store.rollups(last: 10)
        XCTAssertEqual(allRollups.map(\.day), [nextDay, base, previousDay])
        XCTAssertEqual(allRollups.map(\.recovery), [80, 75, 60])
        XCTAssertEqual(Set(allRollups.map(\.day)).count, allRollups.count)
        XCTAssertEqual(store.rollup(for: base)?.recovery, 75)
    }

    func testReconcileUpsertsPreparedRowsInvalidatesMissingDaysAndKeepsUnrelatedDays() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-rollups-reconcile-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = DailyRollupStore(url: tempURL, calendar: Self.calendar)
        let base = Self.calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let invalidatedDay = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -1, to: base))
        let unrelatedDay = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -2, to: base))
        store.upsertMany([
            DailyRollupStoreEntry(day: base, recovery: 55, calendar: Self.calendar),
            DailyRollupStoreEntry(day: invalidatedDay, recovery: 60, rhr: 54, calendar: Self.calendar),
            DailyRollupStoreEntry(day: unrelatedDay, recovery: 70, fitnessAgeDelta: -2, calendar: Self.calendar)
        ])

        let staleOffset = -720
        store.reconcile([
            DailyRollupStoreEntry(day: base.addingTimeInterval(12 * 60 * 60),
                                  tzOffsetMinutes: staleOffset,
                                  recovery: 82,
                                  rhr: 48,
                                  calendar: Self.calendar)
        ], replacingDays: [base, invalidatedDay.addingTimeInterval(8 * 60 * 60)])

        XCTAssertEqual(store.rollup(for: base)?.recovery, 82)
        XCTAssertEqual(store.rollup(for: base)?.rhr, 48)
        XCTAssertEqual(store.rollup(for: base)?.tzOffsetMinutes,
                       Self.calendar.timeZone.secondsFromGMT(for: base) / 60)
        XCTAssertNil(store.rollup(for: invalidatedDay))
        XCTAssertEqual(store.rollup(for: unrelatedDay)?.recovery, 70)
        XCTAssertEqual(store.rollup(for: unrelatedDay)?.fitnessAgeDelta, -2)
        XCTAssertEqual(store.rollups(last: 10).map(\.day), [base, unrelatedDay])
    }

    func testReconcileRetainsOnlyNutritionAndFitnessAgeDeltaForMissingPreparedDay() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-rollups-reconcile-fields-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = DailyRollupStore(url: tempURL, calendar: Self.calendar)
        let day = Self.calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let vitals = DailyRollupVitals(rhr: .init(mean: 52, sd: 2, n: 4),
                                      hrv: .init(mean: 45, sd: 3, n: 4),
                                      resp: .init(mean: 14, sd: 1, n: 4))
        let nutrition = AtriaNutritionSummary(kcal: 2_100,
                                              proteinG: 130,
                                              caffeineMg: 120,
                                              lastCaffeineHour: 13)
        store.upsert(DailyRollupStoreEntry(day: day,
                                           recovery: 65,
                                           lnRMSSD: 3.7,
                                           rhr: 52,
                                           sleepSeconds: 27_000,
                                           sleepPerformance: 90,
                                           bedtimeMinutes: 1_380,
                                           strain: 10.5,
                                           respiratoryRate: 14.2,
                                           skinTemperatureDeviationCelsius: 0.3,
                                           vitals: vitals,
                                           nutrition: nutrition,
                                           fitnessAgeDelta: -3,
                                           calendar: Self.calendar))

        store.reconcile([], replacingDays: [day.addingTimeInterval(6 * 60 * 60)])

        let retained = try XCTUnwrap(store.rollup(for: day))
        XCTAssertNil(retained.recovery)
        XCTAssertNil(retained.lnRMSSD)
        XCTAssertNil(retained.rhr)
        XCTAssertNil(retained.sleepSeconds)
        XCTAssertNil(retained.sleepPerformance)
        XCTAssertNil(retained.bedtimeMinutes)
        XCTAssertNil(retained.strain)
        XCTAssertNil(retained.respiratoryRate)
        XCTAssertNil(retained.skinTemperatureDeviationCelsius)
        XCTAssertNil(retained.vitals)
        XCTAssertEqual(retained.nutrition, nutrition)
        XCTAssertEqual(retained.fitnessAgeDelta, -3)
    }

    func testReconcilePersistsInvalidationThroughDiskReload() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-rollups-reconcile-reload-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let removedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
        let store = DailyRollupStore(url: tempURL, calendar: calendar)
        store.upsertMany([
            DailyRollupStoreEntry(day: day,
                                  recovery: 72,
                                  nutrition: AtriaNutritionSummary(proteinG: 125),
                                  fitnessAgeDelta: 1,
                                  calendar: calendar),
            DailyRollupStoreEntry(day: removedDay, recovery: 64, calendar: calendar)
        ])

        store.reconcile([], replacingDays: [day, removedDay])
        _ = try waitForPersistedRollups(at: tempURL) { entries in
            entries.count == 1
                && entries.first?.day == day
                && entries.first?.recovery == nil
                && entries.first?.nutrition?.proteinG == 125
                && entries.first?.fitnessAgeDelta == 1
        }

        let reloaded = DailyRollupStore(url: tempURL, calendar: calendar)
        XCTAssertNil(reloaded.rollup(for: removedDay))
        XCTAssertNil(reloaded.rollup(for: day)?.recovery)
        XCTAssertEqual(reloaded.rollup(for: day)?.nutrition?.proteinG, 125)
        XCTAssertEqual(reloaded.rollup(for: day)?.fitnessAgeDelta, 1)
    }

    func testUpdateCalendarKolkataToLosAngelesPreservesCivilDayAndOneRowOnUpsert() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-rollups-calendar-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let kolkata = calendar(timeZoneIdentifier: "Asia/Kolkata")
        let losAngeles = calendar(timeZoneIdentifier: "America/Los_Angeles")
        let kolkataJuly10 = try XCTUnwrap(kolkata.date(from: DateComponents(year: 2026,
                                                                           month: 7,
                                                                           day: 10,
                                                                           hour: 14)))
        let store = DailyRollupStore(url: tempURL, calendar: kolkata)
        store.upsert(DailyRollupStoreEntry(day: kolkataJuly10,
                                           recovery: 67,
                                           calendar: kolkata))

        XCTAssertTrue(store.updateCalendar(losAngeles))

        let losAngelesJuly10 = try XCTUnwrap(losAngeles.date(from: DateComponents(year: 2026,
                                                                                 month: 7,
                                                                                 day: 10)))
        let migrated = try XCTUnwrap(store.rollup(for: losAngelesJuly10))
        XCTAssertEqual(losAngeles.dateComponents([.year, .month, .day], from: migrated.day),
                       DateComponents(year: 2026, month: 7, day: 10))
        XCTAssertEqual(migrated.tzOffsetMinutes,
                       losAngeles.timeZone.secondsFromGMT(for: losAngelesJuly10) / 60)

        store.upsert(DailyRollupStoreEntry(day: losAngelesJuly10.addingTimeInterval(18 * 60 * 60),
                                           recovery: 81,
                                           calendar: losAngeles))

        XCTAssertEqual(store.rollups(last: 10).count, 1)
        XCTAssertEqual(store.rollup(for: losAngelesJuly10)?.recovery, 81)
        XCTAssertFalse(store.updateCalendar(losAngeles))
    }

    func testUpdateCalendarPersistsLosAngelesCivilKeyAndOffsetForRoundTrip() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-rollups-calendar-reload-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let kolkata = calendar(timeZoneIdentifier: "Asia/Kolkata")
        let losAngeles = calendar(timeZoneIdentifier: "America/Los_Angeles")
        let kolkataJuly10 = try XCTUnwrap(kolkata.date(from: DateComponents(year: 2026,
                                                                           month: 7,
                                                                           day: 10)))
        let losAngelesJuly10 = try XCTUnwrap(losAngeles.date(from: DateComponents(year: 2026,
                                                                                 month: 7,
                                                                                 day: 10)))
        let expectedOffset = losAngeles.timeZone.secondsFromGMT(for: losAngelesJuly10) / 60
        let store = DailyRollupStore(url: tempURL, calendar: kolkata)
        store.upsert(DailyRollupStoreEntry(day: kolkataJuly10,
                                           recovery: 73,
                                           calendar: kolkata))
        XCTAssertTrue(store.updateCalendar(losAngeles))

        _ = try waitForPersistedRollups(at: tempURL) { entries in
            entries.count == 1
                && entries.first?.day == losAngelesJuly10
                && entries.first?.tzOffsetMinutes == expectedOffset
        }
        let data = try Data(contentsOf: tempURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json.first?["day"] as? String, "2026-07-10")
        XCTAssertEqual(json.first?["tzOffsetMinutes"] as? Int, expectedOffset)

        let reloaded = DailyRollupStore(url: tempURL, calendar: losAngeles)
        let roundTripped = try XCTUnwrap(reloaded.rollup(for: losAngelesJuly10))
        XCTAssertEqual(roundTripped.day, losAngelesJuly10)
        XCTAssertEqual(roundTripped.tzOffsetMinutes, expectedOffset)
        XCTAssertEqual(roundTripped.recovery, 73)
    }

    func testColdLaunchInNewTimezonePreservesPersistedCivilDay() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-rollups-travel-launch-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let kolkata = calendar(timeZoneIdentifier: "Asia/Kolkata")
        let losAngeles = calendar(timeZoneIdentifier: "America/Los_Angeles")
        let kolkataJuly10 = try XCTUnwrap(kolkata.date(from: DateComponents(year: 2026,
                                                                           month: 7,
                                                                           day: 10)))
        let kolkataStore = DailyRollupStore(url: tempURL, calendar: kolkata)
        kolkataStore.upsert(DailyRollupStoreEntry(day: kolkataJuly10,
                                                  recovery: 74,
                                                  calendar: kolkata))
        _ = try waitForPersistedRollups(at: tempURL) { $0.first?.recovery == 74 }

        let losAngelesStore = DailyRollupStore(url: tempURL, calendar: losAngeles)
        let losAngelesJuly10 = try XCTUnwrap(losAngeles.date(from: DateComponents(year: 2026,
                                                                                 month: 7,
                                                                                 day: 10)))
        let migrated = try XCTUnwrap(losAngelesStore.rollup(for: losAngelesJuly10))

        XCTAssertEqual(migrated.day, losAngelesJuly10)
        XCTAssertEqual(migrated.recovery, 74)
        XCTAssertEqual(migrated.tzOffsetMinutes,
                       losAngeles.timeZone.secondsFromGMT(for: losAngelesJuly10) / 60)
    }

    private func calendar(timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar
    }

    private func waitForPersistedRollups(
        at url: URL,
        timeout: TimeInterval = 2,
        until condition: ([DailyRollupStoreEntry]) -> Bool
    ) throws -> [DailyRollupStoreEntry] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let data = try? Data(contentsOf: url),
               let entries = try? JSONDecoder().decode([DailyRollupStoreEntry].self, from: data),
               condition(entries) {
                return entries
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline

        XCTFail("Timed out waiting for daily rollups to persist")
        return []
    }
}
