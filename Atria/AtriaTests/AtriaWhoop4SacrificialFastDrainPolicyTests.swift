import XCTest
@testable import Atria

final class AtriaWhoop4SacrificialFastDrainPolicyTests: XCTestCase {
    private typealias Policy = AtriaWhoop4SacrificialFastDrainPolicy
    private let runID = "D02D8895-B035-48E9-AC23-3CEAA32FDAC2"

    func testLaunchRequiresEveryExplicitArgumentAndOneValidRunID() throws {
        XCTAssertThrowsError(try Policy.authorizeLaunch(arguments: [])) {
            XCTAssertEqual($0 as? Policy.AuthorizationError, .modeMissing)
        }
        XCTAssertThrowsError(try Policy.authorizeLaunch(arguments: [
            Policy.modeArgument,
            Policy.runIDArgument,
            runID,
        ])) {
            XCTAssertEqual($0 as? Policy.AuthorizationError, .confirmationMissing)
        }
        XCTAssertThrowsError(try Policy.authorizeLaunch(arguments: [
            Policy.modeArgument,
            Policy.confirmationArgument,
        ])) {
            XCTAssertEqual($0 as? Policy.AuthorizationError, .runIDMissing)
        }
        XCTAssertThrowsError(try Policy.authorizeLaunch(arguments: [
            Policy.modeArgument,
            Policy.confirmationArgument,
            Policy.runIDArgument,
            "not-a-uuid",
        ])) {
            XCTAssertEqual($0 as? Policy.AuthorizationError, .malformedRunID)
        }
        XCTAssertThrowsError(try Policy.authorizeLaunch(arguments: [
            Policy.modeArgument,
            Policy.confirmationArgument,
            Policy.runIDArgument,
            runID,
            Policy.runIDArgument,
            "3C1B6AAC-AFB7-41A7-8E7A-51FC478C3472",
        ])) {
            XCTAssertEqual($0 as? Policy.AuthorizationError, .runIDRepeated)
        }

        let authorization = try authorization()
        XCTAssertEqual(authorization.runID.uuidString, runID)
    }

    func testExactPreflightServeRepeatedACKAndPostflightTrace() throws {
        var session = Policy.Session(authorization: try authorization())
        XCTAssertEqual(session.phase, .preflight)

        try session.authorize(Policy.getDataRange)
        XCTAssertEqual(session.phase, .serve)
        try session.authorize(Policy.sendHistorical)
        XCTAssertEqual(session.phase, .streaming)

        let first = [UInt8](1...8)
        try session.recordMetadata(historyEnd(sequence: 3, token: first))
        try session.authorize(.init(opcode: 0x17, payload: [0x01] + first))
        XCTAssertEqual(session.phase, .streaming)

        let second = [UInt8](11...18)
        try session.recordMetadata(historyEnd(sequence: 4, token: second))
        try session.authorize(.init(opcode: 0x17, payload: [0x01] + second))

        try session.recordMetadata(historyComplete(sequence: 5))
        XCTAssertEqual(session.phase, .postflight)
        try session.authorize(Policy.getDataRange)
        XCTAssertEqual(session.phase, .complete)

        XCTAssertThrowsError(try session.authorize(Policy.getDataRange)) {
            XCTAssertEqual($0 as? Policy.PolicyError, .runAlreadyComplete)
        }
    }

    func testArbitraryFabricatedAndReplayedACKTokensAreRejected() throws {
        var session = try streamingSession()
        let token = [UInt8](21...28)
        try session.recordMetadata(historyEnd(sequence: 8, token: token))

        for command in [
            Policy.Command(opcode: 0x17, payload: token),
            Policy.Command(opcode: 0x17, payload: [0x00] + token),
            Policy.Command(opcode: 0x17, payload: [0x01] + Array(repeating: 7, count: 8)),
            Policy.Command(opcode: 0x17, payload: [0x01] + token + [0x00]),
        ] {
            XCTAssertThrowsError(try session.authorize(command)) {
                XCTAssertEqual(
                    $0 as? Policy.PolicyError,
                    .commandRejected(phase: .streaming)
                )
            }
        }

        let exact = Policy.Command(opcode: 0x17, payload: [0x01] + token)
        try session.authorize(exact)
        XCTAssertThrowsError(try session.authorize(exact)) {
            XCTAssertEqual(
                $0 as? Policy.PolicyError,
                .commandRejected(phase: .streaming)
            )
        }
        XCTAssertThrowsError(
            try session.recordMetadata(historyEnd(sequence: 9, token: token))
        ) {
            XCTAssertEqual($0 as? Policy.PolicyError, .tokenAlreadyConsumed)
        }
    }

    func testMalformedOrOverlappingMetadataCannotMintOrReplaceACK() throws {
        var session = try streamingSession()
        XCTAssertThrowsError(try session.recordMetadata([0x31, 0x01, 0x02])) {
            XCTAssertEqual(
                $0 as? Policy.PolicyError,
                .metadataRejected(phase: .streaming)
            )
        }
        XCTAssertThrowsError(try session.authorize(.init(
            opcode: 0x17,
            payload: [0x01] + Array(repeating: 0, count: 8)
        )))

        let first = [UInt8](31...38)
        try session.recordMetadata(historyEnd(sequence: 1, token: first))
        XCTAssertThrowsError(
            try session.recordMetadata(historyEnd(
                sequence: 2,
                token: [UInt8](41...48)
            ))
        ) {
            XCTAssertEqual(
                $0 as? Policy.PolicyError,
                .acknowledgementAlreadyPending
            )
        }
        XCTAssertThrowsError(
            try session.recordMetadata(historyComplete(sequence: 3))
        ) {
            XCTAssertEqual(
                $0 as? Policy.PolicyError,
                .historyCompleteBeforeAcknowledgement
            )
        }
    }

