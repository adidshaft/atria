import XCTest
@testable import Atria

final class AtriaHistoricalGeneratedArtifactGCTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testPrunesOnlyUnreachableTypedGenerationsAndPreservesSharedArtifacts() throws {
        let root = try makeRoot()
        let receipts = try directory(root, "consumer-receipts-v1")
        let destinations = try directory(root, "canonical-consumers-v1/destinations")
        let proofs = try directory(root, "canonical-consumers-v1/application-proofs")
        let a = String(repeating: "a", count: 64)
        let b = String(repeating: "b", count: 64)
        let c = String(repeating: "c", count: 64)

        let liveArtifact = "consumer-artifact-sleep-\(a).bin"
        let staleArtifact = "consumer-artifact-sleep-\(b).bin"
        try Data("live".utf8).write(to: receipts.appendingPathComponent(liveArtifact))
        try Data("stale".utf8).write(to: receipts.appendingPathComponent(staleArtifact))
        let liveReceipt = "consumer-receipt-sleep-\(a)-\(b).json"
        let staleReceipt = "consumer-receipt-sleep-\(b)-\(c).json"
        try json(["artifactFilename": liveArtifact],
                 to: receipts.appendingPathComponent(liveReceipt))
        try json(["artifactFilename": staleArtifact],
                 to: receipts.appendingPathComponent(staleReceipt))
        let liveSet = "consumer-set-\(a)-\(b).json"
        let staleSet = "consumer-set-\(b)-\(c).json"
        try json(["entries": [["receiptFilename": liveReceipt]]],
                 to: receipts.appendingPathComponent(liveSet))
        try json(["entries": [["receiptFilename": staleReceipt]]],
                 to: receipts.appendingPathComponent(staleSet))
        try json(["setFilename": liveSet],
                 to: receipts.appendingPathComponent("consumer-set-current-\(a).json"))

        let liveSnapshot = "canonical-sleep-\(String(a.prefix(20)))-\(a).json"
        let staleSnapshot = "canonical-sleep-\(String(b.prefix(20)))-\(b).json"
        try Data("live".utf8).write(to: destinations.appendingPathComponent(liveSnapshot))
        try Data("stale".utf8).write(to: destinations.appendingPathComponent(staleSnapshot))
        try json(["snapshotFilename": liveSnapshot],
                 to: destinations.appendingPathComponent("canonical-sleep-current-\(a).json"))

        let liveProof = "canonical-consumer-set-\(a)-\(b).json"
        let staleProof = "canonical-consumer-set-\(b)-\(c).json"
        try Data("live".utf8).write(to: proofs.appendingPathComponent(liveProof))
        try Data("stale".utf8).write(to: proofs.appendingPathComponent(staleProof))
        try json(["setFilename": liveProof],
                 to: proofs.appendingPathComponent("canonical-consumer-current-\(a).json"))

        let replay = receipts.appendingPathComponent(
            "consumer-artifact-replayIdentity-\(c).bin"
        )
        let unknown = destinations.appendingPathComponent("owner-evidence.bin")
        try Data("replay".utf8).write(to: replay)
        try Data("owner".utf8).write(to: unknown)

