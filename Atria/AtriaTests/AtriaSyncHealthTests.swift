import XCTest
@testable import Atria

final class AtriaSyncHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRowsSpeakPlainlyAndNeverGuess() {
        var snapshot = AtriaSyncHealth.Snapshot(linkState: "Unknown")
        XCTAssertEqual(AtriaSyncHealth.linkText(snapshot), "Not seen yet")
        XCTAssertEqual(AtriaSyncHealth.syncText(snapshot, now: now), "Not synced yet")
        XCTAssertEqual(AtriaSyncHealth.storageText(snapshot), "Measuring at next launch")
        XCTAssertEqual(AtriaSyncHealth.exitText(nil), "No report from iOS yet")

        snapshot.linkState = "Connected"
        snapshot.heartRateAgeSeconds = 3
        XCTAssertEqual(AtriaSyncHealth.linkText(snapshot), "Connected · heart rate live")
        snapshot.linkState = "Disconnected"
        XCTAssertEqual(AtriaSyncHealth.linkText(snapshot), "Not connected")

        snapshot.syncedThrough = now.addingTimeInterval(-5 * 60)
        XCTAssertTrue(AtriaSyncHealth.syncText(snapshot, now: now).hasPrefix("Up to date"))
        snapshot.syncedThrough = now.addingTimeInterval(-3 * 3_600)
        XCTAssertTrue(AtriaSyncHealth.syncText(snapshot, now: now).hasPrefix("3.0 h behind"))

        snapshot.storageBytes = 2_400_000_000
        snapshot.storageTargetBytes = 768 * 1_024 * 1_024
        XCTAssertTrue(AtriaSyncHealth.storageText(snapshot).contains("target"))
    }

    func testExitSummaryNamesForcedStopsOnly() {
        let quiet = AtriaSyncHealth.ExitSummary(periodEndUnix: 0, cpuLimit: 0, watchdog: 0,
                                                memoryLimit: 0, crashes: 0, normal: 9)
        XCTAssertEqual(AtriaSyncHealth.exitText(quiet), "None in the last report")
        let busy = AtriaSyncHealth.ExitSummary(periodEndUnix: 0, cpuLimit: 3, watchdog: 1,
                                               memoryLimit: 0, crashes: 1, normal: 2)
        XCTAssertEqual(AtriaSyncHealth.exitText(busy), "3 for CPU use · 1 slow start · 1 crash")
    }

    func testLoadReadsPersistedStateFromIsolatedDefaultsAndFile() throws {
        let suite = "sync-health-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["1799990000 bg_processing_start", "1799995000 bg_processing_done"],
                     forKey: AtriaBackgroundTaskJournal.key)
        AtriaMainThreadWatchdog.saveExitSummary(
            .init(periodEndUnix: 1, cpuLimit: 2, watchdog: 0, memoryLimit: 0, crashes: 0, normal: 1),
            defaults: defaults)
        let missingFile = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID()).json")
        let snapshot = AtriaSyncHealth.load(now: now, defaults: defaults, diagnosisURL: missingFile)
        XCTAssertEqual(snapshot.lastBackgroundRun, Date(timeIntervalSince1970: 1_799_995_000))
        XCTAssertEqual(snapshot.exits?.cpuLimit, 2)
        XCTAssertEqual(snapshot.linkState, "Unknown")
    }

    func testSettingsDataPageLinksTheHealthScreen() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("AtriaSyncHealthScreen()"))
    }
}

final class AtriaSyncHealthReadbackTests: XCTestCase {
    func testReadbackWordsAndCounting() {
        XCTAssertEqual(AtriaSyncHealth.readbackText(nil), "Health export off")
        XCTAssertEqual(AtriaSyncHealth.readbackText(.init(nightsInHealth: 0, confirmedNights: 0)), "No confirmed nights yet")
        XCTAssertEqual(AtriaSyncHealth.readbackText(.init(nightsInHealth: 22, confirmedNights: 24)), "22 of 24 nights")
        XCTAssertEqual(AtriaSyncHealth.readbackText(.init(nightsInHealth: 30, confirmedNights: 24)), "24 of 24 nights")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AtriaSyncHealth.distinctDays([base, base.addingTimeInterval(60), base.addingTimeInterval(86_400)]), 2)
    }

    func testConfirmedSleepKeyMatchesTheStore() throws {
        let sessions = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift"), encoding: .utf8)
        XCTAssertTrue(sessions.contains("static let key = \"\(AtriaSyncHealth.confirmedSleepsKey)\""))
    }
}
