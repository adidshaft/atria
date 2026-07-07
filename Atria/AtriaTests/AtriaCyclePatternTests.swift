import XCTest
@testable import Atria

/// Cycle-phase patterns (2026-07-07, design backlog item 10): the historical
/// classifier must refuse to guess (no wrap past one cycle length, nothing
/// before the first log) and the aggregation must gate on personalized data.
final class AtriaCyclePatternTests: XCTestCase {
    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    private func day(_ offset: Int, from base: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: base)!
    }

    @MainActor
    private func makeStore(cycleStarts: [Int], base: Date) -> AtriaCycleTrackingStore {
        // Isolated per-store temp directory: the default init reads/writes
        // the real documents file, which leaks state across tests.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cycle-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AtriaCycleTrackingStore(directory: directory)
        for offset in cycleStarts {
            _ = store.logPeriodStart(day(offset, from: base), calendar: calendar)
        }
        return store
    }

    @MainActor
    func testHistoricalDayBeforeFirstLogIsUnclassified() {
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeStore(cycleStarts: [0, 28, 56], base: base)
        XCTAssertNil(store.phaseEstimate(on: day(-5, from: base), calendar: calendar))
    }

    @MainActor
    func testHistoricalDayNeverWrapsPastOneCycle() {
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeStore(cycleStarts: [0], base: base)
        // 40 days after the only logged start, with a 28-day default cycle:
        // refuse to classify rather than wrap-guess.
        XCTAssertNil(store.phaseEstimate(on: day(40, from: base), calendar: calendar))
    }

    @MainActor
    func testEarlyCycleDaysClassifyMenstrualThenFollicular() {
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeStore(cycleStarts: [0, 28, 56], base: base)
        // Starts logged without explicit ends close at ~zero length, so the
        // median period is 1 day: only the start day itself is menstrual.
        XCTAssertEqual(store.phaseEstimate(on: day(56, from: base), calendar: calendar), .menstrual)
        XCTAssertEqual(store.phaseEstimate(on: day(60, from: base), calendar: calendar), .follicular)
    }

    @MainActor
    func testPatternsRequireTwoCompletedCycles() {
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeStore(cycleStarts: [0], base: base)
        let days = (0..<60).map { (day: day($0, from: base), recovery: Optional(70)) }
        XCTAssertTrue(store.recoveryPatternsByPhase(days: days, now: day(59, from: base), calendar: calendar).isEmpty)
    }

    @MainActor
    func testPatternsAggregatePerPhase() {
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeStore(cycleStarts: [0, 28, 56], base: base)
        let days = (0..<84).map { (day: day($0, from: base), recovery: Optional(70)) }
        let patterns = store.recoveryPatternsByPhase(days: days, now: day(83, from: base), calendar: calendar)
        XCTAssertFalse(patterns.isEmpty)
        XCTAssertTrue(patterns.allSatisfy { $0.averageRecovery == 70 && $0.dayCount >= 3 })
    }
}
