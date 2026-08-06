import CryptoKit
import Foundation
import XCTest
@testable import Atria

final class AtriaWhoop4ExactRangeTrialHarnessTests: XCTestCase {
    private typealias Harness = AtriaWhoop4ExactRangeTrialHarness

    private let startUnix: UInt32 = 1_784_390_000
    private let endUnix: UInt32 = 1_784_390_180
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    func testGateAndOneShotArmEmitOnlyGETClockThenExactEightByteRange() throws {
        let harness = makeHarness()
        XCTAssertNil(Harness.ResearchGate(enabled: false,
                                          acknowledgement: Harness.requiredAcknowledgement))
        XCTAssertNil(Harness.ResearchGate(enabled: true,
                                          acknowledgement: "not-consented"))
        XCTAssertThrowsError(try harness.arm(
            gate: nil,
            request: request(),
            now: date(200)
        )) { XCTAssertEqual($0 as? Harness.HarnessError, .gateRequired) }

        let issued = try arm(harness)
        XCTAssertEqual(issued.getClock.innerPacket, [0x23, 0x04, 0x0b])
        XCTAssertFalse(Harness.productionIntegrationEnabled)

        try harness.recordGETClockWriteCompleted(
            identity: issued.identity,
            instruction: issued.getClock,
            completedAt: date(201)
        )
        let history = try harness.recordGETClockResponseAndIssueExactRange(
            identity: issued.identity,
            responseBytes: clockResponse(requestSequence: 0x04),
            receivedAt: date(202)
        )
        XCTAssertEqual(history.command, 0x16)
        XCTAssertEqual(history.requestSequence, 0x05)
        XCTAssertEqual(history.data, le32(startUnix) + le32(endUnix))
        XCTAssertEqual(
            history.innerPacket,
            [0x23, 0x05, 0x16] + le32(startUnix) + le32(endUnix)
        )

        XCTAssertThrowsError(try harness.arm(
            gate: gate(),
            request: request(),
            now: date(203)
        )) { XCTAssertEqual($0 as? Harness.HarnessError, .trialAlreadyExists) }
        XCTAssertThrowsError(try harness.recordGETClockResponseAndIssueExactRange(
            identity: issued.identity,
            responseBytes: clockResponse(requestSequence: 0x04),
            receivedAt: date(203)
        )) { XCTAssertEqual($0 as? Harness.HarnessError, .instructionAlreadyIssued) }
    }

    func testSameGenerationPeripheralStrapAndRequestSequencesAreMandatory() throws {
        let harness = makeHarness()
        let issued = try arm(harness)
        let stale = Harness.EventIdentity(
            trialIdentifier: issued.identity.trialIdentifier,
            transportGeneration: issued.identity.transportGeneration + 1,
            peripheralIdentifier: issued.identity.peripheralIdentifier,
            strapIdentity: issued.identity.strapIdentity
        )
        XCTAssertThrowsError(try harness.recordGETClockWriteCompleted(
            identity: stale,
            instruction: issued.getClock,
            completedAt: date(201)
        )) { XCTAssertEqual($0 as? Harness.HarnessError, .staleEventIdentity) }

        try harness.recordGETClockWriteCompleted(
            identity: issued.identity,
            instruction: issued.getClock,
            completedAt: date(201)
        )
        XCTAssertThrowsError(try harness.recordGETClockResponseAndIssueExactRange(
            identity: issued.identity,
            responseBytes: clockResponse(requestSequence: 0x44),
            receivedAt: date(202)
        ))

        let reloaded = Harness(directoryURL: temporaryURLs.last!)
        XCTAssertThrowsError(try reloaded.recordGETClockResponseAndIssueExactRange(
            identity: issued.identity,
            responseBytes: clockResponse(requestSequence: 0x04),
            receivedAt: date(203)
        )) { error in
            XCTAssertEqual(error as? Harness.HarnessError,
                           .terminalState(.malformedClockResponse))
        }
    }

