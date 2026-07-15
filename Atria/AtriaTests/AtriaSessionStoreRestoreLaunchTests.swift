import XCTest
@testable import Atria

@MainActor
final class AtriaSessionStoreRestoreLaunchTests: XCTestCase {
    func testRestoreBlockCanConstructDependenciesWithoutStartingCoreBluetooth() {
        let ble = AtriaBLEManager(startsBluetooth: false)

        XCTAssertTrue(ble.bluetoothStartupSuspended)
    }

    func testReinitializationCompletesInterruptedRestoreBeforeLoadingPersistedState() throws {
        let fixture = try RestoreLaunchFixture()
        defer { fixture.cleanup() }
        let oldBaseline = PersonalBaseline(restingHR: 58, hrvEMA: 44, sessions: 2)
        let newBaseline = PersonalBaseline(restingHR: 52, hrvEMA: 63, sessions: 20)
        let oldProfile = AthleteProfile(age: 29, measuredMaxHR: 188,
                                        maxHRSource: .measured, updated: fixture.day,
                                        hasCompletedOnboarding: true)
        let newProfile = AthleteProfile(age: 34, measuredMaxHR: 196,
                                        maxHRSource: .measured, updated: fixture.day,
                                        hasCompletedOnboarding: true)
        let oldRollups = [DailyRollupStoreEntry(day: fixture.day, recovery: 35)]
        let newRollups = [DailyRollupStoreEntry(day: fixture.day, recovery: 88)]
        let encoder = JSONEncoder()
        let oldBaselineData = try encoder.encode(oldBaseline)
        let newBaselineData = try encoder.encode(newBaseline)
        let oldProfileData = try encoder.encode(oldProfile)
        let newProfileData = try encoder.encode(newProfile)
        let oldRollupData = try encoder.encode(oldRollups)
        let newRollupData = try encoder.encode(newRollups)
        fixture.defaults.set(oldBaselineData, forKey: PersonalBaseline.persistenceKey)
        fixture.defaults.set(oldProfileData, forKey: AthleteProfile.persistenceKey)
        try oldRollupData.write(to: fixture.rollupURL)

        let transaction = AtriaRestoreTransaction(destinations: [
            .defaults(key: PersonalBaseline.persistenceKey,
                      previous: .data(oldBaselineData), next: .data(newBaselineData)),
            .defaults(key: AthleteProfile.persistenceKey,
                      previous: .data(oldProfileData), next: .data(newProfileData)),
            .file(path: fixture.rollupURL.path,
                  previous: oldRollupData, next: newRollupData)
        ])
        XCTAssertThrowsError(try AtriaRestoreTransactionCoordinator.commit(
            transaction,
            markerURL: fixture.markerURL,
            defaults: fixture.defaults,
            injection: .init(crashForwardAfterDestination: 0)
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL.path))
        XCTAssertEqual(fixture.defaults.data(forKey: AthleteProfile.persistenceKey), oldProfileData)

        let store = SessionStore(restoreInitialization: fixture.initialization())

        XCTAssertFalse(store.restoreInitializationBlocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL.path))
        XCTAssertEqual(store.baseline.restingInt, 52)
        XCTAssertEqual(store.baseline.hrvInt, 63)
        XCTAssertEqual(store.profile.age, 34)
        XCTAssertEqual(store.profile.measuredMaxHR, 196)
        XCTAssertEqual(store.dailyRollupHistory.first?.recovery, 88)
    }

    func testRetainedMarkerBlocksEveryPersistedBootstrapLoader() throws {
        let fixture = try RestoreLaunchFixture()
        defer { fixture.cleanup() }
        try Data("corrupt restore authority".utf8).write(to: fixture.markerURL)
        let loads = LockedLoadCount()
        let initialization = SessionStore.RestoreInitialization(
            recover: {
                AtriaRestoreTransactionCoordinator.recoverIfNeeded(
                    markerURL: fixture.markerURL,
                    defaults: fixture.defaults
                )
            },
            loadBaseline: {
                loads.increment()
                return PersonalBaseline(restingHR: 1)
            },
            loadProfile: {
                loads.increment()
                return AthleteProfile(age: 99, measuredMaxHR: 220,
                                      maxHRSource: .measured, updated: nil,
                                      hasCompletedOnboarding: true)
            },
            loadDailyRollups: {
                loads.increment()
                return DailyRollupStore(url: fixture.rollupURL,
                                        recoveryMetricsURL: nil)
            }
        )

        let store = SessionStore(restoreInitialization: initialization)

        XCTAssertTrue(store.restoreInitializationBlocked)
        XCTAssertEqual(loads.value, 0)
        XCTAssertNil(store.baseline.restingHR)
        XCTAssertFalse(store.profile.hasCompletedOnboarding)
        XCTAssertTrue(store.dailyRollupHistory.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL.path))

        let session = SavedSession(id: UUID(),
                                   start: fixture.day,
                                   end: fixture.day.addingTimeInterval(60),
                                   label: "must remain blocked",
                                   points: [.init(t: 0, bpm: 70)])
        XCTAssertFalse(store.checkpoint(session))
        XCTAssertFalse(store.add(session))
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.writeSessionBackup(label: "blocked-restore-marker"))
    }
}

private final class RestoreLaunchFixture {
    let directory: URL
    let markerURL: URL
    let rollupURL: URL
    let defaults: UserDefaults
    let suiteName: String
    let day = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-session-store-launch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        markerURL = directory.appendingPathComponent(AtriaRestoreTransactionCoordinator.markerFileName)
        rollupURL = directory.appendingPathComponent("daily-rollups.json")
        suiteName = "com.adidshaft.atria.tests.restore-launch.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func initialization() -> SessionStore.RestoreInitialization {
        SessionStore.RestoreInitialization(
            recover: {
                AtriaRestoreTransactionCoordinator.recoverIfNeeded(
                    markerURL: self.markerURL,
                    defaults: self.defaults
                )
            },
            loadBaseline: {
                guard let data = self.defaults.data(forKey: PersonalBaseline.persistenceKey),
                      let value = try? JSONDecoder().decode(PersonalBaseline.self, from: data) else {
                    return PersonalBaseline()
                }
                return value
            },
            loadProfile: {
                guard let data = self.defaults.data(forKey: AthleteProfile.persistenceKey),
                      let value = try? JSONDecoder().decode(AthleteProfile.self, from: data) else {
                    return AthleteProfile(age: 30, measuredMaxHR: 190,
                                          maxHRSource: .measured, updated: nil,
                                          hasCompletedOnboarding: false)
                }
                return value
            },
            loadDailyRollups: {
                DailyRollupStore(url: self.rollupURL,
                                 recoveryMetricsURL: nil)
            }
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class LockedLoadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
