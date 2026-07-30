import XCTest
@testable import Atria

final class AtriaWhoop4DailyMotionBankRearmPolicyTests: XCTestCase {
    private typealias Policy = AtriaWhoop4DailyMotionBankRearmPolicy

    private let identity = Policy.Identity(
        generation: 41,
        ticketID: "BAE8B048-B389-40CC-B1FC-4DFB6F68C568|10000|10100",
        strapIdentifier: UUID(
            uuidString: "BAE8B048-B389-40CC-B1FC-4DFB6F68C568"
        )!,
        callbackEpoch: 73,
        connectionStartedAt: Date(timeIntervalSince1970: 10_200)
    )

    func testFullyAuthorizedStateSendsOnlyExactMotionBankRearm() {
        XCTAssertEqual(
            Policy.evaluate(validInput()),
            .send(.init(opcode: 0x69, payload: [0x01]))
        )
    }

    func testPolicyAndNestedInputsAreSendable() {
        assertSendable(Policy.self)
        assertSendable(Policy.Input.self)
        assertSendable(Policy.Decision.self)
        assertSendable(Policy.Identity.self)
    }

    func testActiveHistoryMustExistAndMatchEveryIdentityField() {
        var input = validInput()
        input = replacing(input, activeHistoryIdentity: .some(nil))
        XCTAssertEqual(
            Policy.evaluate(input),
            .cancel(.activeHistoryMissing)
        )

        assertEveryIdentityMismatch(stage: .activeHistory) { mismatch in
            self.replacing(self.validInput(), activeHistoryIdentity: mismatch)
        }
    }

    func testServeMustBeExactConfirmedSixteenZeroForSameIdentity() {
        var input = validInput()
        input = replacing(input, confirmedHistoryServe: .some(nil))
        XCTAssertEqual(
            Policy.evaluate(input),
            .cancel(.attestationMissing(.historyServe))
        )

        assertEveryIdentityMismatch(stage: .historyServe) { mismatch in
            self.replacing(
                self.validInput(),
                confirmedHistoryServe: .init(
                    identity: mismatch,
                    command: Policy.historyServeCommand,
                    writeConfirmed: true
                )
            )
        }

        for wrongCommand in [
            Policy.Command(opcode: 0x16, payload: []),
            Policy.Command(opcode: 0x16, payload: [0x01]),
            Policy.Command(opcode: 0x69, payload: [0x01]),
        ] {
            input = replacing(
                validInput(),
                confirmedHistoryServe: .init(
                    identity: identity,
                    command: wrongCommand,
                    writeConfirmed: true
                )
            )
            XCTAssertEqual(
                Policy.evaluate(input),
                .cancel(.historyServeCommandMismatch)
            )
        }

        input = replacing(
            validInput(),
            confirmedHistoryServe: .init(
                identity: identity,
                command: Policy.historyServeCommand,
                writeConfirmed: false
            )
        )
        XCTAssertEqual(
            Policy.evaluate(input),
            .cancel(.historyServeWriteUnconfirmed)
        )
    }

    func testHistoryStartAndFullDrainAuthorityMustExistAndMatch() {
        var input = replacing(
            validInput(),
            acceptedHistoryStart: .some(nil)
        )
        XCTAssertEqual(
            Policy.evaluate(input),
            .cancel(.attestationMissing(.historyStart))
        )
        assertEveryIdentityMismatch(stage: .historyStart) { mismatch in
            self.replacing(
                self.validInput(),
                acceptedHistoryStart: .init(identity: mismatch)
            )
        }

        input = replacing(validInput(), fullDrainAuthority: .some(nil))
        XCTAssertEqual(
            Policy.evaluate(input),
            .cancel(.attestationMissing(.fullDrainAuthority))
        )
        assertEveryIdentityMismatch(stage: .fullDrainAuthority) { mismatch in
            self.replacing(
                self.validInput(),
                fullDrainAuthority: .init(identity: mismatch)
            )
        }
    }

    func testAnyAcceptedTerminalCancelsAndStaleTerminalCannotContaminate() {
        var input = replacing(
            validInput(),
            acceptedTerminal: .init(identity: identity)
        )
        XCTAssertEqual(
            Policy.evaluate(input),
            .cancel(.terminalObserved)
        )

        assertEveryIdentityMismatch(stage: .terminal) { mismatch in
            self.replacing(
                self.validInput(),
                acceptedTerminal: .init(identity: mismatch)
            )
        }
    }

