import XCTest
@testable import Atria

/// Strain-trend consistency (2026-07-08 audit): a day's strain is
/// score(SUM of session TRIMPs), NOT the average of per-session scores. Since
/// score() saturates, averaging per-session scores under-reports ~2x — the
/// trend chart used to disagree with every other strain surface.
final class AtriaStrainConsistencyTests: XCTestCase {
    private func workout(start: Date, bpm: Int, minutes: Int) -> SavedSession {
        let pts = stride(from: 0, through: minutes * 60, by: 10).map { SavedSession.Point(t: Double($0), bpm: bpm) }
        return SavedSession(id: UUID(), start: start, end: start.addingTimeInterval(Double(minutes * 60)),
                            label: "Workout", points: pts, respiratoryRate: nil, rrPoints: [],
                            sleepWakeResearchState: nil)
    }

    func testPerDayStrainSumsWithinDayAndBeatsPerSessionAverage() {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(10 * 3600)
        let s1 = workout(start: day, bpm: 150, minutes: 25)
        let s2 = workout(start: day.addingTimeInterval(3600), bpm: 150, minutes: 25)
        let strains = SessionStore.perDayStrains([s1, s2], rest: 60, maxHR: 190)
        XCTAssertEqual(strains.count, 1, "two same-day sessions collapse to one day strain")
        let t1 = s1.trimp(rest: 60, max: 190), t2 = s2.trimp(rest: 60, max: 190)
        XCTAssertGreaterThan(t1, 0)
        XCTAssertEqual(strains[0], Metrics.strain(fromTRIMP: t1 + t2), accuracy: 0.01)
        let perSessionAverage = (Metrics.strain(fromTRIMP: t1) + Metrics.strain(fromTRIMP: t2)) / 2
        XCTAssertGreaterThan(strains[0], perSessionAverage + 0.5,
                             "day-summed strain must exceed per-session average (the ~2x under-report)")
    }

    func testPerDayStrainSeparatesDifferentDays() {
        let day1 = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(10 * 3600)
        let day2 = day1.addingTimeInterval(48 * 3600)
        let strains = SessionStore.perDayStrains([workout(start: day1, bpm: 150, minutes: 25),
                                                  workout(start: day2, bpm: 150, minutes: 25)],
                                                 rest: 60, maxHR: 190)
        XCTAssertEqual(strains.count, 2)
    }
    // Recovery honesty (2026-07-08 audit): unknown in-bed span must NOT read as
    // 100% efficiency — return nil so recovery skips the sleep signal.
    func testSleepEfficiencyNilWhenSpanUnknown() {
        XCTAssertNil(SessionStore.sleepEfficiency(duration: 7 * 3600, span: nil))
        XCTAssertNil(SessionStore.sleepEfficiency(duration: nil, span: 8 * 3600))
    }

    func testSleepEfficiencyComputesWhenSpanKnown() {
        let e = SessionStore.sleepEfficiency(duration: 7 * 3600, span: 8 * 3600)
        XCTAssertEqual(e ?? 0, 0.875, accuracy: 0.001)
        // span shorter than duration clamps to <= 1 (never > 100%).
        XCTAssertEqual(SessionStore.sleepEfficiency(duration: 8 * 3600, span: 7 * 3600) ?? 0, 1.0, accuracy: 0.001)
    }
}

