import XCTest
@testable import Atria

/// Handoff-8 CP1: the per-chunk HR sidecar index and the exact-window result
/// cache. The sidecar is an accelerator bound to exact catalog identity —
/// every test here proves either "same truth, fewer bytes" or "mismatch fails
/// closed to the raw scan".
final class AtriaHeartRateWindowIndexTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUp() {
        super.setUp()
        HistoricalArchive.HeartRateWindowResultCache.removeAll()
    }

    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories.removeAll()
        HistoricalArchive.HeartRateWindowResultCache.removeAll()
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let sealedURL: URL
        let activeURL: URL
        let sealedChunk: AtriaHistoricalArchiveCatalog.RawChunk
        let catalog: AtriaHistoricalArchiveCatalog
        let windowStart: Date
        let windowEnd: Date
        let sealedBPMs: [Int]
        let activeBPMs: [Int]
        var candidates: [URL] { [sealedURL, activeURL] }
    }

    /// One sealed, digested chunk (20 rows) plus one active chunk (5 rows),
    /// both inside the requested window.
    private func makeFixture() throws -> Fixture {
        let root = try temporaryDirectory()
        let rawRoot = root.appendingPathComponent("segments/raw-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: rawRoot,
                                                withIntermediateDirectories: true)
        let sealedURL = rawRoot.appendingPathComponent("sealed.jsonl")
        let activeURL = rawRoot.appendingPathComponent("active.jsonl")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let sealedRows = (0..<20).map {
            metricHeartRateLine(unix: Int(base.timeIntervalSince1970) + $0, bpm: 100 + $0)
        }
        let activeRows = (0..<5).map {
            metricHeartRateLine(unix: Int(base.timeIntervalSince1970) + 40 + $0, bpm: 70 + $0)
        }
        try Data((sealedRows.joined(separator: "\n") + "\n").utf8).write(to: sealedURL)
        try Data((activeRows.joined(separator: "\n") + "\n").utf8).write(to: activeURL)
        let sealedChunk = AtriaHistoricalArchiveCatalog.RawChunk(
            id: "sealed",
            relativePath: relative(sealedURL, root: root),
            createdAt: base,
            sealedAt: base.addingTimeInterval(30),
            byteCount: try fileBytes(sealedURL),
            rowCount: sealedRows.count,
            firstTimestamp: base,
            lastTimestamp: base.addingTimeInterval(19),
            contentSHA256: String(repeating: "a", count: 64),
            state: .sealed,
            retirementManifestRelativePath: nil
        )
        let activeChunk = AtriaHistoricalArchiveCatalog.RawChunk(
            id: "active",
            relativePath: relative(activeURL, root: root),
            createdAt: base,
            sealedAt: nil,
            byteCount: 0,
            rowCount: nil,
            firstTimestamp: nil,
            lastTimestamp: nil,
            contentSHA256: nil,
            state: .active,
            retirementManifestRelativePath: nil
        )
        let catalog = AtriaHistoricalArchiveCatalog(
            version: AtriaHistoricalArchiveCatalog.currentVersion,
            generation: 7,
            activeChunkID: "active",
            chunks: [sealedChunk, activeChunk]
        )
        return Fixture(root: root,
                       sealedURL: sealedURL,
                       activeURL: activeURL,
                       sealedChunk: sealedChunk,
                       catalog: catalog,
                       windowStart: base,
                       windowEnd: base.addingTimeInterval(60),
                       sealedBPMs: Array(100..<120),
                       activeBPMs: Array(70..<75))
    }

    private func read(_ fixture: Fixture,
                      start: Date? = nil,
                      end: Date? = nil,
                      maximumPoints: Int = 200)
        -> (read: HistoricalArchive.HeartRateWindowRead?,
            diagnostics: HistoricalArchive.HeartRateWindowReadDiagnostics) {
        var diagnostics = HistoricalArchive.HeartRateWindowReadDiagnostics(
            startUnix: 0, endUnix: 0, elapsedMilliseconds: 0,
            candidateFileCount: 0, trustedOutsideWindowSkipped: 0,
            selectedFileCount: 0, scannedFileCount: 0, scannedByteCount: 0,
            scannedLineCount: 0, heartRateCandidateLineCount: 0,
            inWindowPointCount: 0, catalogGeneration: 0, catalogChunkCount: 0,
            terminal: "unset"
        )
        let result = HistoricalArchive.exactMetricHeartRatePoints(
            in: fixture.candidates,
            catalog: fixture.catalog,
            archiveRoot: fixture.root,
            start: start ?? fixture.windowStart,
            end: end ?? fixture.windowEnd,
            maximumPoints: maximumPoints,
            diagnostics: &diagnostics
        )
        return (result, diagnostics)
    }

    private func sidecarURL(_ fixture: Fixture) -> URL {
        HistoricalArchive.heartRateSidecarURL(
            forChunkRelativePath: fixture.sealedChunk.relativePath,
            archiveRoot: fixture.root
        )
    }

    // MARK: - Same truth, fewer bytes

    func testFirstReadBuildsSidecarAndSecondReadSkipsSealedRawBytes() throws {
        let fixture = try makeFixture()
        let expectedBPMs = fixture.sealedBPMs + fixture.activeBPMs

        let first = read(fixture)
        let firstRead = try XCTUnwrap(first.read)
        XCTAssertEqual(firstRead.points.map(\.bpm), expectedBPMs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL(fixture).path),
                      "First touch of a sealed digested chunk must leave a sidecar behind")
        XCTAssertEqual(first.diagnostics.scannedFileCount, 2)

        let second = read(fixture)
        let secondRead = try XCTUnwrap(second.read)
        XCTAssertEqual(secondRead.points.map(\.bpm), firstRead.points.map(\.bpm))
        XCTAssertEqual(secondRead.points.map(\.t), firstRead.points.map(\.t))
        // Bounded visits: only the active file pays raw bytes on repeat reads.
        let activeBytes = Int(try fileBytes(fixture.activeURL))
        XCTAssertEqual(second.diagnostics.scannedFileCount, 1)
        XCTAssertEqual(second.diagnostics.scannedByteCount, activeBytes,
                       "Repeat navigation must not rescan unchanged sealed raw bytes")
        XCTAssertLessThan(second.diagnostics.scannedByteCount,
                          first.diagnostics.scannedByteCount)
    }

    func testSidecarAndRawFallbackReturnByteEquivalentResultsIncludingEmptyTruth() throws {
        let fixture = try makeFixture()
        _ = read(fixture) // builds the sidecar

        let viaSidecar = try XCTUnwrap(read(fixture).read)
        try FileManager.default.removeItem(
            at: HistoricalArchive.heartRateSidecarDirectory(archiveRoot: fixture.root)
        )
        let viaRaw = try XCTUnwrap(read(fixture).read)
        XCTAssertEqual(viaSidecar.points.map(\.t), viaRaw.points.map(\.t))
        XCTAssertEqual(viaSidecar.points.map(\.bpm), viaRaw.points.map(\.bpm))
        XCTAssertFalse(viaSidecar.points.isEmpty)

        // Identical empty truth for a gap window both paths agree contains
        // nothing: non-nil (proven) and empty. Any raw read of a sealed chunk
        // rebuilds the sidecar, so delete again to force the raw path first.
        let gapStart = fixture.windowStart.addingTimeInterval(25)
        let gapEnd = fixture.windowStart.addingTimeInterval(35)
        try FileManager.default.removeItem(
            at: HistoricalArchive.heartRateSidecarDirectory(archiveRoot: fixture.root)
        )
        let rawEmpty = try XCTUnwrap(
            read(fixture, start: gapStart, end: gapEnd).read
        )
        let sidecarEmpty = try XCTUnwrap(
            read(fixture, start: gapStart, end: gapEnd).read
        )
        XCTAssertTrue(rawEmpty.points.isEmpty)
        XCTAssertTrue(sidecarEmpty.points.isEmpty)
    }

    func testOverflowStaysFailClosedNilOnBothPaths() throws {
        let fixture = try makeFixture()
        XCTAssertNil(read(fixture, maximumPoints: 3).read,
                     "Raw path overflow must return nil, never a silent truncation")
        _ = read(fixture) // build sidecar
        XCTAssertNil(read(fixture, maximumPoints: 3).read,
                     "Sidecar path overflow must return nil, never a silent truncation")
    }

    // MARK: - Binding fails closed

    func testSidecarBindingRejectsEveryIdentityMismatch() throws {
        let fixture = try makeFixture()
        _ = read(fixture) // writes a valid sidecar
        let url = sidecarURL(fixture)
        let chunk = fixture.sealedChunk
        XCTAssertNotNil(HistoricalArchive.validHeartRateSidecarBinding(
            sidecarURL: url, chunk: chunk
        ))

        func variant(byteCount: UInt64? = nil,
                     digest: String? = nil,
                     relativePath: String? = nil,
                     state: AtriaHistoricalArchiveCatalog.RawChunk.State = .sealed)
            -> AtriaHistoricalArchiveCatalog.RawChunk {
            .init(id: chunk.id,
                  relativePath: relativePath ?? chunk.relativePath,
                  createdAt: chunk.createdAt,
                  sealedAt: chunk.sealedAt,
                  byteCount: byteCount ?? chunk.byteCount,
                  rowCount: chunk.rowCount,
                  firstTimestamp: chunk.firstTimestamp,
                  lastTimestamp: chunk.lastTimestamp,
                  contentSHA256: digest ?? chunk.contentSHA256,
                  state: state,
                  retirementManifestRelativePath: nil)
        }

        XCTAssertNil(HistoricalArchive.validHeartRateSidecarBinding(
            sidecarURL: url, chunk: variant(byteCount: chunk.byteCount + 1)
        ), "A grown source file must invalidate the sidecar")
        XCTAssertNil(HistoricalArchive.validHeartRateSidecarBinding(
            sidecarURL: url, chunk: variant(digest: String(repeating: "b", count: 64))
        ), "A different content digest must invalidate the sidecar")
        XCTAssertNil(HistoricalArchive.validHeartRateSidecarBinding(
            sidecarURL: url, chunk: variant(relativePath: "segments/raw-v2/other.jsonl")
        ), "A different chunk path must invalidate the sidecar")
        XCTAssertNil(HistoricalArchive.validHeartRateSidecarBinding(
            sidecarURL: url, chunk: variant(state: .active)
        ), "An active chunk can still grow; its sidecar is never trusted")
        XCTAssertNil(HistoricalArchive.validHeartRateSidecarBinding(
            sidecarURL: url.deletingLastPathComponent()
                .appendingPathComponent("missing.hr.v1.jsonl"),
            chunk: chunk
        ))

        // Truncated / garbage header fails closed.
        try Data("not-json".utf8).write(to: url)
        XCTAssertNil(HistoricalArchive.validHeartRateSidecarBinding(
            sidecarURL: url, chunk: chunk
        ))
        try Data("{\"version\":1}".utf8).write(to: url) // no newline, wrong shape
        XCTAssertNil(HistoricalArchive.validHeartRateSidecarBinding(
            sidecarURL: url, chunk: chunk
        ))
    }

    func testStaleSidecarFromPreviousChunkContentIsIgnoredAndRepaired() throws {
        let fixture = try makeFixture()
        _ = read(fixture) // valid sidecar for current content

        // The chunk is re-sealed with different content (e.g. compaction):
        // catalog identity changes, the old sidecar must not answer for it.
        let extraRow = metricHeartRateLine(
            unix: Int(fixture.windowStart.timeIntervalSince1970) + 20, bpm: 155
        )
        let existing = try String(contentsOf: fixture.sealedURL, encoding: .utf8)
        try Data((existing + extraRow + "\n").utf8).write(to: fixture.sealedURL)
        let resealed = AtriaHistoricalArchiveCatalog.RawChunk(
            id: fixture.sealedChunk.id,
            relativePath: fixture.sealedChunk.relativePath,
            createdAt: fixture.sealedChunk.createdAt,
            sealedAt: fixture.sealedChunk.sealedAt,
            byteCount: try fileBytes(fixture.sealedURL),
            rowCount: 21,
            firstTimestamp: fixture.sealedChunk.firstTimestamp,
            lastTimestamp: fixture.windowStart.addingTimeInterval(20),
            contentSHA256: String(repeating: "c", count: 64),
            state: .sealed,
            retirementManifestRelativePath: nil
        )
        let catalog = AtriaHistoricalArchiveCatalog(
            version: fixture.catalog.version,
            generation: fixture.catalog.generation + 1,
            activeChunkID: fixture.catalog.activeChunkID,
            chunks: [resealed] + fixture.catalog.chunks.filter { $0.id != resealed.id }
        )
        XCTAssertNil(HistoricalArchive.validHeartRateSidecarBinding(
            sidecarURL: sidecarURL(fixture), chunk: resealed
        ), "The sidecar bound to the old content must fail closed after a reseal")

        var diagnostics = HistoricalArchive.HeartRateWindowReadDiagnostics(
            startUnix: 0, endUnix: 0, elapsedMilliseconds: 0,
            candidateFileCount: 0, trustedOutsideWindowSkipped: 0,
            selectedFileCount: 0, scannedFileCount: 0, scannedByteCount: 0,
            scannedLineCount: 0, heartRateCandidateLineCount: 0,
            inWindowPointCount: 0, catalogGeneration: 0, catalogChunkCount: 0,
            terminal: "unset"
        )
        let repaired = try XCTUnwrap(HistoricalArchive.exactMetricHeartRatePoints(
            in: fixture.candidates,
            catalog: catalog,
            archiveRoot: fixture.root,
            start: fixture.windowStart,
            end: fixture.windowEnd,
            maximumPoints: 200,
            diagnostics: &diagnostics
        ))
        XCTAssertTrue(repaired.points.map(\.bpm).contains(155),
                      "The raw fallback must surface the new row the stale sidecar lacks")
        XCTAssertNotNil(HistoricalArchive.validHeartRateSidecarBinding(
            sidecarURL: sidecarURL(fixture), chunk: resealed
        ), "The read that fell back must leave a repaired sidecar behind")
    }

    func testCorruptSidecarBodyFallsBackToRawTruthAndRepairs() throws {
        let fixture = try makeFixture()
        _ = read(fixture)
        let url = sidecarURL(fixture)
        let header = try XCTUnwrap(
            String(contentsOf: url, encoding: .utf8).split(separator: "\n").first
        )
        try Data((header + "\nnot a row\n").utf8).write(to: url)

        let result = try XCTUnwrap(read(fixture).read)
        XCTAssertEqual(result.points.map(\.bpm),
                       fixture.sealedBPMs + fixture.activeBPMs,
                       "A malformed sidecar body must fall back to the raw scan truth")
        let repaired = try XCTUnwrap(HistoricalArchive.sidecarHeartRatePoints(
            sidecarURL: url,
            start: fixture.windowStart,
            end: fixture.windowEnd,
            maximumPoints: 200
        ))
        XCTAssertEqual(repaired.map(\.bpm), fixture.sealedBPMs)
    }

    // MARK: - Result cache invalidation

    func testWindowResultCacheKeyChangesWithFingerprintGenerationAndReaderVersion() throws {
        let descriptor = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: URL(fileURLWithPath: "/tmp/a.jsonl"),
            size: 100,
            modificationTime: 1_800_000_000,
            resourceIdentifier: "id-1"
        )
        func hash(generation: UInt64?, size: UInt64,
                  mtime: Double, resource: String?) -> Int {
            let fingerprint = HistoricalArchive.makeConsumerSourceFingerprint(
                catalogGeneration: generation,
                descriptors: [
                    .init(url: descriptor.url,
                          size: size,
                          modificationTime: mtime,
                          resourceIdentifier: resource)
                ]
            )
            var hasher = Hasher()
            if let encoded = try? JSONEncoder().encode(fingerprint) {
                hasher.combine(encoded)
            }
            return hasher.finalize()
        }
        let baseline = hash(generation: 5, size: 100,
                            mtime: 1_800_000_000, resource: "id-1")
        XCTAssertNotEqual(baseline,
                          hash(generation: 6, size: 100,
                               mtime: 1_800_000_000, resource: "id-1"),
                          "A catalog generation bump must produce a different cache key")
        XCTAssertNotEqual(baseline,
                          hash(generation: 5, size: 101,
                               mtime: 1_800_000_000, resource: "id-1"),
                          "A size change must produce a different cache key")
        XCTAssertNotEqual(baseline,
                          hash(generation: 5, size: 100,
                               mtime: 1_800_000_001, resource: "id-1"),
                          "An mtime change must produce a different cache key")
        XCTAssertNotEqual(baseline,
                          hash(generation: 5, size: 100,
                               mtime: 1_800_000_000, resource: "id-2"),
                          "A resource-identity change must produce a different cache key")

        let sameFingerprintKeyA = HistoricalArchive.HeartRateWindowResultCache.Key(
            startUnix: 0, endUnix: 60, fingerprintHash: baseline, readerVersion: 1
        )
        let readerBumped = HistoricalArchive.HeartRateWindowResultCache.Key(
            startUnix: 0, endUnix: 60, fingerprintHash: baseline, readerVersion: 2
        )
        XCTAssertNotEqual(sameFingerprintKeyA, readerBumped,
                          "A reader-version bump must miss every existing entry")
    }

    func testWindowResultCacheReturnsInstalledReadAndEvictsOldestBeyondCapacity() throws {
        typealias Cache = HistoricalArchive.HeartRateWindowResultCache
        func key(_ index: Int) -> Cache.Key {
            .init(startUnix: Double(index), endUnix: Double(index) + 60,
                  fingerprintHash: 42, readerVersion: 1)
        }
        let read = HistoricalArchive.HeartRateWindowRead(
            points: [.init(t: Date(timeIntervalSince1970: 1), bpm: 60)],
            scannedFileCount: 1,
            scannedByteCount: 10
        )
        Cache.install(read, for: key(0))
        XCTAssertEqual(Cache.value(for: key(0))?.points.map(\.bpm), [60])
        XCTAssertNil(Cache.value(for: .init(startUnix: 0, endUnix: 60,
                                            fingerprintHash: 43, readerVersion: 1)),
                     "A different fingerprint hash must miss")
        for index in 1...16 { Cache.install(read, for: key(index)) }
        XCTAssertNil(Cache.value(for: key(0)),
                     "The oldest window falls out once capacity is exceeded")
        XCTAssertNotNil(Cache.value(for: key(16)))
    }

    // MARK: - Helpers (mirrors AtriaHistoricalArchiveCatalogTests)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHeartRateWindowIndexTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func relative(_ url: URL, root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private func fileBytes(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.size] as? NSNumber)?.uint64Value)
    }

    private func metricHeartRateLine(unix: Int, bpm: Int) -> String {
        "{\"clockCorrectedUnix7\":\(unix),\"clockCorrectionStatus\":\"clock_ref_present\",\"gravityValidated\":true,\"layoutVersion\":\"\(HistoricalArchive.layoutVersion)\",\"metricUsable\":true,\"subsec11\":0,\"unix7\":\(unix),\"whoofHR17\":\(bpm)}"
    }
}
