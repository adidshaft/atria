import XCTest
@testable import Atria

/// The exact per-calendar-day step authority: policy units, plus an
/// integration pass over the owner's real pulled shards when present.
final class AtriaCivilDayStepAuthorityTests: XCTestCase {

    private static let shardDirectory =
        "/private/tmp/claude-501/-Users-amanpandey-projects-atria/"
        + "90cb7ac0-fd92-46ca-acf1-b136c273c440/scratchpad/devpull/"
        + "Library/Application Support/Atria/whoop4-motion-compact-v1"
    private static let strap = "C125C62E-C432-53E7-BD19-9761251B2C3E"

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private func istDay(_ day: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = day
        return calendar.date(from: c)!
    }

    // MARK: - Cache-validity policy

    private func record(fingerprint: String = "fp",
                        exclusions: String = "",
                        computedAt: Double,
                        complete: Bool) -> AtriaCivilDayStepAuthority.DayRecord {
        .init(dayStartUnix: 0, steps: 100, ticks: 120,
              knownCoverageSeconds: 3_600,
              sourceFingerprint: fingerprint,
              exclusionFingerprint: exclusions,
              computedAtUnix: computedAt,
              dayWasComplete: complete)
    }

    func testACompleteDayIsServedForeverWhileItsShardsAreUnchanged() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(AtriaCivilDayStepAuthority.isServable(
            record: record(computedAt: 0, complete: true),
            sourceFingerprint: "fp", exclusionFingerprint: "", now: now))
    }

    func testAChangedShardFingerprintForcesRecompute() {
        // The drain landing backfilled rows into a day's shard is exactly the
        // moment its number must improve.
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertFalse(AtriaCivilDayStepAuthority.isServable(
            record: record(computedAt: 1_999_999, complete: true),
            sourceFingerprint: "DIFFERENT", exclusionFingerprint: "", now: now))
    }

    func testALabelledWorkoutInvalidatesTheDayItTouches() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertFalse(AtriaCivilDayStepAuthority.isServable(
            record: record(computedAt: 1_999_999, complete: true),
            sourceFingerprint: "fp",
            exclusionFingerprint: "123-456", now: now))
    }

    func testAnOpenDayGoesStaleAfterTheRefreshWindow() {
        let computed = 1_000_000.0
        let fresh = Date(timeIntervalSince1970: computed + 100)
        let stale = Date(timeIntervalSince1970: computed + 600)
        XCTAssertTrue(AtriaCivilDayStepAuthority.isServable(
            record: record(computedAt: computed, complete: false),
            sourceFingerprint: "fp", exclusionFingerprint: "", now: fresh))
        XCTAssertFalse(AtriaCivilDayStepAuthority.isServable(
            record: record(computedAt: computed, complete: false),
            sourceFingerprint: "fp", exclusionFingerprint: "", now: stale))
    }

    // MARK: - Exclusion policy

    func testOnlyStrengthAndCyclingAreExcluded() {
        // The set is deliberately short: over-excluding deletes real walking.
        XCTAssertEqual(AtriaCivilDayStepAuthority.nonGaitActivityKinds,
                       ["Strength", "Cycling"])

        func workout(_ type: String, hour: Int) -> UserConfirmedWorkout {
            UserConfirmedWorkout(
                id: "\(type)-\(hour)", createdAt: istDay(24),
                start: istDay(24).addingTimeInterval(Double(hour) * 3_600),
                end: istDay(24).addingTimeInterval(Double(hour) * 3_600 + 1_800),
                label: type, source: "test", confidence: "high", sessions: 1,
                samples: 100, avgHR: 100, peakHR: 140, p95HR: 130, p99HR: 135,
                thresholdHR: 120, streamCoveragePercent: 95,
                observedDuration: 1_800, reason: "test", activityType: type)
        }
        let windows = AtriaCivilDayStepAuthority.nonGaitExclusionWindows(
            workouts: [workout("Walking", hour: 9),
                       workout("Strength", hour: 11),
                       workout("Running", hour: 13),
                       workout("Cycling", hour: 15)])
        XCTAssertEqual(windows.count, 2, "Walking and Running keep their ticks")
    }

    func testExclusionFingerprintClipsToTheDay() {
        let day = istDay(24)
        let dayEnd = day.addingTimeInterval(86_400)
        let crossing = DateInterval(start: day.addingTimeInterval(-3_600),
                                    end: day.addingTimeInterval(3_600))
        let outside = DateInterval(start: dayEnd.addingTimeInterval(3_600),
                                   end: dayEnd.addingTimeInterval(7_200))
        let print1 = AtriaCivilDayStepAuthority.exclusionFingerprint(
            [crossing, outside], dayStart: day, dayEnd: dayEnd)
        XCTAssertFalse(print1.isEmpty, "the crossing hour inside the day counts")
        XCTAssertFalse(print1.contains("|"),
                       "the fully-outside window must not appear")
    }

    // MARK: - Overlay policy

    func testExactValuesOverrideTheFallbackAndGapsKeepIt() {
        let d1 = istDay(24), d2 = istDay(25), d3 = istDay(26)
        let merged = AtriaCivilDayStepAuthority.overlay(
            fallback: [d1: 505, d2: 7_626, d3: 2_893],
            exact: [d1: 7_076, d3: 7_629])
        XCTAssertEqual(merged[d1], 7_076, "exact wins")
        XCTAssertEqual(merged[d2], 7_626, "no shards -> fallback survives")
        XCTAssertEqual(merged[d3], 7_629)
    }

    // MARK: - Owner's real shards (skips when absent)

    private func realStore() throws -> AtriaWhoop4MotionTickCompactStore {
        let url = URL(fileURLWithPath: Self.shardDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("owner shard pull not present on this machine")
        }
        return AtriaWhoop4MotionTickCompactStore(directoryURL: url)
    }

    func testAuthorityMatchesTheProvenEvidenceReadOnRealShards() async throws {
        let store = try realStore()
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("civil-day-test-\(UUID().uuidString).json")
        let authority = AtriaCivilDayStepAuthority(cacheURL: cache, store: store)
        let day = istDay(26)
        let now = day.addingTimeInterval(2 * 86_400)   // day long closed

        let totals = await authority.dailyTotals(
            days: [day], strapIdentifier: Self.strap,
            nonGaitExclusions: [], fallback: [:], now: now)
        let authoritySteps = try XCTUnwrap(totals[day],
                                           "26 Aug must be answerable from shards")

        // The independent ground truth: the shipped evidence read directly.
        var direct: Int?
        let done = expectation(description: "direct read")
        DispatchQueue.global(qos: .userInitiated).async {
            if case .qualified(let e) = store.motionTickDayEvidenceRead(
                start: day, end: day.addingTimeInterval(86_400),
                bankCoverage: [], strapIdentifier: Self.strap) {
                direct = e.steps
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 180)
        XCTAssertEqual(authoritySteps, try XCTUnwrap(direct),
                       "the authority is a cache over the read, never a "
                           + "different calculation")
        // Order-of-magnitude honesty: the audit measured ~7.6k raw for 26 Aug
        // where the shipped chart said 2,893.
        XCTAssertGreaterThan(authoritySteps, 4_000)
        XCTAssertLessThan(authoritySteps, 12_000)
    }

    func testSecondCallIsServedFromTheCache() async throws {
        let store = try realStore()
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("civil-day-test-\(UUID().uuidString).json")
        let day = istDay(26)
        let now = day.addingTimeInterval(2 * 86_400)

        let first = AtriaCivilDayStepAuthority(cacheURL: cache, store: store)
        _ = await first.dailyTotals(days: [day], strapIdentifier: Self.strap,
                                    nonGaitExclusions: [], fallback: [:], now: now)

        // Rewrite the cached record with a sentinel value, keeping the real
        // fingerprints. A fresh authority instance must serve the sentinel —
        // proving the cache is consulted and keyed exactly as designed.
        let data = try Data(contentsOf: cache)
        var records = try JSONDecoder().decode(
            [AtriaCivilDayStepAuthority.DayRecord].self, from: data)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        records[0] = .init(dayStartUnix: r.dayStartUnix, steps: 123_456,
                           ticks: r.ticks,
                           knownCoverageSeconds: r.knownCoverageSeconds,
                           sourceFingerprint: r.sourceFingerprint,
                           exclusionFingerprint: r.exclusionFingerprint,
                           computedAtUnix: r.computedAtUnix,
                           dayWasComplete: r.dayWasComplete)
        try JSONEncoder().encode(records).write(to: cache)

        let second = AtriaCivilDayStepAuthority(cacheURL: cache, store: store)
        let totals = await second.dailyTotals(
            days: [day], strapIdentifier: Self.strap,
            nonGaitExclusions: [], fallback: [:], now: now)
        XCTAssertEqual(totals[day], 123_456,
                       "unchanged fingerprints must serve the cache, not decode "
                           + "90k rows again")
    }
}
