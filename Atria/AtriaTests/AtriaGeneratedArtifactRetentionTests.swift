import XCTest
@testable import Atria

final class AtriaGeneratedArtifactRetentionTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testPrunesOldestMatchingFilesByCountAndPreservesCurrentArtifact() throws {
        let root = try makeRoot()
        let policy = AtriaGeneratedArtifactRetention.Policy(
            filenamePrefix: "atria-export-",
            allowedExtensions: ["zip"],
            maximumFiles: 2,
            maximumBytes: 1_000
        )
        let old = try write("atria-export-1.zip", bytes: 10, at: root, modifiedAt: Date(timeIntervalSince1970: 1))
        let middle = try write("atria-export-2.zip", bytes: 10, at: root, modifiedAt: Date(timeIntervalSince1970: 2))
        let current = try write("atria-export-3.zip", bytes: 10, at: root, modifiedAt: Date(timeIntervalSince1970: 3))
        _ = try write("unrelated.zip", bytes: 10, at: root, modifiedAt: .distantPast)

        let result = AtriaGeneratedArtifactRetention.prune(in: root,
                                                            policy: policy,
                                                            preserving: [current])

        XCTAssertEqual(result.matchedFiles, 3)
        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("unrelated.zip").path))
        XCTAssertTrue(result.limitSatisfied)
    }

    func testByteBudgetRemovesMultipleOldFilesWithoutFollowingSymlink() throws {
        let root = try makeRoot()
        let external = try makeRoot()
        let externalFile = try write("keep.csv", bytes: 25, at: external, modifiedAt: .distantPast)
        let policy = AtriaGeneratedArtifactRetention.Policy(
            filenamePrefix: "atria-capture-",
            allowedExtensions: ["csv"],
            maximumFiles: 10,
            maximumBytes: 25
        )
        _ = try write("atria-capture-1.csv", bytes: 20, at: root, modifiedAt: Date(timeIntervalSince1970: 1))
        _ = try write("atria-capture-2.csv", bytes: 20, at: root, modifiedAt: Date(timeIntervalSince1970: 2))
        let newest = try write("atria-capture-3.csv", bytes: 20, at: root, modifiedAt: Date(timeIntervalSince1970: 3))
        let link = root.appendingPathComponent("atria-capture-link.csv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalFile)

        let result = AtriaGeneratedArtifactRetention.prune(in: root,
                                                            policy: policy,
                                                            preserving: [newest])

        XCTAssertEqual(result.removedFiles, 2)
        XCTAssertEqual(result.remainingFiles, 1)
        XCTAssertTrue(result.limitSatisfied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testShareCardPolicyOnlyPrunesTopLevelDailyPNGs() throws {
        let root = try makeRoot()
        let policy = AtriaGeneratedArtifactRetention.shareCards
        var matching: [URL] = []
        for index in 0..<(policy.maximumFiles + 2) {
            matching.append(try write("atria-share-\(index).png",
                                      bytes: 1,
                                      at: root,
                                      modifiedAt: Date(timeIntervalSince1970: TimeInterval(index))))
        }
        let current = matching.last!
        let workout = try write("atria-workout-share-keep.png",
                                bytes: 1,
                                at: root,
                                modifiedAt: .distantPast)
        let wrongExtension = try write("atria-share-keep.jpg",
                                       bytes: 1,
                                       at: root,
                                       modifiedAt: .distantPast)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let nestedCard = try write("atria-share-nested.png",
                                   bytes: 1,
                                   at: nested,
                                   modifiedAt: .distantPast)
        let external = try makeRoot()
        let externalCard = try write("external.png", bytes: 1, at: external, modifiedAt: .distantPast)
        let link = root.appendingPathComponent("atria-share-link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalCard)

        let result = AtriaGeneratedArtifactRetention.prune(in: root,
                                                            policy: policy,
                                                            preserving: [current])

        XCTAssertEqual(result.matchedFiles, policy.maximumFiles + 2)
        XCTAssertEqual(result.removedFiles, 2)
        XCTAssertEqual(result.remainingFiles, policy.maximumFiles)
        XCTAssertTrue(result.limitSatisfied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: matching[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: matching[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workout.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrongExtension.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedCard.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalCard.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaGeneratedArtifactRetentionTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    @discardableResult
    private func write(_ name: String,
                       bytes: Int,
                       at root: URL,
                       modifiedAt: Date) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x5a, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }
}
