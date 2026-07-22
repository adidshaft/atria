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

        let legacy = chunk(id: "legacy", createdAt: now.addingTimeInterval(-30 * 86_400))
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
