import XCTest
@testable import Atria

final class AtriaPolicyMathTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeSession(start: Date) -> SavedSession {
        SavedSession(id: UUID(),
                     start: start,
                     end: start.addingTimeInterval(60),
                     label: "Test",
                     points: [])
    }

    private var gmtCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }

    // MARK: - SessionStore.partitionSessionsForPersist

    @MainActor
    func testPartitionSessionAtCutoffStaysHotOlderGoesCold() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = now.addingTimeInterval(-TimeInterval(SessionStore.coldSessionAgeDays) * 24 * 60 * 60)
        let atCutoff = makeSession(start: cutoff)
        let justOlder = makeSession(start: cutoff.addingTimeInterval(-1))
        let recent = makeSession(start: now.addingTimeInterval(-3600))

        let partition = SessionStore.partitionSessionsForPersist([atCutoff, justOlder, recent], now: now)

        XCTAssertEqual(partition.hot.map(\.id), [atCutoff.id, recent.id])
        XCTAssertEqual(partition.cold.map(\.id), [justOlder.id])
    }

    @MainActor
    func testPartitionEmptyInput() {
        let partition = SessionStore.partitionSessionsForPersist([], now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(partition.hot.isEmpty)
        XCTAssertTrue(partition.cold.isEmpty)
    }

    @MainActor
    func testPartitionPreservesAllSessions() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessions = (0..<10).map { day in
            makeSession(start: now.addingTimeInterval(-TimeInterval(day * 7) * 24 * 60 * 60))
        }
        let partition = SessionStore.partitionSessionsForPersist(sessions, now: now)
        XCTAssertEqual(partition.hot.count + partition.cold.count, sessions.count)
        XCTAssertEqual(Set(partition.hot.map(\.id)).union(partition.cold.map(\.id)),
                       Set(sessions.map(\.id)))
    }

    @MainActor
    func testPartitionedPersistenceReportsHotAndColdSuccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-session-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hotURL = directory.appendingPathComponent("sessions.json")
        let coldURL = directory.appendingPathComponent("sessions-cold.json")
        let recent = makeSession(start: Date())
        let old = makeSession(start: Date().addingTimeInterval(-31 * 24 * 60 * 60))

        XCTAssertTrue(SessionStore.persistPartitionedSessionsSnapshotForTesting(
            [recent, old],
            hotURL: hotURL,
            coldURL: coldURL,
            allowColdWrite: true,
            reason: "test_success"
        ))
        XCTAssertEqual(try JSONDecoder().decode([SavedSession].self,
                                                from: Data(contentsOf: hotURL)).map(\.id),
                       [recent.id])
        XCTAssertEqual(try JSONDecoder().decode([SavedSession].self,
                                                from: Data(contentsOf: coldURL)).map(\.id),
                       [old.id])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: coldURL.appendingPathExtension("fingerprint").path
        ))
    }

    @MainActor
    func testPartitionedPersistenceReportsHotWriteFailureAndDoesNotWriteCold() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-session-persist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hotURL = directory.appendingPathComponent("missing/sessions.json")
        let coldURL = directory.appendingPathComponent("sessions-cold.json")

        XCTAssertFalse(SessionStore.persistPartitionedSessionsSnapshotForTesting(
            [makeSession(start: Date())],
            hotURL: hotURL,
            coldURL: coldURL,
            allowColdWrite: true,
            reason: "test_hot_failure"
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: coldURL.path))
    }

    @MainActor
    func testPartitionedPersistenceReportsColdWriteFailureAfterHotSuccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-session-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hotURL = directory.appendingPathComponent("sessions.json")
        let coldURL = directory.appendingPathComponent("missing/sessions-cold.json")
        let old = makeSession(start: Date().addingTimeInterval(-31 * 24 * 60 * 60))

        XCTAssertFalse(SessionStore.persistPartitionedSessionsSnapshotForTesting(
            [old],
            hotURL: hotURL,
            coldURL: coldURL,
            allowColdWrite: true,
            reason: "test_cold_failure"
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hotURL.path),
                      "The result must still report failure when hot succeeded but cold did not")
    }

    @MainActor
    func testAsyncFlushDoesNotAdvanceCompletedRevisionAfterInjectedWriteFailure() async {
        let store = SessionStore()
        store.setSessionPersistenceWriterForTesting { _, _, _, _, _ in false }
        store.markSessionPersistenceDirtyForTesting()
        let dirty = store.sessionPersistenceRevisionsForTesting

        let failed = await withCheckedContinuation { continuation in
            store.flushScheduledPersistenceAsync(reason: "test_injected_failure") { succeeded in
                continuation.resume(returning: succeeded)
            }
        }
        XCTAssertFalse(failed)
        let afterFailure = store.sessionPersistenceRevisionsForTesting
        XCTAssertGreaterThanOrEqual(afterFailure.current, dirty.current)
        XCTAssertEqual(afterFailure.completed, dirty.completed)
        XCTAssertEqual(afterFailure.pending, 0)

        store.setSessionPersistenceWriterForTesting { _, _, _, _, _ in true }
        let retried = await withCheckedContinuation { continuation in
            store.flushScheduledPersistenceAsync(reason: "test_injected_retry") { succeeded in
                continuation.resume(returning: succeeded)
            }
        }
        XCTAssertTrue(retried)
        let afterRetry = store.sessionPersistenceRevisionsForTesting
        XCTAssertEqual(afterRetry.completed, afterRetry.current)
        XCTAssertEqual(afterRetry.pending, 0)
        store.setSessionPersistenceWriterForTesting(nil)
    }

    // MARK: - LocalNotificationScheduler.quietHoursAdjustedDelay

    private func setLearnedWindow(start: Int = 1413, end: Int = 678) {
        defaults.set(start, forKey: AtriaBLEManager.DutyCycleDefaults.sleepWindowStartMin)
        defaults.set(end, forKey: AtriaBLEManager.DutyCycleDefaults.sleepWindowEndMin)
    }

    @MainActor
    func testQuietHoursDefersDeliveryInsideQuietSpanToWake() {
        setLearnedWindow()
        // Quiet span = 00:33-10:18. Epoch zero is 00:00 GMT; delay 2 h lands at 02:00.
        let now = Date(timeIntervalSince1970: 0)
        let delay: TimeInterval = 2 * 60 * 60
        let adjusted = LocalNotificationScheduler.quietHoursAdjustedDelay(kind: "recovery",
                                                                          delay: delay,
                                                                          now: now,
                                                                          calendar: gmtCalendar,
                                                                          defaults: defaults)
        // 02:00 -> 10:18 is 498 minutes of deferral.
        let expected = delay + TimeInterval(498 * 60)
        XCTAssertEqual(adjusted, expected, accuracy: 60)
    }

    @MainActor
    func testQuietHoursLeavesDaytimeDeliveryUnchanged() {
        setLearnedWindow()
        let now = Date(timeIntervalSince1970: 0)
        let delay: TimeInterval = 12 * 60 * 60 // 12:00, outside 00:33-10:18
        let adjusted = LocalNotificationScheduler.quietHoursAdjustedDelay(kind: "recovery",
                                                                          delay: delay,
                                                                          now: now,
                                                                          calendar: gmtCalendar,
                                                                          defaults: defaults)
        XCTAssertEqual(adjusted, delay)
    }

    @MainActor
    func testQuietHoursExemptKindUnchangedInsideQuietSpan() {
        setLearnedWindow()
        let now = Date(timeIntervalSince1970: 0)
        let delay: TimeInterval = 2 * 60 * 60 // 02:00, inside quiet
        let adjusted = LocalNotificationScheduler.quietHoursAdjustedDelay(kind: "battery",
                                                                          delay: delay,
                                                                          now: now,
                                                                          calendar: gmtCalendar,
                                                                          defaults: defaults)
        XCTAssertEqual(adjusted, delay)
    }

    @MainActor
    func testQuietHoursNoLearnedWindowLeavesDelayUnchanged() {
        // No window keys set on this suite at all.
        let now = Date(timeIntervalSince1970: 0)
        let delay: TimeInterval = 2 * 60 * 60
        let adjusted = LocalNotificationScheduler.quietHoursAdjustedDelay(kind: "recovery",
                                                                          delay: delay,
                                                                          now: now,
                                                                          calendar: gmtCalendar,
                                                                          defaults: defaults)
        XCTAssertEqual(adjusted, delay)
    }

    // MARK: - LocalNotificationScheduler.consumeAttentionBudget

    @MainActor
    func testAttentionBudgetCapsNonExemptKindsPerDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<LocalNotificationScheduler.attentionBudgetPerDay {
            XCTAssertTrue(LocalNotificationScheduler.consumeAttentionBudget(kind: "recovery",
                                                                            now: now,
                                                                            defaults: defaults),
                          "consume \(i + 1) should succeed")
        }
        XCTAssertFalse(LocalNotificationScheduler.consumeAttentionBudget(kind: "recovery",
                                                                         now: now,
                                                                         defaults: defaults))
        // Exempt kind still succeeds after the budget is exhausted.
        XCTAssertTrue(LocalNotificationScheduler.consumeAttentionBudget(kind: "battery",
                                                                        now: now,
                                                                        defaults: defaults))
    }

    @MainActor
    func testAttentionBudgetIsCountedPerDay() {
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let day2 = day1.addingTimeInterval(3 * 24 * 60 * 60)
        for _ in 0..<LocalNotificationScheduler.attentionBudgetPerDay {
            XCTAssertTrue(LocalNotificationScheduler.consumeAttentionBudget(kind: "recovery",
                                                                            now: day1,
                                                                            defaults: defaults))
        }
        XCTAssertFalse(LocalNotificationScheduler.consumeAttentionBudget(kind: "recovery",
                                                                         now: day1,
                                                                         defaults: defaults))
        // A different day has a fresh counter.
        XCTAssertTrue(LocalNotificationScheduler.consumeAttentionBudget(kind: "recovery",
                                                                        now: day2,
                                                                        defaults: defaults))
    }

    // Morning journal check-in timing (2026-07-08): fires at learned wake + 15
    // min, where the duty-cycle window end is median wake + 1 h.
    func testMorningNudgeIsWakePlusFifteen() {
        // windowEnd 08:00 (480) => wake 07:00 => nudge 07:15 (435).
        XCTAssertEqual(LocalNotificationScheduler.morningNudgeMinutes(windowEnd: 8 * 60), 7 * 60 + 15)
    }

    func testMorningNudgeFallsBackToEightAMWhenUnlearned() {
        XCTAssertEqual(LocalNotificationScheduler.morningNudgeMinutes(windowEnd: 0), 8 * 60)
    }

    func testMorningNudgeWrapsAcrossMidnight() {
        // windowEnd 00:30 (30) => wake 23:30 => nudge 23:45 (1425), no negative/overflow.
        XCTAssertEqual(LocalNotificationScheduler.morningNudgeMinutes(windowEnd: 30), 23 * 60 + 45)
        let m = LocalNotificationScheduler.morningNudgeMinutes(windowEnd: 30)
        XCTAssertTrue((0..<1440).contains(m))
    }
}
