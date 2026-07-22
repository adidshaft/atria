import XCTest
@testable import Atria

final class AtriaHistoricalRecoveryWindowTests: XCTestCase {
    private func workout(start: TimeInterval,
                         end: TimeInterval,
                         coverage: Int) -> UserConfirmedWorkout {
        UserConfirmedWorkout(id: UUID().uuidString,
                             createdAt: Date(timeIntervalSince1970: end),
                             start: Date(timeIntervalSince1970: start),
                             end: Date(timeIntervalSince1970: end),
                             label: "Strength",
                             source: "live_workout_end",
                             confidence: "user_confirmed",
                             sessions: 1,
                             samples: 58,
                             avgHR: 110,
                             peakHR: 150,
                             p95HR: 140,
                             p99HR: 148,
                             thresholdHR: 120,
                             streamCoveragePercent: coverage,
                             observedDuration: 58 * 5,
                             reason: "user_declared",
                             activityType: "Strength")
    }

    func testJulyElevenSparseWorkoutRearmsRecoveryWhenArchiveEndsBeforeWindow() throws {
        let sparse = workout(start: 1_783_768_620, end: 1_783_771_620, coverage: 3)
        let window = try XCTUnwrap(SessionStore.historicalRecoveryWindow(
            confirmedWorkouts: [sparse],
            archiveLastUnix: 1_783_755_889,
            now: Date(timeIntervalSince1970: 1_783_820_000)
        ))
        XCTAssertEqual(window.start.timeIntervalSince1970, 1_783_768_620)
        XCTAssertEqual(window.end.timeIntervalSince1970, 1_783_771_620)
        XCTAssertEqual(window.coveragePercent, 3)
    }

    func testArchiveCoveredWorkoutDoesNotArmAndNinetyPercentStillRepairs() throws {
        let sparse = workout(start: 1_783_768_620, end: 1_783_771_620, coverage: 3)
        XCTAssertNil(SessionStore.historicalRecoveryWindow(
            confirmedWorkouts: [sparse],
            archiveLastUnix: 1_783_771_620,
            now: Date(timeIntervalSince1970: 1_783_820_000)
        ))
        let incomplete = try XCTUnwrap(SessionStore.historicalRecoveryWindow(
            confirmedWorkouts: [workout(start: 1_783_768_620,
                                        end: 1_783_771_620,
                                        coverage: 90)],
            archiveLastUnix: 1_783_755_889,
            now: Date(timeIntervalSince1970: 1_783_820_000)
        ))
        XCTAssertEqual(incomplete.coveragePercent, 90)
    }
}
