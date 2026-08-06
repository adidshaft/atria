import Foundation

/// Pure, fail-closed authorization for submitting WHOOP 4's daily motion-bank
/// rearm (`0x69/0x01`) while a full historical drain is already active.
///
/// The policy owns no CoreBluetooth or persistence state. The caller must
/// construct every attestation from accepted, generation-fenced production
/// state immediately before submission. A `.send` result is a one-time
/// snapshot decision; it must not be retained across callbacks.
struct AtriaWhoop4DailyMotionBankRearmPolicy: Sendable {
    static let command = Command(opcode: 0x69, payload: [0x01])
    static let historyServeCommand = Command(opcode: 0x16, payload: [0x00])
    static let maximumAcceptedHRAge: TimeInterval = 15

    struct Command: Equatable, Sendable {
        let opcode: UInt8
        let payload: [UInt8]
    }

    /// All fields jointly identify one connection-owned history transaction.
    /// A generation alone is deliberately insufficient because generations
    /// can be reused after relaunch and callbacks can outlive a connection.
    struct Identity: Equatable, Sendable {
        let generation: UInt64
        let ticketID: String
        let strapIdentifier: UUID
        let callbackEpoch: UInt64
        let connectionStartedAt: Date
    }

    struct Attestation: Equatable, Sendable {
        let identity: Identity
    }

    struct ConfirmedCommand: Equatable, Sendable {
        let identity: Identity
        let command: Command
        let writeConfirmed: Bool
    }

    struct AcceptedHeartRate: Equatable, Sendable {
        let identity: Identity
        /// Monotonic age of the last accepted live HR sample.
        let age: TimeInterval
    }

    struct OperatingState: Equatable, Sendable {
        let batteryAllowsRearm: Bool
        let manualWorkoutActive: Bool
        let calibrationHoldActive: Bool
        let stopPending: Bool
        let cutoverActive: Bool
    }

    struct CommandPipe: Equatable, Sendable {
        let withResponseWritePending: Bool
        let historyACKGatePending: Bool
        let replayACKPending: Bool
        let continuationPending: Bool
        let durableFlushPending: Bool
        let ingressBarrierPending: Bool
    }

    struct WriteWithoutResponseState: Equatable, Sendable {
        let supported: Bool
        let ready: Bool
    }

    struct Input: Equatable, Sendable {
        /// Identity captured when this daily rearm attempt was created.
        let expectedIdentity: Identity
        /// Identity currently owned by the active history transaction.
        let activeHistoryIdentity: Identity?
        /// Exact confirmed `0x16/0x00` submission for this transaction.
        let confirmedHistoryServe: ConfirmedCommand?
        /// Accepted, parsed HISTORY_START for this transaction.
        let acceptedHistoryStart: Attestation?
        /// Active full-drain authority minted after HISTORY_START.
        let fullDrainAuthority: Attestation?
        /// Accepted terminal for any transaction. It must be absent.
        let acceptedTerminal: Attestation?
        /// Fresh accepted live HR proving the realtime path remains healthy.
        let acceptedHeartRate: AcceptedHeartRate?
        let operatingState: OperatingState
        let commandPipe: CommandPipe
        let writeWithoutResponse: WriteWithoutResponseState
        /// Verified support for `0x69/0x01` on this strap/connection.
        let verifiedCapability: Attestation?
    }

    enum IdentityStage: Equatable, Sendable {
        case activeHistory
        case historyServe
        case historyStart
        case fullDrainAuthority
        case terminal
        case acceptedHeartRate
        case capability
    }

    enum IdentityField: Equatable, Sendable {
        case generation
        case ticket
        case strapIdentifier
        case callbackEpoch
        case connection
    }

    enum CancelReason: Equatable, Sendable {
        case activeHistoryMissing
        case attestationMissing(IdentityStage)
        case identityMismatch(stage: IdentityStage, field: IdentityField)
        case historyServeCommandMismatch
        case historyServeWriteUnconfirmed
        case terminalObserved
        case batteryBlocked
        case manualWorkoutActive
        case calibrationHoldActive
        case stopPending
        case cutoverActive
        case invalidAcceptedHRAge
        case writeWithoutResponseUnsupported
    }

    enum DeferReason: Equatable, Sendable {
        case acceptedHeartRateUnavailable
        case acceptedHeartRateStale
        case withResponseWritePending
        case historyACKGatePending
        case replayACKPending
        case continuationPending
        case durableFlushPending
        case ingressBarrierPending
        case writeWithoutResponseNotReady
    }

