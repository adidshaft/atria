import XCTest
@testable import Atria

/// Cross-module transaction tests for the exact loss boundaries that cannot be
/// exercised by the reducer or file store in isolation.
final class AtriaWhoop4HistoryRecoveryTransactionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testDeathBeforeFsyncReplaysOneRowAndCannotACKUntilRestartFlush() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("history.jsonl")
        let index = directory.appendingPathComponent("history.identity.jsonl")
        let identity = AtriaHistoricalArchiveDurableStore.FrameIdentity(
            strapIdentifier: "whoop-4-transaction",
            protocolVersion: 24,
            counter: 42,
            unixSeconds: 1_800_000_000,
            subsecond: 0,
            payload: Data([0x18, 0x2a])
        )
        let record = try JSONSerialization.data(withJSONObject: [
            "schema": 3,
            "sequence": 42,
            "metricUsable": true
        ], options: [.sortedKeys])

        var firstStore: AtriaHistoricalArchiveDurableStore? = try .init(
            indexURL: index,
            existingArchiveURLs: []
        )
        let abandonedBatch = try XCTUnwrap(firstStore).beginDrainBatch()
        XCTAssertEqual(try XCTUnwrap(firstStore).append(
            identity: identity,
            encodedJSONObject: record,
            to: archive,
            batch: abandonedBatch
        ), .inserted)

        var firstDrain = AtriaWhoop4HistoryDrainState()
        firstDrain.begin(generation: 1)
        _ = firstDrain.receiveFrame(
            generation: 1,
            frameKey: identity.stableKey,
            payload: [0x18, 0x2a]
        )
        _ = firstDrain.persistenceCompleted(
            generation: 1,
            frameKey: identity.stableKey,
            succeeded: true
        )
        XCTAssertEqual(firstDrain.historyEnd(
            generation: 1,
            boundaryID: "first-end",
            ackPayload: [0x01, 0xaa]
        ), [.durableFlush(generation: 1, boundary: .batch("first-end"))])

        var metricFence = AtriaHistoricalMetricDurabilityFence()
        metricFence.begin(generation: 1)
        metricFence.recordPersistedMetric(
            generation: 1,
            metricUsable: true,
            effectiveUnix: 1_800_000_000
        )
        XCTAssertEqual(
            metricFence.durableFlushCompleted(generation: 1, succeeded: false),
            [],
            "append success cannot release gap evidence"
        )

        // Model SIGKILL/power loss before either archive or identity fsync.
        firstStore = nil

        let restartedStore = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [archive]
        )
        let replayBatch = restartedStore.beginDrainBatch()
        XCTAssertEqual(try restartedStore.append(
            identity: identity,
            encodedJSONObject: record,
            to: archive,
            batch: replayBatch
        ), .duplicate(durable: false))

        var replayDrain = AtriaWhoop4HistoryDrainState()
        replayDrain.begin(generation: 2)
        _ = replayDrain.receiveFrame(
            generation: 2,
            frameKey: identity.stableKey,
            payload: [0x18, 0x2a]
        )
        _ = replayDrain.persistenceCompleted(
            generation: 2,
            frameKey: identity.stableKey,
            succeeded: true
        )
        XCTAssertEqual(replayDrain.historyEnd(
            generation: 2,
            boundaryID: "replay-end",
            ackPayload: [0x01, 0xbb]
        ), [.durableFlush(generation: 2, boundary: .batch("replay-end"))])

        metricFence.begin(generation: 2)
        metricFence.recordPersistedMetric(
            generation: 2,
            metricUsable: true,
            effectiveUnix: 1_800_000_000
        )
        XCTAssertEqual(
            Set(try restartedStore.flush(replayBatch).synchronizedFiles),
            Set([archive, index])
        )
        XCTAssertEqual(
            metricFence.durableFlushCompleted(generation: 2, succeeded: true),
            [.init(effectiveUnix: 1_800_000_000)]
        )
        XCTAssertEqual(replayDrain.durableFlushCompleted(
            generation: 2,
            boundary: .batch("replay-end"),
            succeeded: true
        ), [.sendACK(
            generation: 2,
            boundaryID: "replay-end",
            payload: [0x01, 0xbb],
            attempt: 1
        )])
        XCTAssertEqual(try lineCount(at: archive), 1)
    }

    func testDisconnectWaitingForACKCannotAdvanceReconnectGeneration() {
        let strapID = UUID()
        var epochFence = AtriaBLECallbackEpochFence()
        let deadEpoch = epochFence.activate(peripheralID: strapID)

        var drain = AtriaWhoop4HistoryDrainState()
        drain.begin(generation: 10)
        XCTAssertEqual(drain.historyEnd(
            generation: 10,
            boundaryID: "dead-end",
            ackPayload: [0x01, 0xde]
        ), [.durableFlush(generation: 10, boundary: .batch("dead-end"))])
        XCTAssertEqual(drain.durableFlushCompleted(
            generation: 10,
            boundary: .batch("dead-end"),
            succeeded: true
        ), [.sendACK(
            generation: 10,
            boundaryID: "dead-end",
            payload: [0x01, 0xde],
            attempt: 1
        )])

        epochFence.invalidate(ifMatching: strapID)
        let liveEpoch = epochFence.activate(peripheralID: strapID)
        drain.begin(generation: 11)

        XCTAssertFalse(epochFence.accepts(
            callbackEpoch: deadEpoch,
            peripheralID: strapID,
            peripheralConnected: true
        ))
        XCTAssertTrue(drain.ackCompleted(
            generation: 10,
            boundaryID: "dead-end",
            succeeded: true
        ).isEmpty)
        XCTAssertEqual(drain.generation, 11)

        XCTAssertTrue(epochFence.accepts(
            callbackEpoch: liveEpoch,
            peripheralID: strapID,
            peripheralConnected: true
        ))
        XCTAssertEqual(drain.historyComplete(generation: 11), [
            .finished(generation: 11)
        ])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoryTransactionTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func lineCount(at url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .count
    }
}
