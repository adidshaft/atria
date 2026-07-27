import XCTest
@testable import Atria

final class AtriaWhoop4SacrificialHistoryTrimPolicyTests: XCTestCase {
    private typealias Policy = AtriaWhoop4SacrificialHistoryTrimPolicy
    private let runID = "4B137B08-105A-491E-8246-EA32348AFF5C"

    func testLaunchRequiresModeConfirmationAndValidUniqueRunID() throws {
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
            "60567EE7-EE9B-4F93-B1BC-C13C44CD3644",
        ])) {
            XCTAssertEqual($0 as? Policy.AuthorizationError, .runIDRepeated)
        }

        let authorization = try Policy.authorizeLaunch(arguments: [
            "Atria",
            Policy.modeArgument,
            Policy.confirmationArgument,
            Policy.runIDArgument,
            runID,
        ])
        XCTAssertEqual(authorization.runID.uuidString, runID)
    }

    func testExactOneShotTraceIsTheOnlyAllowedPhaseProgression() throws {
        XCTAssertEqual(
            try Policy.authorize(command: Policy.getDataRange, in: .preflight),
            .trim
        )
        XCTAssertEqual(
            try Policy.authorize(command: Policy.forceTrim, in: .trim),
            .postflight
        )
        XCTAssertEqual(
            try Policy.authorize(command: Policy.getDataRange, in: .postflight),
            .complete
        )

        XCTAssertThrowsError(
            try Policy.authorize(command: Policy.forceTrim, in: .complete)
        ) {
            XCTAssertEqual($0 as? Policy.CommandError, .runAlreadyComplete)
        }
    }

    func testAllOtherOpcodesAndWrongPayloadsAreRejected() {
        let forbiddenOpcodes: [UInt8] = [
            0x14, // abort
            0x16, // send historical
            0x17, // history ACK
            0x1D, // reboot
            0x20, // clock
            0x21, // read pointer
            0x31, // mode/config example
        ]
        for opcode in forbiddenOpcodes {
            XCTAssertThrowsError(try Policy.authorize(
                command: .init(opcode: opcode, payload: [0x00]),
                in: .preflight
            ))
            XCTAssertThrowsError(try Policy.authorize(
                command: .init(opcode: opcode, payload: [0x00]),
                in: .trim
            ))
            XCTAssertThrowsError(try Policy.authorize(
                command: .init(opcode: opcode, payload: [0x00]),
                in: .postflight
            ))
        }

        for wrong in [
            Policy.Command(opcode: 0x22, payload: []),
            Policy.Command(opcode: 0x22, payload: [0x01]),
            Policy.Command(opcode: 0x19, payload: []),
            Policy.Command(opcode: 0x19, payload: Array(repeating: 0xFE, count: 7)),
            // This is the previously attempted, one-byte-short form.
            Policy.Command(opcode: 0x19, payload: Array(repeating: 0xFE, count: 8)),
            Policy.Command(opcode: 0x19, payload: Array(repeating: 0xFE, count: 9)),
            Policy.Command(opcode: 0x19, payload: Array(repeating: 0xFF, count: 8) + [0x00]),
            Policy.Command(opcode: 0x19, payload: Array(repeating: 0xFE, count: 8) + [0x01]),
        ] {
            XCTAssertThrowsError(try Policy.authorize(command: wrong, in: .trim))
        }

        XCTAssertThrowsError(
            try Policy.authorize(command: Policy.forceTrim, in: .preflight)
        )
        XCTAssertThrowsError(
            try Policy.authorize(command: Policy.getDataRange, in: .trim)
        )
        XCTAssertThrowsError(
            try Policy.authorize(command: Policy.forceTrim, in: .postflight)
        )
    }

    func testPostconditionAcceptsExactEmptyOrTinyRecordingRaceAfterMaterialCollapse() {
        let preflight = Policy.CursorObservation(
            writeCursor: 50_000,
            readCursor: 10_000,
            pendingRecords: 40_000
        )
        let exact = Policy.CursorObservation(
            writeCursor: 50_000,
            readCursor: 50_000,
            pendingRecords: 0
        )
        let oneNewRecord = Policy.CursorObservation(
            writeCursor: 50_001,
            readCursor: 50_000,
            pendingRecords: 1
        )

        XCTAssertTrue(Policy.isExactlyEmpty(exact))
        XCTAssertTrue(Policy.hasAcceptablePostTrimCollapse(
            preflight: preflight,
            postflight: exact
        ))
        XCTAssertTrue(Policy.hasAcceptablePostTrimCollapse(
            preflight: preflight,
            postflight: oneNewRecord
        ))
    }

    func testPostconditionRejectsUncollapsedInconsistentOrLargeResidualBacklog() {
        let preflight = Policy.CursorObservation(
            writeCursor: 100,
            readCursor: 90,
            pendingRecords: 10
        )
        XCTAssertFalse(Policy.hasAcceptablePostTrimCollapse(
            preflight: preflight,
            postflight: .init(writeCursor: 100, readCursor: 90, pendingRecords: 10)
        ))
        XCTAssertFalse(Policy.hasAcceptablePostTrimCollapse(
            preflight: preflight,
            postflight: .init(writeCursor: 103, readCursor: 100, pendingRecords: 3)
        ))
        XCTAssertFalse(Policy.hasAcceptablePostTrimCollapse(
            preflight: preflight,
            postflight: .init(writeCursor: 100, readCursor: 99, pendingRecords: 0)
        ))
        XCTAssertFalse(Policy.hasAcceptablePostTrimCollapse(
            preflight: .init(writeCursor: 2, readCursor: 0, pendingRecords: 2),
            postflight: .init(writeCursor: 2, readCursor: 2, pendingRecords: 0)
        ))
    }
}
