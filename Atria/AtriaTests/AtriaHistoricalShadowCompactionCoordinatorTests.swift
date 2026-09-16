import XCTest
@testable import Atria

final class AtriaHistoricalShadowCompactionCoordinatorTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/atria-shadow-coordinator-tests")
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testPoisonChunkCannotStarveLaterValidChunk() {
        let poison = chunk(id: "poison", createdAt: now.addingTimeInterval(-200))
        let valid = chunk(id: "valid", createdAt: now.addingTimeInterval(-100))
        enum FixtureError: Error { case poison }
        var attempted: [String] = []

        let outcome = AtriaHistoricalShadowCompactionCoordinator.commitFirst(
            candidates: [poison, valid]
        ) { candidate in
            attempted.append(candidate.id)
            if candidate.id == poison.id { throw FixtureError.poison }
            return candidate.id
        }

        guard case let .committed(value, failures) = outcome else {
            return XCTFail("later valid chunk must commit")
        }
        XCTAssertEqual(value, valid.id)
        XCTAssertEqual(attempted, [poison.id, valid.id])
        XCTAssertEqual(failures.map(\.chunkID), [poison.id])
    }

    func testSceneBackgroundRetirementSkipsHugeLegacyChunks() {
        var huge = chunk(id: "legacy-monolith", createdAt: now.addingTimeInterval(-80 * 86_400))
        huge.byteCount = 134_218_092
        var medium = chunk(id: "july-shard", createdAt: now.addingTimeInterval(-70 * 86_400))
        medium.byteCount = 72_358_010
        var small = chunk(id: "finishable", createdAt: now.addingTimeInterval(-40 * 86_400))
        small.byteCount = 20_217
        let selected = AtriaHistoricalShadowCompactionCoordinator
            .sceneBackgroundRetirementCandidates([huge, medium, small])
        XCTAssertEqual(selected.map(\.id), [small.id])

        let onlyHuge = AtriaHistoricalShadowCompactionCoordinator
            .sceneBackgroundRetirementCandidates([huge, medium])
        XCTAssertTrue(
            onlyHuge.isEmpty,
            "an 8-25s pass must not start a 72/134 MB JSONL"
        )
    }

    func testOverdueIdleRetirementCapsAtEightMegabytes() {
        var tooBig = chunk(id: "median-12mb", createdAt: now.addingTimeInterval(-50 * 86_400))
        tooBig.byteCount = 12 * 1024 * 1024
        var finishable = chunk(id: "finishable-2mb", createdAt: now.addingTimeInterval(-40 * 86_400))
        finishable.byteCount = 2_395_673
        let selected = AtriaHistoricalShadowCompactionCoordinator
            .sceneBackgroundRetirementCandidates(
                [tooBig, finishable],
                maximumByteCount: 8 * 1024 * 1024
            )
        XCTAssertEqual(
            selected.map(\.id),
            [finishable.id],
            "a 180s sitting lease must skip a 12 MB JSONL and take 2.4 MB"
        )
    }

    func testDeskSittingCapStillSkipsLegacyMonoliths() {
        var huge = chunk(id: "legacy-monolith", createdAt: now.addingTimeInterval(-80 * 86_400))
        huge.byteCount = 134_218_092
        var medium = chunk(id: "july-shard", createdAt: now.addingTimeInterval(-70 * 86_400))
        medium.byteCount = 72_358_010
        var mid = chunk(id: "isolated-33mb", createdAt: now.addingTimeInterval(-40 * 86_400))
        mid.byteCount = 33_555_393
        let selected = AtriaHistoricalShadowCompactionCoordinator
            .sceneBackgroundRetirementCandidates(
                [huge, medium, mid],
                maximumByteCount: AtriaCompactIMULiveDiagnostics.sittingIdleLargeChunkBytes
            )
        XCTAssertEqual(
            selected.map(\.id),
            [mid.id],
            "desk sitting may take 33 MB but must never start 72/134 MB JSONL"
        )
    }

    func testDeskSittingPrefersLargestIsolatedChunk() {
        var small = chunk(id: "raw-4mb", createdAt: now.addingTimeInterval(-40 * 86_400))
        small.byteCount = 4_194_313
        var large = chunk(id: "raw-33mb", createdAt: now.addingTimeInterval(-50 * 86_400))
        large.byteCount = 33_555_830
        XCTAssertEqual(
            AtriaHistoricalShadowCompactionCoordinator.orderedIdleRetirementCandidates(
                [small, large],
                preferLarge: true,
                limit: 1
            ).map(\.id),
            [large.id]
        )
        XCTAssertEqual(
            AtriaHistoricalShadowCompactionCoordinator.orderedIdleRetirementCandidates(
                [small, large],
                preferLarge: false,
                limit: 3
            ).map(\.id),
            [small.id, large.id]
        )
    }

    func testSittingIdleBuildCandidatesTrySmallFilesBeforeOneLarge() {
        var tiny = chunk(id: "raw-2mb", createdAt: now.addingTimeInterval(-30 * 86_400))
        tiny.byteCount = 2_000_000
        var small = chunk(id: "raw-4mb", createdAt: now.addingTimeInterval(-40 * 86_400))
        small.byteCount = 4_194_313
        var large = chunk(id: "raw-33mb", createdAt: now.addingTimeInterval(-50 * 86_400))
        large.byteCount = 33_555_830
        XCTAssertEqual(
            AtriaHistoricalShadowCompactionCoordinator.sittingIdleBuildCandidates(
                [large, small, tiny],
                smallChunkBytes: 8 * 1024 * 1024,
                includeOneLarge: true
            ).map(\.id),
            [tiny.id, small.id, large.id]
        )
        XCTAssertEqual(
            AtriaHistoricalShadowCompactionCoordinator.sittingIdleBuildCandidates(
                [large, small, tiny],
                smallChunkBytes: 8 * 1024 * 1024,
                includeOneLarge: false
            ).map(\.id),
            [tiny.id, small.id]
        )
    }

    func testSittingIdlePicksSmallestIsolatedLargeFileWhenSmallShardsAreGone() {
        var mid = chunk(id: "raw-8mb", createdAt: now.addingTimeInterval(-40 * 86_400))
        mid.byteCount = 8_515_342
        var large = chunk(id: "raw-33mb", createdAt: now.addingTimeInterval(-50 * 86_400))
        large.byteCount = 33_555_830
        XCTAssertEqual(
            AtriaHistoricalShadowCompactionCoordinator.sittingIdleBuildCandidates(
                [large, mid],
                smallChunkBytes: 8 * 1024 * 1024,
                includeOneLarge: true
            ).map(\.id),
            [mid.id],
            "an 8.5 MB isolated shard must finish before a 33 MB parse holds already_running"
        )
    }

    func testSittingIdleDoesNotStartLargeJSONLWhileSmallFilesRemain() {
        var tiny = chunk(id: "raw-2mb", createdAt: now.addingTimeInterval(-30 * 86_400))
        tiny.byteCount = 2_000_000
        var large = chunk(id: "raw-33mb", createdAt: now.addingTimeInterval(-50 * 86_400))
        large.byteCount = 33_555_830
        XCTAssertFalse(
            AtriaHistoricalShadowCompactionCoordinator.shouldIncludeLargeIdleChunk(
                isolatedUnskipped: [tiny, large],
                smallChunkBytes: 8 * 1024 * 1024,
                preferLarge: true
            )
        )
        XCTAssertTrue(
            AtriaHistoricalShadowCompactionCoordinator.shouldIncludeLargeIdleChunk(
                isolatedUnskipped: [large],
                smallChunkBytes: 8 * 1024 * 1024,
                preferLarge: true
            )
        )
        XCTAssertFalse(
            AtriaHistoricalShadowCompactionCoordinator.shouldIncludeLargeIdleChunk(
                isolatedUnskipped: [large],
                smallChunkBytes: 8 * 1024 * 1024,
                preferLarge: false
            )
        )
        XCTAssertEqual(
            AtriaHistoricalShadowCompactionCoordinator.preferredIdleShadowCutoverChunkID(
                shadowed: [large, tiny],
                smallChunkBytes: 8 * 1024 * 1024,
                allowLarge: false
            ),
            tiny.id
        )
        XCTAssertNil(
            AtriaHistoricalShadowCompactionCoordinator.preferredIdleShadowCutoverChunkID(
                shadowed: [large],
                smallChunkBytes: 8 * 1024 * 1024,
                allowLarge: false
            ),
            "a 33 MB shadow cutover must wait until isolated ≤8 MB JSONL is gone"
        )
        XCTAssertEqual(
            AtriaHistoricalShadowCompactionCoordinator.preferredIdleShadowCutoverChunkID(
                shadowed: [large],
                smallChunkBytes: 8 * 1024 * 1024,
                allowLarge: true
            ),
            large.id
        )
    }

    func testIdleRetirementSkipsShardsThatOverlapTheMonolith() {
        let start = now.addingTimeInterval(-80 * 86_400)
        var monolith = boundedChunk(
            id: "legacy-monolith",
            first: start,
            last: start.addingTimeInterval(26 * 86_400),
            bytes: 134_218_092
        )
        monolith.relativePath = "historical-archive.jsonl"
        let overlapping = boundedChunk(
            id: "july-overlap",
            first: start.addingTimeInterval(20 * 86_400),
            last: start.addingTimeInterval(21 * 86_400),
            bytes: 125_934
        )
        let isolated = boundedChunk(
            id: "july-29-isolated",
            first: start.addingTimeInterval(43 * 86_400),
            last: start.addingTimeInterval(43 * 86_400 + 90),
            bytes: 130_052
        )
        let active = activeChunk(id: "active", createdAt: now)
        let catalog = AtriaHistoricalArchiveCatalog(
            version: AtriaHistoricalArchiveCatalog.currentVersion,
            generation: 1,
            activeChunkID: active.id,
            chunks: [monolith, overlapping, isolated, active]
        )
        let selected = AtriaHistoricalShadowCompactionCoordinator
            .skippingOversizedTimeOverlaps(
                [overlapping, isolated],
                catalog: catalog,
                oversizedByteCount: 2 * 1024 * 1024
            )
        XCTAssertEqual(selected.map(\.id), [isolated.id])
    }

    func testLockAndSittingSkipShardsThatOverlapLegacyMonoliths() {
        let start = Date(timeIntervalSince1970: 1_783_000_000)
        var monolith = boundedChunk(
            id: "legacy-134",
            first: start,
            last: start.addingTimeInterval(26 * 86_400),
            bytes: 134_218_092
        )
        monolith.state = .sealed
        let overlapping = boundedChunk(
            id: "july-overlap",
            first: start.addingTimeInterval(18 * 86_400),
            last: start.addingTimeInterval(18 * 86_400 + 90),
            bytes: 125_934
        )
        let isolated = boundedChunk(
            id: "july-29-isolated",
            first: start.addingTimeInterval(43 * 86_400),
            last: start.addingTimeInterval(43 * 86_400 + 90),
            bytes: 130_052
        )
        let active = activeChunk(id: "active", createdAt: now)
        let catalog = AtriaHistoricalArchiveCatalog(
            version: AtriaHistoricalArchiveCatalog.currentVersion,
            generation: 1,
            activeChunkID: active.id,
            chunks: [monolith, overlapping, isolated, active]
        )
        let selected = AtriaHistoricalShadowCompactionCoordinator
            .isolatedFinishableIdleCandidates(
                [overlapping, isolated],
                catalog: catalog,
                maximumByteCount: 8 * 1024 * 1024,
                skippedIDs: []
            )
        XCTAssertEqual(selected.map(\.id), [isolated.id])
    }

    func testPermanentIdleFailuresAreRememberedSoLaterShardsCanDrain() {
        let suite = "atria.idle-skip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let failures = [
            AtriaHistoricalShadowCompactionCoordinator.Failure(
                chunkID: "dup",
                message: "duplicateIdentity"
            ),
            AtriaHistoricalShadowCompactionCoordinator.Failure(
                chunkID: "transient",
                message: "sourceMissing"
            )
        ]
        AtriaHistoricalShadowCompactionCoordinator.recordPermanentIdleCutoverSkips(
            failures,
            defaults: defaults
        )
        XCTAssertEqual(
            AtriaHistoricalShadowCompactionCoordinator.idleCutoverSkipChunkIDs(
                defaults: defaults
            ),
            Set(["dup"])
        )
        XCTAssertTrue(
            AtriaHistoricalShadowCompactionCoordinator
                .isPermanentIdleCutoverSkipMessage("duplicateIdentity")
        )
        XCTAssertFalse(
            AtriaHistoricalShadowCompactionCoordinator
                .isPermanentIdleCutoverSkipMessage("sourceMissing")
        )
    }

    func testIdleRetirementSkipsDuplicateIdentityCutoverPoison() {
        let poison = chunk(id: "dup-identity", createdAt: now.addingTimeInterval(-200))
        let valid = chunk(id: "valid-4mb", createdAt: now.addingTimeInterval(-100))
        let selected = AtriaHistoricalShadowCompactionCoordinator
            .skippingIdleCutoverSkips(
                [poison, valid],
                skippedIDs: ["dup-identity"]
            )
        XCTAssertEqual(selected.map(\.id), [valid.id])
        XCTAssertTrue(
            AtriaHistoricalShadowCompactionCoordinator.isPermanentIdleCutoverSkip(
                AtriaHistoricalReplayIdentityShard.ShardError.duplicateIdentity
            )
        )
        XCTAssertFalse(
            AtriaHistoricalShadowCompactionCoordinator.isPermanentIdleCutoverSkip(
                AtriaHistoricalReplayIdentityShard.ShardError.sourceMissing
            )
        )
    }

    func testAllFailuresRemainExplicitInsteadOfBecomingNoop() {
        let first = chunk(id: "first", createdAt: now.addingTimeInterval(-200))
        let second = chunk(id: "second", createdAt: now.addingTimeInterval(-100))
        enum FixtureError: Error { case invalid }

        let outcome: AtriaHistoricalShadowCompactionCoordinator.Outcome<String> =
            AtriaHistoricalShadowCompactionCoordinator.commitFirst(candidates: [first, second]) { _ in
                throw FixtureError.invalid
            }

        guard case let .allFailed(failures) = outcome else {
            return XCTFail("all malformed chunks must report a deferred failure")
        }
        XCTAssertEqual(failures.map(\.chunkID), [first.id, second.id])
    }

    func testEligibilityUsesValidatedCommittedIDsNotManifestExistenceAndOrdersOldestFirst() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalShadowCompactionCoordinatorTests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let newer = chunk(id: "newer", createdAt: now.addingTimeInterval(-100))
        let older = chunk(id: "older", createdAt: now.addingTimeInterval(-300))
        let accepted = chunk(id: "accepted", createdAt: now.addingTimeInterval(-400))
        let active = activeChunk(id: "active", createdAt: now.addingTimeInterval(-500))
        for value in [newer, older, accepted] {
            let url = directory.appendingPathComponent(value.relativePath)
            try Data("raw\n".utf8).write(to: url)
        }
        let catalog = AtriaHistoricalArchiveCatalog(version: AtriaHistoricalArchiveCatalog.currentVersion,
                                                     generation: 1,
                                                     activeChunkID: active.id,
                                                     chunks: [newer, active, accepted, older])

        let eligible = AtriaHistoricalShadowCompactionCoordinator.orderedEligibleChunks(
            catalog: catalog,
            archiveDirectory: directory,
            committedChunkIDs: [accepted.id]
        )

        XCTAssertEqual(eligible.map(\.id), [older.id, newer.id])
    }

    func testNoCandidatesIsDistinctFromAllFailed() {
        let outcome: AtriaHistoricalShadowCompactionCoordinator.Outcome<String> =
            AtriaHistoricalShadowCompactionCoordinator.commitFirst(candidates: []) { _ in
                XCTFail("empty queue must not attempt a commit")
                return "unexpected"
            }
        guard case .noCandidates = outcome else {
            return XCTFail("empty queue must be a noop")
        }
    }

    func testProductionQueueInvokesAgeAndBytePolicyButOnlySchedulesShadowWork() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalRetentionQueueTests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let expired = boundedChunk(id: "expired",
                                   first: now.addingTimeInterval(-20 * 86_400),
                                   last: now.addingTimeInterval(-19 * 86_400),
                                   bytes: 60)
        let recent = boundedChunk(id: "recent",
                                  first: now.addingTimeInterval(-2 * 86_400),
                                  last: now.addingTimeInterval(-86_400),
                                  bytes: 60)
        let active = activeChunk(id: "active", createdAt: now.addingTimeInterval(-100))
        for chunk in [expired, recent] {
            try Data("raw\n".utf8).write(to: directory.appendingPathComponent(chunk.relativePath))
        }
        let catalog = AtriaHistoricalArchiveCatalog(
            version: AtriaHistoricalArchiveCatalog.currentVersion,
            generation: 1,
            activeChunkID: active.id,
            chunks: [recent, active, expired]
        )

        let queue = AtriaHistoricalShadowCompactionCoordinator.retentionQueue(
            catalog: catalog,
            archiveDirectory: directory,
            committedChunkIDs: [],
            policy: .init(rawHorizon: 14 * 86_400, maximumRawBytes: 100),
            now: now
        )

        XCTAssertEqual(queue.plan.rawBytesBefore, 120)
        XCTAssertEqual(queue.plan.candidates.map(\.chunk.identifier), [expired.id])
        XCTAssertEqual(queue.plan.candidates.map(\.reason), [.outsideRawHorizon])
        XCTAssertEqual(queue.uncommittedCandidates.map(\.id), [expired.id])
        XCTAssertTrue(queue.shadowCommittedCandidateIDs.isEmpty)
        XCTAssertTrue(queue.missingSourceCandidateIDs.isEmpty)
        XCTAssertFalse(queue.uncommittedCandidates.contains(where: { $0.state == .active }))
    }

    func testCommittedShadowCandidateRemainsExplicitlyBlockedFromRawRetirement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalRetentionQueueTests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Age derived from the LIVE horizon, not a hardcoded 30 days. When the
        // raw horizon moved 14 -> 30 days (df11d6c5, 2026-08-19) this fixture
        // landed exactly ON the boundary, the queue selected nothing, and two
        // assertions below started passing vacuously against an empty queue
        // while the other two failed. Deriving the age keeps the chunk outside
        // whatever the horizon currently is, so a future retune cannot hollow
        // this test out again.
        let legacy = chunk(
            id: "legacy",
            createdAt: now.addingTimeInterval(
                -AtriaHistoricalRetentionPolicy.production.rawHorizon - 86_400
            )
        )
        let active = activeChunk(id: "active", createdAt: now)
        let sourceURL = directory.appendingPathComponent(legacy.relativePath)
        try Data("raw\n".utf8).write(to: sourceURL)
        let catalog = AtriaHistoricalArchiveCatalog(
            version: AtriaHistoricalArchiveCatalog.currentVersion,
            generation: 1,
            activeChunkID: active.id,
            chunks: [legacy, active]
        )

        let queue = AtriaHistoricalShadowCompactionCoordinator.retentionQueue(
            catalog: catalog,
            archiveDirectory: directory,
            committedChunkIDs: [legacy.id],
            policy: .production,
            now: now
        )

        XCTAssertTrue(queue.uncommittedCandidates.isEmpty)
        XCTAssertEqual(queue.shadowCommittedCandidateIDs, [legacy.id])
        XCTAssertEqual(queue.provisionalTimestampCandidateIDs, [legacy.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path),
                      "selection and an existing shadow aggregate must never remove raw")
    }

    func testMissingOldestLegacyFileDoesNotHideLaterShadowCommittedCandidate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalMissingSourceQueueTests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let missing = chunk(
            id: "legacy-monolith",
            createdAt: now.addingTimeInterval(
                -AtriaHistoricalRetentionPolicy.production.rawHorizon - 2 * 86_400
            )
        )
        var missingHuge = missing
        missingHuge.byteCount = 134_218_092
        let later = chunk(
            id: "verified-later",
            createdAt: now.addingTimeInterval(
                -AtriaHistoricalRetentionPolicy.production.rawHorizon - 86_400
            )
        )
        try Data("raw\n".utf8).write(
            to: directory.appendingPathComponent(later.relativePath)
        )
        let active = activeChunk(id: "active", createdAt: now)
        let catalog = AtriaHistoricalArchiveCatalog(
            version: AtriaHistoricalArchiveCatalog.currentVersion,
            generation: 1,
            activeChunkID: active.id,
            chunks: [missingHuge, later, active]
        )

        let queue = AtriaHistoricalShadowCompactionCoordinator.retentionQueue(
            catalog: catalog,
            archiveDirectory: directory,
            committedChunkIDs: [later.id],
            policy: .production,
            now: now
        )

        XCTAssertEqual(queue.missingSourceCandidateIDs, [missingHuge.id])
        XCTAssertEqual(queue.shadowCommittedCandidateIDs, [later.id])
        XCTAssertTrue(queue.uncommittedCandidates.isEmpty)
    }

    func testAggregateCapCandidateIsExecutedEvenWhenRawPolicyIsWithinBounds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalAggregateRetentionQueueTests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sealed = boundedChunk(id: "aggregate-cap-oldest",
                                  first: now.addingTimeInterval(-2 * 86_400),
                                  last: now.addingTimeInterval(-86_400),
                                  bytes: 60)
        let active = activeChunk(id: "active", createdAt: now)
        try Data("raw\n".utf8).write(to: directory.appendingPathComponent(sealed.relativePath))
        let catalog = AtriaHistoricalArchiveCatalog(
            version: AtriaHistoricalArchiveCatalog.currentVersion,
            generation: 1,
            activeChunkID: active.id,
            chunks: [active, sealed]
        )

        let queue = AtriaHistoricalShadowCompactionCoordinator.retentionQueue(
            catalog: catalog,
            archiveDirectory: directory,
            committedChunkIDs: [],
            additionalCandidateIDs: [sealed.id],
            policy: .init(rawHorizon: 14 * 86_400, maximumRawBytes: 100),
            now: now
        )

        XCTAssertTrue(queue.plan.candidates.isEmpty,
                      "the raw-only policy deliberately remains within bounds")
        XCTAssertEqual(queue.uncommittedCandidates.map(\.id), [sealed.id],
                       "the combined raw+replay planner must feed production execution")
    }

    private func chunk(id: String,
                       createdAt: Date) -> AtriaHistoricalArchiveCatalog.RawChunk {
        .init(id: id,
              relativePath: "\(id).jsonl",
              createdAt: createdAt,
              sealedAt: createdAt.addingTimeInterval(60),
              byteCount: 4,
              rowCount: nil,
              firstTimestamp: nil,
              lastTimestamp: nil,
              contentSHA256: nil,
              state: .sealed,
              retirementManifestRelativePath: nil)
    }

    private func activeChunk(id: String,
                             createdAt: Date) -> AtriaHistoricalArchiveCatalog.RawChunk {
        .init(id: id,
              relativePath: "\(id).jsonl",
              createdAt: createdAt,
              sealedAt: nil,
              byteCount: 0,
              rowCount: nil,
              firstTimestamp: nil,
              lastTimestamp: nil,
              contentSHA256: nil,
              state: .active,
              retirementManifestRelativePath: nil)
    }

    private func boundedChunk(id: String,
                              first: Date,
                              last: Date,
                              bytes: UInt64) -> AtriaHistoricalArchiveCatalog.RawChunk {
        .init(id: id,
              relativePath: "\(id).jsonl",
              createdAt: first,
              sealedAt: last,
              byteCount: bytes,
              rowCount: 1,
              firstTimestamp: first,
              lastTimestamp: last,
              contentSHA256: String(repeating: "a", count: 64),
              state: .sealed,
              retirementManifestRelativePath: nil)
    }
}
