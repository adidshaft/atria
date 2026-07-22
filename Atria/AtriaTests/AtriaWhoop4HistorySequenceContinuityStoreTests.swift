import XCTest
@testable import Atria

final class AtriaWhoop4HistorySequenceContinuityStoreTests: XCTestCase {
    private let strapA = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let strapB = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    func testStoreRoundTripsAndClearsBoundedSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtriaWhoop4HistorySequenceContinuityStore(directoryURL: root)
        var reducer = AtriaWhoop4HistoryDrainState()
        _ = reducer.begin(generation: 7)
        _ = reducer.receiveFrame(generation: 7, frameKey: "a", payload: [0x2f, 0, 0, 1, 0])
        _ = reducer.receiveFrame(generation: 7, frameKey: "b", payload: [0x2f, 0, 0, 4, 0])

        try store.save(reducer.continuitySnapshot, strapIdentifier: strapA)
        XCTAssertEqual(store.load(strapIdentifier: strapA), reducer.continuitySnapshot)
        XCTAssertNil(store.load(strapIdentifier: strapB),
                     "continuity evidence must not cross to a replacement strap")
        try store.clear()
        XCTAssertNil(store.load(strapIdentifier: strapA))
    }

    func testCorruptOrNonCanonicalSnapshotIsDeletedFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("sequence-continuity-v1.json")
        try Data("{\"schemaVersion\":999,\"confirmed\":[],\"pending\":null}".utf8).write(to: state)
        let store = AtriaWhoop4HistorySequenceContinuityStore(directoryURL: root)
        XCTAssertNil(store.load(strapIdentifier: strapA))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testInvalidOrNonCanonicalStrapIdentifierCannotLoadOrSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtriaWhoop4HistorySequenceContinuityStore(directoryURL: root)
        let empty = AtriaWhoop4HistoryDrainState().continuitySnapshot
        XCTAssertThrowsError(try store.save(empty, strapIdentifier: "not-a-uuid"))
        XCTAssertNil(store.load(strapIdentifier: strapA.lowercased()))
    }

    func testMaximumSnapshotRemainsBelowStoreByteCeiling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtriaWhoop4HistorySequenceContinuityStore(directoryURL: root)
        let keyLength = AtriaWhoop4HistoryDrainState.maximumContinuityFrameKeyUTF8Count
        let transitions = (0..<AtriaWhoop4HistoryDrainState.maximumConfirmedForwardDiscontinuities).map { index in
            let suffix = String(format: "%04d", index)
            let prior = String(repeating: "a", count: keyLength - suffix.count) + suffix
            let current = String(repeating: "b", count: keyLength - suffix.count) + suffix
            return AtriaWhoop4HistoryDrainState.ContinuitySnapshot.Transition(
                streamKey: UInt16(index),
                previousFrameKey: prior,
                currentFrameKey: current,
                previousSequence: 1,
                currentSequence: 3
            )
        }
        let snapshot = AtriaWhoop4HistoryDrainState.ContinuitySnapshot(
            schemaVersion: AtriaWhoop4HistoryDrainState.ContinuitySnapshot.currentSchemaVersion,
            pending: nil,
            confirmed: transitions
        )
        try store.save(snapshot, strapIdentifier: strapA)
        let stateURL = root.appendingPathComponent("sequence-continuity-v1.json")
        let byteCount = try Data(contentsOf: stateURL).count
        XCTAssertLessThanOrEqual(byteCount, 600_000)
        XCTAssertEqual(store.load(strapIdentifier: strapA), snapshot)
    }
}