    func testOtherOpcodesAndWrongPayloadsAreRejectedInEveryCommandPhase() throws {
        let forbidden: [Policy.Command] = [
            .init(opcode: 0x03, payload: [0x00]),
            .init(opcode: 0x19, payload: Array(repeating: 0xFE, count: 8)),
            .init(opcode: 0x1D, payload: [0x00]),
            .init(opcode: 0x20, payload: [0x00]),
            .init(opcode: 0x21, payload: [0x00]),
            .init(opcode: 0x60, payload: [0x00]),
            .init(opcode: 0x22, payload: []),
            .init(opcode: 0x16, payload: []),
            .init(opcode: 0x14, payload: []),
        ]

        for command in forbidden {
            var preflight = Policy.Session(authorization: try authorization())
            XCTAssertThrowsError(try preflight.authorize(command))

            var serve = Policy.Session(authorization: try authorization())
            try serve.authorize(Policy.getDataRange)
            XCTAssertThrowsError(try serve.authorize(command))

            var streaming = try streamingSession()
            XCTAssertThrowsError(try streaming.authorize(command))

            var postflight = try postflightSession()
            XCTAssertThrowsError(try postflight.authorize(command))
        }
    }

    func testAbortRequiresAnActuallyExpiredBoundedTimeout() throws {
        var session = try streamingSession()
        XCTAssertThrowsError(try session.authorize(Policy.abort)) {
            XCTAssertEqual(
                $0 as? Policy.PolicyError,
                .commandRejected(phase: .streaming)
            )
        }
        XCTAssertThrowsError(
            try session.recordBoundedTimeout(elapsed: 9.9, limit: 10)
        ) {
            XCTAssertEqual($0 as? Policy.PolicyError, .abortTimeoutNotExpired)
        }
        for invalidLimit in [0, -1, Policy.maximumAbortTimeout + 1] {
            XCTAssertThrowsError(
                try session.recordBoundedTimeout(
                    elapsed: Policy.maximumAbortTimeout + 1,
                    limit: invalidLimit
                )
            ) {
                XCTAssertEqual($0 as? Policy.PolicyError, .invalidAbortTimeout)
            }
        }

        try session.recordBoundedTimeout(elapsed: 10, limit: 10)
        XCTAssertEqual(session.phase, .abortReady)
        XCTAssertThrowsError(try session.authorize(Policy.getDataRange))
        try session.authorize(Policy.abort)
        XCTAssertEqual(session.phase, .complete)
    }

    func testCursorCollapseAcceptsAtMostTwoRecordingRaceRows() {
        let preflight = Policy.CursorObservation(
            writeCursor: 90_000,
            readCursor: 1_000,
            pendingRecords: 89_000
        )
        XCTAssertTrue(Policy.hasAcceptableCursorCollapse(
            preflight: preflight,
            postflight: .init(
                writeCursor: 90_000,
                readCursor: 90_000,
                pendingRecords: 0
            )
        ))
        XCTAssertTrue(Policy.hasAcceptableCursorCollapse(
            preflight: preflight,
            postflight: .init(
                writeCursor: 90_002,
                readCursor: 90_000,
                pendingRecords: 2
            )
        ))
        XCTAssertFalse(Policy.hasAcceptableCursorCollapse(
            preflight: preflight,
            postflight: .init(
                writeCursor: 90_003,
                readCursor: 90_000,
                pendingRecords: 3
            )
        ))
        XCTAssertFalse(Policy.hasAcceptableCursorCollapse(
            preflight: preflight,
            postflight: .init(
                writeCursor: 90_000,
                readCursor: 89_999,
                pendingRecords: 0
            )
        ))
        XCTAssertFalse(Policy.hasAcceptableCursorCollapse(
            preflight: .init(
                writeCursor: 2,
                readCursor: 0,
                pendingRecords: 2
            ),
            postflight: .init(
                writeCursor: 2,
                readCursor: 2,
                pendingRecords: 0
            )
        ))
    }

    private func authorization() throws -> Policy.Authorization {
        try Policy.authorizeLaunch(arguments: [
            "Atria",
            Policy.modeArgument,
            Policy.confirmationArgument,
            Policy.runIDArgument,
            runID,
        ])
    }

    private func streamingSession() throws -> Policy.Session {
        var session = Policy.Session(authorization: try authorization())
        try session.authorize(Policy.getDataRange)
        try session.authorize(Policy.sendHistorical)
        return session
    }

    private func postflightSession() throws -> Policy.Session {
        var session = try streamingSession()
        try session.recordMetadata(historyComplete(sequence: 1))
        return session
    }

    private func historyEnd(sequence: UInt8, token: [UInt8]) -> [UInt8] {
        precondition(token.count == 8)
        var bytes = Array(repeating: UInt8(0), count: 21)
        bytes[0] = 0x31
        bytes[1] = sequence
        bytes[2] = 0x02
        bytes.replaceSubrange(13..<21, with: token)
        return bytes
    }

    private func historyComplete(sequence: UInt8) -> [UInt8] {
        [0x31, sequence, 0x03]
    }
}
