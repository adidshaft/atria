import XCTest
@testable import Atria

final class AtriaWhoop4HistoricalOrphanVaultTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-orphan-vault-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func validSpool(at url: URL, generation: UInt64 = 7) throws -> AtriaWhoop4HistoricalIngressSpool {
        let spool = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: generation)
        try spool.append(.metadata(payload: [0x01, 0x02], phaseGeneration: generation))
        try spool.append(.frame(payload: [0x2f, 0x00, 0x01, 0x02],
                                clock: .init(device: 100, wall: 200),
                                clockAuthorityEnabled: false))
        try spool.synchronize()
        return spool
    }

    func testSealIsByteIdenticalAndIdempotentBeforeSourceRemoval() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        _ = try validSpool(at: source)
        let original = try Data(contentsOf: source)
        let vault = try AtriaWhoop4HistoricalOrphanVault(
            directoryURL: directory.appendingPathComponent("vault", isDirectory: true)
        )

        let first = try vault.seal(sourceURL: source,
                                   strapIdentifier: "strap-a",
                                   generation: 7)
        let second = try vault.seal(sourceURL: source,
                                    strapIdentifier: "strap-a",
                                    generation: 7)

        XCTAssertEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the caller, not seal(), controls source retirement")
        let restoredSpool = try vault.spool(for: first)
        XCTAssertEqual(restoredSpool.pendingCount, 2)
        XCTAssertEqual(try vault.validatedEntries(for: "strap-a"), [first])
        XCTAssertTrue(try vault.validatedEntries(for: "another-strap").isEmpty)
        let stored = try Data(contentsOf: directory
            .appendingPathComponent("vault", isDirectory: true)
            .appendingPathComponent(first.fileName))
        XCTAssertEqual(stored, original)
    }

    func testCapacityFailureRetainsSourceAndCreatesNoEntry() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        _ = try validSpool(at: source)
        let vault = try AtriaWhoop4HistoricalOrphanVault(
            directoryURL: directory.appendingPathComponent("vault", isDirectory: true),
            maximumBytes: 16
        )

        XCTAssertThrowsError(try vault.seal(sourceURL: source,
                                             strapIdentifier: "strap-a",
                                             generation: 7)) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoricalOrphanVault.VaultError,
                           .capacityExceeded)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try vault.validatedEntries(for: nil).isEmpty)
    }

    func testRetireRequiresValidatedEntry() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        _ = try validSpool(at: source)
        let vaultDirectory = directory.appendingPathComponent("vault", isDirectory: true)
        let vault = try AtriaWhoop4HistoricalOrphanVault(directoryURL: vaultDirectory)
        let entry = try vault.seal(sourceURL: source,
                                   strapIdentifier: "strap-a",
                                   generation: 7)

        try vault.retire(entry)
        XCTAssertTrue(try vault.validatedEntries(for: nil).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: vaultDirectory.appendingPathComponent(entry.fileName).path
        ))
    }
}
