import XCTest
@testable import Atria

final class AtriaHistoricalHighVolumeStoragePlannerTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testRecursiveAccountingIncludesSQLiteWALAndSHMAndSeparatesTypedGrowth() throws {
        let root = try makeRoot()
        try write(bytes: 11, relativePath: "segments/raw-v2/raw-a.jsonl", root: root)
        try write(bytes: 13, relativePath: "retired-replay-v1/retired.sqlite", root: root)
        try write(bytes: 17, relativePath: "retired-replay-v1/retired.sqlite-wal", root: root)
        try write(bytes: 19, relativePath: "retired-replay-v1/retired.sqlite-shm", root: root)
        try write(bytes: 23, relativePath: "aggregates-v2/aggregate-a.json", root: root)
        try write(bytes: 29,
                  relativePath: "consumer-receipts-v1/consumer-artifact-sleep-a.bin",
                  root: root)
        try write(bytes: 31,
                  relativePath: "consumer-receipts-v1/consumer-artifact-replay_identity-a.bin",
                  root: root)
        try write(bytes: 37, relativePath: "historical-archive.catalog-v2.json", root: root)

        let snapshot = try AtriaHistoricalHighVolumeStorageAccounting(
            archiveRoot: root,
            catalogRawRelativePaths: ["segments/raw-v2/raw-a.jsonl"]
        ).measure()

