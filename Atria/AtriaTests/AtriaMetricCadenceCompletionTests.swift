import XCTest
@testable import Atria

@MainActor
final class AtriaMetricCadenceCompletionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testPhysiologicalDayCaloriesMergeReplacesCheckpointedLivePrefix() {
        XCTAssertEqual(SessionStore.mergedTodayActiveCalories(
            savedToday: 320,
            savedActiveSession: 120,
            liveActiveSession: 180
        ), 380)
        XCTAssertEqual(SessionStore.mergedTodayActiveCalories(
            savedToday: 320,
            savedActiveSession: 120,
            liveActiveSession: 80
        ), 320,
        "A restoring live accumulator must never erase its durable checkpoint")
        XCTAssertEqual(SessionStore.mergedTodayActiveCalories(
            savedToday: nil,
            savedActiveSession: nil,
            liveActiveSession: 42
        ), 42)
        XCTAssertNil(SessionStore.mergedTodayActiveCalories(
            savedToday: nil,
            savedActiveSession: nil,
            liveActiveSession: nil
        ))
    }

    func testHomeAggregateCarriesSavedAndActiveSessionCalories() throws {
        let profile = energyProfile()
        let active = session(start: start, bpm: 142)
        let completed = session(start: active.end.addingTimeInterval(30), bpm: 154)
        let now = completed.end.addingTimeInterval(1)
        let interval = DateInterval(start: start, end: now)

        let aggregate = SessionStore.homeSavedAggregate(
            from: [active, completed],
            rest: 58,
            maxHR: profile.maxHR,
            biologicalSex: profile.biologicalSex,
            profile: profile,
            activeSessionID: active.id,
            now: now,
            cycleStart: start
        )

        let expectedActive = try XCTUnwrap(active.activeCalories(
            rest: 58,
            profile: profile,
            within: interval
        ))
        let expectedCompleted = try XCTUnwrap(completed.activeCalories(
            rest: 58,
            profile: profile,
            within: interval
        ))
        XCTAssertEqual(try XCTUnwrap(aggregate.savedActiveSessionActiveCalories),
                       expectedActive,
                       accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(aggregate.savedTodayActiveCalories),
                       expectedActive + expectedCompleted,
                       accuracy: 0.000_001)
    }

    func testCaloriesStayUnavailableWithoutRequiredProfileProvenance() {
        let aggregate = SessionStore.homeSavedAggregate(
            from: [session(start: start, bpm: 150)],
            rest: 58,
            maxHR: 190,
            biologicalSex: .unspecified,
            profile: nil,
            now: start.addingTimeInterval(601),
            cycleStart: start
        )

        XCTAssertNil(aggregate.savedTodayActiveCalories)
        XCTAssertNil(aggregate.savedActiveSessionActiveCalories)
    }

    func testCaloriesStayUnavailableWithoutHeartRateEvidence() {
        let profile = energyProfile()
        let aggregate = SessionStore.homeSavedAggregate(
            from: [],
            rest: 58,
            maxHR: profile.maxHR,
            biologicalSex: profile.biologicalSex,
            profile: profile,
            now: start.addingTimeInterval(601),
            cycleStart: start
        )

        XCTAssertNil(aggregate.savedTodayActiveCalories)
        XCTAssertNil(aggregate.savedActiveSessionActiveCalories)
    }

    func testWorkoutFreshnessClockBeatsEverySensorExpiryWindow() {
        XCTAssertLessThan(AtriaHomeView.liveWorkoutFreshnessRefreshInterval,
                          AtriaHomeModel.liveHeartRateFreshnessInterval)
        XCTAssertLessThan(AtriaHomeView.liveWorkoutFreshnessRefreshInterval,
                          AtriaLiveWorkoutStepProjection.freshnessInterval)
    }

    private func energyProfile() -> AthleteProfile {
        AthleteProfile(age: 34,
                       measuredMaxHR: 190,
                       maxHRSource: .measured,
                       biologicalSex: .male,
                       weightKg: 76,
                       heightCm: 178,
                       updated: start,
                       hasCompletedOnboarding: true)
    }

    private func session(start: Date, bpm: Int) -> SavedSession {
        let points = (0...60).map { index in
            SavedSession.Point(t: TimeInterval(index * 10), bpm: bpm + index % 2)
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(600),
                            label: "Metric cadence fixture",
                            points: points)
    }
}
