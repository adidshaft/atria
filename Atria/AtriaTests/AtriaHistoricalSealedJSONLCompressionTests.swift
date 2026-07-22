import XCTest
@testable import Atria

final class AtriaHistoricalSealedJSONLCompressionTests: XCTestCase {
    private enum InjectedCrash: Error { case stop }

    func testStreamingRoundTripPreservesExactBytesRowsAndScannerResults() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.source)

        let result = try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: "sealed-one",
            sourceURL: fixture.source,
            archiveRootURL: fixture.root,
            activeSourceURL: fixture.active,
            chunkSize: 97
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(result.sourceDeleted)
        XCTAssertEqual(result.manifest.decodedByteCount, UInt64(original.count))
        XCTAssertEqual(result.manifest.decodedRowCount, 3)
        XCTAssertLessThan(result.manifest.compressedByteCount, result.manifest.decodedByteCount)

        var decoded = Data()
        var maximumChunk = 0
        try AtriaHistoricalJSONLInput.forEachChunk(at: result.artifactURL, chunkSize: 113) { chunk in
            maximumChunk = max(maximumChunk, chunk.count)
            decoded.append(chunk)
        }
        XCTAssertEqual(decoded, original)
        XCTAssertLessThanOrEqual(maximumChunk, 113)

        let plainRows = scan(fixture.source)
        let compressedRows = scan(result.artifactURL)
        XCTAssertTrue(plainRows.complete)
        XCTAssertTrue(compressedRows.complete)
        XCTAssertEqual(plainRows.timestamps, compressedRows.timestamps)
        XCTAssertEqual(plainRows.lineCount, compressedRows.lineCount)
    }

    func testActiveSourceIsNeverCompressed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertThrowsError(try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: "active",
            sourceURL: fixture.active,
            archiveRootURL: fixture.root,
            activeSourceURL: fixture.active
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalSealedJSONLCompression.TransactionError,
                           .activeSource)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.active), Data("{}\n".utf8))
    }

    func testHardLinkAliasOfActiveSourceIsNeverCompressed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.active.deletingLastPathComponent()
            .appendingPathComponent("sealed-alias.jsonl")
        try FileManager.default.linkItem(at: fixture.active, to: alias)
        XCTAssertThrowsError(try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: "active-alias",
            sourceURL: alias,
            archiveRootURL: fixture.root,
            activeSourceURL: fixture.active
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalSealedJSONLCompression.TransactionError,
                           .activeSource)
        }
    }

    func testDeletionFailsClosedWithoutDurableStoragePublication() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertThrowsError(try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: "sealed-denied",
            sourceURL: fixture.source,
            archiveRootURL: fixture.root,
            activeSourceURL: fixture.active,
            deleteSourceAfterCommit: true
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalSealedJSONLCompression.TransactionError,
                           .deletionNotAuthorized)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testAuthorizedDeletionRechecksSourceAndCommittedArtifactAndIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transaction = AtriaHistoricalSealedJSONLCompression(
            storagePublicationVerifier: { manifest, artifact, manifestURL in
                manifest.artifactRelativePath.hasSuffix(artifact.lastPathComponent)
                    && FileManager.default.fileExists(atPath: manifestURL.path)
            }
        )
        let first = try transaction.commit(chunkID: "sealed-delete",
                                           sourceURL: fixture.source,
                                           archiveRootURL: fixture.root,
                                           activeSourceURL: fixture.active,
                                           deleteSourceAfterCommit: true,
                                           chunkSize: 101)
        XCTAssertTrue(first.sourceDeleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))

        let retry = try transaction.commit(chunkID: "sealed-delete",
                                           sourceURL: fixture.source,
                                           archiveRootURL: fixture.root,
                                           activeSourceURL: fixture.active,
                                           deleteSourceAfterCommit: true,
                                           chunkSize: 89)
        XCTAssertTrue(retry.reusedCommittedArtifact)
        XCTAssertTrue(retry.sourceDeleted)
        XCTAssertEqual(retry.manifest, first.manifest)
    }

    func testSourceMutationAfterPublicationBlocksDeletion() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: "sealed-mutated",
            sourceURL: fixture.source,
            archiveRootURL: fixture.root,
            activeSourceURL: fixture.active
        )
        let handle = try FileHandle(forWritingTo: fixture.source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        let authorized = AtriaHistoricalSealedJSONLCompression(
            storagePublicationVerifier: { _, _, _ in true }
        )
        XCTAssertThrowsError(try authorized.commit(
            chunkID: "sealed-mutated",
            sourceURL: fixture.source,
            archiveRootURL: fixture.root,
            activeSourceURL: fixture.active,
            deleteSourceAfterCommit: true
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalSealedJSONLCompression.TransactionError,
                           .sourceChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testCrashAfterArtifactPublishLeavesSourceAndRetryCommitsManifest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let crashing = AtriaHistoricalSealedJSONLCompression(checkpoint: { checkpoint in
            if checkpoint == .artifactPublished { throw InjectedCrash.stop }
        })
        XCTAssertThrowsError(try crashing.commit(chunkID: "sealed-crash",
                                                 sourceURL: fixture.source,
                                                 archiveRootURL: fixture.root,
                                                 activeSourceURL: fixture.active))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))

        let completed = try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: "sealed-crash",
            sourceURL: fixture.source,
            archiveRootURL: fixture.root,
            activeSourceURL: fixture.active
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testCorruptAndTrailingCompressedContentFailClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: "sealed-corrupt",
            sourceURL: fixture.source,
            archiveRootURL: fixture.root,
            activeSourceURL: fixture.active
        )
        let handle = try FileHandle(forWritingTo: result.artifactURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xde, 0xad]))
        try handle.close()

        XCTAssertThrowsError(try AtriaHistoricalSealedJSONLCompression.verifyCompressed(
            at: result.artifactURL,
            chunkSize: 31
        ))
        let scanned = scan(result.artifactURL)
        XCTAssertFalse(scanned.complete)
    }

    private func scan(_ url: URL) -> (complete: Bool, timestamps: [TimeInterval], lineCount: Int) {
        guard let descriptor = AtriaHistoricalJSONLRecentScanner.descriptors(for: [url]).first else {
            return (false, [], 0)
        }
        var timestamps: [TimeInterval] = []
        let result = AtriaHistoricalJSONLRecentScanner.scan(
            sources: [.init(descriptor: descriptor, startOffset: 0)],
            cutoff: 0,
            chunkSize: 127
        ) { line in
            if let timestamp = AtriaHistoricalJSONLRecentScanner.timestamp(in: line) {
                timestamps.append(timestamp)
            }
        }
        return (result.complete, timestamps, result.statistics.lineCount)
    }

    private func makeFixture() throws -> (root: URL, source: URL, active: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-compression-\(UUID().uuidString)", isDirectory: true)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        let source = segments.appendingPathComponent("sealed.jsonl")
        let active = segments.appendingPathComponent("active.jsonl")
        let largePadding = String(repeating: "a", count: 80 * 1024)
        let rows = [
            "{\"clockCorrectedUnix7\":1,\"subsec11\":0,\"padding\":\"\(largePadding)\"}\n",
            "{\"clockCorrectedUnix7\":2,\"subsec11\":16384}\n",
            "{\"unix7\":3,\"subsec11\":0}\n",
        ].joined()
        try Data(rows.utf8).write(to: source)
        try Data("{}\n".utf8).write(to: active)
        return (root, source, active)
    }
}