    func testClockHistoryEchoAndStartMustBindWithinThirtySeconds() throws {
        let harness = makeHarness()
        let issued = try armThroughHistoryWrite(harness)
        try harness.recordExactRangeCommandResponse(
            identity: issued.identity,
            responseBytes: historyResponse(requestSequence: 0x05),
            receivedAt: date(204)
        )
        XCTAssertThrowsError(try harness.recordHistoryStart(
            identity: issued.identity,
            metadataBytes: historyStart(deviceUnix: 1_784_390_146),
            receivedAt: date(205)
        )) { error in
            XCTAssertEqual(error as? Harness.HarnessError,
                           .terminalState(.clockBindingMismatch))
        }
        XCTAssertThrowsError(try harness.recordObservedHistoricalRecord(
            identity: issued.identity,
            frameIdentifier: "frame-1",
            payload: [0x2f, 0x01],
            decodedRowTimestampsUnix: [startUnix + 10],
            allRowsDecoded: true,
            receivedAt: date(206)
        )) { error in
            XCTAssertEqual(error as? Harness.HarnessError,
                           .terminalState(.clockBindingMismatch))
        }
    }

    func testACKPermitRequiresEveryObservedRecordDurableAndExactACKWrite() throws {
        let harness = makeHarness()
        let issued = try armThroughBoundStart(harness)
        let payload: [UInt8] = [0x2f, 0x10, 0x20, 0x30]
        try harness.recordObservedHistoricalRecord(
            identity: issued.identity,
            frameIdentifier: "frame-1",
            payload: payload,
            decodedRowTimestampsUnix: [startUnix + 10, startUnix + 11],
            allRowsDecoded: true,
            receivedAt: date(206)
        )
        XCTAssertThrowsError(try harness.recordHistoryEndAndCreateACKPermit(
            identity: issued.identity,
            boundaryIdentifier: "batch-1",
            metadataBytes: historyEnd(token: [1, 2, 3, 4, 5, 6, 7, 8]),
            fence: fence(sequence: 2, at: 208)
        )) { XCTAssertEqual($0 as? Harness.HarnessError, .recordsNotDurable) }

        try harness.recordHistoricalRecordFsynced(
            identity: issued.identity,
            frameIdentifier: "frame-1",
            durability: recordDurability(payload: payload, sequence: 2, at: 207)
        )
        let permit = try harness.recordHistoryEndAndCreateACKPermit(
            identity: issued.identity,
            boundaryIdentifier: "batch-1",
            metadataBytes: historyEnd(token: [1, 2, 3, 4, 5, 6, 7, 8]),
            fence: fence(sequence: 2, at: 208)
        )
        XCTAssertEqual(permit.expectedCommand, 0x17)
        XCTAssertEqual(permit.expectedData, [0x01, 1, 2, 3, 4, 5, 6, 7, 8])

        XCTAssertThrowsError(try harness.recordACKWriteCompleted(
            identity: issued.identity,
            permit: permit,
            commandSequence: 0x06,
            command: 0x17,
            data: [0x00] + Array(permit.expectedData.dropFirst()),
            completedAt: date(209)
        )) { error in
            XCTAssertEqual(error as? Harness.HarnessError,
                           .terminalState(.ackPayloadMismatch))
        }
        XCTAssertThrowsError(try harness.recordACKWriteCompleted(
            identity: issued.identity,
            permit: permit,
            commandSequence: 0x06,
            command: 0x17,
            data: permit.expectedData,
            completedAt: date(210)
        )) { error in
            XCTAssertEqual(error as? Harness.HarnessError,
                           .terminalState(.ackPayloadMismatch))
        }
    }

    func testOutOfWindowOrPartialDecodePermanentlyRejectsTrial() throws {
        for (timestamps, complete, expected) in [
            ([endUnix + 1], true, Harness.Rejection.outOfWindowRecord),
            ([startUnix + 1], false, Harness.Rejection.incompleteRecordDecode),
        ] {
            let harness = makeHarness()
            let issued = try armThroughBoundStart(harness)
            XCTAssertThrowsError(try harness.recordObservedHistoricalRecord(
                identity: issued.identity,
                frameIdentifier: "bad-frame",
                payload: [0x2f, 0x01],
                decodedRowTimestampsUnix: timestamps,
                allRowsDecoded: complete,
                receivedAt: date(206)
            )) { error in
                XCTAssertEqual(error as? Harness.HarnessError,
                               .terminalState(expected))
            }
            XCTAssertThrowsError(try harness.recordObservedHistoricalRecord(
                identity: issued.identity,
                frameIdentifier: "later-frame",
                payload: [0x2f, 0x02],
                decodedRowTimestampsUnix: [startUnix + 2],
                allRowsDecoded: true,
                receivedAt: date(207)
            )) { error in
                XCTAssertEqual(error as? Harness.HarnessError,
                               .terminalState(expected))
            }
        }
    }

