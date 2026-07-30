import XCTest
@testable import Atria

final class AtriaHistoricalArchiveCatalogTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories.removeAll()
    }

    func testLegacyDiscoverySealsExistingFilesAndCreatesOneFreshActiveChunk() throws {
        let root = try temporaryDirectory()
        let base = root.appendingPathComponent("historical-archive.jsonl")
        let segment = root.appendingPathComponent("segments/old.jsonl")
        try FileManager.default.createDirectory(at: segment.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("base\n".utf8).write(to: base)
        try Data("segment\n".utf8).write(to: segment)
        let ids = IdentifierSource(["legacy-a", "legacy-b", "active-a"])
        let store = AtriaHistoricalArchiveCatalogStore(rootURL: root,
                                                       makeIdentifier: ids.next)

        let catalog = try store.loadOrRecover(discoveredLegacyURLs: [base, segment],
                                              now: Date(timeIntervalSince1970: 2_000_000_000))

        XCTAssertEqual(catalog.chunks.filter { $0.state == .sealed }.count, 2)
        XCTAssertEqual(catalog.chunks.filter { $0.state == .active }.count, 1)
        XCTAssertEqual(catalog.activeChunkID, "active-a")
        XCTAssertFalse(catalog.chunks.filter { $0.state == .sealed }
            .contains(where: { $0.relativePath.contains("raw-v2") }))
    }

    func testSizeRotationSealsOldChunkAndNeverReopensItsFilename() throws {
        let root = try temporaryDirectory()
        let ids = IdentifierSource(["active-a", "active-b", "active-c"])
        let store = AtriaHistoricalArchiveCatalogStore(rootURL: root,
                                                       maximumActiveBytes: 10,
                                                       makeIdentifier: ids.next)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try store.loadOrRecover(discoveredLegacyURLs: [], now: now)
        let first = try store.writableChunkURL(now: now)
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: first)

        let second = try store.writableChunkURL(now: now.addingTimeInterval(1))
        let secondAgain = try store.writableChunkURL(now: now.addingTimeInterval(2))
        let catalog = try store.snapshot()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second, secondAgain)
        XCTAssertEqual(catalog.chunks.first(where: { $0.relativePath == relative(first, root: root) })?.state,
                       .sealed)
        XCTAssertEqual(catalog.activeChunk?.relativePath, relative(second, root: root))
    }

    func testDayBoundaryRotatesEvenWhenChunkIsSmall() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let root = try temporaryDirectory()
        let ids = IdentifierSource(["day-a", "day-b"])
        let store = AtriaHistoricalArchiveCatalogStore(rootURL: root,
                                                       calendar: calendar,
                                                       makeIdentifier: ids.next)
        let dayOne = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try store.loadOrRecover(discoveredLegacyURLs: [], now: dayOne)
        let first = try store.writableChunkURL(now: dayOne)
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!

        let second = try store.writableChunkURL(now: dayTwo)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try store.snapshot().chunks.filter { $0.state == .active }.count, 1)
    }

    func testAppendCompletionAndRestartKeepActiveByteCountVerifiable() throws {
        let root = try temporaryDirectory()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            makeIdentifier: IdentifierSource(["active-a"]).next
        )
        _ = try first.loadOrRecover(discoveredLegacyURLs: [], now: now)
        let activeURL = try first.writableChunkURL(now: now)
        try FileManager.default.createDirectory(
            at: activeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("one-row\n".utf8).write(to: activeURL)
        try first.recordAppendCompleted(at: activeURL)

        XCTAssertEqual(try first.snapshotVerifiedAgainstFiles().activeChunk?.byteCount, 8)

        // Simulate a crash after another append but before the in-memory hint.
        let handle = try FileHandle(forWritingTo: activeURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("two\n".utf8))
        try handle.close()
        let restarted = AtriaHistoricalArchiveCatalogStore(rootURL: root)
        let recovered = try restarted.loadOrRecover(discoveredLegacyURLs: [], now: now)

        XCTAssertEqual(recovered.activeChunk?.byteCount, 12)
        XCTAssertEqual(try restarted.snapshotVerifiedAgainstFiles().activeChunk?.byteCount, 12)
    }

    func testDurableFlushReconcilesActiveCatalogBeforeTerminalProof() throws {
        let root = try temporaryDirectory()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            makeIdentifier: IdentifierSource(["active-a"]).next
        )
        _ = try store.loadOrRecover(discoveredLegacyURLs: [], now: now)
        let activeURL = try store.writableChunkURL(now: now)
        try FileManager.default.createDirectory(
            at: activeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("durable-history-row\n".utf8).write(to: activeURL)

        XCTAssertThrowsError(try store.snapshotVerifiedAgainstFiles()) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalArchiveCatalogStore.StoreError,
                .catalogFileMismatch
            )
        }

        try HistoricalArchive.reconcileActiveCatalogAfterDurableFlush(
            synchronizedFiles: [activeURL],
            catalogStore: store
        )

        XCTAssertEqual(
            try store.snapshotVerifiedAgainstFiles().activeChunk?.byteCount,
            20
        )
    }

    func testExistingV2CatalogWithoutStorageMetadataRemainsCompatible() throws {
        let root = try temporaryDirectory()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            makeIdentifier: IdentifierSource(["active-plain"]).next
        )
        _ = try first.loadOrRecover(discoveredLegacyURLs: [], now: now)

        let restarted = AtriaHistoricalArchiveCatalogStore(rootURL: root)
        let loaded = try restarted.loadOrRecover(discoveredLegacyURLs: [], now: now)

        XCTAssertNil(loaded.activeChunk?.compressedStorage)
        XCTAssertEqual(loaded.activeChunk?.storedByteCount, loaded.activeChunk?.byteCount)
    }

    func testCompressedSealedStoragePublishesPhysicalIdentityAndResolvesAfterRestart() throws {
        let fixture = try compressedFixture()

        try fixture.store.recordCompressedStorage(
            chunkID: fixture.sealedID,
            manifestURL: fixture.compressed.manifestURL,
            artifactURL: fixture.compressed.artifactURL
        )
        let catalog = try fixture.store.snapshotVerifiedAgainstFiles()
        let sealed = try XCTUnwrap(catalog.chunks.first { $0.id == fixture.sealedID })

        XCTAssertEqual(sealed.relativePath,
                       relative(fixture.compressed.artifactURL, root: fixture.root))
        XCTAssertEqual(sealed.byteCount, fixture.compressed.manifest.decodedByteCount)
        XCTAssertEqual(sealed.storedByteCount,
                       fixture.compressed.manifest.compressedByteCount)
        XCTAssertEqual(try fixture.store.resolvedFileURL(forChunkID: fixture.sealedID),
                       fixture.compressed.artifactURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path),
                      "catalog storage publication must never remove the original")
        XCTAssertTrue(try fixture.store.verifiesCompressedStorage(
            manifest: fixture.compressed.manifest,
            artifactURL: fixture.compressed.artifactURL,
            manifestURL: fixture.compressed.manifestURL
        ))
        let accounting = try AtriaHistoricalHighVolumeDiagnosticsCoordinator.evaluate(
            archiveRoot: fixture.root,
            catalog: catalog,
            planner: .init(maximumHighVolumeBytes: UInt64.max)
        ).accounting
        let coexistenceBytes = try fileBytes(fixture.source)
            + fileBytes(fixture.compressed.artifactURL)
        XCTAssertEqual(accounting.rawBytes,
                       coexistenceBytes,
                       "crash-safe source/artifact coexistence must be counted, not hidden")

        let restarted = AtriaHistoricalArchiveCatalogStore(rootURL: fixture.root)
        _ = try restarted.loadOrRecover(discoveredLegacyURLs: [], now: fixture.now)
        XCTAssertEqual(try restarted.resolvedFileURL(forChunkID: fixture.sealedID),
                       fixture.compressed.artifactURL)
        XCTAssertNoThrow(try restarted.snapshotVerifiedAgainstFiles())
    }

    func testCompressedArtifactTamperFailsCatalogVerificationAndPreservesOriginal() throws {
        let fixture = try compressedFixture()
        try fixture.store.recordCompressedStorage(
            chunkID: fixture.sealedID,
            manifestURL: fixture.compressed.manifestURL,
            artifactURL: fixture.compressed.artifactURL
        )
        let handle = try FileHandle(forWritingTo: fixture.compressed.artifactURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xde, 0xad]))
        try handle.close()

        XCTAssertThrowsError(try fixture.store.snapshotVerifiedAgainstFiles()) { error in
            XCTAssertEqual(error as? AtriaHistoricalArchiveCatalogStore.StoreError,
                           .catalogFileMismatch)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testSourceMutationBeforeCompressedCatalogPublicationFailsClosed() throws {
        let fixture = try compressedFixture()
        let handle = try FileHandle(forWritingTo: fixture.source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        XCTAssertThrowsError(try fixture.store.recordCompressedStorage(
            chunkID: fixture.sealedID,
            manifestURL: fixture.compressed.manifestURL,
            artifactURL: fixture.compressed.artifactURL
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalArchiveCatalogStore.StoreError,
                           .sealedContentMismatch)
        }
        let sealed = try XCTUnwrap(try fixture.store.snapshot().chunks.first {
            $0.id == fixture.sealedID
        })
        XCTAssertNil(sealed.compressedStorage)
        XCTAssertEqual(sealed.relativePath, relative(fixture.source, root: fixture.root))
    }

    func testActiveChunkCannotReceiveCompressedStorageMetadata() throws {
        let root = try temporaryDirectory()
        let store = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            makeIdentifier: IdentifierSource(["active-only"]).next
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let catalog = try store.loadOrRecover(discoveredLegacyURLs: [], now: now)
        let missing = root.appendingPathComponent("missing")

        XCTAssertThrowsError(try store.recordCompressedStorage(
            chunkID: catalog.activeChunkID,
            manifestURL: missing,
            artifactURL: missing
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalArchiveCatalogStore.StoreError,
                           .chunkNotSealed)
        }
    }

    func testMalformedCatalogIsPreservedAndRawFilesRemainUntouchedDuringRecovery() throws {
        let root = try temporaryDirectory()
        let catalogURL = root.appendingPathComponent("historical-archive.catalog-v2.json")
        let raw = root.appendingPathComponent("historical-archive.jsonl")
        try Data("{torn".utf8).write(to: catalogURL)
        try Data("raw-survives\n".utf8).write(to: raw)
        let ids = IdentifierSource(["corrupt-copy", "legacy", "active"])
        let store = AtriaHistoricalArchiveCatalogStore(rootURL: root,
                                                       makeIdentifier: ids.next)

        let recovered = try store.loadOrRecover(discoveredLegacyURLs: [raw],
                                                now: Date(timeIntervalSince1970: 2_000_000_000))

        XCTAssertEqual(try Data(contentsOf: raw), Data("raw-survives\n".utf8))
        XCTAssertEqual(recovered.chunks.filter { $0.state == .sealed }.count, 1)
        let preserved = try FileManager.default.contentsOfDirectory(at: root,
                                                                    includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), Data("{torn".utf8))
    }

    func testRetirementRequiresCommittedManifestAndAlreadyDeletedSource() throws {
        let root = try temporaryDirectory()
        let ids = IdentifierSource(["active-a", "active-b"])
        let store = AtriaHistoricalArchiveCatalogStore(rootURL: root,
                                                       maximumActiveBytes: 1,
                                                       makeIdentifier: ids.next)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try store.loadOrRecover(discoveredLegacyURLs: [], now: now)
        let source = try store.writableChunkURL(now: now)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([1]).write(to: source)
        _ = try store.writableChunkURL(now: now.addingTimeInterval(1))
        let sealedID = try XCTUnwrap(store.snapshot().chunks.first { $0.state == .sealed }?.id)
        let manifest = root.appendingPathComponent("manifests/manifest.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.markRetired(chunkID: sealedID,
                                                   manifestURL: manifest,
                                                   now: now))
        try Data("committed".utf8).write(to: manifest)
        XCTAssertThrowsError(try store.markRetired(chunkID: sealedID,
                                                   manifestURL: manifest,
                                                   now: now)) { error in
            XCTAssertEqual(error as? AtriaHistoricalArchiveCatalogStore.StoreError,
                           .sourceStillExists)
        }
        try FileManager.default.removeItem(at: source)

        try store.markRetired(chunkID: sealedID, manifestURL: manifest, now: now)

        let retired = try XCTUnwrap(store.snapshot().chunks.first { $0.id == sealedID })
        XCTAssertEqual(retired.state, .retired)
        XCTAssertEqual(retired.retirementManifestRelativePath, "manifests/manifest.json")
    }

    func testExactWorkoutWindowUsesCatalogBoundsAndCannotBeStarvedByNewerRows() throws {
        let root = try temporaryDirectory()
        let rawRoot = root.appendingPathComponent("segments/raw-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: rawRoot,
                                                withIntermediateDirectories: true)
        let targetURL = rawRoot.appendingPathComponent("target.jsonl")
        let newerURL = rawRoot.appendingPathComponent("newer.jsonl")
        let activeURL = rawRoot.appendingPathComponent("active.jsonl")
        let targetStart = Date(timeIntervalSince1970: 1_800_000_000)
        let targetRows = (0..<10).map {
            metricHeartRateLine(unix: Int(targetStart.timeIntervalSince1970) + $0,
                                bpm: 110 + $0)
        }
        // Far more rows than the requested result budget, all newer than the
        // workout. A recent-tail reader would spend its budget here.
        let newerRows = (0..<2_000).map {
            metricHeartRateLine(unix: Int(targetStart.timeIntervalSince1970) + 86_400 + $0,
                                bpm: 90)
        }
        try Data((targetRows.joined(separator: "\n") + "\n").utf8).write(to: targetURL)
        try Data((newerRows.joined(separator: "\n") + "\n").utf8).write(to: newerURL)
        try Data().write(to: activeURL)
        let sealedAt = Date().addingTimeInterval(5)
        let targetBytes = try fileBytes(targetURL)
        let newerBytes = try fileBytes(newerURL)
        let activeRelative = relative(activeURL, root: root)
        let catalog = AtriaHistoricalArchiveCatalog(
            version: AtriaHistoricalArchiveCatalog.currentVersion,
            generation: 1,
            activeChunkID: "active",
            chunks: [
                .init(id: "target",
                      relativePath: relative(targetURL, root: root),
                      createdAt: targetStart,
                      sealedAt: sealedAt,
                      byteCount: targetBytes,
                      rowCount: targetRows.count,
                      firstTimestamp: targetStart,
                      lastTimestamp: targetStart.addingTimeInterval(9),
                      contentSHA256: String(repeating: "a", count: 64),
                      state: .sealed,
                      retirementManifestRelativePath: nil),
                .init(id: "newer",
                      relativePath: relative(newerURL, root: root),
                      createdAt: targetStart.addingTimeInterval(86_400),
                      sealedAt: sealedAt,
                      byteCount: newerBytes,
                      rowCount: newerRows.count,
                      firstTimestamp: targetStart.addingTimeInterval(86_400),
                      lastTimestamp: targetStart.addingTimeInterval(86_400 + 1_999),
                      contentSHA256: String(repeating: "b", count: 64),
                      state: .sealed,
                      retirementManifestRelativePath: nil),
                .init(id: "active",
                      relativePath: activeRelative,
                      createdAt: Date(),
                      sealedAt: nil,
                      byteCount: 0,
                      rowCount: nil,
                      firstTimestamp: nil,
                      lastTimestamp: nil,
                      contentSHA256: nil,
                      state: .active,
                      retirementManifestRelativePath: nil)
            ]
        )
        let end = targetStart.addingTimeInterval(10)

        let selected = HistoricalArchive.exactWindowProjectionFileURLs(
            candidates: [newerURL, targetURL, activeURL],
            catalog: catalog,
            archiveRoot: root,
            start: targetStart,
            end: end
        )
        XCTAssertEqual(Set(selected.map(\.standardizedFileURL.path)),
                       Set([targetURL, activeURL].map(\.standardizedFileURL.path)))

        let read = try XCTUnwrap(HistoricalArchive.exactMetricHeartRatePoints(
            in: [newerURL, targetURL, activeURL],
            catalog: catalog,
            archiveRoot: root,
            start: targetStart,
            end: end,
            maximumPoints: 20
        ))
        XCTAssertEqual(read.points.map(\.bpm), Array(110...119))
        XCTAssertEqual(read.scannedFileCount, 2)
        XCTAssertLessThan(read.scannedByteCount, Int(newerBytes),
                          "Catalog range selection must not stream the newer-volume file")
    }

    func testExactWindowSafelyIncludesCompressedOutOfWindowChunkWithoutDataLoss() throws {
        let root = try temporaryDirectory()
        let rawRoot = root.appendingPathComponent("segments/raw-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: rawRoot,
                                                withIntermediateDirectories: true)
        let targetURL = rawRoot.appendingPathComponent("target.jsonl")
        let newerURL = rawRoot.appendingPathComponent("newer.jsonl")
        let activeURL = rawRoot.appendingPathComponent("active.jsonl")
        let targetStart = Date(timeIntervalSince1970: 1_800_000_000)
        let targetRows = (0..<10).map {
            metricHeartRateLine(unix: Int(targetStart.timeIntervalSince1970) + $0,
                                bpm: 110 + $0)
        }
        let newerRows = (0..<50).map {
            metricHeartRateLine(unix: Int(targetStart.timeIntervalSince1970) + 86_400 + $0,
                                bpm: 90)
        }
        try Data((targetRows.joined(separator: "\n") + "\n").utf8).write(to: targetURL)
        try Data((newerRows.joined(separator: "\n") + "\n").utf8).write(to: newerURL)
        try Data().write(to: activeURL)

        // Decoded identity of the newer chunk before it is compressed.
        let newerDecodedBytes = try fileBytes(newerURL)
        let newerDigest = try AtriaHistoricalJSONLInput.identity(at: newerURL).sha256

        // Substitute the out-of-window chunk's storage with a DEFLATE artifact.
        let compressed = try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: "newer",
            sourceURL: newerURL,
            archiveRootURL: root,
            activeSourceURL: activeURL,
            chunkSize: 97
        )
        let artifactURL = compressed.artifactURL
        XCTAssertNotEqual(try fileBytes(artifactURL), newerDecodedBytes,
                          "artifact must be physically distinct from its decoded source")

        let sealedAt = Date().addingTimeInterval(5)
        let targetBytes = try fileBytes(targetURL)
        let catalog = AtriaHistoricalArchiveCatalog(
            version: AtriaHistoricalArchiveCatalog.currentVersion,
            generation: 1,
            activeChunkID: "active",
            chunks: [
                .init(id: "target",
                      relativePath: relative(targetURL, root: root),
                      createdAt: targetStart,
                      sealedAt: sealedAt,
                      byteCount: targetBytes,
                      rowCount: targetRows.count,
                      firstTimestamp: targetStart,
                      lastTimestamp: targetStart.addingTimeInterval(9),
                      contentSHA256: String(repeating: "a", count: 64),
                      state: .sealed,
                      retirementManifestRelativePath: nil),
                // Catalog byteCount is the DECODED size; the physical artifact is
                // the compressed size, so the skip-optimization's size guard
                // cannot prove this chunk trustworthy — it must be kept, not dropped.
                .init(id: "newer",
                      relativePath: relative(artifactURL, root: root),
                      createdAt: targetStart.addingTimeInterval(86_400),
                      sealedAt: sealedAt,
                      byteCount: newerDecodedBytes,
                      rowCount: newerRows.count,
                      firstTimestamp: targetStart.addingTimeInterval(86_400),
                      lastTimestamp: targetStart.addingTimeInterval(86_400 + 49),
                      contentSHA256: newerDigest,
                      state: .sealed,
                      retirementManifestRelativePath: nil),
                .init(id: "active",
                      relativePath: relative(activeURL, root: root),
                      createdAt: Date(),
                      sealedAt: nil,
                      byteCount: 0,
                      rowCount: nil,
                      firstTimestamp: nil,
                      lastTimestamp: nil,
                      contentSHA256: nil,
                      state: .active,
                      retirementManifestRelativePath: nil)
            ]
        )
        let end = targetStart.addingTimeInterval(10)

        // A compressed out-of-window chunk must never be wrongly excluded.
        let selected = HistoricalArchive.exactWindowProjectionFileURLs(
            candidates: [artifactURL, targetURL, activeURL],
            catalog: catalog,
            archiveRoot: root,
            start: targetStart,
            end: end
        )
        XCTAssertTrue(
            Set(selected.map(\.standardizedFileURL.path))
                .contains(artifactURL.standardizedFileURL.path),
            "a compressed out-of-window chunk must be conservatively kept, never dropped"
        )

        // Even though the compressed chunk is scanned, the window read returns
        // exactly the in-window target points: transparent decode + timestamp
        // filter yields no data loss and no corruption.
        let read = try XCTUnwrap(HistoricalArchive.exactMetricHeartRatePoints(
            in: [artifactURL, targetURL, activeURL],
            catalog: catalog,
            archiveRoot: root,
            start: targetStart,
            end: end,
            maximumPoints: 100
        ))
        XCTAssertEqual(read.points.map(\.bpm), Array(110...119))
    }

    private final class IdentifierSource {
        private var values: [String]
        init(_ values: [String]) { self.values = values }
        func next() -> String { values.removeFirst() }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalArchiveCatalogTests")
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

    private struct CompressedFixture {
        let root: URL
        let now: Date
        let store: AtriaHistoricalArchiveCatalogStore
        let sealedID: String
        let source: URL
        let active: URL
        let compressed: AtriaHistoricalSealedJSONLCompression.Result
    }

    private func compressedFixture() throws -> CompressedFixture {
        let root = try temporaryDirectory()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            maximumActiveBytes: 1,
            makeIdentifier: IdentifierSource(["sealed-storage", "active-next"]).next
        )
        _ = try store.loadOrRecover(discoveredLegacyURLs: [], now: now)
        let source = try store.writableChunkURL(now: now)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{\"unix7\":1}\n{\"unix7\":2}\n".utf8).write(to: source)
        let active = try store.writableChunkURL(now: now.addingTimeInterval(1))
        let sealed = try XCTUnwrap(try store.snapshot().chunks.first { $0.state == .sealed })
        let identity = try AtriaHistoricalJSONLInput.identity(at: source)
        try store.recordSealedMetadata(
            chunkID: sealed.id,
            rowCount: 2,
            firstTimestamp: Date(timeIntervalSince1970: 1),
            lastTimestamp: Date(timeIntervalSince1970: 2),
            contentSHA256: identity.sha256
        )
        let compressed = try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: sealed.id,
            sourceURL: source,
            archiveRootURL: root,
            activeSourceURL: active,
            chunkSize: 17
        )
        return .init(root: root,
                     now: now,
                     store: store,
                     sealedID: sealed.id,
                     source: source,
                     active: active,
                     compressed: compressed)
    }

    private func metricHeartRateLine(unix: Int, bpm: Int) -> String {
        "{\"clockCorrectedUnix7\":\(unix),\"clockCorrectionStatus\":\"clock_ref_present\",\"gravityValidated\":true,\"layoutVersion\":\"\(HistoricalArchive.layoutVersion)\",\"metricUsable\":true,\"subsec11\":0,\"unix7\":\(unix),\"whoofHR17\":\(bpm)}"
    }
}
