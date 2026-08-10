import XCTest
@testable import Atria

final class AtriaHistoricalJSONLRecentScannerTests: XCTestCase {
    func testConsumerSourceFingerprintIsOrderStableAndChangesForEverySourceMutation() {
        let first = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: URL(fileURLWithPath: "/tmp/archive-a.jsonl"),
            size: 100,
            modificationTime: 10.1234,
            resourceIdentifier: "inode-a"
        )
        let second = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: URL(fileURLWithPath: "/tmp/archive-b.jsonl"),
            size: 200,
            modificationTime: 20.5678,
            resourceIdentifier: "inode-b"
        )
        let baseline = HistoricalArchive.makeConsumerSourceFingerprint(
            catalogGeneration: 7,
            descriptors: [second, first]
        )
        XCTAssertEqual(
            baseline,
            HistoricalArchive.makeConsumerSourceFingerprint(
                catalogGeneration: 7,
                descriptors: [first, second]
            ),
            "filesystem enumeration order must not create a false generation"
        )
        XCTAssertNotEqual(
            baseline,
            HistoricalArchive.makeConsumerSourceFingerprint(
                catalogGeneration: 8,
                descriptors: [first, second]
            )
        )
        XCTAssertNotEqual(
            baseline,
            HistoricalArchive.makeConsumerSourceFingerprint(
                catalogGeneration: 7,
                descriptors: [
                    .init(url: first.url,
                          size: first.size + 1,
                          modificationTime: first.modificationTime,
                          resourceIdentifier: first.resourceIdentifier),
                    second,
                ]
            )
        )
        XCTAssertNotEqual(
            baseline,
            HistoricalArchive.makeConsumerSourceFingerprint(
                catalogGeneration: 7,
                descriptors: [
                    .init(url: first.url,
                          size: first.size,
                          modificationTime: first.modificationTime + 1,
                          resourceIdentifier: first.resourceIdentifier),
                    second,
                ]
            )
        )
        XCTAssertNotEqual(
            baseline,
            HistoricalArchive.makeConsumerSourceFingerprint(
                catalogGeneration: 7,
                descriptors: [
                    .init(url: first.url,
                          size: first.size,
                          modificationTime: first.modificationTime,
                          resourceIdentifier: "inode-replaced"),
                    second,
                ]
            )
        )
        XCTAssertNotEqual(
            baseline,
            HistoricalArchive.makeConsumerSourceFingerprint(
                catalogGeneration: 7,
                descriptors: [first]
            ),
            "source removal must invalidate a conclusive negative"
        )
        XCTAssertNotNil(baseline.stableIdentifier)
    }

    func testProductionRecoveredSnapshotReadsOnlyRecentActiveChunkWithManyVerifiedOldChunks() throws {
        let root = temporaryDirectory()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cutoff = now.addingTimeInterval(-14 * 86_400)
        let oldStart = now.addingTimeInterval(-60 * 86_400)
        let oldEnd = now.addingTimeInterval(-59 * 86_400)
        let sealedAt = now.addingTimeInterval(60)
        var oldURLs: [URL] = []
        var oldByteCount = 0

        for index in 0..<64 {
            let url = root.appendingPathComponent("segments/old-\(index).jsonl")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let padding = String(repeating: "x", count: 2_048)
            let line = "{\"unix7\":\(Int(oldEnd.timeIntervalSince1970))," +
                "\"padding\":\"\(padding)\"}\n"
            let data = Data(line.utf8)
            try data.write(to: url)
            oldURLs.append(url)
            oldByteCount += data.count
        }

        let store = AtriaHistoricalArchiveCatalogStore(rootURL: root)
        _ = try store.loadOrRecover(discoveredLegacyURLs: oldURLs, now: sealedAt)
        for chunk in try store.snapshot().chunks where chunk.state == .sealed {
            let url = root.appendingPathComponent(chunk.relativePath)
            try store.recordSealedMetadata(
                chunkID: chunk.id,
                rowCount: 2,
                firstTimestamp: oldStart,
                lastTimestamp: oldEnd,
                contentSHA256: AtriaHistoricalRetentionTransaction.sha256(of: url)
            )
        }

        let active = try store.activeChunkDescriptor().fileURL
        try FileManager.default.createDirectory(
            at: active.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let recentBytes = Data("{\"unix7\":\(Int(now.timeIntervalSince1970 - 1))}\n".utf8)
        try recentBytes.write(to: active)
        let catalog = try store.snapshot()

        let snapshot = runOffMain {
            HistoricalArchive.makeRecoveredDataSnapshot(
                since: cutoff,
                candidates: oldURLs + [active],
                catalog: catalog,
                archiveRoot: root
            )
        }

        XCTAssertEqual(snapshot.scan.fileReadCount, 1)
        XCTAssertEqual(snapshot.scan.byteCount, recentBytes.count)
        XCTAssertGreaterThan(oldByteCount, snapshot.scan.byteCount * 1_000,
                             "a 14-day refresh must not reread lifetime known-old raw bytes")
        XCTAssertEqual(snapshot.completeness, .complete)
    }

    func testProductionRecoveredSnapshotSafelyScansUnknownAndPostSealModifiedBounds() throws {
        let root = temporaryDirectory()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cutoff = now.addingTimeInterval(-14 * 86_400)
        let oldStart = now.addingTimeInterval(-60 * 86_400)
        let oldEnd = now.addingTimeInterval(-59 * 86_400)
        let sealedAt = now.addingTimeInterval(60)
        let unknown = root.appendingPathComponent("segments/unknown.jsonl")
        let modified = root.appendingPathComponent("segments/modified.jsonl")
        try FileManager.default.createDirectory(
            at: unknown.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let unknownBytes = Data("{\"unix7\":\(Int(oldEnd.timeIntervalSince1970))}\n".utf8)
        let modifiedBytes = Data("{\"unix7\":\(Int(oldEnd.timeIntervalSince1970))}\n".utf8)
        try unknownBytes.write(to: unknown)
        try modifiedBytes.write(to: modified)

        let store = AtriaHistoricalArchiveCatalogStore(rootURL: root)
        _ = try store.loadOrRecover(discoveredLegacyURLs: [unknown, modified], now: sealedAt)
        let modifiedChunk = try XCTUnwrap(try store.snapshot().chunks.first {
            root.appendingPathComponent($0.relativePath).standardizedFileURL
                == modified.standardizedFileURL
        })
        try store.recordSealedMetadata(
            chunkID: modifiedChunk.id,
            rowCount: 2,
            firstTimestamp: oldStart,
            lastTimestamp: oldEnd,
            contentSHA256: AtriaHistoricalRetentionTransaction.sha256(of: modified)
        )
        // A same-size post-seal mutation cannot safely rely on the old bound.
        // Advancing mtime models that condition without changing scan bytes.
        try FileManager.default.setAttributes(
            [.modificationDate: sealedAt.addingTimeInterval(10)],
            ofItemAtPath: modified.path
        )

        let active = try store.activeChunkDescriptor().fileURL
        try FileManager.default.createDirectory(
            at: active.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let activeBytes = Data("{\"unix7\":\(Int(now.timeIntervalSince1970 - 1))}\n".utf8)
        try activeBytes.write(to: active)
        let catalog = try store.snapshot()

        let snapshot = runOffMain {
            HistoricalArchive.makeRecoveredDataSnapshot(
                since: cutoff,
                candidates: [unknown, modified, active],
                catalog: catalog,
                archiveRoot: root
            )
        }

        XCTAssertEqual(snapshot.scan.fileReadCount, 3,
                       "unknown or changed catalog bounds must fail closed by scanning")
        XCTAssertEqual(snapshot.scan.byteCount,
                       unknownBytes.count + modifiedBytes.count + activeBytes.count)
        XCTAssertEqual(snapshot.completeness, .complete)
    }

    func testStreamingScanRejectsOldLargeRowsBeforeCandidateDecode() throws {
        let file = temporaryDirectory().appendingPathComponent("archive.jsonl")
        let old = "{\"unix7\":100,\"subsec11\":0,\"rawPayloadHex\":\"\(String(repeating: "ab", count: 100_000))\"}\n"
        let recent = "{ \"unix7\" : 250, \"clockCorrectedUnix7\" : 300, \"subsec11\" : 16384 }\n"
        let bytes = Data((old + recent).utf8)
        try bytes.write(to: file)
        let descriptor = try XCTUnwrap(
            AtriaHistoricalJSONLRecentScanner.descriptors(for: [file]).first
        )
        var candidates: [Data] = []

        let result = AtriaHistoricalJSONLRecentScanner.scan(
            sources: [.init(descriptor: descriptor, startOffset: 0)],
            cutoff: 200,
            chunkSize: 127
        ) { candidates.append($0) }

        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.statistics.fileReadCount, 1)
        XCTAssertEqual(result.statistics.byteCount, bytes.count)
        XCTAssertEqual(result.statistics.lineCount, 2)
        XCTAssertEqual(result.statistics.candidateLineCount, 1)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(try XCTUnwrap(
            AtriaHistoricalJSONLRecentScanner.timestamp(in: candidates[0])
        ), 300.5, accuracy: 0.000_001)
        XCTAssertEqual(result.states[file.path]?.processedOffset, UInt64(bytes.count))
    }

    func testStreamingScanReportsMonotonicPostChunkProgress() throws {
        let file = temporaryDirectory().appendingPathComponent("progress.jsonl")
        let lines = (0..<32).map {
            "{\"unix7\":\(300 + $0),\"subsec11\":0}\n"
        }.joined()
        let bytes = Data(lines.utf8)
        try bytes.write(to: file)
        let descriptor = try XCTUnwrap(
            AtriaHistoricalJSONLRecentScanner.descriptors(for: [file]).first
        )
        var progress: [AtriaHistoricalJSONLRecentScanner.Statistics] = []

        let result = AtriaHistoricalJSONLRecentScanner.scan(
            sources: [.init(descriptor: descriptor, startOffset: 0)],
            cutoff: 0,
            chunkSize: 37,
            onProgress: { progress.append($0) }
        ) { _ in }

        XCTAssertTrue(result.complete)
        XCTAssertGreaterThan(progress.count, 1)
        XCTAssertEqual(progress.last?.byteCount, bytes.count)
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy {
            $0.byteCount < $1.byteCount
        })
        XCTAssertEqual(progress.last, result.statistics)
    }

    func testCompressedArtifactScanTransparentlyDecodesAndReusesPhysicalEOF() throws {
        let root = temporaryDirectory()
        let source = root.appendingPathComponent("segments/raw-v2/raw.jsonl")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let old = "{\"unix7\":100,\"subsec11\":0}\n"
        let recent = "{ \"unix7\" : 250, \"clockCorrectedUnix7\" : 300, \"subsec11\" : 16384 }\n"
        let plaintext = Data((old + recent).utf8)
        try plaintext.write(to: source)

        // Substitute the sealed source with a DEFLATE artifact.
        let compressed = try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: "scanner-compressed",
            sourceURL: source,
            archiveRootURL: root,
            activeSourceURL: root.appendingPathComponent("active.jsonl"),
            chunkSize: 64
        )
        let descriptor = try XCTUnwrap(
            AtriaHistoricalJSONLRecentScanner.descriptors(for: [compressed.artifactURL]).first
        )
        XCTAssertTrue(descriptor.isCompressed)

        var candidates: [Data] = []
        let result = AtriaHistoricalJSONLRecentScanner.scan(
            sources: [.init(descriptor: descriptor, startOffset: 0)],
            cutoff: 200,
            chunkSize: 31
        ) { candidates.append($0) }

        XCTAssertTrue(result.complete)
        // Transparent inflate yields the same rows as scanning the plaintext.
        XCTAssertEqual(result.statistics.lineCount, 2)
        XCTAssertEqual(result.statistics.candidateLineCount, 1)
        XCTAssertEqual(result.statistics.byteCount, plaintext.count,
                       "byteCount must reflect decoded, not physical, bytes")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(try XCTUnwrap(
            AtriaHistoricalJSONLRecentScanner.timestamp(in: candidates[0])
        ), 300.5, accuracy: 0.000_001)
        // The immutable artifact's physical EOF is the stable reuse token.
        XCTAssertEqual(result.states[descriptor.path]?.processedOffset, descriptor.size)
    }

    func testCompressedArtifactCannotResumeFromNonZeroOffset() throws {
        let root = temporaryDirectory()
        let source = root.appendingPathComponent("segments/raw-v2/raw.jsonl")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"unix7\":300,\"subsec11\":0}\n".utf8).write(to: source)
        let compressed = try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: "scanner-compressed-resume",
            sourceURL: source,
            archiveRootURL: root,
            activeSourceURL: root.appendingPathComponent("active.jsonl"),
            chunkSize: 64
        )
        let descriptor = try XCTUnwrap(
            AtriaHistoricalJSONLRecentScanner.descriptors(for: [compressed.artifactURL]).first
        )
        // A compressed artifact has no decoded byte offset to resume from, so a
        // non-zero start offset must fail closed rather than mis-seek.
        let result = AtriaHistoricalJSONLRecentScanner.scan(
            sources: [.init(descriptor: descriptor, startOffset: 1)],
            cutoff: 0
        ) { _ in }
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.statistics.fileReadCount, 0)
    }

    func testDescriptorsCollapseHardLinkAliasesToOnePhysicalFile() throws {
        let directory = temporaryDirectory()
        let original = directory.appendingPathComponent("archive.jsonl")
        let alias = directory.appendingPathComponent("archive-legacy-alias.jsonl")
        try Data("{\"unix7\":300}\n".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: alias)

        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(
            for: [original, alias]
        )

        XCTAssertEqual(descriptors.count, 1,
                       "hard-link aliases must not make recovery reread the same inode")
        XCTAssertEqual(descriptors.first?.url, original.standardizedFileURL)
        XCTAssertNotNil(descriptors.first?.resourceIdentifier)
    }

    func testPartialTrailingLineIsRetriedFromLastCompleteBoundary() throws {
        let file = temporaryDirectory().appendingPathComponent("archive.jsonl")
        let complete = Data("{\"unix7\":200,\"subsec11\":0}\n".utf8)
        let partial = Data("{\"unix7\":300".utf8)
        var initial = complete
        initial.append(partial)
        try initial.write(to: file)
        let firstDescriptor = try XCTUnwrap(
            AtriaHistoricalJSONLRecentScanner.descriptors(for: [file]).first
        )

        let first = AtriaHistoricalJSONLRecentScanner.scan(
            sources: [.init(descriptor: firstDescriptor, startOffset: 0)],
            cutoff: 0,
            chunkSize: 7,
            consumeCandidate: { _ in }
        )
        XCTAssertEqual(first.statistics.candidateLineCount, 1)
        XCTAssertEqual(first.states[file.path]?.processedOffset, UInt64(complete.count))

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(",\"subsec11\":0}\n".utf8))
        try handle.close()
        let nextDescriptor = try XCTUnwrap(
            AtriaHistoricalJSONLRecentScanner.descriptors(for: [file]).first
        )
        let plan = AtriaHistoricalJSONLRecentScanner.plan(
            previousStates: first.states,
            current: [nextDescriptor]
        )
        guard case .incremental(let sources) = plan else {
            return XCTFail("tail completion must be incremental")
        }
        XCTAssertEqual(sources.first?.startOffset, UInt64(complete.count))
        var timestamps: [TimeInterval] = []
        let second = AtriaHistoricalJSONLRecentScanner.scan(
            sources: sources,
            cutoff: 0,
            chunkSize: 5
        ) { line in
            if let timestamp = AtriaHistoricalJSONLRecentScanner.timestamp(in: line) {
                timestamps.append(timestamp)
            }
        }
        XCTAssertEqual(timestamps, [300])
        XCTAssertEqual(second.states[file.path]?.processedOffset, nextDescriptor.size)
    }

    func testByteBudgetStopsResumablyAndPassesCoverEverything() throws {
        // The 2026-08-04 balloon fix scans in budgeted passes; a budget stop
        // must land on a complete-line boundary and resume losslessly.
        let file = temporaryDirectory().appendingPathComponent("budget.jsonl")
        var content = Data()
        for index in 0..<200 {
            content.append(Data("{\"unix7\":\(1000 + index),\"subsec11\":0}\n".utf8))
        }
        try content.write(to: file)
        let descriptor = try XCTUnwrap(
            AtriaHistoricalJSONLRecentScanner.descriptors(for: [file]).first
        )

        var timestamps: [TimeInterval] = []
        var sources = [AtriaHistoricalJSONLRecentScanner.Source(descriptor: descriptor,
                                                                startOffset: 0)]
        var passes = 0
        var totalBytes = 0
        while !sources.isEmpty, passes < 64 {
            passes += 1
            let result = AtriaHistoricalJSONLRecentScanner.scan(
                sources: sources,
                cutoff: 0,
                chunkSize: 64,
                byteBudget: 512
            ) { line in
                if let timestamp = AtriaHistoricalJSONLRecentScanner.timestamp(in: line) {
                    timestamps.append(timestamp)
                }
            }
            totalBytes += result.statistics.byteCount
            if !result.exhaustedByteBudget {
                XCTAssertTrue(result.complete)
                break
            }
            XCTAssertFalse(result.complete,
                           "a budget stop is by definition not a complete scan")
            let offset = try XCTUnwrap(result.states[file.path]?.processedOffset)
            XCTAssertGreaterThan(offset, 0)
            sources = offset >= descriptor.size
                ? []
                : [.init(descriptor: descriptor, startOffset: offset)]
        }
        XCTAssertGreaterThan(passes, 2, "budget must actually split the scan")
        XCTAssertEqual(timestamps.count, 200, "no line lost or duplicated across passes")
        XCTAssertEqual(timestamps, (0..<200).map { TimeInterval(1000 + $0) })
        // A resumed pass re-reads the partial-line tail beyond the last
        // complete boundary, so bytes-read may slightly exceed the file —
        // bounded by one carry per pass. The timestamp equality above is
        // the actual lossless-coverage proof.
        XCTAssertGreaterThanOrEqual(totalBytes, content.count)
        XCTAssertLessThan(totalBytes, content.count + passes * 64)
    }

    func testByteBudgetChecksBeforeEachSourceAndKeepsUntouchedSourcesUnstated() throws {
        // Budget exhaustion mid-list must leave later sources without state
        // entries so a pass loop re-offers them whole.
        let directory = temporaryDirectory()
        let first = directory.appendingPathComponent("a.jsonl")
        let second = directory.appendingPathComponent("b.jsonl")
        try Data(String(repeating: "{\"unix7\":100,\"subsec11\":0}\n", count: 40).utf8)
            .write(to: first)
        try Data("{\"unix7\":200,\"subsec11\":0}\n".utf8).write(to: second)
        let descriptors = AtriaHistoricalJSONLRecentScanner.descriptors(for: [first, second])
        XCTAssertEqual(descriptors.count, 2)

        let result = AtriaHistoricalJSONLRecentScanner.scan(
            sources: descriptors.map { .init(descriptor: $0, startOffset: 0) },
            cutoff: 0,
            chunkSize: 64,
            byteBudget: 256,
            consumeCandidate: { _ in }
        )
        XCTAssertTrue(result.exhaustedByteBudget)
        XCTAssertFalse(result.complete)
        XCTAssertNotNil(result.states[first.path])
        XCTAssertNil(result.states[second.path],
                     "an untouched source must carry no state so it is re-offered whole")
    }

    func testCancellationStopsInsideOneChunkWithoutPublishingCompleteState() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("cancelled.jsonl")
        let lineCount = 512
        let content = (0..<lineCount).map {
            "{\"unix7\":\(1000 + $0),\"subsec11\":0}\n"
        }.joined()
        try Data(content.utf8).write(to: file)
        let descriptor = try XCTUnwrap(
            AtriaHistoricalJSONLRecentScanner.descriptors(for: [file]).first
        )
        var authorityChecks = 0
        var consumed = 0
        let result = AtriaHistoricalJSONLRecentScanner.scan(
            sources: [.init(descriptor: descriptor, startOffset: 0)],
            cutoff: 0,
            chunkSize: content.utf8.count,
            shouldContinue: {
                authorityChecks += 1
                return authorityChecks < 4
            },
            consumeCandidate: { _ in consumed += 1 }
        )

        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.complete)
        XCTAssertFalse(result.exhaustedByteBudget)
        XCTAssertGreaterThan(consumed, 0)
        XCTAssertLessThan(consumed, lineCount)
        XCTAssertLessThanOrEqual(
            consumed,
            128,
            "the inner-line checkpoint must bound work inside one large chunk"
        )
    }

    func testScanPlanReusesGrowthAndFailsClosedOnReplacementOrRemoval() {
        let firstURL = URL(fileURLWithPath: "/tmp/archive-a.jsonl")
        let secondURL = URL(fileURLWithPath: "/tmp/archive-b.jsonl")
        let state = AtriaHistoricalJSONLRecentScanner.FileState(
            path: firstURL.path,
            processedOffset: 100,
            modificationTime: 1,
            resourceIdentifier: "inode-a"
        )
        let unchanged = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: firstURL,
            size: 100,
            modificationTime: 1,
            resourceIdentifier: "inode-a"
        )
        XCTAssertEqual(AtriaHistoricalJSONLRecentScanner.plan(
            previousStates: [firstURL.path: state],
            current: [unchanged]
        ), .reuse)

        let grown = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: firstURL,
            size: 140,
            modificationTime: 2,
            resourceIdentifier: "inode-a"
        )
        guard case .incremental(let growthSources) = AtriaHistoricalJSONLRecentScanner.plan(
            previousStates: [firstURL.path: state],
            current: [grown]
        ) else { return XCTFail("same-file growth must be incremental") }
        XCTAssertEqual(growthSources, [.init(descriptor: grown, startOffset: 100)])

        let replaced = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: firstURL,
            size: 140,
            modificationTime: 2,
            resourceIdentifier: "inode-new"
        )
        guard case .rebuild = AtriaHistoricalJSONLRecentScanner.plan(
            previousStates: [firstURL.path: state],
            current: [replaced]
        ) else { return XCTFail("replacement must rebuild") }

        let other = AtriaHistoricalJSONLRecentScanner.FileDescriptor(
            url: secondURL,
            size: 10,
            modificationTime: 1,
            resourceIdentifier: "inode-b"
        )
        guard case .rebuild = AtriaHistoricalJSONLRecentScanner.plan(
            previousStates: [firstURL.path: state],
            current: [other]
        ) else { return XCTFail("removal must rebuild") }
    }

    func testRunOffMainServicesMainRunLoopWithoutMovingBodyOntoMain() {
        let observation = runOffMain {
            let bodyWasOnMainThread = Thread.isMainThread
            let mainRunLoopDelivery = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                mainRunLoopDelivery.signal()
            }
            let mainRunLoopWasServiced = mainRunLoopDelivery.wait(
                timeout: .now() + 2
            ) == .success
            return (bodyWasOnMainThread, mainRunLoopWasServiced)
        }

        XCTAssertFalse(observation.0, "the production seam must still run off-main")
        XCTAssertTrue(observation.1, "the test wait must leave the main run loop available")
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalJSONLRecentScannerTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func runOffMain<T>(_ body: @escaping () -> T) -> T {
        let completion = expectation(description: "off-main work completed")
        var result: T?
        DispatchQueue.global(qos: .userInitiated).async {
            result = body()
            completion.fulfill()
        }
        wait(for: [completion], timeout: 30)
        return result!
    }
}