        let old = Date(timeIntervalSince1970: 1_900_000_000)
        for url in [
            receipts.appendingPathComponent(staleArtifact),
            receipts.appendingPathComponent(staleReceipt),
            receipts.appendingPathComponent(staleSet),
            destinations.appendingPathComponent(staleSnapshot),
            proofs.appendingPathComponent(staleProof),
        ] {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                  ofItemAtPath: url.path)
        }

        let result = try AtriaHistoricalGeneratedArtifactGC(
            archiveRoot: root,
            now: Date(timeIntervalSince1970: 2_000_000_000)
        ).prune()

        XCTAssertEqual(result.removedFiles, 5)
        for name in [liveArtifact, liveReceipt, liveSet, "consumer-set-current-\(a).json"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: receipts.appendingPathComponent(name).path
            ))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: replay.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleArtifact.path(in: receipts)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleReceipt.path(in: receipts)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleSet.path(in: receipts)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinations
            .appendingPathComponent(staleSnapshot).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proofs
            .appendingPathComponent(staleProof).path))
    }

    func testCorruptCurrentPointerFailsClosedBeforeAnyDeletion() throws {
        let root = try makeRoot()
        let receipts = try directory(root, "consumer-receipts-v1")
        let digest = String(repeating: "d", count: 64)
        let orphan = receipts.appendingPathComponent(
            "consumer-artifact-sleep-\(digest).bin"
        )
        try Data("orphan".utf8).write(to: orphan)
        try Data("not-json".utf8).write(to: receipts.appendingPathComponent(
            "consumer-set-current-\(digest).json"
        ))

        XCTAssertThrowsError(try AtriaHistoricalGeneratedArtifactGC(
            archiveRoot: root
        ).prune())
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testRecentUnreachableGenerationIsQuarantinedForConcurrentPublication() throws {
        let root = try makeRoot()
        let receipts = try directory(root, "consumer-receipts-v1")
        let digest = String(repeating: "f", count: 64)
        let unpublished = receipts.appendingPathComponent(
            "consumer-artifact-sleep-\(digest).bin"
        )
        try Data("publication-in-flight".utf8).write(to: unpublished)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now],
                                              ofItemAtPath: unpublished.path)

        let result = try AtriaHistoricalGeneratedArtifactGC(
            archiveRoot: root,
            now: now.addingTimeInterval(
                AtriaHistoricalGeneratedArtifactGC.unreachableGenerationQuarantine - 1
            )
        ).prune()

        XCTAssertEqual(result.removedFiles, 0)
        XCTAssertEqual(result.avoidableBytesBefore, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpublished.path))
    }

    func testPrunesCrashLeftAggregateTemporariesAfterOneHourOnly() throws {
        let root = try makeRoot()
        let aggregates = try directory(root, "aggregates-v2")
        let manifests = try directory(root, "retention-manifests-v2")
        let oldAggregate = aggregates.appendingPathComponent(
            ".aggregate-legacy-source.json.\(UUID().uuidString).tmp"
        )
        let recentAggregate = aggregates.appendingPathComponent(
            ".aggregate-current-source.json.\(UUID().uuidString).tmp"
        )
        let oldManifest = manifests.appendingPathComponent(
            ".manifest-legacy-source.json.\(UUID().uuidString).tmp"
        )
        let committed = aggregates.appendingPathComponent("aggregate-legacy-source.json")
        let unknown = aggregates.appendingPathComponent(
            ".unrelated.json.\(UUID().uuidString).tmp"
        )
        for url in [oldAggregate, recentAggregate, oldManifest, committed, unknown] {
            try Data(repeating: 0x41, count: 32).write(to: url)
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(
            -AtriaHistoricalGeneratedArtifactGC.abandonedTemporaryQuarantine - 1
        )
        for url in [oldAggregate, oldManifest, committed, unknown] {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                  ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([
            .modificationDate: now.addingTimeInterval(
                -AtriaHistoricalGeneratedArtifactGC.abandonedTemporaryQuarantine + 1
            ),
        ], ofItemAtPath: recentAggregate.path)

        let result = try AtriaHistoricalGeneratedArtifactGC(
            archiveRoot: root,
            now: now
        ).prune()

        XCTAssertEqual(result.removedFiles, 2)
        XCTAssertEqual(result.removedBytes, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAggregate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentAggregate.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    }

    func testSeparateAvoidableGenerationCeilingIsMeasuredAndReclaimed() throws {
        let root = try makeRoot()
        let receipts = try directory(root, "consumer-receipts-v1")
        let digest = String(repeating: "e", count: 64)
        let orphan = receipts.appendingPathComponent(
            "consumer-artifact-sleep-\(digest).bin"
        )
        FileManager.default.createFile(atPath: orphan.path, contents: nil)
        let handle = try FileHandle(forWritingTo: orphan)
        try handle.truncate(atOffset:
            AtriaHistoricalGeneratedArtifactGC.productionMaximumAvoidableBytes + 1)
        try handle.close()
        let collectionTime = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes([
            .modificationDate: collectionTime.addingTimeInterval(
                -AtriaHistoricalGeneratedArtifactGC.unreachableGenerationQuarantine - 1
            ),
        ], ofItemAtPath: orphan.path)

        let result = try AtriaHistoricalGeneratedArtifactGC(
            archiveRoot: root,
            now: collectionTime
        ).prune()
        XCTAssertGreaterThan(result.avoidableBytesBefore,
                             AtriaHistoricalGeneratedArtifactGC
                                .productionMaximumAvoidableBytes)
        XCTAssertEqual(result.avoidableBytesAfter, 0)
        XCTAssertTrue(result.limitSatisfied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalGeneratedArtifactGCTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func directory(_ root: URL, _ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func json(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url)
    }
}

private extension String {
    func path(in directory: URL) -> String {
        directory.appendingPathComponent(self).path
    }
}
