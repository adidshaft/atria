import XCTest
@testable import Atria

final class AtriaBLEReadOnlyHistoryCaptureTests: XCTestCase {
    func testFirewallAllowsOnlyExactAuditedCommands() {
        for opcode in UInt8.min...UInt8.max {
            let allowed = AtriaBLEReadOnlyHistoryCapturePolicy.allows(
                opcode: opcode,
                payload: [0x00]
            )
            XCTAssertEqual(allowed, [0x22, 0x16, 0x14].contains(opcode))
        }
        for opcode in [UInt8(0x22), 0x16, 0x14] {
            XCTAssertFalse(AtriaBLEReadOnlyHistoryCapturePolicy.allows(opcode: opcode,
                                                                       payload: []))
            XCTAssertFalse(AtriaBLEReadOnlyHistoryCapturePolicy.allows(opcode: opcode,
                                                                       payload: [0x00, 0x00]))
        }
        for forbidden in [UInt8(0x03), 0x0b, 0x0a, 0x17, 0x19, 0x21, 0x60, 0x61] {
            XCTAssertFalse(AtriaBLEReadOnlyHistoryCapturePolicy.allows(opcode: forbidden,
                                                                       payload: [0x00]))
        }
    }

    func testTraceAndBoundsAreFixed() {
        XCTAssertEqual(AtriaBLEReadOnlyHistoryCapturePolicy.exactTrace, [
            .init(opcode: 0x22, payload: [0x00]),
            .init(opcode: 0x16, payload: [0x00]),
            .init(opcode: 0x14, payload: [0x00]),
        ])
        XCTAssertEqual(AtriaBLEReadOnlyHistoryCapturePolicy.postRangeResponseSettle, 2)
        XCTAssertEqual(AtriaBLEReadOnlyHistoryCapturePolicy.pairingSettle, 12)
        XCTAssertEqual(AtriaBLEReadOnlyHistoryCapturePolicy.rangeWriteConfirmationTimeout, 45)
        XCTAssertEqual(AtriaBLEReadOnlyHistoryCapturePolicy.maximumCapturedFrames, 50)
    }

    func testOnlyRangeBootstrapGetsExtendedSecurityWait() {
        XCTAssertEqual(
            AtriaBLEReadOnlyHistoryCapturePolicy.writeConfirmationPollAttempts(
                opcode: 0x22,
                pollInterval: 0.1
            ),
            450
        )
        XCTAssertEqual(
            AtriaBLEReadOnlyHistoryCapturePolicy.writeConfirmationPollAttempts(
                opcode: 0x16,
                pollInterval: 0.1
            ),
            150
        )
        XCTAssertEqual(
            AtriaBLEReadOnlyHistoryCapturePolicy.writeConfirmationPollAttempts(
                opcode: 0x14,
                pollInterval: 0.1
            ),
            150
        )
    }

    func testExplicitBluetoothSecurityErrorsAreClassifiedAsSecurityRequired() {
        for code in [0x05, 0x0c, 0x0f] {
            XCTAssertEqual(
                AtriaBLEReadOnlyHistoryCapturePolicy.classifyWriteCompletion(
                    succeeded: false,
                    errorDomain: "CBATTErrorDomain",
                    errorCode: code
                ),
                .securityRequired
            )
        }
        XCTAssertEqual(
            AtriaBLEReadOnlyHistoryCapturePolicy.classifyWriteCompletion(
                succeeded: false,
                errorDomain: "CBErrorDomain",
                errorCode: 15
            ),
            .securityRequired
        )
    }

    func testAmbiguousAndUnrelatedWriteFailuresDoNotAuthorizeRetry() {
        let failures: [(String?, Int?)] = [
            (nil, nil),
            ("CBATTErrorDomain", 0x03),
            ("CBErrorDomain", 6),
            ("NSPOSIXErrorDomain", 15),
        ]
        for (domain, code) in failures {
            let result = AtriaBLEReadOnlyHistoryCapturePolicy.classifyWriteCompletion(
                succeeded: false,
                errorDomain: domain,
                errorCode: code
            )
            XCTAssertEqual(result, .failed)
            XCTAssertFalse(
                AtriaBLEReadOnlyHistoryCapturePolicy.permitsRangeRetry(
                    after: result,
                    retriesAlreadyIssued: 0
                )
            )
        }
        XCTAssertEqual(
            AtriaBLEReadOnlyHistoryCapturePolicy.classifyWriteCompletion(
                succeeded: true,
                errorDomain: nil,
                errorCode: nil
            ),
            .confirmed
        )
    }

    func testRangeRetryIsSingleShotAndRequiresExplicitSecurityFailure() {
        XCTAssertTrue(
            AtriaBLEReadOnlyHistoryCapturePolicy.permitsRangeRetry(
                after: .securityRequired,
                retriesAlreadyIssued: 0
            )
        )
        XCTAssertFalse(
            AtriaBLEReadOnlyHistoryCapturePolicy.permitsRangeRetry(
                after: .securityRequired,
                retriesAlreadyIssued: 1
            )
        )
        for result in [
            AtriaBLEReadOnlyHistoryCapturePolicy.WriteConfirmationResult.failed,
            .timedOut,
            .interrupted,
            .confirmed,
        ] {
            XCTAssertFalse(
                AtriaBLEReadOnlyHistoryCapturePolicy.permitsRangeRetry(
                    after: result,
                    retriesAlreadyIssued: 0
                )
            )
        }
    }

    func testAbortRequiresConfirmedServeOrObservedHistoryStart() {
        XCTAssertFalse(
            AtriaBLEReadOnlyHistoryCapturePolicy.shouldIssueAbort(
                serveWriteConfirmed: false,
                historyStarted: false
            )
        )
        XCTAssertTrue(
            AtriaBLEReadOnlyHistoryCapturePolicy.shouldIssueAbort(
                serveWriteConfirmed: true,
                historyStarted: false
            )
        )
        XCTAssertTrue(
            AtriaBLEReadOnlyHistoryCapturePolicy.shouldIssueAbort(
                serveWriteConfirmed: false,
                historyStarted: true
            )
        )
    }

    func testActiveCaptureOwnsRawFramesBeforeProductionParsedUpdates() throws {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)
        let applyStart = try XCTUnwrap(source.range(
            of: "private func applyOrderedProprietaryCallbackBatch"
        ))
        let applyEnd = try XCTUnwrap(source.range(
            of: "private func persistBatteryLevel",
            range: applyStart.upperBound..<source.endIndex
        ))
        let body = String(source[applyStart.lowerBound..<applyEnd.lowerBound])
        let captureRoute = try XCTUnwrap(body.range(
            of: "if readOnlyHistoryCaptureActive"
        ))
        let parsedRoute = try XCTUnwrap(body.range(
            of: "if let parsedProprietaryUpdate"
        ))
        XCTAssertLessThan(captureRoute.lowerBound, parsedRoute.lowerBound)
        let captureBody = String(body[captureRoute.lowerBound..<parsedRoute.lowerBound])
        XCTAssertTrue(captureBody.contains("handleProprietary("))
        XCTAssertTrue(captureBody.contains("continue"))
    }
}
