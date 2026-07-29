import XCTest
@testable import Atria

final class AtriaWhoop4MotionTickDailyStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AtriaWhoop4MotionTickDailyStoreTests-\(UUID().uuidString)"
        )
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testReceiptIsIsolatedByStrapAndPhysiologicalBoundary() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strapA = UUID().uuidString
        let strapB = UUID().uuidString
        let start = Date(timeIntervalSince1970: 10_000)
        let evidence = makeEvidence(start: start, ticks: 155, steps: 132)

        XCTAssertTrue(try store.save(evidence, strapIdentifier: strapA))
        XCTAssertEqual(
            store.load(strapIdentifier: strapA, windowStart: start),
            evidence
        )
        XCTAssertNil(store.load(strapIdentifier: strapB, windowStart: start))
        XCTAssertNil(
            store.load(
                strapIdentifier: strapA,
                windowStart: start.addingTimeInterval(60)
            )
        )
    }

    func testCurrentCycleAttemptSignatureInvalidatesForEvidenceAuthority() throws {
        let start = Date(timeIntervalSince1970: 9_000)
        let strap = "strap-a"
        let authority = AtriaWhoop4MotionBankCoverageLedger
            .ProjectionAuthority(
                algorithmVersion:
                    AtriaWhoop4MotionBankCoverageLedger.algorithmVersion,
                strapIdentifier: strap,
                closed: [],
                openStart: start
            )
        let source = HistoricalArchive.makeConsumerSourceFingerprint(
            catalogGeneration: 1,
            descriptors: []
        )
        let base = try XCTUnwrap(
            SessionStore.currentCycleStepReceiptAttemptSignature(
                strapIdentifier: strap,
                cycleStart: start,
                coverageAuthority: authority,
                sourceFingerprint: source,
                compactSourceIdentifier: "compact-1"
            )
        )
        XCTAssertEqual(
            base,
            SessionStore.currentCycleStepReceiptAttemptSignature(
                strapIdentifier: strap,
                cycleStart: start,
                coverageAuthority: authority,
                sourceFingerprint: source,
                compactSourceIdentifier: "compact-1"
            )
        )
        XCTAssertNotEqual(
            base,
            SessionStore.currentCycleStepReceiptAttemptSignature(
                strapIdentifier: strap,
                cycleStart: start.addingTimeInterval(1),
                coverageAuthority: authority,
                sourceFingerprint: source,
                compactSourceIdentifier: "compact-1"
            )
        )
        XCTAssertNotEqual(
            base,
            SessionStore.currentCycleStepReceiptAttemptSignature(
                strapIdentifier: strap,
                cycleStart: start,
                coverageAuthority: authority,
                sourceFingerprint:
                    HistoricalArchive.makeConsumerSourceFingerprint(
                        catalogGeneration: 2,
                        descriptors: []
                    ),
                compactSourceIdentifier: "compact-1"
            )
        )
        XCTAssertNotEqual(
            base,
            SessionStore.currentCycleStepReceiptAttemptSignature(
                strapIdentifier: strap,
                cycleStart: start,
                coverageAuthority: authority,
                sourceFingerprint: source,
                compactSourceIdentifier: "compact-2"
            )
        )
    }

    func testOlderOrWeakerReplayCannotReplaceReceipt() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 20_000)
        let strong = makeEvidence(
            start: start,
            ticks: 310,
            steps: 264,
            capturedAfter: 240,
            known: 220
        )
        let weaker = makeEvidence(
            start: start,
            ticks: 155,
            steps: 132,
            capturedAfter: 180,
            known: 160
        )

        XCTAssertTrue(try store.save(strong, strapIdentifier: strap))
        XCTAssertFalse(try store.save(weaker, strapIdentifier: strap))
        XCTAssertEqual(
            store.load(strapIdentifier: strap, windowStart: start),
            strong
        )
    }

    func testNewerMonotonicSubtotalReplacesReceipt() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 30_000)
        let first = makeEvidence(start: start, ticks: 155, steps: 132)
        let second = makeEvidence(
            start: start,
            ticks: 315,
            steps: 268,
            capturedAfter: 360,
            known: 330
        )

        XCTAssertTrue(try store.save(first, strapIdentifier: strap))
        XCTAssertTrue(try store.save(second, strapIdentifier: strap))
        XCTAssertEqual(
            store.load(strapIdentifier: strap, windowStart: start),
            second
        )
    }

    func testStrongerReplayMayCorrectFalsePositiveStepsDownward() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 40_000)
        let partial = makeEvidence(
            start: start,
            ticks: 155,
            steps: 132,
            capturedAfter: 180,
            known: 160
        )
        let corrected = makeEvidence(
            start: start,
            ticks: 315,
            steps: 126,
            capturedAfter: 360,
            known: 330
        )

        XCTAssertTrue(try store.save(partial, strapIdentifier: strap))
        XCTAssertTrue(try store.save(corrected, strapIdentifier: strap))
        XCTAssertEqual(
            store.load(strapIdentifier: strap, windowStart: start),
            corrected
        )
    }

    func testDurableCurrentCycleReceiptFillsMissingAsyncProjection() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 50_000)
        let receipt = makeEvidence(
            start: start,
            ticks: 315,
            steps: 268,
            capturedAfter: 360,
            known: 330
        )
        XCTAssertTrue(try store.save(receipt, strapIdentifier: strap))

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifier: strap,
            windowStart: start,
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].state, .missing)
        XCTAssertEqual(merged[0].knownStepDeltaSum, 268)
        XCTAssertEqual(merged[0].knownCoverageSeconds, 330)
        XCTAssertEqual(merged[0].dayStart, start)
        let presentation = AtriaDailyStepPresentation.resolve(
            day: start,
            now: start.addingTimeInterval(360),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: merged,
            physiologicalDayStart: start,
            calendar: utcCalendar
        )
        XCTAssertEqual(presentation.valueText, "≥268")
        XCTAssertEqual(presentation.completeness, .partial)
        XCTAssertEqual(presentation.source, .verifiedCanonical)
    }

    func testDurableReceiptWinsOnlyWhenItsCoverageIsStronger() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 60_000)
        XCTAssertTrue(
            try store.save(
                makeEvidence(
                    start: start,
                    ticks: 315,
                    steps: 268,
                    capturedAfter: 360,
                    known: 330
                ),
                strapIdentifier: strap
            )
        )
        let strongerProjection = stepDay(
            start: start,
            end: start.addingTimeInterval(480),
            steps: 300,
            known: 450
        )

        let merged = store.mergingCurrentCycleReceipt(
            into: [strongerProjection],
            strapIdentifier: strap,
            windowStart: start,
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0], strongerProjection)
    }

    func testExactCanonicalCurrentCycleOutranksPartialReceipt() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 70_000)
        XCTAssertTrue(
            try store.save(
                makeEvidence(start: start, ticks: 315, steps: 268),
                strapIdentifier: strap
            )
        )
        let exact = AtriaHistoricalDailyConsumerProjection.StepDay(
            localDay: "1970-01-01",
            dayStart: start,
            dayEnd: start.addingTimeInterval(600),
            state: .available,
            stepCount: 271,
            knownStepDeltaSum: 271,
            knownEpochCount: 10,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: 600,
            missingCoverageSeconds: 0
        )

        let merged = store.mergingCurrentCycleReceipt(
            into: [exact],
            strapIdentifier: strap,
            windowStart: start,
            calendar: utcCalendar
        )

        XCTAssertEqual(merged, [exact])
    }

    func testSavedLinkIdentifierPublishesReceiptBeforeHistoryIdentityReturns()
        throws {
        let suite = "AtriaWhoop4MotionTickDailyStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 80_000)
        defaults.set(
            strap,
            forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
        )
        XCTAssertTrue(
            try store.save(
                makeEvidence(start: start, ticks: 315, steps: 268),
                strapIdentifier: strap
            )
        )

        let identifiers = AtriaWhoop4MotionTickDailyStore
            .persistedStrapIdentifiers(defaults: defaults)
        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: identifiers,
            windowStart: start,
            now: start.addingTimeInterval(360),
            calendar: utcCalendar
        )

        XCTAssertEqual(identifiers, [strap])
        XCTAssertEqual(merged.first?.knownStepDeltaSum, 268)
    }

    func testCurrentSavedLinkReplacesFormerVerifiedHistoryIdentity() throws {
        let suite = "AtriaWhoop4MotionTickDailyStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let formerStrap = UUID().uuidString
        let currentStrap = UUID().uuidString
        defaults.set(
            formerStrap,
            forKey: AtriaBLEManager.OfflineSyncDefaults
                .verifiedHistoryPeripheralID
        )
        defaults.set(
            currentStrap,
            forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
        )

        XCTAssertEqual(
            AtriaWhoop4MotionTickDailyStore.persistedStrapIdentifiers(
                defaults: defaults
            ),
            [currentStrap],
            "a former strap must not contribute to the current cycle"
        )
    }

    func testRelaunchReloadsDurableReceiptFromDisk() throws {
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 90_000)
        let firstProcess =
            AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        XCTAssertTrue(
            try firstProcess.save(
                makeEvidence(start: start, ticks: 315, steps: 268),
                strapIdentifier: strap
            )
        )

        let relaunched =
            AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let merged = relaunched.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: start,
            now: start.addingTimeInterval(360),
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.first?.knownStepDeltaSum, 268)
        XCTAssertEqual(merged.first?.state, .missing)
    }

    func testContainedCurrentCivilDayReceiptIsSafePartialLowerBound() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 172_800)
        let receiptStart = cycleStart.addingTimeInterval(3_600)
        XCTAssertTrue(
            try store.save(
                makeEvidence(
                    start: receiptStart,
                    ticks: 315,
                    steps: 268,
                    capturedAfter: 360,
                    known: 330
                ),
                strapIdentifier: strap
            )
        )

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: cycleStart,
            now: receiptStart.addingTimeInterval(360),
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.first?.dayStart, cycleStart)
        XCTAssertEqual(merged.first?.knownStepDeltaSum, 268)
        XCTAssertEqual(merged.first?.state, .missing)
        XCTAssertEqual(merged.first?.missingCoverageSeconds, 3_600 + 270)
    }

    func testContainedReceiptRemainsCurrentAcrossCivilMidnight() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        // Wake at 20:00 UTC, first verified bank starts at 21:00, and the
        // active physiological cycle remains open after civil midnight.
        let cycleStart = Date(timeIntervalSince1970: 20 * 3_600)
        let receiptStart = cycleStart.addingTimeInterval(3_600)
        let afterMidnight = Date(timeIntervalSince1970: 24 * 3_600 + 600)
        XCTAssertTrue(
            try store.save(
                .init(
                    windowStart: receiptStart,
                    windowEnd: afterMidnight,
                    motionTicks: 315,
                    steps: 268,
                    knownCoverageSeconds: 3_600,
                    missingCoverageSeconds: 7_800,
                    decodedRows: 3_600,
                    capturedThrough: afterMidnight
                ),
                strapIdentifier: strap
            )
        )

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: cycleStart,
            now: afterMidnight,
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.first?.dayStart, cycleStart)
        XCTAssertEqual(merged.first?.knownStepDeltaSum, 268)
        XCTAssertEqual(merged.first?.state, .missing)
        XCTAssertEqual(merged.first?.missingCoverageSeconds, 3_600 + 7_800)
    }

    func testReceiptBeforeCurrentCycleNeverMasqueradesAsToday() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let oldStart = Date(timeIntervalSince1970: 172_800)
        let newCycle = oldStart.addingTimeInterval(60)
        XCTAssertTrue(
            try store.save(
                makeEvidence(
                    start: oldStart,
                    ticks: 315,
                    steps: 268,
                    capturedAfter: 180,
                    known: 330
                ),
                strapIdentifier: strap
            )
        )

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: newCycle,
            now: oldStart.addingTimeInterval(180),
            calendar: utcCalendar
        )

        XCTAssertTrue(merged.isEmpty)
    }

    func testCompleteDurableReceiptPublishesExactCount() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 100_000)
        let complete = HistoricalArchive.MotionTickDayEvidence(
            windowStart: start,
            windowEnd: start.addingTimeInterval(600),
            motionTicks: 320,
            steps: 271,
            knownCoverageSeconds: 600,
            missingCoverageSeconds: 0,
            decodedRows: 20,
            capturedThrough: start.addingTimeInterval(600)
        )
        XCTAssertTrue(try store.save(complete, strapIdentifier: strap))

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: start,
            now: start.addingTimeInterval(600),
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.first?.state, .available)
        XCTAssertEqual(merged.first?.stepCount, 271)
    }

    func testObservedMotionWithNoQualifiedCadenceIsNotPublishedAsZero()
        throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 110_000)
        let unresolved = makeEvidence(
            start: start,
            ticks: 7_097,
            steps: 0,
            capturedAfter: 600,
            known: 530
        )
        XCTAssertTrue(try store.save(unresolved, strapIdentifier: strap))

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: start,
            now: unresolved.capturedThrough,
            calendar: utcCalendar
        )
        let day = try XCTUnwrap(merged.first)
        XCTAssertEqual(day.state, .missing)
        XCTAssertNil(day.stepCount)
        XCTAssertEqual(day.knownCoverageSeconds, 0)
        XCTAssertGreaterThan(day.missingCoverageSeconds, 0)

        let presentation = AtriaDailyStepPresentation.resolve(
            day: start,
            now: unresolved.capturedThrough,
            liveCount: 4_257,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: unresolved.capturedThrough,
            canonicalDays: merged,
            physiologicalDayStart: start,
            calendar: utcCalendar
        )
        XCTAssertNil(presentation.count)
        XCTAssertEqual(
            presentation.unavailabilityReason,
            .motionObservedCountUnresolved
        )
        XCTAssertEqual(
            presentation.detailText,
            "Strap motion found · count still resolving"
        )
    }

    func testTrueStationaryCompleteReceiptMayPublishVerifiedZero() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 160_000)
        let stationary = HistoricalArchive.MotionTickDayEvidence(
            windowStart: start,
            windowEnd: start.addingTimeInterval(600),
            motionTicks: 0,
            steps: 0,
            knownCoverageSeconds: 600,
            missingCoverageSeconds: 0,
            decodedRows: 600,
            capturedThrough: start.addingTimeInterval(600)
        )
        XCTAssertTrue(try store.save(stationary, strapIdentifier: strap))

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: start,
            now: stationary.capturedThrough,
            calendar: utcCalendar
        )
        XCTAssertEqual(merged.first?.state, .available)
        XCTAssertEqual(merged.first?.stepCount, 0)
    }

    func testVerifiedOffloadRefreshBypassesUnrelatedHistoryPriorityFence() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sessions = try String(
            contentsOf: testsURL.deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )
        let ble = try String(
            contentsOf: testsURL.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(sessions.range(
            of: "private func refreshCurrentCycleStrapStepReceipt"
        ))
        let end = try XCTUnwrap(sessions.range(
            of: "/// Loads one older verified canonical page",
            range: start.upperBound..<sessions.endIndex
        ))
        let body = String(sessions[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains(
            "HistoricalArchive.motionTickDayEvidenceRead("
        ))
        XCTAssertTrue(body.contains(
            "Self.currentCycleStepReceiptQueue.async"
        ), "bounded compact receipt work must not wait behind lifetime archive projections")
        XCTAssertTrue(body.contains(
            "Self.historySnapshotProjectionQueue.sync"
        ), "the legacy JSONL fallback must remain serialized with heavyweight archive readers")
        XCTAssertTrue(body.contains(
            "AtriaWhoop4MotionTickDailyStore.shared.save("
        ))
        XCTAssertFalse(body.contains(
            "exactRecoveryProjectionOwnsArchivePriority"
        ))
        XCTAssertTrue(sessions.contains(
            "reason: \"verified_bank_offload\""
        ))
        XCTAssertTrue(sessions.contains(
            "reason: \"session_store_init\""
        ))
        XCTAssertTrue(sessions.contains(
            "reason: \"compact_generation_durable\""
        ), "partial durable compact progress must refresh the daily receipt")
        XCTAssertTrue(sessions.contains(
            ".didSynchronizeNotification"
        ))
        XCTAssertTrue(ble.contains(
            "reason: \"compact_generation_durable\""
        ))
        XCTAssertTrue(ble.contains(
            "allowRetry: false"
        ), "post-fsync ticket verification must not start another BLE drain")
        XCTAssertTrue(body.contains(
            "if !changed"
        ))
        XCTAssertTrue(body.contains(
            ".didSaveNotification"
        ), "an unchanged durable receipt must still refresh relaunch surfaces")
    }

    func testArchiveWideMotionReadersShareOneSerialConsumerLane() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourcesURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let sessions = try String(
            contentsOf: sourcesURL.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let ble = try String(
            contentsOf: sourcesURL.appendingPathComponent(
                "AtriaBLEManager.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(sessions.contains(
            "historySnapshotProjectionQueue =\n        HistoricalArchive.consumerProjectionQueue"
        ))
        XCTAssertTrue(sessions.contains(
            "workoutStepEvidenceQueue =\n        HistoricalArchive.consumerProjectionQueue"
        ))
        XCTAssertTrue(sessions.contains(
            "private static let currentCycleStepReceiptQueue = DispatchQueue("
        ))
        XCTAssertTrue(ble.contains(
            "HistoricalArchive.consumerProjectionQueue.async"
        ))

        let historyStart = try XCTUnwrap(sessions.range(
            of: "private func refreshHistorySnapshotCache"
        ))
        let historyEnd = try XCTUnwrap(sessions.range(
            of: "private func refreshCurrentCycleStrapStepReceipt",
            range: historyStart.upperBound..<sessions.endIndex
        ))
        let historyBody = String(
            sessions[historyStart.lowerBound..<historyEnd.lowerBound]
        )
        XCTAssertFalse(historyBody.contains(
            "HistoricalArchive.motionTickDayEvidence("
        ), "history refresh must consume the durable receipt, not decode it again")
        XCTAssertTrue(historyBody.contains(
            "AtriaWhoop4MotionTickDailyStore.shared.load("
        ))

        let home = try String(
            contentsOf: sourcesURL.appendingPathComponent(
                "AtriaHomeView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(home.contains(
            "ble.$status.removeDuplicates().map { _ in () }"
        ))
        XCTAssertTrue(home.contains(
            "ble.$isBluetoothReady.removeDuplicates().map { _ in () }"
        ))
        let historyPublisher = try XCTUnwrap(home.range(
            of: "store.$historySnapshot"
        ))
        let historyPublisherEnd = try XCTUnwrap(home.range(
            of: ".store(in: &cancellables)",
            range: historyPublisher.upperBound..<home.endIndex
        ))
        let historyPublisherBody = String(
            home[historyPublisher.lowerBound..<historyPublisherEnd.upperBound]
        )
        XCTAssertTrue(historyPublisherBody.contains(
            "self?.publishCoreLive()"
        ))
    }

    private func makeEvidence(
        start: Date,
        ticks: Int,
        steps: Int,
        capturedAfter: TimeInterval = 180,
        known: Int = 160
    ) -> HistoricalArchive.MotionTickDayEvidence {
        .init(
            windowStart: start,
            windowEnd: start.addingTimeInterval(600),
            motionTicks: ticks,
            steps: steps,
            knownCoverageSeconds: known,
            missingCoverageSeconds: 600 - known,
            decodedRows: 20,
            capturedThrough: start.addingTimeInterval(capturedAfter)
        )
    }

    private func stepDay(
        start: Date,
        end: Date,
        steps: Int,
        known: Int
    ) -> AtriaHistoricalDailyConsumerProjection.StepDay {
        .init(
            localDay: "1970-01-01",
            dayStart: start,
            dayEnd: end,
            state: .missing,
            stepCount: nil,
            knownStepDeltaSum: steps,
            knownEpochCount: 1,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: known,
            missingCoverageSeconds: max(
                0,
                Int(end.timeIntervalSince(start)) - known
            )
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