    func testPositiveTrialSurvivesRereadButNeverAuthorizesProduction() throws {
        let harness = makeHarness()
        let directory = temporaryURLs.last!
        let issued = try armThroughBoundStart(harness)
        let payload: [UInt8] = [0x2f, 0xaa, 0xbb]
        try harness.recordObservedHistoricalRecord(
            identity: issued.identity,
            frameIdentifier: "frame-positive",
            payload: payload,
            decodedRowTimestampsUnix: [startUnix, startUnix + 90, endUnix],
            allRowsDecoded: true,
            receivedAt: date(206)
        )
        try harness.recordHistoricalRecordFsynced(
            identity: issued.identity,
            frameIdentifier: "frame-positive",
            durability: recordDurability(payload: payload, sequence: 3, at: 207)
        )
        let permit = try harness.recordHistoryEndAndCreateACKPermit(
            identity: issued.identity,
            boundaryIdentifier: "batch-positive",
            metadataBytes: historyEnd(token: [8, 7, 6, 5, 4, 3, 2, 1]),
            fence: fence(sequence: 3, at: 208)
        )
        try harness.recordACKWriteCompleted(
            identity: issued.identity,
            permit: permit,
            commandSequence: 0x06,
            command: permit.expectedCommand,
            data: permit.expectedData,
            completedAt: date(209)
        )
        let evidence = try harness.recordHistoryComplete(
            identity: issued.identity,
            metadataBytes: [0x31, 0x94, 0x03],
            terminalFence: fence(sequence: 3, at: 210),
            receivedAt: date(211)
        )
        XCTAssertEqual(evidence.durableRecordCount, 1)
        XCTAssertEqual(evidence.usableRowCount, 3)
        XCTAssertEqual(evidence.acknowledgedBoundaryCount, 1)
        XCTAssertEqual(evidence.clockRequestSequence, 0x04)
        XCTAssertEqual(evidence.historyRequestSequence, 0x05)
        XCTAssertFalse(evidence.authorizesProductionTransport)
        XCTAssertFalse(Harness.productionIntegrationEnabled)

        let reloaded = Harness(directoryURL: directory)
        XCTAssertEqual(try reloaded.loadValidatedEvidence(), evidence)
        XCTAssertEqual(try reloaded.loadEventIdentity(), issued.identity)
        XCTAssertThrowsError(try reloaded.arm(
            gate: gate(),
            request: request(),
            now: date(212)
        )) { XCTAssertEqual($0 as? Harness.HarnessError, .trialAlreadyExists) }
    }

    func testHistoryCompleteRequiresAtLeastOneUsableRow() throws {
        let harness = makeHarness()
        let issued = try armThroughBoundStart(harness)
        XCTAssertThrowsError(try harness.recordHistoryComplete(
            identity: issued.identity,
            metadataBytes: [0x31, 0x94, 0x03],
            terminalFence: fence(sequence: 1, at: 207),
            receivedAt: date(208)
        )) { XCTAssertEqual($0 as? Harness.HarnessError, .noUsableRows) }
    }

    func testArmRejectsWideOrNotAlreadyDurableTarget() {
        let harness = makeHarness()
        var wide = request()
        wide = Harness.ArmRequest(
            transportGeneration: wide.transportGeneration,
            peripheralIdentifier: wide.peripheralIdentifier,
            strapIdentity: wide.strapIdentity,
            clockRequestSequence: wide.clockRequestSequence,
            historyRequestSequence: wide.historyRequestSequence,
            startUnix: startUnix,
            endUnix: startUnix + Harness.maximumIntervalSeconds + 1,
            sourceIntervalDurabilitySHA256: wide.sourceIntervalDurabilitySHA256
        )
        XCTAssertThrowsError(try harness.arm(
            gate: gate(),
            request: wide,
            now: Date(timeIntervalSince1970: TimeInterval(wide.endUnix + 1))
        )) { XCTAssertEqual($0 as? Harness.HarnessError, .invalidRequest) }
        let missingDurability = Harness.ArmRequest(
            transportGeneration: 7,
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop4-a",
            clockRequestSequence: 0x04,
            historyRequestSequence: 0x05,
            startUnix: startUnix,
            endUnix: endUnix,
            sourceIntervalDurabilitySHA256: ""
        )
        XCTAssertThrowsError(try harness.arm(
            gate: gate(),
            request: missingDurability,
            now: date(200)
        )) { XCTAssertEqual($0 as? Harness.HarnessError, .invalidRequest) }
    }

