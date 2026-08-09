import XCTest
@testable import Atria

final class AtriaWhoop4MotionTickCompactStoreTests: XCTestCase {
    private var directory: URL!
    private var store: AtriaWhoop4MotionTickCompactStore!
    private var strapIdentifier: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AtriaWhoop4MotionTickCompactStoreTests-\(UUID().uuidString)"
            )
        store = AtriaWhoop4MotionTickCompactStore(
            directoryURL: directory
        )
        strapIdentifier = UUID().uuidString
    }

    override func tearDownWithError() throws {
        store = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testDuplicateCanonicalPayloadIsIdempotent() throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down))
        let record = makeRecord(unix: unix, flash: 1, tick: 1)
        let payload = payloadIdentity(unix: unix, tick: 1)

        XCTAssertTrue(
            try store.append(
                record: record,
                rawPayload: payload,
                strapIdentifier: strapIdentifier
            )
        )
        XCTAssertFalse(
            try store.append(
                record: record,
                rawPayload: payload,
                strapIdentifier: strapIdentifier
            )
        )
    }

    func testSynchronizePublishesOnlyNewDurableGenerations() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down))
        let firstPublication = expectation(
            description: "first durable compact generation"
        )
        var observer = NotificationCenter.default.addObserver(
            forName: AtriaWhoop4MotionTickCompactStore
                .didSynchronizeNotification,
            object: nil,
            queue: .main
        ) { _ in
            firstPublication.fulfill()
        }
        try appendPoint(base: unix, second: 0)
        try store.synchronize()
        await fulfillment(of: [firstPublication], timeout: 1)
        NotificationCenter.default.removeObserver(observer)

        let duplicatePublication = expectation(
            description: "no duplicate publication without a new append"
        )
        duplicatePublication.isInverted = true
        observer = NotificationCenter.default.addObserver(
            forName: AtriaWhoop4MotionTickCompactStore
                .didSynchronizeNotification,
            object: nil,
            queue: .main
        ) { _ in
            duplicatePublication.fulfill()
        }
        try store.synchronize()
        await fulfillment(of: [duplicatePublication], timeout: 0.1)
        NotificationCenter.default.removeObserver(observer)

        let secondPublication = expectation(
            description: "second durable compact generation"
        )
        observer = NotificationCenter.default.addObserver(
            forName: AtriaWhoop4MotionTickCompactStore
                .didSynchronizeNotification,
            object: nil,
            queue: .main
        ) { _ in
            secondPublication.fulfill()
        }
        try appendPoint(base: unix, second: 1)
        try store.synchronize()
        await fulfillment(of: [secondPublication], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
    }

    func testHistoricalDrainPublishesCompactStepsAtDurableCheckpoints()
        throws
    {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let checkpointStart = try XCTUnwrap(source.range(
            of: "if let checkpoint = checkpointCoordinator.recordPersistence("
        ))
        let callbackStart = try XCTUnwrap(source.range(
            of: "Task { @MainActor [weak self] in",
            range: checkpointStart.upperBound..<source.endIndex
        ))
        let checkpoint = String(
            source[checkpointStart.lowerBound..<callbackStart.lowerBound]
        )

        let rawSync = try XCTUnwrap(checkpoint.range(
            of: ".synchronizeDurableStorage(generation: generation)"
        ))
        let admission = try XCTUnwrap(checkpoint.range(
            of: "markCurrentPrefixArchiveDurableWithReceipt"
        ))
        let compactSync = try XCTUnwrap(checkpoint.range(
            of: "AtriaWhoop4MotionTickCompactStore.shared"
        ))
        let completed = try XCTUnwrap(checkpoint.range(
            of: "checkpointCoordinator.checkpointCompleted("
        ))

        XCTAssertLessThan(rawSync.lowerBound, admission.lowerBound)
        XCTAssertLessThan(admission.lowerBound, compactSync.lowerBound)
        XCTAssertLessThan(compactSync.lowerBound, completed.lowerBound)
        XCTAssertTrue(
            checkpoint.contains("checkpoint_flush_failed"),
            "compact cache failure must not invalidate canonical durability"
        )
    }

    func testExactWindowRequiresAtLeastNinetyPercentCoverage() async throws {
        let base = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 120
        for second in 0..<89 {
            try appendPoint(base: base, second: second)
        }
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = Date(timeIntervalSince1970: TimeInterval(base + 99))
        let below = await coverage(
            start: start,
            end: end,
            strapIdentifier: strapIdentifier
        )
        XCTAssertEqual(below.expectedSeconds, 100)
        XCTAssertEqual(below.observedSeconds, 89)
        XCTAssertFalse(below.satisfiesNinetyPercentExactWindow)

        try appendPoint(base: base, second: 89)
        let passing = await coverage(
            start: start,
            end: end,
            strapIdentifier: strapIdentifier
        )
        XCTAssertEqual(passing.observedSeconds, 90)
        XCTAssertEqual(passing.densityPercent, 90)
        XCTAssertEqual(passing.maximumMissingRunSeconds, 10)
        XCTAssertTrue(passing.satisfiesNinetyPercentExactWindow)
    }

    func testConfirmedWorkoutWindowPublishesFromCompactCorrectedTimeline()
        async throws {
        let base = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 180
        let duration: TimeInterval = 92.3
        let count = 97
        let sampleRate = Double(count - 1) / duration
        let points = (0..<count).map { index in
            let elapsed = Double(index) / sampleRate
            let phase = 2 * Double.pi * 0.42 * elapsed
            let textureScale = 0.55
            return AtriaWhoop4MotionTickCompactStore.MigrationPoint(
                timestamp: TimeInterval(base) + elapsed,
                flash: UInt32(index),
                tick: index * 2,
                gravityX: textureScale * (
                    0.073 * sin(phase)
                        + 0.16 * pseudoNoise(index, channel: 1)
                ),
                gravityY: textureScale * (
                    0.073 * cos(phase)
                        + 0.16 * pseudoNoise(index, channel: 2)
                ),
                gravityZ: 1 + textureScale * 0.16
                    * pseudoNoise(index, channel: 3),
                unknownMotionScalar32: 0.12,
                rawPayload: payloadIdentity(
                    unix: base + UInt32(index),
                    tick: index * 2
                )
            )
        }
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        try await Task.detached(priority: .utility) {
            _ = try store.appendMigrated(
                points,
                strapIdentifier: strapIdentifier
            )
            try store.synchronize()
        }.value

        let read = await Task.detached(priority: .utility) {
            store.motionTickWindowRead(
                start: Date(timeIntervalSince1970: TimeInterval(base)),
                end: Date(
                    timeIntervalSince1970: TimeInterval(base) + duration
                ),
                strapIdentifier: strapIdentifier
            )
        }.value
        guard case .qualified(let window) = read else {
            return XCTFail("expected the compact workout window to qualify")
        }
        XCTAssertEqual(window.steps, 133)
        XCTAssertEqual(window.delta, 192)
        XCTAssertEqual(window.coverageFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(window.decodedRows, count)
    }

    func testMissingCompactWorkoutBoundaryNeverClaimsNegativeEvidence()
        async throws {
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let start = Date().addingTimeInterval(-120)
        let read = await Task.detached(priority: .utility) {
            store.motionTickWindowRead(
                start: start,
                end: start.addingTimeInterval(90),
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(read, .incomplete)
    }

    func testCompactWorkoutWindowRefusesMoreThanRetainedFourBuckets()
        async throws {
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let start = Date().addingTimeInterval(-5 * 86_400)
        let read = await Task.detached(priority: .utility) {
            store.motionTickWindowRead(
                start: start,
                end: Date(),
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(read, .incomplete)
    }

    func testStrapIdentityCannotReadAnotherStrapsShard() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        try appendPoint(base: unix, second: 0)
        let coverage = await coverage(
            start: Date(timeIntervalSince1970: TimeInterval(unix)),
            end: Date(timeIntervalSince1970: TimeInterval(unix + 1)),
            strapIdentifier: UUID().uuidString
        )
        XCTAssertEqual(coverage.observedSeconds, 0)
        XCTAssertFalse(coverage.satisfiesNinetyPercentExactWindow)
    }

    func testSourceFingerprintChangesWhenCompactShardGrows() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        let start = Date(timeIntervalSince1970: TimeInterval(unix))
        let end = start.addingTimeInterval(60)
        let before = await sourceFingerprint(start: start, end: end)

        try appendPoint(base: unix, second: 0)
        let afterFirstAppend = await sourceFingerprint(
            start: start,
            end: end
        )
        XCTAssertNotEqual(before, afterFirstAppend)

        let duplicate = try store.append(
            record: makeRecord(unix: unix, flash: 1, tick: 0),
            rawPayload: payloadIdentity(unix: unix, tick: 0),
            strapIdentifier: strapIdentifier
        )
        XCTAssertFalse(duplicate)
        let afterDuplicate = await sourceFingerprint(start: start, end: end)
        XCTAssertEqual(afterFirstAppend, afterDuplicate)
    }

    func testOneCompactReadCanVerifyMultipleExactTickets() async throws {
        let base = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 120
        for second in 0..<100 {
            try appendPoint(base: base, second: second)
        }
        let tickets = [
            AtriaWhoop4MotionBankCoverageLedger.OffloadTicket(
                id: "first",
                strapIdentifier: strapIdentifier,
                start: Date(timeIntervalSince1970: TimeInterval(base)),
                end: Date(timeIntervalSince1970: TimeInterval(base + 49)),
                armedConnectionStartedAt: nil,
                attempts: 1,
                lastAttemptAt: nil
            ),
            AtriaWhoop4MotionBankCoverageLedger.OffloadTicket(
                id: "second",
                strapIdentifier: strapIdentifier,
                start: Date(timeIntervalSince1970: TimeInterval(base + 50)),
                end: Date(timeIntervalSince1970: TimeInterval(base + 99)),
                armedConnectionStartedAt: nil,
                attempts: 0,
                lastAttemptAt: nil
            ),
        ]
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let coverages = await Task.detached(priority: .utility) {
            store.transportCoverages(
                tickets: tickets,
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(coverages.count, 2)
        XCTAssertTrue(try XCTUnwrap(coverages["first"])
            .satisfiesNinetyPercentExactWindow)
        XCTAssertTrue(try XCTUnwrap(coverages["second"])
            .satisfiesNinetyPercentExactWindow)
    }

    func testCanonicalMigrationIsIdempotentAndAdvancesFingerprint() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        let start = Date(timeIntervalSince1970: TimeInterval(unix))
        let end = start.addingTimeInterval(60)
        let before = await sourceFingerprint(start: start, end: end)
        let point = AtriaWhoop4MotionTickCompactStore.MigrationPoint(
            timestamp: TimeInterval(unix),
            flash: 7,
            tick: 3,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 1,
            unknownMotionScalar32: 0.05,
            rawPayload: payloadIdentity(unix: unix, tick: 3)
        )
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let first = try await Task.detached(priority: .utility) {
            try store.appendMigrated(
                [point],
                strapIdentifier: strapIdentifier
            )
        }.value
        let second = try await Task.detached(priority: .utility) {
            try store.appendMigrated(
                [point],
                strapIdentifier: strapIdentifier
            )
        }.value

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        let after = await sourceFingerprint(start: start, end: end)
        XCTAssertNotEqual(before, after)
    }

    func testRelaunchTruncatesPartialTailBeforeAppending() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        try appendPoint(base: unix, second: 0)
        try store.synchronize()
        store = nil

        let shard = try onlyShard()
        let tornTail = try FileHandle(forWritingTo: shard)
        try tornTail.seekToEnd()
        try tornTail.write(contentsOf: Data([0x41, 0x54, 0x4D, 0x31, 0xAA]))
        try tornTail.synchronize()
        try tornTail.close()
        XCTAssertEqual(try shardSize(shard), 52 + 5)

        store = AtriaWhoop4MotionTickCompactStore(directoryURL: directory)
        try appendPoint(base: unix, second: 1)
        try store.synchronize()

        XCTAssertEqual(try shardSize(shard), 52 * 2)
        let repairedCoverage = await coverage(
            start: Date(timeIntervalSince1970: TimeInterval(unix)),
            end: Date(timeIntervalSince1970: TimeInterval(unix + 1)),
            strapIdentifier: strapIdentifier
        )
        XCTAssertEqual(repairedCoverage.observedSeconds, 2)
    }

    func testCorruptRecordIdentityDoesNotBlockCanonicalRepair() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        let record = makeRecord(unix: unix, flash: 1, tick: 1)
        let payload = payloadIdentity(unix: unix, tick: 1)
        XCTAssertTrue(
            try store.append(
                record: record,
                rawPayload: payload,
                strapIdentifier: strapIdentifier
            )
        )
        try store.synchronize()
        store = nil

        let shard = try onlyShard()
        var bytes = try Data(contentsOf: shard)
        XCTAssertEqual(bytes.count, 52)
        // Keep magic and identity intact while making the timestamp NaN.
        bytes.replaceSubrange(4..<12, with: repeatElement(0xFF, count: 8))
        try bytes.write(to: shard, options: .atomic)

        store = AtriaWhoop4MotionTickCompactStore(directoryURL: directory)
        XCTAssertTrue(
            try store.append(
                record: record,
                rawPayload: payload,
                strapIdentifier: strapIdentifier
            )
        )
        try store.synchronize()

        let repairedCoverage = await coverage(
            start: Date(timeIntervalSince1970: TimeInterval(unix)),
            end: Date(timeIntervalSince1970: TimeInterval(unix + 1)),
            strapIdentifier: strapIdentifier
        )
        XCTAssertEqual(repairedCoverage.observedSeconds, 1)
    }

    func testRetentionDropsDeletedShardIdentitiesInSameProcess() throws {
        let now = UInt32(Date().timeIntervalSince1970.rounded(.down))
        let oldUnix = now - UInt32(5 * 86_400)
        let oldRecord = makeRecord(unix: oldUnix, flash: 1, tick: 1)
        let oldPayload = payloadIdentity(unix: oldUnix, tick: 1)
        XCTAssertTrue(
            try store.append(
                record: oldRecord,
                rawPayload: oldPayload,
                strapIdentifier: strapIdentifier
            )
        )

        try appendPoint(base: now, second: 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "bin" }.count,
            1
        )

        // The old shard was deleted, so its digest must no longer remain in
        // the in-memory duplicate index.
        XCTAssertTrue(
            try store.append(
                record: oldRecord,
                rawPayload: oldPayload,
                strapIdentifier: strapIdentifier
            )
        )
    }

    func testConfirmedWorkoutLaunchAndForegroundPathsAreCompactOnly() throws {
        let sourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let sessions = try String(
            contentsOf: sourcesURL.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(sessions.range(
            of: "private func scheduleConfirmedWorkoutStepEvidencePublication("
        ))
        let end = try XCTUnwrap(sessions.range(
            of: "nonisolated static func workoutStepNegativeAttemptKey(",
            range: start.upperBound..<sessions.endIndex
        ))
        let publication = String(
            sessions[start.lowerBound..<end.lowerBound]
        )

        XCTAssertTrue(publication.contains(
            "AtriaWhoop4MotionTickCompactStore.shared"
        ))
        XCTAssertTrue(publication.contains(
            ".motionTickWindowRead("
        ))
        XCTAssertTrue(publication.contains(
            "Self.workoutStepEvidenceQueue.async"
        ))
        for forbidden in [
            "HistoricalArchive.motionTickWindowRead(",
            "HistoricalArchive.consumerSourceFingerprint()",
            "HistoricalArchive.consumerProjectionQueue",
            "exactRecoveryProjectionOwnsArchivePriority()",
            "UIApplication.shared.applicationState",
        ] {
            XCTAssertFalse(
                publication.contains(forbidden),
                "hot workout-step publication must not contain \(forbidden)"
            )
        }
        XCTAssertTrue(sessions.contains(
            "reason: \"session_store_init_workout_evidence\""
        ))
        XCTAssertTrue(sessions.contains(
            "reason: \"compact_generation_durable\""
        ))
        XCTAssertFalse(sessions.contains(
            "workoutStepEvidenceDeferredUntilForeground"
        ))

        let resumeStart = try XCTUnwrap(sessions.range(
            of: "func resumeDeferredForegroundArchiveWork(reason: String)"
        ))
        let resumeEnd = try XCTUnwrap(sessions.range(
            of: "private func finishConfirmedWorkoutRehydrationCompletions(",
            range: resumeStart.upperBound..<sessions.endIndex
        ))
        let resume = String(
            sessions[resumeStart.lowerBound..<resumeEnd.lowerBound]
        )
        XCTAssertFalse(resume.contains(
            "scheduleConfirmedWorkoutStepEvidencePublication("
        ), "scene-active replay must never re-arm canonical workout motion")

        let app = try String(
            contentsOf: sourcesURL.appendingPathComponent("AtriaApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(app.contains(
            "scheduleBoundedLegacyCurrentCycleStepMigrationIfSafe("
        ), "guarded BGProcessing must retain eventual recent-workout compact migration")

        let productionSources = try FileManager.default.contentsOfDirectory(
            at: sourcesURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.pathExtension == "swift"
                && $0.lastPathComponent != "HistoricalArchive.swift"
        }
        for sourceURL in productionSources {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertFalse(
                source.contains("HistoricalArchive.motionTickWindowRead(")
                    || source.contains("HistoricalArchive.motionTickWindow("),
                "\(sourceURL.lastPathComponent) must not call the legacy workout JSONL reader"
            )
        }
    }

    private func appendPoint(base: UInt32, second: Int) throws {
        let unix = base + UInt32(second)
        XCTAssertTrue(
            try store.append(
                record: makeRecord(
                    unix: unix,
                    flash: UInt32(second + 1),
                    tick: second
                ),
                rawPayload: payloadIdentity(unix: unix, tick: second),
                strapIdentifier: strapIdentifier
            )
        )
    }

    private func coverage(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) async -> HistoricalArchive.MotionBankTransportCoverage {
        let store = try! XCTUnwrap(store)
        return await Task.detached(priority: .utility) {
            store.transportCoverage(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }.value
    }

    private func sourceFingerprint(
        start: Date,
        end: Date
    ) async -> String? {
        let store = try! XCTUnwrap(store)
        let strapIdentifier = try! XCTUnwrap(strapIdentifier)
        return await Task.detached(priority: .utility) {
            store.sourceFingerprint(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }.value
    }

    private func onlyShard() throws -> URL {
        let shards = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "bin" }
        return try XCTUnwrap(shards.first)
    }

    private func shardSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
    }

    private func makeRecord(
        unix: UInt32,
        flash: UInt32,
        tick: Int
    ) -> HistoricalArchive.Record {
        var record = HistoricalArchive.Record(
            schema: HistoricalArchive.schema,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(unix)),
            source: "0x2f",
            layoutVersion: HistoricalArchive.layoutVersion,
            sequence: Int(AtriaWhoop4HistoricalLayout.v24.rawValue),
            command: 0x2f,
            unix7: unix,
            subsec11: 0,
            flash13: flash,
            payloadLength: 92,
            whoofHR17: 80,
            whoofRRNum18: 0,
            whoofRR19: [],
            kRR64: [],
            gravityX36: 0,
            gravityY40: 0,
            gravityZ44: 1,
            unknownMotionScalar32: 0.05,
            gravityMagnitude: 1,
            gravityValidated: true,
            candidateRR: [],
            rawPayloadHex: "",
            clockDeviceRef: unix,
            clockWallRef: unix,
            clockDriftSeconds: 0,
            clockCorrectedUnix7: unix,
            clockCorrectionStatus: "clock_ref_present",
            currentSessionUsable: true,
            metricUsable: true,
            usabilityReason: "test"
        )
        record.motionTickCounter88 = tick
        return record
    }

    private func payloadIdentity(unix: UInt32, tick: Int) -> [UInt8] {
        withUnsafeBytes(of: unix.littleEndian) { unixBytes in
            withUnsafeBytes(of: UInt16(tick).littleEndian) { tickBytes in
                Array(unixBytes) + Array(tickBytes)
            }
        }
    }

    private func pseudoNoise(_ index: Int, channel: Int) -> Double {
        let raw = sin(
            Double(index + 1)
                * (12.9898 + Double(channel) * 78.233)
        ) * 43_758.5453
        let fraction = raw - floor(raw)
        return fraction * 2 - 1
    }
}