    func testEveryOperatingBlockerCancelsRatherThanWaiting() {
        let cases: [(Policy.OperatingState, Policy.CancelReason)] = [
            (
                .init(
                    batteryAllowsRearm: false,
                    manualWorkoutActive: false,
                    calibrationHoldActive: false,
                    stopPending: false,
                    cutoverActive: false
                ),
                .batteryBlocked
            ),
            (
                .init(
                    batteryAllowsRearm: true,
                    manualWorkoutActive: true,
                    calibrationHoldActive: false,
                    stopPending: false,
                    cutoverActive: false
                ),
                .manualWorkoutActive
            ),
            (
                .init(
                    batteryAllowsRearm: true,
                    manualWorkoutActive: false,
                    calibrationHoldActive: true,
                    stopPending: false,
                    cutoverActive: false
                ),
                .calibrationHoldActive
            ),
            (
                .init(
                    batteryAllowsRearm: true,
                    manualWorkoutActive: false,
                    calibrationHoldActive: false,
                    stopPending: true,
                    cutoverActive: false
                ),
                .stopPending
            ),
            (
                .init(
                    batteryAllowsRearm: true,
                    manualWorkoutActive: false,
                    calibrationHoldActive: false,
                    stopPending: false,
                    cutoverActive: true
                ),
                .cutoverActive
            ),
        ]

        for (state, reason) in cases {
            XCTAssertEqual(
                Policy.evaluate(replacing(validInput(), operatingState: state)),
                .cancel(reason)
            )
        }
    }

    func testCapabilityAndWriteSupportArePermanentRequirements() {
        var input = replacing(
            validInput(),
            writeWithoutResponse: .init(supported: false, ready: true)
        )
        XCTAssertEqual(
            Policy.evaluate(input),
            .cancel(.writeWithoutResponseUnsupported)
        )

        input = replacing(validInput(), verifiedCapability: .some(nil))
        XCTAssertEqual(
            Policy.evaluate(input),
            .cancel(.attestationMissing(.capability))
        )
        assertEveryIdentityMismatch(stage: .capability) { mismatch in
            self.replacing(
                self.validInput(),
                verifiedCapability: .init(identity: mismatch)
            )
        }
    }

    func testAcceptedHRMustMatchAndBeFresh() {
        var input = replacing(validInput(), acceptedHeartRate: .some(nil))
        XCTAssertEqual(
            Policy.evaluate(input),
            .defer(.acceptedHeartRateUnavailable)
        )

        assertEveryIdentityMismatch(stage: .acceptedHeartRate) { mismatch in
            self.replacing(
                self.validInput(),
                acceptedHeartRate: .init(identity: mismatch, age: 1)
            )
        }

        for invalidAge in [
            -0.001,
            TimeInterval.infinity,
            -TimeInterval.infinity,
            TimeInterval.nan,
        ] {
            input = replacing(
                validInput(),
                acceptedHeartRate: .init(
                    identity: identity,
                    age: invalidAge
                )
            )
            XCTAssertEqual(
                Policy.evaluate(input),
                .cancel(.invalidAcceptedHRAge)
            )
        }

        input = replacing(
            validInput(),
            acceptedHeartRate: .init(
                identity: identity,
                age: Policy.maximumAcceptedHRAge.nextUp
            )
        )
        XCTAssertEqual(
            Policy.evaluate(input),
            .defer(.acceptedHeartRateStale)
        )

        input = replacing(
            validInput(),
            acceptedHeartRate: .init(
                identity: identity,
                age: Policy.maximumAcceptedHRAge
            )
        )
        XCTAssertEqual(Policy.evaluate(input), .send(Policy.command))
    }

    func testEveryTransientCommandPipePressureDefersIndependently() {
        let cases: [(Policy.CommandPipe, Policy.DeferReason)] = [
            (
                pipe(withResponseWritePending: true),
                .withResponseWritePending
            ),
            (
                pipe(historyACKGatePending: true),
                .historyACKGatePending
            ),
            (
                pipe(replayACKPending: true),
                .replayACKPending
            ),
            (
                pipe(continuationPending: true),
                .continuationPending
            ),
            (
                pipe(durableFlushPending: true),
                .durableFlushPending
            ),
            (
                pipe(ingressBarrierPending: true),
                .ingressBarrierPending
            ),
        ]

        for (pipe, reason) in cases {
            XCTAssertEqual(
                Policy.evaluate(replacing(validInput(), commandPipe: pipe)),
                .defer(reason)
            )
        }
    }

    func testWriteWithoutResponseBackpressureDefers() {
        XCTAssertEqual(
            Policy.evaluate(replacing(
                validInput(),
                writeWithoutResponse: .init(supported: true, ready: false)
            )),
            .defer(.writeWithoutResponseNotReady)
        )
    }

    func testPermanentFailureWinsOverTransientPressure() {
        let input = replacing(
            replacing(
                validInput(),
                commandPipe: pipe(withResponseWritePending: true)
            ),
            operatingState: .init(
                batteryAllowsRearm: true,
                manualWorkoutActive: false,
                calibrationHoldActive: false,
                stopPending: true,
                cutoverActive: false
            )
        )
        XCTAssertEqual(Policy.evaluate(input), .cancel(.stopPending))
    }