    // MARK: - Fixtures

    private func makeHarness() -> Harness {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "atria-exact-range-trial-\(UUID().uuidString)",
            isDirectory: true
        )
        temporaryURLs.append(url)
        return Harness(directoryURL: url, makeIdentifier: { "trial-fixed" })
    }

    private func request() -> Harness.ArmRequest {
        Harness.ArmRequest(
            transportGeneration: 7,
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop4-a",
            clockRequestSequence: 0x04,
            historyRequestSequence: 0x05,
            startUnix: startUnix,
            endUnix: endUnix,
            sourceIntervalDurabilitySHA256: String(repeating: "a", count: 64)
        )
    }

    private func gate() -> Harness.ResearchGate {
        Harness.ResearchGate(
            enabled: true,
            acknowledgement: Harness.requiredAcknowledgement
        )!
    }

    private func arm(_ harness: Harness) throws -> Harness.IssuedTrial {
        try harness.arm(gate: gate(), request: request(), now: date(200))
    }

    private func armThroughHistoryWrite(
        _ harness: Harness
    ) throws -> Harness.IssuedTrial {
        let issued = try arm(harness)
        try harness.recordGETClockWriteCompleted(
            identity: issued.identity,
            instruction: issued.getClock,
            completedAt: date(201)
        )
        let exact = try harness.recordGETClockResponseAndIssueExactRange(
            identity: issued.identity,
            responseBytes: clockResponse(requestSequence: 0x04),
            receivedAt: date(202)
        )
        try harness.recordExactRangeWriteCompleted(
            identity: issued.identity,
            instruction: exact,
            completedAt: date(203)
        )
        return issued
    }

    private func armThroughBoundStart(
        _ harness: Harness
    ) throws -> Harness.IssuedTrial {
        let issued = try armThroughHistoryWrite(harness)
        try harness.recordExactRangeCommandResponse(
            identity: issued.identity,
            responseBytes: historyResponse(requestSequence: 0x05),
            receivedAt: date(204)
        )
        try harness.recordHistoryStart(
            identity: issued.identity,
            metadataBytes: historyStart(deviceUnix: 1_784_390_116),
            receivedAt: date(205)
        )
        return issued
    }

    private func date(_ offset: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(endUnix + offset))
    }

    private func clockResponse(requestSequence: UInt8) -> [UInt8] {
        [0x24, 0x90, 0x0b, requestSequence, 0x01]
            + le32(1_784_390_115)
    }

    private func historyResponse(requestSequence: UInt8) -> [UInt8] {
        [0x24, 0x91, 0x16, requestSequence, 0x01]
    }

    private func historyStart(deviceUnix: UInt32) -> [UInt8] {
        [0x31, 0x92, 0x01] + le32(deviceUnix)
    }

    private func historyEnd(token: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 21)
        bytes[0] = 0x31
        bytes[1] = 0x93
        bytes[2] = 0x02
        bytes.replaceSubrange(13..<21, with: token)
        return bytes
    }

    private func recordDurability(
        payload: [UInt8],
        sequence: UInt64,
        at offset: UInt32
    ) -> Harness.RecordDurability {
        Harness.RecordDurability(
            payloadSHA256: sha256(payload),
            rawSnapshotSHA256: String(repeating: "b", count: 64),
            identitySnapshotSHA256: String(repeating: "c", count: 64),
            rawDurableSequence: sequence,
            identityDurableSequence: sequence,
            fsyncedAtUnix: date(offset).timeIntervalSince1970
        )
    }

    private func fence(
        sequence: UInt64,
        at offset: UInt32
    ) -> Harness.DurableFence {
        Harness.DurableFence(
            rawSnapshotSHA256: String(repeating: "d", count: 64),
            identitySnapshotSHA256: String(repeating: "e", count: 64),
            rawDurableSequence: sequence,
            identityDurableSequence: sequence,
            fsyncedAtUnix: date(offset).timeIntervalSince1970
        )
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ]
    }

    private func sha256(_ bytes: [UInt8]) -> String {
        // The fixture only needs a stable valid digest; use CryptoKit through
        // the same deterministic public value generated for the known payload.
        // Importing CryptoKit here keeps the test independent of app internals.
        SHA256.hash(data: Data(bytes))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