        XCTAssertEqual(snapshot.rawBytes, 11)
        XCTAssertEqual(snapshot.replayEvidenceBytes, 13 + 17 + 19 + 31)
        XCTAssertEqual(snapshot.highVolumeBytes, 11 + 13 + 17 + 19 + 31)
        XCTAssertEqual(snapshot.compactLongTermTypedBytes, 23 + 29)
        XCTAssertEqual(snapshot.otherManagedBytes, 37)
        XCTAssertEqual(snapshot.scannedFileCount, 8)
        XCTAssertEqual(snapshot.scannedByteCount, 180)
    }

    func testSymlinkAnywhereInManagedTreeFailsClosed() throws {
        let root = try makeRoot()
        try write(bytes: 5, relativePath: "segments/raw-v2/raw-a.jsonl", root: root)
        let link = root.appendingPathComponent("retired-replay-v1/unsafe-link")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: URL(fileURLWithPath: "/tmp"))
        let accounting = try AtriaHistoricalHighVolumeStorageAccounting(
            archiveRoot: root,
            catalogRawRelativePaths: ["segments/raw-v2/raw-a.jsonl"]
        )

        XCTAssertThrowsError(try accounting.measure()) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalHighVolumeStorageAccounting.AccountingError,
                .symbolicLinkDetected("retired-replay-v1/unsafe-link")
            )
        }
    }

    func testMissingRootAndMissingCatalogRawBothFailClosed() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
        let unavailable = try AtriaHistoricalHighVolumeStorageAccounting(
            archiveRoot: missing,
            catalogRawRelativePaths: []
        )
        XCTAssertThrowsError(try unavailable.measure()) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalHighVolumeStorageAccounting.AccountingError,
                .rootUnavailable
            )
        }

        let root = try makeRoot()
        let missingRaw = try AtriaHistoricalHighVolumeStorageAccounting(
            archiveRoot: root,
            catalogRawRelativePaths: ["segments/raw-v2/raw-missing.jsonl"]
        )
        XCTAssertThrowsError(try missingRaw.measure()) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalHighVolumeStorageAccounting.AccountingError,
                .catalogRawMissing("segments/raw-v2/raw-missing.jsonl")
            )
        }
    }

    func testPureAccountingOverflowFailsClosed() throws {
        let facts = [
            AtriaHistoricalHighVolumeStorageAccounting.FileFact(
                relativePath: "retired-replay-v1/a.sqlite",
                byteCount: UInt64.max,
                isSymbolicLink: false
            ),
            AtriaHistoricalHighVolumeStorageAccounting.FileFact(
                relativePath: "retired-replay-v1/a.sqlite-wal",
                byteCount: 1,
                isSymbolicLink: false
            ),
        ]
        XCTAssertThrowsError(try AtriaHistoricalHighVolumeStorageAccounting.summarize(
            rootURL: URL(fileURLWithPath: "/tmp/accounting-overflow"),
            facts: facts,
            catalogRawRelativePaths: []
        )) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalHighVolumeStorageAccounting.AccountingError,
                .byteCountOverflow
            )
        }
    }

    func testPlannerContinuesAcrossOldestNetDecreasingChunksUntilUnderCap() throws {
        let snapshot = try accountingSnapshot(raw: 800, replay: 200, compactTyped: 70)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let chunks = [
            chunk("active", raw: 100, age: 0, sealed: false, added: nil, now: now),
            chunk("oldest", raw: 400, age: 3, sealed: true, added: 100, now: now),
            chunk("newer", raw: 300, age: 2, sealed: true, added: 50, now: now),
        ]

        let plan = try AtriaHistoricalHighVolumeStoragePlanner(
            maximumHighVolumeBytes: 500
        ).plan(accounting: snapshot, chunks: chunks)

        XCTAssertEqual(plan.selections.map(\.chunk.identifier), ["oldest", "newer"])
        XCTAssertEqual(plan.selections.map(\.projectedHighVolumeBytes), [700, 450])
        XCTAssertEqual(plan.state, .capSatisfied)
        XCTAssertTrue(plan.capSatisfied)
        XCTAssertEqual(plan.remainingOverageBytes, 0)
        XCTAssertEqual(plan.compactLongTermTypedBytes, 70,
                       "compact typed growth is reported but excluded from the hard cap")
    }

    func testPlannerReportsProgressWithoutClaimingCapSatisfied() throws {
        let snapshot = try accountingSnapshot(raw: 800, replay: 200, compactTyped: 20)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let chunks = [
            chunk("active", raw: 100, age: 0, sealed: false, added: nil, now: now),
            chunk("eligible", raw: 300, age: 3, sealed: true, added: 200, now: now),
            chunk("unverified", raw: 400, age: 2, sealed: true, added: nil, now: now),
        ]

        let plan = try AtriaHistoricalHighVolumeStoragePlanner(
            maximumHighVolumeBytes: 500
        ).plan(accounting: snapshot, chunks: chunks)

        XCTAssertEqual(plan.selections.map(\.chunk.identifier), ["eligible"])
        XCTAssertEqual(plan.projectedHighVolumeBytes, 900)
        XCTAssertEqual(plan.state, .progressOnly)
        XCTAssertTrue(plan.makesNetDecreasingProgress)
        XCTAssertFalse(plan.capSatisfied)
        XCTAssertEqual(plan.remainingOverageBytes, 400)
        XCTAssertEqual(plan.protectedActiveOverageBytes, 100)
        XCTAssertEqual(plan.unresolvedNonActiveOverageBytes, 300)
    }

    func testPlannerReportsProtectedActiveOverageAsBoundedException() throws {
        let snapshot = try accountingSnapshot(raw: 600, replay: 100, compactTyped: 10)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let chunks = [
            chunk("active", raw: 400, age: 0, sealed: false, added: nil, now: now),
            chunk("sealed", raw: 200, age: 2, sealed: true, added: 50, now: now),
        ]

        let plan = try AtriaHistoricalHighVolumeStoragePlanner(
            maximumHighVolumeBytes: 400
        ).plan(accounting: snapshot, chunks: chunks)

        XCTAssertEqual(plan.projectedHighVolumeBytes, 550)
        XCTAssertEqual(plan.state, .protectedActiveException)
        XCTAssertFalse(plan.capSatisfied)
        XCTAssertEqual(plan.protectedActiveBytes, 400)
        XCTAssertEqual(plan.protectedActiveOverageBytes, 150)
        XCTAssertEqual(plan.unresolvedNonActiveOverageBytes, 0)
    }

    func testPlannerRejectsCatalogAccountingMismatch() throws {
        let snapshot = try accountingSnapshot(raw: 10, replay: 0, compactTyped: 0)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let planner = AtriaHistoricalHighVolumeStoragePlanner(maximumHighVolumeBytes: 100)

        XCTAssertThrowsError(try planner.plan(
            accounting: snapshot,
            chunks: [chunk("raw", raw: 9, age: 1, sealed: true, added: 1, now: now)]
        )) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalHighVolumeStoragePlanner.PlannerError,
                .rawAccountingMismatch(expected: 9, actual: 10)
            )
        }
    }

    func testReadOnlyCoordinatorUsesRealCatalogAndLeavesRawUntouched() throws {
        let root = try makeRoot()
        let activePath = "segments/raw-v2/active.jsonl"
        let sealedPath = "segments/raw-v2/sealed.jsonl"
        try write(bytes: 10, relativePath: activePath, root: root)
        try write(bytes: 20, relativePath: sealedPath, root: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let catalog = AtriaHistoricalArchiveCatalog(
            version: AtriaHistoricalArchiveCatalog.currentVersion,
            generation: 1,
            activeChunkID: "active",
            chunks: [
                .init(id: "active", relativePath: activePath, createdAt: now,
                      sealedAt: nil, byteCount: 10, rowCount: nil,
                      firstTimestamp: nil, lastTimestamp: nil,
                      contentSHA256: nil, state: .active,
                      retirementManifestRelativePath: nil),
                .init(id: "sealed", relativePath: sealedPath,
                      createdAt: now.addingTimeInterval(-100), sealedAt: now,
                      byteCount: 20, rowCount: 1,
                      firstTimestamp: now.addingTimeInterval(-100),
                      lastTimestamp: now.addingTimeInterval(-90),
                      contentSHA256: String(repeating: "a", count: 64),
                      state: .sealed, retirementManifestRelativePath: nil),
            ]
        )

        let report = try AtriaHistoricalHighVolumeDiagnosticsCoordinator.evaluate(
            archiveRoot: root,
            catalog: catalog,
            planner: .init(maximumHighVolumeBytes: 15)
        )

        XCTAssertEqual(report.accounting.rawBytes, 30)
        XCTAssertEqual(report.verifiedReplayEvidenceChunkCount, 0)
        XCTAssertEqual(report.incompleteReplayEvidenceChunkCount, 1)
        XCTAssertEqual(report.plan.state, .blocked)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(activePath).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(sealedPath).path
        ))
    }

    func testProductionMaintenanceCallsReadOnlyDiagnosticsWithoutDestructiveAuthority() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testsURL.deletingLastPathComponent().deletingLastPathComponent()
        let archiveSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Atria/HistoricalArchive.swift"),
            encoding: .utf8
        )
        let diagnosticsSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Atria/AtriaHistoricalHighVolumeStoragePlanner.swift"
            ),
            encoding: .utf8
        )
        let compactStart = try XCTUnwrap(
            archiveSource.range(of: "static func compactArchive(")
        )
        let compactEnd = try XCTUnwrap(
            archiveSource.range(of: "private static func legacyCompactArchiveDisabled",
                                range: compactStart.lowerBound..<archiveSource.endIndex)
        )
        let compactBody = String(
            archiveSource[compactStart.lowerBound..<compactEnd.lowerBound]
        )

        XCTAssertTrue(compactBody.contains(
            "AtriaHistoricalHighVolumeDiagnosticsCoordinator"
        ))
        XCTAssertTrue(compactBody.contains("mutation_authority=0 raw_retained=1"))
        XCTAssertFalse(compactBody.contains("markRetired"))
        XCTAssertFalse(compactBody.contains("deleteSourceAfterCommit: true"))
        XCTAssertFalse(compactBody.contains("removeItem"))
        XCTAssertFalse(diagnosticsSource.contains("markRetired"))
        XCTAssertFalse(diagnosticsSource.contains("deleteSourceAfterCommit"))
        XCTAssertFalse(diagnosticsSource.contains("removeItem"))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalHighVolumeStoragePlannerTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func write(bytes: Int, relativePath: String, root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x5a, count: bytes).write(to: url)
    }

    private func accountingSnapshot(
        raw: UInt64,
        replay: UInt64,
        compactTyped: UInt64
    ) throws -> AtriaHistoricalHighVolumeStorageAccounting.Snapshot {
        try AtriaHistoricalHighVolumeStorageAccounting.summarize(
            rootURL: URL(fileURLWithPath: "/tmp/planner-fixture"),
            facts: [
                .init(relativePath: "segments/raw-v2/all.jsonl",
                      byteCount: raw, isSymbolicLink: false),
                .init(relativePath: "retired-replay-v1/retired.sqlite",
                      byteCount: replay, isSymbolicLink: false),
                .init(relativePath: "aggregates-v2/all.json",
                      byteCount: compactTyped, isSymbolicLink: false),
            ],
            catalogRawRelativePaths: ["segments/raw-v2/all.jsonl"]
        )
    }

    private func chunk(
        _ identifier: String,
        raw: UInt64,
        age: TimeInterval,
        sealed: Bool,
        added: UInt64?,
        now: Date
    ) -> AtriaHistoricalHighVolumeStoragePlanner.Chunk {
        .init(identifier: identifier,
              rawByteCount: raw,
              latestTimestamp: now.addingTimeInterval(-age),
              isSealed: sealed,
              additionalRetainedEvidenceBytes: added)
    }
}
