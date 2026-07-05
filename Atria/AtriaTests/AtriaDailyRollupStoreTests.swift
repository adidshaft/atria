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
        XCTAssertEqual(decoded.recovery, 62)
        XCTAssertEqual(decoded.rhr, 54)
    }

    func testDailyRollupEntryRoundTripsFitnessAgeDelta() throws {
        // Note: uses the default (.current) calendar to match the entry's own
        // "yyyy-MM-dd" day formatter, which is always keyed to the device's
        // local time zone regardless of which calendar callers pass in for
        // day-normalization — a mismatched calendar here would make the
        // round-tripped `day` land on a different local calendar date.
        let entry = DailyRollupStoreEntry(day: Date(timeIntervalSince1970: 1_780_000_000),
                                          recovery: 70,
                                          rhr: 50,
                                          strain: 11.0,
                                          fitnessAgeDelta: -3)
        XCTAssertEqual(entry.fitnessAgeDelta, -3)

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DailyRollupStoreEntry.self, from: data)

        XCTAssertEqual(decoded.fitnessAgeDelta, -3)
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
                                          fitnessAgeDelta: 2,
                                          calendar: Self.calendar)
        store.upsert(entry)

        let fetched = store.rollup(for: day)
        XCTAssertEqual(fetched?.fitnessAgeDelta, 2)
    }
}