    enum Decision: Equatable, Sendable {
        case send(Command)
        case `defer`(DeferReason)
        case cancel(CancelReason)
    }

    static func evaluate(_ input: Input) -> Decision {
        let expected = input.expectedIdentity

        guard let active = input.activeHistoryIdentity else {
            return .cancel(.activeHistoryMissing)
        }
        if let mismatch = identityMismatch(expected, active) {
            return .cancel(.identityMismatch(
                stage: .activeHistory,
                field: mismatch
            ))
        }

        guard let serve = input.confirmedHistoryServe else {
            return .cancel(.attestationMissing(.historyServe))
        }
        if let mismatch = identityMismatch(expected, serve.identity) {
            return .cancel(.identityMismatch(
                stage: .historyServe,
                field: mismatch
            ))
        }
        guard serve.command == historyServeCommand else {
            return .cancel(.historyServeCommandMismatch)
        }
        guard serve.writeConfirmed else {
            return .cancel(.historyServeWriteUnconfirmed)
        }

        guard let historyStart = input.acceptedHistoryStart else {
            return .cancel(.attestationMissing(.historyStart))
        }
        if let mismatch = identityMismatch(expected, historyStart.identity) {
            return .cancel(.identityMismatch(
                stage: .historyStart,
                field: mismatch
            ))
        }

        guard let authority = input.fullDrainAuthority else {
            return .cancel(.attestationMissing(.fullDrainAuthority))
        }
        if let mismatch = identityMismatch(expected, authority.identity) {
            return .cancel(.identityMismatch(
                stage: .fullDrainAuthority,
                field: mismatch
            ))
        }

        if let terminal = input.acceptedTerminal {
            if let mismatch = identityMismatch(expected, terminal.identity) {
                return .cancel(.identityMismatch(
                    stage: .terminal,
                    field: mismatch
                ))
            }
            return .cancel(.terminalObserved)
        }

        guard input.operatingState.batteryAllowsRearm else {
            return .cancel(.batteryBlocked)
        }
        guard !input.operatingState.manualWorkoutActive else {
            return .cancel(.manualWorkoutActive)
        }
        guard !input.operatingState.calibrationHoldActive else {
            return .cancel(.calibrationHoldActive)
        }
        guard !input.operatingState.stopPending else {
            return .cancel(.stopPending)
        }
        guard !input.operatingState.cutoverActive else {
            return .cancel(.cutoverActive)
        }

        guard input.writeWithoutResponse.supported else {
            return .cancel(.writeWithoutResponseUnsupported)
        }

        guard let capability = input.verifiedCapability else {
            return .cancel(.attestationMissing(.capability))
        }
        if let mismatch = identityMismatch(expected, capability.identity) {
            return .cancel(.identityMismatch(
                stage: .capability,
                field: mismatch
            ))
        }

        guard let heartRate = input.acceptedHeartRate else {
            return .defer(.acceptedHeartRateUnavailable)
        }
        if let mismatch = identityMismatch(expected, heartRate.identity) {
            return .cancel(.identityMismatch(
                stage: .acceptedHeartRate,
                field: mismatch
            ))
        }
        guard heartRate.age.isFinite, heartRate.age >= 0 else {
            return .cancel(.invalidAcceptedHRAge)
        }
        guard heartRate.age <= maximumAcceptedHRAge else {
            return .defer(.acceptedHeartRateStale)
        }

        if input.commandPipe.withResponseWritePending {
            return .defer(.withResponseWritePending)
        }
        if input.commandPipe.historyACKGatePending {
            return .defer(.historyACKGatePending)
        }
        if input.commandPipe.replayACKPending {
            return .defer(.replayACKPending)
        }
        if input.commandPipe.continuationPending {
            return .defer(.continuationPending)
        }
        if input.commandPipe.durableFlushPending {
            return .defer(.durableFlushPending)
        }
        if input.commandPipe.ingressBarrierPending {
            return .defer(.ingressBarrierPending)
        }
        guard input.writeWithoutResponse.ready else {
            return .defer(.writeWithoutResponseNotReady)
        }

        return .send(command)
    }

    private static func identityMismatch(
        _ expected: Identity,
        _ observed: Identity
    ) -> IdentityField? {
        if expected.generation != observed.generation {
            return .generation
        }
        if expected.ticketID != observed.ticketID {
            return .ticket
        }
        if expected.strapIdentifier != observed.strapIdentifier {
            return .strapIdentifier
        }
        if expected.callbackEpoch != observed.callbackEpoch {
            return .callbackEpoch
        }
        if expected.connectionStartedAt != observed.connectionStartedAt {
            return .connection
        }
        return nil
    }
}
