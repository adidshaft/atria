import XCTest
@testable import Atria

/// Device-proven 2026-08-20: dismissing the 13:15-16:15 false-positive
/// afternoon "sleep" recorded its window tombstone while automatic
/// settlement's `aggregate_sleep` record for the exact window survived —
/// the dismissal guard saw a stale unconfirmed snapshot and only tombstoned.
/// These tests pin the fix: a dismissal retracts machine-authored confirmed
/// records it suppresses (both race directions), while user-authored records
/// — by source, by user_confirmed_*/manual_* confidence, or by a day-primary
/// answer — are never deleted by a dismissal.
final class AtriaSleepDismissalRetractionTests: XCTestCase {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        Self.utcCalendar.date(from: DateComponents(year: year,
                                                   month: month,
                                                   day: day,
                                                   hour: hour,
                                                   minute: minute))!
    }

    private func confirmedSleep(id: String,
                                start: Date,
                                end: Date,
                                source: String,
                                confidence: String,
                                dayPrimaryChoice: Bool? = nil) -> UserConfirmedSleep {
        UserConfirmedSleep(id: id,
                           createdAt: end,
                           start: start,
                           end: end,
                           source: source,
                           confidence: confidence,
                           sessions: 2,
                           samples: 900,
                           avgHR: 58,
                           peakHR: 72,
                           restingHR: 55,
                           hrv: 44,
                           hrvWindowCount: 6,
                           duration: end.timeIntervalSince(start),
                           span: end.timeIntervalSince(start),
                           reason: "dismissal-retraction fixture",
                           motionSource: "strap_hr_only",
                           motionValidated: false,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: "UTC",
                           dayPrimaryChoice: dayPrimaryChoice)
    }

    private func reviewNight(id: String,
                             start: Date,
                             end: Date,
                             confirmed: Bool) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: id,
                                   day: Self.utcCalendar.startOfDay(for: end),
                                   start: start,
                                   end: end,
                                   duration: end.timeIntervalSince(start),
                                   restingHR: 55,
                                   hrv: 44,
                                   respiratoryRate: nil,
                                   sleepEfficiency: nil,
                                   confidence: "medium",
                                   source: "aggregate_sleep",
                                   confirmed: confirmed,
                                   stageSegments: [])
    }

    @MainActor
    private func makeStore(now: Date) -> SessionStore {
        var baseline = PersonalBaseline()
        for dayOffset in 1...3 {
            baseline.learn(fromResting: 56,
                           hrv: 48 + dayOffset,
                           at: now.addingTimeInterval(-Double(dayOffset) * 24 * 60 * 60),
                           overnight: true)
        }
        let rollupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-dismissal-retraction-\(UUID().uuidString).json")
        return SessionStore(restoreInitialization: .init(
            recover: { .noMarker },
            loadBaseline: { baseline },
            loadProfile: {
                AthleteProfile(age: 30,
                               measuredMaxHR: 190,
                               maxHRSource: .measured,
                               updated: now,
                               hasCompletedOnboarding: true)
            },
            loadDailyRollups: {
                DailyRollupStore(url: rollupURL,
                                 recoveryMetricsURL: nil,
                                 loadPersisted: false)
            }
        ))
    }

    /// Earlier tests in the shared-process suites can leave stores with
    /// in-flight async follow-ups writing the process-global confirmed file.
    @MainActor
    private func quiesceSharedConfirmedStore() async {
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(500))
    }

    private static func clearTombstones(overlappingStart start: Date, end: Date) {
        let unrelated = AtriaDismissedSleepCandidateStore.load().filter {
            !$0.overlaps(start: start, end: end)
        }
        AtriaDismissedSleepCandidateStore.save(unrelated)
    }

    private static func hasTombstone(overlappingStart start: Date, end: Date) -> Bool {
        AtriaDismissedSleepCandidateStore.load().contains {
            $0.overlaps(start: start, end: end)
        }
    }

    /// Installs a durable tombstone BEFORE a store is created, so the store's
    /// init-time load observes it — the launch-sweep tests need the pre-fix
    /// device shape (tombstone persisted by an older build, record surviving).
    private static func installTombstone(start: Date, end: Date) {
        var all = AtriaDismissedSleepCandidateStore.load()
        all.removeAll { $0.overlaps(start: start, end: end) }
        all.append(AtriaDismissedSleepCandidate(start: start, end: end))
        AtriaDismissedSleepCandidateStore.save(all)
    }

    // MARK: - Pure retraction predicate

    func testDismissalRetractsMachineAuthoredSuppressedRecords() {
        let start = date(2026, 8, 14, 13, 15)
        let end = date(2026, 8, 14, 16, 15)
        for (source, confidence) in [
            ("aggregate_sleep", "medium"),        // the 2026-08-20 device record shape
            ("auto_confirmed_sleep", "medium"),
            ("auto_confirmed_sleep_hr_only", "provisional"),
            ("auto_nap", "medium")
        ] {
            let record = confirmedSleep(id: "machine-\(source)",
                                        start: start,
                                        end: end,
                                        source: source,
                                        confidence: confidence)
            XCTAssertTrue(SessionStore.dismissalRetractsConfirmedSleep(record,
                                                                       dismissalStart: start,
                                                                       dismissalEnd: end),
                          "machine-authored \(source) must be retractable by its own dismissal")
        }
    }

    func testDismissalNeverRetractsUserAuthoredRecords() {
        let start = date(2026, 8, 14, 13, 15)
        let end = date(2026, 8, 14, 16, 15)
        for (source, confidence) in [
            ("manual_sleep", "manual_user_entered"),
            ("manual_nap", "manual_user_entered"),
            ("user_adjusted_sleep", "user_confirmed_hr_only"),
            ("user_adjusted_nap", "user_confirmed_motion_validated"),
            // The plain Confirm button keeps the detector's source string and
            // marks authorship in confidence alone (field report 2026-08-19).
            ("aggregate_sleep", "user_confirmed_hr_only"),
            ("sleep_window", "user_confirmed_motion_validated")
        ] {
            let record = confirmedSleep(id: "authored-\(source)-\(confidence)",
                                        start: start,
                                        end: end,
                                        source: source,
                                        confidence: confidence)
            XCTAssertFalse(SessionStore.dismissalRetractsConfirmedSleep(record,
                                                                        dismissalStart: start,
                                                                        dismissalEnd: end),
                           "\(source)/\(confidence) is user-authored; dismissal is not deletion")
        }
    }

    func testDismissalNeverRetractsDayPrimaryChoiceCarrier() {
        let start = date(2026, 8, 14, 13, 15)
        let end = date(2026, 8, 14, 16, 15)
        for choice in [true, false] {
            let record = confirmedSleep(id: "day-primary-\(choice)",
                                        start: start,
                                        end: end,
                                        source: "aggregate_sleep",
                                        confidence: "medium",
                                        dayPrimaryChoice: choice)
            XCTAssertFalse(SessionStore.dismissalRetractsConfirmedSleep(record,
                                                                        dismissalStart: start,
                                                                        dismissalEnd: end),
                           "a record carrying the user's main-sleep answer stays authoritative")
        }
    }

    func testSubSeventyPercentOverlapLeavesRecordUntouched() {
        let start = date(2026, 8, 14, 13, 15)
        let end = date(2026, 8, 14, 16, 15)
        // 180-minute windows: a 54-minute shift is exactly the 0.70 overlap
        // boundary (126/180); one more minute drops below it.
        let atBoundary = confirmedSleep(id: "overlap-at-boundary",
                                        start: start.addingTimeInterval(54 * 60),
                                        end: end.addingTimeInterval(54 * 60),
                                        source: "aggregate_sleep",
                                        confidence: "medium")
        XCTAssertTrue(SessionStore.dismissalRetractsConfirmedSleep(atBoundary,
                                                                   dismissalStart: start,
                                                                   dismissalEnd: end))
        let below = confirmedSleep(id: "overlap-below-boundary",
                                   start: start.addingTimeInterval(55 * 60),
                                   end: end.addingTimeInterval(55 * 60),
                                   source: "aggregate_sleep",
                                   confidence: "medium")
        XCTAssertFalse(SessionStore.dismissalRetractsConfirmedSleep(below,
                                                                    dismissalStart: start,
                                                                    dismissalEnd: end),
                       "a sub-0.70 overlap is a different episode, never retracted")
    }

    // MARK: - Store-level dismissal

    @MainActor
    func testDismissalRetractsRacedMachineAuthoredRecordAndTombstones() async throws {
        await quiesceSharedConfirmedStore()
        let start = date(2026, 8, 15, 13, 15)
        let end = date(2026, 8, 15, 16, 15)
        let store = makeStore(now: date(2026, 8, 15, 18, 0))
        let record = confirmedSleep(id: "dismissal-race-\(UUID().uuidString)",
                                    start: start,
                                    end: end,
                                    source: "aggregate_sleep",
                                    confidence: "medium")
        await store.debugInstallConfirmedSleepsForTesting([record])
        addTeardownBlock { @MainActor in
            _ = await store.debugInstallConfirmedSleepsForTesting([])
            Self.clearTombstones(overlappingStart: start, end: end)
        }

        // The review card's snapshot has not caught up with settlement: it
        // still presents the already-persisted window as an unconfirmed
        // candidate — the exact stale-tap shape from the device.
        let night = reviewNight(id: "raced-candidate", start: start, end: end, confirmed: false)
        XCTAssertTrue(store.dismissSleepCandidate(night))
        XCTAssertTrue(Self.hasTombstone(overlappingStart: start, end: end),
                      "the dismissal tombstone must be recorded before retraction settles")
        // Deterministic completion: retraction is idempotent, so driving it
        // directly cannot double-delete even if the dismissal's own async
        // sweep already won.
        _ = await store.retractConfirmedSleeps(ids: [record.id])
        XCTAssertFalse(store.confirmedSleeps.contains { $0.id == record.id },
                       "the machine-authored record must not survive the user's dismissal")

        // Re-dismissing the now-settled candidate stays a safe no-op with the
        // tombstone intact.
        XCTAssertTrue(store.dismissSleepCandidate(night))
        XCTAssertTrue(Self.hasTombstone(overlappingStart: start, end: end))
        XCTAssertFalse(store.confirmedSleeps.contains { $0.id == record.id })
    }

    @MainActor
    func testDismissingConfirmedMachineAuthoredNightRetractsAndTombstones() async throws {
        await quiesceSharedConfirmedStore()
        let start = date(2026, 8, 16, 13, 15)
        let end = date(2026, 8, 16, 16, 15)
        let store = makeStore(now: date(2026, 8, 16, 18, 0))
        let record = confirmedSleep(id: "dismissal-confirmed-\(UUID().uuidString)",
                                    start: start,
                                    end: end,
                                    source: "auto_confirmed_sleep",
                                    confidence: "medium")
        await store.debugInstallConfirmedSleepsForTesting([record])
        addTeardownBlock { @MainActor in
            _ = await store.debugInstallConfirmedSleepsForTesting([])
            Self.clearTombstones(overlappingStart: start, end: end)
        }

        // The snapshot is fresh — the night already shows as confirmed. The
        // user's "not sleep" verdict must be honored anyway.
        let night = reviewNight(id: "confirmed-machine", start: start, end: end, confirmed: true)
        XCTAssertTrue(store.dismissSleepCandidate(night),
                      "a confirmed machine-authored night must accept dismissal")
        XCTAssertTrue(Self.hasTombstone(overlappingStart: start, end: end))
        // Deterministic completion (idempotent with the in-flight sweep).
        _ = await store.retractConfirmedSleeps(ids: [record.id])
        XCTAssertFalse(store.confirmedSleeps.contains { $0.id == record.id })
    }

    @MainActor
    func testDismissingConfirmedUserAuthoredNightIsRefused() async throws {
        await quiesceSharedConfirmedStore()
        let store = makeStore(now: date(2026, 8, 17, 18, 0))
        // Non-overlapping windows so one durable install covers every carrier.
        let adjusted = confirmedSleep(id: "refused-adjusted-\(UUID().uuidString)",
                                      start: date(2026, 8, 17, 0, 30),
                                      end: date(2026, 8, 17, 3, 30),
                                      source: "user_adjusted_sleep",
                                      confidence: "user_confirmed_hr_only")
        let plainConfirm = confirmedSleep(id: "refused-plain-\(UUID().uuidString)",
                                          start: date(2026, 8, 17, 6, 0),
                                          end: date(2026, 8, 17, 9, 0),
                                          source: "aggregate_sleep",
                                          confidence: "user_confirmed_hr_only")
        let dayPrimary = confirmedSleep(id: "refused-primary-\(UUID().uuidString)",
                                        start: date(2026, 8, 17, 13, 15),
                                        end: date(2026, 8, 17, 16, 15),
                                        source: "aggregate_sleep",
                                        confidence: "medium",
                                        dayPrimaryChoice: true)
        let records = [adjusted, plainConfirm, dayPrimary]
        // The dismissal store is process-global; drop any stale overlapping
        // tombstones so the "records no tombstone" assertions start clean.
        for record in records {
            Self.clearTombstones(overlappingStart: record.start, end: record.end)
        }
        await store.debugInstallConfirmedSleepsForTesting(records)
        addTeardownBlock { @MainActor in
            _ = await store.debugInstallConfirmedSleepsForTesting([])
            for record in records {
                Self.clearTombstones(overlappingStart: record.start, end: record.end)
            }
        }

        for record in records {
            let night = reviewNight(id: "confirmed-\(record.id)",
                                    start: record.start,
                                    end: record.end,
                                    confirmed: true)
            XCTAssertFalse(store.dismissSleepCandidate(night),
                           "\(record.id): dismissal must refuse a confirmed user-authored night")
            XCTAssertFalse(Self.hasTombstone(overlappingStart: record.start, end: record.end),
                           "\(record.id): a refused dismissal records no tombstone")
            XCTAssertTrue(store.confirmedSleeps.contains { $0.id == record.id })
        }
    }

    @MainActor
    func testDismissingStaleCandidateTombstonesButLeavesUserAuthoredRecord() async throws {
        await quiesceSharedConfirmedStore()
        let start = date(2026, 8, 18, 13, 15)
        let end = date(2026, 8, 18, 16, 15)
        let store = makeStore(now: date(2026, 8, 18, 18, 0))
        let record = confirmedSleep(id: "survivor-manual-\(UUID().uuidString)",
                                    start: start,
                                    end: end,
                                    source: "manual_nap",
                                    confidence: "manual_user_entered")
        await store.debugInstallConfirmedSleepsForTesting([record])
        addTeardownBlock { @MainActor in
            _ = await store.debugInstallConfirmedSleepsForTesting([])
            Self.clearTombstones(overlappingStart: start, end: end)
        }

        // An unconfirmed candidate row over the user's own record: the
        // candidate is settled by the tombstone, the record is untouchable.
        let night = reviewNight(id: "stale-over-manual", start: start, end: end, confirmed: false)
        XCTAssertTrue(store.dismissSleepCandidate(night))
        XCTAssertTrue(Self.hasTombstone(overlappingStart: start, end: end))
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.confirmedSleeps.contains { $0.id == record.id },
                      "a user-authored record must survive dismissal of the overlapping candidate")
    }

    @MainActor
    func testRetractionIsIdempotentAndReusesDeletionTombstonePath() async throws {
        await quiesceSharedConfirmedStore()
        let start = date(2026, 8, 19, 13, 15)
        let end = date(2026, 8, 19, 16, 15)
        let store = makeStore(now: date(2026, 8, 19, 18, 0))
        let record = confirmedSleep(id: "idempotent-\(UUID().uuidString)",
                                    start: start,
                                    end: end,
                                    source: "auto_confirmed_sleep_hr_only",
                                    confidence: "provisional")
        await store.debugInstallConfirmedSleepsForTesting([record])
        addTeardownBlock { @MainActor in
            _ = await store.debugInstallConfirmedSleepsForTesting([])
            Self.clearTombstones(overlappingStart: start, end: end)
        }

        let first = await store.retractConfirmedSleeps(ids: [record.id])
        XCTAssertEqual(first, 1)
        XCTAssertFalse(store.confirmedSleeps.contains { $0.id == record.id })
        XCTAssertTrue(Self.hasTombstone(overlappingStart: start, end: end),
                      "retraction rides the deletion path, which tombstones the removed window")

        let second = await store.retractConfirmedSleeps(ids: [record.id])
        XCTAssertEqual(second, 0, "retracting an already-removed id is a no-op")
        XCTAssertFalse(store.confirmedSleeps.contains { $0.id == record.id })
    }

    // MARK: - Launch-time tombstone reconciliation

    @MainActor
    func testLaunchSweepRetractsMachineRecordSuppressedByPreexistingTombstone() async throws {
        await quiesceSharedConfirmedStore()
        let start = date(2026, 8, 18, 13, 15)
        let end = date(2026, 8, 18, 16, 15)
        // The pre-fix device shape: an older build persisted the tombstone,
        // yet the raced machine record survived into the next launch.
        Self.installTombstone(start: start, end: end)
        let store = makeStore(now: date(2026, 8, 18, 18, 0))
        let record = confirmedSleep(id: "launch-sweep-\(UUID().uuidString)",
                                    start: start,
                                    end: end,
                                    source: "aggregate_sleep",
                                    confidence: "medium")
        await store.debugInstallConfirmedSleepsForTesting([record])
        addTeardownBlock { @MainActor in
            _ = await store.debugInstallConfirmedSleepsForTesting([])
            Self.clearTombstones(overlappingStart: start, end: end)
        }

        store.reconcileDismissalTombstonesOnLaunch()
        _ = await store.retractConfirmedSleeps(ids: [record.id])
        XCTAssertFalse(store.confirmedSleeps.contains { $0.id == record.id },
                       "the launch sweep must heal a record its stored tombstone suppresses")
        XCTAssertTrue(Self.hasTombstone(overlappingStart: start, end: end))

        // Idempotent: a second sweep over the healed state selects nothing.
        XCTAssertTrue(store.reconcileDismissalTombstonesOnLaunch().isEmpty)
    }

    @MainActor
    func testLaunchSweepNeverTouchesUserAuthoredOrUnsuppressedRecords() async throws {
        await quiesceSharedConfirmedStore()
        let start = date(2026, 8, 19, 13, 15)
        let end = date(2026, 8, 19, 16, 15)
        Self.installTombstone(start: start, end: end)
        let store = makeStore(now: date(2026, 8, 19, 18, 0))
        // A user-authored record inside the tombstone window (the plain-Confirm
        // shape also writes a settling tombstone beside a protected record) and
        // a machine record far outside any tombstone.
        let userRecord = confirmedSleep(id: "launch-user-\(UUID().uuidString)",
                                        start: start,
                                        end: end,
                                        source: "user_adjusted_sleep",
                                        confidence: "medium")
        let farStart = date(2026, 8, 19, 1, 0)
        let farRecord = confirmedSleep(id: "launch-far-\(UUID().uuidString)",
                                       start: farStart,
                                       end: date(2026, 8, 19, 7, 30),
                                       source: "aggregate_sleep",
                                       confidence: "medium")
        await store.debugInstallConfirmedSleepsForTesting([userRecord, farRecord])
        addTeardownBlock { @MainActor in
            _ = await store.debugInstallConfirmedSleepsForTesting([])
            Self.clearTombstones(overlappingStart: start, end: end)
        }

        XCTAssertTrue(store.reconcileDismissalTombstonesOnLaunch().isEmpty,
                      "neither the user-authored nor the unsuppressed record may be selected")
        XCTAssertTrue(store.confirmedSleeps.contains { $0.id == userRecord.id },
                      "user-authored records are never retracted by the launch sweep")
        XCTAssertTrue(store.confirmedSleeps.contains { $0.id == farRecord.id },
                      "records no tombstone suppresses are untouched")
    }
}