    private func validInput() -> Policy.Input {
        .init(
            expectedIdentity: identity,
            activeHistoryIdentity: identity,
            confirmedHistoryServe: .init(
                identity: identity,
                command: Policy.historyServeCommand,
                writeConfirmed: true
            ),
            acceptedHistoryStart: .init(identity: identity),
            fullDrainAuthority: .init(identity: identity),
            acceptedTerminal: nil,
            acceptedHeartRate: .init(identity: identity, age: 1),
            operatingState: .init(
                batteryAllowsRearm: true,
                manualWorkoutActive: false,
                calibrationHoldActive: false,
                stopPending: false,
                cutoverActive: false
            ),
            commandPipe: pipe(),
            writeWithoutResponse: .init(supported: true, ready: true),
            verifiedCapability: .init(identity: identity)
        )
    }

    private func replacing(
        _ input: Policy.Input,
        activeHistoryIdentity: Policy.Identity?? = nil,
        confirmedHistoryServe: Policy.ConfirmedCommand?? = nil,
        acceptedHistoryStart: Policy.Attestation?? = nil,
        fullDrainAuthority: Policy.Attestation?? = nil,
        acceptedTerminal: Policy.Attestation?? = nil,
        acceptedHeartRate: Policy.AcceptedHeartRate?? = nil,
        operatingState: Policy.OperatingState? = nil,
        commandPipe: Policy.CommandPipe? = nil,
        writeWithoutResponse: Policy.WriteWithoutResponseState? = nil,
        verifiedCapability: Policy.Attestation?? = nil
    ) -> Policy.Input {
        .init(
            expectedIdentity: input.expectedIdentity,
            activeHistoryIdentity:
                activeHistoryIdentity ?? input.activeHistoryIdentity,
            confirmedHistoryServe:
                confirmedHistoryServe ?? input.confirmedHistoryServe,
            acceptedHistoryStart:
                acceptedHistoryStart ?? input.acceptedHistoryStart,
            fullDrainAuthority:
                fullDrainAuthority ?? input.fullDrainAuthority,
            acceptedTerminal: acceptedTerminal ?? input.acceptedTerminal,
            acceptedHeartRate:
                acceptedHeartRate ?? input.acceptedHeartRate,
            operatingState: operatingState ?? input.operatingState,
            commandPipe: commandPipe ?? input.commandPipe,
            writeWithoutResponse:
                writeWithoutResponse ?? input.writeWithoutResponse,
            verifiedCapability:
                verifiedCapability ?? input.verifiedCapability
        )
    }

    private func pipe(
        withResponseWritePending: Bool = false,
        historyACKGatePending: Bool = false,
        replayACKPending: Bool = false,
        continuationPending: Bool = false,
        durableFlushPending: Bool = false,
        ingressBarrierPending: Bool = false
    ) -> Policy.CommandPipe {
        .init(
            withResponseWritePending: withResponseWritePending,
            historyACKGatePending: historyACKGatePending,
            replayACKPending: replayACKPending,
            continuationPending: continuationPending,
            durableFlushPending: durableFlushPending,
            ingressBarrierPending: ingressBarrierPending
        )
    }

    private func assertEveryIdentityMismatch(
        stage: Policy.IdentityStage,
        file: StaticString = #filePath,
        line: UInt = #line,
        makeInput: (Policy.Identity) -> Policy.Input
    ) {
        for (mismatch, field) in mismatchedIdentities() {
            XCTAssertEqual(
                Policy.evaluate(makeInput(mismatch)),
                .cancel(.identityMismatch(stage: stage, field: field)),
                file: file,
                line: line
            )
        }
    }

    private func mismatchedIdentities()
        -> [(Policy.Identity, Policy.IdentityField)] {
        [
            (
                .init(
                    generation: identity.generation + 1,
                    ticketID: identity.ticketID,
                    strapIdentifier: identity.strapIdentifier,
                    callbackEpoch: identity.callbackEpoch,
                    connectionStartedAt: identity.connectionStartedAt
                ),
                .generation
            ),
            (
                .init(
                    generation: identity.generation,
                    ticketID: identity.ticketID + "-other",
                    strapIdentifier: identity.strapIdentifier,
                    callbackEpoch: identity.callbackEpoch,
                    connectionStartedAt: identity.connectionStartedAt
                ),
                .ticket
            ),
            (
                .init(
                    generation: identity.generation,
                    ticketID: identity.ticketID,
                    strapIdentifier: UUID(),
                    callbackEpoch: identity.callbackEpoch,
                    connectionStartedAt: identity.connectionStartedAt
                ),
                .strapIdentifier
            ),
            (
                .init(
                    generation: identity.generation,
                    ticketID: identity.ticketID,
                    strapIdentifier: identity.strapIdentifier,
                    callbackEpoch: identity.callbackEpoch + 1,
                    connectionStartedAt: identity.connectionStartedAt
                ),
                .callbackEpoch
            ),
            (
                .init(
                    generation: identity.generation,
                    ticketID: identity.ticketID,
                    strapIdentifier: identity.strapIdentifier,
                    callbackEpoch: identity.callbackEpoch,
                    connectionStartedAt:
                        identity.connectionStartedAt.addingTimeInterval(1)
                ),
                .connection
            ),
        ]
    }

    private func assertSendable<T: Sendable>(_: T.Type) {}
}
