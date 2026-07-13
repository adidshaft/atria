import XCTest
@testable import Atria

final class AtriaSessionRestoreTests: XCTestCase {
    func testBackupRestoreIsLosslessAndCurrentDuplicateWins() {
        let sharedID = UUID()
        let currentOnly = session(id: UUID(), start: 300, label: "current-only")
        let backupOnly = session(id: UUID(), start: 200, label: "backup-only")
        let currentEdit = session(id: sharedID, start: 100, label: "current edit", points: 1)
        let staleBackupCopy = session(id: sharedID, start: 100, label: "stale backup", points: 4)

        let restored = SessionStore.sessionsAfterBackupRestore(
            current: [currentEdit, currentOnly],
            backup: [backupOnly, staleBackupCopy]
        )

        XCTAssertEqual(restored.map(\.id), [currentOnly.id, backupOnly.id, sharedID])
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored.first(where: { $0.id == sharedID })?.label, "current edit")
        XCTAssertEqual(restored.first(where: { $0.id == sharedID })?.points.count, 1)
    }

    func testConfirmedWorkoutRestoreRecoversBackupOnlyAndCurrentDuplicateWins() {
        let currentOnly = workout(id: "current-only", start: 300, label: "current-only")
        let backupOnly = workout(id: "backup-only", start: 200, label: "backup-only")
        let currentEdit = workout(id: "shared", start: 100, label: "current edit")
        let staleBackupCopy = workout(id: "shared", start: 100, label: "stale backup")

        let restored = SessionStore.confirmedWorkoutsAfterBackupRestore(
            current: [currentEdit, currentOnly],
            backup: [backupOnly, staleBackupCopy]
        )

        XCTAssertEqual(restored.map(\.id), ["current-only", "backup-only", "shared"])
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored.first(where: { $0.id == "shared" })?.label, "current edit")
    }

    func testSchemaFourBackupRoundTripsConfirmedWorkouts() throws {
        let savedWorkout = workout(id: "saved-workout", start: 100, label: "Strength")
        let envelope = SessionBackupEnvelope(
            schema: 4,
            createdAt: Date(timeIntervalSince1970: 400),
            app: "Atria.local",
            sessions: [],
            baseline: PersonalBaseline(),
            profile: AthleteProfile.load(),
            confirmedWorkouts: [savedWorkout]
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(SessionBackupEnvelope.self, from: data)

        XCTAssertEqual(decoded.schema, 4)
        XCTAssertEqual(decoded.confirmedWorkouts, [savedWorkout])
    }

    func testLegacySchemaThreeBackupWithoutConfirmedWorkoutsStillDecodes() throws {
        let legacy = SessionBackupEnvelope(
            schema: 3,
            createdAt: Date(timeIntervalSince1970: 400),
            app: "Atria.local",
            sessions: [],
            baseline: PersonalBaseline(),
            profile: AthleteProfile.load()
        )
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("confirmedWorkouts"))

        let decoded = try JSONDecoder().decode(SessionBackupEnvelope.self, from: data)

        XCTAssertEqual(decoded.schema, 3)
        XCTAssertNil(decoded.confirmedWorkouts)
    }

    private func session(id: UUID,
                         start: TimeInterval,
                         label: String,
                         points: Int = 2) -> SavedSession {
        let began = Date(timeIntervalSince1970: start)
        return SavedSession(
            id: id,
            start: began,
            end: began.addingTimeInterval(60),
            label: label,
            points: (0..<points).map { SavedSession.Point(t: Double($0), bpm: 70 + $0) }
        )
    }

    private func workout(id: String,
                         start: TimeInterval,
                         label: String) -> UserConfirmedWorkout {
        let began = Date(timeIntervalSince1970: start)
        return UserConfirmedWorkout(
            id: id,
            createdAt: began.addingTimeInterval(60),
            start: began,
            end: began.addingTimeInterval(60),
            label: label,
            source: "test",
            confidence: "test",
            sessions: 0,
            samples: 0,
            avgHR: 0,
            peakHR: 0,
            p95HR: 0,
            p99HR: 0,
            thresholdHR: 0,
            streamCoveragePercent: 0,
            observedDuration: 0,
            reason: "test"
        )
    }
}
