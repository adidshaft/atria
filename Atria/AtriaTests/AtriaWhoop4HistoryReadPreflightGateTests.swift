import XCTest
@testable import Atria

final class AtriaWhoop4HistoryReadPreflightGateTests: XCTestCase {
    private let identity = AtriaWhoop4HistoryReadPreflightGate.Identity(
        generation: 7,
        commandSequence: 42
    )

    func testRequiresGATTAndMatchingLogicalResponse() {
        var gate = AtriaWhoop4HistoryReadPreflightGate()
        XCTAssertTrue(gate.arm(identity))
        XCTAssertEqual(
            gate.completeGATT(generation: 7, commandSequence: 42, succeeded: true),
            .awaitingLogicalResponse(identity)
        )
        XCTAssertEqual(
            gate.receiveCommandResponse(
                [0x24, 0x91, 0x0B, 42, 0x01, 0, 0, 0, 0],
                generation: 7
            ),
            .accepted(identity)
        )
    }

    func testStaleResponseCannotAuthorizeCurrentGeneration() {
        var gate = AtriaWhoop4HistoryReadPreflightGate()
        XCTAssertTrue(gate.arm(identity))
        _ = gate.completeGATT(generation: 7, commandSequence: 42, succeeded: true)

        XCTAssertEqual(
            gate.receiveCommandResponse(
                [0x24, 0x90, 0x0B, 41, 0x01, 0, 0, 0, 0],
                generation: 7
            ),
            .ignored
        )
        XCTAssertEqual(gate.identity, identity)
        XCTAssertEqual(gate.timeout(identity), .failed(identity))
    }

    func testGATTSuccessAloneTimesOutAndMalformedStatusFails() {
        var gate = AtriaWhoop4HistoryReadPreflightGate()
        XCTAssertTrue(gate.arm(identity))
        _ = gate.completeGATT(generation: 7, commandSequence: 42, succeeded: true)
        XCTAssertEqual(gate.timeout(identity), .failed(identity))

        XCTAssertTrue(gate.arm(identity))
        _ = gate.completeGATT(generation: 7, commandSequence: 42, succeeded: true)
        XCTAssertEqual(
            gate.receiveCommandResponse(
                [0x24, 0x91, 0x0B, 42, 0x00, 0, 0, 0, 0],
                generation: 7
            ),
            .failed(identity)
        )
    }

    func testCannotDoubleArmAndBuffersExactResponseBeforeGATTConfirmation() {
        var gate = AtriaWhoop4HistoryReadPreflightGate()
        XCTAssertTrue(gate.arm(identity))
        XCTAssertFalse(gate.arm(.init(generation: 7, commandSequence: 43)))
        XCTAssertEqual(
            gate.receiveCommandResponse(
                [0x24, 0x91, 0x0B, 42, 0x01, 0, 0, 0, 0],
                generation: 7
            ),
            .awaitingGATTConfirmation(identity)
        )
        XCTAssertEqual(gate.identity, identity)
        XCTAssertEqual(
            gate.completeGATT(generation: 7, commandSequence: 42, succeeded: true),
            .accepted(identity)
        )
        XCTAssertNil(gate.identity)
    }

    func testBufferedExactResponseCannotOverrideFailedGATTWrite() {
        var gate = AtriaWhoop4HistoryReadPreflightGate()
        XCTAssertTrue(gate.arm(identity))
        XCTAssertEqual(
            gate.receiveCommandResponse(
                [0x24, 0x91, 0x0B, 42, 0x01, 0, 0, 0, 0],
                generation: 7
            ),
            .awaitingGATTConfirmation(identity)
        )
        XCTAssertEqual(
            gate.completeGATT(generation: 7, commandSequence: 42, succeeded: false),
            .failed(identity)
        )
        XCTAssertNil(gate.identity)
    }

    func testStaleEchoBeforeGATTDoesNotSatisfyCurrentPreflight() {
        var gate = AtriaWhoop4HistoryReadPreflightGate()
        XCTAssertTrue(gate.arm(identity))
        XCTAssertEqual(
            gate.receiveCommandResponse(
                [0x24, 0x90, 0x0B, 41, 0x01, 0, 0, 0, 0],
                generation: 7
            ),
            .ignored
        )
        XCTAssertEqual(
            gate.completeGATT(generation: 7, commandSequence: 42, succeeded: true),
            .awaitingLogicalResponse(identity)
        )
    }

    func testProductionIntegrationIsSingleReadOnlyCommandBetweenRangeAndDrain() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let managerURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let manager = try String(contentsOf: managerURL, encoding: .utf8)

        let rangeSettle = try XCTUnwrap(manager.range(
            of: "historyRange status=post_response_settle_confirmed"
        )?.lowerBound)
        let drainLoop = try XCTUnwrap(manager.range(
            of: "if !historyInitSweepCommands.isEmpty {",
            range: rangeSettle..<manager.endIndex
        )?.lowerBound)
        let handoff = String(manager[rangeSettle..<drainLoop])
        XCTAssertEqual(
            handoff.components(separatedBy: "performProductionHistoryReadPreflight(").count - 1,
            1
        )

        let preflightStart = try XCTUnwrap(manager.range(
            of: "private func performProductionHistoryReadPreflight("
        )?.lowerBound)
        let responseStart = try XCTUnwrap(manager.range(
            of: "private func handleProductionHistoryReadPreflightResponse(",
            range: preflightStart..<manager.endIndex
        )?.lowerBound)
        let preflight = String(manager[preflightStart..<responseStart])
        XCTAssertEqual(
            preflight.components(separatedBy: "sendCommand(Cmd.getClock, [0x00], mode: .withResponse)").count - 1,
            1
        )
        XCTAssertTrue(preflight.contains("historyReadPreflightGate.arm(identity)"))
        XCTAssertTrue(preflight.contains("acceptedHistoryReadPreflightIdentity == identity"))
        XCTAssertFalse(preflight.contains("Cmd.toggleRealtimeHR"))
        XCTAssertFalse(preflight.contains("Cmd.setClock"))
        XCTAssertFalse(preflight.contains("Cmd.abortHistoricalTransmits"))
        XCTAssertFalse(preflight.contains("setNotifyValue"))
    }
}
