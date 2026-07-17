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

    func testSleepMetricAndRollupRestoreAreNonDestructiveAndCurrentWins() {
        let currentSleep = sleep(id: "shared", start: 300, reason: "current")
        let backupSleep = sleep(id: "shared", start: 100, reason: "backup")
        let backupOnlySleep = sleep(id: "backup-only", start: 200, reason: "backup-only")
        let restoredSleeps = SessionStore.confirmedSleepsAfterBackupRestore(
            current: [currentSleep], backup: [backupSleep, backupOnlySleep]
        )
        XCTAssertEqual(restoredSleeps.count, 2)
        XCTAssertEqual(restoredSleeps.first(where: { $0.id == "shared" })?.reason, "current")

        let sharedDay = Date(timeIntervalSince1970: 1_700_000_000)
        let currentMetric = metric(day: sharedDay, recovery: 81)
        let backupMetric = metric(day: sharedDay, recovery: 42)
        let backupOnlyMetric = metric(day: sharedDay.addingTimeInterval(-86_400), recovery: 55)
        let restoredMetrics = SessionStore.dailyMetricsAfterBackupRestore(
            current: [currentMetric], backup: [backupMetric, backupOnlyMetric]
        )
        XCTAssertEqual(restoredMetrics.count, 2)
        XCTAssertEqual(restoredMetrics.first(where: { $0.day == sharedDay })?.recoveryPercent, 81)

        let currentRollup = DailyRollupStoreEntry(day: sharedDay, recovery: 81)
        let backupRollup = DailyRollupStoreEntry(day: sharedDay, recovery: 42)
        let backupOnlyRollup = DailyRollupStoreEntry(day: sharedDay.addingTimeInterval(-86_400), recovery: 55)
        let restoredRollups = SessionStore.dailyRollupsAfterBackupRestore(
            current: [currentRollup], backup: [backupRollup, backupOnlyRollup]
        )
        XCTAssertEqual(restoredRollups.count, 2)
        XCTAssertEqual(restoredRollups.first(where: { $0.day == currentRollup.day })?.recovery, 81)
    }

    func testProfileRestoreRecoversFreshInstallWithoutRollingBackOnboardedCurrentProfile() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = AthleteProfile(age: 30, measuredMaxHR: 190,
                                   maxHRSource: .measured, updated: nil,
                                   hasCompletedOnboarding: false)
        let backup = AthleteProfile(age: 31, measuredMaxHR: 196,
                                    maxHRSource: .measured, updated: day,
                                    hasCompletedOnboarding: true)
        XCTAssertEqual(SessionStore.profileAfterBackupRestore(current: fresh, backup: backup), backup)

        let current = AthleteProfile(age: 34, measuredMaxHR: 201,
                                     maxHRSource: .measured,
                                     updated: day.addingTimeInterval(3_600),
                                     hasCompletedOnboarding: true)
        XCTAssertEqual(SessionStore.profileAfterBackupRestore(current: current, backup: backup), current)

        let incompleteBackup = AthleteProfile(age: 29, measuredMaxHR: 185,
                                               maxHRSource: .measured, updated: day,
                                               hasCompletedOnboarding: false)
        XCTAssertEqual(SessionStore.profileAfterBackupRestore(current: fresh, backup: incompleteBackup), fresh)
    }

    func testRestoreRemergeRetryIsBounded() {
        XCTAssertTrue(SessionStore.restoreRetryAllowed(completedRemerges: 0, maximumRemerges: 3))
        XCTAssertTrue(SessionStore.restoreRetryAllowed(completedRemerges: 2, maximumRemerges: 3))
        XCTAssertFalse(SessionStore.restoreRetryAllowed(completedRemerges: 3, maximumRemerges: 3))
        XCTAssertFalse(SessionStore.restoreRetryAllowed(completedRemerges: 100, maximumRemerges: 3))
    }

    func testBackupFingerprintDetectsEveryCanonicalDomainChange() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let sessions = [session(id: UUID(), start: day.timeIntervalSince1970, label: "base")]
        let baseline = PersonalBaseline(restingHR: 60, hrvEMA: 50, sessions: 1, updated: day)
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     updated: day,
                                     hasCompletedOnboarding: true)
        let metrics = [metric(day: day, recovery: 70)]
        let rollups = [DailyRollupStoreEntry(day: day, recovery: 70)]
        let sleeps = [sleep(id: "sleep", start: day.timeIntervalSince1970, reason: "base")]
        let workouts = [workout(id: "workout", start: day.timeIntervalSince1970, label: "base")]
        func digest(_ sessions: [SavedSession],
                    _ baseline: PersonalBaseline,
                    _ profile: AthleteProfile,
                    _ metrics: [SavedDailyMetric],
                    _ rollups: [DailyRollupStoreEntry],
                    _ sleeps: [UserConfirmedSleep],
                    _ workouts: [UserConfirmedWorkout]) throws -> String {
            try XCTUnwrap(SessionStore.makeBackupContentDigest(
                sessions: sessions, baseline: baseline, profile: profile,
                dailyMetrics: metrics, dailyRollups: rollups,
                confirmedSleeps: sleeps, confirmedWorkouts: workouts
            ))
        }
        let base = try digest(sessions, baseline, profile, metrics, rollups, sleeps, workouts)
        XCTAssertNotEqual(base, try digest(
            [session(id: UUID(), start: day.timeIntervalSince1970, label: "changed")],
            baseline, profile, metrics, rollups, sleeps, workouts
        ))
        XCTAssertNotEqual(base, try digest(sessions, PersonalBaseline(restingHR: 61),
                                            profile, metrics, rollups, sleeps, workouts))
        XCTAssertNotEqual(base, try digest(sessions, baseline,
                                            AthleteProfile(age: 31, measuredMaxHR: 190,
                                                           maxHRSource: .measured, updated: day,
                                                           hasCompletedOnboarding: true),
                                            metrics, rollups, sleeps, workouts))
        XCTAssertNotEqual(base, try digest(sessions, baseline, profile,
                                            [metric(day: day, recovery: 71)], rollups, sleeps, workouts))
        XCTAssertNotEqual(base, try digest(sessions, baseline, profile, metrics,
                                            [DailyRollupStoreEntry(day: day, recovery: 71)], sleeps, workouts))
        XCTAssertNotEqual(base, try digest(sessions, baseline, profile, metrics, rollups,
                                            [sleep(id: "sleep", start: day.timeIntervalSince1970, reason: "changed")],
                                            workouts))
        XCTAssertNotEqual(base, try digest(sessions, baseline, profile, metrics, rollups, sleeps,
                                            [workout(id: "workout", start: day.timeIntervalSince1970, label: "changed")]))
    }

    func testStalePreparedRestoreIsRejectedAndFreshRemergePreservesConcurrentSession() {
        let backupOnly = session(id: UUID(), start: 100, label: "backup")
        let concurrent = session(id: UUID(), start: 200, label: "BLE finalized while preparing")
        let preparedRevision: UInt64 = 41
        let currentRevision: UInt64 = 42

        XCTAssertFalse(SessionStore.restorePreparationIsCurrent(
            preparedRevision: preparedRevision,
            canonicalRevision: currentRevision
        ))

        let remerged = SessionStore.sessionsAfterBackupRestore(current: [concurrent],
                                                               backup: [backupOnly])
        XCTAssertEqual(Set(remerged.map(\.id)), Set([concurrent.id, backupOnly.id]))
        XCTAssertTrue(SessionStore.restorePreparationIsCurrent(
            preparedRevision: currentRevision,
            canonicalRevision: currentRevision
        ))
    }

    func testOlderBackupStatusWriterCannotPublishAfterNewerOperationBegins() {
        XCTAssertFalse(SessionStore.backupStatusGenerationIsCurrent(
            resultGeneration: 7,
            currentGeneration: 8
        ))
        XCTAssertTrue(SessionStore.backupStatusGenerationIsCurrent(
            resultGeneration: 8,
            currentGeneration: 8
        ))
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

    private func sleep(id: String, start: TimeInterval, reason: String) -> UserConfirmedSleep {
        let began = Date(timeIntervalSince1970: start)
        return UserConfirmedSleep(id: id,
                                  createdAt: began,
                                  start: began,
                                  end: began.addingTimeInterval(60),
                                  source: "test",
                                  confidence: "test",
                                  sessions: 1,
                                  samples: 1,
                                  avgHR: 60,
                                  peakHR: 70,
                                  restingHR: 55,
                                  hrv: 50,
                                  hrvWindowCount: 1,
                                  duration: 60,
                                  span: 60,
                                  reason: reason,
                                  motionSource: "test",
                                  motionValidated: false,
                                  stageSegments: nil)
    }

    private func metric(day: Date, recovery: Int) -> SavedDailyMetric {
        SavedDailyMetric(day: day,
                         recoveryPercent: recovery,
                         recoveryConfidence: "test",
                         hrv: 50,
                         restingHR: 60,
                         respiratoryRate: 15,
                         sleepDuration: nil,
                         sleepSpan: nil,
                         sleepStart: nil,
                         sleepEnd: nil,
                         sleepSource: nil,
                         sleepStageSegments: [],
                         sleepConsistencyPercent: nil,
                         strain: 5)
    }
}
